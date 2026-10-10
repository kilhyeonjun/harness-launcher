#!/usr/bin/env python3
import hashlib
import json
import sys
import tempfile
import unittest
import os
import fcntl
import subprocess
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bin'))


class SessionCatalogTest(unittest.TestCase):
    def test_linked_terminal_journal_is_partial_and_never_read_as_owner(self):
        from harness_session_catalog import catalog
        owner='11111111-1111-4111-8111-111111111111';native='22222222-2222-4222-8222-222222222222'
        with tempfile.TemporaryDirectory() as tmp:
            state,source,home=Path(tmp,'state'),Path(tmp,'source'),Path(tmp,'home');source.mkdir()
            root=state/'worktrees'/owner;raw=root/'.harness/codex/sessions'/f'{native}.jsonl';raw.parent.mkdir(parents=True)
            raw.write_text(json.dumps({'type':'session_meta','payload':{'id':native}})+'\n')
            record=state/'sessions'/owner;record.mkdir(parents=True)
            (record/'source-root').write_text(str(source.resolve()));(record/'session-root').write_text(str(root))
            outside=Path(tmp,'private-outside');outside.write_text('state=CLOSED\nsecret=never-display\n')
            (record/'journal').symlink_to(outside);(record/'runtime.lock').touch()
            result=catalog(state,{'demo':source},home)
            self.assertEqual(result['items'],[]);self.assertEqual(result['status'],'partial')
            self.assertNotIn('never-display',json.dumps(result));self.assertNotIn(str(outside),json.dumps(result['problems']))

    def test_claude_fifo_and_session_limit_are_reported_as_partial(self):
        import harness_session_catalog as module
        with tempfile.TemporaryDirectory() as tmp:
            source,home=Path(tmp,'source'),Path(tmp,'home');source.mkdir()
            folder=home/'.claude/projects/fixture';folder.mkdir(parents=True)
            os.mkfifo(folder/'unsafe.jsonl')
            self.assertEqual(module.catalog(Path(tmp,'state'),{'demo':source},home)['status'],'partial')
            (folder/'unsafe.jsonl').unlink()
            for native in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222'):
                (folder/(native+'.jsonl')).write_text(json.dumps({'sessionId':native,'cwd':str(source)})+'\n')
            with mock.patch.object(module,'MAX_SESSIONS',1):result=module.catalog(Path(tmp,'state'),{'demo':source},home)
            self.assertEqual(len(result['items']),1);self.assertEqual(result['status'],'partial')

    def test_intermediate_native_home_link_is_not_followed(self):
        from harness_session_catalog import catalog
        with tempfile.TemporaryDirectory() as tmp:
            source,other=Path(tmp,'source'),Path(tmp,'outside');source.mkdir();(source/'.harness').mkdir()
            folder=other/'sessions';folder.mkdir(parents=True);native='11111111-1111-4111-8111-111111111111'
            (folder/(native+'.jsonl')).write_text(json.dumps({'type':'session_meta','payload':{'id':native}})+'\n')
            (source/'.harness/codex').symlink_to(other,target_is_directory=True)
            result=catalog(Path(tmp,'state'),{'demo':source},Path(tmp,'home'))
            self.assertEqual(result['items'],[]);self.assertEqual(result['status'],'partial')

    def test_tampered_own_archive_is_partial_but_other_source_is_skipped(self):
        from harness_session_archive import archive
        from harness_session_catalog import catalog
        with tempfile.TemporaryDirectory() as tmp:
            source,other,state,root=Path(tmp,'source'),Path(tmp,'other'),Path(tmp,'state'),Path(tmp,'root')
            source.mkdir();other.mkdir();raw=root/'.harness/codex/sessions/file.jsonl';raw.parent.mkdir(parents=True);raw.write_text('original')
            owner='11111111-1111-4111-8111-111111111111';saved=archive(root=root,state=state,owner_id=owner,source_root=source)
            (saved/'codex/sessions/file.jsonl').write_text('changed')
            result=catalog(state,{'own':source,'other':other},Path(tmp,'home'))
            self.assertEqual(result['status'],'partial')
            self.assertTrue(any(p.get('profile')=='own' for p in result['problems']))
            self.assertFalse(any(p.get('profile')=='other' for p in result['problems']))

    def test_closed_session_with_held_runtime_lock_is_active(self):
        from harness_session_catalog import catalog
        owner = '99999999-9999-4999-8999-999999999999'; native = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        with tempfile.TemporaryDirectory() as tmp:
            state, source, home = Path(tmp, 'state'), Path(tmp, 'source'), Path(tmp, 'home'); source.mkdir()
            root = state / 'worktrees' / owner; raw = root / '.harness' / 'codex' / 'sessions' / f'{native}.jsonl'; raw.parent.mkdir(parents=True)
            raw.write_text(json.dumps({'type':'session_meta','payload':{'id':native}})+'\n')
            record = state / 'sessions' / owner; record.mkdir(parents=True)
            (record/'source-root').write_text(str(source.resolve())+'\n'); (record/'session-root').write_text(str(root)+'\n')
            (record/'journal').write_text('state=CLOSED\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n'); lock = record/'runtime.lock'; lock.touch()
            claude=home/'.claude/projects/fixture'/f'{native}.jsonl';claude.parent.mkdir(parents=True)
            claude.write_text(json.dumps({'sessionId':native,'cwd':str(root)})+'\n');(record/'provider-sessions').write_text('claude '+native+'\n')
            holder = subprocess.Popen([sys.executable, '-c', 'import fcntl,sys,time; f=open(sys.argv[1],"r+"); fcntl.lockf(f,fcntl.LOCK_EX); print("ready",flush=True); time.sleep(5)', str(lock)], stdout=subprocess.PIPE, text=True)
            self.addCleanup(lambda: holder.poll() is None and holder.terminate())
            self.assertEqual(holder.stdout.readline().strip(), 'ready')
            items=catalog(state,{'demo':source},home)['items']
            holder.terminate(); holder.wait(timeout=5); holder.stdout.close()
            self.assertEqual({item['runtime'] for item in items},{'codex','claude'})
            for item in items:
                self.assertEqual(item['availability'],'active');self.assertFalse(item['can_resume']);self.assertFalse(item['can_fork'])

    def test_invalid_import_proof_never_turns_parent_into_owned_session(self):
        from harness_session_catalog import catalog
        with tempfile.TemporaryDirectory() as tmp:
            source,state=Path(tmp,'source'),Path(tmp,'state');source.mkdir()
            owner='11111111-1111-4111-8111-111111111111';native='22222222-2222-4222-8222-222222222222'
            root=state/'worktrees'/owner;raw=root/'.harness/codex/sessions'/f'{native}.jsonl';raw.parent.mkdir(parents=True)
            raw.write_text(json.dumps({'type':'session_meta','payload':{'id':native}})+'\n')
            record=state/'sessions'/owner;record.mkdir(parents=True)
            (record/'source-root').write_text(str(source.resolve()));(record/'session-root').write_text(str(root));(record/'journal').write_text('state=CLOSED\n');(record/'runtime.lock').touch()
            (record/'restored-native-sessions').write_text('{"schema":1,"source_root":"foreign"}')
            result=catalog(state,{'demo':source},Path(tmp,'home'))
            self.assertEqual(result['items'],[]);self.assertEqual(result['status'],'partial')

    def test_depth_and_node_budgets_return_explicit_partial_results(self):
        import harness_session_catalog as module
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp,'source');folder=source/'.harness/codex/sessions';folder.mkdir(parents=True)
            for index in range(4):(folder/f'{index}.jsonl').write_text('[]\n')
            with mock.patch.object(module,'MAX_NODES',2):result=module.catalog(Path(tmp,'state'),{'demo':source},Path(tmp,'home'))
            self.assertEqual(result['status'],'partial');self.assertIn({'code':'transcript_scan_budget','profile':'demo'},result['problems'])
            for index in range(14):folder=folder/str(index);folder.mkdir()
            result=module.catalog(Path(tmp,'state'),{'demo':source},Path(tmp,'home'))
            self.assertIn({'code':'transcript_depth_budget','profile':'demo'},result['problems'])

    def test_fifo_transcript_is_ignored_without_blocking_catalog(self):
        from harness_session_catalog import catalog
        with tempfile.TemporaryDirectory() as tmp:
            state, source, home = Path(tmp, 'state'), Path(tmp, 'source'), Path(tmp, 'home')
            source.mkdir(); fifo = source / '.harness' / 'codex' / 'sessions' / 'unsafe.jsonl'; fifo.parent.mkdir(parents=True)
            os.mkfifo(fifo)
            result = catalog(state, {'demo': source}, home)
            self.assertEqual(result['items'], [])
            self.assertEqual(result['status'], 'partial')
            self.assertIn({'code':'unsafe_transcript_node','profile':'demo'}, result['problems'])

    def test_catalogs_same_source_claude_project_session(self):
        from harness_session_catalog import catalog

        native = '33333333-3333-4333-8333-333333333333'
        with tempfile.TemporaryDirectory() as tmp:
            state, source, home = Path(tmp, 'state'), Path(tmp, 'source'), Path(tmp, 'home')
            transcript = home / '.claude' / 'projects' / 'fixture' / f'{native}.jsonl'
            transcript.parent.mkdir(parents=True); source.mkdir()
            transcript.write_text(json.dumps({'sessionId': native, 'cwd': str(source)}) + '\nraw conversation\n')

            result = catalog(state, {'demo': source}, home)

            self.assertEqual(len(result['items']), 1)
            self.assertEqual(result['items'][0]['runtime'], 'claude')
            self.assertEqual(result['items'][0]['availability'], 'legacy')

    def test_claude_progress_first_line_uses_later_bounded_metadata(self):
        from harness_session_catalog import catalog
        native = '12121212-1212-4121-8121-121212121212'
        with tempfile.TemporaryDirectory() as tmp:
            state, source, home = Path(tmp, 'state'), Path(tmp, 'source'), Path(tmp, 'home'); source.mkdir()
            path = home / '.claude' / 'projects' / 'fixture' / f'{native}.jsonl'; path.parent.mkdir(parents=True)
            path.write_text(json.dumps({'type':'progress','payload':{'done':False}})+'\n'+json.dumps({'type':'user','payload':{'sessionId':native,'cwd':str(source.resolve())}})+'\n')
            self.assertEqual(catalog(state, {'demo':source}, home)['items'][0]['native_id'], native)

    def test_claude_provider_owner_marks_open_session_active(self):
        from harness_session_catalog import catalog

        owner = '44444444-4444-4444-8444-444444444444'; native = '55555555-5555-4555-8555-555555555555'
        with tempfile.TemporaryDirectory() as tmp:
            state, source, home = Path(tmp, 'state'), Path(tmp, 'source'), Path(tmp, 'home')
            source.mkdir(); transcript = home / '.claude' / 'projects' / 'fixture' / f'{native}.jsonl'; transcript.parent.mkdir(parents=True)
            isolated_cwd = state / 'worktrees' / owner
            transcript.write_text(json.dumps({'sessionId': native, 'cwd': str(isolated_cwd)}) + '\n')
            record = state / 'sessions' / owner; record.mkdir(parents=True)
            (record / 'source-root').write_text(str(source.resolve()) + '\n')
            (record / 'journal').write_text('state=OPEN\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n')
            (record / 'provider-sessions').write_text('claude %s\n' % native)

            item = catalog(state, {'demo': source}, home)['items'][0]
            self.assertEqual(item['launcher_session_id'], owner)
            self.assertEqual(item['availability'], 'active')
            self.assertFalse(item['can_resume'])
            self.assertFalse(item['can_fork'])

    def test_catalogs_archived_native_session_without_exposing_transcript(self):
        from harness_session_catalog import catalog, resolve

        owner = '11111111-1111-4111-8111-111111111111'
        native = '22222222-2222-4222-8222-222222222222'
        with tempfile.TemporaryDirectory() as tmp:
            state, source, home = Path(tmp, 'state'), Path(tmp, 'source'), Path(tmp, 'home')
            transcript = state / 'archives' / owner / 'codex' / 'sessions' / '2026' / f'{native}.jsonl'
            transcript.parent.mkdir(parents=True)
            transcript.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': native, 'cwd': str(source)}}) + '\nsecret conversation\n')
            digest = hashlib.sha256(transcript.read_bytes()).hexdigest()
            provenance = {'codex': []}
            (transcript.parents[3] / 'manifest.json').write_text(json.dumps({
                'version': 1, 'session_id': owner, 'source_root': str(source.resolve()),
                'files': [{'path': str(transcript.relative_to(transcript.parents[3])), 'bytes': transcript.stat().st_size, 'sha256': digest}],
                'grant_provenance': provenance,
                'grant_provenance_sha256': hashlib.sha256(json.dumps(provenance, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
            }))
            source.mkdir(); home.mkdir()
            saved=transcript.parents[3]
            for directory in [saved,*[p for p in saved.rglob('*') if p.is_dir()]]:directory.chmod(0o700)
            for file in [p for p in saved.rglob('*') if p.is_file()]:file.chmod(0o600)

            result = catalog(state, {'demo': source}, home)

            self.assertEqual(result['status'], 'ready')
            self.assertEqual(len(result['items']), 1)
            item = result['items'][0]
            self.assertEqual(item['availability'], 'archived')
            self.assertNotIn('secret conversation', json.dumps(item))
            self.assertTrue(item['can_fork'])
            record = resolve(state, {'demo': source}, home, item['id'])
            self.assertEqual(record['native_id'], native)
            self.assertTrue(record['archived'])

    def test_archived_import_hides_parent_but_keeps_new_child_uuid(self):
        from harness_session_archive import archive
        from harness_session_catalog import catalog
        owner='abababab-abab-4bab-8bab-abababababab'; parent='cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd'; child='edededed-eded-4ede-8ede-edededededed'
        with tempfile.TemporaryDirectory() as tmp:
            state, source, root, home = Path(tmp,'state'), Path(tmp,'source'), Path(tmp,'root'), Path(tmp,'home'); source.mkdir()
            folder=root/'.harness'/'codex'/'sessions'; folder.mkdir(parents=True)
            for native in (parent, child): (folder/(native+'.jsonl')).write_text(json.dumps({'type':'session_meta','payload':{'id':native}})+'\n')
            record=state/'sessions'/owner; record.mkdir(parents=True)
            (record/'restored-native-sessions').write_text(json.dumps({'schema':1,'session_id':owner,'source_root':str(source.resolve()),'imports':[{'runtime':'codex','native_id':parent,'source_owner':'ffffffff-ffff-4fff-8fff-ffffffffffff'}]}))
            archive(root=root,state=state,owner_id=owner,source_root=source)
            ids={item['native_id'] for item in catalog(state,{'demo':source},home)['items']}
            self.assertEqual(ids,{child})

    def test_native_restore_selection_assigns_only_selected_uuid_to_new_owner_live_and_archive(self):
        from harness_session_archive import archive
        from harness_session_catalog import catalog
        old='11111111-1111-4111-8111-111111111111';new='11111111-1111-4111-8111-111111111112'
        parent='22222222-2222-4222-8222-222222222222';child='33333333-3333-4333-8333-333333333333';snapshot='a'*64
        with tempfile.TemporaryDirectory() as tmp:
            state,source,home=Path(tmp,'state'),Path(tmp,'source'),Path(tmp,'home');source.mkdir()
            def owner(identifier, natives):
                root=state/'worktrees'/identifier;folder=root/'.harness/codex/sessions';folder.mkdir(parents=True)
                for native in natives:(folder/(native+'.jsonl')).write_text(json.dumps({'type':'session_meta','payload':{'id':native}})+'\n'+json.dumps({'type':'turn_context','payload':{}})+'\n')
                record=state/'sessions'/identifier;record.mkdir(parents=True)
                (record/'source-root').write_text(str(source.resolve()));(record/'session-root').write_text(str(root));(record/'journal').write_text('state=CLOSED\n');(record/'runtime.lock').touch()
                return root,record
            old_root,_=owner(old,[parent]);new_root,new_record=owner(new,[parent,child])
            receipt=new_record/'native-history-restore.json'
            from test_session_archive import native_restore_fixture
            snapshot=native_restore_fixture(source,state,new_root/'.harness/codex',receipt,child)
            import shutil;shutil.rmtree(source/'.harness/codex')
            live=catalog(state,{'demo':source},home)['items']
            self.assertEqual({(item['native_id'],item['launcher_session_id']) for item in live},{(parent,old),(child,new)})
            saved=archive(root=new_root,state=state,owner_id=new,source_root=source)
            self.assertEqual(len(list((saved/'codex/sessions').glob('*.jsonl'))),2)
            shutil.rmtree(new_root);receipt.unlink()
            archived=catalog(state,{'demo':source},home)['items']
            self.assertEqual({(item['native_id'],item['launcher_session_id']) for item in archived},{(parent,old),(child,new)})

    def test_invalid_native_restore_receipt_is_partial_before_transcript_read(self):
        import harness_session_catalog as module
        from test_session_archive import native_restore_fixture
        owner='11111111-1111-4111-8111-111111111111';native='22222222-2222-4222-8222-222222222222'
        with tempfile.TemporaryDirectory() as tmp:
            state,source=Path(tmp,'state'),Path(tmp,'source');source.mkdir()
            root=state/'worktrees'/owner;raw=root/'.harness/codex/sessions'/(native+'.jsonl');raw.parent.mkdir(parents=True)
            raw.write_text(json.dumps({'type':'session_meta','payload':{'id':native}})+'\n')
            record=state/'sessions'/owner;record.mkdir(parents=True)
            for name,value in {'source-root':str(source.resolve()),'session-root':str(root),'journal':'state=CLOSED\n','runtime.lock':''}.items():(record/name).write_text(value)
            receipt=record/'native-history-restore.json';native_restore_fixture(source,state,root/'.harness/codex',receipt,native)
            import shutil;shutil.rmtree(source/'.harness/codex');receipt.chmod(0o644)
            with mock.patch.object(module,'_record',side_effect=AssertionError('transcript read before restore proof')):
                result=module.catalog(state,{'demo':source},Path(tmp,'home'))
            self.assertEqual(result['items'],[]);self.assertEqual(result['status'],'partial')
            self.assertIn({'code':'unsafe_native_restore','profile':'demo'},result['problems'])


if __name__ == '__main__':
    unittest.main()
