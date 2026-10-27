"""Consumer boundaries exercised with real files, indexes and Git processes."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

BIN = Path(__file__).resolve().parents[1] / 'bin'
spec = importlib.util.spec_from_file_location('launcher_release_bridge', BIN / 'harness_release_client.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def git(root, *args, **kw):
    return subprocess.check_output(['git', '-C', str(root), *args], **kw)


class ReleaseOverlayConsumerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / 'workspace'
        self.root.mkdir()
        git(self.root, 'init', '-q')
        git(self.root, 'config', 'user.name', 'Launcher Test')
        git(self.root, 'config', 'user.email', 'launcher@example.invalid')
        (self.root / 'config').mkdir()
        (self.root / 'config/launcher.env').write_text('HARNESS_PREFIX=sample\n')
        self.literal = 'config/문서 [draft]*?.md'
        (self.root / self.literal).write_text('base selector')
        (self.root / 'config/removed.md').write_text('removed selector')
        (self.root / 'source.txt').write_text('source baseline')
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-qm', 'baseline')
        self.directory = self.base / 'session'
        self.directory.mkdir(mode=0o700)
        self.export = self.directory / 'release'
        (self.export / 'config').mkdir(parents=True)
        (self.export / self.literal).write_text('verified release selector')
        (self.export / 'config/untracked [literal]*.md').write_text('release member')
        (self.export / '.harness/codex').mkdir(parents=True)
        (self.export / '.harness/codex/AGENTS.md').write_text('compiled release output')
        (self.export / 'config/line\nbreak.md').write_text('literal newline release member')
        self.names = [self.literal, 'config/removed.md', 'config/untracked [literal]*.md', 'config/line\nbreak.md']
        bridge.save(self.directory / 'overlay-paths', '\0'.join(self.names) + '\0')
        bridge.save(self.directory / 'release-state.json', json.dumps({
            'mode': 'release', 'export': str(self.export), 'deadline': time.time() + 120,
            'profile': 'sample', 'release_id': 'pinned', 'manifest_sha256': 'a' * 64}))
        subprocess.run(['git', 'init', '-q', '--bare', str(self.directory / 'trusted.git')], check=True)
        subprocess.run(['git', '--git-dir=' + str(self.directory / 'trusted.git'), 'fetch', '-q', str(self.root), 'HEAD'], check=True)
        self.trusted = ['git', '--git-dir=' + str(self.directory / 'trusted.git'), '--work-tree=' + str(self.root)]
        subprocess.run([*self.trusted, 'read-tree', 'FETCH_HEAD'], check=True)

    def test_db_materializes_removals_and_literal_paths_in_both_indexes(self):
        before = (self.root / 'source.txt').stat()
        bridge.materialize(self.directory, self.root)
        self.assertEqual((self.root / self.literal).read_text(), 'verified release selector')
        self.assertFalse((self.root / 'config/removed.md').exists())
        self.assertEqual((self.root / '.harness/codex/AGENTS.md').read_text(), 'compiled release output')
        self.assertEqual((self.root / 'source.txt').stat().st_ino, before.st_ino)
        for command in (['git', '-C', str(self.root)], self.trusted):
            flags = subprocess.check_output([*command, 'ls-files', '-v', '-z'])
            self.assertIn(b'S ' + self.literal.encode() + b'\0', flags)
            self.assertIn(b'S config/removed.md\0', flags)
            self.assertIn(b'S config/line\nbreak.md\0', flags)
            ignored = subprocess.check_output([*command, 'check-ignore', '-z', '--stdin'], input=b'config/untracked [literal]*.md\0')
            self.assertEqual(ignored, b'config/untracked [literal]*.md\0')
        self.assertNotIn(self.literal.encode(), git(self.root, 'diff', '--name-only', '-z'))

    def test_overlay_cannot_follow_workspace_symlink(self):
        outside = self.base / 'outside'
        outside.write_text('untouched')
        (self.root / self.literal).unlink()
        (self.root / self.literal).symlink_to(outside)
        with self.assertRaises(bridge.Refused):
            bridge.materialize(self.directory, self.root)
        self.assertEqual(outside.read_text(), 'untouched')

    def test_expired_budget_installs_nothing(self):
        state = json.loads((self.directory / 'release-state.json').read_text())
        state['deadline'] = time.time() - 1
        (self.directory / 'release-state.json').chmod(0o600)
        (self.directory / 'release-state.json').write_text(json.dumps(state))
        with self.assertRaises(bridge.Refused) as raised:
            bridge.materialize(self.directory, self.root)
        self.assertEqual(raised.exception.code, 43)
        self.assertEqual((self.root / self.literal).read_text(), 'base selector')

    def test_profile_is_committed_literal_not_environment(self):
        (self.root / 'config/launcher.env').write_text('HARNESS_PREFIX=uncommitted\n')
        self.assertEqual(bridge.profile(self.root, 'HEAD'), 'sample')


class LegacySessionConsumerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir='/tmp', prefix='launcher-legacy.')
        self.addCleanup(self.temporary.cleanup)
        # Preserve /tmp spelling: the bridge must accept the OS alias itself.
        self.base = Path(self.temporary.name)
        self.home = self.base / 'home'
        self.home.mkdir()
        self.source = self.base / 'source'
        self.source.mkdir()
        git(self.source, 'init', '-q', '-b', 'main')
        git(self.source, 'config', 'user.name', 'Launcher Test')
        git(self.source, 'config', 'user.email', 'launcher@example.invalid')
        (self.source / 'config').mkdir()
        (self.source / 'config/launcher.env').write_text('HARNESS_PREFIX=sample\n')
        (self.source / 'tracked.txt').write_text('baseline\n')
        git(self.source, 'add', '.')
        git(self.source, 'commit', '-qm', 'baseline')
        self.state = self.base / 'state'
        self.env = dict(os.environ, HOME=str(self.home), HARNESS_SESSION_STATE_HOME=str(self.state))
        self.env.pop('HARNESS_SESSION_ID', None)
        self.env.pop('HARNESS_RELEASE_OPERATION_ROOT', None)

    def client(self, *args, env=None):
        return subprocess.run([str(BIN / 'harness-release-client.sh'), *map(str, args)],
                              env=env or self.env, capture_output=True)

    def broker(self, *args):
        result = subprocess.run([str(getattr(self, 'broker_entry', BIN / 'session-isolation.sh')), *map(str, args)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def create(self):
        fields = dict(line.split('=', 1) for line in self.broker('create', '--local', self.source).stdout.splitlines())
        sid = fields['HARNESS_SESSION_ID']
        return sid, Path(fields['HARNESS_SESSION_ROOT']), self.state / 'sessions' / sid

    def test_no_profile_select_accepts_system_alias_and_rejects_owned_symlink(self):
        for directory in (self.base / 'session', self.base / 'linked-session'):
            if directory.name == 'session':
                directory.mkdir(mode=0o700)
                result = self.client('select', self.source, 'HEAD', directory, time.time() + 120)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((directory / 'release-state.json').read_text())['mode'], 'git')
            else:
                outside = self.base / 'outside'
                outside.mkdir(mode=0o700)
                directory.symlink_to(outside, target_is_directory=True)
                result = self.client('select', self.source, 'HEAD', directory, time.time() + 120)
                self.assertEqual(result.returncode, 11)
                self.assertFalse((outside / 'release-state.json').exists())

    @unittest.skipUnless(Path('/usr/bin/lockf').is_file(), 'broker requires macOS lockf')
    def test_legacy_create_clones_committed_git_without_host_profile(self):
        (self.source / 'tracked.txt').write_text('canonical dirty\n')
        sid, root, record = self.create()
        self.assertEqual((root / 'tracked.txt').read_text(), 'baseline\n')
        self.assertEqual(json.loads((record / 'release-state.json').read_text())['mode'], 'git')
        self.assertIn('state=OPEN\n', (record / 'journal').read_text())
        self.assertEqual(git(root, 'remote'), b'')

    @unittest.skipUnless(Path('/usr/bin/lockf').is_file(), 'broker requires macOS lockf')
    def test_old_session_resume_and_runtime_never_select_or_write(self):
        sid, root, record = self.create()
        (record / 'release-state.json').unlink()
        record.chmod(0o755)
        # A host rollout after creation must not convert this old Git session.
        host = self.home / '.config/harness-launcher/release/sample.json'
        host.parent.mkdir(parents=True)
        host.write_text('{invalid profile')
        self.broker('exit', sid)
        self.broker('resume', self.source, sid)
        env = dict(self.env, HARNESS_SESSION_ID=sid)
        before = {str(p.relative_to(record)): (p.lstat().st_ino, p.read_bytes())
                  for p in record.iterdir() if p.is_file()}
        index = (root / '.git/index').read_bytes()
        for runtime_env in (env, self.env):
            result = self.client('runtime-source', root, env=runtime_env)
            self.assertEqual((result.returncode, result.stdout), (0, b''), result.stderr)
        result = self.client('runtime-home', '', env=env)
        self.assertEqual((result.returncode, result.stdout), (0, b''), result.stderr)
        result = self.client('runtime-run', '', '/usr/bin/git', '-C', root, 'show', 'HEAD:tracked.txt', env=env)
        self.assertEqual((result.returncode, result.stdout), (0, b'baseline\n'), result.stderr)
        after = {str(p.relative_to(record)): (p.lstat().st_ino, p.read_bytes())
                 for p in record.iterdir() if p.is_file()}
        self.assertEqual(after, before)
        self.assertEqual((root / '.git/index').read_bytes(), index)
        self.assertFalse((self.state / 'release-runtime').exists())

    def install_release_fixture(self):
        # Exercise the executable bridge protocol and actual export lifetime,
        # without a live producer installation or authority connection.
        import sys
        entry = self.home / '.local/share/harness-service/bin/harness-service'
        entry.parent.mkdir(parents=True)
        entry.write_text('#!' + sys.executable + '\n' + '''import json, os, pathlib, sys
args = sys.argv[2:]
verb = args.pop(0)
def option(name):
    return args[args.index(name) + 1]
if verb == 'select':
    pathlib.Path(option('--pin-out')).write_text('pinned')
    pathlib.Path(option('--overlay-paths-out')).write_bytes(b'')
elif verb == 'resume':
    assert pathlib.Path(option('--pin')).read_text() == 'pinned'
elif verb == 'export':
    assert option('--release') == 'pinned'
    dest = pathlib.Path(option('--dir'))
    dest.mkdir(mode=0o700)
    (dest / 'verified.txt').write_text('verified export')
    print('pinned ' + 'a' * 64 + ' 1 1')
    sys.exit(0)
else:
    sys.exit(2)
print('release pinned ' + 'a' * 64 + ' DB -')
''')
        entry.chmod(0o700)
        host = self.home / '.config/harness-launcher/release/sample.json'
        host.parent.mkdir(parents=True)
        host.write_text('{}')

    def runtime_export(self, root):
        result = self.client('runtime-source', root)
        self.assertEqual(result.returncode, 0, result.stderr)
        source = Path(result.stdout.decode().strip())
        self.assertEqual((source / 'verified.txt').read_text(), 'verified export')
        return source

    def test_shared_runtime_home_survives_overlapping_operation_cleanup(self):
        self.install_release_fixture()
        first = self.runtime_export(self.source)
        home_result = self.client('runtime-home', first)
        self.assertEqual(home_result.returncode, 0, home_result.stderr)
        home = Path(home_result.stdout.decode().strip())
        home.mkdir()
        native = home / 'history.sqlite'
        native.write_bytes(b'native state')
        inode = native.stat().st_ino
        second = self.runtime_export(self.source)
        self.assertNotEqual(first, second)
        self.assertEqual(self.client('runtime-home', second).stdout, home_result.stdout)
        # B's deadline must not affect A's preparation, nor vice versa.
        context = second.parent.parent / 'runtime-context.json'
        metadata = json.loads(context.read_text())
        metadata['deadline'] = time.time() - 1
        context.chmod(0o600)
        context.write_text(json.dumps(metadata))
        self.assertEqual(self.client('runtime-run', second, '/usr/bin/true').returncode, 43)
        self.assertEqual(self.client('runtime-run', first, '/bin/cat', first / 'verified.txt').stdout, b'verified export')
        self.assertEqual(self.client('runtime-cleanup', first).returncode, 0)
        self.assertFalse(first.parent.parent.exists())
        self.assertTrue(second.exists())
        self.assertEqual(self.client('runtime-cleanup', second).returncode, 0)
        third = self.runtime_export(self.source)
        self.assertEqual(self.client('runtime-home', third).stdout, home_result.stdout)
        self.assertEqual((native.stat().st_ino, native.read_bytes()), (inode, b'native state'))
        self.assertEqual(self.client('runtime-cleanup', third).returncode, 0)
        self.assertFalse(list((self.state / 'release-runtime').rglob('operation-*')))

    def recorded_release(self, deadline):
        self.install_release_fixture()
        sid = '11111111-1111-4111-8111-111111111111'
        root = self.state / 'worktrees' / sid
        root.parent.mkdir(parents=True)
        subprocess.run(['git', 'clone', '-q', str(self.source), str(root)], check=True)
        record = self.state / 'sessions' / sid
        record.mkdir(parents=True, mode=0o700)
        (record / 'session-root').write_text(str(root))
        (record / 'release-pin.json').write_text('pinned')
        bridge.save(record / 'release-state.json', json.dumps({
            'mode': 'release', 'profile': 'sample', 'release_id': 'pinned',
            'manifest_sha256': 'a' * 64, 'deadline': deadline}))
        return root, record

    def test_recorded_worktree_expired_history_gets_new_budget_without_reselection(self):
        root, record = self.recorded_release(time.time() - 300)
        # A completed resume's deadline is historical too, not just create's.
        bridge.save(record / 'runtime-deadline', str(time.time() - 180))
        before = {p.name: (p.stat().st_ino, p.read_bytes()) for p in record.iterdir()}
        index = (root / '.git/index').read_bytes()
        tracked = (root / 'tracked.txt').read_bytes()
        canonical_index = (self.source / '.git/index').read_bytes()
        canonical_tracked = (self.source / 'tracked.txt').read_bytes()
        # An invalid host profile proves that no new selection is attempted.
        (self.home / '.config/harness-launcher/release/sample.json').write_text('{invalid')
        started = time.time()
        source = self.runtime_export(root)
        context = json.loads((source.parent.parent / 'runtime-context.json').read_text())
        self.assertGreaterEqual(context['deadline'], started + 120)
        self.assertLessEqual(context['deadline'], time.time() + 120)
        self.assertEqual(self.client('runtime-run', source, '/bin/cat', source / 'verified.txt').stdout,
                         b'verified export')
        expected_home = bridge.physical_system_path(record) / 'runtime/codex'
        self.assertEqual(self.client('runtime-home', source).stdout.decode().strip(), str(expected_home))
        self.assertEqual(self.client('runtime-cleanup', source).returncode, 0)
        self.env['HARNESS_SESSION_ID'] = '22222222-2222-4222-8222-222222222222'
        source = self.runtime_export(root)
        self.assertEqual(self.client('runtime-home', source).stdout.decode().strip(), str(expected_home))
        self.assertEqual(self.client('runtime-cleanup', source).returncode, 0)
        self.assertEqual({p.name: (p.stat().st_ino, p.read_bytes()) for p in record.iterdir() if p.is_file()}, before)
        self.assertEqual((root / '.git/index').read_bytes(), index)
        self.assertEqual((root / 'tracked.txt').read_bytes(), tracked)
        self.assertEqual((self.source / '.git/index').read_bytes(), canonical_index)
        self.assertEqual((self.source / 'tracked.txt').read_bytes(), canonical_tracked)
        self.assertFalse((root / '.harness').exists())
        self.assertFalse((self.source / '.harness').exists())
        self.assertFalse((self.state / 'release-runtime').exists())
        (record / 'release-state.json').unlink()
        self.env.pop('HARNESS_SESSION_ID')
        result = self.client('runtime-source', root)
        self.assertEqual((result.returncode, result.stdout), (0, b''), result.stderr)
        (record / 'session-root').unlink()
        (record / 'session-root').symlink_to(self.source / 'tracked.txt')
        self.assertEqual(self.client('runtime-source', root).returncode, 11)

    def test_broker_continuation_preserves_budget_and_refuses_expiry(self):
        deadline = time.time() + 90
        root, record = self.recorded_release(deadline)
        env = dict(self.env, HARNESS_RELEASE_OPERATION_ROOT=str(root),
                   HARNESS_SESSION_ID='22222222-2222-4222-8222-222222222222')
        index = (root / '.git/index').read_bytes()
        before = {p.name: p.read_bytes() for p in record.iterdir()}
        result = self.client('runtime-source', root, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        source = Path(result.stdout.decode().strip())
        context = json.loads((source.parent.parent / 'runtime-context.json').read_text())
        self.assertEqual(context['deadline'], deadline)
        self.assertEqual(self.client('runtime-cleanup', source).returncode, 0)
        # A resume marker overrides create's deadline, but must never renew
        # itself just because the preparation stage starts after its expiry.
        expired = time.time() - 1
        bridge.save(record / 'runtime-deadline', str(expired))
        result = self.client('runtime-source', root, env=env)
        self.assertEqual((result.returncode, result.stdout), (43, b''), result.stderr)
        self.assertIn(b'release_deadline', result.stderr)
        self.assertEqual((record / 'runtime-deadline').read_text(), str(expired))
        self.assertFalse(list(record.glob('operation-*')))
        (record / 'runtime-deadline').unlink()
        state_path = record / 'release-state.json'
        state = json.loads(state_path.read_text())
        state['deadline'] = expired
        state_path.chmod(0o600)
        state_path.write_text(json.dumps(state))
        result = self.client('runtime-source', root, env=env)
        self.assertEqual((result.returncode, result.stdout), (43, b''), result.stderr)
        self.assertEqual(json.loads(state_path.read_text())['deadline'], expired)
        self.assertFalse(list(record.glob('operation-*')))
        wrong_root = dict(env, HARNESS_RELEASE_OPERATION_ROOT=str(self.source))
        result = self.client('runtime-source', root, env=wrong_root)
        self.assertEqual((result.returncode, result.stdout), (11, b''), result.stderr)
        self.assertIn(b'release_operation_invalid', result.stderr)
        self.assertFalse(list(record.glob('operation-*')))
        self.assertEqual((root / '.git/index').read_bytes(), index)
        for name in ('session-root', 'release-pin.json'):
            self.assertEqual((record / name).read_bytes(), before[name])
        self.assertFalse((root / '.harness').exists())
        self.assertFalse((self.source / '.harness').exists())

    def prepare_headless(self):
        verifier = self.source / 'core/bin/auto-deliver.sh'
        verifier.parent.mkdir(parents=True)
        verifier.write_text('''#!/bin/bash
set -eu
if [[ "${1:-}" == --help ]]; then echo --verify-candidate; exit 0; fi
[[ "$5" == --verify-candidate && "$6" == "$(git rev-parse HEAD)" && "$7" == "$(git write-tree)" ]]
[[ " $* " == *" --staged-only "* && " $* " == *" --dry-run "* && " $* " == *" --no-push "* ]]
[[ -z "${HARNESS_SESSION_ID:-}" && "${HARNESS_AUTHORITY_NO_REFRESH:-}" == 1 ]]
git diff --cached --exit-code --quiet && exit 91
[[ "$(git show :tracked.txt)" == delivered ]]
[[ "$(git rev-parse refs/remotes/origin/main)" == "$(git rev-parse HEAD)" ]]
''')
        verifier.chmod(0o755)
        git(self.source, 'add', '.')
        git(self.source, 'commit', '-qm', 'trusted verifier')
        remote = self.base / 'remote.git'
        subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(remote)], check=True)
        git(self.source, 'remote', 'add', 'origin', str(remote))
        git(self.source, 'push', '-q', '-u', 'origin', 'main')
        self.env['HARNESS_HEADLESS'] = '1'
        return remote

    def install_broker_chain(self):
        # Reproduce Homebrew's prefix -> keg bin -> shared helper directory.
        prefix = self.base / 'brew'
        keg = prefix / 'Cellar/harness-launcher/0.79.0'
        share = keg / 'share/harness-launcher'
        shutil.copytree(BIN, share)
        (keg / 'bin').mkdir()
        (keg / 'bin/harness-session').symlink_to('../share/harness-launcher/session-isolation.sh')
        (prefix / 'bin').mkdir()
        entry = prefix / 'bin/harness-session'
        entry.symlink_to('../Cellar/harness-launcher/0.79.0/bin/harness-session')
        self.env.update(XDG_CONFIG_HOME=str(self.home / '.config'),
                        XDG_STATE_HOME=str(self.home / '.local/state'),
                        XDG_CACHE_HOME=str(self.home / '.cache'), TMPDIR=str(self.base))
        return entry

    @unittest.skipUnless(Path('/usr/bin/lockf').is_file(), 'broker requires macOS lockf')
    def test_installed_symlink_chain_resumes_direct_session(self):
        entry = self.install_broker_chain()
        sid, root, record = self.create()
        self.broker('exit', sid)
        self.broker_entry = entry
        self.broker('resume', self.source, sid)
        self.assertIn('state=OPEN\n', (record / 'journal').read_text())
        self.assertEqual((root / 'tracked.txt').read_text(), 'baseline\n')
        self.assertEqual((self.source / 'tracked.txt').read_text(), 'baseline\n')

    @unittest.skipUnless(Path('/usr/bin/lockf').is_file(), 'broker requires macOS lockf')
    def test_installed_symlink_chain_submits_direct_session(self):
        remote = self.base / 'origin.git'
        git(self.source, 'init', '--bare', '-q', str(remote))
        git(self.source, 'remote', 'add', 'origin', str(remote))
        git(self.source, 'push', '-q', '-u', 'origin', 'main')
        entry = self.install_broker_chain()
        sid, root, record = self.create()
        self.broker_entry = entry
        (root / 'tracked.txt').write_text('submitted through installed entry\n')
        self.broker('submit', sid)
        journal = dict(line.split('=', 1) for line in (record / 'journal').read_text().splitlines())
        self.assertEqual(journal['state'], 'SUBMITTED')
        self.assertTrue(journal['identity'])
        self.assertEqual((self.source / 'tracked.txt').read_text(), 'baseline\n')

    @unittest.skipUnless(Path('/usr/bin/sandbox-exec').is_file() and Path('/usr/bin/lockf').is_file(),
                         'real headless verifier requires macOS Seatbelt and lockf')
    def test_installed_symlink_chain_closes_with_real_headless_verifier(self):
        remote = self.prepare_headless()
        entry = self.install_broker_chain()
        sid, root, record = self.create()
        self.broker_entry = entry
        (root / 'tracked.txt').write_text('delivered\n')
        self.broker('close', sid)
        self.assertIn('state=DELIVERED\n', (record / 'journal').read_text())
        self.assertEqual(subprocess.check_output(['git', '--git-dir=' + str(remote), 'show', 'main:tracked.txt']),
                         b'delivered\n')

    @unittest.skipUnless(Path('/usr/bin/sandbox-exec').is_file() and Path('/usr/bin/lockf').is_file(),
                         'real headless verifier requires macOS Seatbelt and lockf')
    def test_no_profile_headless_verifier_delivers_real_staged_content(self):
        remote = self.prepare_headless()
        sid, root, record = self.create()
        self.assertFalse((root / 'core/scripts/authority_fence.py').exists())
        (root / 'tracked.txt').write_text('delivered\n')
        self.broker('close', sid)
        self.assertIn('state=DELIVERED\n', (record / 'journal').read_text())
        self.assertEqual(subprocess.check_output(['git', '--git-dir=' + str(remote), 'show', 'main:tracked.txt']),
                         b'delivered\n')

    @unittest.skipUnless(Path('/usr/bin/sandbox-exec').is_file() and Path('/usr/bin/lockf').is_file(),
                         'real headless verifier requires macOS Seatbelt and lockf')
    def test_invalid_host_profile_retains_real_headless_submission(self):
        remote = self.prepare_headless()
        before = subprocess.check_output(['git', '--git-dir=' + str(remote), 'rev-parse', 'main'])
        host = self.home / '.config/harness-launcher/release/sample.json'
        host.parent.mkdir(parents=True)
        for kind in ('malformed', 'symlink', 'dangling'):
            with self.subTest(kind=kind):
                sid, root, record = self.create()
                (root / 'tracked.txt').write_text('delivered\n')
                self.broker('submit', sid)
                identity = dict(line.split('=', 1) for line in (record / 'journal').read_text().splitlines())['identity']
                if kind == 'malformed':
                    host.write_text('{not json')
                else:
                    target = self.base / kind
                    if kind == 'symlink':
                        target.write_text('{}')
                    host.symlink_to(target)
                result = subprocess.run([str(BIN / 'session-isolation.sh'), 'integrate', sid],
                                        env=self.env, capture_output=True)
                self.assertEqual(result.returncode, 17, result.stderr)
                self.assertIn(b'verifier_policy_unavailable', result.stderr)
                journal = dict(line.split('=', 1) for line in (record / 'journal').read_text().splitlines())
                self.assertEqual((journal['state'], journal['identity']), ('SUBMITTED', identity))
                self.assertEqual(subprocess.check_output(['git', '--git-dir=' + str(remote), 'rev-parse', 'main']), before)
                self.assertFalse((record / 'pending-sha').exists())
                host.unlink()

    @unittest.skipUnless(Path('/var').is_symlink(), 'requires the OS /var alias')
    def test_no_profile_select_accepts_var_system_alias(self):
        with tempfile.TemporaryDirectory(dir='/var/tmp', prefix='launcher-legacy.') as temporary:
            directory = Path(temporary) / 'session'
            directory.mkdir(mode=0o700)
            result = self.client('select', self.source, 'HEAD', directory, time.time() + 120)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((directory / 'release-state.json').read_text())['mode'], 'git')

    def test_existing_invalid_and_symlink_host_profiles_never_become_legacy(self):
        host = self.home / '.config/harness-launcher/release/sample.json'
        host.parent.mkdir(parents=True)
        for kind in ('malformed', 'symlink', 'dangling'):
            with self.subTest(kind=kind):
                if os.path.lexists(host):
                    host.unlink()
                if kind == 'malformed':
                    host.write_text('{not json')
                else:
                    target = self.base / kind
                    if kind == 'symlink':
                        target.write_text('{}')
                    host.symlink_to(target)
                directory = self.base / ('session-' + kind)
                directory.mkdir(mode=0o700)
                result = self.client('select', self.source, 'HEAD', directory, time.time() + 120)
                self.assertEqual(result.returncode, 11)
                self.assertFalse((directory / 'release-state.json').exists())
                result = self.client('host-profile', self.source, 'HEAD')
                self.assertEqual(result.returncode, 11)


class InstalledEntryConsumerTests(unittest.TestCase):
    def test_host_profile_without_installed_client_refuses_before_clone(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            source = home / 'source'
            source.mkdir()
            git(source, 'init', '-q')
            git(source, 'config', 'user.name', 'Launcher Test')
            git(source, 'config', 'user.email', 'launcher@example.invalid')
            (source / 'config').mkdir()
            (source / 'config/launcher.env').write_text('HARNESS_PREFIX=sample\n')
            git(source, 'add', '.')
            git(source, 'commit', '-qm', 'baseline')
            profile = home / '.config/harness-launcher/release/sample.json'
            profile.parent.mkdir(parents=True)
            profile.write_text('{}')
            directory = home / 'session'
            directory.mkdir(mode=0o700)
            result = subprocess.run([str(BIN / 'harness-release-client.sh'), 'select', str(source), 'HEAD', str(directory), str(time.time() + 120)],
                                    env=dict(os.environ, HOME=str(home)), capture_output=True)
            self.assertEqual(result.returncode, 11)
            self.assertIn(b'installed_release_client_unavailable', result.stderr)
            self.assertFalse((directory / 'release-state.json').exists())

    def test_non_git_legacy_runtime_has_no_release_source(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([str(BIN / 'harness-release-client.sh'), 'runtime-source', directory], capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'')


if __name__ == '__main__':
    unittest.main()
