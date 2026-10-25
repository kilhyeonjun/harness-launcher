"""Installed producer bridge and immutable launcher session overlays."""
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time


class Refused(Exception):
    def __init__(self, reason, code=11):
        self.reason, self.code = reason, code


def physical_system_path(path):
    path = Path(path).absolute()
    # macOS owns these aliases. Never resolve arbitrary state/session symlinks.
    for alias, target in (('/tmp', '/private/tmp'), ('/var', '/private/var')):
        alias = Path(alias)
        if path == alias or alias in path.parents:
            if alias.is_symlink() and alias.lstat().st_uid == 0 and os.path.normpath(str(alias.parent / os.readlink(alias))) == target:
                path = Path(target) / path.relative_to(alias)
            break
    return path


def private_directory(path):
    path = physical_system_path(path)
    for parent in reversed((path, *path.parents)):
        if not parent.exists():
            parent.mkdir(mode=0o700)
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise Refused('unsafe_release_parent')
    info = path.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise Refused('unsafe_release_parent')
    return path


def profile(source, base):
    value = subprocess.run(['git', '-C', str(source), 'show', base + ':config/launcher.env'],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if value.returncode:
        return None
    matches = re.findall(r'^HARNESS_PREFIX=[\"\']?([A-Za-z_][A-Za-z0-9_-]*)[\"\']?\s*$', value.stdout.decode(), re.M)
    if len(matches) != 1:
        return None
    return matches[0]


def host_profile(source, base):
    prefix = profile(source, base)
    if not prefix:
        return None
    host = physical_system_path(Path.home() / '.config/harness-launcher/release' / (prefix + '.json'))
    # Never resolve away a host configuration link, including dangling links.
    for parent in reversed(host.parent.parents):
        if not os.path.lexists(parent):
            return None
        if not stat.S_ISDIR(parent.lstat().st_mode):
            raise Refused('release_host_profile_invalid')
    if not os.path.lexists(host.parent):
        return None
    if not stat.S_ISDIR(host.parent.lstat().st_mode):
        raise Refused('release_host_profile_invalid')
    if not os.path.lexists(host):
        return None
    info = host.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise Refused('release_host_profile_invalid')
    if not isinstance(json.loads(host.read_text()), dict):
        raise Refused('release_host_profile_invalid')
    return prefix


def remaining(deadline):
    seconds = math.floor(deadline - time.time())
    if seconds < 1:
        raise Refused('release_deadline', 43)
    return min(120, seconds)


def client(args, deadline):
    entry = Path.home() / '.local/share/harness-service/bin/harness-service'
    try:
        info = entry.lstat()
    except OSError:
        raise Refused('installed_release_client_unavailable')
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022 or not os.access(entry, os.X_OK):
        raise Refused('installed_release_client_invalid')
    if args[0] not in ('select', 'resume', 'verify-local', 'verify-overlay', 'export'):
        raise Refused('release_command_invalid')
    try:
        return subprocess.run([str(entry), 'release', *map(str, args)], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env={'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'},
                              timeout=remaining(deadline))
    except subprocess.TimeoutExpired:
        raise Refused('release_deadline', 43)


def require_result(result):
    if result.returncode:
        sys.stderr.buffer.write(result.stderr)
        raise Refused('release_selection_failed', result.returncode)
    return result.stdout.decode().strip()


def save(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
    with os.fdopen(fd, 'w') as stream:
        stream.write(data)


def load(directory):
    return json.loads((Path(directory) / 'release-state.json').read_text())


def export(directory, state, deadline):
    if remaining(deadline) < 15:
        raise Refused('release_deadline', 43)
    destination = Path(directory) / ('release-' + os.urandom(8).hex())
    result = require_result(client(['export', '--profile', state['profile'], '--release', state['release_id'], '--dir', destination], deadline))
    fields = result.split()
    if len(fields) != 4 or fields[:2] != [state['release_id'], state['manifest_sha256']]:
        raise Refused('release_export_identity')
    return destination


def select(source, base, directory, deadline):
    directory = private_directory(directory)
    prefix = profile(source, base)
    state = {'mode': 'git', 'profile': prefix, 'deadline': deadline}
    if host_profile(source, base):
        result = require_result(client(['select', '--profile', prefix, '--source', source, '--base', base,
                                        '--deadline-seconds', remaining(deadline), '--pin-out', directory / 'release-pin.json',
                                        '--overlay-paths-out', directory / 'overlay-paths'], deadline))
        fields = result.split()
        if len(fields) != 5 or fields[0] not in ('git', 'release', 'git_fallback'):
            raise Refused('release_selection_protocol')
        state.update(zip(('mode', 'release_id', 'manifest_sha256', 'base_fence_state', 'banner'), fields))
        if fields[4] != '-':
            print(fields[4], file=sys.stderr)
        if state['mode'] == 'release':
            state['export'] = str(export(directory, state, deadline))
    save(directory / 'release-state.json', json.dumps(state))
    return state


def checked_path(root, name):
    parts = PurePosixPath(name).parts
    if not parts or name.startswith('/') or any(part in ('..', '.', '.git') for part in parts):
        raise Refused('release_overlay_path')
    path = Path(root)
    for part in parts:
        path /= part
        if path.is_symlink():
            raise Refused('release_overlay_symlink')
    return path


def materialize(directory, root):
    state = load(directory)
    if state['mode'] != 'release':
        return
    remaining(state['deadline'])
    source = Path(state['export'])
    names = []
    if (source / '.harness').exists():
        for item in (source / '.harness').rglob('*'):
            if item.is_file():
                names.append(item.relative_to(source).as_posix())
    overlay = Path(directory) / 'overlay-paths'
    if overlay.exists():
        raw = overlay.read_bytes()
        if raw and not raw.endswith(b'\0'):
            raise Refused('release_overlay_paths')
        names.extend(os.fsdecode(p) for p in raw.split(b'\0') if p)
    for name in dict.fromkeys(names):
        src, dest = checked_path(source, name), checked_path(root, name)
        if src.exists():
            if not src.is_file():
                raise Refused('release_overlay_type')
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest)
            dest.chmod(0o644)
        elif dest.exists():
            if not dest.is_file():
                raise Refused('release_overlay_type')
            dest.unlink()
    for gitdir in (Path(root) / '.git', Path(directory) / 'trusted.git'):
        if not gitdir.exists():
            continue
        cmd = ['git', '--git-dir=' + str(gitdir), '--work-tree=' + str(root)]
        tracked = subprocess.check_output([*cmd, 'ls-files', '-z']).split(b'\0')
        tracked = set(tracked)
        # Git exclude files cannot represent a literal newline. Keep those
        # release-only members in the private index instead of a broad glob.
        for name in names:
            raw = os.fsencode(name)
            if ('\n' in name or '\r' in name) and raw not in tracked and checked_path(root, name).is_file():
                oid = subprocess.check_output([*cmd, 'hash-object', '-w', '--', str(checked_path(root, name))]).strip()
                subprocess.run([*cmd, 'update-index', '-z', '--index-info'], input=b'100644 ' + oid + b'\t' + raw + b'\0', check=True)
                tracked.add(raw)
        skip = b''.join(os.fsencode(n) + b'\0' for n in names if os.fsencode(n) in tracked)
        if skip:
            subprocess.run([*cmd, 'update-index', '--skip-worktree', '-z', '--stdin'], input=skip, check=True)
        with (gitdir / 'info/exclude').open('a') as exclusions:
            exclusions.write('/.harness/\n')
            for name in names:
                # Git wildmatch's bracket and metacharacters must stay literal.
                escaped = ''.join('\\' + c if c in '\\*?[]#! ' else c for c in name)
                if '\n' in name or '\r' in name:
                    continue
                exclusions.write('/' + escaped + '\n')
    remaining(state['deadline'])


def operation_deadline(directory, state):
    marker = Path(directory) / 'runtime-deadline'
    return float(marker.read_text()) if marker.exists() else state['deadline']


def resume(directory, deadline=None):
    state = load(directory)
    if state['mode'] != 'release':
        return state
    deadline = deadline if deadline is not None else time.time() + 120
    result = require_result(client(['resume', '--profile', state['profile'], '--pin', Path(directory) / 'release-pin.json',
                                    '--deadline-seconds', remaining(deadline)], deadline))
    fields = result.split()
    if len(fields) != 5 or fields[:3] != ['release', state['release_id'], state['manifest_sha256']]:
        raise Refused('release_resume_identity')
    if fields[4] != '-':
        print(fields[4], file=sys.stderr)
    return state


def check(directory):
    state = load(directory)
    overlay = Path(directory) / 'overlay-paths'
    if state['mode'] != 'release' or not overlay.exists():
        return 0
    result = client(['verify-overlay', '--profile', state['profile'], '--pin', Path(directory) / 'release-pin.json',
                     '--worktree', (Path(directory) / 'session-root').read_text().strip(), '--overlay-paths', overlay], time.time() + 120)
    if result.returncode == 0:
        return 0
    try:
        drift = json.loads(result.stdout)['drift_paths']
        if result.returncode != 1 or not isinstance(drift, list) or not drift:
            raise ValueError()
        print('overlay_drift ' + json.dumps({'drift_paths': drift}, ensure_ascii=False), file=sys.stderr)
    except (ValueError, KeyError, TypeError):
        print('overlay_verification_failed', file=sys.stderr)
    return 12


def runtime_directory(root):
    state_home = physical_system_path(Path(os.environ.get('HARNESS_SESSION_STATE_HOME', os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state')) + '/harness-launcher')))
    root = physical_system_path(root)
    # Identity comes from the actual broker worktree and its private record,
    # never an inherited HARNESS_SESSION_ID.
    if root.parent == state_home / 'worktrees' and re.fullmatch(r'[0-9a-fA-F-]{36}', root.name):
        directory = state_home / 'sessions' / root.name
        record = directory / 'session-root'
        for parent in (root, *root.parents, directory, *directory.parents):
            if not stat.S_ISDIR(parent.lstat().st_mode):
                raise Refused('unsafe_release_parent')
        if not stat.S_ISREG(record.lstat().st_mode) or record.stat().st_uid != os.getuid() or record.stat().st_mode & 0o022:
            raise Refused('unsafe_release_parent')
        info = directory.stat()
        if info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise Refused('unsafe_release_parent')
        if physical_system_path(record.read_text().strip()) != root:
            raise Refused('unsafe_release_parent')
        # Pre-pin records remain Git sessions, without selecting or writing.
        state = directory / 'release-state.json'
        if not os.path.lexists(state):
            return None
        info = state.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise Refused('unsafe_release_parent')
        return directory
    if not host_profile(root, 'HEAD'):
        return None
    key = __import__('hashlib').sha256(str(root.resolve()).encode()).hexdigest()
    return private_directory(state_home / 'release-runtime' / key)


def runtime_context(source):
    # The verified export path is the operation handle passed unchanged by the
    # wrapper. There is no shared pointer to another invocation's selection.
    source = physical_system_path(source)
    operation = source.parent.parent
    if source.parent.name != 'runtime' or not re.fullmatch(r'release-[0-9a-f]{16}', source.name) or not re.fullmatch(r'operation-[A-Za-z0-9_-]+', operation.name):
        raise Refused('release_operation_invalid')
    for parent in (operation, *operation.parents):
        if not stat.S_ISDIR(parent.lstat().st_mode):
            raise Refused('release_operation_invalid')
    info = operation.stat()
    context = operation / 'runtime-context.json'
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700 or not stat.S_ISREG(context.lstat().st_mode):
        raise Refused('release_operation_invalid')
    return operation, json.loads(context.read_text())


def runtime_source(root):
    if subprocess.run(['git', '-C', root, 'rev-parse', '--is-inside-work-tree'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        return
    directory = runtime_directory(root)
    if directory is None:
        return
    pinned = (directory / 'session-root').exists()
    state = load(directory) if pinned else None
    if state is not None and state['mode'] != 'release':
        return
    operation = Path(tempfile.mkdtemp(prefix='operation-', dir=directory))
    try:
        # A recorded deadline belongs to create/resume, not to every future
        # launch of this worktree. Only its explicitly bound continuation may
        # consume that budget; a standalone preparation starts a new one.
        broker_root = os.environ.get('HARNESS_RELEASE_OPERATION_ROOT')
        if broker_root:
            if not pinned or physical_system_path(broker_root) != physical_system_path(root):
                raise Refused('release_operation_invalid')
            deadline = operation_deadline(directory, state)
        else:
            deadline = time.time() + 120
        if not pinned:
            base = subprocess.check_output(['git', '-C', root, 'rev-parse', 'HEAD']).decode().strip()
            state = select(root, base, operation, deadline)
        if state['mode'] != 'release':
            shutil.rmtree(operation)
            return
        runtime = private_directory(directory / 'runtime')
        resume(directory if pinned else operation, deadline)
        destination = export(private_directory(operation / 'runtime'), state, deadline)
        save(operation / 'runtime-context.json', json.dumps({'deadline': deadline, 'home': str(runtime / 'codex')}))
        print(destination)
    except Exception:
        shutil.rmtree(operation)
        raise


def main():
    command, *args = sys.argv[1:]
    if command == 'budget':
        try:
            return subprocess.run(args[1:], timeout=remaining(float(args[0]))).returncode
        except subprocess.TimeoutExpired:
            raise Refused('release_deadline', 43)
    elif command == 'profile':
        print(profile(args[0], args[1]) or '')
    elif command == 'host-profile':
        print(host_profile(args[0], args[1]) or '')
    elif command == 'select':
        select(args[0], args[1], args[2], float(args[3]))
    elif command == 'materialize':
        materialize(*args)
    elif command == 'resume':
        if (Path(args[0]) / 'release-state.json').exists():
            deadline = time.time() + 120
            resume(args[0], deadline)
            marker = Path(args[0]) / ('runtime-deadline-' + os.urandom(8).hex())
            save(marker, str(deadline))
            os.replace(marker, Path(args[0]) / 'runtime-deadline')
    elif command == 'check':
        return check(args[0]) if (Path(args[0]) / 'release-state.json').exists() else 0
    elif command == 'run':
        state = load(args[0])
        try:
            return subprocess.run(args[1:], timeout=remaining(state['deadline'])).returncode
        except subprocess.TimeoutExpired:
            raise Refused('release_deadline', 43)
    elif command == 'runtime-cleanup':
        operation, _ = runtime_context(args[0])
        shutil.rmtree(operation)
    elif command == 'runtime-run':
        if not args[0]:
            return subprocess.run(args[1:]).returncode
        _, context = runtime_context(args[0])
        try:
            return subprocess.run(args[1:], timeout=remaining(context['deadline'])).returncode
        except subprocess.TimeoutExpired:
            raise Refused('release_deadline', 43)
    elif command == 'runtime-source':
        runtime_source(args[0])
    elif command == 'runtime-home':
        if args[0]:
            _, context = runtime_context(args[0])
            print(context['home'])
    else:
        raise Refused('release_command_invalid')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Refused as error:
        print(error.reason, file=sys.stderr)
        sys.exit(error.code)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print('release_client_failed: ' + str(error), file=sys.stderr)
        sys.exit(11)
