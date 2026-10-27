"""Native history admission uses real files; no native CLI or credential access."""
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('native_continuation', Path(__file__).resolve().parents[1]/'bin/harness_omp_continuation.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)
NATIVE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
OWNER = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'


class NativeResumeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.state = self.root/'state'
        self.source = self.root/'source'
        self.namespace = self.root/'namespace'
        self.owner = self.state/'sessions'/OWNER
        self.work = self.state/'worktrees'/OWNER
        for path in (self.source, self.namespace, self.namespace/'history', self.state,
                     self.state/'sessions', self.owner, self.state/'worktrees', self.work):
            path.mkdir(mode=0o700)
        for name, value in {'source-root': str(self.source), 'session-root': str(self.work), 'journal': 'state=ACTIVE'}.items():
            path = self.owner/name
            path.write_text(value+'\n'); path.chmod(0o600)
        self.path = self.namespace/'history'/('2026-10-27_'+NATIVE+'.jsonl')
        self.header = dict(type='session', version=3, id=NATIVE, cwd=str(self.work), timestamp='2026-10-27T00:00:00Z')
        self.persist()
        self.context = patch.object(m, 'current_context', return_value={'namespace_path': str(self.namespace)})
        self.context.start(); self.addCleanup(self.context.stop)
        self.binding = patch.object(m, 'binding', return_value={})
        self.binding.start(); self.addCleanup(self.binding.stop)

    def persist(self):
        self.path.write_text('title\n'+json.dumps(self.header)+'\n')
        self.path.chmod(0o600)

    def resolve(self, fork=False):
        return m.native_resolve(self.state, self.source, NATIVE, __file__, fork)

    def test_public_grammar(self):
        self.assertEqual(m.native_request(['omp', '--resume', NATIVE, '--fork-session', '--model-mode', 'gpt-only']),
                         {'id': NATIVE, 'fork': True, 'model_mode': 'gpt-only'})
        self.assertIsNone(m.native_request(['omp', '--session-new']))
        for args in (['omp', '-p', '--resume', NATIVE], ['omp', '--resume', NATIVE, '--resume', NATIVE],
                     ['omp', '--resume', NATIVE, '--fork-session', '--fork-session'], ['omp', '--resume', '/tmp/a']):
            with self.subTest(args=args), self.assertRaises(m.ContinuationError): m.native_request(args)

    def test_live_owner_identity(self):
        selected = self.resolve()
        self.assertEqual(selected['launcher_session_id'], OWNER)
        self.assertEqual(selected['native_path'], str(self.path))
        self.assertEqual(selected['file_identity']['ino'], self.path.stat().st_ino)

    def test_retired_requires_explicit_fork(self):
        (self.owner/'journal').write_text('state=DELIVERED\n')
        with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_owner_retired'): self.resolve()
        self.assertTrue(self.resolve(True)['retired'])

    def test_closed_owner_remains_live_and_all_model_modes_parse(self):
        (self.owner/'journal').write_text('state=CLOSED\n')
        self.assertFalse(self.resolve()['retired'])
        for mode in ('gpt-only', 'opus-only', 'hybrid-gpt-lead', 'hybrid-opus-lead'):
            with self.subTest(mode=mode):
                self.assertEqual(m.native_request(['omp', '--resume', NATIVE, '--model-mode', mode])['model_mode'], mode)

    def test_discarded_and_missing_worktree_require_fork(self):
        for status in ('DISCARDED', 'ACTIVE'):
            with self.subTest(status=status):
                (self.owner/'journal').write_text('state='+status+'\n')
                if status == 'ACTIVE': self.work.rmdir()
                with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_owner_retired'): self.resolve()
                self.assertTrue(self.resolve(True)['retired'])

    def test_owner_worktree_symlink_and_subdirectory_refused(self):
        self.header['cwd'] = str(self.work/'child'); self.persist()
        with self.assertRaises(m.ContinuationError): self.resolve()
        self.header['cwd'] = str(self.work); self.persist()
        self.work.rmdir(); self.work.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(m.ContinuationError): self.resolve()
        with self.assertRaises(m.ContinuationError): self.resolve(True)

    def test_fork_rejects_additional_directories(self):
        self.header['additionalDirectories'] = ['/tmp/extra']; self.persist()
        with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_additional_directories'): self.resolve(True)

    def test_duplicate_symlink_and_hardlink_rejected(self):
        duplicate = self.path.with_name('other_'+NATIVE+'.jsonl')
        duplicate.write_bytes(self.path.read_bytes())
        with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_missing_or_ambiguous'): self.resolve()
        duplicate.unlink()
        self.path.rename(duplicate); self.path.symlink_to(duplicate)
        with self.assertRaises(m.ContinuationError): self.resolve()
        self.path.unlink(); duplicate.rename(self.path)
        os.link(self.path, self.root/'hardlink')
        with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_history_invalid'): self.resolve()

    def test_header_and_owner_root_mismatch(self):
        self.header['cwd'] = str(self.source); self.persist()
        with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_cwd_mismatch'): self.resolve()
        self.header['cwd'] = str(self.work); self.persist()
        (self.owner/'session-root').write_text(str(self.source)+'\n')
        with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_owner_mismatch'): self.resolve()

    def test_final_admission_rejects_replaced_inode(self):
        _, fingerprint = m.native_admit(self.state, self.source, OWNER, NATIVE)
        replacement = self.path.with_suffix('.replacement')
        replacement.write_bytes(self.path.read_bytes()); replacement.chmod(0o600)
        replacement.replace(self.path)
        with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_identity_changed'):
            m.native_admit(self.state, self.source, OWNER, NATIVE, expected=fingerprint)

    def test_fork_admission_records_lineage_once(self):
        target = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        (self.state/'sessions'/target).mkdir(mode=0o700)
        _, fingerprint = m.native_admit(self.state, self.source, target, NATIVE, fork=True)
        m.native_admit(self.state, self.source, target, NATIVE, fork=True, expected=fingerprint)
        lineage = json.loads((self.state/'sessions'/target/'omp-native-lineage.json').read_text())
        self.assertEqual((lineage['source_owner'], lineage['owner'], lineage['native_id']), (OWNER, target, NATIVE))
        self.assertEqual(self.path.read_text(), 'title\n'+json.dumps(self.header)+'\n')

    def test_native_rebind_checks_free_locks_and_publishes_current_pin(self):
        runtimes = self.root/'launcher-runtimes'
        revision = 'a'*40
        consumer = runtimes/revision/'bin'/'harness_omp_continuation.py'
        consumer.parent.mkdir(parents=True, mode=0o700)
        consumer.write_text('')
        for directory in ('bindings', 'binding-locks'):
            (runtimes/directory).mkdir(mode=0o700)
        pin = dict(version='0.78.3', revision=revision, path=str(consumer.parent.parent), manifest_sha256='b'*64)
        (runtimes/'current.json').write_text(json.dumps(pin))
        bound = runtimes/'bindings'/(OWNER+'.json')
        old = json.dumps(dict(source_root=str(self.source), runtime=dict(pin, revision='c'*40)))
        bound.write_text(old)
        (self.owner/'runtime.lock').write_text('')
        (self.namespace/'.launcher.lock').write_text('')
        locks = self.namespace/'launcher-native-locks'; locks.mkdir(mode=0o700)
        lock = locks/(NATIVE+'.lock'); lock.write_text(''); lock.chmod(0o600)
        self.context.stop()
        self.context = patch.object(m, 'current_context', return_value=dict(namespace_path=str(self.namespace), snapshot_revision=revision))
        self.context.start(); self.addCleanup(self.context.stop)
        script = 'import fcntl,sys; f=open(sys.argv[1],"r+"); fcntl.lockf(f,fcntl.LOCK_EX); print("ready",flush=True); sys.stdin.readline()'
        with patch.object(m, '__file__', str(consumer)):
            child = subprocess.Popen([sys.executable, '-c', script, str(lock)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(child.stdout.readline().strip(), 'ready')
                with self.assertRaises(m.ContinuationError):
                    m.native_rebind_runtime(self.state, self.source, OWNER, NATIVE)
                self.assertEqual(bound.read_text(), old)
            finally:
                child.communicate('\n', timeout=5)
            self.assertEqual(m.native_rebind_runtime(self.state, self.source, OWNER, NATIVE), pin)
        self.assertEqual(json.loads(bound.read_text()), dict(source_root=str(self.source), runtime=pin))

    def test_other_namespace_and_continuation_not_searched(self):
        self.path.unlink()
        continuation = self.namespace/'launcher-continuations'
        continuation.mkdir(); (continuation/self.path.name).write_text('ignored')
        with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_missing_or_ambiguous'): self.resolve()


if __name__ == '__main__':
    unittest.main()
