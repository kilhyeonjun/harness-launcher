#!/usr/bin/env python3
"""Mirror project/local Claude Code plugin install records into an isolated session root.

Claude Code applies a project- or local-scope install record only when its
projectPath is the current project root (or shares its canonical git root). An
isolated session is a separate clone, so plugins installed for the canonical
harness root report "isn't installed" there. Before Claude Code starts, this
helper copies each such record for the canonical root into one for the session
root and drops records for retired session roots.

The registry is Claude Code's user-global installed_plugins.json. Every write
condition fails closed: anything unexpected leaves the file untouched, prints
one warning, and exits 0 so the launch continues.
"""
import argparse
import copy
import fcntl
import json
import os
import re
import sys
import tempfile
import time
import unicodedata

sys.dont_write_bytecode = True

UUID_RE = re.compile(r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}')
SCOPES = ('project', 'local')
LOCK_SUFFIX = '.harness-launcher.lock'
LOCK_TIMEOUT_SECONDS = 10.0
LOCK_POLL_SECONDS = 0.05
MAX_ATTEMPTS = 3


class RegistryRefused(Exception):
    """The registry exists but is not something this helper may rewrite."""


class UsageError(Exception):
    pass


def normalize(path):
    # Claude Code's project root is the realpath of its cwd, NFC-normalized.
    return unicodedata.normalize('NFC', os.path.realpath(path))


def registry_path(env):
    home = env.get('HOME') or os.path.expanduser('~')

    def expand(value):
        if value == '~' or value.startswith('~/'):
            return os.path.join(home, value[2:])
        return value

    cache_dir = env.get('CLAUDE_CODE_PLUGIN_CACHE_DIR')
    if cache_dir:
        return os.path.join(expand(cache_dir), 'installed_plugins.json')
    config_dir = expand(env.get('CLAUDE_CONFIG_DIR') or os.path.join(home, '.claude'))
    name = 'cowork_plugins' if env.get('CLAUDE_CODE_USE_COWORK_PLUGINS') else 'plugins'
    return os.path.join(config_dir, name, 'installed_plugins.json')


def read_bytes(path):
    with open(path, 'rb') as fh:
        return fh.read()


def load_registry(path):
    """Return (raw bytes, parsed data), None when absent; raise RegistryRefused."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    if os.path.islink(path):
        raise RegistryRefused('the registry is a symlink')
    if not os.path.isfile(path):
        raise RegistryRefused('the registry is not a regular file')
    if st.st_nlink > 1:
        raise RegistryRefused('the registry has more than one hard link')
    raw = read_bytes(path)
    return raw, parse_registry(raw)


def _reject_constant(name):
    raise ValueError(f'non-standard JSON constant {name}')


def parse_registry(raw):
    try:
        data = json.loads(raw.decode('utf-8'), parse_constant=_reject_constant)
    except (UnicodeDecodeError, ValueError) as exc:
        raise RegistryRefused(f'the registry is not valid JSON ({exc.__class__.__name__})') from None
    if not isinstance(data, dict):
        raise RegistryRefused('the registry is not a JSON object')
    version = data.get('version')
    if not (isinstance(version, int) and not isinstance(version, bool) and version == 2):
        raise RegistryRefused('the registry is not format version 2')
    plugins = data.get('plugins')
    if not isinstance(plugins, dict) or not all(
            isinstance(records, list) and all(isinstance(rec, dict) for rec in records)
            for records in plugins.values()):
        raise RegistryRefused('the registry plugins table has an unexpected shape')
    return data


def serialize(data):
    # Claude Code writes JSON.stringify(data, null, 2): no trailing newline.
    # allow_nan=False: an out-of-range number parsed as inf must not come back
    # as the non-standard token Infinity.
    try:
        return json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False).encode('utf-8')
    except UnicodeEncodeError:
        raise RegistryRefused('the registry holds a string that cannot be re-encoded') from None
    except ValueError:
        raise RegistryRefused('the registry holds a number outside the JSON range') from None


def _record_path(rec):
    # Claude Code records absolute paths; anything else never matches.
    path = rec.get('projectPath')
    return normalize(path) if isinstance(path, str) and os.path.isabs(path) else None


def plan(data, source, session, worktrees):
    """Return (new data, desired mirrored records as (plugin id, record) pairs)."""
    new = copy.deepcopy(data)
    plugins = new['plugins']

    def launcher_owned(rec):
        path = _record_path(rec) if rec.get('scope') in SCOPES else None
        return (path is not None and os.path.dirname(path) == worktrees
                and UUID_RE.fullmatch(os.path.basename(path)) is not None)

    for plugin_id in list(plugins):
        records = plugins[plugin_id]
        kept = [rec for rec in records if not (launcher_owned(rec) and not os.path.isdir(_record_path(rec)))]
        if len(kept) != len(records):
            if kept:
                plugins[plugin_id] = kept
            else:
                del plugins[plugin_id]

    desired_records = []
    for plugin_id, records in plugins.items():
        sources = [rec for rec in records if rec.get('scope') in SCOPES and _record_path(rec) == source]
        for src in sources:
            desired = {key: (session if key == 'projectPath' else value) for key, value in src.items()}
            desired_records.append((plugin_id, desired))
            existing = next((i for i, rec in enumerate(records)
                             if rec.get('scope') == src.get('scope') and _record_path(rec) == session), None)
            if existing is None:
                records.append(desired)
            elif records[existing] != desired:
                records[existing] = desired
    return new, desired_records


def _warn(stderr, reason):
    print(f'harness-launcher: warning: Claude plugin install records not mirrored: {reason}', file=stderr)


def _acquire_lock(lock_path):
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                return None
            time.sleep(LOCK_POLL_SECONDS)


def _fsync_dir(directory):
    # Best effort: the replace already happened, so a failure here must not be
    # reported as an unmirrored record.
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _write_attempt(path, raw, payload, mode):
    """Replace the registry with payload unless it changed since raw was read."""
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix='.installed_plugins.json.harness-launcher.', suffix='.tmp')
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'wb') as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        if read_bytes(path) != raw:
            return False
        os.replace(tmp, path)
        tmp = None
        _fsync_dir(directory)
        return True
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass


def _validate_args(source_root, session_root, worktrees_dir):
    if os.path.islink(worktrees_dir) or not os.path.isdir(worktrees_dir):
        raise UsageError('the worktrees directory must be an existing non-symlink directory')
    worktrees = normalize(worktrees_dir)
    if os.path.islink(session_root) or not os.path.isdir(session_root):
        raise UsageError('the session root must be an existing non-symlink directory')
    session = normalize(session_root)
    if os.path.dirname(session) != worktrees or UUID_RE.fullmatch(os.path.basename(session)) is None:
        raise UsageError('the session root must be a UUID-named child of the worktrees directory')
    if not os.path.isdir(source_root):
        raise UsageError('the source root must be an existing directory')
    source = normalize(source_root)
    if source == session:
        raise UsageError('the source root and the session root must differ')
    return source, session, worktrees


def ensure(source_root, session_root, worktrees_dir, env=None, stderr=None):
    env = os.environ if env is None else env
    stderr = sys.stderr if stderr is None else stderr
    try:
        source, session, worktrees = _validate_args(source_root, session_root, worktrees_dir)
    except UsageError as exc:
        print(f'harness-launcher: claude-plugin-scope-mirror: {exc}', file=stderr)
        return 2
    path = registry_path(env)
    try:
        loaded = load_registry(path)
        if loaded is None:
            return 0
        new, _ = plan(loaded[1], source, session, worktrees)
        if new == loaded[1]:
            return 0
    except (RegistryRefused, OSError) as exc:
        _warn(stderr, exc)
        return 0

    lock_fd = None
    try:
        lock_fd = _acquire_lock(path + LOCK_SUFFIX)
        if lock_fd is None:
            _warn(stderr, f'the registry lock was busy for {LOCK_TIMEOUT_SECONDS:g}s')
            return 0
        for _ in range(MAX_ATTEMPTS):
            loaded = load_registry(path)
            if loaded is None:
                return 0
            raw, data = loaded
            new, desired = plan(data, source, session, worktrees)
            if new == data:
                return 0
            mode = os.stat(path).st_mode & 0o777
            if not _write_attempt(path, raw, serialize(new), mode):
                continue
            after = parse_registry(read_bytes(path))
            if not all(rec in after['plugins'].get(plugin_id, []) for plugin_id, rec in desired):
                _warn(stderr, 'the registry changed right after the write; the next launch retries')
            return 0
        _warn(stderr, f'the registry kept changing during {MAX_ATTEMPTS} attempts')
        return 0
    except (RegistryRefused, OSError) as exc:
        _warn(stderr, exc)
        return 0
    finally:
        if lock_fd is not None:
            os.close(lock_fd)


def main(argv=None):
    parser = argparse.ArgumentParser(prog='claude-plugin-scope-mirror.py')
    sub = parser.add_subparsers(dest='command', required=True)
    cmd = sub.add_parser('ensure')
    cmd.add_argument('--source-root', required=True)
    cmd.add_argument('--session-root', required=True)
    cmd.add_argument('--worktrees-dir', required=True)
    args = parser.parse_args(argv)
    return ensure(args.source_root, args.session_root, args.worktrees_dir)


if __name__ == '__main__':
    sys.exit(main())
