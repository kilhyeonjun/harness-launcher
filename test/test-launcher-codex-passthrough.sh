#!/usr/bin/env zsh
# test-launcher-codex-passthrough.sh — verify Codex `--passthrough`, profile
# placement, caller-wins options, and the app-server boundary guard wiring.
#
# SDK hosts (Paseo) start `<command...> app-server [--enable goals]`. Codex
# rejects `-p` for app-server and other non-runtime subcommands, and the
# app-server receives each thread's cwd over JSON-RPC, so the launcher must
# omit its profile there and put the boundary guard in front of the server.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cleanup() {
  [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
TEST_TEMP="${TEST_TEMP:A}"
TEST_HARNESS="$TEST_TEMP/fake-harness"
TEST_INSIDE="$TEST_HARNESS/projects/app"
TEST_OUTSIDE="$TEST_TEMP/elsewhere"
TEST_BIN="$TEST_TEMP/bin"
TEST_PROFILE_HOME="$TEST_TEMP/profile-home"
mkdir -p "$TEST_HARNESS/config" "$TEST_INSIDE" "$TEST_OUTSIDE" "$TEST_BIN" "$TEST_PROFILE_HOME/profiles"
cat > "$TEST_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF
print -r -- "$TEST_HARNESS" > "$TEST_PROFILE_HOME/profiles/test"

# Stubs print one argument per line so tests compare exact argv.
cat > "$TEST_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf 'PWD:%s\n' "$PWD" >> "$TEST_STUB_FILE"
for arg in "$@"; do printf 'ARG:%s\n' "$arg"; done >> "$TEST_STUB_FILE"
exit 0
EOF
cat > "$TEST_BIN/codex-home-prepare.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$1/.harness/codex"
EOF
cat > "$TEST_BIN/codex-app-server-guard.py" <<'EOF'
import os, sys
with open(os.environ["TEST_STUB_FILE"], "a") as out:
    for arg in sys.argv[1:]:
        out.write(f"GUARD:{arg}\n")
command = sys.argv[sys.argv.index("--") + 1:]
os.execv(command[0], command)
EOF
chmod +x "$TEST_BIN/codex" "$TEST_BIN/codex-home-prepare.sh"

fail() {
  echo "FAIL: $1" >&2
  [[ -f "${2:-}" ]] && sed 's/^/  /' "$2" >&2
  [[ -f "${2:-}.err" ]] && sed 's/^/  err: /' "$2.err" >&2
  exit 1
}

run_codex() {  # <stub-file> <launcher args after `codex`...>
  local stub_file="$1"; shift
  : > "$stub_file"
  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$TEST_BIN:$PATH"
    export HARNESS_CODEX_BIN="$TEST_BIN/codex"
    export HARNESS_PROFILE_HOME="$TEST_PROFILE_HOME"
    unset HARNESS_CODEX_MCP_PROFILE HARNESS_SESSION_ISOLATION
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    _HARNESS_LAUNCHER_BIN="$TEST_BIN"
    _harness_launcher_run "$TEST_HARNESS" codex "$@"
  ) </dev/null >/dev/null 2>"$stub_file.err"
}

argv_of() { sed -n 's/^ARG://p' "$1"; }
guard_of() { sed -n 's/^GUARD://p' "$1"; }
count_arg() { argv_of "$1" | grep -Fxc -- "$2" || true; }
value_after() { argv_of "$1" | grep -Fx -A1 -- "$2" | sed -n 2p; }
has_arg() { argv_of "$1" | grep -Fxq -- "$2"; }
exact_argv() {  # <stub-file> <tokens...>
  local file="$1"; shift
  [[ "$(argv_of "$file")" == "$(print -rl -- "$@")" ]]
}
guarded() { [[ -n "$(guard_of "$1")" ]]; }

# P1: Paseo's app-server argv — guarded, no profile, harness cwd.
OUT="$TEST_TEMP/p1"
run_codex "$OUT" --passthrough app-server --enable goals || fail 'P1 app-server launch failed' "$OUT"
exact_argv "$OUT" --cd "$TEST_HARNESS" app-server --enable goals || fail 'P1 codex argv' "$OUT"
[[ "$(guard_of "$OUT")" == "$(print -rl -- --root "$TEST_HARNESS" --server-cwd "$TEST_HARNESS" \
  --prefix test --registry "$TEST_PROFILE_HOME/profiles" -- "$TEST_BIN/codex" --cd "$TEST_HARNESS" \
  app-server --enable goals)" ]] || fail 'P1 guard argv' "$OUT"
echo 'PASS: P1 --passthrough app-server runs behind the guard without -p'

# P2: the no-marker form gets the same treatment.
OUT="$TEST_TEMP/p2"
run_codex "$OUT" app-server || fail 'P2 app-server launch failed' "$OUT"
guarded "$OUT" || fail 'P2 app-server was not guarded' "$OUT"
has_arg "$OUT" -p && fail 'P2 -p was passed to app-server' "$OUT"
echo 'PASS: P2 app-server without the marker is guarded and has no -p'

# P3: an explicit launcher profile cannot apply to a non-runtime subcommand.
OUT="$TEST_TEMP/p3"
rc=0; run_codex "$OUT" fast app-server || rc=$?
[[ "$rc" == 2 ]] || fail "P3 expected exit 2, got $rc" "$OUT"
grep -Fq "codex profile 'fast' applies only to runtime commands; 'app-server' rejects --profile" "$OUT.err" \
  || fail 'P3 message' "$OUT"
[[ -s "$OUT" ]] && fail 'P3 codex ran' "$OUT"
echo 'PASS: P3 explicit profile with app-server exits 2'

# P4: `debug` rejects -p unless the next word is prompt-input.
OUT="$TEST_TEMP/p4"
run_codex "$OUT" --passthrough debug models || fail 'P4 debug models failed' "$OUT"
exact_argv "$OUT" --cd "$TEST_HARNESS" debug models || fail 'P4 debug models argv' "$OUT"
guarded "$OUT" && fail 'P4 debug models was guarded' "$OUT"
run_codex "$OUT" --passthrough debug prompt-input || fail 'P4 prompt-input failed' "$OUT"
exact_argv "$OUT" --cd "$TEST_HARNESS" -p base debug prompt-input || fail 'P4 prompt-input argv' "$OUT"
echo 'PASS: P4 debug models omits -p; debug prompt-input keeps it'

# P5: runtime commands keep the default profile; options before the
# subcommand are skipped with their values.
OUT="$TEST_TEMP/p5"
run_codex "$OUT" --passthrough exec x || fail 'P5 exec failed' "$OUT"
exact_argv "$OUT" --cd "$TEST_HARNESS" -p base exec x || fail 'P5 exec argv' "$OUT"
run_codex "$OUT" --passthrough -c k=v app-server || fail 'P5 -c app-server failed' "$OUT"
exact_argv "$OUT" --cd "$TEST_HARNESS" -c k=v app-server || fail 'P5 -c app-server argv' "$OUT"
guarded "$OUT" || fail 'P5 -c app-server was not guarded' "$OUT"
run_codex "$OUT" --passthrough -m app-server || fail 'P5 -m value failed' "$OUT"
exact_argv "$OUT" --cd "$TEST_HARNESS" -p base -m app-server || fail 'P5 option value taken as subcommand' "$OUT"
echo 'PASS: P5 runtime subcommands keep -p base and option values are skipped'

# P6: a caller profile replaces the launcher profile.
for form in '-p plan' '-pplan' '--profile plan' '--profile=plan'; do
  OUT="$TEST_TEMP/p6"
  run_codex "$OUT" --passthrough ${=form} exec x || fail "P6 $form failed" "$OUT"
  exact_argv "$OUT" --cd "$TEST_HARNESS" ${=form} exec x || fail "P6 $form argv" "$OUT"
done
echo 'PASS: P6 caller -p/--profile suppresses the launcher -p'

# P7: a caller -C inside the harness replaces --cd; outside exits 2.
for form in "-C $TEST_INSIDE" "-C$TEST_INSIDE" "-C=$TEST_INSIDE" "--cd $TEST_INSIDE" "--cd=$TEST_INSIDE"; do
  OUT="$TEST_TEMP/p7"
  run_codex "$OUT" --passthrough ${=form} exec x || fail "P7 $form failed" "$OUT"
  exact_argv "$OUT" -p base ${=form} exec x || fail "P7 $form argv" "$OUT"
done
run_codex "$OUT" --passthrough -C "$TEST_INSIDE" app-server || fail 'P7 guarded -C failed' "$OUT"
[[ "$(guard_of "$OUT" | grep -Fx -A1 -- --server-cwd | sed -n 2p)" == "$TEST_INSIDE" ]] \
  || fail 'P7 guard server cwd does not follow -C' "$OUT"
run_codex "$OUT" --passthrough -C projects/app exec x || fail 'P7 relative -C failed' "$OUT"
exact_argv "$OUT" -p base -C projects/app exec x || fail 'P7 relative -C argv' "$OUT"
[[ "$(sed -n 's/^PWD://p' "$OUT")" == "$TEST_HARNESS" ]] || fail 'P7 relative -C base moved' "$OUT"
for form in "-C $TEST_OUTSIDE" "-C=$TEST_OUTSIDE" "--cd=$TEST_OUTSIDE" "-C $TEST_TEMP/missing"; do
  rc=0; run_codex "$OUT" --passthrough ${=form} exec x || rc=$?
  [[ "$rc" == 2 ]] || fail "P7 $form expected exit 2, got $rc" "$OUT"
  [[ -s "$OUT" ]] && fail "P7 $form codex ran" "$OUT"
done
run_codex "$OUT" --passthrough exec -- -C "$TEST_OUTSIDE" || fail 'P7 -C after -- was validated' "$OUT"
echo 'PASS: P7 caller -C forms replace --cd inside the harness and fail outside'

# P8: launcher keywords after the marker are native arguments.
OUT="$TEST_TEMP/p8"
run_codex "$OUT" --passthrough continue || fail 'P8 continue failed' "$OUT"
exact_argv "$OUT" --cd "$TEST_HARNESS" -p base continue || fail 'P8 continue argv' "$OUT"
run_codex "$OUT" fast --passthrough never || fail 'P8 fast marker failed' "$OUT"
exact_argv "$OUT" --cd "$TEST_HARNESS" -p fast never || fail 'P8 keyword before marker' "$OUT"
echo 'PASS: P8 tokens after the marker are verbatim'

# P9: app-server shapes that bypass the relay exit 2; tooling runs unguarded.
for shape in 'app-server proxy' 'app-server daemon start' 'app-server --listen ws://127.0.0.1:1' \
  'app-server --listen=unix://' 'app-server --listen off' 'app-server unknown-tool' \
  'remote-control start' 'exec-server' 'mcp-server'; do
  OUT="$TEST_TEMP/p9"
  rc=0; run_codex "$OUT" --passthrough ${=shape} || rc=$?
  [[ "$rc" == 2 ]] || fail "P9 '$shape' expected exit 2, got $rc" "$OUT"
  [[ -s "$OUT" ]] && fail "P9 '$shape' codex ran" "$OUT"
done
OUT="$TEST_TEMP/p9"
run_codex "$OUT" --passthrough app-server --listen stdio:// || fail 'P9 stdio listen failed' "$OUT"
guarded "$OUT" || fail 'P9 stdio listen was not guarded' "$OUT"
run_codex "$OUT" --passthrough app-server --stdio || fail 'P9 --stdio failed' "$OUT"
guarded "$OUT" || fail 'P9 --stdio was not guarded' "$OUT"
run_codex "$OUT" --passthrough app-server generate-json-schema --out x || fail 'P9 schema tool failed' "$OUT"
guarded "$OUT" && fail 'P9 schema tool was guarded' "$OUT"
exact_argv "$OUT" --cd "$TEST_HARNESS" app-server generate-json-schema --out x || fail 'P9 schema argv' "$OUT"
echo 'PASS: P9 relay-bypassing app-server shapes exit 2'

# P10: the guard root is the harness dir the launcher runs in (the isolated
# session root for isolated launches).
OUT="$TEST_TEMP/p10"
SESSION_ROOT="$TEST_TEMP/session-root"
mkdir -p "$SESSION_ROOT/config"
cp "$TEST_HARNESS/config/launcher.env" "$SESSION_ROOT/config/"
: > "$OUT"
(
  export TEST_STUB_FILE="$OUT"
  export PATH="$TEST_BIN:$PATH"
  export HARNESS_CODEX_BIN="$TEST_BIN/codex"
  export HARNESS_PROFILE_HOME="$TEST_PROFILE_HOME"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  HARNESS_PREFIX=test
  HARNESS_RUN_DIR="$SESSION_ROOT" _harness_launcher_run_codex_cli "$SESSION_ROOT" legacy --passthrough app-server
) </dev/null >/dev/null 2>"$OUT.err" || fail 'P10 isolated app-server failed' "$OUT"
[[ "$(guard_of "$OUT" | sed -n 2p)" == "$SESSION_ROOT" ]] || fail 'P10 guard root is not the session root' "$OUT"
echo 'PASS: P10 guard root follows the isolated session root'

# P11: without the marker a caller -C still reaches Codex as a duplicate.
OUT="$TEST_TEMP/p11"
run_codex "$OUT" exec -C "$TEST_INSIDE" x || fail 'P11 legacy -C failed' "$OUT"
exact_argv "$OUT" --cd "$TEST_HARNESS" -p base exec -C "$TEST_INSIDE" x || fail 'P11 legacy argv changed' "$OUT"
echo 'PASS: P11 legacy freeform argv is unchanged'

# P13: a Codex management-looking word after the marker stays on Codex, also
# behind an isolation control.
OUT="$TEST_TEMP/p13"
: > "$OUT"
(
  export TEST_STUB_FILE="$OUT"
  export PATH="$TEST_BIN:$PATH"
  export HARNESS_CODEX_BIN="$TEST_BIN/codex"
  export HARNESS_PROFILE_HOME="$TEST_PROFILE_HOME"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  _harness_launcher_run "$TEST_HARNESS" --no-isolated codex --passthrough mcp list
) </dev/null >/dev/null 2>"$OUT.err" || fail 'P13 codex mcp failed' "$OUT"
exact_argv "$OUT" --cd "$TEST_HARNESS" -p base mcp list || fail 'P13 codex mcp was rerouted' "$OUT"
echo 'PASS: P13 Codex subcommands after the marker never become Claude management'

# P14: nothing reaches stdout before the app-server, which owns the JSON-RPC stream.
OUT="$TEST_TEMP/p14"
: > "$OUT"
(
  export TEST_STUB_FILE="$OUT"
  export PATH="$TEST_BIN:$PATH"
  export HARNESS_CODEX_BIN="$TEST_BIN/codex"
  export HARNESS_PROFILE_HOME="$TEST_PROFILE_HOME"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  _harness_launcher_run "$TEST_HARNESS" codex --passthrough app-server
) </dev/null >"$OUT.stdout" 2>"$OUT.err" || fail 'P14 app-server failed' "$OUT"
[[ ! -s "$OUT.stdout" ]] || fail 'P14 launcher wrote to the JSON-RPC stdout' "$OUT.stdout"
echo 'PASS: P14 the launcher keeps stdout clean for the app-server'

# P12: the rejecting-subcommand table matches the installed Codex.
if codex_bin="$(PATH="${PATH#$TEST_BIN:}" command -v codex 2>/dev/null)" && [[ "$codex_bin" != "$TEST_BIN/codex" ]]; then
  probe_home="$TEST_TEMP/codex-probe-home"
  mkdir -p "$probe_home"
  allowed="$(CODEX_HOME="$probe_home" "$codex_bin" -p probe features list 2>&1 >/dev/null || true)"
  [[ "$allowed" == *'--profile only applies to'* ]] || fail "P12 unexpected probe output: $allowed"
  codex_commands=("${(@f)$(CODEX_HOME="$probe_home" "$codex_bin" --help | sed -n '/^Commands:/,/^$/p' \
    | sed -n 's/^  \([a-z][a-z-]*\) .*/\1/p')}")
  source "$LAUNCHER_DIR/bin/harness-common.sh"
  for sub in "${codex_commands[@]}"; do
    [[ "$sub" == debug ]] && continue
    if [[ "$allowed" == *"\`codex $sub\`"* ]]; then
      harness_codex_subcommand_rejects_profile "$sub" && fail "P12 launcher rejects runtime command $sub"
    else
      harness_codex_subcommand_rejects_profile "$sub" || fail "P12 launcher misses rejecting command $sub"
    fi
  done
  [[ "$allowed" == *'`codex debug prompt-input`'* ]] || fail 'P12 debug prompt-input no longer special'
  # Top-level options: those with a <VALUE> placeholder take the next argument.
  CODEX_HOME="$probe_home" "$codex_bin" --help | sed -n '/^Options:/,$p' | grep -E '^  +-' > "$TEST_TEMP/codex-options"
  while IFS= read -r line; do
    takes_value=false
    [[ "$line" == *'<'* ]] && takes_value=true
    for opt in ${(s: :)${line//,/ }}; do
      [[ "$opt" == -* ]] || continue
      if $takes_value; then
        harness_codex_option_takes_value "$opt" || fail "P12 value option missing from table: $opt"
      else
        harness_codex_option_takes_value "$opt" && fail "P12 flag listed as value option: $opt"
      fi
    done
  done < "$TEST_TEMP/codex-options"
  echo 'PASS: P12 rejecting-subcommand table matches codex --help'
else
  echo 'SKIP: P12 codex is not installed'
fi

echo 'All Codex passthrough tests passed'
