#!/usr/bin/env bash
# test-launcher-checkup.sh — headless `<prefix> checkup prompt-audit` and the
# `harness-profile checkup` fan-out: argv/cwd contract, report files, a status
# line that never carries report content, failure paths, the working-tree
# guard, isolation rejection before any clone, and reserved profile prefixes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PREFIX="$TMP/prefix"
HOME_DIR="$TMP/home"
BIN_DIR="$HOME_DIR/.local/bin"
STUB_BIN="$TMP/stub-bin"
LOG="$TMP/claude.log"
BODY="REPORT-BODY-MUST-NOT-LEAK"
PY="$(command -v python3)"

fail() { echo "FAIL: $*" >&2; exit 1; }

bash "$ROOT/test/lib/install-runtime-fixture.sh" "$ROOT" "$PREFIX"
mkdir -p "$STUB_BIN" "$BIN_DIR" "$HOME_DIR/.claude/skills" "$HOME_DIR/.claude/plugins"
printf 'must not be readable by the audit\n' > "$HOME_DIR/.claude/settings.json"

make_harness() { # <dir> <prefix> [extra launcher.env line]
  mkdir -p "$1/config" "$1/.claude" "$1/sub"
  printf 'HARNESS_NAME="%s"\nHARNESS_PREFIX="%s"\n%s\n' "$2" "$2" "${3:-}" > "$1/config/launcher.env"
  printf '{"env":{"CHECKUP_LOCAL_ENV":"loaded"}}\n' > "$1/.claude/settings.local.json"
  printf '.harness/\n' > "$1/.gitignore"
  touch "$1/sub/.keep"
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qm init
}

cat > "$STUB_BIN/claude" <<'EOF'
#!/usr/bin/env bash
stdin=""
IFS= read -r -t 1 stdin || true
{
  printf 'PWD:%s\n' "$PWD"
  printf 'ENV:%s\n' "${CHECKUP_LOCAL_ENV:-}"
  printf 'STDIN:%s\n' "$stdin"
  printf 'CALLER:%s|%s|%s|%s|%s\n' "${CLAUDECODE-unset}" "${CLAUDE_CODE_MESSAGING_SOCKET-unset}" \
    "${OTEL_EXPORTER_OTLP_ENDPOINT-unset}" "${CMUX_SOCKET_PATH-unset}" "${CLAUDE_CODE_ENABLE_TELEMETRY-unset}"
  printf 'SESSION:%s|%s\n' "${CLAUDE_CODE_SESSION_ID-unset}" "${HARNESS_SESSION_ID-unset}"
  printf 'PROVIDER:%s|%s|%s|%s|%s|%s|%s\n' "${ANTHROPIC_BASE_URL-unset}" "${ANTHROPIC_AUTH_TOKEN-unset}" \
    "${ANTHROPIC_DEFAULT_OPUS_MODEL-unset}" "${ANTHROPIC_DEFAULT_SONNET_MODEL-unset}" \
    "${ANTHROPIC_DEFAULT_HAIKU_MODEL-unset}" "${ANTHROPIC_CUSTOM_HEADERS-unset}" "${GH_TOKEN-unset}"
  printf 'GLOB:%s MEMORY:%s\n' "${CLAUDE_CODE_GLOB_NO_IGNORE-unset}" "${CLAUDE_CODE_DISABLE_AUTO_MEMORY-unset}"
  printf 'ARGV_JSON:'
  "$CHECKUP_TEST_PY" -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@"
} >> "$CHECKUP_TEST_LOG"
mode="${CHECKUP_STUB_MODE:-ok}"
[[ -n "${CHECKUP_STUB_FAIL_PWD:-}" && "$PWD" == "$CHECKUP_STUB_FAIL_PWD" ]] && mode=budget
case "$mode" in
  ok) printf '{"type":"result","subtype":"success","is_error":false,"result":"%s","session_id":"sid-1","total_cost_usd":1.25,"duration_ms":4500,"num_turns":7,"permission_denials":[]}\n' "$CHECKUP_TEST_BODY" ;;
  noisy)
    echo "STDERR-$CHECKUP_TEST_BODY" >&2
    printf '{"type":"result","subtype":"success","is_error":false,"result":"x","session_id":"sid-4","total_cost_usd":0.5,"duration_ms":10,"num_turns":1,"permission_denials":[{"tool_name":"Bash"},{"tool_name":"Read"}]}\n' ;;
  budget) printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"session_id":"sid-2","total_cost_usd":0.081563,"duration_ms":900,"num_turns":1}\n'; exit 1 ;;
  crash) echo 'not json'; exit 3 ;;
  apierror) printf '{"type":"result","subtype":"success","is_error":true,"result":"API Error: 401","session_id":"sid-5","total_cost_usd":0,"duration_ms":10,"num_turns":1}\n'; exit 1 ;;
  write)
    : > "$PWD/stray-file"
    printf '{"type":"result","subtype":"success","is_error":false,"result":"x","session_id":"sid-3","total_cost_usd":0.1,"duration_ms":10,"num_turns":1}\n' ;;
esac
EOF
chmod +x "$STUB_BIN/claude"

H1="$HOME_DIR/work/test harness"; make_harness "$H1" th
H2="$HOME_DIR/work/other harness"; make_harness "$H2" tg
H3="$HOME_DIR/work/isolated harness"; make_harness "$H3" ti 'HARNESS_SESSION_ISOLATION_DEFAULT="1"'
for h in "$H1" "$H2" "$H3"; do
  HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" "$PREFIX/bin/harness-profile" register "$h" >/dev/null
done
H1R="$(cd "$H1" && pwd -P)"; H2R="$(cd "$H2" && pwd -P)"
REPORTS="$H1R/.harness/reports/checkup"

# run <command> [args...]: run from inside H1/sub (so harness-exec injects
# --cwd), as if called from another Claude session, with input on stdin.
run() {
  (
    cd "$H1/sub"
    export HOME="$HOME_DIR" PATH="$STUB_BIN:/usr/bin:/bin"
    export CHECKUP_TEST_LOG="$LOG" CHECKUP_TEST_BODY="$BODY" CHECKUP_TEST_PY="$PY"
    export HARNESS_SESSION_STATE_HOME="$TMP/state"
    export CHECKUP_STUB_MODE="${CHECKUP_STUB_MODE:-ok}" CHECKUP_STUB_FAIL_PWD="${CHECKUP_STUB_FAIL_PWD:-}"
    export CLAUDECODE=1 CLAUDE_CODE_MESSAGING_SOCKET="$TMP/caller.sock" CLAUDE_CODE_ENABLE_TELEMETRY=1
    export OTEL_EXPORTER_OTLP_ENDPOINT=http://caller.invalid CMUX_SOCKET_PATH="$TMP/cmux.sock"
    export CLAUDE_CODE_SESSION_ID=caller-session HARNESS_SESSION_ID=caller-harness-session
    export ANTHROPIC_BASE_URL=http://caller-gateway.invalid ANTHROPIC_AUTH_TOKEN=caller-token
    export ANTHROPIC_DEFAULT_OPUS_MODEL=caller-model ANTHROPIC_DEFAULT_SONNET_MODEL=caller-model
    export ANTHROPIC_DEFAULT_HAIKU_MODEL=caller-model ANTHROPIC_CUSTOM_HEADERS=caller-header GH_TOKEN=caller-gh-token
    [[ -z "${HARNESS_CHECKUP_MAX_BUDGET_USD:-}" ]] || export HARNESS_CHECKUP_MAX_BUDGET_USD
    [[ -z "${HARNESS_SESSION_ISOLATION:-}" ]] || export HARNESS_SESSION_ISOLATION
    printf 'PIPED-INPUT\n' | "$@"
  )
}
# argv_check <python expression over `a` (argv list) and `s` (parsed --settings)>
# eval() only ever sees the literal assertion strings written in this file.
argv_check() {
  "$PY" - "$LOG" "$1" <<'PY'
import json, sys
lines = [l for l in open(sys.argv[1]) if l.startswith("ARGV_JSON:")]
a = json.loads(lines[-1][len("ARGV_JSON:"):])
s = json.loads(a[a.index("--settings") + 1]) if "--settings" in a else {}
def val(flag):
    return a[a.index(flag) + 1] if flag in a else None
def vals(flag):
    return [a[i + 1] for i, x in enumerate(a) if x == flag]
ok = eval(sys.argv[2])
if not ok:
    print("argv:", a, file=sys.stderr)
sys.exit(0 if ok else 1)
PY
}
expect_rc() { # <rc> <label> <command...>
  local want="$1" label="$2" rc=0; shift 2
  "$@" >"$TMP/rc.out" 2>"$TMP/rc.err" || rc=$?
  [[ "$rc" == "$want" ]] || { sed 's/^/  /' "$TMP/rc.err" >&2; fail "$label: exit $rc, want $want"; }
}

# --- A: default run ---------------------------------------------------------
: > "$LOG"
out="$(run "$BIN_DIR/th" checkup prompt-audit 2>"$TMP/a.err")" || { cat "$TMP/a.err" >&2; fail "checkup exited non-zero"; }
grep -Fqx "PWD:$H1R" "$LOG" || fail "checkup did not run at the harness root"
grep -Fqx "ENV:loaded" "$LOG" || fail "checkup did not export the profile's local env"
grep -Fqx "STDIN:" "$LOG" || fail "claude must not read the caller's stdin"
grep -Fqx "CALLER:unset|unset|unset|unset|unset" "$LOG" || fail "caller session/telemetry env leaked: $(grep '^CALLER:' "$LOG")"
grep -Fqx "GLOB:false MEMORY:1" "$LOG" || fail "glob/memory env not pinned"
grep -Fqx "SESSION:unset|unset" "$LOG" || fail "caller session ids leaked: $(grep '^SESSION:' "$LOG")"
grep -Fqx "PROVIDER:unset|unset|unset|unset|unset|unset|unset" "$LOG" || fail "caller provider routing or GitHub token leaked: $(grep '^PROVIDER:' "$LOG")"
argv_check '"--no-session-persistence" in a' || fail "the audit session must not be resumable by continue"
argv_check 'a[:2] == ["-p", "/checkup prompt-audit"]' || fail "prompt must be the first positional after -p"
argv_check 'a.count("--settings") == 1' || fail "settings must be passed once"
argv_check '"--restricted" in a and "--strict-mcp-config" in a' || fail "restricted/strict-mcp flags missing"
argv_check 'val("--tools") == "Read,Grep,Glob,Bash,Agent" and val("--permission-mode") == "dontAsk"' || fail "tool set or permission mode wrong"
argv_check 'val("--output-format") == "json" and val("--model") == "opus[1m]" and val("--effort") == "high"' || fail "output/model/effort wrong"
argv_check 'val("--max-budget-usd") == "20"' || fail "default budget is not 20"
argv_check 's["permissions"]["allow"] == ["Bash(git ls-files:*)", "Bash(git check-ignore:*)"]' || fail "allow rules must be exactly the git commands that cannot print file contents"
argv_check 'set(["Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch"]) <= set(s["permissions"]["deny"])' || fail "write/network tools must be denied"
argv_check "set(['Read(/$H1R/.claude/settings*.json)', 'Read(/$H1R/.mcp*.json)', 'Read(/$H1R/mcp*.local.json)', 'Read(/$H1R/config/.local/**)', 'Read(/$H1R/.harness/**)']) <= set(s['permissions']['deny'])" || fail "secrets and earlier reports must be unreadable"
argv_check "set(['Read(/$H1R/**/.claude/settings*.json)', 'Read(/$H1R/**/.mcp*.json)', 'Read(/$H1R/**/.harness/**)']) <= set(s['permissions']['deny'])" || fail "nested secrets must be unreadable"
argv_check '"alwaysThinkingEnabled" not in s' || fail "high effort must not force thinking"
argv_check "sorted(vals('--add-dir')) == sorted(['$HOME_DIR/.claude/plugins', '$HOME_DIR/.claude/skills'])" || fail "--add-dir must list only existing ~/.claude config subdirectories"
argv_check '"--cwd" not in a and "--mcp-config" not in a and not any("bypass" in x.lower() for x in a) and "--allowedTools" not in a' || fail "forbidden argument present"
[[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == 1 ]] || fail "stdout must be exactly one status line: $out"
[[ "$out" == "checkup prompt-audit: ok report=$REPORTS/prompt-audit-"*".md cost_usd=1.25 duration_s=4.5 turns=7 denials=0" ]] || fail "unexpected status line: $out"
md="${out#*report=}"; md="${md%% cost_usd=*}"
[[ -f "$md" ]] || fail "report file missing: $md"
grep -Fq "$BODY" "$md" || fail "report file does not contain the result"
[[ -f "${md%.md}.json" ]] || fail "raw JSON missing"
[[ "$(stat -f '%Lp' "$md")" == 600 && "$(stat -f '%Lp' "${md%.md}.json")" == 600 ]] || fail "report files must be private"
[[ "$out$(cat "$TMP/a.err")" != *"$BODY"* ]] || fail "report content leaked to the terminal"
[[ ! -e "${md%.md}.stderr" ]] || fail "empty stderr capture must be removed"
echo "PASS: checkup prompt-audit runs restricted at the harness root and keeps the report inside it"

# --- A2: stderr and denials stay out of the terminal ---------------------------
out="$(CHECKUP_STUB_MODE=noisy run "$BIN_DIR/th" checkup prompt-audit 2>"$TMP/a2.err")" || fail "noisy checkup failed"
[[ "$out" == *" denials=2 stderr=$REPORTS/"*".stderr" ]] || fail "status must count denials and point at stderr: $out"
grep -Fq "STDERR-$BODY" "${out##*stderr=}" || fail "claude stderr not captured"
[[ "$out$(cat "$TMP/a2.err")" != *"STDERR-"* ]] || fail "claude stderr leaked to the terminal"
echo "PASS: checkup keeps Claude stderr in the harness and reports denial counts"

# --- A3: the interactive shell is left as it was --------------------------------
PATH="$STUB_BIN:/usr/bin:/bin" CHECKUP_TEST_LOG="$LOG" CHECKUP_TEST_BODY="$BODY" CHECKUP_TEST_PY="$PY" \
  HOME="$HOME_DIR" ROOT="$ROOT" H1R="$H1R" zsh -c '
  source "$ROOT/bin/aliases.zsh"
  um="$(umask)"; here="$PWD"
  _harness_launcher_run "$H1R" checkup prompt-audit >/dev/null 2>&1 || exit 10
  [[ "$(umask)" == "$um" ]] || exit 11
  [[ "$PWD" == "$here" ]] || exit 12
  [[ -z "${CHECKUP_LOCAL_ENV-}" && -z "${HARNESS_MODE_MODEL-}" && -z "${HARNESS_MODE_EFFORT-}" ]] || exit 13
' || fail "checkup changed the calling shell (code $?)"
echo "PASS: checkup leaves the calling shell's umask, cwd, and env unchanged"

# --- B: preset and budget ----------------------------------------------------
: > "$LOG"
run "$BIN_DIR/th" checkup prompt-audit rich --max-budget-usd 5 >/dev/null 2>&1 || fail "rich checkup failed"
argv_check 'val("--model") == "opus[1m]" and val("--effort") == "xhigh" and s.get("alwaysThinkingEnabled") is True and val("--max-budget-usd") == "5"' || fail "rich preset/budget not applied"
: > "$LOG"
HARNESS_CHECKUP_MAX_BUDGET_USD=7.5 run "$BIN_DIR/th" checkup prompt-audit >/dev/null 2>&1 || fail "env budget checkup failed"
argv_check 'val("--max-budget-usd") == "7.5"' || fail "HARNESS_CHECKUP_MAX_BUDGET_USD not applied"
echo "PASS: preset and budget overrides reach Claude"

# --- C: usage errors never start Claude -------------------------------------
: > "$LOG"
expect_rc 2 "bare checkup" run "$BIN_DIR/th" checkup
expect_rc 2 "unknown check" run "$BIN_DIR/th" checkup doctor
expect_rc 2 "unknown preset" run "$BIN_DIR/th" checkup prompt-audit nosuchpreset
expect_rc 2 "plan preset" run "$BIN_DIR/th" checkup prompt-audit plan
expect_rc 2 "two presets" run "$BIN_DIR/th" checkup prompt-audit opus rich
expect_rc 2 "path argument" run "$BIN_DIR/th" checkup prompt-audit /some/path
expect_rc 2 "non-numeric budget" run "$BIN_DIR/th" checkup prompt-audit --max-budget-usd abc
expect_rc 2 "zero budget" run "$BIN_DIR/th" checkup prompt-audit --max-budget-usd 0
expect_rc 2 "missing budget value" run "$BIN_DIR/th" checkup prompt-audit --max-budget-usd
[[ ! -s "$LOG" ]] || fail "a usage error started Claude"
echo "PASS: checkup usage errors exit 2 before launching Claude"

# --- D: failures -------------------------------------------------------------
before="$(ls "$REPORTS" | wc -l | tr -d ' ')"
CHECKUP_STUB_MODE=budget expect_rc 1 "budget stop" run "$BIN_DIR/th" checkup prompt-audit
grep -q '^checkup prompt-audit: failed (error_max_budget_usd) raw=.*\.json cost_usd=0.08 denials=0$' "$TMP/rc.out" || fail "budget failure line: $(cat "$TMP/rc.out")"
[[ "$(ls "$REPORTS" | wc -l | tr -d ' ')" == $((before + 1)) ]] || fail "a failed run without a result must keep only the raw JSON"
CHECKUP_STUB_MODE=crash expect_rc 3 "claude crash" run "$BIN_DIR/th" checkup prompt-audit
grep -q '^checkup prompt-audit: failed (exit 3) raw=.*\.json$' "$TMP/rc.out" || fail "crash failure line: $(cat "$TMP/rc.out")"
raw="$(sed 's/.*raw=//' "$TMP/rc.out")"
grep -Fqx 'not json' "$raw" || fail "raw output not preserved on crash"
CHECKUP_STUB_MODE=apierror expect_rc 1 "API error" run "$BIN_DIR/th" checkup prompt-audit
grep -q '^checkup prompt-audit: failed (error) raw=' "$TMP/rc.out" || fail "is_error result must read as an error: $(cat "$TMP/rc.out")"
echo "PASS: checkup failures keep raw output and exit non-zero"

# --- E: working-tree guard (informational) -------------------------------------
CHECKUP_STUB_MODE=write expect_rc 0 "tree changed" run "$BIN_DIR/th" checkup prompt-audit
[[ "$(cat "$TMP/rc.out")" == *" tree_changed=1" ]] || fail "status must carry tree_changed: $(cat "$TMP/rc.out")"
grep -q 'working tree changed during checkup (1 git status entries)' "$TMP/rc.err" || fail "guard warning missing: $(cat "$TMP/rc.err")"
! grep -q 'stray-file' "$TMP/rc.out" "$TMP/rc.err" || fail "guard must not print changed paths"
rm -f "$H1R/sub/stray-file" "$H1R/stray-file"
echo "PASS: checkup reports a working tree changed during the run"

# --- F: isolation --------------------------------------------------------------
: > "$LOG"
expect_rc 2 "explicit --isolated" run "$BIN_DIR/ti" --isolated checkup prompt-audit
HARNESS_SESSION_ISOLATION=1 expect_rc 2 "env isolation" run "$BIN_DIR/ti" checkup prompt-audit
expect_rc 2 "explicit --isolated-session" run "$BIN_DIR/ti" --isolated-session 123e4567-e89b-42d3-a456-426614174000 checkup prompt-audit
[[ ! -s "$LOG" ]] || fail "isolated checkup started Claude"
[[ -z "$(find "$TMP/state" -mindepth 1 -maxdepth 3 2>/dev/null | head -1)" ]] || fail "isolated checkup created session state"
run "$BIN_DIR/ti" checkup prompt-audit >/dev/null 2>&1 || fail "checkup on an isolation-default profile must run at the root"
echo "PASS: checkup refuses isolated sessions before cloning"

# --- G: harness-profile fan-out ------------------------------------------------
: > "$LOG"
out="$(run "$PREFIX/bin/harness-profile" checkup prompt-audit th tg --mode rich 2>"$TMP/g.err")" || { cat "$TMP/g.err" >&2; fail "fan-out failed"; }
[[ "$(grep '^PWD:' "$LOG" | tr '\n' '|')" == "PWD:$H1R|PWD:$H2R|" ]] || fail "fan-out order/cwd wrong: $(grep '^PWD:' "$LOG")"
argv_check 'val("--effort") == "xhigh"' || fail "--mode not forwarded"
[[ "$(printf '%s\n' "$out" | tail -1)" == "checkup prompt-audit: 2 ok, 0 failed" ]] || fail "fan-out summary: $out"
[[ "$out$(cat "$TMP/g.err")" != *"$BODY"* ]] || fail "fan-out leaked report content"
CHECKUP_STUB_FAIL_PWD="$H2R" expect_rc 1 "fan-out partial failure" run "$PREFIX/bin/harness-profile" checkup prompt-audit th tg
[[ "$(tail -1 "$TMP/rc.out")" == "checkup prompt-audit: 1 ok, 1 failed" ]] || fail "partial summary: $(cat "$TMP/rc.out")"
: > "$LOG"
run "$PREFIX/bin/harness-profile" checkup prompt-audit --all >/dev/null 2>&1 || fail "--all failed"
[[ "$(grep -c '^PWD:' "$LOG")" == 3 ]] || fail "--all did not run every registered profile"
: > "$LOG"
expect_rc 2 "unknown profile" run "$PREFIX/bin/harness-profile" checkup prompt-audit th zz
expect_rc 2 "no selection" run "$PREFIX/bin/harness-profile" checkup prompt-audit
expect_rc 2 "--all with names" run "$PREFIX/bin/harness-profile" checkup prompt-audit --all th
expect_rc 2 "unknown check" run "$PREFIX/bin/harness-profile" checkup doctor --all
expect_rc 2 "bad --mode" run "$PREFIX/bin/harness-profile" checkup prompt-audit th tg --mode plan
expect_rc 2 "bad budget" run "$PREFIX/bin/harness-profile" checkup prompt-audit th tg --max-budget-usd 0
expect_rc 2 "two --mode" run "$PREFIX/bin/harness-profile" checkup prompt-audit th --mode rich --mode fast
ln -s "$(readlink "$BIN_DIR/th")" "$BIN_DIR/zz"
expect_rc 2 "unregistered profile command" run "$BIN_DIR/zz" checkup prompt-audit th
rm -f "$BIN_DIR/zz"
[[ ! -s "$LOG" ]] || fail "fan-out validation started Claude"
run "$PREFIX/bin/harness-profile" checkup prompt-audit th --max-budget-usd=5 >/dev/null 2>&1 || fail "--max-budget-usd=N fan-out failed"
argv_check 'val("--max-budget-usd") == "5"' || fail "--max-budget-usd=N not forwarded"
: > "$LOG"
run "$PREFIX/bin/harness-profile" checkup prompt-audit th th >/dev/null 2>&1 || fail "duplicate profile run failed"
[[ "$(grep -c '^PWD:' "$LOG")" == 1 ]] || fail "duplicate profile names must run once"
echo "PASS: harness-profile checkup runs profiles one at a time and reports only status"

# --- H: reserved prefixes --------------------------------------------------------
for reserved in checkup register; do
  H4="$HOME_DIR/work/reserved-$reserved"; make_harness "$H4" "$reserved"
  if HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" "$PREFIX/bin/harness-profile" register "$H4" >/dev/null 2>"$TMP/h.err"; then
    fail "register accepted reserved prefix $reserved"
  fi
  grep -q 'reserved' "$TMP/h.err" || fail "reserved prefix error not explained"
done
echo "PASS: harness-profile rejects reserved prefixes"
