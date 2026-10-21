"""Projection checks and bounded Native RPC transport, using owned fixtures."""
import importlib.util
import base64
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("codex_history_native", ROOT / "bin/codex_history_native.py")
native = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native)
ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
ITEM = {"type": "userMessage", "id": "question", "clientId": None,
        "content": [{"type": "text", "text": "fixture sentinel", "text_elements": []}]}


class ProjectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "codex"; self.home.mkdir()
        sessions = self.home / "sessions"; sessions.mkdir()
        (sessions / ("rollout-" + ID + ".jsonl")).write_text(json.dumps({
            "type": "session_meta", "payload": {"id": ID, "history_mode": "paginated"}}) + "\n" +
            json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user"}}) + "\n")
        db = sqlite3.connect(self.home / "thread_history_1.sqlite")
        db.execute("CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT)")
        db.execute("CREATE TABLE thread_items(thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER, item_json TEXT)")
        db.execute("INSERT INTO thread_turns VALUES (?, 'turn', 1, 'completed')", (ID,))
        db.execute("INSERT INTO thread_items VALUES (?, 'turn', 'question', 2, ?)", (ID, json.dumps(ITEM)))
        db.commit(); db.close()

    def test_projection_requires_nonempty_rows_for_nonempty_transcript(self):
        projection = native.expected_history(self.home)
        self.assertEqual(projection[ID]["turns"], ["turn"])
        self.assertEqual(projection[ID]["items"], [{"turnId": "turn", "item": ITEM}])
        db = sqlite3.connect(self.home / "thread_history_1.sqlite")
        db.execute("DELETE FROM thread_items"); db.commit(); db.close()
        with self.assertRaises(native.NativeVerificationError): native.expected_history(self.home)

    def test_empty_success_and_changed_wire_items_never_verify(self):
        class Rpc:
            def __init__(self, *args): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def call(self, method, params):
                if method == 'fs/readFile': return {'dataBase64':base64.b64encode(Path(params['path']).read_bytes()).decode()}
                if method == "thread/resume": return {"thread": {"id": ID}}
                return {"data": [], "nextCursor": None}
        with patch.object(native, "NativeRpc", Rpc), patch.object(native, "binary_identity", return_value={"version": "0.161.0", "sha256": "f" * 64}):
            with self.assertRaises(native.NativeVerificationError): native.verify_native(self.home, {}, "/fixture/codex")

    def test_all_pages_match_preserved_projection(self):
        calls = []
        class Rpc:
            def __init__(self, *args): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def call(self, method, params):
                calls.append((method, params))
                if method == 'fs/readFile': return {'dataBase64':base64.b64encode(Path(params['path']).read_bytes()).decode()}
                if method == "thread/resume": return {"thread": {"id": ID}}
                if method == "thread/turns/list": return {"data": [{"id": "turn"}], "nextCursor": None}
                if not params.get("cursor"): return {"data": [], "nextCursor": "second"}
                return {"data": [{"turnId": "turn", "item": ITEM}], "nextCursor": None}
        with patch.object(native, "NativeRpc", Rpc), patch.object(native, "binary_identity", return_value={"version": "0.161.0", "sha256": "f" * 64}):
            receipt = native.verify_native(self.home, {}, "/fixture/codex")
        self.assertEqual(receipt["threads"][0]["item_count"], 1)
        self.assertEqual(receipt["threads"][0]["turn_count"], 1)
        self.assertEqual(receipt["model_requests"], 0)
        self.assertEqual([method for method,_ in calls if method!='fs/readFile'][0], "thread/resume")
        self.assertTrue(any(p.get("cursor") == "second" for _, p in calls))

    def test_parent_reference_must_be_inside_archive(self):
        path = next((self.home / "sessions").iterdir())
        rows = path.read_text().splitlines(); meta = json.loads(rows[0])
        meta["payload"]["history_base"] = {"thread_id": "ffffffff-1111-4222-8333-444444444444"}
        path.write_text(json.dumps(meta) + "\n" + "\n".join(rows[1:]) + "\n")
        with self.assertRaises(native.NativeVerificationError): native.expected_history(self.home)

    def test_orphan_segment_cannot_be_ignored_by_successful_other_thread(self):
        orphan='ffffffff-1111-4222-8333-444444444444'
        (self.home/'sessions'/('rollout-'+orphan+'_0001.jsonl')).write_text(
            json.dumps({'type':'response_item','payload':{'type':'message','role':'user'}})+'\n')
        with self.assertRaises(native.NativeVerificationError): native.expected_history(self.home)

    def test_fork_inherits_parent_projection_only_at_matching_byte_ordinal_cut(self):
        parent=next((self.home/'sessions').iterdir())
        rows=[json.loads(line) for line in parent.read_text().splitlines()]
        rows[0]['ordinal']=0;rows[1]['ordinal']=3
        parent.write_text(''.join(json.dumps(row)+'\n' for row in rows))
        child='01a123ce-3880-7613-81c9-79cd5213dcec'
        meta={'ordinal':0,'type':'session_meta','payload':{'id':child,'history_mode':'paginated',
              'history_base':{'thread_id':ID,'end_ordinal_exclusive':4,'end_byte_offset':parent.stat().st_size}}}
        path=self.home/'sessions'/('rollout-'+child+'.jsonl');path.write_text(json.dumps(meta)+'\n')
        history=native.expected_history(self.home)
        self.assertEqual(history[child],history[ID])
        meta['payload']['history_base']['end_byte_offset']+=1;path.write_text(json.dumps(meta)+'\n')
        with self.assertRaises(native.NativeVerificationError):native.expected_history(self.home)

    def test_projection_cursor_cannot_claim_bytes_beyond_preserved_rollout(self):
        db=sqlite3.connect(self.home/'thread_history_1.sqlite')
        db.execute('CREATE TABLE thread_history_projection_state(thread_id TEXT,next_rollout_byte_offset INTEGER)')
        db.execute('INSERT INTO thread_history_projection_state VALUES (?,?)',(ID,100000))
        db.commit();db.close()
        with self.assertRaises(native.NativeVerificationError):native.expected_history(self.home)

    def test_projection_thread_without_rollout_is_not_ignored(self):
        db=sqlite3.connect(self.home/'thread_history_1.sqlite')
        db.execute("INSERT INTO thread_turns VALUES ('unpreserved','turn',1,'completed')")
        db.commit();db.close()
        with self.assertRaises(native.NativeVerificationError):native.expected_history(self.home)

    def test_only_characterized_native_versions_verify(self):
        binary = self.home.parent / "codex-binary"; binary.write_text("fixture"); binary.chmod(0o755)
        for version, accepted in (("0.161.0", True), ("0.162.1", True), ("0.162.0", False), ("0.163.0", True), ("0.164.0", False)):
            done = type("Done", (), {"returncode": 0, "stdout": ("codex-cli " + version + "\n").encode()})()
            with patch.object(native, "sandbox_command", return_value=["fixture"]), \
                    patch.object(native.subprocess, "run", return_value=done):
                if accepted:
                    self.assertEqual(native.binary_identity(binary)["version"], version)
                else:
                    with self.assertRaisesRegex(native.NativeVerificationError, "lacks characterized"):
                        native.binary_identity(binary)


    def test_empty_catalog_cannot_hide_orphan_projection_cursor(self):
        next((self.home/'sessions').iterdir()).unlink()
        with sqlite3.connect(self.home/'thread_history_1.sqlite') as db:
            db.execute('DELETE FROM thread_turns');db.execute('DELETE FROM thread_items')
            db.execute('CREATE TABLE thread_history_projection_state(thread_id TEXT,next_rollout_byte_offset INTEGER)')
            db.execute('INSERT INTO thread_history_projection_state VALUES (?,?)',(ID,1))
        with sqlite3.connect(self.home/'state_5.sqlite') as db:
            db.execute('CREATE TABLE threads(id TEXT)')
        with self.assertRaises(native.NativeVerificationError):native.expected_history(self.home)

    def test_repeated_history_cursor_is_rejected(self):
        class Rpc:
            def call(self,method,params):return {'data':[],'nextCursor':'repeated'}
        with self.assertRaisesRegex(native.NativeVerificationError,'cursor repeated'):
            native.pages(Rpc(),'thread/items/list',ID)

    def test_changed_embedded_parent_metadata_is_retained(self):
        parent=json.loads(next((self.home/'sessions').iterdir()).read_text().splitlines()[0])
        child='ffffffff-1111-4222-8333-444444444444'
        primary=json.loads(json.dumps(parent));primary['payload']['id']=child;primary['ordinal']=0
        parent['ordinal']=1;parent['payload']['originator']='unpreserved metadata variant'
        (self.home/'sessions'/('rollout-'+child+'.jsonl')).write_text(json.dumps(primary)+'\n'+json.dumps(parent)+'\n')
        with self.assertRaisesRegex(native.NativeVerificationError,'identical preserved primary'):
            native.expected_history(self.home)


class RealNativeCharacterizationTests(unittest.TestCase):
    """Opt-in real offline protocol proof; never sends turn/start or tool results."""
    def setUp(self):
        import os
        self.binary = os.environ.get('HARNESS_TEST_REAL_CODEX_BIN')
        if not self.binary:
            self.skipTest('set HARNESS_TEST_REAL_CODEX_BIN for offline native characterization')
        self.temp = tempfile.TemporaryDirectory(prefix='native-proof-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.home = self.base / 'source' / '.harness' / 'codex'
        self.home.mkdir(parents=True)

    def make_history(self, turns=1):
        path = self.home / 'sessions' / ('rollout-2026-10-01T00-00-00-' + ID + '.jsonl')
        path.parent.mkdir()
        self.turn_ids = []; self.items = []; self.cuts = []
        rows = [{'type':'session_meta','payload':{'id':ID,'timestamp':'2026-10-01T00:00:00Z',
            'cwd':str(self.home),'originator':'fixture','cli_version':'0.163.0',
            'source':'cli','model_provider':'openai','history_mode':'paginated'}}]
        for i in range(turns):
            turn = 'bbbbbbbb-cccc-4ddd-8eee-' + f'{i:012d}'
            self.turn_ids.append(turn)
            item = {'type':'UserMessage','id':f'question-{i}','client_id':None,
                    'content':[{'type':'text','text':f'fixture sentinel {i}','text_elements':[]}]}
            self.items.append({'turnId':turn,'item':{'type':'userMessage','id':f'question-{i}',
                'clientId':None,'content':[{'type':'text','text':f'fixture sentinel {i}','text_elements':[]}]}})
            rows.extend([
                {'type':'event_msg','payload':{'type':'task_started','turn_id':turn,
                    'root_turn_id':turn,'model_context_window':258400,'collaboration_mode_kind':'default'}},
                {'type':'event_msg','payload':{'type':'item_completed','thread_id':ID,'turn_id':turn,'item':item}},
                {'type':'response_item','payload':{'type':'message','role':'user',
                    'content':[{'type':'input_text','text':f'fixture sentinel {i}'}]}},
                {'type':'event_msg','payload':{'type':'task_complete','turn_id':turn,
                    'root_turn_id':turn,'last_agent_message':None}}])
            self.cuts.append(len(rows))
        encoded = []
        for ordinal,row in enumerate(rows):
            encoded.append(json.dumps({'timestamp':'2026-10-01T00:00:00Z','ordinal':ordinal,**row})+'\n')
        path.write_text(''.join(encoded))
        self.raw_rows = encoded; self.rollout = path
        self.resume(self.home, ID)
        # Independent literal expected wire shape, not derived from Native output.
        self.assertEqual(native.expected_history(self.home)[ID],
                         {'turns':self.turn_ids,'items':self.items})

    def resume(self, home, thread):
        with native.NativeRpc(self.binary, home, []) as rpc:
            result = rpc.call('thread/resume',{'threadId':thread,'cwd':str(home),
                'excludeTurns':True,'sandbox':'read-only','approvalPolicy':'untrusted'})
            self.assertEqual(result['thread']['id'], thread)

    def restored(self):
        # Use the real archival implementation, including committed WAL backup,
        # derived-state path relocation, original disappearance and durable receipt.
        import argparse, contextlib, io, sys
        spec=importlib.util.spec_from_file_location('fixture_history',ROOT/'bin/codex-history.py')
        history=importlib.util.module_from_spec(spec);spec.loader.exec_module(history)
        catalog=self.base/'catalog';receipt=self.base/'snapshot.json'
        args=argparse.Namespace(source=str(self.home),catalog=str(catalog),receipt=str(receipt),
            source_root=str(self.home.parent.parent),isolation_id='canonical',runtime_revision='a'*40)
        with contextlib.redirect_stdout(io.StringIO()):history.snapshot(args)
        saved=json.loads(receipt.read_text());self.snapshot_id=saved['snapshot_id']
        self.retained=self.base/'retained';self.home.parent.parent.rename(self.retained)
        args=argparse.Namespace(catalog=str(catalog),snapshot=self.snapshot_id,
            source=str(self.retained/'.harness/codex'),codex_bin=self.binary)
        with contextlib.redirect_stdout(io.StringIO()):history.verify(args)
        proofs=list((catalog/'snapshots'/self.snapshot_id/'verifications').glob('*.json'))
        self.assertEqual(len(proofs),1)
        proof=json.loads(proofs[0].read_text())['proof']
        self.assertEqual(proof['native']['version'],'0.163.0')
        self.assertEqual(proof['model_requests'],0)
        self.assertEqual(proof['network'],'sandbox-denied')
        self.assertFalse(self.home.exists())
        return proof

    def test_real_0163_paginated_archive_restore_and_full_wire_history(self):
        self.make_history(101)
        proof=self.restored()
        self.assertEqual(proof['threads'][0]['turn_count'],101)
        self.assertEqual(proof['threads'][0]['item_count'],101)

    def test_real_0163_parent_cut_archived_rollout_segment_and_wal(self):
        self.make_history(2)
        child='ffffffff-1111-4222-8333-444444444444'
        ordinal=self.cuts[0]; offset=len(''.join(self.raw_rows[:ordinal]).encode())
        path=self.home/'sessions'/('rollout-2026-10-01T00-00-01-'+child+'.jsonl')
        path.write_text(json.dumps({'timestamp':'2026-10-01T00:00:00Z','ordinal':0,
            'type':'session_meta','payload':{'id':child,'timestamp':'2026-10-01T00:00:00Z',
            'cwd':str(self.home),'originator':'fixture','cli_version':'0.163.0','source':'cli',
            'model_provider':'openai','history_mode':'paginated',
            'history_base':{'thread_id':ID,'end_ordinal_exclusive':ordinal,'end_byte_offset':offset}}})+'\n')
        self.resume(self.home,child)
        self.assertEqual(native.expected_history(self.home)[child],
            {'turns':self.turn_ids[:1],'items':self.items[:1]})
        archived=self.home/'archived_sessions';archived.mkdir()
        # A preserved raw segment without a header belongs to its filename UUID.
        (archived/('rollout-2026-10-01T00-00-00-'+ID+'_0001.jsonl')).write_text(
            json.dumps({'timestamp':'2026-10-01T00:00:01Z','ordinal':10,
                        'type':'event_msg','payload':{'type':'token_count','info':None,'rate_limits':None}})+'\n')
        db=sqlite3.connect(self.home/'thread_history_1.sqlite')
        self.addCleanup(db.close)
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('CREATE TABLE fixture_wal_sentinel(value TEXT)')
        db.execute("INSERT INTO fixture_wal_sentinel VALUES ('committed WAL sentinel')")
        db.commit()
        self.assertTrue((self.home/'thread_history_1.sqlite-wal').exists())
        proof=self.restored()
        self.assertEqual(proof['raw_rollout_count'],3)
        archived_db=self.base/'catalog'/'snapshots'/self.snapshot_id/'data'/'thread_history_1.sqlite'
        with sqlite3.connect(archived_db.as_uri()+'?mode=ro',uri=True) as saved:
            self.assertEqual(saved.execute('SELECT value FROM fixture_wal_sentinel').fetchall(),
                             [('committed WAL sentinel',)])
        self.assertEqual({row['native_id']:row['item_count'] for row in proof['threads']},{ID:2,child:1})

    def test_real_0163_empty_catalog_still_preserves_native_payload(self):
        # Native startup before the first conversation creates a state catalog
        # and shell snapshots, but no rollout/projection at all.
        with native.NativeRpc(self.binary,self.home,[]) as rpc:
            self.assertEqual(rpc.call('thread/list',{'limit':100})['data'],[])
        shell=self.home/'shell_snapshots';shell.mkdir(exist_ok=True)
        (shell/'fixture.sh').write_text('export FIXTURE_SENTINEL=preserved\n')
        self.assertFalse(list((self.home/'sessions').rglob('*.jsonl')))
        self.assertEqual(native.expected_history(self.home),{})
        proof=self.restored()
        self.assertEqual(proof['threads'],[])
        self.assertTrue(proof['empty_catalog_verified'])

    def test_empty_rollouts_with_nonempty_thread_catalog_are_held(self):
        self.make_history()
        self.rollout.unlink()
        with self.assertRaises(native.NativeVerificationError):native.expected_history(self.home)

    def test_real_0163_copied_parent_metadata_does_not_change_rollout_owner(self):
        self.make_history(2)
        child='ffffffff-1111-4222-8333-444444444444'
        primary=json.loads(self.raw_rows[0]);primary['payload']['id']=child
        rows=[primary]+[json.loads(row) for row in self.raw_rows]
        for ordinal,row in enumerate(rows):row['ordinal']=ordinal
        path=self.home/'sessions'/('rollout-2026-10-01T00-00-01-'+child+'.jsonl')
        path.write_text(''.join(json.dumps(row)+'\n' for row in rows))
        self.resume(self.home,child)
        self.assertEqual(native.expected_history(self.home)[child],
            {'turns':self.turn_ids,'items':self.items})
        proof=self.restored()
        self.assertEqual({row['native_id']:row['item_count'] for row in proof['threads']},{ID:2,child:2})


if __name__ == "__main__": unittest.main()
