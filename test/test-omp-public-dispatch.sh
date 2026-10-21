#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bin/harness-common.sh"
PYTHON_BIN="$(harness_python3_resolve)"
if [[ "$#" -eq 0 ]]; then
  exec "$PYTHON_BIN" -I -B "$ROOT/test/omp_public_dispatch_capsule_runner.py" \
    --baseline-repository "$ROOT" \
    --manifest "$ROOT/test/fixtures/omp-public-dispatch-5faf-manifest.json" \
    --shell "${BASH:-/bin/bash}"
fi
exec "$PYTHON_BIN" -I -B "$ROOT/test/test_omp_public_dispatch.py" "$@"
