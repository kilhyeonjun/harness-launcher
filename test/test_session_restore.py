#!/usr/bin/env python3
"""Synthetic archive rehydration tests; never read a user transcript."""
import sys
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bin'))


class SessionRestoreTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('codex'), 'codex CLI is unavailable')
    def test_native_app_server_resumes_and_reads_synthetic_rollout_without_model_call(self):
        from harness_session_archive import archive
        from harness_session_restore import rehydrate

        sid = '66666666-6666-4666-8666-666666666666'
        old = '77777777-7777-4777-8777-777777777777'; new = '88888888-8888-4888-8888-888888888888'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); state = root / 'state'; source = root / 'source'; source.mkdir(); home = root / 'home'; cwd = root / 'work'; cwd.mkdir()
            old_root = root / 'old'; raw = old_root / '.harness' / 'codex' / 'sessions' / '2026' / ('rollout-2026-10-10T00-00-00-' + sid + '.jsonl')
            raw.parent.mkdir(parents=True); timestamp = '2026-10-10T00:00:00.000Z'
            meta = {'session_id': sid, 'id': sid, 'cwd': str(cwd), 'timestamp': timestamp,
                    'cli_version': '0.160.0', 'source': 'cli', 'model_provider': 'openai',
                    'originator': 'codex-tui', 'thread_source': 'user'}
            events = [
                {'timestamp': timestamp, 'ordinal': 0, 'type': 'session_meta', 'payload': meta},
                {'timestamp': timestamp, 'ordinal': 1, 'type': 'response_item', 'payload': {
                    'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'Synthetic fixture only'}]}},
                {'timestamp': timestamp, 'ordinal': 2, 'type': 'response_item', 'payload': {
                    'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Synthetic response only'}]}},
            ]
            raw.write_text(''.join(json.dumps(event, separators=(',', ':')) + '\n' for event in events))
            old_env = {'HOME': str(home), 'PATH': os.environ['PATH'], 'CODEX_HOME': str(old_root / '.harness' / 'codex')}
            with subprocess.Popen(['codex', 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, env=old_env) as server:
                def warm(value):
                    server.stdin.write(json.dumps(value) + '\n'); server.stdin.flush()
                    while True:
                        response = json.loads(server.stdout.readline())
                        if response.get('id') == value['id']: return response
                self.assertIn('result', warm({'id': 10, 'method': 'initialize', 'params': {'clientInfo': {'name': 'restore-test', 'version': '1'}, 'capabilities': {'experimentalApi': True}}}))
                self.assertEqual(warm({'id': 11, 'method': 'thread/resume', 'params': {'threadId': sid, 'path': str(raw), 'excludeTurns': True}})['result']['thread']['id'], sid)
                self.assertEqual(warm({'id': 12, 'method': 'thread/read', 'params': {'threadId': sid, 'includeTurns': False}})['result']['thread']['id'], sid)
                server.terminate(); server.wait(timeout=5)
            archive(root=old_root, state=state, owner_id=old, source_root=source)
            shutil.rmtree(old_root)
            target = state / 'worktrees' / new; target.mkdir(parents=True); record = state / 'sessions' / new; record.mkdir(parents=True)
            (record / 'session-root').write_text(str(target.resolve()) + '\n'); (record / 'source-root').write_text(str(source.resolve()) + '\n')
            (record / 'journal').write_text('state=OPEN\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n')
            restored = rehydrate(session={'runtime':'codex','archived':True,'availability':'archived','launcher_session_id':old,'native_id':sid,'source_root':str(source.resolve())}, target_root=target, state=state, source_root=source, owner_id=new)
            env = {'HOME': str(home), 'PATH': os.environ['PATH'], 'CODEX_HOME': restored['native_home']}
            with subprocess.Popen(['codex', 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, env=env) as server:
                def request(value):
                    server.stdin.write(json.dumps(value) + '\n'); server.stdin.flush()
                    while True:
                        response = json.loads(server.stdout.readline())
                        if response.get('id') == value['id']:
                            return response
                initialize = request({'id': 1, 'method': 'initialize', 'params': {
                    'clientInfo': {'name': 'restore-test', 'version': '1'}, 'capabilities': {'experimentalApi': True}}})
                resumed = request({'id': 2, 'method': 'thread/resume', 'params': {
                    'threadId': sid, 'cwd': str(target), 'excludeTurns': True}})
                read = request({'id': 3, 'method': 'thread/read', 'params': {'threadId': sid, 'includeTurns': False}})
                server.terminate(); server.wait(timeout=5)
            self.assertEqual(Path(initialize['result']['codexHome']).resolve(), Path(restored['native_home']).resolve())
            self.assertIn('result', resumed, resumed)
            self.assertEqual(resumed['result']['thread']['id'], sid)
            self.assertEqual(read['result']['thread']['id'], sid)
            self.assertEqual(Path(resumed['result']['thread']['cwd']).resolve(), target.resolve())
            self.assertEqual(Path(read['result']['thread']['cwd']).resolve(), target.resolve())

    def test_refuses_to_overwrite_an_existing_codex_home(self):
        from harness_session_restore import RestoreError, rehydrate

        owner = '44444444-4444-4444-8444-444444444444'
        with tempfile.TemporaryDirectory() as tmp:
            state, source = Path(tmp, 'state'), Path(tmp, 'source')
            target = state / 'worktrees' / owner; target.mkdir(parents=True); source.mkdir()
            (target / '.harness' / 'codex').mkdir(parents=True)
            (target / '.harness' / 'codex' / 'keep').write_text('unrelated')
            record = state / 'sessions' / owner; record.mkdir(parents=True)
            (record / 'session-root').write_text(str(target.resolve()) + '\n')
            (record / 'source-root').write_text(str(source.resolve()) + '\n')
            (record / 'journal').write_text('state=OPEN\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n')
            session = {'runtime': 'codex', 'archived': True, 'availability': 'archived',
                       'launcher_session_id': owner, 'native_id': owner, 'source_root': str(source.resolve())}

            with self.assertRaises(RestoreError):
                rehydrate(session=session, target_root=target, state=state, source_root=source, owner_id=owner)
            self.assertEqual((target / '.harness' / 'codex' / 'keep').read_text(), 'unrelated')

    def test_rehydrates_verified_archived_codex_transcript_into_fresh_owner_home(self):
        from harness_session_archive import archive
        from harness_session_restore import rehydrate

        old = '11111111-1111-4111-8111-111111111111'
        new = '22222222-2222-4222-8222-222222222222'
        native = '33333333-3333-4333-8333-333333333333'
        with tempfile.TemporaryDirectory() as tmp:
            state, source = Path(tmp, 'state'), Path(tmp, 'source')
            old_root, target = Path(tmp, 'old'), state / 'worktrees' / new
            source.mkdir(); target.mkdir(parents=True)
            raw = old_root / '.harness' / 'codex' / 'sessions' / '2026' / f'{native}.jsonl'
            raw.parent.mkdir(parents=True)
            raw.write_text('{"type":"session_meta","payload":{"id":"%s"}}\nsynthetic only\n' % native)
            extra = raw.with_name('other-44444444-4444-4444-8444-444444444444.jsonl')
            extra.write_text('{"type":"session_meta","payload":{"id":"44444444-4444-4444-8444-444444444444"}}\n')
            (old_root / '.harness' / 'codex' / 'auth.json').write_text('excluded')
            archive(root=old_root, state=state, owner_id=old, source_root=source)
            record = state / 'sessions' / new; record.mkdir(parents=True)
            (record / 'session-root').write_text(str(target.resolve()) + '\n')
            (record / 'source-root').write_text(str(source.resolve()) + '\n')
            (record / 'journal').write_text('state=OPEN\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n')
            session = {'runtime': 'codex', 'archived': True, 'availability': 'archived',
                       'launcher_session_id': old, 'native_id': native,
                       'source_root': str(source.resolve()), 'transcript_path': str(state / 'archives' / old / raw.relative_to(old_root / '.harness'))}

            result = rehydrate(session=session, target_root=target, state=state, source_root=source, owner_id=new)

            restored = target / '.harness' / 'codex' / 'sessions' / '2026' / f'{native}.jsonl'
            self.assertEqual(restored.read_bytes(), raw.read_bytes())
            self.assertFalse((target / '.harness' / 'codex' / 'auth.json').exists())
            self.assertFalse((target / '.harness' / 'codex' / extra.relative_to(old_root / '.harness' / 'codex')).exists())
            self.assertEqual(result['native_id'], native)
            self.assertEqual(result['native_home'], str(target / '.harness' / 'codex'))
            self.assertEqual(result['grant_provenance'], {'codex': []})
            ledger = json.loads((state / 'sessions' / new / 'restored-native-sessions').read_text())
            self.assertEqual(ledger['imports'][0]['source_owner'], old)
            self.assertEqual(ledger['imports'][0]['native_id'], native)


class RestoreSafetyTest(unittest.TestCase):
    def setUp(self):
        import harness_session_restore as restore
        from harness_session_archive import archive
        self.restore=restore;self.temp=tempfile.TemporaryDirectory(prefix='native-restore-safety-');self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name).resolve();self.state=self.base/'state';self.source=self.base/'source';self.source.mkdir(mode=0o700)
        self.old='11111111-1111-4111-8111-111111111111';self.new='22222222-2222-4222-8222-222222222222';self.native='33333333-3333-4333-8333-333333333333'
        self.old_root=self.state/'worktrees'/self.old;raw=self.old_root/'.harness/codex/sessions/test'/(self.native+'.jsonl');raw.parent.mkdir(parents=True)
        raw.write_text(json.dumps({'type':'session_meta','payload':{'id':self.native}})+'\n')
        archive(root=self.old_root,state=self.state,source_root=self.source,owner_id=self.old)
        self.target=self.state/'worktrees'/self.new;self.target.mkdir(mode=0o700)
        self.record=self.state/'sessions'/self.new;self.record.mkdir(parents=True,mode=0o700)
        (self.record/'source-root').write_text(str(self.source));(self.record/'session-root').write_text(str(self.target));(self.record/'journal').write_text('state=OPEN\n')
        self.session={'runtime':'codex','archived':True,'source_root':str(self.source),'launcher_session_id':self.old,'native_id':self.native}

    def run_restore(self):
        return self.restore.rehydrate(session=self.session,target_root=self.target,state=self.state,source_root=self.source,owner_id=self.new)

    def test_symlink_target_never_writes_outside_owner(self):
        outside=self.base/'outside';self.target.rename(outside);self.target.symlink_to(outside,target_is_directory=True)
        (self.record/'session-root').write_text(str(outside))
        with self.assertRaises(self.restore.RestoreError):self.run_restore()
        self.assertFalse((outside/'.harness').exists())

    def test_target_parent_traversal_cannot_change_the_returned_native_home(self):
        intermediate=self.state/'worktrees/intermediate';intermediate.mkdir()
        target=intermediate/'..'/self.new
        with self.assertRaises(self.restore.RestoreError):
            self.restore.rehydrate(session=self.session,target_root=target,state=self.state,source_root=self.source,owner_id=self.new)

    def test_symlink_worktree_and_record_parent_are_rejected(self):
        for name in ('worktrees','sessions'):
            with self.subTest(parent=name):
                parent=self.state/name;outside=self.base/('outside-'+name);parent.rename(outside);parent.symlink_to(outside,target_is_directory=True)
                if name=='worktrees':(self.record/'session-root').write_text(str(outside/self.new))
                with self.assertRaises(self.restore.RestoreError):self.run_restore()
                parent.unlink();outside.rename(parent);(self.record/'session-root').write_text(str(self.target))

    def test_linked_metadata_and_harness_are_rejected(self):
        for name in ('source-root','session-root','journal'):
            with self.subTest(metadata=name):
                path=self.record/name;outside=self.base/('outside-'+name);path.rename(outside);path.symlink_to(outside)
                with self.assertRaises(self.restore.RestoreError):self.run_restore()
                path.unlink();outside.rename(path)
        outside=self.base/'outside-harness';outside.mkdir();(self.target/'.harness').symlink_to(outside,target_is_directory=True)
        with self.assertRaises(self.restore.RestoreError):self.run_restore()
        self.assertFalse((outside/'codex').exists())

    def test_group_writable_and_oversized_metadata_are_rejected(self):
        journal=self.record/'journal';journal.chmod(0o660)
        with self.assertRaises(self.restore.RestoreError):self.run_restore()
        journal.chmod(0o600);journal.write_text('state=OPEN\n'+'x'*65536)
        with self.assertRaises(self.restore.RestoreError):self.run_restore()

    def test_hardlinked_metadata_unsafe_directories_and_bad_identity_are_rejected(self):
        path=self.record/'source-root';link=self.base/'hardlinked-source-root';os.link(path,link)
        with self.assertRaises(self.restore.RestoreError):self.run_restore()
        link.unlink()
        for directory in (self.state,self.state/'worktrees',self.state/'sessions',self.record,self.target,self.source):
            with self.subTest(directory=directory.name):
                original=directory.stat().st_mode&0o777;directory.chmod(original|0o020)
                with self.assertRaises(self.restore.RestoreError):self.run_restore()
                directory.chmod(original)
        for value in (None,True,'invalid-owner','00000000-0000-0000-0000-000000000000'):
            with self.subTest(owner=value):
                with self.assertRaises(self.restore.RestoreError):
                    self.restore.rehydrate(session=self.session,target_root=self.target,state=self.state,source_root=self.source,owner_id=value)

    def test_root_and_harness_swap_before_publish_do_not_write_to_the_new_target(self):
        copy=self.restore._copy_verified;outside=self.base/'retired-target'
        def changed(*args,**kwargs):
            result=copy(*args,**kwargs);self.target.rename(outside);self.target.mkdir();return result
        with patch.object(self.restore,'_copy_verified',side_effect=changed):
            with self.assertRaises(self.restore.RestoreError):self.run_restore()
        self.assertFalse((self.target/'.harness/codex').exists());self.assertFalse((outside/'.harness/codex').exists())
        self.assertFalse((self.record/'restored-native-sessions').exists())

    def test_ledger_failure_does_not_mask_the_error_or_leave_partial_publication(self):
        with patch.object(self.restore.os,'fsync',side_effect=OSError('fictional fsync failure')):
            with self.assertRaises(self.restore.RestoreError) as failure:self.run_restore()
        self.assertNotIn('Bad file descriptor',str(failure.exception))
        self.assertFalse((self.target/'.harness/codex').exists());self.assertFalse((self.record/'restored-native-sessions').exists())

    def test_record_directory_fsync_failure_removes_the_owned_import_ledger(self):
        fsync=self.restore.os.fsync
        def failure(fd):
            if os.fstat(fd).st_ino==self.record.stat().st_ino:raise OSError('fictional record fsync failure')
            return fsync(fd)
        with patch.object(self.restore.os,'fsync',side_effect=failure):
            with self.assertRaises(self.restore.RestoreError):self.run_restore()
        self.assertFalse((self.record/'restored-native-sessions').exists());self.assertFalse((self.target/'.harness/codex').exists())

    def test_publish_never_replaces_a_foreign_empty_codex_directory(self):
        write=self.restore._write_import;foreign=[]
        def changed(*args,**kwargs):
            result=write(*args,**kwargs);path=self.target/'.harness/codex';path.mkdir();foreign.append(path.stat().st_ino);return result
        with patch.object(self.restore,'_write_import',side_effect=changed):
            with self.assertRaises(self.restore.RestoreError):self.run_restore()
        path=self.target/'.harness/codex'
        self.assertEqual(path.stat().st_ino,foreign[0]);self.assertEqual(list(path.iterdir()),[])
        self.assertFalse((self.record/'restored-native-sessions').exists())

    def test_harness_swap_after_ledger_refuses_publish_and_preserves_foreign_files(self):
        write=self.restore._write_import;outside=self.base/'retired-owned-harness';foreign=self.base/'foreign-harness';foreign.mkdir();(foreign/'keep').write_text('unrelated')
        def changed(*args,**kwargs):
            result=write(*args,**kwargs);(self.target/'.harness').rename(outside);(self.target/'.harness').symlink_to(foreign,target_is_directory=True);return result
        with patch.object(self.restore,'_write_import',side_effect=changed):
            with self.assertRaises(self.restore.RestoreError):self.run_restore()
        self.assertFalse((outside/'codex').exists());self.assertEqual((foreign/'keep').read_text(),'unrelated')
        self.assertFalse((self.record/'restored-native-sessions').exists())

    def test_fifo_metadata_is_rejected_without_waiting_for_a_writer(self):
        if not hasattr(os,'mkfifo'):self.skipTest('POSIX FIFO required')
        journal=self.record/'journal';journal.unlink();os.mkfifo(journal)
        payload={'session':self.session,'target_root':str(self.target),'state':str(self.state),'source_root':str(self.source),'owner_id':self.new}
        code='import json,sys;from pathlib import Path;from harness_session_restore import rehydrate,RestoreError;r=json.loads(sys.argv[1]);r.update({k:Path(r[k]) for k in ("target_root","state","source_root")});\ntry:rehydrate(**r)\nexcept RestoreError:sys.exit(7)'
        result=subprocess.run([sys.executable,'-B','-c',code,json.dumps(payload)],env=dict(os.environ,PYTHONPATH=str(Path(__file__).resolve().parents[1]/'bin')),capture_output=True,timeout=3)
        self.assertEqual(result.returncode,7)

    def test_metadata_and_root_swap_before_publish_are_rejected(self):
        copy=self.restore._copy_verified
        outside=self.base/'outside-source-root';outside.write_text(str(self.source))
        def changed(*args,**kwargs):
            result=copy(*args,**kwargs);(self.record/'source-root').unlink();(self.record/'source-root').symlink_to(outside);return result
        with patch.object(self.restore,'_copy_verified',side_effect=changed):
            with self.assertRaises(self.restore.RestoreError):self.run_restore()
        self.assertFalse((self.target/'.harness/codex').exists());self.assertFalse((self.record/'restored-native-sessions').exists())

    def test_archive_source_swap_cannot_follow_a_foreign_parent(self):
        copy=self.restore._copy_verified;archive=self.state/'archives'/self.old;outside=self.base/'outside-archive';outside.mkdir()
        original=archive/'codex';original.rename(outside/'codex');original.symlink_to(outside/'codex',target_is_directory=True)
        with self.assertRaises(self.restore.RestoreError):self.run_restore()
        self.assertFalse((self.target/'.harness/codex').exists())

    def test_live_archive_keeps_the_original_kernel_lease_during_copy(self):
        from harness_session_archive import archive
        record=self.state/'sessions'/self.old;record.mkdir()
        (record/'source-root').write_text(str(self.source));(record/'session-root').write_text(str(self.old_root));(record/'journal').write_text('state=CLOSED\n');(record/'runtime.lock').touch()
        self.session['archived']=False
        def checked(*args,**kwargs):
            code='import fcntl,sys;f=open(sys.argv[1],"r+");\ntry:fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError:sys.exit(9)'
            result=subprocess.run([sys.executable,'-B','-c',code,str(record/'runtime.lock')],capture_output=True,timeout=3)
            self.assertEqual(result.returncode,9,'the source lease was released before archival')
            return archive(*args,**kwargs)
        with patch.object(self.restore,'archive',side_effect=checked):self.run_restore()


if __name__ == '__main__':
    unittest.main()
