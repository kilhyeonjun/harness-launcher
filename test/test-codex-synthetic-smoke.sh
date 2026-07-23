#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/bin/codex-synthetic-smoke.py"

python3 - "$HELPER" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import re
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("codex_synthetic_smoke", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Response:
    status = 200
    def read(self, _size): return b""

class Connection:
    calls = []
    def __init__(self, host, port, timeout):
        self.calls.append((host, port, timeout))
    def request(self, method, path, body, headers):
        self.calls.append((method, path, body, headers))
    def getresponse(self): return Response()
    def close(self): pass

module.http.client.HTTPConnection = Connection
module.secrets.token_hex = lambda _size: "a" * 64
module.time.time_ns = lambda: 123456789
output = io.StringIO()
with contextlib.redirect_stdout(output):
    assert module.main(["alpha", "http://127.0.0.1:4318"]) == 0

assert Connection.calls[0] == ("127.0.0.1", 4318, 0.75)
method, request_path, raw, headers = Connection.calls[1]
assert (method, request_path, headers) == ("POST", "/v1/logs", {"Content-Type": "application/json"})
payload = json.loads(raw)
encoded = json.dumps(payload, sort_keys=True)
assert "codex.synthetic_smoke" in encoded
assert "codex.instrumentation_verified" in encoded
assert '"obs.profile", "value": {"stringValue": "alpha"}' in encoded
assert '"obs.runtime", "value": {"stringValue": "codex"}' in encoded
assert '"service.name", "value": {"stringValue": "harness-agent"}' in encoded
assert '"session.id", "value": {"stringValue": "' + "a" * 64 + '"}' in encoded
records = payload["resourceLogs"][0]["scopeLogs"][0]["logRecords"]
assert len(records) == 2
assert records[0]["body"]["stringValue"] == "codex.synthetic_smoke"
assert records[1]["body"]["stringValue"] == "codex.instrumentation_verified"
assert all(item["key"] != "session.id" for item in records[1]["attributes"])
assert "/Users/" not in encoded and "prompt" not in encoded and "account" not in encoded
assert re.fullmatch(r"codex.synthetic_smoke profile=alpha marker=a{64} delivery=accepted\n", output.getvalue())

class Offline:
    def __init__(self, *_args, **_kwargs): pass
    def request(self, *_args, **_kwargs): raise TimeoutError
    def close(self): pass

module.http.client.HTTPConnection = Offline
output = io.StringIO()
with contextlib.redirect_stdout(output):
    assert module.main(["gamma", "http://127.0.0.1:4318"]) == 1
assert "delivery=unconfirmed" in output.getvalue()

class Redirect(Response): status = 302
class RedirectConnection(Connection):
    calls = []
    def getresponse(self): return Redirect()
module.http.client.HTTPConnection = RedirectConnection
os.environ["HTTP_PROXY"] = "http://proxy.invalid:8080"
output = io.StringIO()
with contextlib.redirect_stdout(output):
    assert module.main(["beta", "http://127.0.0.1:4318"]) == 1
assert RedirectConnection.calls[0] == ("127.0.0.1", 4318, 0.75)
assert len([call for call in RedirectConnection.calls if call and call[0] == "POST"]) == 1
with contextlib.redirect_stderr(io.StringIO()):
    assert module.main(["bad/profile", "http://127.0.0.1:4318"]) == 2
    assert module.main(["beta", "http://example.com:4318"]) == 2
PY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/harness/config/.local" "$TMP/bin"
printf 'HARNESS_NAME=fixture\nHARNESS_PREFIX=beta\n' > "$TMP/harness/config/launcher.env"
printf 'HARNESS_OBSERVABILITY_ENABLED=1\nHARNESS_OTLP_HTTP_ENDPOINT=http://127.0.0.1:4318\n' > "$TMP/harness/config/.local/observability.env"
cat > "$TMP/bin/codex-synthetic-smoke.py" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$SMOKE_ARGS"
EOF
chmod +x "$TMP/bin/codex-synthetic-smoke.py"
SMOKE_ARGS="$TMP/args" zsh -c '
  source "$1/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$2/bin"
  _harness_launcher_run "$2/harness" codex-smoke
' _ "$ROOT" "$TMP"
[[ "$(cat "$TMP/args")" == "beta http://127.0.0.1:4318" ]]

printf 'HARNESS_OBSERVABILITY_ENABLED=0\nHARNESS_OTLP_HTTP_ENDPOINT=http://127.0.0.1:4318\n' > "$TMP/harness/config/.local/observability.env"
if SMOKE_ARGS="$TMP/disabled-args" zsh -c '
  source "$1/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$2/bin"
  _harness_launcher_run "$2/harness" codex-smoke
' _ "$ROOT" "$TMP" >/dev/null 2>&1; then
  echo 'FAIL: disabled observability must reject codex-smoke' >&2
  exit 1
fi
[[ ! -e "$TMP/disabled-args" ]]

printf 'PASS: bounded metadata-only Codex synthetic smoke is profile-exact and reports transport failure\n'
