#!/usr/bin/env bash
# Public launcher boundary: never import producer code from a checkout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/harness-common.sh"
PYTHON_BIN="$(harness_python3_resolve)"
exec "$PYTHON_BIN" -I "$SCRIPT_DIR/harness_release_client.py" "$@"
