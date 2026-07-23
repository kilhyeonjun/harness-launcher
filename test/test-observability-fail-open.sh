#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bin/harness-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/config/.local"
printf 'HARNESS_PREFIX=alpha\n' > "$TMP/config/launcher.env"

check_disabled() {
  local value="$1"
  printf '%s\n' "$value" > "$TMP/config/.local/observability.env"
  HARNESS_OBSERVABILITY_ENABLED=sentinel
  set +e
  harness_observability_load "$TMP" >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 1 ]]
  [[ "$HARNESS_OBSERVABILITY_ACTIVE" -eq 0 ]]
  [[ "$HARNESS_OBSERVABILITY_ENABLED" == sentinel ]]
}

check_disabled 'UNKNOWN_KEY=1'
check_disabled 'HARNESS_OBSERVABILITY_ENABLED=bogus'
check_disabled 'HARNESS_OBSERVABILITY_ENABLED=1
HARNESS_OTLP_HTTP_ENDPOINT=http://example.com:4318'
check_disabled 'not-an-assignment'

cat > "$TMP/config/.local/observability.env" <<'EOF'
HARNESS_OBSERVABILITY_ENABLED=1
HARNESS_OTLP_HTTP_ENDPOINT=http://127.0.0.1:4318
EOF
harness_observability_load "$TMP"
[[ "$HARNESS_OBSERVABILITY_ACTIVE" -eq 1 ]]
[[ "$HARNESS_OBSERVABILITY_PROFILE" == alpha ]]
[[ "$HARNESS_OTLP_HTTP_ENDPOINT" == "http://127.0.0.1:4318" ]]
[[ "$HARNESS_OBSERVABILITY_ENABLED" == sentinel ]]

printf 'PASS: optional observability config is strict but fail-open\n'
