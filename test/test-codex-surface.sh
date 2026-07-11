#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHON_BIN="${HARNESS_PYTHON_BIN:-$(command -v python3 2>/dev/null || true)}"
for candidate in \
  /opt/homebrew/opt/python@3.13/libexec/bin/python3 \
  /usr/local/opt/python@3.13/libexec/bin/python3 \
  "$PYTHON_BIN" \
  /opt/homebrew/bin/python3 \
  /usr/local/bin/python3; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    PYTHON_BIN="$candidate"
    break
  fi
done
"$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' || {
  echo "FAIL: test-codex-surface requires Python 3.11+" >&2
  exit 1
}
"$PYTHON_BIN" "$ROOT/test/test_codex_surface.py" -v
