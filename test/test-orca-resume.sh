#!/usr/bin/env zsh
# test-orca-resume.sh — Orca restores an agent as `<override> <default args>
# --resume <id>` (Claude) or `<override> codex resume <id>` (Codex). For
# isolation-default profiles the launcher must (a) give a fresh isolated Claude
# launch a session id it can map back, and (b) map that restore argv to the
# owning isolated session instead of rejecting it.
set -e
unset CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SURFACE_ID

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HARNESS="$TMP/harness"
OTHER="$TMP/other-harness"
STATE="$TMP/state"
mkdir -p "$HARNESS/config" "$OTHER" "$TMP/bin"
git -C "$HARNESS" init -q -b main
git -C "$HARNESS" config user.email test@example.invalid
git -C "$HARNESS" config user.name test
print -r -- 'HARNESS_NAME="test"' 'HARNESS_PREFIX="test"' 'HARNESS_SESSION_ISOLATION_DEFAULT="1"' > "$HARNESS/config/launcher.env"
git -C "$HARNESS" add -A && git -C "$HARNESS" commit -qm initial

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
{ printf 'SESSION=%s\n' "${HARNESS_SESSION_ROOT:-}"; printf 'ARG=%s\n' "$@"; } > "$STUB_LOG"
if [[ -n "${WAIT_START:-}" ]]; then
  touch "$WAIT_START"
  while [[ ! -e "$WAIT_RELEASE" ]]; do sleep 0.05; done
fi
STUB
chmod +x "$TMP/bin/claude"

fail() { echo "FAIL: $*" >&2; exit 1; }

# run <log> [ENV=val ...] -- args : non-tty launcher call (ambient isolation route)
run() {
  local log="$1"; shift
  local -a envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  rm -f "$log" "$log.err"
  (
    export PATH="$TMP/bin:/usr/bin:/bin" HARNESS_SESSION_STATE_HOME="$STATE" STUB_LOG="$log" "${envs[@]}"
    source "$ROOT/bin/aliases.zsh"
    _harness_launcher_run "$HARNESS" "$@"
  ) >/dev/null 2>"$log.err"
}

# run_tty <log> args : interactive launcher call (profile-default route)
run_tty() {
  local log="$1"; shift
  rm -f "$log" "$log.err"
  ROOT="$ROOT" HARNESS="$HARNESS" STATE="$STATE" TMP="$TMP" STUB_LOG="$log" TEST_ARGS="${(j: :)${(q)@}}" expect <<'EXPECT'
set timeout 20
log_user 0
spawn env ROOT=$env(ROOT) HARNESS=$env(HARNESS) STATE=$env(STATE) TMP=$env(TMP) STUB_LOG=$env(STUB_LOG) TEST_ARGS=$env(TEST_ARGS) PATH=$env(TMP)/bin:/usr/bin:/bin zsh -c {
  export PATH="$TMP/bin:/usr/bin:/bin" HARNESS_SESSION_STATE_HOME="$STATE"
  unset CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SURFACE_ID
  source "$ROOT/bin/aliases.zsh"
  eval "set -- $TEST_ARGS"
  _harness_launcher_run "$HARNESS" "$@"
}
expect eof
catch wait result
exit [lindex $result 3]
EXPECT
}

argv_has() { grep -qxF -- "ARG=$2" "$1"; }
arg_after() { awk -v k="ARG=$2" 'f{print; exit} $0==k{f=1}' "$1"; }
session_count() { find "$STATE/sessions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
UUID_RE='^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$'

# --- fresh launch: --name kept, lowercase --session-id appended -------------
run_tty "$TMP/fresh.log" base || fail 'fresh interactive isolated launch failed'
root="$(sed -n 's/^SESSION=//p' "$TMP/fresh.log")"
ID="$(basename "$root")"
[[ "$ID" =~ $UUID_RE ]] || fail "session dir is not an uppercase UUID: $ID"
argv_has "$TMP/fresh.log" --name || fail 'fresh launch lost the bootstrap --name'
lower="${(L)ID}"
[[ "$(arg_after "$TMP/fresh.log" --session-id)" == "ARG=$lower" ]] || fail 'fresh launch must carry --session-id <lowercase id>'
# --session-id comes after --name (bootstrap eligibility rejects --session-id).
name_line="$(grep -n '^ARG=--name$' "$TMP/fresh.log" | cut -d: -f1)"
sid_line="$(grep -n '^ARG=--session-id$' "$TMP/fresh.log" | cut -d: -f1)"
(( sid_line > name_line )) || fail '--session-id must be appended after --name'

# An argv that already names a session is left alone.
run "$TMP/own.log" HARNESS_SESSION_ISOLATION=1 -- base --session-id 11111111-2222-4333-8444-555555555555 || fail 'explicit --session-id launch failed'
[[ "$(grep -c '^ARG=--session-id$' "$TMP/own.log")" == 1 ]] || fail 'must not add a second --session-id'

# Session-selecting flags outside the isolate route get no --session-id.
for flags in "--from-pr 12" "--teleport abc" "--bg" "--remote-control"; do
  run "$TMP/legacyflag.log" HARNESS_SESSION_ISOLATION=1 -- base ${=flags} || { cat "$TMP/legacyflag.log.err" >&2; fail "launch with $flags failed"; }
  ! grep -q '^ARG=--session-id$' "$TMP/legacyflag.log" || fail "--session-id must not be added next to $flags"
done

# --- Claude resume mapping ---------------------------------------------------
before="$(session_count)"
for form in "--resume $lower" "--resume=$lower" "-r $lower" "-r$lower" "--resume ${(U)lower}"; do
  run "$TMP/resume.log" HARNESS_SESSION_ISOLATION=1 -- base ${=form} || { cat "$TMP/resume.log.err" >&2; fail "resume form '$form' was not mapped"; }
  [[ "$(sed -n 's/^SESSION=//p' "$TMP/resume.log")" == "$root" ]] || fail "resume form '$form' did not land in the owning session root"
done
[[ "$(session_count)" == "$before" ]] || fail 'resume must not create a session'
# default (profile) route, two consecutive restores
for n in 1 2; do
  run_tty "$TMP/resume-tty.log" base --resume "$lower" || fail "profile-default restore $n was rejected"
  [[ "$(sed -n 's/^SESSION=//p' "$TMP/resume-tty.log")" == "$root" ]] || fail "profile-default restore $n used the wrong root"
done

# --- rejection paths ---------------------------------------------------------
reject_msg='this profile isolates fresh sessions'
UNKNOWN=99999999-2222-4333-8444-555555555555
if run "$TMP/unknown.log" HARNESS_SESSION_ISOLATION=1 -- base --resume $UNKNOWN; then fail 'unknown id must be rejected'; fi
grep -q -- "$reject_msg\|continuation requires" "$TMP/unknown.log.err" || fail 'unknown id must keep the unchanged reject message'
[[ ! -e "$TMP/unknown.log" ]] || fail 'unknown id must not launch'
if run "$TMP/nonuuid.log" HARNESS_SESSION_ISOLATION=1 -- base --resume not-a-uuid; then fail 'non-UUID id must be rejected'; fi
grep -q -- "continuation requires" "$TMP/nonuuid.log.err" || fail 'non-UUID id must keep the unchanged reject message'
if run_tty "$TMP/unknown-tty.log" base --resume $UNKNOWN; then fail 'unknown id (default route) must be rejected'; fi
[[ ! -e "$TMP/unknown-tty.log" ]] || fail 'unknown id (default route) must not launch'

# Another harness's source-root is ignored.
cp "$STATE/sessions/$ID/source-root" "$TMP/source-root.bak"
print -r -- "$OTHER" > "$STATE/sessions/$ID/source-root"
if run "$TMP/foreign.log" HARNESS_SESSION_ISOLATION=1 -- base --resume $lower; then fail 'foreign source-root must be ignored'; fi
grep -q -- "continuation requires" "$TMP/foreign.log.err" || fail 'foreign source-root must keep the unchanged reject message'
cp "$TMP/source-root.bak" "$STATE/sessions/$ID/source-root"

# Explicit --no-isolated still wins (legacy launch, no isolated root).
run "$TMP/noiso.log" HARNESS_SESSION_ISOLATION=1 -- --no-isolated base --resume $lower || fail '--no-isolated launch failed'
[[ -z "$(sed -n 's/^SESSION=//p' "$TMP/noiso.log")" ]] || fail '--no-isolated must not map into an isolated session'

# Profiles with default 0 are unaffected.
cp "$HARNESS/config/launcher.env" "$TMP/launcher.env.bak"
print -r -- 'HARNESS_SESSION_ISOLATION_DEFAULT="0"' >> "$HARNESS/config/launcher.env"
run "$TMP/default0.log" -- base --resume $lower || fail 'default-0 resume failed'
[[ -z "$(sed -n 's/^SESSION=//p' "$TMP/default0.log")" ]] || fail 'default-0 profile must not isolate a resume'
cp "$TMP/launcher.env.bak" "$HARNESS/config/launcher.env"

# --- specific failure messages ----------------------------------------------
# Held lease.
run "$TMP/lease-owner.log" HARNESS_SESSION_ISOLATION=1 WAIT_START="$TMP/ls" WAIT_RELEASE="$TMP/lr" -- base --resume $lower & owner=$!
for _ in {1..300}; do [[ -f "$TMP/ls" ]] && break; sleep 0.05; done
[[ -f "$TMP/ls" ]] || { kill $owner 2>/dev/null || true; fail 'lease owner did not start'; }
if run "$TMP/lease.log" HARNESS_SESSION_ISOLATION=1 -- base --resume $lower; then touch "$TMP/lr"; wait $owner; fail 'held lease must be rejected'; fi
touch "$TMP/lr"; wait $owner
grep -q 'already active' "$TMP/lease.log.err" || fail 'held lease must say the session is already active'
[[ ! -e "$TMP/lease.log" ]] || fail 'held lease must not launch'

# Delivered session.
cp "$STATE/sessions/$ID/journal" "$TMP/journal.bak"
printf 'state=DELIVERED\nidentity=%s\nheartbeat=2026-01-01T00:00:00Z\n' "$(printf '%064d' 0)" > "$STATE/sessions/$ID/journal"
if run "$TMP/delivered.log" HARNESS_SESSION_ISOLATION=1 -- base --resume $lower; then fail 'delivered session must be rejected'; fi
grep -q 'DELIVERED' "$TMP/delivered.log.err" || fail 'delivered session needs its own message'
[[ ! -e "$TMP/delivered.log" ]] || fail 'delivered session must not launch'
cp "$TMP/journal.bak" "$STATE/sessions/$ID/journal"

# --- Codex rollout mapping ---------------------------------------------------
CODEX_ID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
rollout_dir="$STATE/worktrees/$ID/.harness/codex/sessions/2026/09/29"
mkdir -p "$rollout_dir"
: > "$rollout_dir/rollout-2026-09-29T01-02-03-$CODEX_ID.jsonl"
run_codex() { # <log> [ENV=val ...] -- args
  local log="$1"; shift
  local -a envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  rm -f "$log" "$log.err"
  (
    export PATH="$TMP/bin:/usr/bin:/bin" HARNESS_SESSION_STATE_HOME="$STATE" STUB_LOG="$log" "${envs[@]}"
    source "$ROOT/bin/aliases.zsh"
    _harness_launcher_run_codex_cli() { printf 'SESSION=%s\nARGS=%s\n' "${HARNESS_SESSION_ROOT:-}" "$*" > "$STUB_LOG"; }
    _harness_launcher_run "$HARNESS" "$@"
  ) >/dev/null 2>"$log.err"
}
run_codex "$TMP/codex.log" HARNESS_SESSION_ISOLATION=1 -- codex resume $CODEX_ID || { cat "$TMP/codex.log.err" >&2; fail 'codex rollout id was not mapped'; }
[[ "$(sed -n 's/^SESSION=//p' "$TMP/codex.log")" == "$root" ]] || fail 'codex resume landed in the wrong root'
if run_codex "$TMP/codex-unknown.log" HARNESS_SESSION_ISOLATION=1 -- codex resume $UNKNOWN; then fail 'unknown codex id must be rejected'; fi
grep -q 'continuation requires' "$TMP/codex-unknown.log.err" || fail 'unknown codex id must keep the unchanged reject message'

# Duplicate owner is invalid: a second session holds the same rollout id.
run "$TMP/second.log" HARNESS_SESSION_ISOLATION=1 -- base || fail 'second fresh session failed'
ID2="$(basename "$(sed -n 's/^SESSION=//p' "$TMP/second.log")")"
mkdir -p "$STATE/worktrees/$ID2/.harness/codex/sessions/2026/09/29"
: > "$STATE/worktrees/$ID2/.harness/codex/sessions/2026/09/29/rollout-2026-09-29T01-02-03-$CODEX_ID.jsonl"
if run_codex "$TMP/codex-dup.log" HARNESS_SESSION_ISOLATION=1 -- codex resume $CODEX_ID; then fail 'duplicate rollout owner must be invalid'; fi
grep -q 'ambiguous' "$TMP/codex-dup.log.err" || fail 'duplicate owner must say ambiguous'
[[ ! -e "$TMP/codex-dup.log" ]] || fail 'duplicate owner must not launch'

# Garbage-collected workspace (session record kept, worktree retired).
rm -rf "$STATE/worktrees/$ID2" "$STATE/worktrees/$ID"
if run "$TMP/gc.log" HARNESS_SESSION_ISOLATION=1 -- base --resume ${(L)ID2}; then fail 'retired workspace must be rejected'; fi
grep -q 'missing or retired' "$TMP/gc.log.err" || fail 'retired workspace needs its own message'
grep -q 'could not restore isolated session' "$TMP/gc.log.err" || fail 'mapped restore failure must be reported'
[[ ! -e "$TMP/gc.log" ]] || fail 'retired workspace must not launch'

echo 'PASS: test-orca-resume'
