#!/usr/bin/env bash
# harness-headless: non-interactive isolated run, delivery, and result contract.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PREFIX="$TMP/prefix"
STUB="$TMP/stub"
SOURCE="$TMP/harness"
REMOTE="$TMP/remote.git"
STATE="$TMP/state"
FAKE_HOME="$TMP/home"
PROFILES="$TMP/profiles"
RESULT="$TMP/out/result.json"
LOCK="$TMP/run.lock"
PROMPT="$TMP/prompt.txt"
mkdir -p "$STUB" "$FAKE_HOME" "$PROFILES/profiles" "$TMP/out" "$SOURCE/config" "$SOURCE/core/bin" "$SOURCE/projects/product" "$SOURCE/.claude"

bash "$ROOT/test/lib/install-runtime-fixture.sh" "$ROOT" "$PREFIX"

git init -q --bare -b main "$REMOTE"
git -C "$SOURCE" init -q -b main
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" config user.name test
printf '%s\n' 'HARNESS_NAME="headless"' 'HARNESS_PREFIX="hh"' > "$SOURCE/config/launcher.env"
printf '%s\n' 'github_user: tester' > "$SOURCE/config/config.yaml"
printf '%s\n' tracked > "$SOURCE/tracked.txt"
printf '%s\n' '.claude/settings.local.json' 'mcp.local.json' > "$SOURCE/.gitignore"
printf '%s\n' base > "$SOURCE/projects/keep.txt"
printf '%s\n' base > "$SOURCE/projects/drop.txt"
cat > "$SOURCE/core/bin/auto-deliver.sh" <<EOF
#!/usr/bin/env bash
# Reports the environment the repository verifier runs with on stdout (the
# broker log): headless verifiers are sandboxed and can only write their
# candidate and temp dir. Like kh's auto-deliver, it runs the candidate's tests.
printf 'VERIFIER-ENV TMPDIR=%s CLAUDE_CODE_TMPDIR=%s\n' "\${TMPDIR:-}" "\${CLAUDE_CODE_TMPDIR:-}"
[[ ! -s "$TMP/run-tmp" || ! -e "\$(cat "$TMP/run-tmp")" ]] || echo 'VERIFIER-ENV RUN_TMP_PRESENT'
env | grep -E '^(SSH_AUTH_SOCK|GH_|GITHUB_|[A-Z_]*_TOKEN=)' | sed 's/^/VERIFIER-LEAK /'
[[ ! -e "$TMP/verify-fail" ]] || exit 92
for t in "\$TEST_HARNESS_DIR"/verify-tests/*.sh; do
  [[ -e "\$t" ]] || continue
  bash "\$t" || exit 93
done
EOF
chmod +x "$SOURCE/core/bin/auto-deliver.sh"
git -C "$SOURCE" add . && git -C "$SOURCE" commit -qm initial
git -C "$SOURCE" remote add origin "$REMOTE"
git -C "$SOURCE" push -q origin main
printf '%s\n' '{"env":{"LOCAL_SETTINGS_SECRET":"leak-local"}}' > "$SOURCE/.claude/settings.local.json"
printf '%s\n' '{"mcpServers":{"docs":{"command":"echo"}}}' > "$SOURCE/.mcp.local.json"
printf '%s\n' '{"mcpServers":{"local":{"command":"echo"}}}' > "$SOURCE/mcp.local.json"
SOURCE_REAL="$(cd "$SOURCE" && pwd -P)"
printf '%s\n' "$SOURCE" > "$PROFILES/profiles/hh"

cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "auth token --user tester" ]] && echo gh-token-leak
EOF
# Test control travels through files: harness-headless clears the environment.
cat > "$STUB/claude" <<EOF
#!/usr/bin/env bash
printf '%s\0' "\$@" > "$TMP/claude-argv"
env > "$TMP/claude-env"
printf '%s\n' "\${CLAUDE_CODE_TMPDIR:-}" > "$TMP/run-tmp"
stat -f '%Lp %u' "\${CLAUDE_CODE_TMPDIR:-/nonexistent}" > "$TMP/claude-tmpdir-stat" 2>/dev/null
printf '%s\n' "\$PWD" > "$TMP/claude-pwd"
cat > "$TMP/claude-stdin"
mode="\$(cat "$TMP/mode")"
sid=11111111-2222-4333-8444-555555555555
ok='{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.12,"num_turns":3,"result":"done: summary","session_id":"'\$sid'"}'
case "\$mode" in
  change)
    printf 'headless %s\n' "\$\$" > headless-change.txt
    project="\$HOME/.claude/projects/\$(printf '%s' "\$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "\$project" && : > "\$project/\$sid.jsonl"
    echo "\$ok" ;;
  none)
    # Claude output that mimics a launcher refusal must not change the status.
    echo 'harness-session: headless clone refused: symlink at x' >&2
    echo "\$ok" ;;
  commit)
    printf 'committed %s\n' "\$\$" > committed.txt
    git add committed.txt && git -c user.name=t -c user.email=t@example.invalid commit -qm agent
    printf 'uncommitted %s\n' "\$\$" > uncommitted.txt
    echo "\$ok" ;;
  excluded)
    printf '{"env":{"PLANTED":"x"}}\n' > .claude/settings.local.json
    mkdir -p config/.local projects && printf 'x\n' > config/.local/planted && printf 'x\n' > projects/planted
    printf 'normal %s\n' "\$\$" > normal.txt
    git add -f .claude/settings.local.json config/.local/planted projects/planted normal.txt
    git -c user.name=t -c user.email=t@example.invalid commit -qm planted
    echo "\$ok" ;;
  variants)
    # One table row: <expect>|<kind>|<path>. The canonical excluded entries are
    # removed first so the variant is created under its own spelling, and the
    # path is negated in .gitignore so only the launcher's fence stands.
    rm -rf projects config/.local mcp.local.json .mcp.local.json .claude/settings.local.json
    while IFS='|' read -r expect kind path; do
      [[ -n "\$kind" ]] || continue
      printf '!/%s\n' "\$path" >> .gitignore
      case "\$kind" in
        file) mkdir -p "\$(dirname "\$path")"; printf 'variant\n' > "\$path" ;;
        dir) mkdir -p "\$path"; printf 'variant\n' > "\$path/a" ;;
        link) mkdir -p projects; ln -s projects "\$path"; printf 'through-link\n' > "\$path/x" ;;
      esac
    done < "$TMP/variants"
    printf 'normal %s\n' "\$\$" > variants-normal.txt
    echo "\$ok" ;;
  casevariants)
    # Negations override info/exclude; case variants dodge case-sensitive
    # pathspecs. None of these may be delivered.
    printf '%s\n' '!/Projects' '!/PROJECTS' '!/config/.LOCAL' '!/.claude/Settings.Local.json' '!/MCP.local.json' '!/.MCP.Local.json' >> .gitignore
    mkdir -p PROJECTS config/.LOCAL .claude
    printf 'v\n' > PROJECTS/variant.txt
    printf 'v\n' > config/.LOCAL/variant.txt
    printf '{"v":1}\n' > .claude/Settings.Local.json
    printf '{"v":1}\n' > MCP.local.json
    printf '{"v":1}\n' > .MCP.Local.json
    printf 'normal %s\n' "\$\$" > casevariants-normal.txt
    echo "\$ok" ;;
  trackedexcluded)
    printf 'agent edit\n' > projects/keep.txt
    rm projects/drop.txt
    printf 'normal %s\n' "\$\$" > trackedexcluded-normal.txt
    echo "\$ok" ;;
  nested)
    printf 'edit %s\n' "\$\$" > nested-edit.txt
    git init -q sub
    echo "\$ok" ;;
  unreadable)
    printf 'edit %s\n' "\$\$" > unreadable-edit.txt
    printf 'x\n' > locked.txt && chmod 000 locked.txt
    echo "\$ok" ;;
  linger)
    printf 'linger %s\n' "\$\$" > linger.txt
    # Outside claude's process group, cwd in the session root.
    perl -e 'use POSIX; POSIX::setsid(); exec @ARGV' sleep 300 > /dev/null 2>&1 &
    echo \$! > "$TMP/linger.pid"
    # Another one parked in the run's private temp base.
    (cd "\$CLAUDE_CODE_TMPDIR" && exec perl -e 'use POSIX; POSIX::setsid(); exec @ARGV' sleep 300 > /dev/null 2>&1) &
    echo \$! > "$TMP/linger-tmp.pid"
    echo "\$ok" ;;
  breach)
    printf 'breach %s\n' "\$\$" > breach-normal.txt
    mkdir -p verify-tests && cp "$TMP/breach.sh" verify-tests/breach.sh
    echo "\$ok" ;;
  okverify)
    printf 'okverify %s\n' "\$\$" > okverify.txt
    mkdir -p verify-tests && cp "$TMP/okverify.sh" verify-tests/ok.sh
    echo "\$ok" ;;
  conflict)
    printf 'session %s\n' "\$\$" > tracked.txt
    # Meanwhile main changes the same line.
    rm -rf "$TMP/conflict-clone" && git clone -q "$REMOTE" "$TMP/conflict-clone"
    printf 'remote %s\n' "\$\$" > "$TMP/conflict-clone/tracked.txt"
    git -C "$TMP/conflict-clone" -c user.name=t -c user.email=t@example.invalid commit -qam remote
    git -C "$TMP/conflict-clone" push -q origin HEAD:main
    echo "\$ok" ;;
  gitcfgonly)
    printf '[filter "evil"]\n\tclean = touch %s\n' "$TMP/filter-ran" >> .git/config
    echo "\$ok" ;;
  gitcfg)
    printf 'tamper %s\n' "\$\$" > tamper.txt
    printf '* filter=evil\n' > .gitattributes
    printf '[core]\n\tfsmonitor = touch %s\n[filter "evil"]\n\tclean = touch %s\n' "$TMP/fsmonitor-ran" "$TMP/filter-ran" >> .git/config
    echo "\$ok" ;;
  budget) echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":2.01,"num_turns":9,"session_id":"'\$sid'"}'; exit 1 ;;
  error) echo '{"type":"result","subtype":"error_during_execution","is_error":true,"total_cost_usd":0.5,"num_turns":2,"result":"boom","session_id":"'\$sid'"}'; exit 1 ;;
  hang)
    sleep 300 & echo \$! > "$TMP/grandchild.pid"
    echo \$\$ > "$TMP/child.pid"
    wait ;;
  wait)
    : > "$TMP/started"
    while [[ ! -e "$TMP/release" ]]; do sleep 0.05; done
    echo "\$ok" ;;
esac
EOF
chmod +x "$STUB/gh" "$STUB/claude"
printf '%s\n' 'Fix the typo.' > "$PROMPT"
printf '%s\n' '{"_note":"bridge policy","permissions":{"deny":["Read(//secret/**)"]},"sandbox":{"filesystem":{"denyRead":["/secret"]},"network":{"allowedDomains":["example.com"]}}}' > "$TMP/caller-settings.json"

headless() {
  rm -f "$TMP/claude-argv" "$TMP/claude-env" "$TMP/claude-pwd"
  ${HEADLESS_EXEC:+exec} env -i PATH="$TMP/failgit:$STUB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$FAKE_HOME" TMPDIR="$TMP" \
    HARNESS_PROFILE_HOME="$PROFILES" HARNESS_SESSION_STATE_HOME="$STATE" \
    ANTHROPIC_API_KEY=leak-api BUZZ_TOKEN=leak-buzz TELEGRAM_BOT_TOKEN=leak-telegram \
    "$PREFIX/bin/harness-headless" hh --prompt-file "$PROMPT" --result-file "$RESULT" \
    --lock-file "$LOCK" --budget-usd 2 --timeout-min "${TIMEOUT_MIN:-1}" "$@"
}
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print("null" if v is None else v)' "$RESULT" "$1"; }
# On failure, print the result and the launcher/Claude/broker log next to it.
fail() {
  echo "FAIL: $*" >&2
  [[ -f "$RESULT" ]] && { sed 's/^/  /' "$RESULT"; echo; } >&2
  [[ -f "$RESULT.log" ]] && { echo "  --- $RESULT.log" >&2; sed 's/^/  | /' "$RESULT.log" >&2; }
  exit 1
}
expect_status() { [[ "$(field status)" == "$1" && "$(field version)" == 1 ]] || fail "expected status $1 (version 1)"; }

# --- delivered -----------------------------------------------------------------
echo change > "$TMP/mode"
headless --settings-file "$TMP/caller-settings.json" --model sonnet || fail 'delivered run must exit 0'
expect_status delivered
sid="$(field session_id)"
[[ "$sid" =~ ^[0-9A-Fa-f-]{36}$ ]] || fail 'delivered result must name the launcher session'
[[ "$(field commit)" == "$(git --git-dir="$REMOTE" rev-parse main)" ]] || fail 'commit must be the delivered remote SHA'
git --git-dir="$REMOTE" show main:headless-change.txt >/dev/null || fail 'change must reach the remote'
grep -qx state=DELIVERED "$STATE/sessions/$sid/journal" || fail 'session must be DELIVERED'
[[ "$(field cost_usd)" == 0.12 && "$(field num_turns)" == 3 && "$(field summary)" == 'done: summary' && "$(field exit_code)" == 0 ]] || fail 'claude metadata must be copied'
session_root="$STATE/worktrees/$sid"
[[ "$(cat "$TMP/claude-pwd")" == "$session_root" ]] || fail "claude must run in the session root, got $(cat "$TMP/claude-pwd")"
[[ "$(field transcript)" == "$FAKE_HOME/.claude/projects/"*"/11111111-2222-4333-8444-555555555555.jsonl" ]] || fail 'transcript path must be reported'
[[ ! -L "$session_root/projects" && ! -L "$session_root/.claude/settings.local.json" && ! -L "$session_root/mcp.local.json" ]] || fail 'headless session must not link back to the source'
[[ "$(cat "$TMP/claude-stdin")" == 'Fix the typo.' ]] || fail 'the prompt must reach claude on stdin'
run_tmp="$(sed -n 's/^CLAUDE_CODE_TMPDIR=//p' "$TMP/claude-env")"
[[ "$run_tmp" == /private/tmp/hh-* && "$run_tmp" != /private/tmp/claude-* ]] || fail "claude must get a private short temp base, got '$run_tmp'"
grep -qx "TMPDIR=$run_tmp" "$TMP/claude-env" || fail 'TMPDIR must be the same private temp base'
[[ "$(cat "$TMP/claude-tmpdir-stat")" == "700 $(id -u)" ]] || fail 'the temp base must be 0700 and owned by the user'
[[ ! -e "$run_tmp" ]] || fail 'the temp base must be removed after the run'
python3 - "$TMP/claude-argv" "$SOURCE_REAL" "$FAKE_HOME" "$session_root" "$run_tmp" "$(id -u)" <<'PY' || fail 'claude argv contract'
import json, sys
argv = open(sys.argv[1]).read().split('\0')[:-1]
source, home, root, tmp, uid = sys.argv[2:]
assert argv.count('--settings') == 1, argv
assert '--strict-mcp-config' in argv and '--mcp-config' not in argv, argv
for a, b in (('--output-format', 'json'), ('--max-budget-usd', '2'), ('--permission-mode', 'acceptEdits'), ('--model', 'sonnet')):
    assert argv[argv.index(a) + 1] == b, (a, argv)
assert 'bypassPermissions' not in argv and '-p' in argv and 'Fix the typo.\n' not in argv and '--' not in argv, argv
settings = json.loads(argv[argv.index('--settings') + 1])
assert settings['disableAllHooks'] is True and settings['disableBypassPermissionsMode'] == 'disable', settings
deny = settings['permissions']['deny']
homes = ['%s/%s' % (home, d) for d in ('.hermes', 'buzz', '.ssh', '.config/gh', '.aws', '.claude')]
sandbox = settings['sandbox']
fs = sandbox['filesystem']
assert sandbox['enabled'] is True and sandbox['failIfUnavailable'] is True, sandbox
assert sandbox['allowUnsandboxedCommands'] is False and sandbox['autoAllowBashIfSandboxed'] is True, sandbox
assert sandbox['network'] == {'strictAllowlist': True, 'allowedDomains': ['example.com']}, sandbox
assert set(fs['denyRead']) == set(homes + [source, '/secret']), fs
assert fs['allowWrite'] == [tmp], fs
git = root + '/.git'
assert set(fs['denyWrite']) >= {git + '/config', git + '/hooks', git + '/info', '/private/tmp/claude-' + uid, '/tmp/claude-' + uid}, fs
assert set(sandbox) == {'enabled', 'failIfUnavailable', 'allowUnsandboxedCommands', 'autoAllowBashIfSandboxed', 'network', 'filesystem'}, sandbox
# Gate parity: every sandbox read deny is a Read deny, and both read- and
# write-denied paths are closed to the edit tools.
for path in fs['denyRead']:
    assert 'Read(/%s/**)' % path in deny, ('Read', path)
for path in fs['denyRead'] + [home + '/Library/LaunchAgents']:
    for tool in ('Edit', 'Write', 'NotebookEdit'):
        assert '%s(/%s/**)' % (tool, path) in deny, (tool, path)
for tool in ('Edit', 'Write', 'NotebookEdit'):
    for rule in ('%s(/%s/config)', '%s(/%s/hooks/**)', '%s(/%s/info/**)'):
        assert rule % (tool, git) in deny, (rule, tool)
rules = ['WebFetch', 'WebSearch', 'Bash(hermes:*)', 'Bash(buzz:*)', 'Bash(rm -rf:*)']
rules += ['Bash(*%s*)' % w for w in ('harness-session', 'session-isolation.sh', 'auto-deliver', 'git push', 'sudo', 'launchctl')]
for rule in rules:
    assert rule in deny, (rule, deny)
assert 'Bash(*buzz*)' not in deny and 'Bash(*hermes*)' not in deny, deny
PY
# Merge order: the launcher's settings merge is last-wins for scalars, so the
# mandatory block (passed last) beats any weaker earlier --settings.
python3 - "$ROOT/bin" "$SOURCE" "$FAKE_HOME" <<'PY' || fail 'mandatory settings must win the launcher merge'
import importlib.util, json, sys
bin_dir, source, home = sys.argv[1:]
sys.path.insert(0, bin_dir)
import harness_headless
spec = importlib.util.spec_from_file_location('policy', bin_dir + '/slack-approval-policy.py')
policy = importlib.util.module_from_spec(spec); spec.loader.exec_module(policy)
weak = {'sandbox': {'enabled': False, 'failIfUnavailable': False, 'allowUnsandboxedCommands': True,
                    'network': {'strictAllowlist': False}}, 'permissions': {'deny': []},
        'disableAllHooks': False, 'disableBypassPermissionsMode': 'enable'}
mandatory = harness_headless.mandatory_settings(source, home, [])
argv = policy.claude_argv(['--settings', json.dumps(weak), '--settings', json.dumps(mandatory), '-p'])
merged = json.loads(argv[argv.index('--settings') + 1])
sandbox = merged['sandbox']
assert sandbox['enabled'] is True and sandbox['failIfUnavailable'] is True, sandbox
assert sandbox['allowUnsandboxedCommands'] is False and sandbox['network']['strictAllowlist'] is True, sandbox
assert merged['disableAllHooks'] is True and merged['disableBypassPermissionsMode'] == 'disable', merged
assert set(mandatory['permissions']['deny']) <= set(merged['permissions']['deny'])
PY
for leak in leak-api leak-buzz leak-telegram leak-local gh-token-leak; do
  ! grep -q "$leak" "$TMP/claude-env" || fail "secret $leak reached the claude environment"
done
! grep -q '^GH_TOKEN=' "$TMP/claude-env" || fail 'GH_TOKEN must not be exported in headless runs'
echo 'PASS: harness-headless delivers through the broker with merged denies and a clean environment'

# --- no_changes -----------------------------------------------------------------
echo none > "$TMP/mode"
headless || fail 'no_changes run must exit 0'
expect_status no_changes
grep -qx state=CLOSED "$STATE/sessions/$(field session_id)/journal" || fail 'clean session must close'
[[ "$(field commit)" == null ]] || fail 'no_changes has no commit'
echo 'PASS: harness-headless reports no_changes for a clean session'

# --- committed work, session git payloads, excluded paths, lingering processes ------
echo commit > "$TMP/mode"
headless || fail 'commit run must exit 0'
expect_status delivered
git --git-dir="$REMOTE" show main:committed.txt >/dev/null || fail 'committed agent work must be delivered'
git --git-dir="$REMOTE" show main:uncommitted.txt >/dev/null || fail 'uncommitted agent work must be delivered with it'
echo gitcfg > "$TMP/mode"
headless || fail 'git payload run must exit 0'
expect_status delivered
[[ ! -e "$TMP/fsmonitor-ran" && ! -e "$TMP/filter-ran" ]] || fail 'session git config and attribute payloads must never run'
git --git-dir="$REMOTE" show main:tamper.txt >/dev/null || fail 'work-tree content is still delivered'
echo gitcfgonly > "$TMP/mode"
headless || fail 'config-only run must exit 0'
expect_status no_changes
[[ ! -e "$TMP/filter-ran" ]] || fail 'a repo-config filter must not run'
echo excluded > "$TMP/mode"
headless || fail 'excluded-path run must exit 0'
expect_status delivered
git --git-dir="$REMOTE" show main:normal.txt >/dev/null || fail 'normal committed paths must be delivered'
for excluded in .claude/settings.local.json config/.local/planted projects/planted; do
  ! git --git-dir="$REMOTE" cat-file -e "main:$excluded" 2>/dev/null || fail "excluded $excluded was delivered"
done
echo linger > "$TMP/mode"
rm -f "$TMP/linger.pid"
headless || fail 'linger run must exit 0'
expect_status delivered
[[ -s "$TMP/linger.pid" ]] || fail 'linger process did not start'
! kill -0 "$(cat "$TMP/linger.pid")" 2>/dev/null || fail 'a process left in the session root must be killed before delivery'
[[ -s "$TMP/linger-tmp.pid" ]] && ! kill -0 "$(cat "$TMP/linger-tmp.pid")" 2>/dev/null || fail 'a process left in the run temp base must be killed before delivery'
grep -q '^VERIFIER-ENV TMPDIR=' "$RESULT.log" || fail 'the repository verifier did not run'
! grep -q '^VERIFIER-ENV TMPDIR=/private/tmp/hh-' "$RESULT.log" || fail 'broker git and the verifier must not use the run temp base'
! grep -q '^VERIFIER-ENV .*CLAUDE_CODE_TMPDIR=[^ ]' "$RESULT.log" || fail 'the broker env must not carry CLAUDE_CODE_TMPDIR'
! grep -q '^VERIFIER-ENV RUN_TMP_PRESENT' "$RESULT.log" || fail 'the run temp base must be removed before delivery starts'
verifier_tmp="$(sed -n 's/^VERIFIER-ENV TMPDIR=\([^ ]*\) .*/\1/p' "$RESULT.log" | tail -n 1)"
[[ "$verifier_tmp" == */verifier-tmp.* && ! -e "$verifier_tmp" ]] || fail "the verifier must get its own temp dir, removed afterwards (got '$verifier_tmp')"
echo trackedexcluded > "$TMP/mode"
headless || fail 'tracked excluded run must exit 0'
expect_status delivered
git --git-dir="$REMOTE" show main:trackedexcluded-normal.txt >/dev/null || fail 'normal paths beside an excluded edit must be delivered'
[[ "$(git --git-dir="$REMOTE" show main:projects/keep.txt)" == base ]] || fail 'an edit to a tracked file under an excluded path must not be delivered'
[[ "$(git --git-dir="$REMOTE" show main:projects/drop.txt)" == base ]] || fail 'a deletion under an excluded path must not be delivered'
for local_file in .claude/settings.local.json mcp.local.json .mcp.local.json; do
  ! git --git-dir="$REMOTE" cat-file -e "main:$local_file" 2>/dev/null || fail "gitignored local file $local_file reached the remote"
done
echo casevariants > "$TMP/mode"
headless || fail 'case-variant run must exit 0'
expect_status delivered
git --git-dir="$REMOTE" show main:casevariants-normal.txt >/dev/null || fail 'normal paths beside case variants must be delivered'
leaked="$(git --git-dir="$REMOTE" ls-tree -r --name-only main | grep -iE '^(config/\.local/|\.claude/settings\.local\.json$|\.?mcp\.local\.json$|projects/)' | grep -vx -e projects/keep.txt -e projects/drop.txt || true)"
[[ -z "$leaked" ]] || fail "case variants of excluded paths were delivered: $leaked"
for kept in keep.txt drop.txt; do
  [[ "$(git --git-dir="$REMOTE" show "main:projects/$kept")" == base ]] || fail "projects/$kept changed through a case variant"
done
echo 'PASS: harness-headless delivers the work tree through a launcher-owned git dir'

# --- every exclusion layer agrees: table of path variants -----------------------
# excluded: aliases an excluded entry on this filesystem (case, Unicode case
# folding) and must not reach the remote. distinct: a different name on APFS
# and in git, delivered as its own path. link: a symlink into projects/ is
# delivered as the link itself, never as content under projects/.
{
  printf '%s\n' 'excluded|dir|Projects' 'excluded|file|PROJECTS' 'excluded|dir|config/.LOCAL' \
    'excluded|file|config/.local' 'excluded|file|.claude/SETTINGS.local.json' 'excluded|file|MCP.local.json' \
    'excluded|file|.Mcp.Local.json' 'distinct|dir|projects.' 'distinct|dir|projects ' 'link|link|plink'
  printf 'excluded|dir|project\xc5\xbf\n'                      # projectſ (U+017F folds to s)
  printf 'excluded|file|mcp.local.j\xc5\xbfon\n'                # mcp.local.jſon
  printf 'excluded|file|.claude/\xc5\xbfettings.local.json\n'   # .claude/ſettings.local.json
} > "$TMP/variant-table"
echo variants > "$TMP/mode"
while IFS= read -r row; do
  printf '%s\n' "$row" > "$TMP/variants"
  headless || fail "variant run must exit 0: $row"
  expect_status delivered
  git --git-dir="$REMOTE" show main:variants-normal.txt >/dev/null || fail "normal paths beside $row must be delivered"
  git --git-dir="$REMOTE" ls-tree -r --name-only -z main > "$TMP/main-paths"
  python3 - "$TMP/variants" "$TMP/main-paths" "$TMP/probe" <<'PY' || fail "an exclusion layer disagreed on: $row"
import os, sys
rows = [l.split(b'|', 2) for l in open(sys.argv[1], 'rb').read().split(b'\n') if l]
main = set(open(sys.argv[2], 'rb').read().split(b'\0')) - {b''}
# Filesystem truth: does a path alias an excluded entry on this volume?
probe = sys.argv[3].encode()
for d in (b'projects', b'config/.local', b'.claude'):
    os.makedirs(os.path.join(probe, d), exist_ok=True)
for f in (b'mcp.local.json', b'.mcp.local.json', b'.claude/settings.local.json'):
    open(os.path.join(probe, f), 'a').close()
leaves = [os.path.join(probe, e) for e in (b'projects', b'config/.local', b'mcp.local.json', b'.mcp.local.json', b'.claude/settings.local.json')]
def aliases(path):
    parts = path.split(b'/')
    for depth in (1, 2):
        if len(parts) < depth:
            break
        candidate = os.path.join(probe, *parts[:depth])
        if os.path.lexists(candidate) and any(os.path.samefile(candidate, l) for l in leaves):
            return True
    return False
base = {b'projects/keep.txt', b'projects/drop.txt'}
leaked = sorted(p for p in main if aliases(p) and p not in base)
assert not leaked, ('excluded content delivered', leaked)
for expect, kind, path in rows:
    if expect == b'excluded':
        assert path not in main and path + b'/a' not in main, ('excluded variant delivered', path)
    if expect == b'distinct':
        assert path + b'/a' in main, ('distinct name must be delivered', path)
    if expect == b'link':
        assert path in main and path + b'/x' not in main, ('symlink must be delivered as itself', path)
PY
  for kept in keep.txt drop.txt; do
    [[ "$(git --git-dir="$REMOTE" show "main:projects/$kept")" == base ]] || fail "projects/$kept changed through $row"
  done
done < "$TMP/variant-table"
[[ "$(git --git-dir="$REMOTE" ls-tree main plink | awk '{print $1}')" == 120000 ]] || fail 'plink must be delivered as a symlink'
! git --git-dir="$REMOTE" cat-file -e main:projects/x 2>/dev/null || fail 'content written through a symlink into projects/ was delivered'
echo 'PASS: every exclusion layer agrees on case, Unicode folding, file/dir forms, trailing dots and symlinks'

# --- a failed stage is never reported as no_changes -------------------------------
for mode in nested unreadable; do
  echo "$mode" > "$TMP/mode"
  remote_before="$(git --git-dir="$REMOTE" rev-parse main)"
  headless || fail "$mode run must exit 0"
  expect_status failed
  [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_before" ]] || fail "$mode run must deliver nothing"
  [[ "$(field session_id)" != null ]] && grep -qv state=CLOSED "$STATE/sessions/$(field session_id)/journal" || fail "$mode session must be kept"
done
echo 'PASS: harness-headless fails closed when the work tree cannot be staged'

# --- a broker git error is never read as "nothing to exclude" or "no changes" -----
# The git on PATH fails calls matching the pattern in $TMP/fail-git (the
# launcher's environment allowlist drops anything else).
mkdir -p "$TMP/failgit"
cat > "$TMP/failgit/git" <<EOF
#!/bin/bash
pattern="\$(cat "$TMP/fail-git" 2>/dev/null)"
if [[ -n "\$pattern" && " \$* " == *"\$pattern"* ]]; then echo "injected git failure: \$pattern" >&2; exit 128; fi
exec "$(command -v git)" "\$@"
EOF
chmod +x "$TMP/failgit/git"
echo variants > "$TMP/mode"
printf 'excluded|dir|project\xc5\xbf\n' > "$TMP/variants"
for pattern in '--name-only --no-renames -z' '--cached --quiet' '--name-status' 'ls-tree'; do
  printf '%s' "$pattern" > "$TMP/fail-git"
  remote_before="$(git --git-dir="$REMOTE" rev-parse main)"
  headless || fail "run with failing git '$pattern' must exit 0"
  expect_status failed
  [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_before" ]] || fail "run with failing git '$pattern' must deliver nothing"
  ! grep -qx state=CLOSED "$STATE/sessions/$(field session_id)/journal" || fail "session with failing git '$pattern' must be kept"
done
rm -f "$TMP/fail-git"
echo 'PASS: harness-headless fails closed when broker git fails'

# --- an INTEGRATING journal after close is recovered once, whatever the exit code --
python3 - "$ROOT/bin" "$TMP/m1" <<'PY' || fail 'INTEGRATING after close must be recovered'
import os, sys, types
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import harness_headless as h
state, sid = Path(sys.argv[2]), '11111111-2222-4333-8444-555555555555'
d = state / 'sessions' / sid
d.mkdir(parents=True)
journal = lambda s: (d / 'journal').write_text('state=%s\nidentity=\nheartbeat=x\n' % s)
journal('ABANDONED')
calls = []
def run(cmd, **kw):
    calls.append(cmd[1])
    if cmd[1] == 'close':
        journal('INTEGRATING'); return types.SimpleNamespace(returncode=128)
    if cmd[1] == 'recover' and len(calls) > 1:
        (d / 'delivered-sha').write_text('a' * 40 + '\n'); journal('DELIVERED')
    return types.SimpleNamespace(returncode=0)
h.subprocess.run = run
assert h.deliver(sid, state, {}, '/', None) == ('delivered', 'a' * 40, None), calls
assert calls == ['recover', 'close', 'recover'], calls
PY
echo 'PASS: harness-headless recovers an INTEGRATING session once after close'

# --- budget / failed --------------------------------------------------------------
echo budget > "$TMP/mode"
headless || fail 'budget run must exit 0'
expect_status budget
[[ "$(field cost_usd)" == 2.01 && "$(field session_id)" != null ]] || fail 'budget result must keep cost and session'
echo error > "$TMP/mode"
headless || fail 'failed run must exit 0'
expect_status failed
[[ "$(field summary)" == boom && "$(field exit_code)" == 1 ]] || fail 'failed result must keep the claude result and exit code'
echo 'PASS: harness-headless maps budget and error results'

# --- conflict -----------------------------------------------------------------------
echo conflict > "$TMP/mode"
headless || fail 'conflict run must exit 0'
expect_status conflict
grep -qx state=CONFLICT "$STATE/sessions/$(field session_id)/journal" || fail 'conflict session must be left for the owner'
echo 'PASS: harness-headless reports conflict and leaves the session'

# --- a verifier rejection is a failure, not a conflict ------------------------------
echo change > "$TMP/mode"
: > "$TMP/verify-fail"
remote_before="$(git --git-dir="$REMOTE" rev-parse main)"
headless || fail 'verifier-rejected run must exit 0'
rm -f "$TMP/verify-fail"
expect_status failed
[[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_before" ]] || fail 'a rejected candidate must not be delivered'
grep -q 'verifier' "$RESULT" || fail 'a verifier rejection must say so'
! grep -qx -e state=CLOSED -e state=DELIVERED "$STATE/sessions/$(field session_id)/journal" || fail 'a rejected session must be kept'
echo 'PASS: harness-headless reports a verifier rejection as failed and keeps the session'

# --- the verifier runs agent-written tests in a sandbox -----------------------------
mkdir -p "$FAKE_HOME/.ssh"; printf 'fixture-private-key\n' > "$FAKE_HOME/.ssh/id_fixture"
cat > "$TMP/breach.sh" <<'EOF'
#!/bin/bash
# An agent-written test that reaches for the network, HOME, ~/.ssh, the
# keychain and git credentials. It "passes" only if it got everything.
python3 - <<'PY'
import errno, os, socket
home = os.environ['HOME']
def probe(name, f):
    try:
        f()
        print(f'PROBE {name} ALLOWED')
    except OSError as e:
        print(f'PROBE {name} {errno.errorcode.get(e.errno, e.errno)}')
probe('network', lambda: socket.create_connection(('1.1.1.1', 443), timeout=5).close())
probe('write-home', lambda: open(os.path.join(home, 'breach-wrote-home'), 'w').close())
probe('read-ssh', lambda: open(os.path.join(home, '.ssh', 'id_fixture')).read())
PY
if security find-generic-password -s harness-breach-probe -w >/dev/null 2>&1; then echo 'PROBE security ALLOWED'; else echo 'PROBE security blocked'; fi
if printf 'protocol=https\nhost=example.invalid\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill >/dev/null 2>&1; then
  echo 'PROBE git-credential ALLOWED'
else
  echo 'PROBE git-credential blocked'
fi
exit 1
EOF
# Control: outside the sandbox the same test reaches HOME and ~/.ssh.
control="$(HOME="$FAKE_HOME" bash "$TMP/breach.sh" 2>&1 || true)"
grep -q 'PROBE write-home ALLOWED' <<< "$control" && grep -q 'PROBE read-ssh ALLOWED' <<< "$control" || fail "breach probe control must reach HOME unsandboxed: $control"
rm -f "$FAKE_HOME/breach-wrote-home"
echo breach > "$TMP/mode"
remote_before="$(git --git-dir="$REMOTE" rev-parse main)"
headless || fail 'breach run must exit 0'
expect_status failed
[[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_before" ]] || fail 'a candidate whose tests broke out must not be delivered'
for blocked in 'network EPERM' 'write-home EPERM' 'read-ssh EPERM' 'security blocked' 'git-credential blocked'; do
  grep -q "^PROBE $blocked\$" "$RESULT.log" || fail "the verifier sandbox must block: $blocked"
done
! grep -q 'ALLOWED' "$RESULT.log" || fail 'a sandboxed probe was allowed'
[[ ! -e "$FAKE_HOME/breach-wrote-home" ]] || fail 'the verifier wrote to HOME'
! grep -q '^VERIFIER-LEAK' "$RESULT.log" || fail 'the verifier environment carried credentials'
echo okverify > "$TMP/mode"
cat > "$TMP/okverify.sh" <<'EOF'
#!/bin/bash
# A normal test: its temp dir, the candidate, loopback and git all work.
set -e
: > "$TMPDIR/ok-tmp"
: > "$TEST_HARNESS_DIR/ok-candidate-write"
python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(); socket.create_connection(s.getsockname(), timeout=5).close()'
git -C "$TEST_HARNESS_DIR" status --porcelain >/dev/null
echo OK-VERIFY-RAN
EOF
headless || fail 'okverify run must exit 0'
expect_status delivered
grep -q '^OK-VERIFY-RAN$' "$RESULT.log" || fail 'a normal candidate test must run in the sandbox'
git --git-dir="$REMOTE" show main:okverify.txt >/dev/null || fail 'a normal candidate must be delivered'
echo 'PASS: harness-headless runs candidate tests in a sandbox without network, secrets or HOME writes'

# --- a moved source checkout is refused with a plain reason -----------------------
mv_out="$(env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$FAKE_HOME" HARNESS_HEADLESS=1 HARNESS_PYTHON_BIN="$(command -v python3)" \
  HARNESS_SESSION_STATE_HOME="$STATE" "$ROOT/bin/session-isolation.sh" create "$SOURCE")"
mv_id="$(printf '%s\n' "$mv_out" | sed -n 's/^HARNESS_SESSION_ID=//p')"; mv_root="$(printf '%s\n' "$mv_out" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
printf 'moved\n' > "$mv_root/moved.txt"
mv "$SOURCE" "$SOURCE.moved"
moved_rc=0
env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$FAKE_HOME" HARNESS_SESSION_STATE_HOME="$STATE" \
  python3 - "$ROOT/bin" "$STATE" "$mv_id" <<'PY' || moved_rc=$?
import os, subprocess, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import harness_headless as h
state, sid = Path(sys.argv[2]), sys.argv[3]
subprocess.run([str(h.BIN / 'session-isolation.sh'), 'exit', sid], env=os.environ, stderr=subprocess.DEVNULL)
with open(os.devnull, 'w') as log:
    status, commit, reason = h.deliver(sid, state, dict(os.environ), str(state), log)
assert status == 'refused' and commit is None and 'source checkout' in (reason or ''), (status, reason)
PY
mv "$SOURCE.moved" "$SOURCE"
[[ "$moved_rc" == 0 ]] || fail 'a moved source checkout must be refused with its own reason'
! grep -qx -e state=CLOSED -e state=DELIVERED "$STATE/sessions/$mv_id/journal" || fail 'a session whose source moved must be kept'
echo 'PASS: harness-headless names a moved source checkout'

# --- timeout ------------------------------------------------------------------------
echo hang > "$TMP/mode"
rm -f "$TMP/child.pid" "$TMP/grandchild.pid"
start=$SECONDS
TIMEOUT_MIN=0.1 headless || fail 'timeout run must exit 0'
expect_status timeout
timeout_tmp="$(sed -n 's/^CLAUDE_CODE_TMPDIR=//p' "$TMP/claude-env")"
[[ -n "$timeout_tmp" && ! -e "$timeout_tmp" ]] || fail 'the temp base must be removed after a timeout'
(( SECONDS - start < 30 )) || fail 'timeout must stop the run promptly'
for pidfile in "$TMP/child.pid" "$TMP/grandchild.pid"; do
  [[ -s "$pidfile" ]] || fail "missing $pidfile"
  ! kill -0 "$(cat "$pidfile")" 2>/dev/null || fail 'timeout must kill the whole process group'
done
echo 'PASS: harness-headless kills the process group on timeout'

# --- lock ---------------------------------------------------------------------------
echo wait > "$TMP/mode"
rm -f "$TMP/started" "$TMP/release"
headless > /dev/null 2>&1 &
first=$!
for _ in $(seq 1 200); do [[ -e "$TMP/started" ]] && break; sleep 0.05; done
[[ -e "$TMP/started" ]] || fail 'locked run did not start'
python3 - "$LOCK" <<'PY' || fail 'harness-headless must hold an exclusive flock while running'
import fcntl, sys
with open(sys.argv[1], 'a') as f:
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit(0)
raise SystemExit(1)
PY
before="$(shasum "$RESULT")"
rc=0; headless > /dev/null 2>&1 || rc=$?
[[ "$rc" == 75 && "$(shasum "$RESULT")" == "$before" ]] || fail "a busy lock must exit 75 without touching the result (rc=$rc)"
: > "$TMP/release"
wait "$first" || fail 'locked run must finish'
expect_status no_changes
rc=0
env -i PATH="$STUB:/usr/bin:/bin" HOME="$FAKE_HOME" HARNESS_PROFILE_HOME="$PROFILES" \
  "$PREFIX/bin/harness-headless" hh --prompt-file "$PROMPT" --result-file "$RESULT" \
  --lock-file "$TMP/missing-dir/run.lock" --budget-usd 1 --timeout-min 1 2>/dev/null || rc=$?
[[ "$rc" == 2 ]] || fail "an unusable lock path must exit 2 (rc=$rc)"
expect_status refused
echo 'PASS: harness-headless holds the lock file for its whole run'

# --- SIGTERM: kill the group, write the result, then release the lock -------------
echo hang > "$TMP/mode"
rm -f "$TMP/child.pid" "$TMP/grandchild.pid" "$RESULT"
# exec: the background job's pid is harness-headless itself.
HEADLESS_EXEC=1 headless > /dev/null 2>&1 &
runner=$!
for _ in $(seq 1 200); do [[ -s "$TMP/grandchild.pid" && -s "$TMP/child.pid" ]] && break; sleep 0.05; done
[[ -s "$TMP/grandchild.pid" ]] || fail 'hang run did not start'
python3 - "$LOCK" "$RESULT" "$runner" <<'PY' || fail 'the lock must be released only after the result is written'
import fcntl, os, signal, sys, time
lock, result, pid = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.kill(pid, signal.SIGTERM)
with open(lock, 'a') as f:
    for _ in range(400):
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            time.sleep(0.05)
            continue
        raise SystemExit(0 if os.path.exists(result) else 1)
raise SystemExit(1)
PY
wait "$runner" || true
expect_status failed
term_tmp="$(sed -n 's/^CLAUDE_CODE_TMPDIR=//p' "$TMP/claude-env")"
[[ -n "$term_tmp" && ! -e "$term_tmp" ]] || fail 'the temp base must be removed after SIGTERM'
for pidfile in "$TMP/child.pid" "$TMP/grandchild.pid"; do
  ! kill -0 "$(cat "$pidfile")" 2>/dev/null || fail 'SIGTERM must kill the whole process group'
done
echo 'PASS: harness-headless handles SIGTERM by killing the group and writing a result'

# --- refused ------------------------------------------------------------------------
rm -f "$TMP/claude-argv"
: > "$PROMPT"
headless || fail 'refused run must exit 0'
expect_status refused
[[ "$(field session_id)" == null && ! -e "$TMP/claude-argv" ]] || fail 'refused run must not launch claude'
printf '%s\n' 'Fix the typo.' > "$PROMPT"
env -i PATH="/usr/bin:/bin" HOME="$FAKE_HOME" HARNESS_PROFILE_HOME="$PROFILES" \
  "$PREFIX/bin/harness-headless" missing --prompt-file "$PROMPT" --result-file "$RESULT" \
  --lock-file "$LOCK" --budget-usd 1 --timeout-min 1 || fail 'unknown harness must still write a result'
expect_status refused
# A tracked symlinked .claude makes the headless clone refuse itself.
LINKED="$TMP/linked"
mkdir -p "$LINKED/config" "$TMP/linked-outside"
git -C "$LINKED" init -q -b main
printf '%s\n' 'HARNESS_NAME="linked"' 'HARNESS_PREFIX="lh"' > "$LINKED/config/launcher.env"
ln -s "$TMP/linked-outside" "$LINKED/.claude"
git -C "$LINKED" add -A && git -C "$LINKED" -c user.email=t@example.invalid -c user.name=t commit -qm initial
rm "$LINKED/.claude" && mkdir "$LINKED/.claude" && printf '%s\n' '{}' > "$LINKED/.claude/settings.local.json"
printf '%s\n' "$LINKED" > "$PROFILES/profiles/lh"
rm -f "$TMP/claude-argv"
env -i PATH="$STUB:/usr/bin:/bin" HOME="$FAKE_HOME" HARNESS_PROFILE_HOME="$PROFILES" HARNESS_SESSION_STATE_HOME="$STATE" \
  "$PREFIX/bin/harness-headless" lh --prompt-file "$PROMPT" --result-file "$RESULT" \
  --lock-file "$LOCK" --budget-usd 1 --timeout-min 1 || fail 'refused clone must still write a result'
expect_status refused
[[ ! -e "$TMP/claude-argv" && ! -e "$TMP/linked-outside/settings.local.json" ]] || fail 'refused clone must not launch claude or write outside'
# Caller settings may only add restrictions; anything else is refused.
for weak in '{"permissions":{"allow":["Bash"]}}' '{"permissions":{"ask":["Bash"]}}' \
  '{"permissions":{"defaultMode":"bypassPermissions"}}' '{"permissions":{"additionalDirectories":["/"]}}' \
  '{"hooks":{}}' '{"env":{"A":"b"}}' '{"apiKeyHelper":"x"}' '{"enableAllProjectMcpServers":true}' \
  '{"sandbox":{"enabled":false}}' '{"sandbox":{"allowUnsandboxedCommands":true}}' \
  '{"sandbox":{"excludedCommands":["git"]}}' '{"sandbox":{"autoAllowBashIfSandboxed":true}}' \
  '{"sandbox":{"network":{"strictAllowlist":false}}}' '{"sandbox":{"filesystem":{"allowWrite":["/"]}}}' \
  '{"sandbox":{"filesystem":{"allowRead":["/"]}}}' '{"sandbox":{"enableWeakerNestedSandbox":true}}' \
  '{"permissions":{"deny":"Bash"}}' '{"sandbox":{"network":{"allowedDomains":[1]}}}' '[]'; do
  printf '%s\n' "$weak" > "$TMP/weak.json"
  rm -f "$TMP/claude-argv"
  headless --settings-file "$TMP/weak.json" || fail "weak settings run must write a result: $weak"
  [[ "$(field status)" == refused && ! -e "$TMP/claude-argv" ]] || fail "caller settings must be refused: $weak"
done
if "$PREFIX/bin/harness-headless" hh --prompt-file "$PROMPT" 2>/dev/null; then fail 'missing required options must exit nonzero'; fi
echo 'PASS: harness-headless refuses runs that would need interactive input'

# --- a temp-base failure still writes a result -------------------------------------
rm -f "$RESULT"
python3 - "$ROOT/bin" hh --prompt-file "$PROMPT" --result-file "$RESULT" --lock-file "$LOCK" \
  --budget-usd 1 --timeout-min 1 <<'PY' || fail 'a mkdtemp failure must still exit 0 with a result'
import sys, tempfile
sys.path.insert(0, sys.argv[1])
import harness_headless
def boom(*a, **k):
    raise OSError(28, 'No space left on device')
tempfile.mkdtemp = boom
raise SystemExit(harness_headless.main(sys.argv[2:]))
PY
expect_status failed
echo 'PASS: harness-headless writes a result when the temp base cannot be created'

# --- no /usr/bin/lockf: refuse before spending anything ---------------------------
rm -f "$RESULT" "$TMP/claude-argv"
env -i PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$FAKE_HOME" TMPDIR="$TMP" \
  HARNESS_PROFILE_HOME="$PROFILES" HARNESS_SESSION_STATE_HOME="$STATE" \
  python3 - "$ROOT/bin" hh --prompt-file "$PROMPT" --result-file "$RESULT" --lock-file "$LOCK" \
  --budget-usd 1 --timeout-min 1 <<'PY' || fail 'a missing lockf must still exit 0 with a result'
import sys
sys.path.insert(0, sys.argv[1])
import harness_headless
harness_headless.LOCKF = '/nonexistent/lockf'
raise SystemExit(harness_headless.main(sys.argv[2:]))
PY
expect_status refused
[[ ! -e "$TMP/claude-argv" ]] && grep -q lockf "$RESULT" || fail 'a missing lockf must refuse before launching claude'
echo 'PASS: harness-headless refuses before launch when session delivery cannot lock'

# --- no verifier sandbox: refuse before spending anything --------------------------
printf '#!/bin/sh\necho "sandbox-exec: profile failed to load" >&2\nexit 65\n' > "$TMP/bad-sandbox-exec"; chmod +x "$TMP/bad-sandbox-exec"
for sandbox in /nonexistent/sandbox-exec "$TMP/bad-sandbox-exec"; do
  rm -f "$RESULT" "$TMP/claude-argv"
  env -i PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$FAKE_HOME" TMPDIR="$TMP" \
    HARNESS_PROFILE_HOME="$PROFILES" HARNESS_SESSION_STATE_HOME="$STATE" \
    python3 - "$ROOT/bin" "$sandbox" hh --prompt-file "$PROMPT" --result-file "$RESULT" --lock-file "$LOCK" \
    --budget-usd 1 --timeout-min 1 <<'PY' || fail "an unusable sandbox ($sandbox) must still exit 0 with a result"
import sys
sys.path.insert(0, sys.argv[1])
import harness_headless
harness_headless.SANDBOX_EXEC = sys.argv[2]
raise SystemExit(harness_headless.main(sys.argv[3:]))
PY
  expect_status refused
  [[ ! -e "$TMP/claude-argv" ]] && grep -q sandbox "$RESULT" || fail "an unusable sandbox ($sandbox) must refuse before launching claude"
done
echo 'PASS: harness-headless refuses before launch when the verifier sandbox is unavailable'
