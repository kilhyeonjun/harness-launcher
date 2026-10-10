#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SOURCE="$TMP/source"
mkdir -p "$SOURCE"

request='{"source":"'"$SOURCE"'","runtime":"codex","preset":"base","presets":[{"id":"base","label":"Base","model":"gpt-6-sol","effort":"medium"}]}'
output="$(printf '%s' "$request" | HARNESS_PYTHON_BIN="$(command -v python3)" "$ROOT/bin/harness-plan" plan)"

python3 - "$output" <<'PY'
import json, sys
result = json.loads(sys.argv[1])
assert result['can_launch'] is True, result
assert result['args'] == ['codex', 'base', '--passthrough'], result
PY

echo 'PASS: harness-plan emits a side-effect-free JSON plan'
