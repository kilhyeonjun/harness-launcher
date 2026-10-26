#!/usr/bin/env bash
set -euo pipefail

ROOT="$1"
PREFIX="$2"
SHARE="$PREFIX/share/harness-launcher"
mkdir -p "$SHARE" "$PREFIX/bin"
for source in "$ROOT"/bin/*; do
  [[ -f "$source" ]] || continue
  cp "$source" "$SHARE/"
done
# Consumer fixtures must never consult the developer account's storage policy.
# Keep the real resolver and inject its documented home argument in this test
# copy only; production has no environment switch or alternate config path.
cp "$SHARE/verification_storage.py" "$SHARE/verification_storage_fixture_policy.py"
mkdir -p "$SHARE/.fixture-policy-home"
cat > "$SHARE/verification_storage.py" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import verification_storage_fixture_policy as _policy
from verification_storage_fixture_policy import VerificationStorageError, nested_lifetimes_settled
_configured_root = _policy.configured_root

def configured_root(home=None):
    return _configured_root(home=home if home is not None else Path(__file__).resolve().parent / '.fixture-policy-home')

_policy.configured_root = configured_root
if __name__ == '__main__':
    raise SystemExit(_policy.main())
PY
chmod 755 "$SHARE"/*
for file in harness-auto harness-codex harness-exec harness-headless harness-herdr-web harness-paseo harness-profile; do
  ln -s "../share/harness-launcher/$file" "$PREFIX/bin/$file"
done
