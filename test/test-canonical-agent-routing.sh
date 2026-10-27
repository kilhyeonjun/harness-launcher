#!/usr/bin/env zsh
# Canonical agent entry and selected TUI dispatch, with external executables
# replaced at their boundary. Run with zsh; no model CLI or network is needed.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; TMP="${TMP:A}"
trap 'rm -rf "$TMP"' EXIT
export ROOT TMP HOME="$TMP/home" HARNESS_PROFILE_HOME="$TMP/registry"
export HARNESS="$TMP/canonical checkout" LOG="$TMP/dispatch.log"
mkdir -p "$HOME" "$HARNESS/config" "$HARNESS/nested" "$HARNESS_PROFILE_HOME/profiles"
printf 'HARNESS_NAME="routing test"\nHARNESS_PREFIX="route"\nHARNESS_SESSION_ISOLATION_DEFAULT="0"\n' > "$HARNESS/config/launcher.env"
printf '%s\n' "$HARNESS" > "$HARNESS_PROFILE_HOME/profiles/route"
fail() { print -u2 -r -- "FAIL: $*"; exit 1; }

# Install the real transport but make loading aliases/projection observable.
# Explicit --no-isolated must refuse before either is reached, including OMP's
# immutable-runtime dispatch (which precedes normal alias loading).
bash "$ROOT/test/lib/install-runtime-fixture.sh" "$ROOT" "$TMP/prefix"
BOUND="$TMP/prefix/share/harness-launcher"
cat > "$BOUND/aliases.zsh" <<'ALIASES'
print reached-aliases >> "$LOG"
_harness_launcher_run() { print reached-launch >> "$LOG"; }
ALIASES
cat > "$BOUND/harness_omp_projection.py" <<'PROJECTION'
import os
with open(os.environ['LOG'], 'a') as stream:
    stream.write('reached-projection\n')
raise SystemExit(91)
PROJECTION
for cwd in "$HARNESS" "$HARNESS/nested"; do
  for runtime in claude codex omp; do
    : > "$LOG"
    rc=0
    HARNESS_SESSION_ISOLATION=1 HARNESS_SESSION_ROOT="$HARNESS" \
      "$TMP/prefix/bin/harness-exec" "$HARNESS" --cwd "$cwd" --no-isolated "$runtime" resume 'session with spaces' > "$TMP/out" 2> "$TMP/err" || rc=$?
    [[ "$rc" == 2 ]] || fail "explicit $runtime legacy entry returned $rc"
    [[ "$(<"$TMP/err")" == *canonical_agent_refused* && "$(<"$TMP/err")" == *'--isolated '* ]] || fail "$runtime missing refusal and alternative"
    [[ ! -s "$LOG" ]] || fail "$runtime reached preparation before refusal"
  done
done
# Exercise implicit nested cwd resolution at the transport boundary too.
rc=0
(cd "$HARNESS/nested"; "$TMP/prefix/bin/harness-exec" "$HARNESS" --no-isolated codex base) > "$TMP/out" 2> "$TMP/err" || rc=$?
[[ "$rc" == 2 && ! -s "$LOG" ]] || fail 'implicit nested cwd escaped early refusal'
# A missing registry must retain the transport route, not ban by launcher.env.
: > "$LOG"
HARNESS_PROFILE_HOME="$TMP/missing-registry" "$TMP/prefix/bin/harness-exec" "$HARNESS" --cwd "$HARNESS/nested" --no-isolated codex base
[[ "$(<"$LOG")" == $'reached-aliases\nreached-launch' ]] || fail 'missing registry did not fail open'
print 'PASS: explicit canonical legacy entry refuses before aliases and OMP probes; missing registry fails open'

# Actual launcher classification must refuse legacy continuations even when
# the profile's isolation default is off; no native launch may happen.
cat > "$TMP/resume.zsh" <<'RESUME'
set -eu
unset HARNESS_SESSION_ISOLATION HARNESS_SESSION_ROOT HARNESS_SESSION_ID
unset HARNESS_TERMINAL_RUNTIME TERM_PROGRAM CLAUDECODE CODEX_THREAD_ID
unset -m 'HERDR_*' 'ORCA_*' 'CMUX_*' || true
source "$ROOT/bin/aliases.zsh"
_harness_launcher_run_session() { print native >> "$LOG"; }
_harness_launcher_run_codex_cli() { print native >> "$LOG"; }
_harness_launcher_codex_history_select() { print history >> "$LOG"; return 1; }
for cwd in "$HARNESS" "$HARNESS/nested"; do
  for runtime in claude codex; do
    : > "$LOG"
    args=(--resume 11111111-1111-4111-8111-111111111111)
    [[ "$runtime" != codex ]] || args=(codex --passthrough resume 11111111-1111-4111-8111-111111111111)
    rc=0
    _harness_launcher_run "$HARNESS" --cwd "$cwd" "${args[@]}" > "$TMP/resume.out" 2> "$TMP/resume.err" || rc=$?
    [[ "$rc" == 2 && ! -s "$LOG" && "$(<"$TMP/resume.err")" == *canonical_agent_refused* ]] || { print -u2 -r -- "FAIL: $runtime legacy resume ($rc): $(<"$TMP/resume.err")"; exit 1; }
  done
done
RESUME
/bin/zsh "$TMP/resume.zsh"
print 'PASS: canonical Claude and Codex legacy continuations refuse in nested directories'

# Load the actual final-selection assembly functions without starting an
# interactive menu. Selection values below are what collect_* hands off.
# Only external settings/history effects are stubbed, never the refusal guard
# or isolated argv construction under test.
cat > "$TMP/selected.bash" <<'SELECTED'
set -eo pipefail
source "$ROOT/bin/harness-common.sh"
: > "$TMP/selected-functions.bash"
inside=0
while IFS= read -r line; do
  case "$line" in 'launch_claude() {'|'launch_codex() {'|'launch_omp() {') inside=1 ;; esac
  if [ "$inside" = 1 ]; then
    printf '%s\n' "$line" >> "$TMP/selected-functions.bash"
    [ "$line" != '}' ] || inside=0
  fi
done < "$ROOT/bin/launcher.sh"
source "$TMP/selected-functions.bash"
harness_export_local_env() { return 0; }
harness_gh_token_load() { return 0; }
harness_observability_load() { return 1; }
harness_agent_usage_export_discard() { return 0; }
harness_launch_source_root() { printf '%s\n' "$HARNESS"; }
history_save() { :; }
HARNESS_DIR="$HARNESS" HARNESS_RUN_DIR="$HARNESS/nested" LAUNCHER_BIN_DIR="$TMP/tui-bin"
CHOICE_PROVIDER=direct CHOICE_HAPPY=0 CHOICE_MODE=base CHOICE_SESSION=new
CHOICE_PERM=default CHOICE_CHROME=0 CHOICE_MCP_SURFACE=light
CHOICE_CODEX_PROFILE=fast CHOICE_CODEX_SURFACE=work CHOICE_CODEX_SAFETY=never CHOICE_CODEX_CONTEXT=1m
OMP_HANDOFF="$TMP/omp-handoff"
case "$1" in
  claude) CHOICE_MODE=custom CHOICE_C_MODEL=chosen-model CHOICE_C_EFFORT=high; launch_claude ;;
  codex) CHOICE_SESSION=continue; launch_codex ;;
  codex-happy) CHOICE_HAPPY=1 CHOICE_SESSION=fork CHOICE_CODEX_SAFETY=bypass; launch_codex ;;
  claude-happy) CHOICE_HAPPY=1 CHOICE_MODE=custom CHOICE_C_MODEL=chosen-model CHOICE_C_EFFORT=high; launch_claude ;;
  omp) CHOICE_MODE='mode with spaces'; launch_omp ;;
esac
SELECTED
mkdir -p "$TMP/tui-bin"
cat > "$TMP/tui-bin/harness-exec" <<'EXEC'
#!/bin/sh
printf '%s\n' "$@" > "$LOG"
printf '%s\n' "${HARNESS_CODEX_CONTEXT:-}" > "$TMP/context"
EXEC
chmod 755 "$TMP/tui-bin/harness-exec"
for runtime in claude codex codex-happy omp; do
  : > "$LOG"
  bash "$TMP/selected.bash" "$runtime"
  actual=("${(@f)$(<"$LOG")}")
  expected=("$HARNESS" --cwd "$HARNESS/nested" --isolated)
  case "$runtime" in
    claude) expected+=(claude light --passthrough --model chosen-model --effort high --exclude-dynamic-system-prompt-sections) ;;
    codex) expected+=(codex fast 1m work never continue)
      [[ "$(<"$TMP/context")" == 1m ]] || fail 'Codex selection lost context' ;;
    codex-happy) expected+=(codex fast 1m happy work bypass fork) ;;
    omp) expected+=(omp --model-mode 'mode with spaces') ;;
  esac
  [[ "${(j:|:)actual}" == "${(j:|:)expected}" ]] || fail "$runtime selected TUI argv changed: ${(j:|:)actual}"
done
: > "$LOG"
rc=0
bash "$TMP/selected.bash" claude-happy > "$TMP/happy.out" 2> "$TMP/happy.err" || rc=$?
[[ "$rc" == 2 && ! -s "$LOG" && "$(<"$TMP/happy.err")" == *canonical_agent_refused* ]] || fail 'Claude Happy canonical selection did not refuse'
[[ ! -e "$TMP/omp-handoff" ]] || fail 'canonical OMP used native handoff instead of isolation'
print 'PASS: actual selected Claude/Codex/OMP TUI functions dispatch isolated argv with selected options'
