#!/usr/bin/env bash
# Focused durable native Codex history storage contract.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${HARNESS_PYTHON_BIN:-$(command -v python3)}"

"$PYTHON_BIN" "$ROOT/test/test_codex_history.py" -v
