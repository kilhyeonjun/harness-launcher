#!/usr/bin/env python3
"""Exercise run-all's real dispatcher/accounting with disposable child executors."""
import copy
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
RUNNER = Path(os.environ.get("RUN_ALL_UNDER_TEST", ROOT / "test/run-all.sh"))
SOURCES = Path(os.environ.get("RUN_ALL_TEST_SOURCES", ROOT))
WORKFLOW = Path(os.environ.get("RUN_ALL_TEST_WORKFLOW", ROOT / ".github/workflows/ci.yml"))
PRESERVATION = "test_git_policy.py test_preservation_snapshot.py test_trusted_preservation.py test_preservation_adversarial.py".split()
# A representative child for failure/source-drift injection, not a copied inventory.
PYTHON = ['test_profile_resolver.py']
HEADLESS = ["test-harness-headless.sh", "test-headless-target.sh"]
LOCKF = set("test-harness-exec-workspace-choice-tui.sh test-codex-config-preservation.sh test-codex-global-mcp-drift.sh test-codex-home-lock.sh test-codex-home-prepare.sh test-codex-history-gc.sh test-codex-history-resume-integration.sh test-codex-observability-profile.sh test-codex-migrate-to-symlinks.sh test-codex-project-trust.sh test-session-isolation.sh test-session-isolation-concurrency.sh test-session-transcript-retention.sh test-harness-headless.sh test-headless-target.sh".split())
GROUPS = ("headless", "headless-security", "headless-codex", "target", "sessions", "shell", "shell-extra", "preservation", "python")
SHARDS = ("delivery", "security", "codex")
TARGET = set("test-headless-target.sh test-terminal-runtime-launch.sh test-omp-routing.sh test-orca-resume.sh test-launcher-isolated.sh".split())
LOCKF.update("test-harness-headless.sh@" + shard for shard in SHARDS)
SHA = "a" * 40


def bounded_child(argv, **kwargs):
    """Local test utility: exact owned child, 30s/64KiB combined capture."""
    child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, **kwargs)
    streams = {"stdout":bytearray(), "stderr":bytearray()}
    deadline = time.monotonic() + 30
    try:
        with selectors.DefaultSelector() as watch:
            watch.register(child.stdout, selectors.EVENT_READ, "stdout")
            watch.register(child.stderr, selectors.EVENT_READ, "stderr")
            while watch.get_map():
                left = deadline-time.monotonic()
                if left <= 0:
                    raise AssertionError("owned fake entry exceeded30s; no retry")
                for key, _ in watch.select(min(left,0.2)):
                    data = os.read(key.fd,8192)
                    if not data:
                        watch.unregister(key.fileobj)
                    else:
                        if sum(map(len,streams.values()))+len(data)>65536:
                            raise AssertionError("owned fake capture exceeded64KiB; no retry")
                        streams[key.data].extend(data)
        status = child.wait(timeout=max(0.001,deadline-time.monotonic()))
    finally:
        if child.poll() is None:
            child.kill()
        child.wait()
        child.stdout.close()
        child.stderr.close()
    return subprocess.CompletedProcess(argv,status,streams["stdout"].decode(),streams["stderr"].decode())

# This boundary replaces only expensive/external children and Git metadata.
# Actual runner selection, argv, admission, receipt serialization and verification run.
BOUNDARY = r'''
import json,os,pathlib,sys
kind=sys.argv[1];args=sys.argv[2:];root=pathlib.Path(os.environ['FAKE_ROOT'])
def log(value):
 with open(os.environ['TRACE'],'a') as f:f.write(json.dumps(value)+'\n')
if kind=='git':
 if args==['-C',str(root),'rev-parse','HEAD']:print(os.environ.get('ACTUAL_SHA','a'*40));sys.exit(0)
 if args==['-C',str(root),'ls-files','-z']:
  sys.stdout.buffer.write(b''.join(os.fsencode(str(p.relative_to(root)))+b'\0' for p in sorted(root.rglob('*')) if p.is_file()));sys.exit(0)
 sys.exit(29)
if kind in ('initial','resolved') and '-' in args:
 os.execv(sys.executable,[sys.executable]+args)
if kind=='initial' and args[-1].endswith('/omp-fixture-source.py'):
 log({'stage':'admission'});sys.exit(17) if os.environ.get('FAIL_PREP') else None
 print(root/'synthetic-source');sys.exit(0)
if '-p' in args:name=args[args.index('-p')+1]
else:name=pathlib.Path(args[0] if kind in ('bash','zsh') else args[-1]).name
if '--ci-shard' in args:name+='@'+args[args.index('--ci-shard')+1]
normalized=[a.replace(str(root),'ROOT') for a in args]
log({'stage':'child','id':name,'kind':kind,'argv':normalized,'source':os.environ.get('HARNESS_TEST_OMP_SOURCE'),'mirror':os.environ.get('HARNESS_CLAUDE_PLUGIN_MIRROR')})
if os.environ.get('MUTATE_ON')==name:
 with open(root/'test/run-all.sh','a') as f:f.write('\n# changed during child\n')
sys.exit(7 if os.environ.get('FAIL_CHILD')==name else 0)
'''


class Fixture:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="run-all-partition-")
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "source"
        for name in ("test", "bin", ".github/workflows"):
            (self.root / name).mkdir(parents=True)
        self.shells = sorted(p.name for p in (SOURCES / "test").glob("test-*.sh"))
        for name in self.shells:
            first = (SOURCES / "test" / name).read_text().splitlines()[0]
            markers = ""
            if name == HEADLESS[0]:
                markers = "".join(f"# CI_SHARD_BEGIN {shard}\n# --- {shard}\n# CI_SHARD_END {shard}\n" for shard in SHARDS)
            (self.root / "test" / name).write_text(first + "\n" + markers + "exit 0\n")
        for pattern in ('test_*.py', 'test_*.mjs'):
            for source in (SOURCES / 'test').glob(pattern):
                (self.root / 'test' / source.name).write_text('# owned synthetic child\n')
        (self.root / "test/omp-fixture-source.py").write_text("# admission handled at the boundary\n")
        (self.root / "test/run-all.sh").write_bytes(RUNNER.read_bytes())
        (self.root / ".github/workflows/ci.yml").write_bytes(WORKFLOW.read_bytes())
        self.trace = self.base / "trace.jsonl"
        boundary = self.base / "boundary.py"
        boundary.write_text(BOUNDARY)
        tools = self.base / "tools"
        tools.mkdir()
        for name, kind in (("python3", "initial"), ("resolved-python", "resolved"), ("child-bash", "bash"), ("child-zsh", "zsh"), ("node", "node"), ("git", "git")):
            f = tools / name
            f.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " -I -S -B " + shlex.quote(str(boundary)) + " " + kind + ' "$@"\n')
            f.chmod(0o700)
        common = self.root / "bin/harness-common.sh"
        common.write_text('harness_python3_resolve() { printf "%s\\n" "{\\\"stage\\\":\\\"resolve\\\"}" >> "$TRACE"; printf "%s\\n" "$RESOLVED_PYTHON"; }\n')
        (self.base / "home").mkdir(mode=0o700)
        (self.base / "results").mkdir(mode=0o700)
        self.env = {"PATH":str(tools)+":/usr/bin:/bin:/usr/sbin:/sbin", "HOME":str(self.base/"home"),
                    "BASH_BIN":str(tools/"child-bash"), "ZSH_BIN":str(tools/"child-zsh"),
                    "RESOLVED_PYTHON":str(tools/"resolved-python"), "TRACE":str(self.trace), "FAKE_ROOT":str(self.root),
                    "GITHUB_ACTIONS":"true", "GITHUB_RUN_ID":"123", "GITHUB_RUN_ATTEMPT":"2", "GITHUB_SHA":SHA,
                    "CI_PR_HEAD":"b"*40, "GITHUB_EVENT_NAME":"pull_request", "RUNNER_TEMP":str(self.base/"results"), "LC_ALL":"C",
                    "HARNESS_TEST_FORCE_NO_LOCKF":os.environ.get("HARNESS_TEST_FORCE_NO_LOCKF","0")}

    def close(self):
        self.temp.cleanup()

    def run(self, *args, **env):
        self.trace.write_text("")
        effective = dict(self.env, **env)
        self.lockf_available = os.access("/usr/bin/lockf", os.X_OK) and effective.get("HARNESS_TEST_FORCE_NO_LOCKF") != "1"
        return bounded_child(["/bin/bash", str(self.root/"test/run-all.sh"), *args], cwd=self.root,
                             env=effective)

    def events(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()]

    def lane(self, group, **env):
        target = self.base / "results" / (group + ".json")
        r = self.run("--ci-group", group, "--ci-result", str(target), **env)
        return r, target

    def results(self):
        outputs = {}
        for group in GROUPS:
            r, target = self.lane(group)
            if r.returncode or not target.exists():
                raise AssertionError("lane did not emit a successful typed result: " + group + " " + r.stderr[-800:])
            outputs[group] = json.loads(target.read_text())
        return outputs

    def verify(self, outputs):
        env = {"CI_RESULT_"+g.upper().replace('-', '_'):json.dumps(outputs[g],separators=(",",":")) for g in outputs}
        return self.run("--ci-verify", **env)


class Partition(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.addCleanup(self.f.close)

    def test_source_admission_failure_calls_no_child_and_creates_no_result(self):
        r,target=self.f.lane("python",FAIL_PREP="1")
        self.assertEqual(r.returncode,17)
        self.assertEqual(self.f.events(),[{"stage":"admission"}])
        self.assertFalse(target.exists())

    def test_first_child_failure_preserves_exit_and_no_later_calls_or_receipt(self):
        first=self.f.shells[0]
        r,target=self.f.lane("shell",FAIL_CHILD=first)
        self.assertEqual(r.returncode,7)
        self.assertEqual([e["id"] for e in self.f.events() if e["stage"]=="child"],[first])
        self.assertNotIn({"stage":"resolve"},self.f.events())
        self.assertFalse(target.exists())
        self.assertIn("REGRESSION_CHILD_FAILED",r.stderr)

    def test_original_lockf_only_skips_and_complete_accounting(self):
        sessions=[n for n in self.f.shells if n.startswith("test-session-")]
        remaining=[n for n in self.f.shells if n != HEADLESS[0] and n not in TARGET and n not in sessions]
        partitions=(("headless",[HEADLESS[0]+"@delivery"]),
                    ("headless-security",[HEADLESS[0]+"@security"]),
                    ("headless-codex",[HEADLESS[0]+"@codex"]),
                    ("target",[n for n in self.f.shells if n in TARGET]),
                    ("sessions",sessions),("shell",remaining[::2]),("shell-extra",remaining[1::2]))
        for group,expected in partitions:
            with self.subTest(group=group):
                r,target=self.f.lane(group,HARNESS_TEST_FORCE_NO_LOCKF="1")
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertTrue(target.is_file(),"missing lane accounting")
                result=json.loads(target.read_text())
                self.assertEqual(result["scheduled_ids"],expected)
                self.assertEqual(result["completed_ids"],[n for n in expected if n not in LOCKF])
                self.assertEqual(result["skipped_ids_with_original_reason"],[{"id":n,"reason":"lockf-unavailable"} for n in expected if n in LOCKF])

    def test_bad_cli_and_unowned_or_existing_result_refuse_before_child(self):
        bad=[("--ci-group","unknown","--ci-result",str(self.f.base/"results/x")),("--ci-group","shell"),("--ci-verify","extra"),("--unknown",)]
        for args in bad:
            with self.subTest(args=args):
                r=self.f.run(*args);self.assertNotEqual(r.returncode,0)
                self.assertFalse(any(e.get("stage")=="child" for e in self.f.events()))
        target=self.f.base/"results/existing";target.write_text("preserve")
        for path in [target,self.f.root/"outside-result"]:
            r=self.f.run("--ci-group","shell","--ci-result",str(path));self.assertNotEqual(r.returncode,0)
            self.assertFalse(any(e.get("stage")=="child" for e in self.f.events()))
        self.assertEqual(target.read_text(),"preserve")

    def test_source_change_during_child_cannot_publish_success(self):
        r,target=self.f.lane("python",MUTATE_ON=PYTHON[0])
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(target.exists())

    def test_actual_checkout_mismatch_refuses_before_child(self):
        r,target=self.f.lane("headless",ACTUAL_SHA="c"*40)
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(target.exists())
        self.assertFalse(any(e.get("stage")=="child" for e in self.f.events()))

    def test_push_without_pr_object_accepts_only_current_checkout_and_null_pr_head(self):
        self.f.env.update(GITHUB_EVENT_NAME="push",CI_PR_HEAD="")
        outputs=self.f.results()
        for result in outputs.values():
            self.assertIsNone(result["pr_head_if_applicable"])
            self.assertEqual(result["execution_sha"],SHA)
        self.assertEqual(self.f.verify(outputs).returncode,0)
        outputs["shell"]["pr_head_if_applicable"]="b"*40
        self.assertNotEqual(self.f.verify(outputs).returncode,0)

    def test_mixed_successful_attempts_accept_only_same_run_and_source(self):
        outputs=self.f.results()
        for group in GROUPS[::2]:
            outputs[group]['run_attempt']=1
        result=self.f.verify(outputs)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('CI_INVENTORY_COMPLETE',result.stdout)
        for key,value in (('run_id',124),('execution_sha','c'*40),('pr_head_if_applicable','d'*40),
                          ('run_attempt',0),('run_attempt',-1),('run_attempt',3)):
            changed=copy.deepcopy(outputs)
            changed['headless'][key]=value
            self.assertNotEqual(self.f.verify(changed).returncode,0,(key,value))
        del outputs['headless-codex']
        self.assertNotEqual(self.f.verify(outputs).returncode,0)

    def test_ci_union_covers_full_inventory_once_with_all_headless_cases(self):
        result=self.f.run(HARNESS_TEST_FORCE_NO_LOCKF='1')
        self.assertEqual(result.returncode,0,result.stderr)
        full=[e['id'] for e in self.f.events() if e['stage']=='child']
        # Original platform skips are represented in receipts, not executed.
        full.extend(n for n in self.f.shells if n in LOCKF)
        outputs=self.f.results()
        union=[name for value in outputs.values() for name in value['scheduled_ids']]
        self.assertEqual(len(union),len(set(union)))
        self.assertEqual(set(union),set(full)-{HEADLESS[0]}|{HEADLESS[0]+'@'+s for s in SHARDS})
        self.assertEqual(self.f.verify(outputs).returncode,0)

    def test_aggregate_rejects_typed_identity_source_and_coverage_corruption(self):
        original=self.f.results()
        mutations=[("schema",True),("run_id",True),("run_id","123"),("run_id",124),("run_attempt",True),("run_attempt",3),("execution_sha","c"*40),("pr_head_if_applicable",SHA),("pr_head_if_applicable",None),("inventory_sha","d"*64),("group","headless"),("exit",True),("exit",1),("completed_ids",[]),("completed_ids",True),("scheduled_ids",[]),("skipped_ids_with_original_reason",[{'id':PYTHON[0],'reason':'new-skip'}])]
        for field,value in mutations:
            with self.subTest(field=field,value=value):
                outputs=copy.deepcopy(original);outputs["python"][field]=value
                self.assertNotEqual(self.f.verify(outputs).returncode,0)
        for kind in ("missing","extra","duplicate","reorder","moved","unexpected-field"):
            with self.subTest(kind=kind):
                outputs=copy.deepcopy(original);r=outputs["python"]
                if kind=="missing":r["completed_ids"].pop()
                elif kind=="extra":r["completed_ids"].append("test_unregistered.py")
                elif kind=="duplicate":r["completed_ids"].append(r["completed_ids"][0])
                elif kind=="reorder":r["completed_ids"].reverse()
                elif kind=="moved":r["scheduled_ids"].append(HEADLESS[0])
                else:r["success"]=True
                self.assertNotEqual(self.f.verify(outputs).returncode,0)
        for group in GROUPS:
            outputs=copy.deepcopy(original);del outputs[group]
            self.assertNotEqual(self.f.verify(outputs).returncode,0)
        duplicate_key=json.dumps(original['shell'])[:-1]+',"group":"shell"}'
        for raw in ("{", "null", "[]", "true", "{}", "x"*32769, duplicate_key):
            env={"CI_RESULT_"+g.upper().replace('-', '_'):json.dumps(original[g]) for g in GROUPS}
            env["CI_RESULT_SHELL"]=raw
            self.assertNotEqual(self.f.run("--ci-verify",**env).returncode,0)

    def test_current_source_changed_after_results_cannot_be_accepted(self):
        outputs=self.f.results()
        with (self.f.root/"test"/self.f.shells[0]).open("a") as f:f.write("# current closure changed\n")
        self.assertNotEqual(self.f.verify(outputs).returncode,0)


class Workflow(unittest.TestCase):
    def test_terminal_gate_rejects_any_unsuccessful_lane(self):
        source=WORKFLOW.read_text()
        job_source=source.split("\njobs:\n",1)[1]
        matches=list(re.finditer(r"^  ([a-z][a-z-]*):\n",job_source,re.M))
        jobs={m.group(1):job_source[m.end():matches[i+1].start() if i+1<len(matches) else len(job_source)] for i,m in enumerate(matches)}
        aggregate=jobs["test"]
        # Run the actual final gate shell with owned stubs, not GitHub or real suites.
        block=aggregate.split("      - name: Verify complete regression results\n",1)[1]
        script=block.split("        run: |\n",1)[1]
        script="\n".join(line[10:] for line in script.splitlines() if line.startswith("          "))+"\n"
        with tempfile.TemporaryDirectory(prefix="aggregate-gate-") as tmp:
            root=Path(tmp);(root/"test").mkdir()
            stub=root/"test/run-all.sh";stub.write_text('#!/bin/sh\nprintf invoked > "$MARKER"\n');stub.chmod(0o700)
            base={"PATH":"/usr/bin:/bin","MARKER":str(root/"marker"),**{"CI_STATUS_"+g.upper().replace('-', '_'):"success" for g in GROUPS}}
            for group in GROUPS:
                for status in ("failure","cancelled","skipped",""):
                    env=dict(base);env["CI_STATUS_"+group.upper().replace('-', '_')]=status
                    r=subprocess.run(["/bin/bash","-c",script],cwd=root,env=env,capture_output=True,timeout=5)
                    self.assertNotEqual(r.returncode,0)
                    self.assertFalse((root/"marker").exists())
            r=subprocess.run(["/bin/bash","-c",script],cwd=root,env=base,capture_output=True,timeout=5)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual((root/"marker").read_text(),"invoked")


if __name__ == "__main__":
    unittest.main()
