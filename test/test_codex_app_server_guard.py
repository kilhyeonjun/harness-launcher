#!/usr/bin/env python3
"""Contract for the Codex app-server harness-boundary guard.

SDK hosts (Paseo) start one `codex app-server` per agent in their own working
directory and send each thread's cwd over JSON-RPC. The guard relays that
stream and rejects fields that would make Codex execute, or load
instructions, outside the selected harness.
"""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "bin" / "codex-app-server-guard.py"
FIELDS_FIXTURE = ROOT / "test" / "fixtures" / "codex-app-server-path-fields.json"

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("codex_app_server_guard", GUARD)
guard_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard_module)

# Fake app-server: echoes every received line as {"echo": <line>} and exits 7
# on EOF; exits 0 on SIGTERM so signal forwarding is observable.
FAKE_SERVER = r"""
import json, signal, sys
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
for raw in sys.stdin.buffer:
    sys.stdout.write(json.dumps({"echo": raw.decode().rstrip("\n")}) + "\n")
    sys.stdout.flush()
sys.exit(7)
"""


def schema_path_fields(schema_dir):
    """Return sorted "Definition.field" path fields a client can send.

    Client-sent messages are requests and notifications plus responses to
    server requests (approvals, elicitations).
    """
    schema_dir = Path(schema_dir)
    path_types = ("AbsolutePathBuf", "LegacyAppPathString")
    names = ("cwd", "cwds", "path", "paths", "root", "roots")
    suffixes = ("Root", "Roots", "Path", "Paths")
    roots = [schema_dir / "ClientRequest.json", schema_dir / "ClientNotification.json"]
    for item in json.loads((schema_dir / "ServerRequest.json").read_text())["oneOf"]:
        ref = (item["properties"].get("params") or {}).get("$ref", "")
        response = schema_dir / (ref.rsplit("/", 1)[-1].removesuffix("Params") + "Response.json")
        if ref.endswith("Params") and response.is_file():
            roots.append(response)
    found = set()

    def is_path_field(key, node):
        if key in names or key.endswith(suffixes):
            return True
        return any(f'/{kind}"' in json.dumps(node) for kind in path_types)

    for document_path in roots:
        document = json.loads(document_path.read_text())
        definitions = document.get("definitions") or {}
        seen = set()

        def walk(node, trail, owner):
            if isinstance(node, list):
                for item in node:
                    walk(item, trail, owner)
                return
            if not isinstance(node, dict):
                return
            ref = node.get("$ref", "")
            if ref.startswith("#/definitions/"):
                name = ref.rsplit("/", 1)[-1]
                if name not in seen:
                    seen.add(name)
                    walk(definitions[name], [], name)
            for key, value in (node.get("properties") or {}).items():
                if is_path_field(key, value):
                    found.add(".".join([owner, *trail, key]))
                walk(value, trail + [key], owner)
            for key in ("items", "additionalProperties"):
                walk(node.get(key), trail, owner)
            for key in ("anyOf", "oneOf", "allOf"):
                walk(node.get(key), trail, owner)

        walk(document, [], document_path.stem)
    return sorted(found)


class GuardProcessTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.root = base / "harness"
        self.inside = self.root / "projects" / "app"
        self.inside.mkdir(parents=True)
        self.nested = self.root / "projects" / "nested-harness"
        (self.nested / "config").mkdir(parents=True)
        (self.nested / "config" / "launcher.env").write_text('HARNESS_PREFIX="nested"\n')
        (self.root / "config").mkdir()
        (self.root / "config" / "launcher.env").write_text('HARNESS_PREFIX="alpha"\n')
        self.registry = base / "profiles"
        self.registry.mkdir()
        (self.registry / "alpha").write_text(f"{self.root}\n")
        (self.registry / "nested").write_text(f"{self.nested}\n")
        self.outside = base / "elsewhere"
        self.outside.mkdir()
        (self.root / "escape").symlink_to(self.outside, target_is_directory=True)
        self.server = base / "fake_server.py"
        self.server.write_text(FAKE_SERVER)

    def command(self):
        return [sys.executable, str(GUARD), "--root", str(self.root), "--server-cwd", str(self.inside),
                "--prefix", "alpha", "--registry", str(self.registry),
                "--", sys.executable, str(self.server)]

    def run_guard(self, lines):
        proc = subprocess.run(self.command(), input="".join(line + "\n" for line in lines).encode(),
                              capture_output=True, cwd=str(self.root), timeout=20)
        out = [json.loads(line) for line in proc.stdout.decode().splitlines() if line.strip()]
        return proc.returncode, out, proc.stderr.decode()

    @staticmethod
    def request(method, params, rid=1):
        return json.dumps({"id": rid, "method": method, "params": params})

    @staticmethod
    def errors(out):
        return [m for m in out if "error" in m]

    @staticmethod
    def echoes(out):
        return [json.loads(m["echo"]) for m in out if "echo" in m]

    def test_inside_and_exempt_fields_are_forwarded(self):
        lines = [
            self.request("thread/start", {"cwd": str(self.inside)}, 1),
            self.request("turn/start", {"threadId": "t", "cwd": str(self.root)}, 2),
            self.request("thread/start", {"cwd": None}, 3),
            self.request("thread/start", {}, 4),
            self.request("turn/start", {"threadId": "t", "cwd": str(self.inside / "new-dir"),
                                        "input": [{"type": "localImage", "path": str(self.outside / "a.png")}]}, 5),
            self.request("fs/readFile", {"path": str(self.outside / "note")}, 6),
            self.request("fuzzyFileSearch", {"query": "q", "roots": [str(self.outside)]}, 7),
            self.request("turn/start", {"threadId": "t", "cwd": str(self.inside),
                                        "sandboxPolicy": {"type": "workspaceWrite", "writableRoots": [str(self.outside)]}}, 8),
            self.request("skills/config/write", {"path": str(self.outside / "SKILL.md"), "enabled": True}, 9),
            self.request("thread/list", {"cwd": [str(self.inside), str(self.root)]}, 10),
            self.request("thread/start", {"cwd": str(self.inside), "selectedCapabilityRoots": [
                {"id": "c", "location": {"type": "environment", "environmentId": "e", "path": str(self.inside)}}]}, 11),
            json.dumps({"id": 12, "result": {"permissions": {"fileSystem": {"write": [str(self.outside)]}}}}),
        ]
        code, out, _ = self.run_guard(lines)
        self.assertEqual(code, 7)
        self.assertEqual(self.errors(out), [])
        self.assertEqual([m["id"] for m in self.echoes(out)], list(range(1, 13)))

    def test_outside_execution_fields_are_rejected(self):
        cases = [
            ("thread/start", {"cwd": str(self.outside)}),
            ("thread/resume", {"threadId": "t", "cwd": str(self.outside)}),
            ("thread/fork", {"threadId": "t", "cwd": str(self.outside)}),
            ("turn/start", {"threadId": "t", "cwd": str(self.outside)}),
            ("command/exec", {"command": ["ls"], "cwd": str(self.outside)}),
            ("process/spawn", {"command": ["ls"], "cwd": str(self.outside)}),
            ("config/read", {"cwd": str(self.outside)}),
            ("plugin/list", {"cwds": [str(self.inside), str(self.outside)]}),
            ("thread/start", {"cwd": str(self.inside), "runtimeWorkspaceRoots": [str(self.outside)]}),
            ("turn/start", {"threadId": "t", "cwd": str(self.inside),
                            "environments": [{"id": "e", "cwd": str(self.outside)}]}),
            ("skills/extraRoots/set", {"extraRoots": [str(self.outside)]}),
            ("thread/start", {"cwd": str(self.root / "escape")}),
            ("thread/start", {"cwd": str(self.root / ".." / "elsewhere")}),
            ("thread/start", {"cwd": str(self.root / "missing" / ".." / ".." / "elsewhere")}),
            ("thread/start", {"cwd": "~"}),
            ("thread/start", {"cwd": "projects/app"}),
            ("thread/start", {"cwd": 42}),
            ("thread/start", {"cwd": str(self.nested)}),
            ("thread/start", {"cwd": f"{self.root}-evil"}),
            ("thread/list", {"cwd": [str(self.inside), str(self.outside)]}),
            ("thread/settings/update", {"threadId": "t", "cwd": str(self.outside)}),
            ("thread/start", {"selectedCapabilityRoots": [
                {"id": "c", "location": {"type": "environment", "environmentId": "e", "path": str(self.outside)}}]}),
        ]
        lines = [self.request(method, params, rid) for rid, (method, params) in enumerate(cases, 1)]
        code, out, _ = self.run_guard(lines)
        self.assertEqual(code, 7)
        self.assertEqual(self.echoes(out), [])
        errors = self.errors(out)
        self.assertEqual(sorted(m["id"] for m in errors), list(range(1, len(cases) + 1)))
        for message in errors:
            self.assertEqual(message["error"]["code"], -32602)
            self.assertIn("outside the alpha harness boundary", message["error"]["message"])

    def test_resume_and_fork_without_cwd_get_the_server_cwd(self):
        lines = [
            self.request("thread/resume", {"threadId": "t"}, 1),
            self.request("thread/fork", {"threadId": "t", "cwd": None}, 2),
        ]
        code, out, _ = self.run_guard(lines)
        self.assertEqual(self.errors(out), [])
        self.assertEqual([m["params"]["cwd"] for m in self.echoes(out)], [str(self.inside)] * 2)

    def test_violating_notification_is_dropped(self):
        line = json.dumps({"method": "thread/start", "params": {"cwd": str(self.outside)}})
        code, out, err = self.run_guard([line, json.dumps({"method": "initialized"})])
        self.assertEqual(out, [{"echo": json.dumps({"method": "initialized"})}])
        self.assertIn("outside the alpha harness boundary", err)

    def test_unparseable_lines_and_batches_are_rejected(self):
        batch = json.dumps([{"id": 1, "method": "model/list", "params": {}}])
        code, out, _ = self.run_guard(["not json", batch, self.request("model/list", {}, 3)])
        self.assertEqual([m["error"]["code"] for m in self.errors(out)], [-32700, -32600])
        self.assertEqual([m["id"] for m in self.errors(out)], [None, None])
        self.assertEqual([m["id"] for m in self.echoes(out)], [3])

    def test_sigterm_is_forwarded_while_stdin_stays_open(self):
        proc = subprocess.Popen(self.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, cwd=str(self.root))
        proc.stdin.write((self.request("model/list", {}) + "\n").encode())
        proc.stdin.flush()
        self.assertIn(b"echo", proc.stdout.readline())
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=10), 0)
        proc.stdin.close()
        proc.stdout.close()

    def test_malformed_messages_get_errors_and_the_relay_continues(self):
        deep = '{"id": 2, "method": "thread/start", "params": ' + '{"a": ' * 5000 + '1' + '}' * 5000 + '}'
        lines = [
            '{"id": 1, "method": "thread/start", "params": {"cwd": "/tmp", "cwd": "%s"}}' % self.inside,
            deep,
            json.dumps({"id": 3, "method": "thread/start", "params": {"cwd": str(self.inside) + "\u0000x"}}),
            self.request("model/list", {}, 4),
        ]
        code, out, _ = self.run_guard(lines)
        self.assertEqual(code, 7)
        self.assertEqual(len(self.errors(out)), 3)
        self.assertEqual([m["id"] for m in self.echoes(out)], [4])

    def test_tilde_inside_the_harness_is_allowed(self):
        env = dict(os.environ, HOME=str(self.root))
        line = self.request("thread/start", {"cwd": "~/projects/app"})
        proc = subprocess.run(self.command(), input=(line + "\n").encode(), capture_output=True,
                              cwd=str(self.root), timeout=20, env=env)
        out = [json.loads(item) for item in proc.stdout.decode().splitlines()]
        self.assertEqual(self.errors(out), [])
        self.assertEqual(len(self.echoes(out)), 1)

    def test_violating_response_becomes_a_refusal_to_the_server(self):
        line = json.dumps({"id": 9, "result": {"cwd": str(self.outside)}})
        code, out, _ = self.run_guard([line])
        forwarded = self.echoes(out)
        self.assertEqual(len(forwarded), 1)
        self.assertEqual(forwarded[0]["id"], 9)
        self.assertEqual(forwarded[0]["error"]["code"], -32602)
        self.assertNotIn("result", forwarded[0])

    def test_unchecked_responses_are_refused_to_the_server(self):
        lines = [
            '{"id": 21, "result": {"decision": "accept", "decision": "decline"}}',
            json.dumps({"id": 22, "result": {"cwd": str(self.inside) + "\u0000x"}}),
        ]
        code, out, _ = self.run_guard(lines)
        self.assertEqual(self.errors(out), [])
        forwarded = self.echoes(out)
        self.assertEqual([m["id"] for m in forwarded], [21, 22])
        self.assertEqual({m["error"]["code"] for m in forwarded}, {-32600})

    def test_nested_harness_in_another_letter_case_is_rejected(self):
        variant = self.root / "projects" / "NESTED-HARNESS"
        if not variant.exists():
            self.skipTest("case-sensitive filesystem")
        code, out, _ = self.run_guard([self.request("thread/start", {"cwd": str(variant)})])
        self.assertEqual([m["error"]["code"] for m in self.errors(out)], [-32602])

    def test_large_lines_are_relayed_quickly_both_ways(self):
        big = "x" * (4 * 1024 * 1024)
        started = time.monotonic()
        code, out, _ = self.run_guard([self.request("thread/start", {"cwd": str(self.inside), "note": big})])
        elapsed = time.monotonic() - started
        self.assertEqual(code, 7)
        self.assertEqual(self.echoes(out)[0]["params"]["note"], big)
        self.assertLess(elapsed, 10)

    def test_signalled_child_status_is_128_plus_signal(self):
        self.server.write_text("import os, signal\nos.kill(os.getpid(), signal.SIGKILL)\n")
        code, _, _ = self.run_guard([])
        self.assertEqual(code, 128 + signal.SIGKILL)

    def test_usage_errors_exit_2(self):
        for argv in ([], ["--root", str(self.root)],
                     ["--root", str(self.root), "--server-cwd", str(self.root), "--prefix", "a", "--"],
                     ["--root", str(self.outside / "missing"), "--server-cwd", str(self.root),
                      "--prefix", "a", "--", "true"],
                     ["--root", str(self.root), "--server-cwd", str(self.outside), "--prefix", "a", "--", "true"]):
            proc = subprocess.run([sys.executable, str(GUARD), *argv], capture_output=True, timeout=10)
            self.assertEqual(proc.returncode, 2, argv)


class SchemaDriftTest(unittest.TestCase):
    def test_every_schema_path_field_is_classified(self):
        fields = json.loads(FIELDS_FIXTURE.read_text())["fields"]
        unclassified = [field for field in fields if not guard_module.classify_field(field)]
        self.assertEqual(unclassified, [])

    @unittest.skipUnless(shutil.which("codex"), "codex is not installed")
    def test_fixture_matches_installed_codex_schema(self):
        with tempfile.TemporaryDirectory() as out, tempfile.TemporaryDirectory() as home:
            subprocess.run(["codex", "app-server", "generate-json-schema", "--experimental", "--out", out],
                           check=True, capture_output=True, timeout=60,
                           env={"CODEX_HOME": home, "HOME": home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
            self.assertEqual(schema_path_fields(out), json.loads(FIELDS_FIXTURE.read_text())["fields"],
                             "regenerate test/fixtures/codex-app-server-path-fields.json and classify new fields")


if __name__ == "__main__":
    unittest.main()
