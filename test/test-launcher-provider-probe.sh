#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cleanup() {
  [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true
  [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
TEST_HARNESS="$TEST_TEMP/fake-harness"
TEST_BIN="$TEST_TEMP/bin"
REAL_NODE_PATH="$(command -v node || true)"
[[ -n "$REAL_NODE_PATH" ]] || {
  echo 'FAIL: node not found in PATH'
  exit 1
}
mkdir -p "$TEST_HARNESS/config/.local" "$TEST_BIN"

cat > "$TEST_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF

PORT_FILE="$TEST_TEMP/http-port"
PORT_FILE="$PORT_FILE" python3 - <<'PY' > /dev/null 2>&1 &
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'not found')
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ok')

    def log_message(self, format, *args):
        pass

server = HTTPServer(('127.0.0.1', 0), Handler)
with open(os.environ['PORT_FILE'], 'w', encoding='utf-8') as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
HTTP_PID=$!

PORT_FILE="$PORT_FILE" python3 - <<'PY'
import os
from pathlib import Path
import time

port_file = Path(os.environ['PORT_FILE'])
for _ in range(50):
    if port_file.exists() and port_file.read_text().strip():
        raise SystemExit(0)
    time.sleep(0.1)
raise SystemExit(1)
PY

HTTP_PORT="$(cat "$PORT_FILE")"
HTTP_URL="http://127.0.0.1:$HTTP_PORT"

cat > "$TEST_HARNESS/config/.local/kiro-gateway.env" <<EOF
KIRO_GATEWAY_URL="$HTTP_URL"
KIRO_GATEWAY_API_KEY="kiro-test-key"
EOF

cat > "$TEST_HARNESS/config/.local/codex-gateway.env" <<EOF
CODEX_GATEWAY_URL="$HTTP_URL"
CODEX_GATEWAY_API_KEY="codex-test-key"
EOF

cat > "$TEST_BIN/claude" <<'CEOF'
#!/usr/bin/env bash
{ echo "EXEC:claude"; echo "ARGS:$*"; } >> "${TEST_STUB_FILE:-/dev/null}"
exit 0
CEOF
chmod +x "$TEST_BIN/claude"

cat > "$TEST_BIN/node" <<EOF
#!/usr/bin/env bash
exec "$REAL_NODE_PATH" "\$@"
EOF
chmod +x "$TEST_BIN/node"

OUTPUT_FILE="$TEST_TEMP/output.txt"
PATH="$TEST_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
HARNESS_CODEX_BIN="$TEST_TEMP/no-codex" \
HARNESS_DIR="$TEST_HARNESS" \
HARNESS_NAME="test harness" \
bash "$LAUNCHER_DIR/bin/launcher.sh" <<< $'9\nq\n' > "$OUTPUT_FILE" 2>&1 || true

grep -q 'Provider' "$OUTPUT_FILE" || {
  echo 'FAIL: expected provider menu when gateways are configured (HTTP 404 /health)'
  cat "$OUTPUT_FILE"
  exit 1
}

grep -q 'Kiro gateway' "$OUTPUT_FILE" || {
  echo 'FAIL: expected Kiro gateway listed on HTTP 404 /health'
  cat "$OUTPUT_FILE"
  exit 1
}

grep -q 'Codex gateway' "$OUTPUT_FILE" || {
  echo 'FAIL: expected Codex gateway listed on HTTP 404 /health'
  cat "$OUTPUT_FILE"
  exit 1
}

grep -q '(1-' "$OUTPUT_FILE" || {
  echo 'FAIL: invalid provider input should reprompt with guidance'
  cat "$OUTPUT_FILE"
  exit 1
}

kill "$HTTP_PID" 2>/dev/null || true
wait "$HTTP_PID" 2>/dev/null || true
unset HTTP_PID

UNUSED_PORT="$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(('127.0.0.1', 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
UNREACHABLE_URL="http://127.0.0.1:$UNUSED_PORT"

cat > "$TEST_HARNESS/config/.local/kiro-gateway.env" <<EOF
KIRO_GATEWAY_URL="$UNREACHABLE_URL"
KIRO_GATEWAY_API_KEY="kiro-test-key"
EOF

cat > "$TEST_HARNESS/config/.local/codex-gateway.env" <<EOF
CODEX_GATEWAY_URL="$UNREACHABLE_URL"
CODEX_GATEWAY_API_KEY="codex-test-key"
EOF

NEGATIVE_OUTPUT_FILE="$TEST_TEMP/output-negative.txt"
NEGATIVE_STUB="$TEST_TEMP/negative.stub"
rm -f "$TEST_HARNESS/.harness/launcher-last"
# Select the unreachable Codex gateway (3) → New session → Base → Start.
# The launch gate must re-probe, fail closed, and never exec claude.
TEST_STUB_FILE="$NEGATIVE_STUB" \
PATH="$TEST_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
HARNESS_CODEX_BIN="$TEST_TEMP/no-codex" \
HARNESS_DIR="$TEST_HARNESS" \
HARNESS_NAME="test harness" \
bash "$LAUNCHER_DIR/bin/launcher.sh" <<< $'3\n1\n2\n1\n' > "$NEGATIVE_OUTPUT_FILE" 2>&1 || true

grep -q 'Provider' "$NEGATIVE_OUTPUT_FILE" || {
  echo 'FAIL: provider menu must still be shown when gateways are unreachable (marks show state)'
  cat "$NEGATIVE_OUTPUT_FILE"
  exit 1
}
grep -q '연결할 수 없습니다' "$NEGATIVE_OUTPUT_FILE" || {
  echo 'FAIL: selecting an unreachable gateway should fail closed with a clear error'
  cat "$NEGATIVE_OUTPUT_FILE"
  exit 1
}
if [[ -f "$NEGATIVE_STUB" ]] && grep -q '^EXEC:claude' "$NEGATIVE_STUB"; then
  echo 'FAIL: unreachable gateway must not launch claude'
  cat "$NEGATIVE_STUB"
  exit 1
fi

echo 'PASS: provider menu lists configured gateways; unreachable gateway fails closed at launch'
