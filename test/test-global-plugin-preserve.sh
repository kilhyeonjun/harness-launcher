#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bin/harness-common.sh"
PYTHON_BIN="$(harness_python3_resolve)"
"$PYTHON_BIN" -B "$ROOT/test/test_global_plugin_guard.py"
