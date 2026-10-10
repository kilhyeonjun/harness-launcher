#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"${HARNESS_PYTHON_BIN:-$(command -v python3)}" -I "$ROOT/test/test_codex_history_native.py" -v
