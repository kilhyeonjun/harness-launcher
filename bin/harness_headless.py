"""harness-headless: one non-interactive isolated Claude run with broker delivery.

The caller (an external bridge) gets exactly one JSON result file per run; see
docs/architecture.md "Headless isolated runs" for the contract.
"""
import argparse
import fcntl
import json
import math
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
from pathlib import Path

sys.dont_write_bytecode = True
BIN = Path(__file__).resolve().parent
UUID = r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
SESSION_LINE = re.compile(r'^harness-launcher: isolated session (' + UUID + r');', re.M)
# Caller environment kept for the launcher and Claude. Everything else
# (API keys, bot tokens, ...) is dropped before anything is launched.
ENV_ALLOW = ('HOME', 'PATH', 'USER', 'LOGNAME', 'SHELL', 'LANG')
# Launcher state location only, so `harness-session` sees the same sessions.
ENV_LAUNCHER = ('HARNESS_SESSION_STATE_HOME', 'XDG_STATE_HOME')
HOME_DENY = ('.hermes', 'buzz', '.ssh', '.config/gh', '.aws', '.claude')
# Edit-tool denies only (persistence vectors that are not secrets).
HOME_WRITE_DENY = ('Library/LaunchAgents',)
BASH_DENY = ('harness-session', 'session-isolation.sh', 'auto-deliver', 'git push', 'sudo', 'launchctl')
# Prefix form only: a wildcard would also block paths such as docs/*buzz*/.
BASH_PREFIX_DENY = ('hermes', 'buzz', 'rm -rf')
EDIT_TOOLS = ('Edit', 'Write', 'NotebookEdit')
# Broker integration and session GC serialize on this macOS lock tool and fail
# closed without it.
LOCKF = '/usr/bin/lockf'
# The broker runs the repository verifier (candidate tests) under Seatbelt.
SANDBOX_EXEC = '/usr/bin/sandbox-exec'
SUMMARY_MAX = 3000
# The agent's message for the delivery commit (see agent_commit_message).
COMMIT_MESSAGE = 'commit-message'
MESSAGE_MAX_BYTES = 8192
MESSAGE_MAX_LINES = 200
SUBJECT_MAX = 100
# Trailer keys dropped from the message (see trailer_key): the broker appends
# Harness-Session itself, and skip-checks would switch off the checks.
DROPPED_TRAILERS = ('harnesssession', 'skipchecks')
# CI-skip directives (GitHub Actions and most CI systems): the delivered
# commit must not switch off the repository's checks.
CI_SKIP_TOKEN = re.compile(r'\[\s*(?:skip\s+ci|ci\s+skip|no\s+ci|skip\s+actions|actions\s+skip)\s*\]', re.I)
CI_SKIP_LEADING = re.compile(r'^[ \t]*(?:' + CI_SKIP_TOKEN.pattern + r')[ \t]*', re.I | re.M)
DELIVERY_NOTE = (
    '---\n'
    'Delivery note from the launcher: when you finish, the launcher commits your changes to the repository '
    'as one commit. Your own git commits are not kept as commits. Write the message for that commit with Bash '
    'to the file named by $HARNESS_COMMIT_MESSAGE_FILE: a subject line of at most 72 characters, a blank line, '
    'then the body. Follow the repository\'s commit conventions. If you do not write it, a generic message is used.')
EXIT_TIMEOUT = 124
EXIT_REFUSED = 2


class Refused(Exception):
    pass


class Terminated(Exception):
    pass


def _terminate(signum, frame):
    raise Terminated(signum)


def parse_args(argv):
    parser = argparse.ArgumentParser(prog='harness-headless', allow_abbrev=False)
    parser.add_argument('harness')
    for name in ('--prompt-file', '--result-file', '--lock-file', '--budget-usd', '--timeout-min'):
        parser.add_argument(name, required=True)
    parser.add_argument('--settings-file')
    parser.add_argument('--model')
    return parser.parse_args(argv)


def positive(value, name):
    try:
        number = float(value)
    except ValueError:
        number = math.nan
    if not (math.isfinite(number) and number > 0):
        raise Refused(f'{name} must be a positive number')
    return number


def harness_dir(name):
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]*', name):
        raise Refused(f'invalid harness name: {name}')
    home = os.environ.get('HARNESS_PROFILE_HOME') or os.path.join(
        os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'harness-launcher')
    record = Path(home, 'profiles', name)
    if not record.is_file() or record.is_symlink():
        raise Refused(f'harness is not registered: {name}')
    lines = record.read_text().splitlines()
    root = lines[0] if lines else ''
    if not root or not Path(root, 'config', 'launcher.env').is_file():
        raise Refused(f'registered harness is unavailable: {name}')
    return root


def child_env(run_tmp):
    env = {k: v for k, v in os.environ.items() if k in ENV_ALLOW + ENV_LAUNCHER or k.startswith('LC_')}
    # One private temp base per run: Claude keeps its per-uid dir (Bash cwd
    # tracking) under CLAUDE_CODE_TMPDIR, which must stay short for AF_UNIX
    # sockets, so the shared /private/tmp/claude-<uid> can stay write-denied.
    env.update(TMPDIR=run_tmp, CLAUDE_CODE_TMPDIR=run_tmp)
    # HARNESS_HEADLESS selects the headless clone and skips harness-local
    # secrets; the interpreter is the one the launcher shim already resolved.
    env.update(HARNESS_HEADLESS='1', HARNESS_PYTHON_BIN=sys.executable, GIT_TERMINAL_PROMPT='0')
    # The only place the agent can hand the launcher a commit message: the
    # sandbox may write the run's temp base, never the session record.
    env['HARNESS_COMMIT_MESSAGE_FILE'] = os.path.join(run_tmp, COMMIT_MESSAGE)
    return env


def trailer_key(line):
    """The trailer key of a line compared loosely, so no spoof of a dropped
    trailer survives: compatibility forms (full-width letters and colons)
    folded by NFKC, case folded, and every non-alphanumeric character in the
    key (spaces, hyphens, underscores) removed. None without a colon."""
    norm = unicodedata.normalize('NFKC', line).casefold().replace('\u2236', ':')
    key, colon, _ = norm.partition(':')
    return re.sub(r'[\W_]', '', key) if colon else None


def agent_commit_message(run_tmp):
    """(message, None) from the agent's message file, or (None, reason). The
    file is agent-written: no symlink or special file, bounded, strict UTF-8,
    no control characters but LF and TAB, no reserved trailer. Never raises."""
    try:
        fd = os.open(os.path.join(run_tmp, COMMIT_MESSAGE), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None, 'no message file'
    except OSError as exc:
        return None, f'unreadable message file ({exc.strerror})'
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return None, 'message file is not a regular file'
        # A hard link would be another file's content (defence in depth: the
        # sandbox cannot link read-denied files).
        if info.st_nlink != 1:
            return None, 'message file has more than one link'
        data = os.read(fd, MESSAGE_MAX_BYTES + 1)
    except OSError as exc:
        return None, f'unreadable message file ({exc.strerror})'
    finally:
        os.close(fd)
    if len(data) > MESSAGE_MAX_BYTES:
        return None, f'message file is larger than {MESSAGE_MAX_BYTES} bytes'
    try:
        text = data.decode('utf-8', errors='strict')
    except UnicodeError:
        return None, 'message file is not valid UTF-8'
    # Line and paragraph separators split lines for viewers, so they are lines.
    text = text.replace('\r\n', '\n').replace('\r', '\n').replace('\u2028', '\n').replace('\u2029', '\n')
    text = re.sub(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]', '', text)
    # Format characters (bidi overrides, zero-width) could hide or reorder text.
    text = ''.join(c for c in text if unicodedata.category(c) != 'Cf')
    while CI_SKIP_TOKEN.search(text):
        # A token that starts a line takes its following blanks with it.
        text = CI_SKIP_LEADING.sub('', text)
        text = CI_SKIP_TOKEN.sub('', text)
    lines = [line.rstrip() for line in text.split('\n')
             if trailer_key(line) not in DROPPED_TRAILERS]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    if not lines or len(lines[0]) > SUBJECT_MAX or len(lines) > MESSAGE_MAX_LINES:
        return None, 'message has no subject, a subject over 100 characters or over 200 lines'
    return '\n'.join(lines) + '\n', None


def record_commit_message(state, sid, message):
    """Atomically write the message to the launcher-owned session record,
    where the broker reads it. Returns None, or why it was not written."""
    record = state / 'sessions' / sid
    target = record / COMMIT_MESSAGE
    try:
        if target.is_symlink():
            return 'the session record has a symlink at commit-message'
        fd, tmp = tempfile.mkstemp(dir=record, prefix='.commit-message.')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as out:
                out.write(message)
                out.flush()
                os.fsync(out.fileno())
            os.replace(tmp, target)
        except BaseException:
            os.unlink(tmp)
            raise
    except OSError as exc:
        return f'could not write the session record ({exc.strerror})'
    return None


def broker_env(env):
    """The run environment without the run's temp base: broker git and the
    repository verifier write and execute their own temp files, which must
    never sit in a directory the sandboxed agent could write."""
    env = {k: v for k, v in env.items() if k != 'CLAUDE_CODE_TMPDIR'}
    env['TMPDIR'] = tempfile.gettempdir()
    return env


def state_home(env):
    if env.get('HARNESS_SESSION_STATE_HOME'):
        return Path(env['HARNESS_SESSION_STATE_HOME'])
    base = env.get('XDG_STATE_HOME') or os.path.join(env['HOME'], '.local', 'state')
    return Path(base, 'harness-launcher')


def mandatory_settings(source, home, caller_deny_read, run_tmp=None):
    """Launcher-owned containment. Passed last, so the launcher's settings
    merge (dicts deep-merged, lists unioned, scalars last-wins) keeps every
    value here over any earlier --settings. Every sandbox read-denied path is
    also denied to the Read and edit tools, which the sandbox does not cover."""
    uid = os.getuid()
    homes = [os.path.join(home, d) for d in HOME_DENY]
    sources = [source, os.path.realpath(source)]
    # The session clone has its own Git directory (no hardlinks or alternates)
    # and copied local files, so the canonical source root can be read-denied.
    deny_read = list(dict.fromkeys(homes + sources + list(caller_deny_read)))
    deny_write = [f'/private/tmp/claude-{uid}', f'/tmp/claude-{uid}']
    write_paths = deny_read + [os.path.join(home, d) for d in HOME_WRITE_DENY] + deny_write
    deny = [f'Read(/{path}/**)' for path in deny_read]
    deny += [f'{tool}(/{path}/**)' for path in write_paths for tool in EDIT_TOOLS]
    deny += ['WebFetch', 'WebSearch']
    for word in BASH_DENY:
        deny += [f'Bash({word}:*)', f'Bash(*{word}*)']
    deny += [f'Bash({word}:*)' for word in BASH_PREFIX_DENY]
    return {'permissions': {'deny': deny},
            'disableAllHooks': True,
            'disableBypassPermissionsMode': 'disable',
            'sandbox': {'enabled': True, 'failIfUnavailable': True, 'allowUnsandboxedCommands': False,
                        'autoAllowBashIfSandboxed': True,
                        'network': {'strictAllowlist': True, 'allowedDomains': []},
                        'filesystem': {'denyRead': deny_read, 'denyWrite': deny_write,
                                       'allowWrite': [run_tmp] if run_tmp else []}}}


def _strings(value):
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


# The only caller settings accepted: additions that restrict further, plus the
# network allowlist. Any other key could weaken containment.
CALLER_SHAPE = {'_note': str, 'permissions': {'deny': _strings},
                'sandbox': {'filesystem': {'denyRead': _strings}, 'network': {'allowedDomains': _strings}}}


def validate_caller(value, shape=CALLER_SHAPE, where='settings'):
    if not isinstance(value, dict):
        raise Refused(f'--settings-file {where} must be a JSON object')
    for key, item in value.items():
        rule = shape.get(key)
        if rule is None:
            raise Refused(f'--settings-file key is not allowed: {where}.{key}')
        if isinstance(rule, dict):
            validate_caller(item, rule, f'{where}.{key}')
        elif not (isinstance(item, rule) if isinstance(rule, type) else rule(item)):
            raise Refused(f'--settings-file value has the wrong type: {where}.{key}')


def claude_result(stdout):
    for line in reversed(stdout.splitlines()):
        try:
            data = json.loads(line)
        except ValueError:
            continue
        if isinstance(data, dict) and ('is_error' in data or data.get('type') == 'result'):
            return data
    return None


def journal_state(state, sid):
    try:
        for line in (state / 'sessions' / sid / 'journal').read_text().splitlines():
            if line.startswith('state='):
                return line[len('state='):]
    except OSError:
        pass
    return ''


def launched_session(log_text, state, source):
    """The launcher-announced session, accepted only when it is genuine."""
    match = SESSION_LINE.search(log_text)
    if not match:
        return None
    sid = match.group(1)
    try:
        recorded = (state / 'sessions' / sid / 'source-root').read_text().strip()
    except OSError:
        return None
    return sid if os.path.realpath(recorded) == os.path.realpath(source) else None


def transcript_path(home, session_root, claude_sid):
    if not (claude_sid and re.fullmatch(UUID, claude_sid) and session_root):
        return None
    path = Path(home, '.claude', 'projects', re.sub(r'[^A-Za-z0-9]', '-', session_root), claude_sid + '.jsonl')
    return str(path) if path.is_file() else None


def kill_group(pgid):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except (ProcessLookupError, PermissionError):
            return
        if sig == signal.SIGTERM:
            time.sleep(2)


def kill_lingering(*roots):
    """SIGKILL every process of this user whose cwd or an open file is inside
    one of roots (the session root and the run's temp base), so nothing changes
    the work tree or broker inputs while the broker reads them.
    ponytail: one lsof snapshot; a process with no cwd or open file under the
    root at that instant, or one started after it, escapes. Upgrade path: run
    the agent as a dedicated macOS user and kill all of that user's processes."""
    lsof = '/usr/sbin/lsof'
    if not os.path.exists(lsof):
        return []
    out = subprocess.run([lsof, '-nP', '-w', '-u', str(os.getuid()), '-Fpn'], stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout
    roots = [r.rstrip('/') for r in roots if r]
    pid, victims = None, set()
    for line in out.splitlines():
        if line.startswith('p'):
            pid = int(line[1:])
        elif line.startswith('n') and pid not in (None, os.getpid()):
            name = line[1:]
            if any(name == r or name.startswith(r + '/') for r in roots):
                victims.add(pid)
    for victim in victims:
        try:
            os.kill(victim, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    return sorted(victims)


NO_TRUSTED_GIT = 'headless session record has no trusted git directory; delivery refused, session kept'
SOURCE_MISSING = ('the source checkout this session was cloned from could not be found (moved or deleted); '
                  'delivery refused, session kept')
VERIFIER_REJECTED = ('the repository verifier rejected the session; it runs sandboxed (no network but '
                     'loopback, no credentials, writes only to its candidate); see the run log; session kept')


def deliver(sid, state, env, cwd, log, message=None):
    """Broker delivery after a successful run: (status, commit, reason).
    The agent's commit message is recorded for the broker only while `close`
    runs; every outcome other than DELIVERED removes it again."""
    record = state / 'sessions' / sid / COMMIT_MESSAGE
    outcome = None
    try:
        outcome = _deliver(sid, state, env, cwd, log, message)
        return outcome
    finally:
        if outcome is None or outcome[0] != 'delivered':
            try:
                record.unlink()
            except FileNotFoundError:
                pass


def _deliver(sid, state, env, cwd, log, message):
    iso = str(BIN / 'session-isolation.sh')

    def session(*args):
        return subprocess.run([iso, *args, sid], env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                              stdout=log, stderr=log).returncode

    def delivered():
        sha = (state / 'sessions' / sid / 'delivered-sha').read_text().strip()
        return 'delivered', sha, None

    current = journal_state(state, sid)
    if current == 'CLOSED':
        return 'no_changes', None, None
    if current != 'ABANDONED' or session('recover') != 0:
        return 'failed', None, None
    # The session has changes and is about to be closed through the broker.
    reason = record_commit_message(state, sid, message) if message else 'no usable message file'
    print(f'harness-headless: commit message: {"agent" if not reason else f"generic ({reason})"}', file=log, flush=True)
    rc = session('close')
    after = journal_state(state, sid)
    if after == 'INTEGRATING':
        # Indeterminate integration (readback outage, exit 4 or a git 128):
        # prove the pending commit once.
        session('recover')
        after = journal_state(state, sid)
    if after == 'DELIVERED':
        return delivered()
    if rc == 0 and after == 'CLOSED':
        return 'no_changes', None, None
    if rc == 6:
        return 'refused', None, NO_TRUSTED_GIT
    if rc == 8:
        return 'refused', None, SOURCE_MISSING
    if rc == 9:
        return 'failed', None, VERIFIER_REJECTED
    if rc in (3, 5):
        return 'conflict', None, None
    return 'failed', None, None


def sandbox_preflight():
    """Refuse before launch unless the verifier sandbox profile loads here."""
    if not os.access(SANDBOX_EXEC, os.X_OK):
        raise Refused(f'{SANDBOX_EXEC} is required to sandbox the repository verifier and is unavailable')
    env = {'HOME': os.environ.get('HOME', ''), 'PATH': '/usr/bin:/bin', 'TMPDIR': tempfile.gettempdir()}
    check = subprocess.run([str(BIN / 'session-isolation.sh'), 'sandbox-check', SANDBOX_EXEC], env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if check.returncode != 0:
        detail = check.stderr.strip()[-300:]
        raise Refused(f'the repository verifier sandbox profile failed to load ({SANDBOX_EXEC}): {detail}')


def run(args, result, run_tmp):
    hdir = harness_dir(args.harness)
    if not os.access(LOCKF, os.X_OK):
        # Delivery could never succeed; do not spend the budget first.
        raise Refused(f'{LOCKF} is required for session delivery and is unavailable')
    sandbox_preflight()
    try:
        prompt = Path(args.prompt_file).read_text()
    except OSError as exc:
        raise Refused(f'prompt file is unreadable: {exc.strerror}')
    if not prompt.strip():
        raise Refused('prompt file is empty; a headless run cannot ask for input')
    positive(args.budget_usd, '--budget-usd')
    timeout = positive(args.timeout_min, '--timeout-min') * 60
    caller = None
    if args.settings_file:
        try:
            caller = json.loads(Path(args.settings_file).read_text())
        except (OSError, ValueError):
            raise Refused('--settings-file must contain a JSON object')
        validate_caller(caller)

    env = child_env(run_tmp)
    state = state_home(env)
    # The launcher merges every --settings (its launch-record hook, the
    # caller's, these denies) into the single --settings Claude receives.
    # acceptEdits, not bypass: writes outside the session root are denied and
    # sandboxed Bash auto-runs (autoAllowBashIfSandboxed). The prompt is stdin.
    command = [str(BIN / 'harness-exec'), hdir, '--isolated', '--passthrough', '-p',
               '--output-format', 'json', '--max-budget-usd', args.budget_usd,
               '--permission-mode', 'acceptEdits', '--strict-mcp-config']
    if args.model:
        command += ['--model', args.model]
    if caller is not None:
        command += ['--settings', json.dumps(caller)]
    caller_deny_read = ((caller or {}).get('sandbox') or {}).get('filesystem', {}).get('denyRead', [])
    command += ['--settings', json.dumps(mandatory_settings(hdir, env['HOME'], caller_deny_read, run_tmp))]

    log_path = args.result_file + '.log'
    with open(log_path, 'w') as log, tempfile.TemporaryFile('w+') as out, tempfile.TemporaryFile('w+') as stdin:
        stdin.write(prompt.rstrip('\n') + '\n\n' + DELIVERY_NOTE)
        stdin.flush()
        stdin.seek(0)
        proc = subprocess.Popen(command, cwd=hdir, env=env, stdin=stdin,
                                stdout=out, stderr=log, start_new_session=True)
        timed_out = False
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            # Also on a terminating signal: the whole group goes first.
            kill_group(proc.pid)
        proc.wait()
        log.flush()
        out.seek(0)
        data = claude_result(out.read())
        log_text = Path(log_path).read_text(errors='replace')
        sid = launched_session(log_text, state, hdir)
        result['session_id'] = sid
        # Before any broker step: nothing from the run survives near the work
        # tree or the temp base, and the temp base is gone.
        kill_lingering(str(state / 'worktrees' / sid) if sid else None, run_tmp)
        # Read now (the temp base goes next); recorded only for a delivery.
        message, message_reason = agent_commit_message(run_tmp)
        shutil.rmtree(run_tmp, ignore_errors=True)
        # A clone refusal can only precede the launcher's session announcement.
        announced = SESSION_LINE.search(log_text)
        launcher_text = log_text[:announced.start()] if announced else log_text
        result['exit_code'] = EXIT_TIMEOUT if timed_out else proc.returncode
        if data:
            text = data.get('result')
            result['summary'] = (text if isinstance(text, str) else str(data.get('subtype') or ''))[:SUMMARY_MAX]
            result['cost_usd'] = data.get('total_cost_usd')
            result['num_turns'] = data.get('num_turns')
            session_root = str(state / 'worktrees' / sid) if sid else None
            result['transcript'] = transcript_path(env['HOME'], session_root, data.get('session_id'))
        if timed_out:
            result['status'] = 'timeout'
        elif 'headless clone refused' in launcher_text:
            result['status'] = 'refused'
            result['summary'] = 'isolated session refused: symlinked machine-local path in the harness tree'
        elif data is None:
            result['status'] = 'failed'
            result['summary'] = f'launcher exited {proc.returncode} without a Claude result; see {log_path}'
        elif data.get('subtype') == 'error_max_budget_usd':
            result['status'] = 'budget'
        elif data.get('is_error') or proc.returncode != 0:
            result['status'] = 'failed'
        elif not sid:
            result['status'] = 'failed'
            result['summary'] = 'isolated session id was not announced by the launcher'
        else:
            if not message:
                print(f'harness-headless: agent commit message unusable: {message_reason}', file=log, flush=True)
            result['status'], result['commit'], reason = deliver(sid, state, broker_env(env), str(state), log, message)
            if reason:
                result['summary'] = reason


def write_result(path, result):
    directory = os.path.dirname(os.path.abspath(path))
    with tempfile.NamedTemporaryFile('w', dir=directory, prefix='.harness-headless-', delete=False) as tmp:
        json.dump(result, tmp)
        tmp.flush()
        os.fsync(tmp.fileno())
    os.replace(tmp.name, path)


def main(argv):
    args = parse_args(argv)
    result = {'version': 1, 'status': 'failed', 'session_id': None, 'commit': None, 'cost_usd': None,
              'num_turns': None, 'summary': '', 'transcript': None, 'exit_code': 1,
              'started_at': int(time.time()), 'ended_at': None}
    try:
        lock = open(args.lock_file, 'a')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        # Another run owns the lock and its result file: touch nothing.
        print(f'harness-headless: lock is held: {args.lock_file}', file=sys.stderr)
        return 75
    except OSError as exc:
        print(f'harness-headless: lock unavailable: {args.lock_file}: {exc.strerror}', file=sys.stderr)
        result.update(status='refused', summary=f'lock unavailable: {exc.strerror}',
                      exit_code=EXIT_REFUSED, ended_at=int(time.time()))
        try:
            write_result(args.result_file, result)
        except OSError:
            pass
        return 2
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, _terminate)
    run_tmp = None
    try:
        # Short, user-owned, 0700, not a symlink, outside the shared claude-<uid>.
        run_tmp = tempfile.mkdtemp(prefix='hh-', dir='/private/tmp')
        run(args, result, run_tmp)
    except Refused as exc:
        result.update(status='refused', summary=str(exc)[:SUMMARY_MAX], exit_code=EXIT_REFUSED)
    except Terminated as exc:
        signum = exc.args[0]
        result.update(status='failed', exit_code=128 + signum,
                      summary=f'harness-headless terminated by signal {signum}')
    except Exception as exc:  # the result file is the contract; never exit silently
        result.update(status='failed', summary=f'harness-headless error: {exc}'[:SUMMARY_MAX])
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)
    if run_tmp:
        shutil.rmtree(run_tmp, ignore_errors=True)
    result['ended_at'] = int(time.time())
    try:
        write_result(args.result_file, result)
    except OSError as exc:
        print(f'harness-headless: cannot write result: {exc}', file=sys.stderr)
        return 1
    # The lock is released only after the result is in place.
    lock.close()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
