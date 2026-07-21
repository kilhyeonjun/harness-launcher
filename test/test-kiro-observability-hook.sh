#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3)}"
"$PYTHON_BIN" - "$ROOT/bin/kiro-observability-hook.py" <<'PY'
import importlib.util
import json
import pathlib
import tempfile
import threading
import time
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("kiro_observer", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp:
    queue = pathlib.Path(tmp)
    spawn_worker = module._spawn_worker
    module._spawn_worker = lambda *_args, **_kwargs: None
    started = time.monotonic()
    rc = module.handle("postToolUse", "kh", json.dumps({"tool_name": "fs_read", "secret": "must-not-persist"}), queue)
    elapsed = time.monotonic() - started
    assert rc == 0
    assert elapsed < 0.1, elapsed
    files = list(queue.glob("*.json"))
    assert len(files) == 1
    persisted = files[0].read_text()
    assert "must-not-persist" not in persisted
    assert "fs_read" in persisted
    assert files[0].stat().st_mode & 0o777 == 0o600
    module._spawn_worker = spawn_worker

with tempfile.TemporaryDirectory() as tmp:
    queue = pathlib.Path(tmp)
    module.MAX_QUEUE_FILES = 2
    popen_calls = []
    held_locks = []
    real_popen = module.subprocess.Popen
    def fake_popen(*args, **kwargs):
        popen_calls.append(args)
        pass_fds = kwargs.get("pass_fds", ())
        if pass_fds:
            held_locks.append(module.os.dup(pass_fds[0]))
        return object()
    module.subprocess.Popen = fake_popen
    for _ in range(5):
        assert module.handle("agentSpawn", "gp", "{}", queue) == 0
    module.subprocess.Popen = real_popen
    assert len(list(queue.glob("*.json"))) <= 2
    assert len(popen_calls) == 1, f"burst spawned {len(popen_calls)} workers"
    for fd in held_locks:
        module.os.close(fd)

with tempfile.TemporaryDirectory() as tmp:
    queue = pathlib.Path(tmp)
    module._spawn_worker = lambda *_args, **_kwargs: None
    module.handle("agentSpawn", "gd", "{}", queue)
    sent = []
    post_json = module._post_json
    module._post_json = lambda payload: sent.append(payload) or True
    assert module.drain(queue) == 0
    module._post_json = post_json
    assert len(sent) == 1
    assert not list(queue.glob("*.json"))

assert module.handle("unknown", "kh", "{}") == 0
assert module.handle("agentSpawn", "bad", "{}") == 0
assert module.main(["hook.py"]) == 0

redirect_hits = []
trap_hits = []
class TrapHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        trap_hits.append(self.path)
        self.send_response(200); self.end_headers()
    def log_message(self, *_args): pass
class RedirectHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        redirect_hits.append(self.path)
        self.send_response(302)
        self.send_header("Location", f"http://127.0.0.1:{trap.server_port}/stolen")
        self.end_headers()
    def log_message(self, *_args): pass

trap = HTTPServer(("127.0.0.1", 0), TrapHandler)
redirect = HTTPServer(("127.0.0.1", 0), RedirectHandler)
for server in (trap, redirect):
    threading.Thread(target=server.serve_forever, daemon=True).start()
module.OTLP_PORT = redirect.server_port
assert module._post_json(module._payload("kiro.session.start", "kh")) is False
for server in (redirect, trap): server.shutdown(); server.server_close()
assert redirect_hits == ["/v1/logs"]
assert trap_hits == [], "loopback collector redirects must never be followed"

prepare = (path.parent / "kiro-home-prepare.sh").read_text()
assert prepare.count(">/dev/null 2>&1 || :") >= 4

print("PASS: Kiro observer is nonblocking, bounded, fail-open, metadata-only, and redirect-safe")
PY
