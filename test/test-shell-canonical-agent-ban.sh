#!/usr/bin/env zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export ROOT TMP
export HOME="$TMP/home" HARNESS_PROFILE_HOME="$TMP/registry"
export HARNESS="$TMP/canonical checkout" OTHER="$TMP/unrelated"
export LOG="$TMP/native.log" HARNESS_CODEX_MCP_PROFILE=""
mkdir -p "$HOME" "$HARNESS/config" "$HARNESS/nested" "$OTHER" "$TMP/native" "$HARNESS_PROFILE_HOME/profiles"
printf 'HARNESS_NAME="canonical test"\nHARNESS_PREFIX="alpha"\n' > "$HARNESS/config/launcher.env"
printf '%s\n' "$HARNESS" > "$HARNESS_PROFILE_HOME/profiles/alpha"
ln -s "$HARNESS" "$TMP/canonical-link"
for runtime in omp codex claude; do
  cat > "$TMP/native/$runtime" <<'NATIVE'
#!/bin/sh
printf '%s:' "${0##*/}" >> "$LOG"
printf ' <%s>' "$@" >> "$LOG"
printf '\n' >> "$LOG"
if [ "${HARNESS_TEST_CAPTURE_CODEX_HOME:-0}" = 1 ]; then
  printf 'CODEX_HOME:<%s>\n' "${CODEX_HOME:-}" >> "$LOG"
fi
NATIVE
  chmod 755 "$TMP/native/$runtime"
done
export PATH="$TMP/native:/usr/bin:/bin"
bash "$ROOT/test/lib/install-runtime-fixture.sh" "$ROOT" "$TMP/prefix"
cp "$TMP/prefix/share/harness-launcher/harness-auto" "$TMP/real-harness-auto"
cp "$TMP/prefix/share/harness-launcher/harness-exec" "$TMP/real-harness-exec"
cat > "$TMP/prefix/share/harness-launcher/harness-exec" <<'BOUND'
#!/bin/sh
shift
exec omp "$@"
BOUND
chmod 755 "$TMP/prefix/share/harness-launcher/harness-exec"
cat > "$TMP/prefix/share/harness-launcher/harness-auto" <<'AUTO'
#!/bin/sh
printf 'route:' >> "$LOG"
printf ' <%s>' "$@" >> "$LOG"
printf '\n' >> "$LOG"
if [ "${1:-}" = claude-management ]; then
  shift
  exec claude "$@"
fi
AUTO
chmod 755 "$TMP/prefix/share/harness-launcher/harness-auto"
cat > "$TMP/check.zsh" <<'CHECK'
set -eu
source "$TMP/prefix/share/harness-launcher/aliases.zsh"
fail() { print -u2 -r -- "FAIL: $*"; exit 1; }
harness_shell_enable
harness_shell_enable
: > "$LOG"
# Persisted registration alone must suffice; no harness_register call here.
for cwd in "$HARNESS" "$HARNESS/nested" "$TMP/canonical-link/nested"; do
  cd "$cwd"
  for runtime in omp codex claude; do
    rc=0
    "$runtime" --resume 'session with spaces' > "$TMP/out" 2> "$TMP/err" || rc=$?
    [[ "$rc" == 2 ]] || fail "$runtime did not refuse canonical cwd ($rc)"
    [[ "$(<"$TMP/err")" == *canonical_agent_refused* && "$(<"$TMP/err")" == *'--isolated '* ]] || fail 'missing refusal reason or isolated alternative'
    [[ ! -s "$LOG" ]] || fail 'refused agent reached native executable'
  done
done
# Native information/management must remain usable in a canonical checkout,
# without entering an agent route or adding launcher argv.
cd "$HARNESS"
for runtime in omp codex claude; do
  case "$runtime" in
    omp) management_words=(--version --help login models) ;;
    codex) management_words=(--version -V --help -h help login logout mcp completion features) ;;
    claude) management_words=(--version --help auth mcp plugin doctor) ;;
  esac
  for subcommand in "${management_words[@]}"; do
    : > "$LOG"
    "$runtime" "$subcommand" 'native argument' || fail "$runtime $subcommand was refused"
    if [[ "$runtime" == codex && "$subcommand" != (--version|-V|--help|-h) ]]; then
      [[ "$(<"$LOG")" == "route: <codex> <--passthrough> <$subcommand> <native argument>" ]] || fail "codex $subcommand bypassed profile transport or changed argv"
    else
      [[ "$(<"$LOG")" == *"$runtime: <$subcommand> <native argument>"* ]] || fail "$runtime $subcommand did not preserve native argv"
      [[ "$(<"$LOG")" != *' <base> '* && "$(<"$LOG")" != *' <--passthrough> '* ]] || fail 'management entered an agent route'
    fi
  done
done
# Agent-executing subcommands and post-- prompt flags are not exemptions.
for subcommand in exec review app-server; do
  : > "$LOG"
  rc=0
  codex "$subcommand" task >"$TMP/out" 2>"$TMP/err" || rc=$?
  [[ "$rc" == 2 && ! -s "$LOG" ]] || fail "codex $subcommand bypassed canonical refusal"
  if harness_agent_is_management codex "$subcommand" task; then fail "classified codex $subcommand as management"; fi
done
for runtime in omp codex claude; do
  rc=0
  "$runtime" -- --help >"$TMP/out" 2>"$TMP/err" || rc=$?
  [[ "$rc" == 2 && ! -s "$LOG" ]] || fail 'post-- prompt flag bypassed canonical refusal'
done
: > "$LOG"
print 'PASS: interactive native management stays native while agent subcommands remain refused'
# Matching is path-component based, not a string prefix, and uses no external
# commands even when the registry is missing.
mkdir -p "$HARNESS-sibling"
_harness_launcher_canonical_agent_refuse "$HARNESS-sibling" omp || fail 'sibling path was refused'
_HARNESS_LAUNCHER_REGISTERED_DIRS=("$HARNESS")
HARNESS_PROFILE_HOME="$TMP/missing-registry"
old_path="$PATH"
PATH=/nonexistent
rc=0
_harness_launcher_canonical_agent_refuse "$HARNESS/nested" codex 2> "$TMP/memory.err" || rc=$?
[[ "$rc" == 2 ]] || fail 'in-memory registration did not refuse without external commands'
_harness_launcher_canonical_agent_refuse "$OTHER" omp || fail 'noncanonical cwd was refused'
_HARNESS_LAUNCHER_REGISTERED_DIRS=()
_harness_launcher_canonical_agent_refuse "$HARNESS/nested" omp || fail 'missing registry did not fail open'
PATH="$old_path"
cd "$OTHER"
omp resume 'session with spaces'
[[ "$(<"$LOG")" == 'omp: <resume> <session with spaces>' ]] || fail 'noncanonical omp argv changed'
codex resume 'outside session'
claude --resume 'outside session'
[[ "$(<"$LOG")" == *'route: <codex> <--passthrough> <resume> <outside session>'* && "$(<"$LOG")" == *'route: <claude> <base> <--passthrough> <--resume> <outside session>'* ]] || fail 'noncanonical routed argv changed'
# Exercise harness_register's real bound function against the transport stub.
harness_register "$HARNESS"
cd "$HARNESS"
alpha resume 'bound-session' --flag 'two words'
[[ "$(<"$LOG")" == *'omp: <resume> <bound-session> <--flag> <two words>'* ]] || fail 'bound launcher argv changed'
HARNESS_PROFILE_HOME="$TMP/registry"
harness_shell_disable
(( ! $+functions[omp] && ! $+functions[claude] )) || fail 'disable retained temporary wrappers'
: > "$LOG"
omp disabled
claude disabled
codex disabled
[[ "$(<"$LOG")" == *'omp: <disabled>'* && "$(<"$LOG")" == *'claude: <disabled>'* && "$(<"$LOG")" == *'codex: <disabled>'* ]] || fail 'disabled canonical commands changed'
# Collisions are atomic and user replacements survive disable.
omp() { return 37; }
if harness_shell_enable 2> "$TMP/collision.err"; then fail 'claimed user omp function'; fi
(( ! $+functions[claude] )) || fail 'omp collision partially enabled Claude'
unfunction omp
alias omp='return 38'
if harness_shell_enable 2> "$TMP/alias.err"; then fail 'claimed user omp alias'; fi
unalias omp
harness_shell_enable
source "$TMP/prefix/share/harness-launcher/aliases.zsh"
harness_shell_enable
omp() { return 39; }
rc=0
harness_shell_disable 2> "$TMP/replaced.err" || rc=$?
[[ "$rc" == 2 ]] || fail 'disable did not report replaced omp'
rc=0
omp || rc=$?
[[ "$rc" == 39 ]] || fail 'disable deleted replaced omp'
print 'PASS: interactive canonical shell refusal, registry matching, native behavior, argv, and ownership'
CHECK
/bin/zsh -fic 'source "$1"' _ "$TMP/check.zsh"
# The opt-in interception must not affect noninteractive native omp commands.
: > "$LOG"
/bin/zsh -fc 'source "$TMP/prefix/share/harness-launcher/aliases.zsh"; harness_shell_enable; cd "$HARNESS"; omp resume "noninteractive session"; codex resume "noninteractive session"; claude --resume "noninteractive session"'
[[ "$(<"$LOG")" == *'omp: <resume> <noninteractive session>'* && "$(<"$LOG")" == *'route: <codex> <--passthrough> <resume> <noninteractive session>'* && "$(<"$LOG")" == *'route: <claude> <base> <--passthrough> <--resume> <noninteractive session>'* ]] || { print -u2 'FAIL: noninteractive runtime routing changed'; exit 1; }
# The common guard must also load and refuse from the supported Bash entry.
rc=0
/bin/bash -c 'source "$ROOT/bin/harness-common.sh"; harness_canonical_agent_refuse "$HARNESS/nested" claude' 2> "$TMP/bash.err" || rc=$?
[[ "$rc" == 2 && "$(<"$TMP/bash.err")" == *canonical_agent_refused* ]] || { print -u2 'FAIL: portable guard did not refuse in Bash'; exit 1; }
print 'PASS: noninteractive native omp and portable Bash guard'

# Restore the real profile transport to prove management keeps CODEX_HOME;
# only preparation is stubbed, never profile resolution or environment export.
cp "$TMP/real-harness-auto" "$TMP/prefix/share/harness-launcher/harness-auto"
cp "$TMP/real-harness-exec" "$TMP/prefix/share/harness-launcher/harness-exec"
printf '#!/bin/sh\nexit 0\n' > "$TMP/prefix/share/harness-launcher/codex-home-prepare.sh"
chmod 755 "$TMP/prefix/share/harness-launcher/codex-home-prepare.sh"
: > "$LOG"
export HARNESS_TEST_CAPTURE_CODEX_HOME=1
/bin/zsh -fic 'source "$TMP/prefix/share/harness-launcher/aliases.zsh"; harness_shell_enable; cd "$HARNESS"; codex login "profile argument"'
[[ "$(<"$LOG")" == *'<login> <profile argument>'* && "$(<"$LOG")" == *"CODEX_HOME:<$HARNESS/.harness/codex>"* ]] || { print -u2 'FAIL: real Codex management lost native argv or profile CODEX_HOME'; exit 1; }
print 'PASS: canonical Codex management retains profile CODEX_HOME through real routing'
