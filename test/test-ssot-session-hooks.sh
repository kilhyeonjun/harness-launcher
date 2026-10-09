#!/usr/bin/env bash
# Catches missing opt-in registration, lost Claude settings and env-only opt-in.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/kh/config"
source "$ROOT/bin/harness-common.sh"
printf 'HARNESS_PREFIX=kh\n' > "$TMP/kh/config/launcher.env"
printf '{"enabled":true}\n' > "$TMP/kh/config/ssot-session-hooks.json"
settings="$(harness_claude_launch_settings "$ROOT/bin" "$TMP/kh" true default '')"
python3 - "$settings" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data['alwaysThinkingEnabled'] is True
assert data['hooks']['SessionStart']
for event in ('UserPromptSubmit', 'Stop'):
    handlers = data['hooks'].get(event, [])
    assert len(handlers) == 1, f'{event} collector not registered'
    assert 'harness-session-hook' in handlers[0]['hooks'][0]['command']
    assert '--runtime claude' in handlers[0]['hooks'][0]['command']
PY
printf 'HARNESS_PREFIX=gp\n' > "$TMP/kh/config/launcher.env"
rm "$TMP/kh/config/ssot-session-hooks.json"
settings="$(HARNESS_SSOT_SESSION_HOOKS=1 harness_claude_launch_settings "$ROOT/bin" "$TMP/kh" false default '')"
python3 - "$settings" <<'PY'
import json, sys
assert set(json.loads(sys.argv[1])['hooks']) == {'SessionStart'}
PY
printf 'PASS: SSOT hooks require literal per-profile opt-in and preserve Claude launch settings\n'
