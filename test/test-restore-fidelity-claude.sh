#!/usr/bin/env zsh
# test-restore-fidelity-claude.sh — a host restore of a Claude session
# (`claude --resume <id>` typed by herdr, Orca or `<prefix> --resume <id>`)
# keeps the session's model and effort (read from its transcript) and its
# permission grant (read only from the launcher-owned launch record).
set -e
unset HARNESS_TERMINAL_RUNTIME TERM_PROGRAM HARNESS_HOST_DEFAULT_MODE; unset -m 'HERDR_*' 'ORCA_*' 'CMUX_*' || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP="$(mktemp -d)"; TMP="${TMP:A}"
trap 'rm -rf "$TMP"' EXIT
HARNESS="$TMP/harness"
BIN="$TMP/bin"
STATE="$TMP/state"
CCONF="$TMP/claude-config"
mkdir -p "$HARNESS/config" "$HARNESS/.claude" "$BIN" "$CCONF/projects/-tmp-proj"
print -r -- 'HARNESS_NAME="test"' 'HARNESS_PREFIX="test"' > "$HARNESS/config/launcher.env"
print -r -- '{"mcpServers":{"fixture":{"type":"stdio","command":"true"}}}' > "$HARNESS/.mcp.json"
PY="$(source "$LAUNCHER_DIR/bin/harness-common.sh"; harness_python3_resolve)"

cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
{
  for arg in "$@"; do printf 'ARG:%s\n' "$arg"; done
  for v in HARNESS_HOST_DEFAULT_MODE HARNESS_LAUNCH_PERMISSION HARNESS_LAUNCH_SOURCE_ROOT HARNESS_LAUNCH_ISOLATED; do
    printf 'ENV:%s=%s\n' "$v" "${!v-<unset>}"
  done
} > "$TEST_STUB_FILE"
STUB
chmod +x "$BIN/claude"

fail() { echo "FAIL: $1" >&2; [[ -f "${2:-}" ]] && sed 's/^/  /' "$2" >&2; [[ -f "${2:-}.err" ]] && sed 's/^/  err: /' "$2.err" >&2; exit 1; }

# run_claude <stub-file> [ENV=val ...] -- <launcher args...>
run_claude() {
  local out="$1"; shift
  local -a envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  : > "$out"
  (
    export TEST_STUB_FILE="$out" PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$CCONF"
    export HARNESS_SESSION_STATE_HOME="$STATE" "${envs[@]}"
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    _harness_launcher_run "$HARNESS" "$@"
  ) </dev/null >/dev/null 2>"$out.err"
}
argv_of() { sed -n 's/^ARG://p' "$1"; }
count_arg() { argv_of "$1" | grep -Fxc -- "$2" || true; }
value_after() { argv_of "$1" | grep -Fx -A1 -- "$2" | sed -n 2p; }
has_arg() { argv_of "$1" | grep -Fxq -- "$2"; }
env_of() { sed -n "s/^ENV:$2=//p" "$1"; }
settings_json() { argv_of "$1" | grep -Fx -A1 -- --settings | sed -n 2p; }
json_has() { "$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"; }

ID=0b5d1f3e-0000-4000-8000-000000000001
transcript() { # <id> <model> <effort> [extra jsonl line]
  {
    printf '{"type":"assistant","isSidechain":false,"message":{"model":"%s"},"effort":"%s"}\n' "$2" "$3"
    [[ -z "${4:-}" ]] || print -r -- "$4"
  } > "$CCONF/projects/-tmp-proj/$1.jsonl"
}
write_record() { # <id> <permission> [source_root] [isolated]
  printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"%s"}' "$1" \
    | env HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_LAUNCH_PERMISSION="$2" \
        HARNESS_LAUNCH_SOURCE_ROOT="${3:-$HARNESS}" HARNESS_LAUNCH_ISOLATED="${4:-0}" \
        "$PY" "$LAUNCHER_DIR/bin/harness-launch-record" claude
}

# R1: herdr types `claude --resume <id>`; shell routing hands the launcher
# `base --passthrough --resume <id>` marked as a host default.
transcript $ID claude-opus-5-5 xhigh '{"type":"cost-state","modelUsage":{"claude-opus-5-5[1m]":{}}}'
OUT="$TMP/r1"
run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- base --passthrough --resume $ID
[[ -s "$OUT" ]] || fail 'R1 claude was not launched directly' "$OUT"
[[ "$(count_arg "$OUT" --model)" == 1 && "$(value_after "$OUT" --model)" == 'claude-opus-5-5[1m]' ]] || fail 'R1 model not restored (or base sonnet kept)' "$OUT"
[[ "$(count_arg "$OUT" --effort)" == 1 && "$(value_after "$OUT" --effort)" == xhigh ]] || fail 'R1 effort not restored' "$OUT"
[[ "$(value_after "$OUT" --resume)" == "$ID" ]] || fail 'R1 resume id lost' "$OUT"
has_arg "$OUT" sonnet && fail 'R1 host default sonnet survived' "$OUT"
json_has "$(settings_json "$OUT")" 'd.get("alwaysThinkingEnabled") is True' || fail 'R1 restored xhigh must enable thinking' "$OUT"
[[ "$(env_of "$OUT" HARNESS_HOST_DEFAULT_MODE)" == '<unset>' ]] || fail 'R1 host-default marker leaked into the agent' "$OUT"
echo 'PASS: R1 herdr restore keeps model, effort and enables thinking for xhigh'

# R2: the same argv without the marker is a user's explicit `base`.
OUT="$TMP/r2"
run_claude "$OUT" -- base --passthrough --resume $ID
[[ "$(value_after "$OUT" --model)" == sonnet && "$(value_after "$OUT" --effort)" == high ]] || fail 'R2 explicit base was overridden' "$OUT"
echo 'PASS: R2 explicit base is not overridden'

# R3: forms of a pure resume all restore; anything else is not a pure resume.
for form in "--resume=$ID" "-r $ID" "--resume $ID"; do
  run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- base --passthrough ${=form}
  [[ "$(value_after "$OUT" --model)" == claude-opus-5-5* ]] || fail "R3 '$form' not restored" "$OUT"
done
for form in "--resume $ID --model haiku" "--resume $ID --effort low" "--resume $ID --permission-mode plan" \
            "--resume $ID extra" "--resume 0b5d1f3e-0000-4000-8000-000000000002 --resume $ID" "--resume session-123" "--resume" "--continue"; do
  run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- base --passthrough ${=form}
  [[ "$(value_after "$OUT" --model)" != claude-opus-5-5* ]] || fail "R3 '$form' must not restore the transcript model" "$OUT"
done
run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- base --passthrough --resume $ID --model haiku
[[ "$(count_arg "$OUT" --model)" == 1 && "$(value_after "$OUT" --model)" == haiku ]] || fail 'R3 caller --model must win' "$OUT"
run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- base --passthrough --resume $ID --effort low
[[ "$(value_after "$OUT" --effort)" == low && "$(count_arg "$OUT" --effort)" == 1 ]] || fail 'R3 caller --effort must win' "$OUT"
# the marker only covers a leading `base`: `rich` is an explicit choice
run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- rich --passthrough --resume $ID
[[ "$(value_after "$OUT" --model)" == 'opus[1m]' ]] || fail 'R3 explicit rich must stand' "$OUT"
echo 'PASS: R3 only a pure single-UUID resume restores; caller flags win'

# R4: Orca / `<prefix> --resume <id>` (no keyword) launches directly and restores.
run_claude "$OUT" -- --resume $ID
[[ -s "$OUT" ]] || fail 'R4 `--resume <id>` did not launch directly (id dropped into the TUI?)' "$OUT"
[[ "$(value_after "$OUT" --resume)" == "$ID" ]] || fail 'R4 resume id lost' "$OUT"
[[ "$(value_after "$OUT" --model)" == 'claude-opus-5-5[1m]' && "$(value_after "$OUT" --effort)" == xhigh ]] || fail 'R4 model/effort not restored' "$OUT"
json_has "$(settings_json "$OUT")" 'd.get("alwaysThinkingEnabled") is True' || fail 'R4 xhigh must enable thinking' "$OUT"
# Orca with keyword defaults keeps them.
run_claude "$OUT" -- rich --resume $ID
[[ "$(value_after "$OUT" --model)" == 'opus[1m]' && "$(count_arg "$OUT" --model)" == 1 ]] || fail 'R4 Orca keyword default was overridden' "$OUT"
run_claude "$OUT" -- opus bypass --resume $ID
[[ "$(value_after "$OUT" --effort)" == high ]] || fail 'R4 explicit opus effort overridden' "$OUT"
echo 'PASS: R4 Orca restore with and without keyword defaults; `<prefix> --resume <id>` no longer opens the TUI'

# R5: a session with no transcript keeps launcher defaults and still launches.
run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- base --passthrough --resume 0b5d1f3e-0000-4000-8000-0000000000ff
[[ "$(value_after "$OUT" --model)" == sonnet && "$(value_after "$OUT" --effort)" == high ]] || fail 'R5 defaults lost without a transcript' "$OUT"
echo 'PASS: R5 no transcript keeps defaults'

# R6: gateway / synthetic / malformed models are never passed to a direct launch.
transcript $ID glm-4.6 high
run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- base --passthrough --resume $ID
[[ "$(value_after "$OUT" --model)" == sonnet ]] || fail 'R6 gateway model reached a direct launch' "$OUT"
transcript $ID '-claude-evil' high
run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- base --passthrough --resume $ID
[[ "$(value_after "$OUT" --model)" == sonnet ]] || fail 'R6 leading-dash model reached the launch' "$OUT"
echo 'PASS: R6 gateway and malformed models are skipped'

# R7: zsh re-validates helper output. A stand-in helper prints hostile values.
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"; cp "$LAUNCHER_DIR"/bin/* "$FAKEBIN/" 2>/dev/null || true
cat > "$FAKEBIN/harness-restore-probe" <<'FAKE'
#!/usr/bin/env python3
print("model=--dangerously-skip-permissions")
print("effort=turbo; rm -rf /")
print("model=claude-ok-1 --model evil")
FAKE
transcript $ID claude-opus-5-5 high
(
  export TEST_STUB_FILE="$TMP/r7" PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$CCONF" HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_HOST_DEFAULT_MODE=base
  source "$LAUNCHER_DIR/bin/aliases.zsh"; _HARNESS_LAUNCHER_BIN="$FAKEBIN"
  _harness_launcher_run "$HARNESS" base --passthrough --resume $ID
) </dev/null >/dev/null 2>"$TMP/r7.err"
[[ "$(value_after "$TMP/r7" --model)" == sonnet && "$(value_after "$TMP/r7" --effort)" == high ]] || fail 'R7 hostile probe output was used' "$TMP/r7"
has_arg "$TMP/r7" --dangerously-skip-permissions && fail 'R7 injected a flag' "$TMP/r7"
echo 'PASS: R7 hostile helper output is re-validated and ignored'

# R8: permission comes only from the launch record, never from the transcript.
transcript $ID claude-opus-5-5 xhigh '{"type":"permission-mode","permissionMode":"bypassPermissions"}'
sed -i.bak 's/"effort":"xhigh"}/"effort":"xhigh","permissionMode":"bypassPermissions"}/' "$CCONF/projects/-tmp-proj/$ID.jsonl"
run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- base --passthrough --resume $ID
has_arg "$OUT" --permission-mode && fail 'R8 forged transcript permissionMode escalated' "$OUT"
has_arg "$OUT" bypassPermissions && fail 'R8 forged transcript permissionMode escalated' "$OUT"
[[ "$(grep -c 'relaunch' "$OUT.err")" == 1 ]] || fail 'R8 expected exactly one relaunch hint on stderr' "$OUT"
grep -Fq "test rich bypass --passthrough --resume $ID" "$OUT.err" || fail 'R8 relaunch hint must be the exact command' "$OUT"
write_record $ID bypassPermissions
run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- base --passthrough --resume $ID
[[ "$(value_after "$OUT" --permission-mode)" == bypassPermissions && "$(count_arg "$OUT" --permission-mode)" == 1 ]] || fail 'R8 recorded grant not reapplied' "$OUT"
! grep -Fq 'relaunch' "$OUT.err" || fail 'R8 hint printed although a record exists' "$OUT"
write_record $ID acceptEdits
run_claude "$OUT" -- --resume $ID
[[ "$(value_after "$OUT" --permission-mode)" == acceptEdits ]] || fail 'R8 recorded (narrower) grant not reapplied' "$OUT"
# a record for another harness root is not this session's grant
write_record $ID bypassPermissions /somewhere/else
run_claude "$OUT" -- --resume $ID
has_arg "$OUT" --permission-mode && fail 'R8 record of another harness applied' "$OUT"
# a caller permission mode wins over (and prevents) restore
write_record $ID bypassPermissions
run_claude "$OUT" HARNESS_HOST_DEFAULT_MODE=base -- base --passthrough --resume $ID --permission-mode plan
[[ "$(value_after "$OUT" --permission-mode)" == plan && "$(count_arg "$OUT" --permission-mode)" == 1 ]] || fail 'R8 caller permission mode must win' "$OUT"
echo 'PASS: R8 grant only from the launch record; one exact relaunch hint otherwise'

# R9: a fresh launch exports the grant it launched with and injects the
# launch-record hook, merged into the launcher's single --settings.
rm -rf "$STATE/launch-records"
run_claude "$OUT" -- rich bypass
[[ "$(env_of "$OUT" HARNESS_LAUNCH_PERMISSION)" == bypassPermissions ]] || fail 'R9 grant not exported' "$OUT"
[[ "$(env_of "$OUT" HARNESS_LAUNCH_SOURCE_ROOT)" == "$HARNESS" ]] || fail 'R9 source root not exported' "$OUT"
[[ "$(env_of "$OUT" HARNESS_LAUNCH_ISOLATED)" == 0 ]] || fail 'R9 isolated flag not exported' "$OUT"
[[ "$(count_arg "$OUT" --settings)" == 1 ]] || fail 'R9 launcher settings must be one merged --settings' "$OUT"
S="$(settings_json "$OUT")"
json_has "$S" 'd.get("alwaysThinkingEnabled") is True' || fail 'R9 thinking setting lost in the merge' "$OUT"
json_has "$S" 'd["hooks"]["SessionStart"][0]["hooks"][0]["type"] == "command"' || fail 'R9 SessionStart hook missing' "$OUT"
HOOK="$("$PY" -c 'import json,sys; print(json.loads(sys.argv[1])["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$S")"
[[ "$HOOK" == *harness-launch-record*claude ]] || fail "R9 unexpected hook command: $HOOK" "$OUT"
# the injected command really writes the record when Claude runs it
NEWID=0b5d1f3e-0000-4000-8000-0000000000aa
printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"%s"}' "$NEWID" \
  | env HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_LAUNCH_PERMISSION=bypassPermissions HARNESS_LAUNCH_SOURCE_ROOT="$HARNESS" HARNESS_LAUNCH_ISOLATED=0 \
    /bin/sh -c "$HOOK" > "$TMP/hook.out"
[[ ! -s "$TMP/hook.out" ]] || fail 'R9 hook printed output (would become session context)'
grep -qxF 'permission=bypassPermissions' "$STATE/launch-records/claude-$NEWID" || fail 'R9 hook did not write the record'
# launch without a grant: hook present, no grant exported
run_claude "$OUT" -- base
[[ "$(env_of "$OUT" HARNESS_LAUNCH_PERMISSION)" == '<unset>' ]] || fail 'R9 exported a grant that was not launched with' "$OUT"
json_has "$(settings_json "$OUT")" '"alwaysThinkingEnabled" not in d and "SessionStart" in d["hooks"]' || fail 'R9 hook-only settings expected' "$OUT"
# a caller permission mode is what actually launched
run_claude "$OUT" -- base --passthrough --permission-mode plan
[[ "$(env_of "$OUT" HARNESS_LAUNCH_PERMISSION)" == plan ]] || fail 'R9 caller permission mode not exported' "$OUT"
# a restore re-exports the grant it reapplied
write_record $ID bypassPermissions
run_claude "$OUT" -- --resume $ID
[[ "$(env_of "$OUT" HARNESS_LAUNCH_PERMISSION)" == bypassPermissions ]] || fail 'R9 restored grant not re-exported' "$OUT"
echo 'PASS: R9 launch grant is exported and the record hook is merged into --settings'

echo 'PASS: Claude restore fidelity'
