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
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.dont_write_bytecode = True
BIN = Path(__file__).resolve().parent
UUID = r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
SESSION_LINE = re.compile(r'^harness-launcher: isolated session (' + UUID + r');', re.M)
# Caller environment kept for the launcher and Claude. Everything else
# (API keys, bot tokens, ...) is dropped before anything is launched.
ENV_ALLOW = ('HOME', 'PATH', 'USER', 'LOGNAME', 'SHELL', 'LANG', 'TMPDIR')
# Launcher state location only, so `harness-session` sees the same sessions.
ENV_LAUNCHER = ('HARNESS_SESSION_STATE_HOME', 'XDG_STATE_HOME')
HOME_DENY = ('.hermes', 'buzz', '.ssh', '.config/gh', '.aws', '.claude')
BASH_DENY = ('harness-session', 'session-isolation.sh', 'auto-deliver', 'git push', 'sudo', 'launchctl')
SUMMARY_MAX = 3000
EXIT_TIMEOUT = 124
EXIT_REFUSED = 2


class Refused(Exception):
    pass


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


def child_env():
    env = {k: v for k, v in os.environ.items() if k in ENV_ALLOW + ENV_LAUNCHER or k.startswith('LC_')}
    # HARNESS_HEADLESS selects the headless clone and skips harness-local
    # secrets; the interpreter is the one the launcher shim already resolved.
    env.update(HARNESS_HEADLESS='1', HARNESS_PYTHON_BIN=sys.executable, GIT_TERMINAL_PROMPT='0')
    return env


def state_home(env):
    if env.get('HARNESS_SESSION_STATE_HOME'):
        return Path(env['HARNESS_SESSION_STATE_HOME'])
    base = env.get('XDG_STATE_HOME') or os.path.join(env['HOME'], '.local', 'state')
    return Path(base, 'harness-launcher')


def mandatory_settings(source, home):
    """Launcher-owned containment. Passed last, so the launcher's settings
    merge (dicts deep-merged, lists unioned, scalars last-wins) keeps every
    value here over any earlier --settings."""
    homes = list(dict.fromkeys(os.path.join(home, d) for d in HOME_DENY))
    sources = list(dict.fromkeys([source, os.path.realpath(source)]))
    deny = [f'{tool}(/{path}/**)' for path in sources + homes for tool in ('Edit', 'Write', 'NotebookEdit')]
    deny += [f'Read(/{path}/**)' for path in homes]
    deny += ['WebFetch', 'WebSearch']
    for word in BASH_DENY:
        deny += [f'Bash({word}:*)', f'Bash(*{word}*)']
    # The session clone has its own Git directory and copied local files, so
    # the canonical source root can be read-denied too.
    return {'permissions': {'deny': deny},
            'sandbox': {'enabled': True, 'failIfUnavailable': True, 'allowUnsandboxedCommands': False,
                        'network': {'strictAllowlist': True, 'allowedDomains': []},
                        'filesystem': {'denyRead': homes + sources}}}


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


def deliver(sid, state, env, cwd, log):
    """Broker delivery after a successful run: (status, commit)."""
    iso = str(BIN / 'session-isolation.sh')

    def session(*args):
        return subprocess.run([iso, *args, sid], env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                              stdout=log, stderr=log).returncode

    def delivered():
        sha = (state / 'sessions' / sid / 'delivered-sha').read_text().strip()
        return 'delivered', sha

    current = journal_state(state, sid)
    if current == 'CLOSED':
        return 'no_changes', None
    if current != 'ABANDONED' or session('recover') != 0:
        return 'failed', None
    rc = session('close')
    after = journal_state(state, sid)
    if rc == 0:
        if after == 'DELIVERED':
            return delivered()
        return ('no_changes', None) if after == 'CLOSED' else ('failed', None)
    if rc in (3, 5):
        return 'conflict', None
    if rc == 4 and after == 'INTEGRATING':
        # Indeterminate post-push readback: prove the pending commit once.
        if session('recover') == 0 and journal_state(state, sid) == 'DELIVERED':
            return delivered()
    return 'failed', None


def run(args, result):
    hdir = harness_dir(args.harness)
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

    env = child_env()
    state = state_home(env)
    # The launcher merges every --settings (its launch-record hook, the
    # caller's, these denies) into the single --settings Claude receives.
    command = [str(BIN / 'harness-exec'), hdir, '--isolated', '--passthrough', '-p',
               '--output-format', 'json', '--max-budget-usd', args.budget_usd,
               '--permission-mode', 'bypassPermissions', '--strict-mcp-config']
    if args.model:
        command += ['--model', args.model]
    if caller is not None:
        command += ['--settings', json.dumps(caller)]
    command += ['--settings', json.dumps(mandatory_settings(hdir, env['HOME'])), '--', prompt]

    log_path = args.result_file + '.log'
    with open(log_path, 'w') as log, tempfile.TemporaryFile('w+') as out:
        proc = subprocess.Popen(command, cwd=hdir, env=env, stdin=subprocess.DEVNULL,
                                stdout=out, stderr=log, start_new_session=True)
        timed_out = False
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        kill_group(proc.pid)
        proc.wait()
        log.flush()
        out.seek(0)
        data = claude_result(out.read())
        log_text = Path(log_path).read_text(errors='replace')
        sid = launched_session(log_text, state, hdir)
        result['session_id'] = sid
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
        elif 'headless clone refused' in log_text:
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
            result['status'], result['commit'] = deliver(sid, state, env, hdir, log)


def write_result(path, result):
    directory = os.path.dirname(os.path.abspath(path))
    with tempfile.NamedTemporaryFile('w', dir=directory, prefix='.harness-headless-', delete=False) as tmp:
        json.dump(result, tmp)
        tmp.flush()
        os.fsync(tmp.fileno())
    os.replace(tmp.name, path)


def main(argv):
    args = parse_args(argv)
    try:
        lock = open(args.lock_file, 'a')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        print(f'harness-headless: lock unavailable: {args.lock_file}: {exc.strerror}', file=sys.stderr)
        return 75
    result = {'version': 1, 'status': 'failed', 'session_id': None, 'commit': None, 'cost_usd': None,
              'num_turns': None, 'summary': '', 'transcript': None, 'exit_code': 1,
              'started_at': int(time.time()), 'ended_at': None}
    try:
        run(args, result)
    except Refused as exc:
        result.update(status='refused', summary=str(exc)[:SUMMARY_MAX], exit_code=EXIT_REFUSED)
    except Exception as exc:  # the result file is the contract; never exit silently
        result.update(status='failed', summary=f'harness-headless error: {exc}'[:SUMMARY_MAX])
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
