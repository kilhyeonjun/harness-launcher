#!/usr/bin/python3
"""One-operation released native approval carrier; never a canonical write CLI.

The private transaction owns all repository effects. This process admits code,
retains its ownership evidence and carries a single native session's lifecycle.
"""
import ctypes
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
import uuid

SCHEMA = 'launcher-canonical-bootstrap-control/v1'
PIN_SCHEMA = 'launcher-canonical-bootstrap/v2'
SOURCE_SCHEMA = 'canonical-bootstrap-source/v1'
STATE = '.local/state/kilhyeonjun-harness/launcher-runtimes'
SYSTEM_PYTHON = '/usr/bin/python3'
INSTALLED_SELECTOR = '/opt/homebrew/opt/harness-launcher/share/harness-launcher/harness_omp_projection.py'
FILES = tuple(sorted(('core/scripts/omp_canonical_update.ts',
    'core/scripts/omp_canonical_update_lock.py', 'core/scripts/canonical_occupancy.py',
    'core/scripts/launcher_runtime_snapshot.py', 'core/scripts/harness_compile.py',
    'core/scripts/cross_harness_surface_diff.py', 'core/omp/model_modes.py')))
LIMIT = 65536
HEX40 = re.compile('[0-9a-f]{40}')
HEX64 = re.compile('[0-9a-f]{64}')
HEX32 = re.compile('[0-9a-f]{32}')


class BootstrapError(ValueError):
    pass


class BootstrapEffectUnknown(BootstrapError):
    """Native execution began but no trustworthy final result was consumed."""
    def __init__(self, code, receipt_path):
        super().__init__(code)
        self.receipt_path = str(receipt_path)


def require(value, code='BOOTSTRAP_UNBOUND'):
    if not value:
        raise BootstrapError(code)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def pairs(items):
    value = {}
    for key, item in items:
        require(key not in value, 'BOOTSTRAP_DUPLICATE_KEY')
        value[key] = item
    return value


def decode(raw, limit=LIMIT):
    require(len(raw) <= limit, 'BOOTSTRAP_MESSAGE_SIZE')
    return json.loads(raw.decode('utf-8'), object_pairs_hook=pairs,
                      parse_constant=lambda _: require(False, 'BOOTSTRAP_JSON'))


def identity(info):
    return {key: str(value) for key, value in (
        ('dev', info.st_dev), ('ino', info.st_ino), ('uid', info.st_uid),
        ('mode', stat.S_IMODE(info.st_mode)), ('nlink', info.st_nlink),
        ('size', info.st_size), ('mtime_ns', info.st_mtime_ns), ('ctime_ns', info.st_ctime_ns))}


def stable(info):
    return info.st_dev, info.st_ino, info.st_uid, stat.S_IMODE(info.st_mode), stat.S_IFMT(info.st_mode)


def ancestry(path, mode=None, directory=None):
    path = Path(path)
    require(path.is_absolute() and str(path) == os.path.normpath(path), 'BOOTSTRAP_PATH')
    for node in (path, *path.parents):
        info = node.lstat()
        require(not stat.S_ISLNK(info.st_mode) and info.st_uid in (0, os.getuid())
                and not info.st_mode & 0o022, 'BOOTSTRAP_UNSAFE_ANCESTRY')
        if node != path:
            require(stat.S_ISDIR(info.st_mode), 'BOOTSTRAP_UNSAFE_ANCESTRY')
    info = path.lstat()
    if mode is not None:
        require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == mode,
                'BOOTSTRAP_UNSAFE_MODE')
    if directory is not None:
        require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
                'BOOTSTRAP_FILE_TYPE')
    return path


def account_home():
    require(sys.platform == 'darwin', 'BOOTSTRAP_DARWIN_REQUIRED')
    return ancestry(Path(pwd.getpwuid(os.getuid()).pw_dir), directory=True)


def environment(home, inherited=None):
    inherited = os.environ if inherited is None else inherited
    terminal = inherited.get('TERM', 'xterm-256color')
    if not re.fullmatch(r'[A-Za-z0-9._+\-]{1,64}', terminal):
        terminal = 'xterm-256color'
    result = {'HOME': str(home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
              'LANG': 'en_US.UTF-8', 'LC_ALL': 'C', 'TERM': terminal,
              'HARNESS_CANONICAL_BOOTSTRAP_SANITIZED': '1'}
    # Only the original updater's independently checked Git authentication socket
    # is inherited. No model/provider credentials or existing native home enter.
    if inherited.get('SSH_AUTH_SOCK'):
        result['SSH_AUTH_SOCK'] = inherited['SSH_AUTH_SOCK']
    return result


def read_file(path, mode, limit=1048576):
    path = ancestry(path, mode, False)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(before.st_nlink == 1 and before.st_size <= limit, 'BOOTSTRAP_FILE_IDENTITY')
        raw = os.read(fd, limit + 1)
        require(len(raw) == before.st_size and identity(os.fstat(fd)) == identity(before)
                and identity(path.lstat()) == identity(before), 'BOOTSTRAP_FILE_CHANGED')
        return raw, identity(before)
    finally:
        os.close(fd)


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    sys.modules[name] = value
    spec.loader.exec_module(value)
    return value


def selected_bin(home):
    done = subprocess.run([SYSTEM_PYTHON, '-I', '-S', '-B', INSTALLED_SELECTOR, 'dispatch-source'],
                          env=environment(home), stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15)
    require(done.returncode == 0 and len(done.stdout) <= 4096, 'BOOTSTRAP_CURRENT_UNAVAILABLE')
    result = Path(done.stdout.decode('utf-8').strip())
    require(result.parent.parent == home / STATE and HEX40.fullmatch(result.parent.name)
            and result.name == 'bin', 'BOOTSTRAP_CURRENT_UNBOUND')
    return result


def dispatch(home, argv):
    directory = selected_bin(home)
    target = directory / 'harness_canonical_bootstrap.py'
    require(target.is_file() and not target.is_symlink(), 'BOOTSTRAP_RUNTIME_NOT_INSTALLED')
    if Path(__file__).absolute() != target:
        require(argv != ['_observe'], 'BOOTSTRAP_RUNTIME_CHANGED')
        os.execve(SYSTEM_PYTHON, [SYSTEM_PYTHON, '-I', '-S', '-B', str(target), *argv], environment(home))
    projection = module('_canonical_bootstrap_projection', directory / 'harness_omp_projection.py')
    # The fixed installed selector has just authenticated this whole code tree.
    require(Path(projection.dispatch_source()) == directory, 'BOOTSTRAP_RUNTIME_CHANGED')
    return directory, projection


def observer_directory(home):
    """Current immutable observer closure; parent retains the full package proof."""
    raw, _ = read_file(home / STATE / 'current.json', 0o600, 131072)
    current = decode(raw)
    require(type(current) is dict and set(current) == {'version', 'revision', 'path', 'manifest_sha256'}
            and type(current['revision']) is str and HEX40.fullmatch(current['revision'])
            and type(current['manifest_sha256']) is str and HEX64.fullmatch(current['manifest_sha256']),
            'BOOTSTRAP_CURRENT_UNBOUND')
    root = home / STATE / current['revision']
    directory = root / 'bin'
    require(current['path'] == str(root) and Path(__file__).absolute() == directory / 'harness_canonical_bootstrap.py',
            'BOOTSTRAP_RUNTIME_CHANGED')
    ancestry(root, 0o500, True)
    ancestry(directory, 0o500, True)
    raw, _ = read_file(root / 'manifest.json', 0o400, 131072)
    manifest = decode(raw, 131072)
    require(digest(raw) == current['manifest_sha256'] and set(manifest) == {'version', 'revision', 'files'}
            and manifest['version'] == current['version'] and manifest['revision'] == current['revision'],
            'BOOTSTRAP_RUNTIME_CHANGED')
    for name in ('harness_canonical_bootstrap.py', 'harness_omp_projection.py',
                 'harness_omp_continuation.py', 'omp_canonical_bootstrap.mjs', 'canonical-bootstrap-source.json'):
        row = manifest['files'].get('bin/' + name)
        require(type(row) is dict and set(row) == {'mode', 'sha256'} and row['mode'] in (0o400, 0o500),
                'BOOTSTRAP_RUNTIME_CHANGED')
        data, _ = read_file(directory / name, row['mode'])
        require(digest(data) == row['sha256'], 'BOOTSTRAP_RUNTIME_CHANGED')
    return directory


STOCK_NATIVE = {'release': {'version': '18.11.3', 'source_revision': '96894a6147d8cc64b7e00ad3a7d7178fd93b9531'},
    'sha256': 'd518310d647d467a2c5c3f2d38e34489a761996d766395c03b37c61a2203d02b', 'bytes': 194982944}
FORK_RELEASE = {'version': '18.11.3-kh-mcp.2', 'source_revision': '273a19ab5c2fddac54c28ffd05184bf2a4447c64',
    'contract_id': 'kh-mcp-runtime-admission/v1', 'upstream_base_version': '18.11.3',
    'upstream_base_revision': '96894a6147d8cc64b7e00ad3a7d7178fd93b9531',
    'source_patch_sha256': 'ae318b194c48aafc23d0d1856adafc8fc625f7e2a76c3e2074b5827018ff3bde'}


def validate_native_profiles(value):
    require(type(value) is dict and set(value) == {'kh', 'gp', 'gd'}, 'BOOTSTRAP_NATIVE_RELEASE')
    for profile, entries in value.items():
        require(type(entries) is list and len(entries) == (2 if profile == 'kh' else 1), 'BOOTSTRAP_NATIVE_RELEASE')
        require(len({canonical(entry) for entry in entries}) == len(entries), 'BOOTSTRAP_NATIVE_RELEASE')
        require(sum(entry == STOCK_NATIVE for entry in entries) == 1, 'BOOTSTRAP_NATIVE_RELEASE')
        for entry in entries:
            require(type(entry) is dict and set(entry) == {'release', 'sha256', 'bytes'}
                    and type(entry['sha256']) is str and HEX64.fullmatch(entry['sha256'])
                    and type(entry['bytes']) is int and entry['bytes'] > 0, 'BOOTSTRAP_NATIVE_RELEASE')
            if entry == STOCK_NATIVE:
                continue
            release = entry['release']
            require(profile == 'kh' and type(release) is dict
                    and set(release) == {*FORK_RELEASE, 'build_provenance_sha256'}
                    and all(release[key] == expected for key, expected in FORK_RELEASE.items())
                    and type(release['build_provenance_sha256']) is str
                    and HEX64.fullmatch(release['build_provenance_sha256']), 'BOOTSTRAP_NATIVE_RELEASE')
    return value


def validate_pin(value):
    require(type(value) is dict and set(value) == {'schema', 'revision', 'manifest_sha256', 'files', 'native_by_profile'}
            and value['schema'] == PIN_SCHEMA, 'BOOTSTRAP_SOURCE_PIN')
    require(type(value['revision']) is str and HEX40.fullmatch(value['revision'])
            and type(value['manifest_sha256']) is str and HEX64.fullmatch(value['manifest_sha256']),
            'BOOTSTRAP_SOURCE_PIN')
    rows = value['files']
    require(type(rows) is list and len(rows) == len(FILES), 'BOOTSTRAP_SOURCE_INVENTORY')
    require(tuple(row.get('path') for row in rows if type(row) is dict) == FILES,
            'BOOTSTRAP_SOURCE_INVENTORY')
    for row in rows:
        require(set(row) == {'path', 'git_mode', 'bytes', 'sha256'}
                and row['git_mode'] == '100644' and type(row['bytes']) is int
                and 0 <= row['bytes'] <= 1048576 and type(row['sha256']) is str
                and HEX64.fullmatch(row['sha256']), 'BOOTSTRAP_SOURCE_INVENTORY')
    validate_native_profiles(value['native_by_profile'])
    return value


def admit_source(home, directory):
    raw, _ = read_file(directory / 'canonical-bootstrap-source.json', 0o400)
    pin = validate_pin(decode(raw))
    root = home / STATE / 'canonical-bootstrap' / pin['revision'] / pin['manifest_sha256']
    ancestry(root, 0o500, True)
    manifest, _ = read_file(root / 'manifest.json', 0o400)
    require(digest(manifest) == pin['manifest_sha256']
            and decode(manifest) == {'schema': SOURCE_SCHEMA, 'files': pin['files']},
            'BOOTSTRAP_SOURCE_MANIFEST')
    expected = set(FILES) | {'manifest.json'}
    found, dirs = set(), {''}
    for row in pin['files']:
        relative = Path(row['path'])
        dirs.update(str(parent) for parent in relative.parents if str(parent) != '.')
        data, _ = read_file(root / relative, 0o400)
        require(len(data) == row['bytes'] and digest(data) == row['sha256'], 'BOOTSTRAP_SOURCE_CONTENT')
    seen_dirs = {''}
    for parent, children, names in os.walk(root, followlinks=False):
        ancestry(parent, 0o500, True)
        for child in children:
            path = Path(parent) / child
            ancestry(path, 0o500, True)
            seen_dirs.add(path.relative_to(root).as_posix())
        found.update((Path(parent) / name).relative_to(root).as_posix() for name in names)
    require(found == expected and seen_dirs == dirs, 'BOOTSTRAP_SOURCE_INVENTORY')
    return pin, root


def kernel_module(source):
    return module('_canonical_bootstrap_kernel', source / 'core/scripts/canonical_occupancy.py')


def process_image(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidpath.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    size = library.proc_pidpath(pid, buffer, len(buffer))
    require(size > 0, 'BOOTSTRAP_PROCESS_IMAGE')
    return buffer.value.decode('utf-8', 'strict')


def process_record(kernel, pid):
    parent, group, owner, generation, args = kernel.kernel_identity(pid)
    return {'pid': pid, 'ppid': parent, 'pgid': group, 'uid': owner,
            'generation': list(generation), 'argv': list(args), 'executable': process_image(pid)}


def same_process(kernel, expected):
    require(process_record(kernel, expected['pid']) == expected, 'BOOTSTRAP_PROCESS_CHANGED')


class Retained:
    """Frozen code/data admission with held-and-named identity rechecks."""
    def __init__(self):
        self.nodes = {}

    def hold(self, path, sealed=False):
        path = Path(path)
        if path in self.nodes:
            return
        before = path.lstat()
        require(not path.is_symlink(), 'BOOTSTRAP_RETAINED_LINK')
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        require(identity(os.fstat(fd)) == identity(before), 'BOOTSTRAP_RETAINED_CHANGED')
        self.nodes[path] = fd, identity(before) if sealed or path.is_file() else stable(before), sealed or path.is_file()
        # Global parent names may grow, but their physical identity/mode cannot.
        if path.parent != path:
            self.hold(path.parent)

    def tree(self, root):
        for parent, children, names in os.walk(root, followlinks=False):
            self.hold(parent, True)
            for name in (*children, *names):
                self.hold(Path(parent) / name, True)

    def check(self):
        for path, (fd, before, full) in self.nodes.items():
            held, named = os.fstat(fd), path.lstat()
            require((identity(held) if full else stable(held)) == before
                    and (identity(named) if full else stable(named)) == before,
                    'BOOTSTRAP_AUTHORITY_CHANGED')

    def close(self):
        for fd, _, _ in self.nodes.values():
            os.close(fd)
        self.nodes.clear()


def profile_context(home, directory, projection, request, pin):
    require(request['profile'] in pin['native_by_profile'], 'BOOTSTRAP_NATIVE_BINDING')
    registry = home / '.config/harness-launcher/profiles'
    raw, _ = read_file(registry / request['profile'], 0o600, 4096)
    root = ancestry(raw.decode('utf-8').strip(), directory=True)
    context = projection.select(request['profile'], str(root), str(directory / 'aliases.zsh'), continuation=True)
    require(context is not None, 'BOOTSTRAP_PROFILE_NOT_ENROLLED')
    validate_native_profiles(pin['native_by_profile'])
    matches = [entry for entry in pin['native_by_profile'][request['profile']]
               if context['binary_release'] == entry['release']
               and context['binary_sha256'] == entry['sha256']
               and type(context['binary_size']) is int and context['binary_size'] == entry['bytes']]
    require(len(matches) == 1, 'BOOTSTRAP_NATIVE_BINDING')
    native = matches[0]
    binary = home / '.local/state/kilhyeonjun-harness/omp-bin' / (native['release']['version'] + '-' + native['sha256'][:8]) / 'bin/omp'
    require(context['binary_path'] == str(binary), 'BOOTSTRAP_NATIVE_BINDING')
    return root, context


def write_record(path, value, mode=0o400):
    raw = canonical(value)
    require(len(raw) <= LIMIT, 'BOOTSTRAP_RECORD_SIZE')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        offset = 0
        while offset < len(raw):
            offset += os.write(fd, raw[offset:])
        os.fsync(fd)
        os.fchmod(fd, mode)
        stamp = identity(os.fstat(fd))
    finally:
        os.close(fd)
    return digest(raw), stamp


def observe(home, directory):
    """A native-created NON-HOLDER observer; never accepts an operation grant."""
    value = decode(sys.stdin.buffer.read(LIMIT + 1))
    require(type(value) is dict and set(value) == {'frame', 'session_id'}, 'BOOTSTRAP_OBSERVER_INPUT')
    frame = value['frame']
    require(type(frame) is dict and frame.get('schema') == SCHEMA
            and HEX32.fullmatch(frame.get('operation_id', ''))
            and HEX32.fullmatch(frame.get('nonce', '')), 'BOOTSTRAP_FRAME')
    control = home / STATE / 'canonical-bootstrap/operations' / frame['operation_id']
    ancestry(control, 0o700, True)
    raw, stamp = read_file(control / 'record.json', 0o400, LIMIT)
    require(stamp == frame['record_identity'] and digest(raw) == frame['record_sha256'], 'BOOTSTRAP_RECORD_CHANGED')
    record = decode(raw)
    require(record == frame['record'] and record['account_home'] == str(home)
            and record['control']['path'] == str(control)
            and record.get('schema') == SCHEMA and record.get('purpose') == 'canonical-update'
            and record.get('operation_id') == frame['operation_id'] and record.get('nonce') == frame['nonce']
            and all(identity(control.lstat())[key] == record['control']['identity'][key]
                    for key in ('dev', 'ino', 'uid', 'mode')), 'BOOTSTRAP_RECORD')
    require(record['expires_at'] > time.time() * 1000, 'BOOTSTRAP_EXPIRED')
    current, _ = read_file(home / STATE / 'current.json', 0o600)
    require(decode(current) == record['runtime'] and directory == Path(record['runtime']['path']) / 'bin',
            'BOOTSTRAP_RUNTIME_CHANGED')
    pin, source = admit_source(home, directory)
    require(record['source'] == {'revision': pin['revision'], 'manifest_sha256': pin['manifest_sha256'], 'path': str(source)},
            'BOOTSTRAP_SOURCE_CHANGED')
    kernel = kernel_module(source)
    require(os.getppid() == record['native']['pid'], 'BOOTSTRAP_OBSERVER_CALLER')
    observer = process_record(kernel, os.getpid())
    same_process(kernel, record['parent'])
    same_process(kernel, record['native'])
    require(record['native']['ppid'] == record['parent']['pid']
            and record['native']['executable'] == record['native']['argv'][0]
            and os.path.samefile(record['parent']['executable'], observer['executable']), 'BOOTSTRAP_PROCESS_BINDING')
    require(record['parent']['argv'][1:5] == ['-I', '-S', '-B', str(directory / 'harness_canonical_bootstrap.py')]
            and (record['parent']['argv'][0] == SYSTEM_PYTHON
                 or os.path.samefile(record['parent']['argv'][0], observer['executable'])), 'BOOTSTRAP_PARENT_ARGV')
    lease = control / 'lease'
    require(record['lease']['path'] == str(lease), 'BOOTSTRAP_LEASE_PATH')
    ancestry(lease, 0o600, False)
    fd = os.open(lease, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        require(identity(os.fstat(fd)) == record['lease']['identity']
                and identity(lease.lstat()) == record['lease']['identity'], 'BOOTSTRAP_LEASE_CHANGED')
        require(kernel.lease_owner(fd) == record['parent']['pid'], 'BOOTSTRAP_LEASE_OWNER')
    finally:
        os.close(fd)  # NOT the holder process: this cannot drop the parent's lock.
    continuation = module('_canonical_bootstrap_continuation', directory / 'harness_omp_continuation.py')
    native = continuation.inspect_native(control / 'history', control / 'cwd')
    require(native['id'] == value['session_id'], 'BOOTSTRAP_NATIVE_SESSION')
    print('{"ok":true}')


def request_from_args(argv):
    require(len(argv) == 6 and argv[::2] == ['--profile', '--expected-base', '--revision'], 'BOOTSTRAP_ARGUMENTS')
    require(re.fullmatch('[A-Za-z_][A-Za-z0-9_-]{0,63}', argv[1]) and HEX40.fullmatch(argv[3]) and HEX40.fullmatch(argv[5]),
            'BOOTSTRAP_ARGUMENTS')
    return {'profile': argv[1], 'expected_base': argv[3], 'revision': argv[5]}


def safe_code(error):
    code = str(error).split(':', 1)[0]
    return code if re.fullmatch('[A-Za-z][A-Za-z0-9_]{0,95}', code) else 'BOOTSTRAP_OPERATION_FAILED'


def run(home, directory, projection, request):
    require(os.isatty(0) and os.isatty(1), 'BOOTSTRAP_MAIN_TUI_REQUIRED')
    pin, source = admit_source(home, directory)
    root, context = profile_context(home, directory, projection, request, pin)
    kernel = kernel_module(source)
    runtime_raw, _ = read_file(home / STATE / 'current.json', 0o600)
    runtime = decode(runtime_raw)
    base = home / STATE / 'canonical-bootstrap'
    operations = base / 'operations'
    if not operations.exists():
        operations.mkdir(mode=0o700)
    ancestry(operations, 0o700, True)
    operation = uuid.uuid4().hex
    control = operations / operation
    control.mkdir(mode=0o700)
    for name in ('home', 'agent', 'history', 'cwd', 'tmp', 'cache', 'config', 'state', 'data'):
        (control / name).mkdir(mode=0o700)
    config = control / 'bootstrap.yml'
    write_record(control / 'request.json', request)
    fd = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, b'startup:\n  setupWizard: false\ndev:\n  autoqa: false\nmcp:\n  enableProjectConfig: false\n')
    finally:
        os.close(fd)
    parent_socket, child_socket = socket.socketpair()
    for channel in (parent_socket, child_socket):
        channel.setsockopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO, struct.pack('ll', 5, 0))
        channel.setsockopt(socket.SOL_SOCKET, socket.SO_SNDTIMEO, struct.pack('ll', 5, 0))
    require(3 <= child_socket.fileno() <= 128, 'BOOTSTRAP_CONTROL_FD')
    alive_read, alive_write = os.pipe()
    child_alive_fd = alive_read
    alive_identity = identity(os.fstat(alive_read))
    require(3 <= child_alive_fd <= 128, 'BOOTSTRAP_CONTROL_FD')
    def revoke_liveness():
        nonlocal alive_write
        if alive_write is not None:
            os.close(alive_write)
            alive_write = None
    lease_path = control / 'lease'
    lease = os.open(lease_path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    # Never open/close a second descriptor for this inode in the holder process.
    fcntl.lockf(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
    retained = Retained()
    child = None
    native_identity = None
    final = None
    bound_session = None
    native_header = None
    failures = []
    started = time.monotonic()
    cancelled = False
    try:
        retained.tree(directory.parent)
        retained.tree(source)
        for path in (home / STATE / 'current.json',
                     home / '.config/harness-launcher/profiles' / request['profile'],
                     home / '.config/harness-launcher/omp-projection-v1/enrollment.json',
                     home / '.config/harness-launcher/omp-projection-v1/state.json',
                     Path(context['namespace_path']) / '.owner.json', Path(context['binary_path'])):
            retained.hold(path, True)
        for path in (home, base, operations, control):
            retained.hold(path)
        env = environment(home)
        env.update(HOME=str(control / 'home'), PI_CODING_AGENT_DIR=str(control / 'agent'),
                   XDG_CACHE_HOME=str(control / 'cache'), XDG_CONFIG_HOME=str(control / 'config'),
                   XDG_STATE_HOME=str(control / 'state'), XDG_DATA_HOME=str(control / 'data'), TMPDIR=str(control / 'tmp'),
                   HARNESS_CANONICAL_BOOTSTRAP_FD=str(child_socket.fileno()),
                   HARNESS_CANONICAL_BOOTSTRAP_ALIVE_FD=str(child_alive_fd))
        argv = [context['binary_path'], '--no-extensions', '--trusted-extension=' + str(directory / 'omp_canonical_bootstrap.mjs'),
                '--no-skills', '--no-rules', '--no-tools', '--no-lsp', '--no-title', '--no-prewalk',
                '--config=' + str(config), '--session-dir=' + str(control / 'history')]
        parent_identity = process_record(kernel, os.getpid())
        child = subprocess.Popen(argv, cwd=control / 'cwd', env=env,
                                 pass_fds=(child_socket.fileno(), child_alive_fd), start_new_session=True)
        child_socket.close()
        os.close(alive_read)
        alive_read = None
        native_identity = process_record(kernel, child.pid)
        require(native_identity['ppid'] == os.getpid() and native_identity['pgid'] == child.pid
                and native_identity['argv'] == argv and native_identity['executable'] == context['binary_path'],
                'BOOTSTRAP_NATIVE_PROCESS')
        nonce = uuid.uuid4().hex
        record = {'schema': SCHEMA, 'purpose': 'canonical-update', 'operation_id': operation, 'nonce': nonce,
                  'request': request, 'request_sha256': digest(canonical(request)),
                  'expires_at': int(time.time() * 1000) + 300000, 'runtime': runtime,
                  'source': {'revision': pin['revision'], 'manifest_sha256': pin['manifest_sha256'], 'path': str(source)},
                  'account_home': str(home), 'parent': parent_identity, 'native': native_identity,
                  'control': {'path': str(control), 'identity': identity(control.lstat())},
                  'lease': {'path': str(lease_path), 'identity': identity(os.fstat(lease))},
                  'liveness': {'read_fd': child_alive_fd, 'identity': alive_identity},
                  'registered_root': str(root), 'context': context}
        record_sha, record_identity = write_record(control / 'record.json', record)
        retained.hold(control / 'record.json', True)
        frame = {'schema': SCHEMA, 'operation_id': operation, 'nonce': nonce,
                 'record_sha256': record_sha, 'record_identity': record_identity, 'record': record}
        frame_raw = canonical(frame) + b'\n'
        require(len(frame_raw) <= LIMIT, 'BOOTSTRAP_MESSAGE_SIZE')
        parent_socket.sendall(frame_raw)
        continuation = module('_canonical_bootstrap_continuation', directory / 'harness_omp_continuation.py')
        def check():
            require(not cancelled and time.monotonic() - started < 300
                    and time.time() * 1000 < record['expires_at'], 'BOOTSTRAP_EXPIRED')
            retained.check()
            projection.fresh(context['valid_until'])
            same_process(kernel, parent_identity)
            same_process(kernel, native_identity)
            require(identity(os.fstat(lease)) == record['lease']['identity']
                    and identity(lease_path.lstat()) == record['lease']['identity'], 'BOOTSTRAP_LEASE_CHANGED')
            if bound_session:
                observed = continuation.inspect_native(control / 'history', control / 'cwd')
                try:
                    continuation.same_native(native_header, observed)
                except continuation.ContinuationError:
                    raise BootstrapError('BOOTSTRAP_NATIVE_SESSION_CHANGED') from None
        cancelled_at = None
        def cancel(_number, _frame):
            nonlocal cancelled, cancelled_at
            cancelled = True
            if cancelled_at is None:
                cancelled_at = time.monotonic()
            # EOF only revokes. It cannot approve anything, and does not kill
            # the native process while an approved transaction is draining.
            revoke_liveness()
            if child.poll() is None and bound_session is None:
                try:
                    same_process(kernel, native_identity)
                    os.kill(child.pid, signal.SIGTERM)
                except (OSError, ValueError):
                    pass
        previous = {number: signal.signal(number, cancel) for number in (signal.SIGINT, signal.SIGTERM)}
        pending = bytearray()
        sequence = 0
        try:
            while child.poll() is None or pending:
                if final is not None:
                    # All effects/disposal finished before RESULT. Native teardown
                    # cannot close any user's original workspace or session.
                    try:
                        child.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        same_process(kernel, native_identity)
                        os.kill(child.pid, signal.SIGTERM)
                    break
                if time.monotonic() - started >= 300 and not cancelled:
                    cancel(signal.SIGTERM, None)
                if cancelled_at is not None and time.monotonic() - cancelled_at >= 65:
                    failures.append('BOOTSTRAP_DRAIN_UNCONFIRMED')
                    break
                if not select.select([parent_socket], [], [], 0.2)[0]:
                    continue
                block = parent_socket.recv(4096)
                if not block:
                    break
                pending.extend(block)
                require(len(pending) <= LIMIT, 'BOOTSTRAP_MESSAGE_SIZE')
                while b'\n' in pending:
                    line, _, rest = pending.partition(b'\n')
                    pending = bytearray(rest)
                    message = decode(line)
                    require(type(message) is dict and type(message.get('seq')) is int
                            and message.get('seq') == sequence + 1
                            and message.get('type') in ('BIND', 'CHECK', 'RESULT'), 'BOOTSTRAP_PROTOCOL')
                    sequence += 1
                    session_id = message.get('session_id')
                    require(type(session_id) is str and str(uuid.UUID(session_id)) == session_id, 'BOOTSTRAP_NATIVE_SESSION')
                    try:
                        if message['type'] != 'RESULT':
                            check()
                        if message['type'] == 'BIND':
                            require(bound_session is None and set(message) == {'type', 'seq', 'session_id'}, 'BOOTSTRAP_PROTOCOL')
                            native_header = continuation.inspect_native(control / 'history', control / 'cwd')
                            require(native_header['id'] == session_id, 'BOOTSTRAP_NATIVE_SESSION')
                            bound_session = session_id
                        else:
                            require(bound_session == session_id, 'BOOTSTRAP_NATIVE_SESSION')
                            if message['type'] == 'CHECK':
                                require(set(message) == {'type', 'seq', 'session_id'}, 'BOOTSTRAP_PROTOCOL')
                            else:
                                require(final is None and set(message) == {'type', 'seq', 'session_id', 'decision', 'phase',
                                    'cleanup_verified', 'error_code', 'result'}, 'BOOTSTRAP_PROTOCOL')
                                require(message['decision'] in ('once', 'deny', 'cancelled', None)
                                        and message['phase'] in ('prepare', 'approval', 'apply', 'disposed')
                                        and type(message['cleanup_verified']) is bool, 'BOOTSTRAP_RESULT')
                                retained.check()
                                same_process(kernel, native_identity)
                                final = message
                                # Engine work is drained before RESULT. Release the
                                # reader before waiting for native stream shutdown.
                                revoke_liveness()
                        parent_socket.sendall(canonical({'seq': sequence, 'ok': True}) + b'\n')
                    except (BootstrapError, OSError, ValueError) as error:
                        failures.append(safe_code(error))
                        parent_socket.sendall(canonical({'seq': sequence, 'ok': False, 'error_code': safe_code(error)}) + b'\n')
                        cancel(signal.SIGTERM, None)
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)
        if child.poll() is None:
            if final is None:
                revoke_liveness()
                if bound_session is None:
                    same_process(kernel, native_identity)
                    child.send_signal(signal.SIGTERM)
            try:
                child.wait(timeout=65 if final is None else 3)
            except subprocess.TimeoutExpired:
                same_process(kernel, native_identity)
                child.kill()
                child.wait(timeout=3)
        result = final['result'] if final else None
        if result is not None:
            require(type(result) is dict and set(result) == {'status', 'profile', 'root', 'before', 'target',
                    'after', 'changed', 'verified', 'detail'} and result['profile'] == request['profile']
                    and result['root'] == str(root) and result['before'] == request['expected_base']
                    and result['target'] == request['revision'] and final['decision'] == 'once'
                    and result['status'] in ('updated', 'already_current', 'not_applied', 'uncertain')
                    and type(result['verified']) is bool and (type(result['changed']) is bool or result['changed'] is None)
                    and (result['after'] is None or type(result['after']) is str and HEX40.fullmatch(result['after']))
                    and type(result['detail']) is str, 'BOOTSTRAP_RESULT')
            require(result['status'] not in ('updated', 'already_current') or
                    result['verified'] and result['after'] == request['revision'], 'BOOTSTRAP_RESULT')
            result = {key: value for key, value in result.items() if key != 'detail'}
        receipt = {'schema': 'launcher-canonical-bootstrap-receipt/v1', 'operation_id': operation,
                   'request': request, 'runtime': runtime, 'source': record['source'], 'native_session': bound_session,
                   'decision': final['decision'] if final else None, 'result': result,
                   'status': (result['status'] if final['cleanup_verified'] else 'uncertain') if result else
                             'not_applied' if final and final['decision'] != 'once' and final['cleanup_verified'] else 'unknown',
                   'cleanup_verified': bool(final and final['cleanup_verified']),
                   'error_code': safe_code(final['error_code']) if final and final['error_code'] else failures[-1] if failures else None,
                   'elapsed_seconds': round(time.monotonic() - started, 3)}
        write_record(control / 'receipt.json', receipt, 0o600)
        print(json.dumps(receipt, ensure_ascii=False))
        return 0 if receipt['status'] in ('updated', 'already_current') and receipt['cleanup_verified'] else 1
    except (BootstrapError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        if child is None:
            raise
        receipt_path = control / 'receipt.json'
        if not receipt_path.exists():
            emergency = {'schema': 'launcher-canonical-bootstrap-receipt/v1', 'operation_id': operation,
                         'request': request, 'runtime': runtime,
                         'source': {'revision': pin['revision'], 'manifest_sha256': pin['manifest_sha256'], 'path': str(source)},
                         'native_session': bound_session, 'decision': None, 'result': None,
                         'status': 'unknown', 'cleanup_verified': False, 'error_code': safe_code(error),
                         'elapsed_seconds': round(time.monotonic() - started, 3)}
            try:
                write_record(receipt_path, emergency, 0o600)
            except OSError:
                pass  # The error remains unknown; never manufacture a success receipt.
        raise BootstrapEffectUnknown(safe_code(error), receipt_path) from None
    finally:
        # Ownership lasts until the actual child/drain settles; only then release.
        if child is not None and child.poll() is None:
            try:
                if native_identity is not None:
                    same_process(kernel, native_identity)
                if bound_session and final is None:
                    revoke_liveness()
                else:
                    child.send_signal(signal.SIGTERM)
                try:
                    child.wait(timeout=65 if bound_session and final is None else 5)
                except subprocess.TimeoutExpired:
                    if native_identity is not None:
                        same_process(kernel, native_identity)
                    child.kill()
                    child.wait(timeout=5)
            except (OSError, ValueError, subprocess.SubprocessError):
                # Never signal a replaced image or turn an unknown primary
                # outcome into an apparent pre-launch refusal.
                failures.append('BOOTSTRAP_NATIVE_DRAIN_UNCONFIRMED')
        parent_socket.close()
        child_socket.close()
        revoke_liveness()
        if alive_read is not None:
            os.close(alive_read)
        retained.close()
        os.close(lease)


def main(argv):
    if argv == ['--help']:
        print('Usage: harness-canonical-update --profile <registered-profile> --expected-base <full40> --revision <full40>\n'
              'Launch the admitted upstream main TUI for genuine human once approval.\n'
              'No caller paths, credentials, native arguments or automated approval are accepted.')
        return 0
    home = account_home()
    if os.environ.get('HARNESS_CANONICAL_BOOTSTRAP_SANITIZED') != '1':
        os.execve(SYSTEM_PYTHON, [SYSTEM_PYTHON, '-I', '-S', '-B', str(Path(__file__).absolute()), *argv], environment(home))
    # Ambient HOME is never a selector or native-auth authority, even with a
    # forged sanitation marker. Every child receives a newly constructed env.
    os.environ['HOME'] = str(home)
    if argv == ['_observe']:
        observe(home, observer_directory(home))
        return 0
    directory, projection = dispatch(home, argv)
    return run(home, directory, projection, request_from_args(argv))


if __name__ == '__main__':
    os.umask(0o077)
    try:
        sys.exit(main(sys.argv[1:]))
    except (BootstrapError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        report = {'status': 'unknown' if isinstance(error, BootstrapEffectUnknown) else 'stopped',
                  'error_code': safe_code(error)}
        if isinstance(error, BootstrapEffectUnknown):
            report['receipt_path'] = error.receipt_path
        print(json.dumps(report), file=sys.stderr)
        sys.exit(2)
