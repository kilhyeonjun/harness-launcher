#!/usr/bin/env bash
# gh keeps ONE global active account, but the three harnesses legitimately expect
# different GitHub users. Deriving GH_TOKEN per harness removes that arbitration:
# GH_TOKEN takes precedence over gh's stored credentials, so the active account
# stops deciding whether a command succeeds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bin/harness-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/harness/config/.local"

# Fake gh: prints a per-user token, fails for an unknown user.
cat > "$TMP/bin/gh" <<'SH'
#!/bin/bash
if [ "$1 $2" = "auth token" ]; then
  case "${4:-}" in
    known-user) echo "gho_TESTTOKEN_known"; exit 0 ;;
    *) echo "no token for ${4:-}" >&2; exit 1 ;;
  esac
fi
echo "unexpected fake gh args: $*" >&2
exit 1
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

reset_env() { unset GH_TOKEN HARNESS_GH_USER; }

# 1. .local config is the primary source (gp/gd layout)
reset_env
printf 'github_user: known-user\n' > "$TMP/harness/config/.local/config.yaml"
harness_gh_token_load "$TMP/harness"
[[ "$HARNESS_GH_USER" == known-user ]]
[[ "$GH_TOKEN" == gho_TESTTOKEN_known ]]

# 2. tracked config is the fallback (kh layout)
reset_env
rm -f "$TMP/harness/config/.local/config.yaml"
printf 'github_user: known-user\n' > "$TMP/harness/config/config.yaml"
harness_gh_token_load "$TMP/harness"
[[ "$GH_TOKEN" == gho_TESTTOKEN_known ]]

# 3. .local wins over the tracked file
reset_env
printf 'github_user: known-user\n' > "$TMP/harness/config/.local/config.yaml"
printf 'github_user: other-user\n' > "$TMP/harness/config/config.yaml"
harness_gh_token_load "$TMP/harness"
[[ "$HARNESS_GH_USER" == known-user ]]

# 4. Fail open: no config at all leaves GH_TOKEN untouched, so the hook stays the
#    backstop instead of every gh command breaking.
reset_env
rm -f "$TMP/harness/config/.local/config.yaml" "$TMP/harness/config/config.yaml"
set +e
harness_gh_token_load "$TMP/harness"; rc=$?
set -e
[[ "$rc" -eq 1 ]]
[[ -z "${GH_TOKEN:-}" ]]

# 5. Fail open: a declared user with no stored token must not export an empty value.
#    An empty GH_TOKEN would override the stored credentials with nothing.
reset_env
printf 'github_user: unknown-user\n' > "$TMP/harness/config/.local/config.yaml"
set +e
harness_gh_token_load "$TMP/harness"; rc=$?
set -e
[[ "$rc" -eq 1 ]]
[[ -z "${GH_TOKEN:-}" ]]

# 6. Fail open when gh itself is absent
reset_env
printf 'github_user: known-user\n' > "$TMP/harness/config/.local/config.yaml"
set +e
PATH="/usr/bin:/bin" harness_gh_token_load "$TMP/harness"; rc=$?
set -e
[[ "$rc" -eq 1 ]]
[[ -z "${GH_TOKEN:-}" ]]

# 7. A malformed github_user must be rejected rather than passed to gh
reset_env
printf 'github_user: bad user; rm -rf /\n' > "$TMP/harness/config/.local/config.yaml"
set +e
harness_gh_token_load "$TMP/harness"; rc=$?
set -e
[[ "$rc" -eq 1 ]]
[[ -z "${GH_TOKEN:-}" ]]

# 8. The token value must never be printed, even on success
reset_env
printf 'github_user: known-user\n' > "$TMP/harness/config/.local/config.yaml"
out="$(harness_gh_token_load "$TMP/harness" 2>&1)"
[[ "$out" != *gho_TESTTOKEN_known* ]]

printf 'PASS: per-harness GH_TOKEN derivation is strict, redacted, and fail-open\n'
