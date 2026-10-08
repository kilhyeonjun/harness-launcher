"""Registered code-repository targets for `harness-headless --target` (B1g).

A target is one personal, private GitHub repository the owner registered by
hand. Its host record, `<profile home>/targets/<name>.json` (mode 0600), holds
exactly the canonical JSON of the entry; `harness-headless` runs only when the
caller's `--target-digest` is the sha256 of those bytes. `<name>.path` beside
it (optional) names the owner's live checkout (its realpath), which a run never
touches and the agent sandbox denies.

The owner-specific boundary values live in host configuration, never in this
code: `<profile home>/target-policy.json` (same file rules as a record) with
exactly `owner` (the GitHub account), `ssh_hosts` (the SSH host aliases a
remote may use), `deny_repos` (`owner/repo` or `owner/*`) and `home_deny`
(paths under HOME, a trailing `*` matching a name prefix, that no live
checkout may sit under and the agent sandbox denies). Without it every target
command and run is refused.

`harness-profile target add|list|show` is the CLI. The terminal check in
`target add` is an accident guard, not a security boundary: the boundary is
that no sandboxed run can write `~/.config/harness-launcher`.
"""
import difflib
import hashlib
import hmac
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

NAME = re.compile(r'[a-z0-9-]{1,40}')
# The loop's name for the harness repository itself.
RESERVED = ('k' + 'h',)
GITHUB = re.compile(r'([A-Za-z0-9-]{1,39})/([A-Za-z0-9._-]{1,100})')
REMOTE = re.compile(r'git@([^:/\s@]+):([^\s]+)')
HOST_ALIAS = re.compile(r'[A-Za-z0-9][A-Za-z0-9.-]{0,252}')
DENY_REPO = re.compile(r'[A-Za-z0-9-]{1,39}/(?:\*|[A-Za-z0-9._-]{1,100})')
HOME_DENY = re.compile(r'[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*\*?')
POLICY_KEYS = {'owner', 'ssh_hosts', 'deny_repos', 'home_deny'}
BASE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._/-]{0,199}')
GROUP = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}')
ENTRY_KEYS = {'name', 'github', 'remote', 'base', 'test'}
TEST_KEYS = {'group', 'run', 'timeout_min'}
# targets.yaml keys that are not part of the digest.
YAML_ONLY = ('path', 'about')
RECORD_MAX = 64 * 1024
GH_TIMEOUT = 120


class Refused(Exception):
    pass


def canonical(entry):
    return json.dumps(entry, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def digest(entry):
    return hashlib.sha256(canonical(entry)).hexdigest()


def profile_home():
    return os.environ.get('HARNESS_PROFILE_HOME') or os.path.join(
        os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'harness-launcher')


def targets_dir():
    return Path(profile_home(), 'targets')


def read_policy():
    """The owner's boundary values; refused when missing or malformed."""
    path = Path(profile_home(), 'target-policy.json')
    data = _read_owned(path, 'target policy (target-policy.json)')
    try:
        policy = json.loads(data.decode('utf-8'), object_pairs_hook=_unique)
    except (UnicodeError, ValueError):
        raise Refused(f'{path} is not JSON with unique keys')
    strings = lambda v: isinstance(v, list) and all(isinstance(i, str) for i in v)  # noqa: E731
    if not (isinstance(policy, dict) and set(policy) == POLICY_KEYS and isinstance(policy['owner'], str)
            and GITHUB.fullmatch(policy['owner'] + '/x') and strings(policy['ssh_hosts']) and policy['ssh_hosts']
            and strings(policy['deny_repos']) and strings(policy['home_deny']) and policy['home_deny']):
        raise Refused(f'{path} must hold exactly owner, ssh_hosts (non-empty), deny_repos and home_deny (non-empty)')
    for host in policy['ssh_hosts']:
        # Plain github.com may carry another account's default key.
        if not HOST_ALIAS.fullmatch(host) or host.casefold() == 'github.com':
            raise Refused(f'{path}: ssh_hosts entry is not a host alias: {host!r}')
    for repo in policy['deny_repos']:
        if not DENY_REPO.fullmatch(repo):
            raise Refused(f'{path}: deny_repos entry must be owner/repo or owner/*: {repo!r}')
    for entry in policy['home_deny']:
        if not HOME_DENY.fullmatch(entry) or '..' in entry.split('/') or '.' in entry.split('/'):
            raise Refused(f'{path}: home_deny entry must be a relative path under HOME: {entry!r}')
    return policy


def check_name(name):
    if not (isinstance(name, str) and NAME.fullmatch(name)) or name in RESERVED:
        raise Refused(f'invalid target name {name!r}: [a-z0-9-]{{1,40}}, not {", ".join(RESERVED)}')
    return name


def _unique(pairs):
    keys = [k for k, _ in pairs]
    if len(set(keys)) != len(keys):
        raise ValueError('duplicate key')
    return dict(pairs)


def parse_yaml_text(text):
    """targets.yaml as data: PyYAML safe_load when the interpreter has it,
    otherwise the system Ruby's Psych safe_load."""
    try:
        import yaml
    except ImportError:
        yaml = None
    if yaml is not None:
        return yaml.safe_load(text)
    try:
        out = subprocess.run(['/usr/bin/ruby', '-ryaml', '-rjson', '-e', 'print JSON.generate(YAML.safe_load(STDIN.read))'],
                             input=text, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise Refused('no YAML parser: install PyYAML for the launcher interpreter (HARNESS_PYTHON_BIN)')
    if out.returncode != 0:
        raise Refused(f'targets YAML does not parse: {out.stderr.strip()[-200:]}')
    return json.loads(out.stdout)


def entry_from_targets(targets, name):
    """The digest entry for name from parsed targets.yaml: path and about
    dropped, nothing else added or changed."""
    check_name(name)
    item = targets.get(name) if isinstance(targets, dict) else None
    if not isinstance(item, dict):
        raise Refused(f'target {name} is not in the targets file')
    unknown = set(item) - (ENTRY_KEYS - {'name'}) - set(YAML_ONLY)
    if unknown:
        raise Refused(f'target {name} has unknown keys: {", ".join(sorted(unknown))}')
    entry = {k: v for k, v in item.items() if k not in YAML_ONLY}
    entry['name'] = name
    return validate_entry(entry)


def check_policy(entry, policy):
    """The owner's boundary rules that need no network."""
    github = entry['github']
    owner = github.split('/')[0]
    if owner != policy['owner']:
        raise Refused(f'target owner must be the policy owner {policy["owner"]}: {github}')
    for denied in policy['deny_repos']:
        d_owner, d_repo = denied.casefold().split('/')
        if owner.casefold() == d_owner and d_repo in ('*', github.split('/')[1].casefold()):
            raise Refused(f'target repository is on the deny list: {github}')
    host = REMOTE.fullmatch(entry['remote']).group(1)
    if host not in policy['ssh_hosts']:
        raise Refused(f'target remote must use one of the policy ssh_hosts ({", ".join(policy["ssh_hosts"])}): {host}')
    return entry


def validate_entry(entry):
    """The entry shape (policy-independent rules)."""
    if not isinstance(entry, dict) or set(entry) != ENTRY_KEYS:
        raise Refused(f'target entry must have exactly {", ".join(sorted(ENTRY_KEYS))}')
    check_name(entry['name'])
    github, remote, base, test = entry['github'], entry['remote'], entry['base'], entry['test']
    match = GITHUB.fullmatch(github) if isinstance(github, str) else None
    if not match or match.group(2) in ('.', '..') or match.group(2).endswith('.git'):
        raise Refused(f'target github must be <owner>/<repo>: {github!r}')
    remote_match = REMOTE.fullmatch(remote) if isinstance(remote, str) else None
    if not remote_match or not HOST_ALIAS.fullmatch(remote_match.group(1)) \
            or remote_match.group(1).casefold() == 'github.com':
        raise Refused(f'target remote must be git@<ssh host alias>:<owner>/<repo>.git (not plain github.com): {remote!r}')
    if remote_match.group(2) != github + '.git':
        raise Refused(f'target remote path must be exactly {github}.git: {remote}')
    if not (isinstance(base, str) and BASE.fullmatch(base)) or any(
            bad in base for bad in ('..', '//', '/.', '@{')) or base.endswith(('/', '.', '.lock')):
        raise Refused(f'target base is not a plain branch name: {base!r}')
    if not isinstance(test, dict) or set(test) != TEST_KEYS:
        raise Refused(f'target test must have exactly {", ".join(sorted(TEST_KEYS))}')
    if not (isinstance(test['group'], str) and GROUP.fullmatch(test['group'])):
        raise Refused(f'target test.group is not a plain name: {test["group"]!r}')
    run = test['run']
    if not (isinstance(run, list) and 1 <= len(run) <= 64 and all(
            isinstance(a, str) and '\0' not in a and len(a) <= 1024 for a in run)):
        raise Refused('target test.run must be a list of 1-64 strings')
    if run[0] != 'python':
        raise Refused('target test.run must start with the literal `python` (it becomes <venv>/bin/python)')
    minutes = test['timeout_min']
    if not (type(minutes) is int and 1 <= minutes <= 240):
        raise Refused('target test.timeout_min must be an integer from 1 to 240')
    return entry


def home_denied(rel, entry):
    """Does a HOME-relative path sit at or under a home_deny entry?"""
    parts, want = rel.split('/'), entry.split('/')
    if len(parts) < len(want) or parts[:len(want) - 1] != want[:-1]:
        return False
    last, part = want[-1], parts[len(want) - 1]
    return part.startswith(last[:-1]) if last.endswith('*') else part == last


def check_live_path(path, home, policy):
    """The registered live checkout as an absolute realpath, not under a
    policy home_deny entry."""
    if path is None:
        return None
    if not (isinstance(path, str) and path.startswith('/') and '\0' not in path and '\n' not in path):
        raise Refused(f'target path must be one absolute path: {path!r}')
    real = os.path.realpath(path)
    for base in dict.fromkeys([home, os.path.realpath(home)]):
        rel = os.path.relpath(real, base)
        if rel.startswith('..') or rel == '.':
            continue
        for entry in policy['home_deny']:
            if home_denied(rel, entry):
                raise Refused(f'target path is under ~/{entry}: {path}')
    return real


def _read_owned(path, what):
    """Bytes of a launcher-owned record: regular file, no symlink, owned by
    this user, mode 0600, one link, bounded."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise Refused(f'{what} is not registered: {path}')
    except OSError as exc:
        raise Refused(f'{what} is unreadable: {exc.strerror} (a symlink is refused)')
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise Refused(f'{what} must be a regular file')
        if info.st_uid != os.getuid():
            raise Refused(f'{what} must be owned by the current user')
        if stat.S_IMODE(info.st_mode) != 0o600:
            raise Refused(f'{what} must have mode 0600')
        if info.st_nlink != 1:
            raise Refused(f'{what} must have exactly one link')
        data = os.read(fd, RECORD_MAX + 1)
    finally:
        os.close(fd)
    if len(data) > RECORD_MAX:
        raise Refused(f'{what} is too large')
    return data


def read_record(name, policy, expected_digest=None):
    """(entry, live path or None) from the host record. With an expected
    digest, the record bytes must hash to it."""
    check_name(name)
    data = _read_owned(targets_dir() / f'{name}.json', f'target record {name}')
    if expected_digest is not None and not hmac.compare_digest(
            hashlib.sha256(data).hexdigest(), expected_digest):
        raise Refused(f'target record {name} does not match --target-digest (the registry and the host record drifted)')
    try:
        entry = json.loads(data.decode('utf-8'), object_pairs_hook=_unique)
    except (UnicodeError, ValueError):
        raise Refused(f'target record {name} is not JSON with unique keys')
    check_policy(validate_entry(entry), policy)
    if canonical(entry) != data or entry['name'] != name:
        raise Refused(f'target record {name} is not the canonical JSON of its own entry')
    path_file = targets_dir() / f'{name}.path'
    path = None
    if os.path.lexists(path_file):
        path = _read_owned(path_file, f'target path record {name}').decode('utf-8', 'strict').rstrip('\n')
    return entry, path


def _write_atomic(target, data):
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=f'.{target.name}.')
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, target)
    except BaseException:
        if os.path.lexists(tmp):
            os.unlink(tmp)
        raise


def write_record(name, entry, path=None):
    """Atomically write the host record (and the live path record) 0600 in a
    0700 directory. No checks: callers validate first."""
    directory = targets_dir()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    path_file = directory / f'{name}.path'
    if path is not None:
        _write_atomic(path_file, path.encode('utf-8') + b'\n')
    elif os.path.lexists(path_file):
        path_file.unlink()
    _write_atomic(directory / f'{name}.json', canonical(entry))


# --- remote boundary (network; the broker runs these outside every sandbox) ---------

def run_bounded(argv, env, cwd, timeout, stdin=subprocess.DEVNULL):
    """(returncode, stdout, stderr, timed_out); the whole process group goes
    on timeout."""
    proc = subprocess.Popen(argv, env=env, cwd=cwd, stdin=stdin, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out, err, False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        out, err = proc.communicate()
        return proc.returncode, out, err, True


def tool(name, env):
    from shutil import which
    found = which(name, path=env.get('PATH', ''))
    if not found:
        raise Refused(f'`{name}` is not on PATH for this run (launchd/cron PATH?); the target preflight needs it')
    return os.path.abspath(found)


def base_env(extra=()):
    """The broker's environment for gh and ssh: identity and PATH only, plus
    the ssh agent socket. Never the caller's tokens."""
    keep = ('HOME', 'PATH', 'USER', 'LOGNAME', 'LANG', 'SSH_AUTH_SOCK') + tuple(extra)
    env = {k: v for k, v in os.environ.items() if k in keep or k.startswith('LC_')}
    env.update(GH_PROMPT_DISABLED='1', GH_NO_UPDATE_NOTIFIER='1', GH_SPINNER_DISABLED='1', NO_COLOR='1',
               GIT_TERMINAL_PROMPT='0')
    return env


def gh_timeout():
    value = os.environ.get('HARNESS_HEADLESS_GH_TIMEOUT', '')
    return float(value) if re.fullmatch(r'[0-9]{1,4}(\.[0-9]+)?', value) and float(value) > 0 else GH_TIMEOUT


def scrub(text, token):
    return text.replace(token, '***') if token else text


class Remote:
    """gh and ssh for one target, run from an empty broker-owned directory.
    The token lives only in this object and the per-call env of gh."""

    def __init__(self, entry, workdir, policy):
        self.entry, self.workdir, self.owner = entry, workdir, policy['owner']
        self.env = base_env()
        self.gh_bin, self.ssh_bin = tool('gh', self.env), tool('ssh', self.env)
        self.token = None

    def gh(self, *args, timeout=None):
        env = dict(self.env)
        if self.token:
            env['GH_TOKEN'] = self.token
        return run_bounded([self.gh_bin, *args], env, self.workdir, timeout or gh_timeout())

    def gh_json(self, *args):
        rc, out, err, timed_out = self.gh(*args)
        if rc != 0 or timed_out:
            why = 'timed out' if timed_out else f'exit {rc}: {scrub(err, self.token).strip()[-200:]}'
            raise Refused(f'`gh {" ".join(args)}` failed ({why})')
        try:
            return json.loads(out)
        except ValueError:
            raise Refused(f'`gh {" ".join(args)}` did not return JSON')

    def load_token(self):
        rc, out, _, timed_out = self.gh('auth', 'token', '--user', self.owner)
        token = out.strip()
        if rc != 0 or timed_out or not re.fullmatch(r'[\x21-\x7e]{1,4096}', token):
            raise Refused(f'`gh auth token --user {self.owner}` failed in this context (exit {rc}'
                          f'{", timed out" if timed_out else ""}); a launchd/cron run needs the gh keyring '
                          'account to be readable')
        self.token = token

    def ssh_account(self):
        host = REMOTE.fullmatch(self.entry['remote']).group(1)
        rc, out, err, timed_out = run_bounded(
            [self.ssh_bin, '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', f'git@{host}'],
            self.env, self.workdir, 60)
        match = re.search(r'^Hi ([A-Za-z0-9-]+)!', (err or '') + (out or ''), re.M)
        if timed_out or not match:
            raise Refused(f'`ssh -T git@{host}` gave no GitHub greeting (exit {rc})')
        if match.group(1) != self.owner:
            raise Refused(f'`ssh -T git@{host}` authenticates as {match.group(1)}, not {self.owner}')

    def check(self):
        """Every network boundary rule; refuses on the first mismatch."""
        github = self.entry['github']
        self.load_token()
        user = self.gh_json('api', 'user')
        if not isinstance(user, dict) or user.get('login') != self.owner:
            raise Refused(f'gh api user is not {self.owner}')
        self.ssh_account()
        repo = self.gh_json('api', f'repos/{github}')
        if not isinstance(repo, dict) or repo.get('private') is not True:
            raise Refused(f'{github} is not private')
        if repo.get('fork') is not False:
            raise Refused(f'{github} is a fork')
        actions = self.gh_json('api', f'repos/{github}/actions/permissions')
        if not isinstance(actions, dict) or actions.get('enabled') is not False:
            raise Refused(f'{github}: GitHub Actions are enabled; a workflow (on push, per-workflow permissions, '
                          'environment secrets) could run before review. Disable Actions for the repository')
        perms = self.gh_json('api', f'repos/{github}/actions/permissions/workflow')
        if not isinstance(perms, dict) or perms.get('default_workflow_permissions') != 'read':
            raise Refused(f'{github} default workflow permissions are not read')
        found = self.gh_json('api', f'repos/{github}/actions/secrets')
        if not isinstance(found, dict) or found.get('total_count') != 0:
            raise Refused(f'{github} has Actions secrets; a workflow could use them before review')


# --- CLI: harness-profile target add|list|show ---------------------------------------

def pretty(entry, path):
    return json.dumps({'entry': entry, 'path': path}, indent=2, sort_keys=True, ensure_ascii=False) + '\n'


def cmd_add(name, source):
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise Refused('target add needs a terminal: the owner confirms every record by hand '
                      '(an accident guard, not a security boundary)')
    try:
        text = Path(source).read_text(encoding='utf-8')
    except OSError as exc:
        raise Refused(f'cannot read {source}: {exc.strerror}')
    policy = read_policy()
    targets = parse_yaml_text(text)
    entry = check_policy(entry_from_targets(targets, name), policy)
    path = check_live_path(targets[name].get('path'), os.environ['HOME'], policy)
    with tempfile.TemporaryDirectory(prefix='harness-target-') as workdir:
        Remote(entry, workdir, policy).check()
    try:
        old = pretty(*read_record(name, policy))
    except Refused:
        old = None
    new = pretty(entry, path)
    print(f'Policy ({Path(profile_home(), "target-policy.json")}):')
    for key in ('owner', 'ssh_hosts', 'deny_repos', 'home_deny'):
        value = policy[key]
        print(f'  {key}: {value if isinstance(value, str) else ", ".join(value)}')
    print(f'Target {name} (sha256 {digest(entry)}):')
    print(new, end='')
    if old is None:
        print('(no existing record)')
    else:
        diff = list(difflib.unified_diff(old.splitlines(), new.splitlines(), 'current', 'new', lineterm=''))
        print('\n'.join(diff) if diff else '(same as the existing record)')
    sys.stdout.write(f'Retype the target name to write {targets_dir()}/{name}.json: ')
    sys.stdout.flush()
    if sys.stdin.readline().strip() != name:
        print('Not written: the name did not match.', file=sys.stderr)
        return 1
    write_record(name, entry, path)
    print(f'Wrote {targets_dir()}/{name}.json (sha256 {digest(entry)})')
    return 0


def cmd_list():
    policy = read_policy()
    directory = targets_dir()
    for record in sorted(directory.glob('*.json')) if directory.is_dir() else []:
        name = record.stem
        try:
            entry, _ = read_record(name, policy)
            print(f'{name}\t{digest(entry)}\t{entry["github"]}\t{entry["base"]}')
        except Refused as exc:
            print(f'{name}\tINVALID\t{exc}')
    return 0


def cmd_show(name):
    entry, path = read_record(name, read_policy())
    print(f'sha256 {digest(entry)}')
    print(pretty(entry, path), end='')
    return 0


USAGE = '''usage: harness-profile target add <name> --from <targets.yaml>
       harness-profile target list
       harness-profile target show <name>'''


def main(argv):
    try:
        if len(argv) == 4 and argv[0] == 'add' and argv[2] == '--from':
            return cmd_add(argv[1], argv[3])
        if argv == ['list']:
            return cmd_list()
        if len(argv) == 2 and argv[0] == 'show':
            return cmd_show(argv[1])
        print(USAGE, file=sys.stderr)
        return 2
    except Refused as exc:
        print(f'harness-profile: target refused: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
