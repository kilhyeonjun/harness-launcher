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
        # Launcher-written private state is 0600; do not inherit the runner's umask.
        for path in (runtimes/'current.json', bound, self.owner/'runtime.lock', self.namespace/'.launcher.lock'):
            path.chmod(0o600)
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
            shared = script.replace('fcntl.LOCK_EX', 'fcntl.LOCK_SH')
            child = subprocess.Popen([sys.executable, '-c', shared, str(self.namespace/'.launcher.lock')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(child.stdout.readline().strip(), 'ready')
                self.assertEqual(m.native_rebind_runtime(self.state, self.source, OWNER, NATIVE), pin)
            finally:
                child.communicate('\n', timeout=5)
            with patch.object(m, 'native_rebind_runtime') as rebind:
                m.native_rebind_stale(self.state, self.source, OWNER, NATIVE)
                rebind.assert_not_called()
                bound.write_text(old)
                m.native_rebind_stale(self.state, self.source, OWNER, NATIVE)
                rebind.assert_called_once_with(self.state, self.source, OWNER, NATIVE)
            bound.write_text(json.dumps(dict(source_root=str(self.source), runtime=pin)))
        self.assertEqual(json.loads(bound.read_text()), dict(source_root=str(self.source), runtime=pin))

    def test_submitted_and_integrating_refused_before_owner_selection(self):
        for state in ('SUBMITTED', 'INTEGRATING'):
            (self.owner/'journal').write_text('state='+state+'\n')
            for fork in (False, True):
                with self.subTest(state=state, fork=fork), self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_owner_busy'):
                    self.resolve(fork)

    def test_fork_allows_appends_but_rejects_header_and_inode_changes(self):
        target = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        (self.state/'sessions'/target).mkdir(mode=0o700)
        _, fingerprint = m.native_admit(self.state, self.source, target, NATIVE, fork=True)
        with self.path.open('a') as stream:
            stream.write('{"type":"message","text":"concurrent source write"}\n')
        m.native_admit(self.state, self.source, target, NATIVE, fork=True, expected=fingerprint)
        self.header['timestamp'] = '2026-10-28T00:00:00Z'; self.persist()
        with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_identity_changed'):
            m.native_admit(self.state, self.source, target, NATIVE, fork=True, expected=fingerprint)
        self.header['timestamp'] = '2026-10-27T00:00:00Z'; self.persist()
        replacement = self.path.with_suffix('.replacement')
        replacement.write_bytes(self.path.read_bytes()); replacement.chmod(0o600); replacement.replace(self.path)
        with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_identity_changed'):
            m.native_admit(self.state, self.source, target, NATIVE, fork=True, expected=fingerprint)

    def test_shell_native_adopts_environment_and_finalizes_reopened_owners(self):
        shim = self.root/'python-shim'
        # The shim returns the namespace from an explicit environment value;
        # all admission/identity behavior is covered by real helper tests above.
        shim.write_text('#!'+sys.executable+'\nimport os,sys\nif "--native-admit" in sys.argv: print("/history/native.jsonl\\n"+os.environ["TEST_NAMESPACE"]+"\\n"+"a"*64)\n')
        shim.chmod(0o700)
        shell = r'''
source "$1/bin/aliases.zsh"
config_root="$2/source" HARNESS_SESSION_STATE_HOME="$2/state" HARNESS_OMP_ROOT="$2/namespace"
export TEST_NAMESPACE="$HARNESS_OMP_ROOT"
harness_python3_resolve() { print -r -- "$fixture/python-shim"; }
_harness_launcher_omp_check_args() { :; }
_harness_launcher_isolated_lease_acquire() { :; }
_harness_launcher_isolated_session_create() {
  [[ "$failure" != create ]] || return 2
  print -r -- "resume:$1:$2" >> "$fixture/trace"
  print OPEN > "$fixture/owner-state"
  export HARNESS_SESSION_ID="$2" HARNESS_SOURCE_ROOT="$1" HARNESS_SESSION_ROOT="$fixture/state/worktrees/$2"
}
_harness_launcher_omp_validate() { [[ "$failure" != admission ]]; }
_harness_launcher_omp_required_argv() { omp_required_argv=(); }
_harness_launcher_omp_native() {
  [[ "$HARNESS_SESSION_ID" == "$owner" && "$HARNESS_SOURCE_ROOT" == "$fixture/source" ]] || return 90
  [[ "$HARNESS_SESSION_ROOT" == "$fixture/state/worktrees/$owner" && "$HARNESS_RUN_DIR" == "$HARNESS_SESSION_ROOT" ]] || return 91
  [[ -z "$_harness_omp_herdr_resume" ]] || return 92
  print -r -- "native:$HARNESS_SESSION_ID" >> "$fixture/trace"
}
_harness_launcher_isolated_finish() {
  print -r -- "finish:$1" >> "$fixture/trace"
  print CLOSED > "$fixture/owner-state"
}
fixture="$2" owner="$3" failure="$6"
[[ "$failure" != lock ]] || ln -s "$fixture/missing" "$HARNESS_OMP_ROOT/.launcher.lock"
_harness_launcher_omp_native_resume "$owner" "$4" "$5"
'''
        repo = Path(__file__).resolve().parents[1]
        for operation in ('resume', 'fork'):
            for failure in ('none', 'create', 'admission', 'lock'):
                with self.subTest(operation=operation, failure=failure):
                    trace = self.root/'trace'; trace.write_text('')
                    owner_state = self.root/'owner-state'; owner_state.write_text('CLOSED\n')
                    (self.namespace/'.launcher.lock').unlink(missing_ok=True)
                    result = subprocess.run(['/bin/zsh', '-f', '-c', shell, 'test', str(repo), str(self.root), OWNER,
                                             '--session-native-'+operation, NATIVE, failure], text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0 if failure == 'none' else 2, result.stderr)
                    expected = []
                    if failure != 'create':
                        expected.append('resume:'+str(self.source)+':'+OWNER)
                        if failure == 'none': expected.append('native:'+OWNER)
                        expected.append('finish:'+OWNER)
                    self.assertEqual(trace.read_text().splitlines(), expected)
                    self.assertEqual(owner_state.read_text(), 'CLOSED\n')

    def test_other_namespace_and_continuation_not_searched(self):
        self.path.unlink()
        continuation = self.namespace/'launcher-continuations'
        continuation.mkdir(); (continuation/self.path.name).write_text('ignored')
        with self.assertRaisesRegex(m.ContinuationError, 'runtime_resume_missing_or_ambiguous'): self.resolve()


if __name__ == '__main__':
    unittest.main()
