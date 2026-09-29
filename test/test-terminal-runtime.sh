#!/usr/bin/env bash
# test-terminal-runtime.sh — harness_terminal_runtime, harness_terminal_scrub_env
# and harness_terminal_announce_cwd from bin/harness-common.sh.
#
# Every case runs in a fresh `env -i` child of /bin/bash (3.2 on macOS) and of
# /bin/zsh, each sourcing bin/harness-common.sh. Both shells must produce the
# same runtime value and the same surviving variables, so each shell is checked
# against one expected result. The two shells of a case run in parallel.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$ROOT/bin/harness-common.sh"
SHELLS=(/bin/bash "${ZSH_BIN:-/bin/zsh}")
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for sh_bin in "${SHELLS[@]}"; do
  [[ -x "$sh_bin" ]] || { echo "FAIL: shell under test not found: $sh_bin"; exit 1; }
done

# The OSC 7 expectations spell TMP out by hand; a TMPDIR with reserved bytes
# would need the encoder under test to compute them.
case "$TMP" in
  *[!A-Za-z0-9._/\ -]*)
    echo "FAIL: TMPDIR contains bytes this test does not pre-encode: $TMP"
    exit 1
    ;;
esac
ENC_TMP="$(printf '%s' "$TMP" | sed 's/ /%20/g')"

SOCK="$TMP/herdr.sock"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SOCK"
[[ -S "$SOCK" ]] || { echo "FAIL: socket fixture was not created"; exit 1; }
NOT_SOCK="$TMP/not-a-socket"
: > "$NOT_SOCK"
ABSENT_SOCK="$TMP/absent.sock"

failures=0
checks=0

fail() {
  failures=$((failures + 1))
  printf 'FAIL: %s\n' "$1"
  shift
  [[ $# -eq 0 ]] || printf '%s\n' "$@"
}

# Print "ok" for a case only when it added no failure.
finish() {
  if [[ "$failures" -eq "$1" ]]; then
    printf 'ok: %s\n' "$2"
  fi
}

# run_shells SCRIPT ARG [ENV=value ...]
# Runs SCRIPT in a fresh `env -i` child of each shell in SHELLS, in parallel,
# and leaves each child's combined stdout/stderr in RESULT_0 and RESULT_1. The
# script sees $1 = library path, $2 = a scratch dir private to that shell,
# $3 = env filter, $4 = ARG.
ENV_FILTER='^([A-Za-z0-9_]*(CMUX|ORCA|HERDR)[A-Za-z0-9_]*|TERM_PROGRAM|CODEX_HOME|HARNESS_TERMINAL_RUNTIME)='
RESULT_0=""
RESULT_1=""
run_shells() {
  local script="$1" arg="$2" i
  shift 2
  for i in 0 1; do
    mkdir -p "$TMP/scratch.$i"
    env -i HOME="$HOME" PATH="$PATH" TERM=xterm-256color LANG=en_US.UTF-8 "$@" \
      "${SHELLS[$i]}" -c "$script" _ "$COMMON" "$TMP/scratch.$i" "$ENV_FILTER" "$arg" \
      >"$TMP/scratch.$i/result" 2>&1 </dev/null &
  done
  wait
  RESULT_0="$(cat "$TMP/scratch.0/result")"
  RESULT_1="$(cat "$TMP/scratch.1/result")"
}

# expect_results LABEL EXPECTED — both shells must have produced EXPECTED.
expect_results() {
  local label="$1" expected="$2" i actual
  for i in 0 1; do
    checks=$((checks + 1))
    if [[ "$i" -eq 0 ]]; then actual="$RESULT_0"; else actual="$RESULT_1"; fi
    if [[ "$actual" != "$expected" ]]; then
      fail "$label (${SHELLS[$i]})" "--- expected" "$expected" "--- actual" "$actual"
    fi
  done
}

# dump lists the variables this feature owns, one NAME=value line each, sorted.
SNAPSHOT='
. "$1"
dump() {
  env | grep -E "$3" | LC_ALL=C sort
}
runtime="$(harness_terminal_runtime)"
harness_terminal_scrub_env >"$2/scrub.out" 2>&1
scrub_rc=$?
first="$(dump "$1" "$2" "$3")"
harness_terminal_scrub_env
second="$(dump "$1" "$2" "$3")"
if [ "$first" = "$second" ]; then again=same; else again=changed; fi
printf "runtime=%s\nscrub_rc=%s\nscrub_output=[%s]\nrescrub=%s\n%s\n" \
  "$runtime" "$scrub_rc" "$(cat "$2/scrub.out")" "$again" "$first"
'

# check_scrub LABEL EXPECTED_RUNTIME EXPECTED_ENV_LINES [ENV=value ...]
# EXPECTED_ENV_LINES lists every surviving variable that matches ENV_FILTER.
check_scrub() {
  local label="$1" want_rt="$2" want_lines="$3" before="$failures"
  shift 3
  run_shells "$SNAPSHOT" "" "$@"
  expect_results "$label" "runtime=$want_rt
scrub_rc=0
scrub_output=[]
rescrub=same
$(printf '%s\n' "$want_lines" | LC_ALL=C sort)"
  finish "$before" "$label"
}

# --- Runtime detection and scrub (brief cases 1-9) ----------------------------

check_scrub "case 1: herdr beats Orca" herdr \
  "HARNESS_TERMINAL_RUNTIME=herdr
HERDR_ENV=1
HERDR_PANE_ID=w1:p1
HERDR_SOCKET_PATH=$SOCK" \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$SOCK" \
  ORCA_TERMINAL_HANDLE=term_x ORCA_PANE_KEY=k TERM_PROGRAM=Orca

check_scrub "case 2: herdr beats cmux" herdr \
  "HARNESS_TERMINAL_RUNTIME=herdr
HERDR_ENV=1
HERDR_PANE_ID=w1:p1
HERDR_SOCKET_PATH=$SOCK" \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$SOCK" \
  CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c CMUX_SOCKET_PATH=/tmp/x

check_scrub "case 3: Orca beats cmux" orca \
  "HARNESS_TERMINAL_RUNTIME=orca
ORCA_TERMINAL_HANDLE=term_x" \
  ORCA_TERMINAL_HANDLE=term_x CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c

check_scrub "case 4: TERM_PROGRAM=Orca alone is Orca" orca \
  "HARNESS_TERMINAL_RUNTIME=orca
TERM_PROGRAM=Orca" \
  TERM_PROGRAM=Orca

check_scrub "case 5: cmux with a stale HERDR_PANE_ID" cmux \
  "HARNESS_TERMINAL_RUNTIME=cmux
CMUX_WORKSPACE_ID=a
CMUX_TAB_ID=b
CMUX_SURFACE_ID=c" \
  CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c HERDR_PANE_ID=w1:p9

check_scrub "case 5b: cmux with a full stale HERDR set (socket gone)" cmux \
  "HARNESS_TERMINAL_RUNTIME=cmux
CMUX_WORKSPACE_ID=a
CMUX_TAB_ID=b
CMUX_SURFACE_ID=c" \
  CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p9 HERDR_SOCKET_PATH="$ABSENT_SOCK"

check_scrub "case 6: nothing set" plain \
  "HARNESS_TERMINAL_RUNTIME=plain"

check_scrub "case 7: herdr variables but the socket path is a regular file" plain \
  "HARNESS_TERMINAL_RUNTIME=plain" \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$NOT_SOCK"

check_scrub "case 8: equal CODEX_HOME and ORCA_CODEX_HOME are both unset" orca \
  "HARNESS_TERMINAL_RUNTIME=orca
ORCA_TERMINAL_HANDLE=t" \
  ORCA_CODEX_HOME=/o CODEX_HOME=/o ORCA_TERMINAL_HANDLE=t

check_scrub "case 9: differing CODEX_HOME survives (no Orca marker)" plain \
  "HARNESS_TERMINAL_RUNTIME=plain
CODEX_HOME=/u" \
  ORCA_CODEX_HOME=/o CODEX_HOME=/u

check_scrub "case 9b: differing CODEX_HOME and ORCA_CODEX_HOME survive under Orca" orca \
  "HARNESS_TERMINAL_RUNTIME=orca
ORCA_TERMINAL_HANDLE=t
ORCA_CODEX_HOME=/o
CODEX_HOME=/u" \
  ORCA_CODEX_HOME=/o CODEX_HOME=/u ORCA_TERMINAL_HANDLE=t

# --- Additional edges ---------------------------------------------------------

check_scrub "HERDR_ENV=0 is not herdr" plain \
  "HARNESS_TERMINAL_RUNTIME=plain" \
  HERDR_ENV=0 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$SOCK"

check_scrub "empty HERDR_PANE_ID is not herdr" plain \
  "HARNESS_TERMINAL_RUNTIME=plain" \
  HERDR_ENV=1 HERDR_PANE_ID= HERDR_SOCKET_PATH="$SOCK"

check_scrub "missing HERDR_SOCKET_PATH is not herdr" plain \
  "HARNESS_TERMINAL_RUNTIME=plain" \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1

check_scrub "two of three cmux variables are not cmux" plain \
  "HARNESS_TERMINAL_RUNTIME=plain" \
  CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b

check_scrub "empty ORCA_TERMINAL_HANDLE is not an Orca marker" cmux \
  "HARNESS_TERMINAL_RUNTIME=cmux
CMUX_WORKSPACE_ID=a
CMUX_TAB_ID=b
CMUX_SURFACE_ID=c" \
  ORCA_TERMINAL_HANDLE= CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c

check_scrub "Orca handle removes a stale HERDR set" orca \
  "HARNESS_TERMINAL_RUNTIME=orca
ORCA_TERMINAL_HANDLE=t" \
  ORCA_TERMINAL_HANDLE=t HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$ABSENT_SOCK"

check_scrub "other TERM_PROGRAM values are kept" plain \
  "HARNESS_TERMINAL_RUNTIME=plain
TERM_PROGRAM=Apple_Terminal" \
  TERM_PROGRAM=Apple_Terminal

check_scrub "TERM_PROGRAM=orca (lowercase) is neither Orca nor removed" plain \
  "HARNESS_TERMINAL_RUNTIME=plain
TERM_PROGRAM=orca" \
  TERM_PROGRAM=orca

check_scrub "names outside the CMUX_/ORCA_/HERDR_ prefixes are kept" plain \
  "HARNESS_TERMINAL_RUNTIME=plain
HARNESS_ORCA_AGENT_HOOKS=1
HARNESS_HERDR_AGENT_HOOKS=1
CODEX_CMUX_TITLE_REQUEST_FILE=/r
NOT_CMUX_A=1
CMUXX=1
ORCA=1
ORCAS=1
HERDR=1
HERDRX=1
CMUX=1" \
  HARNESS_ORCA_AGENT_HOOKS=1 HARNESS_HERDR_AGENT_HOOKS=1 \
  CODEX_CMUX_TITLE_REQUEST_FILE=/r NOT_CMUX_A=1 CMUXX=1 ORCA=1 ORCAS=1 \
  HERDR=1 HERDRX=1 CMUX=1

check_scrub "an inherited HARNESS_TERMINAL_RUNTIME is recomputed" plain \
  "HARNESS_TERMINAL_RUNTIME=plain" \
  HARNESS_TERMINAL_RUNTIME=herdr

# --- Values that contain newlines --------------------------------------------

MULTILINE='
. "$1"
harness_terminal_scrub_env
scrub_rc=$?
printf "rc=%s\n" "$scrub_rc"
printf "runtime=%s\n" "$HARNESS_TERMINAL_RUNTIME"
printf "ORCA_MULTI=[%s]\n" "${ORCA_MULTI-UNSET}"
printf "CMUX_MULTI=[%s]\n" "${CMUX_MULTI-UNSET}"
printf "HERDR_MULTI=[%s]\n" "${HERDR_MULTI-UNSET}"
printf "CMUX_INJECT=[%s]\n" "${CMUX_INJECT-UNSET}"
printf "ORCA_TERMINAL_HANDLE=[%s]\n" "${ORCA_TERMINAL_HANDLE-UNSET}"
'
before="$failures"
run_shells "$MULTILINE" "" \
  ORCA_TERMINAL_HANDLE=t \
  ORCA_MULTI=$'a\nCMUX_INJECT=1' \
  CMUX_MULTI=$'b\nORCA_TERMINAL_HANDLE=zzz' \
  HERDR_MULTI=$'c\nORCA_MULTI=evil'
expect_results "multi-line values do not confuse the scrub" "rc=0
runtime=orca
ORCA_MULTI=[a
CMUX_INJECT=1]
CMUX_MULTI=[UNSET]
HERDR_MULTI=[UNSET]
CMUX_INJECT=[UNSET]
ORCA_TERMINAL_HANDLE=[t]"
finish "$before" "multi-line values do not confuse the scrub"

# --- harness_terminal_scrub_env RUNTIME argument -----------------------------

# The launcher passes its launch runtime (plain without a terminal) as the
# argument. A valid value replaces detection; anything else detects as before.
SNAPSHOT_ARG='
. "$1"
harness_terminal_scrub_env "$4"
scrub_rc=$?
printf "scrub_rc=%s\nruntime=%s\n" "$scrub_rc" "$HARNESS_TERMINAL_RUNTIME"
env | grep -E "$3" | LC_ALL=C sort
'

# check_scrub_arg LABEL ARG EXPECTED_RUNTIME EXPECTED_ENV_LINES [ENV=value ...]
# EXPECTED_ENV_LINES lists every surviving variable that matches ENV_FILTER,
# HARNESS_TERMINAL_RUNTIME included.
check_scrub_arg() {
  local label="$1" arg="$2" want_rt="$3" want_lines="$4" before="$failures"
  shift 4
  run_shells "$SNAPSHOT_ARG" "$arg" "$@"
  expect_results "$label" "scrub_rc=0
runtime=$want_rt
$(printf '%s\n' "$want_lines" | LC_ALL=C sort)"
  finish "$before" "$label"
}

ALL_MARKERS=(HERDR_ENV=1 HERDR_PANE_ID=w1:p1 "HERDR_SOCKET_PATH=$SOCK"
  ORCA_TERMINAL_HANDLE=t ORCA_PANE_KEY=k TERM_PROGRAM=Orca
  CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c CMUX_SOCKET_PATH=/s)

check_scrub_arg "argument plain removes every runtime's variables" plain plain \
  "HARNESS_TERMINAL_RUNTIME=plain" "${ALL_MARKERS[@]}"
check_scrub_arg "argument herdr keeps only HERDR_* (markers say herdr)" herdr herdr \
  "HARNESS_TERMINAL_RUNTIME=herdr
HERDR_ENV=1
HERDR_PANE_ID=w1:p1
HERDR_SOCKET_PATH=$SOCK" "${ALL_MARKERS[@]}"
check_scrub_arg "argument orca overrides herdr markers" orca orca \
  "HARNESS_TERMINAL_RUNTIME=orca
ORCA_PANE_KEY=k
ORCA_TERMINAL_HANDLE=t
TERM_PROGRAM=Orca" "${ALL_MARKERS[@]}"
check_scrub_arg "argument cmux overrides herdr and Orca markers" cmux cmux \
  "HARNESS_TERMINAL_RUNTIME=cmux
CMUX_SOCKET_PATH=/s
CMUX_SURFACE_ID=c
CMUX_TAB_ID=b
CMUX_WORKSPACE_ID=a" "${ALL_MARKERS[@]}"
check_scrub_arg "argument orca with cmux-only markers removes CMUX_*" orca orca \
  "HARNESS_TERMINAL_RUNTIME=orca" CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c
check_scrub_arg "argument plain still applies the L1 rule" plain plain \
  "HARNESS_TERMINAL_RUNTIME=plain" ORCA_CODEX_HOME=/o CODEX_HOME=/o
check_scrub_arg "an unknown argument detects from the markers" bogus cmux \
  "HARNESS_TERMINAL_RUNTIME=cmux
CMUX_WORKSPACE_ID=a
CMUX_TAB_ID=b
CMUX_SURFACE_ID=c" CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c
check_scrub_arg "an empty argument detects from the markers" "" orca \
  "HARNESS_TERMINAL_RUNTIME=orca
ORCA_TERMINAL_HANDLE=t" ORCA_TERMINAL_HANDLE=t CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c
check_scrub_arg "an argument with different case is not a runtime" PLAIN cmux \
  "HARNESS_TERMINAL_RUNTIME=cmux
CMUX_WORKSPACE_ID=a
CMUX_TAB_ID=b
CMUX_SURFACE_ID=c" CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c

# --- harness_terminal_launch_runtime ------------------------------------------

# Without a terminal (run_shells detaches stdin and stdout) the runtime is
# plain whatever the markers say.
LAUNCH_RT='
. "$1"
harness_terminal_launch_runtime
printf "rc=%s\n" "$?"
harness_terminal_launch_runtime rt
printf "assigned=%s rc=%s\n" "$rt" "$?"
'
before="$failures"
run_shells "$LAUNCH_RT" "" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 "HERDR_SOCKET_PATH=$SOCK" \
  ORCA_TERMINAL_HANDLE=t CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c
expect_results "launch runtime without a terminal is plain despite markers" \
  $'plain\nrc=0\nassigned=plain rc=0'
finish "$before" "launch runtime without a terminal is plain despite markers"

# With a terminal, run each shell on a pty (stdin and stdout are terminals)
# through run-bounded.py: a hard time limit, a silent pty stdin, and a
# transcript with CRLF normalized to LF.
BOUNDED="$ROOT/test/lib/run-bounded.py"
# run_shells_tty SCRIPT ARG [ENV=value ...]: like run_shells, on a pty.
run_shells_tty() {
  local script="$1" arg="$2" i
  shift 2
  for i in 0 1; do
    mkdir -p "$TMP/scratch.$i"
    python3 "$BOUNDED" tty 60 "$TMP/scratch.$i/result" \
      env -i HOME="$HOME" PATH="$PATH" TERM=xterm-256color LANG=en_US.UTF-8 "$@" \
      "${SHELLS[$i]}" -c "$script" _ "$COMMON" "$TMP/scratch.$i" "$ENV_FILTER" "$arg" \
      </dev/null &
  done
  wait
  RESULT_0="$(cat "$TMP/scratch.0/result")"
  RESULT_1="$(cat "$TMP/scratch.1/result")"
}

# check_launch_tty LABEL EXPECTED_RUNTIME [ENV=value ...]
check_launch_tty() {
  local label="$1" want="$2" before="$failures"
  shift 2
  run_shells_tty "$LAUNCH_RT" "" "$@"
  expect_results "$label" "$want"$'\nrc=0\nassigned='"$want"' rc=0'
  finish "$before" "$label"
}
check_launch_tty "launch runtime on a terminal: herdr" herdr \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1 "HERDR_SOCKET_PATH=$SOCK" ORCA_TERMINAL_HANDLE=t CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c
check_launch_tty "launch runtime on a terminal: orca" orca \
  ORCA_TERMINAL_HANDLE=t CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c
check_launch_tty "launch runtime on a terminal: cmux" cmux \
  CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c
check_launch_tty "launch runtime on a terminal: plain" plain NOT_A_MARKER=1

# Either stream not being a terminal is enough for plain, and the value can only
# be captured through the variable-name form: `$(...)` makes stdout a pipe.
PARTIAL='
. "$1"
harness_terminal_launch_runtime | cat
printf "captured=%s\n" "$(harness_terminal_launch_runtime)"
harness_terminal_launch_runtime rt
printf "assigned=%s\n" "$rt"
</dev/null harness_terminal_launch_runtime rt
printf "stdin-detached=%s\n" "$rt"
harness_terminal_launch_runtime "not a name"
printf "bad-name-rc=%s\n" "$?"
harness_terminal_launch_runtime _htlr_rt
printf "own-name-rc=%s\n" "$?"
'
before="$failures"
run_shells_tty "$PARTIAL" "" ORCA_TERMINAL_HANDLE=t
expect_results "launch runtime: stdout pipe, capture, detached stdin, bad and own names" \
  $'plain\ncaptured=plain\nassigned=orca\nstdin-detached=plain\nbad-name-rc=2\nown-name-rc=2'
finish "$before" "launch runtime: stdout pipe, capture, detached stdin, bad and own names"

# --- harness_terminal_runtime contract ---------------------------------------

# Exactly one line and exit 0, with PATH pointing nowhere: only builtins and the
# socket test may run, so detection cannot shell out.
NO_PATH='
. "$1"
PATH=/nonexistent
harness_terminal_runtime
printf "rc=%s\n" "$?"
'
# check_runtime_no_path LABEL EXPECTED_RUNTIME [ENV=value ...]
check_runtime_no_path() {
  local label="$1" want="$2" before="$failures"
  shift 2
  run_shells "$NO_PATH" "" "$@"
  expect_results "$label" "$want"$'\nrc=0'
  finish "$before" "$label"
}
check_runtime_no_path "runtime herdr without external commands" herdr \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$SOCK" ORCA_TERMINAL_HANDLE=t
check_runtime_no_path "runtime orca (handle) without external commands" orca \
  ORCA_TERMINAL_HANDLE=t CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c
check_runtime_no_path "runtime orca (TERM_PROGRAM) without external commands" orca \
  TERM_PROGRAM=Orca
check_runtime_no_path "runtime cmux without external commands" cmux \
  CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c
check_runtime_no_path "runtime plain without external commands" plain

# harness_terminal_runtime must not export, set or unset anything.
UNCHANGED='
. "$1"
env | grep -v "^_=" | LC_ALL=C sort > "$2/env.before"
harness_terminal_runtime >/dev/null
env | grep -v "^_=" | LC_ALL=C sort > "$2/env.after"
if cmp -s "$2/env.before" "$2/env.after"; then echo unchanged; else echo changed; fi
'
before="$failures"
run_shells "$UNCHANGED" "" \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$SOCK" \
  ORCA_TERMINAL_HANDLE=t CMUX_WORKSPACE_ID=a CMUX_TAB_ID=b CMUX_SURFACE_ID=c
expect_results "runtime does not change the environment" "unchanged"
finish "$before" "runtime does not change the environment"

# The functions must survive a caller that runs with `set -eu -o pipefail`.
STRICT='
. "$1"
set -eu -o pipefail
runtime="$(harness_terminal_runtime)"
harness_terminal_scrub_env
harness_terminal_announce_cwd "$4"
printf "strict-ok %s %s\n" "$runtime" "$HARNESS_TERMINAL_RUNTIME"
'
before="$failures"
run_shells "$STRICT" "$TMP" \
  HARNESS_TERMINAL_TTY="$TMP/strict.tty" \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$SOCK" ORCA_TERMINAL_HANDLE=t
expect_results "functions run under set -eu -o pipefail" "strict-ok herdr herdr"
finish "$before" "functions run under set -eu -o pipefail"

# --- harness_terminal_announce_cwd (brief cases 10-12) -----------------------

ANNOUNCE='
. "$1"
out="$(harness_terminal_announce_cwd "$4" 2>&1)"
printf "rc=%s out=[%s]\n" "$?" "$out"
'
ANNOUNCE_NO_ARG='
. "$1"
out="$(harness_terminal_announce_cwd 2>&1)"
printf "rc=%s out=[%s]\n" "$?" "$out"
'

# check_announce LABEL RUNTIME DIR EXPECTED_CAPTURE [SCRIPT] [PREFIX] [EXTRA_ENV]
# RUNTIME empty leaves HARNESS_TERMINAL_RUNTIME unset. Each shell gets its own
# capture file, seeded with PREFIX, so a passing case also proves append
# semantics. EXTRA_ENV is one word-split string of ENV=value assignments.
check_announce() {
  local label="$1" runtime="$2" dir="$3" want="$4"
  local script="${5:-$ANNOUNCE}" prefix="${6:-}" extra="${7:-}"
  local before="$failures" i runtime_env=""
  [[ -z "$runtime" ]] || runtime_env="HARNESS_TERMINAL_RUNTIME=$runtime"
  for i in 0 1; do
    mkdir -p "$TMP/scratch.$i"
    printf '%s' "$prefix" > "$TMP/scratch.$i/capture"
  done
  # The capture path differs per shell, so run each shell by hand in parallel.
  for i in 0 1; do
    # shellcheck disable=SC2086 # runtime_env and extra are intentionally split
    env -i HOME="$HOME" PATH="$PATH" TERM=xterm-256color LANG=en_US.UTF-8 \
      HARNESS_TERMINAL_TTY="$TMP/scratch.$i/capture" $runtime_env $extra \
      "${SHELLS[$i]}" -c "$script" _ "$COMMON" "$TMP/scratch.$i" "$ENV_FILTER" "$dir" \
      >"$TMP/scratch.$i/result" 2>&1 </dev/null &
  done
  wait
  for i in 0 1; do
    checks=$((checks + 1))
    if [[ "$(cat "$TMP/scratch.$i/result")" != "rc=0 out=[]" ]]; then
      fail "$label (${SHELLS[$i]}): expected silent success" "$(cat "$TMP/scratch.$i/result")"
    fi
    if ! printf '%s' "$prefix$want" | cmp -s - "$TMP/scratch.$i/capture"; then
      fail "$label (${SHELLS[$i]}): capture bytes differ" \
        "--- expected" "$(printf '%s' "$prefix$want" | od -An -c)" \
        "--- actual" "$(od -An -c "$TMP/scratch.$i/capture")"
    fi
  done
  finish "$before" "$label"
}

seq7() { printf '\033]7;file://%s\007' "$1"; }

mkdir "$TMP/run dir"
check_announce "case 10: herdr writes one OSC 7 with an empty host" herdr \
  "$TMP/run dir" "$(seq7 "$ENC_TMP/run%20dir")"

# Bytes outside A-Za-z0-9 - . _ ~ / are encoded one byte at a time, uppercase.
ODD_NAME="e 한#%x+&?'~._-"
mkdir "$TMP/$ODD_NAME"
odd_want="$(seq7 "$ENC_TMP/e%20%ED%95%9C%23%25x%2B%26%3F%27~._-")"
check_announce "reserved and UTF-8 bytes are percent-encoded (UTF-8 locale)" herdr \
  "$TMP/$ODD_NAME" "$odd_want"
check_announce "reserved and UTF-8 bytes are percent-encoded (C locale)" herdr \
  "$TMP/$ODD_NAME" "$odd_want" "$ANNOUNCE" "" "LC_ALL=C"

check_announce "output is appended after existing bytes" herdr \
  "$TMP/run dir" "$(seq7 "$ENC_TMP/run%20dir")" "$ANNOUNCE" "PRE-EXISTING"

check_announce "case 11: orca writes nothing" orca "$TMP/run dir" ""
check_announce "cmux writes nothing" cmux "$TMP/run dir" ""
check_announce "plain writes nothing" plain "$TMP/run dir" ""
check_announce "unset runtime writes nothing" "" "$TMP/run dir" ""

mkdir -p "$TMP/rel"
: > "$TMP/plain-file"
check_announce "case 12: relative directory writes nothing" herdr "rel" ""
check_announce "case 12: missing directory writes nothing" herdr "$TMP/missing" ""
check_announce "empty directory argument writes nothing" herdr "" ""
check_announce "a regular file is not a directory" herdr "$TMP/plain-file" ""
check_announce "missing argument writes nothing" herdr "" "" "$ANNOUNCE_NO_ARG"

# An unopenable target is silent and returns 0.
before="$failures"
for bad in "$TMP/no-such-dir/tty" "$TMP"; do
  run_shells "$ANNOUNCE" "$TMP/run dir" HARNESS_TERMINAL_TTY="$bad" HARNESS_TERMINAL_RUNTIME=herdr
  expect_results "unwritable target $bad" "rc=0 out=[]"
done
finish "$before" "unwritable capture targets are silent and return 0"

# No controlling terminal: /dev/tty cannot be opened. Detach each child with
# setsid so the default target fails as it would for a launch without a tty.
DETACHED='
. "$1"
if ( : >>/dev/tty ) 2>/dev/null; then echo ctty=yes; else echo ctty=no; fi
out="$(harness_terminal_announce_cwd "$4" 2>&1)"
printf "rc=%s out=[%s]\n" "$?" "$out"
'
before="$failures"
for i in 0 1; do
  mkdir -p "$TMP/scratch.$i"
  env -i HOME="$HOME" PATH="$PATH" TERM=xterm-256color LANG=en_US.UTF-8 \
    HARNESS_TERMINAL_RUNTIME=herdr \
    python3 -c '
import os, sys
pid = os.fork()
if pid == 0:
    os.setsid()
    os.execvp(sys.argv[1], sys.argv[1:])
_, st = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(st))' \
    "${SHELLS[$i]}" -c "$DETACHED" _ "$COMMON" "$TMP/scratch.$i" "$ENV_FILTER" "$TMP/run dir" \
    >"$TMP/scratch.$i/result" 2>&1 </dev/null &
done
wait
RESULT_0="$(cat "$TMP/scratch.0/result")"
RESULT_1="$(cat "$TMP/scratch.1/result")"
expect_results "no controlling terminal is silent and returns 0" $'ctty=no\nrc=0 out=[]'
finish "$before" "no controlling terminal is silent and returns 0"

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s) in %d shell checks\n' "$failures" "$checks"
  exit 1
fi
printf '\nPASS: terminal runtime detection, scrub and OSC 7 (%d shell checks, bash + zsh)\n' "$checks"
