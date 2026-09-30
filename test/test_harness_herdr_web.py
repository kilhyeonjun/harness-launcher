#!/usr/bin/env python3
"""Contract for harness-herdr-web (temp dirs, fake tools and a fake server only)."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import threading
import unittest

BIN = Path(__file__).resolve().parents[1] / "bin"
WRAPPER = BIN / "harness-herdr-web"
PIN = "efd017b1a42cc090fb0fec4221e160554b1d407a"
TOKEN = "a" * 64
NO_LOGIN = {"BackendState": "NeedsLogin", "Self": {"UserID": 0}, "User": {}}
LOGGED_IN = {"BackendState": "Stopped", "Self": {"UserID": 7},
             "User": {"7": {"LoginName": "owner@example"}}}

FAKE_HERDR = r'''#!/bin/sh
log() { printf '%s\n' "$*" >> "$FAKE_LOG"; }
case "$1 $2" in
  "plugin config-dir") mkdir -p "$FAKE_CONFIG_DIR"; printf '%s\n' "$FAKE_CONFIG_DIR" ;;
  "plugin list") cat "$FAKE_PLUGINS_JSON" ;;
  "plugin install")
    if grep -q '^HERDR_WEB_TOKEN=[0-9a-f]\{64\}$' "$FAKE_CONFIG_DIR/env" 2>/dev/null; then log "token-before-install"; fi
    log "$*" ;;
  "plugin action") log "$*" ;;
  "status server") printf '{"running": %s}\n' "${FAKE_HERDR_RUNNING:-true}" ;;
  *) log "unexpected $*"; exit 2 ;;
esac
'''
FAKE_BUN = '#!/bin/sh\n[ "$1" = --version ] && printf "%s\\n" "${FAKE_BUN_VERSION:-1.4.2}"\n'
FAKE_GIT = '#!/bin/sh\nprintf "%s\\n" "${FAKE_GIT_HEAD:-' + PIN + '}"\n'
FAKE_TAILSCALE = '#!/bin/sh\n[ "$1" = status ] && cat "$FAKE_TS_JSON"\n'
FAKE_PBCOPY = '#!/bin/sh\nprintf "argc=%s\\n" "$#" > "$FAKE_PBCOPY_LOG"\ncat >> "$FAKE_PBCOPY_LOG"\n'


class FakeServer:
    """In-process /api/health responder; routes map path+query to (status, body)."""

    def __init__(self):
        routes = self.routes = {}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                status, body = routes.get(self.path, (404, {"error": "nope"}))
                data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def healthy(self, authenticated=False, revision=PIN):
        self.routes["/api/health?scope=bridge"] = (
            200, {"ok": True, "auth": {"required": True, "authenticated": authenticated}})
        self.routes["/api/health"] = (
            200, {"ok": True, "auth": {"required": True, "authenticated": authenticated},
                  "web_ui": {"boot_id": "b", "revision": revision}})


def free_port():
    import socket
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class HerdrWebCase(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.home = self.root / "home"
        self.tools = self.root / "tools"
        self.home.mkdir()
        self.tools.mkdir()
        self.dir = self.root / "config" / "devswha.herdr-web-ui"
        self.env_file = self.dir / "env"
        self.dot_env = self.dir / ".env"
        self.log = self.root / "herdr.log"
        self.plugins = self.root / "plugins.json"
        self.ts_json = self.root / "ts.json"
        self.pbcopy_log = self.root / "pbcopy.log"
        self.plugin_root = self.root / "plugin-root"
        self.plugin_root.mkdir()
        self.set_plugins(installed=False)
        self.ts_json.write_text(json.dumps(NO_LOGIN))
        for name, body in (("herdr", FAKE_HERDR), ("bun", FAKE_BUN), ("git", FAKE_GIT),
                           ("tailscale", FAKE_TAILSCALE), ("pbcopy", FAKE_PBCOPY)):
            path = self.tools / name
            path.write_text(body)
            path.chmod(0o755)
        self.server = None
        self.extra = {}

    def serve(self):
        self.server = FakeServer()
        self.addCleanup(self.server.close)
        return self.server

    def set_plugins(self, installed=True):
        plugins = [{"plugin_id": "devswha.herdr-web-ui", "plugin_root": str(self.plugin_root)}] if installed else []
        self.plugins.write_text(json.dumps({"id": "x", "result": {"type": "plugin_list", "plugins": plugins}}))

    def write_env(self, text, mode=0o600, dir_mode=0o700, name="env"):
        self.dir.mkdir(parents=True, exist_ok=True)
        path = self.dir / name
        path.write_bytes(text if isinstance(text, bytes) else text.encode())
        path.chmod(mode)
        self.dir.chmod(dir_mode)
        return path

    def good_env(self, port=None):
        port = port if port is not None else (self.server.port if self.server else free_port())
        return self.write_env(f"HERDR_WEB_TOKEN={TOKEN}\nHOST=127.0.0.1\nHERDR_WEB_AUTO_UPDATE=0\nPORT={port}\n")

    def env(self):
        env = {
            "HOME": str(self.home),
            "PATH": f"{self.tools}:/opt/homebrew/bin:/usr/bin:/bin",
            "FAKE_CONFIG_DIR": str(self.dir),
            "FAKE_LOG": str(self.log),
            "FAKE_PLUGINS_JSON": str(self.plugins),
            "FAKE_TS_JSON": str(self.ts_json),
            "FAKE_PBCOPY_LOG": str(self.pbcopy_log),
            "HARNESS_HERDR_WEB_TAILSCALE_CANDIDATES": str(self.tools / "tailscale"),
            "HARNESS_HERDR_WEB_START_TIMEOUT": "0.5",
        }
        env.update(self.extra)
        return env

    def run_cli(self, *args):
        return subprocess.run([str(WRAPPER), *args], capture_output=True, text=True, env=self.env())

    def entries(self):
        values = {}
        for line in self.env_file.read_text().split("\n"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
        return values

    def mode(self, path):
        return stat.S_IMODE(path.lstat().st_mode)

    def herdr_calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def assert_no_token_leak(self, result, token):
        self.assertNotIn(token, result.stdout)
        self.assertNotIn(token, result.stderr)


class ConfigureTest(HerdrWebCase):
    def test_fresh(self):
        result = self.run_cli("configure")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.mode(self.dir), 0o700)
        self.assertEqual(self.mode(self.env_file), 0o600)
        values = self.entries()
        self.assertRegex(values["HERDR_WEB_TOKEN"], r"^[0-9a-f]{64}$")
        self.assertEqual(values["HOST"], "127.0.0.1")
        self.assertEqual(values["HERDR_WEB_AUTO_UPDATE"], "0")
        self.assertNotIn('"', self.env_file.read_text())
        self.assert_no_token_leak(result, values["HERDR_WEB_TOKEN"])

    def test_preserve_and_repair(self):
        self.write_env("# mine\r\nHERDR_WEB_TOKEN=abc\r\nPORT=7400\r\nHOST=0.0.0.0\r\n"
                       "FOO=bar # x\r\nHERDR_WEB_AUTO_UPDATE=1\r\nHOST=10.0.0.1\r\n")
        result = self.run_cli("configure")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        text = self.env_file.read_text()
        self.assertIn("# mine", text)
        self.assertIn("FOO=bar # x", text)
        self.assertEqual(len(re.findall(r"^HOST=", text, re.M)), 1)
        values = self.entries()
        self.assertEqual(values["PORT"], "7400")
        self.assertEqual(values["HOST"], "127.0.0.1")
        self.assertEqual(values["HERDR_WEB_AUTO_UPDATE"], "0")
        self.assertRegex(values["HERDR_WEB_TOKEN"], r"^[0-9a-f]{64}$")
        self.assertIn("WARN", result.stdout)
        self.assertLess(text.index("HERDR_WEB_TOKEN"), text.index("PORT"))  # replaced in place

    def test_keeps_long_token_and_replaces_quoted_empty(self):
        self.write_env(f"HERDR_WEB_TOKEN={TOKEN}\n")
        self.assertEqual(self.run_cli("configure").returncode, 0)
        self.assertEqual(self.entries()["HERDR_WEB_TOKEN"], TOKEN)
        self.write_env('HERDR_WEB_TOKEN=""\n')
        result = self.run_cli("configure")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertRegex(self.entries()["HERDR_WEB_TOKEN"], r"^[0-9a-f]{64}$")

    def test_mode_repair_without_content_change(self):
        path = self.write_env(f"HERDR_WEB_TOKEN={TOKEN}\nHOST=127.0.0.1\nHERDR_WEB_AUTO_UPDATE=0\n",
                              mode=0o644, dir_mode=0o755)
        before = path.read_text()
        result = self.run_cli("configure")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.mode(path), 0o600)
        self.assertEqual(self.mode(self.dir), 0o700)
        self.assertEqual(path.read_text(), before)

    def test_idempotent(self):
        self.assertEqual(self.run_cli("configure").returncode, 0)
        first = self.env_file.stat()
        self.assertEqual(self.run_cli("configure").returncode, 0)
        second = self.env_file.stat()
        self.assertEqual((first.st_ino, first.st_mtime_ns), (second.st_ino, second.st_mtime_ns))

    def assert_refused(self, result, path=None, content=None):
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL", result.stdout)
        if path is not None:
            self.assertEqual(path.read_text(), content)

    def test_symlinked_env_refused(self):
        self.dir.mkdir(parents=True)
        target = self.root / "elsewhere"
        target.write_text("HOST=0.0.0.0\n")
        self.env_file.symlink_to(target)
        self.assert_refused(self.run_cli("configure"), target, "HOST=0.0.0.0\n")

    def test_symlinked_dir_refused(self):
        real = self.root / "real-dir"
        real.mkdir()
        self.dir.parent.mkdir(parents=True)
        self.dir.symlink_to(real)
        self.assert_refused(self.run_cli("configure"))
        self.assertEqual(list(real.iterdir()), [])

    def test_export_line_refused(self):
        path = self.write_env(f"export HERDR_WEB_TOKEN={TOKEN}\n")
        self.assert_refused(self.run_cli("configure"), path, f"export HERDR_WEB_TOKEN={TOKEN}\n")

    def test_dot_env_managed_key_refused(self):
        for line in ("HOST=0.0.0.0\n", "HERDR_WEB_TOKEN=\n"):
            with self.subTest(line=line):
                self.write_env(line, name=".env")
                self.assert_refused(self.run_cli("configure"))
                self.assertFalse(self.env_file.exists())


class InstallTest(HerdrWebCase):
    def test_ordering_and_start(self):
        server = self.serve()
        server.healthy()
        self.write_env(f"PORT={server.port}\n", dir_mode=0o755)
        self.extra["FAKE_HERDR_RUNNING"] = "true"
        result = self.run_cli("install")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.entries()["PORT"], str(server.port))
        calls = self.herdr_calls()
        self.assertIn("token-before-install", calls)
        install = calls.index("plugin install devswha/herdr-web-ui --ref v0.3.34 --yes")
        self.assertLess(calls.index("token-before-install"), install)
        self.assertGreater(calls.index("plugin action invoke devswha.herdr-web-ui.start"), install)
        self.assert_no_token_leak(result, self.entries()["HERDR_WEB_TOKEN"])

    def test_ref_override_warns(self):
        result = self.run_cli("install", "--ref", "v0.3.40")
        self.assertIn("plugin install devswha/herdr-web-ui --ref v0.3.40 --yes", self.herdr_calls())
        self.assertIn("WARN", result.stdout)

    def test_herdr_not_running_skips_start(self):
        self.extra["FAKE_HERDR_RUNNING"] = "false"
        result = self.run_cli("install")
        self.assertNotIn("plugin action invoke devswha.herdr-web-ui.start", self.herdr_calls())
        self.assertIn("start action", result.stdout)

    def test_refuses_before_installing(self):
        cases = {"old bun": lambda: self.extra.update(FAKE_BUN_VERSION="1.2.18"),
                 "tailscale owner": lambda: self.ts_json.write_text(json.dumps(LOGGED_IN))}
        for name, arrange in cases.items():
            with self.subTest(name):
                self.setUp()
                arrange()
                result = self.run_cli("install")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertFalse(any(c.startswith("plugin install") or c.startswith("plugin action")
                                     for c in self.herdr_calls()), self.herdr_calls())


class CheckTest(HerdrWebCase):
    def check(self):
        return self.run_cli("check")

    def assert_fail(self, needle=None):
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL", result.stdout)
        if needle:
            self.assertIn(needle, result.stdout)
        return result

    def test_all_good_installed_and_running(self):
        self.serve().healthy()
        self.good_env()
        self.set_plugins(installed=True)
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("WARN", result.stdout)
        self.assert_no_token_leak(result, TOKEN)

    def test_effective_token_missing_short_or_overridden(self):
        for text, dot in ((f"HOST=127.0.0.1\n", None), ("HERDR_WEB_TOKEN=abc\nHOST=127.0.0.1\n", None),
                          (f"HERDR_WEB_TOKEN={TOKEN}\nHOST=127.0.0.1\n", "HERDR_WEB_TOKEN=\n")):
            with self.subTest(text=text, dot=dot):
                self.setUp()
                self.write_env(text)
                if dot:
                    self.write_env(dot, name=".env")
                self.assert_fail("HERDR_WEB_TOKEN")

    def test_host_and_auto_update(self):
        for text in (f"HERDR_WEB_TOKEN={TOKEN}\nHOST=localhost\n",
                     f"HERDR_WEB_TOKEN={TOKEN}\n",  # unset HOST falls back to herdr's env
                     f"HERDR_WEB_TOKEN={TOKEN}\nHOST=127.0.0.1\nHERDR_WEB_AUTO_UPDATE=1\n"):
            with self.subTest(text=text):
                self.write_env(text)
                self.assert_fail()

    def test_mode_and_symlink(self):
        self.write_env(f"HERDR_WEB_TOKEN={TOKEN}\nHOST=127.0.0.1\n", mode=0o644)
        self.assert_fail("0600")
        self.env_file.unlink()
        target = self.root / "t"
        target.write_text(f"HERDR_WEB_TOKEN={TOKEN}\nHOST=127.0.0.1\n")
        self.env_file.symlink_to(target)
        self.assert_fail("symlink")

    def test_tailscale_owner_fails_for_path_and_app_cli(self):
        self.good_env()
        self.ts_json.write_text(json.dumps(LOGGED_IN))
        self.assert_fail("Tailscale")
        app = self.root / "Tailscale.app" / "Contents" / "MacOS" / "Tailscale"
        app.parent.mkdir(parents=True)
        app.write_text(FAKE_TAILSCALE)
        app.chmod(0o755)
        self.extra["HARNESS_HERDR_WEB_TAILSCALE_CANDIDATES"] = f"{self.root / 'missing'}:{app}"
        self.assert_fail("Tailscale")

    def test_tailscale_no_login_or_missing_cli_ok(self):
        self.good_env()
        self.assertEqual(self.check().returncode, 0)
        self.extra["HARNESS_HERDR_WEB_TAILSCALE_CANDIDATES"] = str(self.root / "missing")
        self.assertEqual(self.check().returncode, 0)

    def test_runtime_probe_fails_open_server(self):
        self.serve().healthy(authenticated=True)
        self.good_env()
        self.set_plugins(installed=True)
        self.assert_fail("unauthenticated")

    def test_runtime_probe_fails_without_auth(self):
        server = self.serve()
        server.routes["/api/health?scope=bridge"] = (200, {"ok": True})
        self.good_env()
        self.set_plugins(installed=True)
        self.assert_fail("cannot verify")

    def test_runtime_probe_timeout_fails(self):
        import socket
        silent = socket.socket()
        self.addCleanup(silent.close)
        silent.bind(("127.0.0.1", 0))
        silent.listen(1)  # accepts at the kernel, never answers
        self.good_env(port=silent.getsockname()[1])
        self.set_plugins(installed=True)
        self.extra["HARNESS_HERDR_WEB_PROBE_TIMEOUT"] = "0.3"
        self.assert_fail("cannot verify")

    def test_warnings_exit_zero(self):
        self.good_env(port=free_port())  # not running
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("not installed", result.stdout)
        self.set_plugins(installed=True)
        self.extra["FAKE_GIT_HEAD"] = "0" * 40
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("unreviewed build", result.stdout)
        self.assertIn("not running", result.stdout)

    def test_revision_drift_warns_and_502_skips(self):
        server = self.serve()
        server.healthy(revision="f" * 40)
        self.good_env()
        self.set_plugins(installed=True)
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("in-app release", result.stdout)
        server.routes["/api/health"] = (502, {"error": "herdr unreachable"})
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("in-app release", result.stdout)


class UpstreamGrammarTest(HerdrWebCase):
    """Parse exactly like upstream's readEnvFile (split on \\n, JS trim)."""

    def test_lone_cr_does_not_end_a_line(self):
        self.write_env(b"# c\rHERDR_WEB_TOKEN=" + TOKEN.encode() + b"\nHOST=127.0.0.1\n")
        result = self.run_cli("check")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("HERDR_WEB_TOKEN", result.stdout)
        self.assertEqual(self.run_cli("configure").returncode, 0)
        self.assertNotIn("FAIL effective HERDR_WEB_TOKEN", self.run_cli("check").stdout)

    def test_bom_on_dot_env_is_trimmed_like_js(self):
        self.write_env("\ufeffHOST=0.0.0.0\n", name=".env")
        result = self.run_cli("configure")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(".env sets HOST", result.stdout)

    def test_invalid_utf8_and_odd_json_never_traceback(self):
        self.write_env(b"HERDR_WEB_TOKEN=" + TOKEN.encode() + b"\xff\nHOST=127.0.0.1\n")
        self.ts_json.write_text("[]")
        result = self.run_cli("check")
        self.assertNotIn("Traceback", result.stdout + result.stderr)


class TailscaleCandidatesTest(HerdrWebCase):
    def test_any_cli_with_a_login_fails(self):
        self.good_env()
        other_json = self.root / "ts2.json"
        other_json.write_text(json.dumps(LOGGED_IN))
        second = self.root / "bin2" / "tailscale"
        second.parent.mkdir()
        second.write_text(f'#!/bin/sh\n[ "$1" = status ] && cat "{other_json}"\n')
        second.chmod(0o755)
        self.extra["HARNESS_HERDR_WEB_TAILSCALE_CANDIDATES"] = f"{self.tools / 'tailscale'}:{second}"
        result = self.run_cli("check")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Tailscale", result.stdout)


class TokenTest(HerdrWebCase):
    def test_copy_uses_stdin_only(self):
        self.good_env()
        result = self.run_cli("token", "--copy")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_no_token_leak(result, TOKEN)
        log = self.pbcopy_log.read_text()
        self.assertTrue(log.startswith("argc=0\n"), log)
        self.assertIn(TOKEN, log)

    def test_without_copy_never_prints(self):
        self.good_env()
        result = self.run_cli("token")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_token_leak(result, TOKEN)


if __name__ == "__main__":
    unittest.main()
