#!/usr/bin/env zsh
# test-orca-env.sh — Orca terminal environment handling in the launcher:
# CODEX_HOME sanitization (L1) and checkup ORCA_* scrub (L5).
set -e
unset CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SURFACE_ID

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HARNESS="$TMP/harness"
STATE="$TMP/state"
mkdir -p "$HARNESS/config" "$TMP/bin"
git -C "$HARNESS" init -q -b main
git -C "$HARNESS" config user.email test@example.invalid
git -C "$HARNESS" config user.name test
print -r -- 'HARNESS_NAME="test"' 'HARNESS_PREFIX="test"' > "$HARNESS/config/launcher.env"
print -r -- '.harness/' > "$HARNESS/.gitignore"
git -C "$HARNESS" add -A && git -C "$HARNESS" commit -qm initial

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'CODEX_HOME=%s\nORCA_CODEX_HOME=%s\nORCA_TERMINAL_HANDLE=%s\nORCA_OTHER=%s\n' \
  "${CODEX_HOME-unset}" "${ORCA_CODEX_HOME-unset}" "${ORCA_TERMINAL_HANDLE-unset}" "${ORCA_OTHER-unset}" >> "$STUB_LOG"
STUB
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'CODEX_HOME=%s\nORCA_CODEX_HOME=%s\n' "${CODEX_HOME-unset}" "${ORCA_CODEX_HOME-unset}" >> "$STUB_LOG"
STUB
chmod +x "$TMP/bin/claude" "$TMP/bin/codex"

fail() { echo "FAIL: $*" >&2; exit 1; }
run() { # <log> <env assignments...> -- <args...>
  local log="$1"; shift
  local -a envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  (
    export PATH="$TMP/bin:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" STUB_LOG="$log" "${envs[@]}"
    source "$ROOT/bin/aliases.zsh"
    _harness_launcher_run "$HARNESS" "$@"
  ) >/dev/null 2>"${log}.err" || true
}

# (a) Orca-equal CODEX_HOME: Claude sees neither variable.
run "$TMP/a.log" CODEX_HOME=/orca/codex-home ORCA_CODEX_HOME=/orca/codex-home -- base
grep -qx 'CODEX_HOME=unset' "$TMP/a.log" || fail 'Orca-owned CODEX_HOME must be unset for Claude'
grep -qx 'ORCA_CODEX_HOME=unset' "$TMP/a.log" || fail 'ORCA_CODEX_HOME must be unset for Claude'

# (b) A user-set CODEX_HOME that differs is preserved.
run "$TMP/b.log" CODEX_HOME=/user/codex ORCA_CODEX_HOME=/orca/codex-home -- base
grep -qx 'CODEX_HOME=/user/codex' "$TMP/b.log" || fail 'user CODEX_HOME must be preserved'
grep -qx 'ORCA_CODEX_HOME=/orca/codex-home' "$TMP/b.log" || fail 'ORCA_CODEX_HOME must be preserved when differing'

# Empty ORCA_CODEX_HOME never triggers.
run "$TMP/b2.log" CODEX_HOME= ORCA_CODEX_HOME= -- base
grep -qx 'CODEX_HOME=' "$TMP/b2.log" || fail 'empty ORCA_CODEX_HOME must not trigger sanitization'

# L5: checkup prompt-audit child has no ORCA_* variables.
run "$TMP/e.log" ORCA_TERMINAL_HANDLE=term_1 ORCA_OTHER=x -- checkup prompt-audit
[[ -s "$TMP/e.log" ]] || { cat "$TMP/e.log.err" >&2; fail 'checkup stub was not invoked'; }
grep -qx 'ORCA_TERMINAL_HANDLE=unset' "$TMP/e.log" || fail 'checkup child must not see ORCA_TERMINAL_HANDLE'
grep -qx 'ORCA_OTHER=unset' "$TMP/e.log" || fail 'checkup child must not see ORCA_*'

# The remaining cases run the real codex-home-prepare.sh, which requires the
# macOS /usr/bin/lockf kernel lock (see run-all.sh). Hosted images without it
# skip only these cases; L1 and L5 above still run.
if [[ ! -x /usr/bin/lockf || "${HARNESS_TEST_FORCE_NO_LOCKF:-0}" == 1 ]]; then
  echo 'SKIP: codex prepare cases (/usr/bin/lockf unavailable)'
  echo 'PASS: test-orca-env'
  exit 0
fi

# (c) The Codex path still exports the harness-owned home.
run "$TMP/c.log" CODEX_HOME=/orca/codex-home ORCA_CODEX_HOME=/orca/codex-home -- codex
grep -qx "CODEX_HOME=$HARNESS/.harness/codex" "$TMP/c.log" || { cat "$TMP/c.log" "$TMP/c.log.err" >&2; fail 'codex path must export harness CODEX_HOME'; }
grep -qx 'ORCA_CODEX_HOME=unset' "$TMP/c.log" || fail 'codex path must not see ORCA_CODEX_HOME'

# L3 wiring: HARNESS_ORCA_AGENT_HOOKS from launcher.env reaches codex-home-prepare;
# an ambient value without the launcher.env opt-in does not.
hooks_json="$HARNESS/.harness/codex/hooks.json"
run "$TMP/f.log" HARNESS_ORCA_AGENT_HOOKS=1 -- codex
grep -q 'agent-hooks/codex-hook.sh' "$hooks_json" 2>/dev/null && fail 'ambient HARNESS_ORCA_AGENT_HOOKS must not enable hooks'
print -r -- 'HARNESS_ORCA_AGENT_HOOKS=1' >> "$HARNESS/config/launcher.env"
run "$TMP/g.log" -- codex
grep -q 'agent-hooks/codex-hook.sh' "$hooks_json" || fail 'launcher.env opt-in must generate the Orca Codex hook'
sed -i '' '/HARNESS_ORCA_AGENT_HOOKS/d' "$HARNESS/config/launcher.env"
run "$TMP/h.log" HARNESS_ORCA_AGENT_HOOKS=1 -- codex
grep -q 'agent-hooks/codex-hook.sh' "$hooks_json" && fail 'removing the opt-in must regenerate hooks without the Orca entry'

echo 'PASS: test-orca-env'
