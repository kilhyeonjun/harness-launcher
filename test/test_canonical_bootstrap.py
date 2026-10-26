#!/usr/bin/env python3
"""Controller boundaries, using disposable synthetic authority only.

Run: python3 -B -m unittest discover -s test -p test_canonical_bootstrap.py -v
No installed selector, private source, real enrollment, or canonical repository
is used. Darwin tests exercise real POSIX locks across independent processes.
"""
import contextlib
import copy
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import pwd
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('bootstrap_under_test', ROOT / 'bin/harness_canonical_bootstrap.py')
b = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(b)

# Darwin struct flock: off_t start/len, pid_t pid, short type/whence.
# This is an OS query primitive, not an alternate admission policy.
LOCK_QUERY = r'''
import fcntl, os, struct, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW)
try:
    value = fcntl.fcntl(fd, fcntl.F_GETLK, struct.pack('qqihh', 0, 0, 0, fcntl.F_WRLCK, os.SEEK_SET))
    start, length, pid, kind, whence = struct.unpack('qqihh', value)
    print(pid if kind != fcntl.F_UNLCK else 0, flush=True)
finally:
    os.close(fd)
'''
LOCK_HOLDER = r'''
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOFOLLOW)
fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
print(os.getpid(), flush=True)
for line in sys.stdin:
    if line.strip() == 'unlock':
        fcntl.lockf(fd, fcntl.LOCK_UN)
        print('unlocked', flush=True)
    elif line.strip() == 'query':
        # A holder sees no conflicting lock: never use this as ownership proof.
        import struct
        out = fcntl.fcntl(fd, fcntl.F_GETLK, struct.pack('qqihh', 0, 0, 0, fcntl.F_WRLCK, os.SEEK_SET))
        print(struct.unpack('qqihh', out)[3] == fcntl.F_UNLCK, flush=True)
'''


class Disposable(unittest.TestCase):
    def setUp(self):
        # /tmp is intentionally not an authority root: ancestry() rejects it.
        self.temp = tempfile.TemporaryDirectory(prefix='.bootstrap-test-', dir=pwd.getpwuid(os.getuid()).pw_dir)
        self.home = Path(self.temp.name)
        self.home.chmod(0o700)

    def tearDown(self):
        # Sealed fixture directories must be writable before recursive removal.
        for parent, dirs, files in os.walk(self.home):
            Path(parent).chmod(0o700)
        self.temp.cleanup()

    def put(self, path, raw=b'fixture\n', mode=0o600):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_bytes(raw)
        path.chmod(mode)
        return path

    def source(self):
        data = {name: ('synthetic authority: ' + name + '\n').encode() for name in b.FILES}
        rows = [{'path': name, 'git_mode': '100644', 'bytes': len(data[name]), 'sha256': b.digest(data[name])}
                for name in b.FILES]
        manifest = b.canonical({'schema': b.SOURCE_SCHEMA, 'files': rows}) + b'\n'
        pin = {'schema': b.PIN_SCHEMA, 'revision': 'a' * 40, 'manifest_sha256': b.digest(manifest), 'files': rows,
               'native': {'version': '18.11.3', 'source_revision': '96894a6147d8cc64b7e00ad3a7d7178fd93b9531',
                          'sha256': 'd518310d647d467a2c5c3f2d38e34489a761996d766395c03b37c61a2203d02b',
                          'bytes': 194982944}}
        directory = self.home / 'released/bin'
        self.put(directory / 'canonical-bootstrap-source.json', b.canonical(pin), 0o400)
        source = self.home / b.STATE / 'canonical-bootstrap' / pin['revision'] / pin['manifest_sha256']
        self.put(source / 'manifest.json', manifest, 0o400)
        for name, raw in data.items():
            self.put(source / name, raw, 0o400)
        for parent, _, _ in os.walk(source):
            Path(parent).chmod(0o500)
        return directory, source, pin

    def rejected(self, code):
        return self.assertRaisesRegex(b.BootstrapError, '^' + code + '$')


class SourceAdmission(Disposable):
    def test_exact_sealed_cache_and_public_pin(self):
        directory, source, pin = self.source()
        self.assertEqual(b.admit_source(self.home, directory), (pin, source))

    def test_closed_pin_inventory_and_release(self):
        _, _, pin = self.source()
        mutations = [lambda p: p.update(extra=True), lambda p: p.update(revision='A' * 40),
                     lambda p: p['files'].reverse(), lambda p: p['files'].pop(),
                     lambda p: p['files'][0].update(path='../escape'),
                     lambda p: p['files'][0].update(git_mode='100755'),
                     lambda p: p['files'][0].update(bytes=True),
                     lambda p: p['files'][0].update(bytes=1048577),
                     lambda p: p['files'][0].update(sha256='0' * 63),
                     lambda p: p['files'][0].update(extra=True),
                     lambda p: p['native'].update(sha256='0' * 64)]
        for mutate in mutations:
            candidate = copy.deepcopy(pin)
            mutate(candidate)
            with self.subTest(candidate=candidate), self.assertRaises(b.BootstrapError):
                b.validate_pin(candidate)

    def test_cache_content_manifest_inventory_modes_and_links(self):
        mutations = ('content', 'manifest', 'extra-file', 'extra-directory', 'file-mode',
                     'directory-mode', 'hardlink', 'symlink')
        for kind in mutations:
            with self.subTest(kind=kind):
                case = self.home / kind
                case.mkdir(mode=0o700)
                with mock.patch.object(self, 'home', case):
                    directory, source, _ = self.source()
                    target = source / b.FILES[0]
                    if kind == 'content':
                        target.chmod(0o600)
                        target.write_bytes(b'changed')
                        target.chmod(0o400)
                    elif kind == 'manifest':
                        target = source / 'manifest.json'
                        target.chmod(0o600)
                        target.write_bytes(target.read_bytes() + b'\n')
                        target.chmod(0o400)
                    elif kind.startswith('extra'):
                        source.chmod(0o700)
                        if kind == 'extra-file':
                            self.put(source / 'unexpected', mode=0o400)
                        else:
                            (source / 'unexpected').mkdir(mode=0o500)
                        source.chmod(0o500)
                    elif kind == 'file-mode':
                        target.chmod(0o600)
                    elif kind == 'directory-mode':
                        target.parent.chmod(0o700)
                    else:
                        target.parent.chmod(0o700)
                        if kind == 'hardlink':
                            os.link(target, case / 'outside-link')
                        else:
                            raw = target.read_bytes()
                            target.unlink()
                            other = self.put(case / 'outside', raw, 0o400)
                            target.symlink_to(other)
                        target.parent.chmod(0o500)
                    with self.assertRaises((b.BootstrapError, OSError)):
                        b.admit_source(case, directory)

    def test_unsafe_ancestry_is_not_accepted(self):
        path = self.put(self.home / 'unsafe/file')
        path.parent.chmod(0o777)
        with self.rejected('BOOTSTRAP_UNSAFE_ANCESTRY'):
            b.read_file(path, 0o600)


class InputAndRecordBoundaries(Disposable):
    def test_exact_request_and_no_authority_overrides(self):
        argv = ['--profile', 'sample-profile', '--expected-base', '1' * 40, '--revision', '2' * 40]
        for profile in ('sample-profile', 'Sample', 'sample_profile', '_profile', 'a' * 33, 'A_' + 'b' * 62):
            changed = argv[:]
            changed[1] = profile
            with self.subTest(profile=profile):
                self.assertEqual(b.request_from_args(changed)['profile'], profile)
        variants = [argv + ['--once'], argv + ['--source', str(self.home)], argv + ['--home', str(self.home)],
                    argv + ['--native-arg', '--print'], argv + ['--approval', 'once'], argv[2:] + argv[:2],
                    ['--profile=sample-profile'] + argv[2:]]
        for profile in ('../sample', '', 'a' * 65, '-profile', '1profile', 'two words', 'prøfile', 'line\nfeed'):
            changed = argv[:]
            changed[1] = profile
            variants.append(changed)
        for revision in ('main', 'a' * 39, 'A' * 40, 'a' * 41):
            changed = argv[:]
            changed[5] = revision
            variants.append(changed)
        for value in variants:
            with self.subTest(argv=value), self.rejected('BOOTSTRAP_ARGUMENTS'):
                b.request_from_args(value)

    @unittest.skipUnless(sys.platform == 'darwin', 'account authority is Darwin-only')
    def test_account_home_ignores_ambient_home_and_xdg(self):
        expected = Path(pwd.getpwuid(os.getuid()).pw_dir)
        with mock.patch.dict(os.environ, {'HOME': str(self.home), 'XDG_STATE_HOME': str(self.home / 'forged')}):
            self.assertEqual(b.account_home(), expected)

    def test_environment_strips_credentials_paths_and_approval(self):
        inherited = {'HOME': '/untrusted', 'PATH': '/untrusted', 'TERM': '\nunsafe', 'API_KEY': 'secret',
                     'HARNESS_SESSION_ID': 'forged', 'HARNESS_CANONICAL_BOOTSTRAP_FD': '7',
                     'HARNESS_CANONICAL_BOOTSTRAP_APPROVAL': 'once', 'PI_CODING_AGENT_DIR': '/untrusted',
                     'XDG_CONFIG_HOME': '/untrusted', 'PYTHONPATH': '/untrusted'}
        actual = b.environment(self.home, inherited)
        self.assertEqual(actual['HOME'], str(self.home))
        self.assertEqual(actual['PATH'], '/usr/bin:/bin:/usr/sbin:/sbin')
        self.assertEqual(actual['TERM'], 'xterm-256color')
        self.assertTrue(set(actual).isdisjoint(set(inherited) - {'HOME', 'PATH', 'TERM'}))

    def test_profile_registry_and_enrolled_binary_are_both_required(self):
        directory, _, pin = self.source()
        workspace = self.home / 'workspace'
        workspace.mkdir(mode=0o700)
        self.put(self.home / '.config/harness-launcher/profiles/sample-profile', str(workspace).encode())
        native = pin['native']
        binary = self.home / '.local/state/kilhyeonjun-harness/omp-bin' / (native['version'] + '-' + native['sha256'][:8]) / 'bin/omp'
        context = {'binary_path': str(binary), 'binary_sha256': native['sha256'], 'binary_size': native['bytes'],
                   'binary_release': {key: native[key] for key in ('version', 'source_revision')}}
        request = {'profile': 'sample-profile'}
        projection = types.SimpleNamespace(select=mock.Mock(return_value=context))
        for key, replacement in (('binary_path', str(self.home / 'other-native')), ('binary_sha256', '0' * 64),
                                 ('binary_size', native['bytes'] - 1), ('binary_release', {'version': 'other'})):
            altered = copy.deepcopy(context)
            altered[key] = replacement
            projection.select.return_value = altered
            with self.subTest(field=key), self.rejected('BOOTSTRAP_NATIVE_BINDING'):
                b.profile_context(self.home, directory, projection, request, pin)
        projection.select.return_value = None
        with self.rejected('BOOTSTRAP_PROFILE_NOT_ENROLLED'):
            b.profile_context(self.home, directory, projection, request, pin)

    def test_json_duplicates_constants_and_size_are_rejected(self):
        for raw in (b'{"a":1,"a":2}', b'{"nested":{"a":1,"a":2}}', b'{"x":NaN}', b'{"x":Infinity}'):
            with self.subTest(raw=raw), self.assertRaises(b.BootstrapError):
                b.decode(raw)
        with self.rejected('BOOTSTRAP_MESSAGE_SIZE'):
            b.decode(b' ' * (b.LIMIT + 1))

    def test_record_roundtrip_full_precision_and_exclusive_creation(self):
        stamp = types.SimpleNamespace(st_dev=2**54 + 1, st_ino=2**63 + 3, st_uid=os.getuid(),
                                      st_mode=stat.S_IFREG | 0o400, st_nlink=1, st_size=27,
                                      st_mtime_ns=1700000000123456789, st_ctime_ns=1700000000987654321)
        encoded = b.identity(stamp)
        self.assertEqual(set(encoded), {'dev', 'ino', 'uid', 'mode', 'nlink', 'size', 'mtime_ns', 'ctime_ns'})
        self.assertTrue(all(type(value) is str and value.isdecimal() for value in encoded.values()))
        self.assertEqual(encoded['ino'], str(2**63 + 3))
        record = {'identity': encoded, 'request': {'profile': 'sample-profile'}, 'purpose': 'test-only'}
        path = self.home / 'record.json'
        digest, actual = b.write_record(path, record)
        raw, observed = b.read_file(path, 0o400)
        self.assertEqual(raw, b.canonical(record))
        self.assertEqual(b.decode(raw), record)
        self.assertEqual(digest, b.digest(raw))
        self.assertEqual(actual, observed)
        with self.assertRaises(FileExistsError):
            b.write_record(path, {'replacement': True})
        with self.rejected('BOOTSTRAP_RECORD_SIZE'):
            b.write_record(self.home / 'oversize', {'x': 'a' * b.LIMIT})
        self.assertFalse((self.home / 'oversize').exists())

    def test_errors_do_not_leak_paths_or_raw_details(self):
        self.assertEqual(b.safe_code(ValueError('BOOTSTRAP_SOURCE_CHANGED: private detail')), 'BOOTSTRAP_SOURCE_CHANGED')
        for detail in ('/sensitive/path', 'failure with credentials', 'x' * 97, ''):
            self.assertEqual(b.safe_code(ValueError(detail)), 'BOOTSTRAP_OPERATION_FAILED')


class RetainedAuthority(Disposable):
    def test_mutations_never_become_new_authority(self):
        for kind in ('replace', 'rewrite', 'chmod', 'hardlink', 'unlink'):
            with self.subTest(kind=kind):
                path = self.put(self.home / kind)
                held = b.Retained()
                try:
                    held.hold(path, True)
                    held.check()
                    if kind == 'replace':
                        replacement = self.put(self.home / (kind + '-new'), path.read_bytes())
                        os.replace(replacement, path)
                    elif kind == 'rewrite':
                        before = path.stat()
                        path.write_bytes(b'changed\n')
                        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
                    elif kind == 'chmod':
                        path.chmod(0o400)
                    elif kind == 'hardlink':
                        os.link(path, self.home / 'another-name')
                    else:
                        path.unlink()
                    with self.assertRaises((b.BootstrapError, OSError)):
                        held.check()
                finally:
                    held.close()
                self.assertEqual(held.nodes, {})

    def test_sealed_directory_inventory_and_active_directory_growth(self):
        sealed = self.home / 'sealed'
        sealed.mkdir(mode=0o700)
        self.put(sealed / 'original')
        held = b.Retained()
        self.addCleanup(held.close)
        held.tree(sealed)
        self.put(sealed / 'new')
        with self.rejected('BOOTSTRAP_AUTHORITY_CHANGED'):
            held.check()
        active = self.home / 'active'
        active.mkdir(mode=0o700)
        growing = b.Retained()
        self.addCleanup(growing.close)
        growing.hold(active)
        self.put(active / 'history')
        growing.check()
        active.rename(self.home / 'old-active')
        active.mkdir(mode=0o700)
        with self.rejected('BOOTSTRAP_AUTHORITY_CHANGED'):
            growing.check()

    def test_process_generation_parent_group_uid_image_and_argv_are_frozen(self):
        expected = {'pid': 123, 'ppid': 100, 'pgid': 123, 'uid': os.getuid(), 'generation': [1000, 3],
                    'argv': ['/native', '--no-tools'], 'executable': '/native'}
        with mock.patch.object(b, 'process_record', return_value=copy.deepcopy(expected)):
            b.same_process(object(), expected)
        replacements = {'pid': 124, 'ppid': 101, 'pgid': 124, 'uid': os.getuid() + 1,
                        'generation': [1000, 4], 'argv': ['/native', '--print'], 'executable': '/other'}
        for key, replacement in replacements.items():
            changed = copy.deepcopy(expected)
            changed[key] = replacement
            with self.subTest(field=key), mock.patch.object(b, 'process_record', return_value=changed), self.rejected('BOOTSTRAP_PROCESS_CHANGED'):
                b.same_process(object(), expected)
        with mock.patch.object(b, 'process_record', side_effect=ProcessLookupError):
            with self.assertRaises(ProcessLookupError):
                b.same_process(object(), expected)


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin F_GETLK ABI')
class DarwinLeaseProof(Disposable):
    def query(self, path):
        return int(subprocess.check_output([sys.executable, '-I', '-S', '-B', '-c', LOCK_QUERY, str(path)], timeout=10))

    def holder(self, path):
        child = subprocess.Popen([sys.executable, '-I', '-S', '-B', '-c', LOCK_HOLDER, str(path)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop, child)
        self.assertEqual(int(child.stdout.readline()), child.pid)
        return child

    @staticmethod
    def stop(child):
        if child.poll() is None:
            child.terminate()
        child.communicate(timeout=10)

    def test_nonholder_sees_actual_owner_but_holder_self_query_does_not(self):
        path = self.put(self.home / 'lease')
        child = self.holder(path)
        self.assertEqual(self.query(path), child.pid)
        child.stdin.write('query\n')
        child.stdin.flush()
        self.assertEqual(child.stdout.readline().strip(), 'True')
        # Closing the non-holder query FD must not release the holder's lock.
        self.assertEqual(self.query(path), child.pid)
        child.stdin.write('unlock\n')
        child.stdin.flush()
        self.assertEqual(child.stdout.readline().strip(), 'unlocked')
        self.assertEqual(self.query(path), 0)

    def test_holder_death_drops_lease_and_same_path_does_not_transfer_lock(self):
        path = self.put(self.home / 'lease')
        child = self.holder(path)
        self.assertEqual(self.query(path), child.pid)
        original = self.home / 'original-lease'
        path.rename(original)
        self.put(path)
        self.assertEqual(self.query(path), 0)
        self.assertEqual(self.query(original), child.pid)
        child.kill()
        child.wait(timeout=10)
        self.assertEqual(self.query(original), 0)


OBSERVER_FIXTURE = r'''
# Synthetic process-identity authority; all filesystem and F_GETLK admission is real.
import importlib.util, json, os, struct, fcntl, sys, types
from pathlib import Path
spec = importlib.util.spec_from_file_location('observer_controller', sys.argv[1])
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
def lease_owner(fd):
    value = fcntl.fcntl(fd, fcntl.F_GETLK, struct.pack('qqihh', 0, 0, 0, fcntl.F_WRLCK, os.SEEK_SET))
    _, _, pid, kind, _ = struct.unpack('qqihh', value)
    return pid if kind != fcntl.F_UNLCK else 0
b.kernel_module = lambda _: types.SimpleNamespace(lease_owner=lease_owner)
b.same_process = lambda kernel, record: os.kill(record['pid'], 0)
b.process_record = lambda kernel, pid: {'executable': sys.executable}
original_module = b.module
b.module = lambda name, path: original_module(name, Path(sys.argv[1]).with_name('harness_omp_continuation.py'))
try:
    b.observe(Path(sys.argv[2]), Path(sys.argv[3]))
except (b.BootstrapError, OSError, ValueError) as error:
    print(json.dumps({'ok':False, 'error_code': b.safe_code(error)}))
    sys.exit(2)
'''
NATIVE_OBSERVER_BRIDGE = r'''
import json, os, subprocess, sys
from pathlib import Path
value = json.loads(sys.stdin.readline())
control = Path(value['frame']['record']['control']['path'])
header = {'type':'session','version':3,'id':value['session_id'], 'cwd':str(control/'cwd'),
          'timestamp':'2026-01-01T00:00:00Z'}
path = control/'history'/('fixture_'+value['session_id']+'.jsonl')
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd, b'fixture title\n' + json.dumps(header).encode() + b'\n')
os.close(fd)
reply = subprocess.run([sys.executable,'-I','-S','-B',*sys.argv[1:]], input=json.dumps(value).encode(),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
sys.stdout.buffer.write(reply.stdout)
sys.stderr.buffer.write(reply.stderr)
sys.exit(reply.returncode)
'''


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin F_GETLK ABI')
class NonholderObserverAdmission(Disposable):
    def observe_case(self, mutation=None):
        import time
        import uuid
        directory, source, pin = self.source()
        runtime = {'version': '0.0.0', 'revision': '3' * 40, 'path': str(directory.parent), 'manifest_sha256': '4' * 64}
        self.put(self.home / b.STATE / 'current.json', b.canonical(runtime))
        operation, nonce = uuid.uuid4().hex, uuid.uuid4().hex
        control = self.home / b.STATE / 'canonical-bootstrap/operations' / operation
        for name in ('history', 'cwd'):
            (control / name).mkdir(parents=True, mode=0o700)
        control.chmod(0o700)
        lease_path = self.put(control / 'lease')
        lease = os.open(lease_path, os.O_RDWR | os.O_NOFOLLOW)
        # This is the actual holder. Do not reopen/close its lease inode here.
        fcntl.lockf(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        observer = self.put(self.home / 'synthetic_observer.py', OBSERVER_FIXTURE.encode())
        native = subprocess.Popen([sys.executable, '-I', '-S', '-B', '-c', NATIVE_OBSERVER_BRIDGE,
                                   str(observer), str(ROOT / 'bin/harness_canonical_bootstrap.py'),
                                   str(self.home), str(directory)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            record = {'schema': b.SCHEMA, 'purpose': 'canonical-update', 'operation_id': operation, 'nonce': nonce,
                      'account_home': str(self.home), 'expires_at': int(time.time()*1000) + 300000,
                      'runtime': runtime, 'source': {'revision': pin['revision'], 'manifest_sha256': pin['manifest_sha256'], 'path': str(source)},
                      'parent': {'pid': os.getpid(), 'executable': sys.executable,
                                 'argv': [b.SYSTEM_PYTHON, '-I', '-S', '-B', str(directory / 'harness_canonical_bootstrap.py')]},
                      'native': {'pid': native.pid, 'ppid': os.getpid(), 'executable': sys.executable, 'argv': [sys.executable]},
                      'control': {'path': str(control), 'identity': b.identity(control.stat())},
                      'lease': {'path': str(lease_path), 'identity': b.identity(os.fstat(lease))}}
            if mutation == 'expiry': record['expires_at'] = 0
            if mutation == 'caller': record['native']['pid'] = os.getpid()
            digest, stamp = b.write_record(control / 'record.json', record)
            frame = {'schema': b.SCHEMA, 'operation_id': operation, 'nonce': nonce,
                     'record': record, 'record_sha256': digest, 'record_identity': stamp}
            if mutation == 'unlock': fcntl.lockf(lease, fcntl.LOCK_UN)
            if mutation == 'replace':
                lease_path.rename(control / 'old-lease')
                self.put(lease_path)
            if mutation == 'record':
                path = control / 'record.json'
                path.chmod(0o600)
                path.write_bytes(b.canonical(record) + b' ')
                path.chmod(0o400)
            value = {'frame': frame, 'session_id': str(uuid.uuid4())}
            stdout, stderr = native.communicate(b.canonical(value) + b'\n', timeout=20)
            self.assertTrue(stdout, stderr.decode(errors='replace'))
            return native.returncode, json.loads(stdout)
        finally:
            if native.poll() is None:
                native.kill()
                native.communicate(timeout=10)
            os.close(lease)

    def test_actual_observer_accepts_only_nonholder_proof_of_live_parent_lock(self):
        status, reply = self.observe_case()
        self.assertEqual(status, 0)
        self.assertEqual(reply, {'ok': True})

    def test_observer_rejects_unlock_replacement_expiry_record_and_caller_change(self):
        expected = {'unlock': 'BOOTSTRAP_LEASE_OWNER', 'replace': 'BOOTSTRAP_LEASE_CHANGED',
                    'expiry': 'BOOTSTRAP_EXPIRED', 'record': 'BOOTSTRAP_RECORD_CHANGED',
                    'caller': 'BOOTSTRAP_OBSERVER_CALLER'}
        for mutation, code in expected.items():
            with self.subTest(mutation=mutation):
                case = self.home / mutation
                case.mkdir(mode=0o700)
                with mock.patch.object(self, 'home', case):
                    status, reply = self.observe_case(mutation)
                self.assertEqual(status, 2)
                self.assertEqual(reply, {'ok': False, 'error_code': code})


# This child is deliberately synthetic authority, never a genuine approval UI.
# It drives the real controller's framing, sequencing, receipt, and retention.
NATIVE_FIXTURE = r'''
import json, os, socket, sys, uuid
channel = socket.socket(fileno=int(os.environ['HARNESS_CANONICAL_BOOTSTRAP_FD']))
stream = channel.makefile('rb')
frame = json.loads(stream.readline())
mode = sys.argv[1]
control = frame['record']['control']['path']
session = str(uuid.uuid4())
header = {'type':'session','version':3,'id':session,'cwd':control+'/cwd','timestamp':'2026-01-01T00:00:00Z'}
path = control + '/history/fixture_' + session + '.jsonl'
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd, b'fixture title\n' + json.dumps(header).encode() + b'\n')
os.close(fd)
def send(value, fragmented=False):
    raw = json.dumps(value).encode() + b'\n'
    if fragmented:
        for offset in range(0, len(raw), 7): channel.sendall(raw[offset:offset+7])
    else: channel.sendall(raw)
    return json.loads(stream.readline())
if mode == 'eof': sys.exit(0)
if mode == 'unknown-method':
    send({'type':'APPROVE','seq':1,'session_id':session,'decision':'once'})
    sys.exit(0)
seq = True if mode == 'boolean-seq' else 1.0 if mode == 'float-seq' else 2 if mode == 'replay' else 1
reply = send({'type':'BIND','seq':seq,'session_id':session}, True)
if not reply['ok']: sys.exit(0)
if mode == 'tamper':
    path = frame['record']['source']['path'] + '/authority'
    with open(path, 'wb') as file: file.write(b'tampered')
if mode == 'changed-session': session = str(uuid.uuid4())
reply = send({'type':'CHECK','seq':2,'session_id':session})
if not reply['ok']: sys.exit(0)
if mode == 'after-check-eof': sys.exit(0)
message = {'type':'RESULT','seq':3,'session_id':session,'decision':'deny','phase':'disposed',
           'cleanup_verified':True,'error_code':None,'result':None}
if mode == 'forged-result':
    message['result'] = {'profile':frame['record']['request']['profile'],'root':'/forged',
                         'before':frame['record']['request']['expected_base'],
                         'target':frame['record']['request']['revision'],'status':'updated'}
if mode == 'unverified-result':
    request = frame['record']['request']
    message.update(decision='once', result={'profile':request['profile'], 'root':frame['record']['registered_root'],
        'before':request['expected_base'], 'target':request['revision'], 'after':request['revision'],
        'status':'updated', 'changed':True, 'verified':False, 'detail':'engine_result_redacted'})
if mode == 'cleanup-unconfirmed': message['cleanup_verified'] = False
send(message)
if mode == 'wait-for-revocation':
    assert os.read(int(os.environ['HARNESS_CANONICAL_BOOTSTRAP_ALIVE_FD']), 1) == b''
    with open(control + '/reader-drained', 'wb') as marker: marker.write(b'eof')
'''


class ControllerProtocol(Disposable):
    def invoke(self, mode):
        directory = self.home / 'released/bin'
        self.put(directory / 'code')
        source = self.home / 'closure'
        self.put(source / 'authority')
        root = self.home / 'workspace'
        root.mkdir(mode=0o700)
        namespace = self.home / 'namespace'
        self.put(namespace / '.owner.json')
        binary = self.put(self.home / 'native', mode=0o500)
        request = {'profile': 'sample-profile', 'expected_base': '1' * 40, 'revision': '2' * 40}
        runtime = {'version': '0.0.0', 'revision': '3' * 40, 'path': str(directory.parent), 'manifest_sha256': '4' * 64}
        self.put(self.home / b.STATE / 'current.json', b.canonical(runtime))
        for name in ('profiles/sample-profile', 'omp-projection-v1/enrollment.json', 'omp-projection-v1/state.json'):
            self.put(self.home / '.config/harness-launcher' / name)
        (self.home / b.STATE / 'canonical-bootstrap').mkdir(mode=0o700)
        native_script = self.put(self.home / 'synthetic_native.py', NATIVE_FIXTURE.encode())
        pin = {'revision': '5' * 40, 'manifest_sha256': '6' * 64}
        context = {'binary_path': str(binary), 'namespace_path': str(namespace),
                   'valid_until': '2000-01-01T00:00:00Z' if mode == 'expired' else '2999-01-01T00:00:00Z'}
        projection = b.module('_bootstrap_test_projection', ROOT / 'bin/harness_omp_projection.py')
        kernel = types.SimpleNamespace(lease_owner=mock.Mock(side_effect=AssertionError('holder must never self-query F_GETLK')))
        real_popen = subprocess.Popen
        launched = {}

        def spawn(argv, **kwargs):
            child = real_popen([sys.executable, '-I', '-S', '-B', str(native_script), mode], **kwargs)
            launched.update(child=child, argv=argv)
            return child

        def process_record(_kernel, pid):
            # Synthetic identity only. Actual Darwin lock proof has separate tests.
            if pid == os.getpid():
                return {'pid': pid, 'ppid': os.getppid(), 'pgid': os.getpgrp(), 'uid': os.getuid(),
                        'generation': [1, 1], 'argv': [sys.executable], 'executable': sys.executable}
            self.assertEqual(pid, launched['child'].pid)
            os.kill(pid, 0)
            return {'pid': pid, 'ppid': os.getpid(), 'pgid': pid, 'uid': os.getuid(),
                    'generation': [2, 1], 'argv': launched['argv'], 'executable': str(binary)}

        continuation = b.module('_bootstrap_test_continuation', ROOT / 'bin/harness_omp_continuation.py')
        output = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(b, 'module', return_value=continuation))
            for target, value in (('admit_source', lambda *_: (pin, source)),
                                  ('profile_context', lambda *_: (root, context)),
                                  ('kernel_module', lambda *_: kernel), ('process_record', process_record)):
                stack.enter_context(mock.patch.object(b, target, value))
            stack.enter_context(mock.patch.object(b.os, 'isatty', return_value=True))
            stack.enter_context(mock.patch.object(b.subprocess, 'Popen', side_effect=spawn))
            stack.enter_context(contextlib.redirect_stdout(output))
            status = b.run(self.home, directory, projection, request)
        kernel.lease_owner.assert_not_called()
        receipt = json.loads(output.getvalue())
        operation = self.home / b.STATE / 'canonical-bootstrap/operations' / receipt['operation_id']
        self.assertEqual(json.loads((operation / 'receipt.json').read_bytes()), receipt)
        self.assertIsNotNone(launched['child'].poll())
        return status, receipt

    def test_deny_is_no_apply_without_fabricated_after_and_child_is_drained(self):
        status, receipt = self.invoke('deny')
        self.assertEqual(status, 1)
        self.assertEqual(receipt['status'], 'not_applied')
        self.assertEqual(receipt['decision'], 'deny')
        self.assertIsNone(receipt['result'])
        self.assertTrue(receipt['cleanup_verified'])

    def test_drained_native_reader_observes_eof_before_parent_waits_for_exit(self):
        _, receipt = self.invoke('wait-for-revocation')
        control = self.home / b.STATE / 'canonical-bootstrap/operations' / receipt['operation_id']
        self.assertEqual((control / 'reader-drained').read_bytes(), b'eof')

    def test_denial_without_confirmed_cleanup_remains_unknown(self):
        status, receipt = self.invoke('cleanup-unconfirmed')
        self.assertEqual(status, 1)
        self.assertEqual(receipt['status'], 'unknown')
        self.assertEqual(receipt['decision'], 'deny')
        self.assertFalse(receipt['cleanup_verified'])

    def test_eof_before_bound_result_truthfully_reports_unknown(self):
        for mode in ('eof', 'after-check-eof'):
            with self.subTest(mode=mode):
                case = self.home / mode
                case.mkdir(mode=0o700)
                with mock.patch.object(self, 'home', case):
                    status, receipt = self.invoke(mode)
                self.assertEqual(status, 1)
                self.assertEqual(receipt['status'], 'unknown')
                self.assertIsNone(receipt['result'])
                self.assertFalse(receipt['cleanup_verified'])

    def test_retained_authority_and_session_change_stop_without_apply(self):
        for mode in ('tamper', 'changed-session'):
            with self.subTest(mode=mode):
                case = self.home / mode
                case.mkdir(mode=0o700)
                with mock.patch.object(self, 'home', case):
                    _, receipt = self.invoke(mode)
                self.assertEqual(receipt['status'], 'unknown')
                self.assertIsNone(receipt['result'])
                self.assertFalse(receipt['cleanup_verified'])
                self.assertIn(receipt['error_code'], ('BOOTSTRAP_AUTHORITY_CHANGED', 'BOOTSTRAP_NATIVE_SESSION'))

    def test_replay_unknown_method_and_forged_result_are_rejected(self):
        for mode in ('replay', 'boolean-seq', 'float-seq', 'unknown-method', 'forged-result', 'unverified-result'):
            with self.subTest(mode=mode):
                case = self.home / mode
                case.mkdir(mode=0o700)
                with mock.patch.object(self, 'home', case):
                    with self.assertRaises(b.BootstrapError):
                        self.invoke(mode)


if __name__ == '__main__':
    unittest.main()
