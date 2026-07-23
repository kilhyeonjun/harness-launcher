#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPARE="$ROOT/bin/codex-home-prepare.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
HARNESS="$TMP/harness"
mkdir -p "$HOME_DIR" "$HARNESS/config/.local"
printf '# fixture\n' > "$HARNESS/CLAUDE.md"
cat > "$HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="fixture"
HARNESS_PREFIX="team-one"
EOF
cat > "$HARNESS/config/.local/observability.env" <<'EOF'
HARNESS_OBSERVABILITY_ENABLED=1
HARNESS_OTLP_HTTP_ENDPOINT=http://127.0.0.1:4318
EOF
chmod 600 "$HARNESS/config/.local/observability.env"

HOME="$HOME_DIR" \
HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$TMP/no-marketplace" \
  "$PREPARE" "$HARNESS"

CONFIG="$HARNESS/.harness/codex/config.toml"
grep -q '^\[otel\]$' "$CONFIG" || { echo 'FAIL: missing Codex OTel config'; exit 1; }
grep -q '^environment = "team-one"$' "$CONFIG" || { echo 'FAIL: Codex metrics environment must equal harness profile'; exit 1; }
grep -q '^log_user_prompt = false$' "$CONFIG" || { echo 'FAIL: prompt logging must remain disabled'; exit 1; }
grep -q '^exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/logs", protocol = "binary", headers = {} } }$' "$CONFIG" || { echo 'FAIL: metadata-only Codex logs must use the loopback collector'; exit 1; }
grep -q '"obs.profile" = "team-one"' "$CONFIG" || { echo 'FAIL: Codex span profile missing'; exit 1; }
grep -q '"environment": expected_profile' "$ROOT/bin/codex-surface-warm.py" || { echo 'FAIL: warm validator must require the current profile environment'; exit 1; }

echo 'PASS: Codex OTel config carries the harness profile for metrics and spans'
