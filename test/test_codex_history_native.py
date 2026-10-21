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

    def test_only_exact_historical_metadata_paths_are_exempt(self):
        root=self.home.parent;path=str(root/'old.py')
        cases=[({'type':'commandExecution','commandActions':[{'type':'read','command':'cat old.py','name':'old.py','path':path}]},True),
               ({'type':'fileChange','changes':[{'path':path,'kind':{'type':'add'},'diff':'sentinel'}]},True),
               ({'type':'commandExecution','commandActions':[{'type':'unknown','path':path}]},False),
               ({'type':'fileChange','changes':[{'path':path,'extra':'unknown'}]},False),
               ({'type':'localImage','path':path},False),
               ({'type':'unknown','artifact_path':path},False)]
        for item,allowed in cases:
            with self.subTest(item=item):
                class Rpc:
                    def __init__(self,*args):pass
                    def __enter__(self):return self
                    def __exit__(self,*args):pass
                    def call(self,method,params):
                        if method=='fs/readFile':return {'dataBase64':base64.b64encode(Path(params['path']).read_bytes()).decode()}
                        if method=='thread/resume':return {'thread':{'id':ID}}
                        if method=='thread/turns/list':return {'data':[{'id':'turn'}]}
                        return {'data':[{'turnId':'turn','item':item}]}
                with patch.object(native,'expected_history',return_value={ID:{'turns':['turn'],'items':[{'turnId':'turn','item':item}]}}),patch.object(native,'binary_identity',return_value={'version':'0.163.0'}),patch.object(native,'NativeRpc',Rpc):
                    if allowed:native.verify_native(self.home,{'source':str(root/'.harness/codex')},'/fixture/codex')
                    else:
                        with self.assertRaises(native.NativeVerificationError):native.verify_native(self.home,{'source':str(root/'.harness/codex')},'/fixture/codex')

    def test_only_direct_output_blocks_inside_active_turn_supply_image_bytes(self):
        path=next((self.home/'sessions').iterdir());header=path.read_text().splitlines()[0]
        block={'type':'input_image','image_url':'data:image/png;base64,'+base64.b64encode(b'image').decode()}
        for output,closed in [([{'type':'debug','metadata':block}],False),([block],True)]:
            with self.subTest(output=output,closed=closed):
                rows=[{'type':'event_msg','payload':{'type':'task_started','turn_id':'turn'}}]
                if closed:rows.append({'type':'event_msg','payload':{'type':'task_complete','turn_id':'turn'}})
                rows.append({'type':'response_item','payload':{'type':'custom_tool_call_output','output':output}})
                path.write_text(header+'\n'+''.join(json.dumps(row)+'\n' for row in rows))
                self.assertFalse(native.inline_images(self.home).get((ID,'turn')))

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

    def test_only_characterized_subagent_refusal_uses_read_and_full_pages(self):
        calls=[]
        error={'code':-32600,'message':'cannot resume an unloaded multi-agent v2 sub-agent through its parent; resume the parent first, or use thread/read to inspect it'}
        version='0.163.0';read_id=ID;wire=ITEM
        class Rpc:
            def __init__(self,*args):self.last_error=None
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def call(self,method,params):
                calls.append(method)
                if method=='fs/readFile':return {'dataBase64':base64.b64encode(Path(params['path']).read_bytes()).decode()}
                if method=='thread/resume':
                    self.last_error=error
                    raise native.NativeVerificationError('Native rejected the full-history probe')
                if method=='thread/read':return {'thread':{'id':read_id}}
                if method=='thread/turns/list':return {'data':[{'id':'turn'}]}
                return {'data':[{'turnId':'turn','item':wire}]}
        with patch.object(native,'NativeRpc',Rpc),patch.object(native,'binary_identity',return_value={'version':'0.163.0'}):
            proof=native.verify_native(self.home,{},'/fixture/codex')
        self.assertEqual(proof['threads'][0]['item_count'],1)
        self.assertEqual(calls[-4:],['thread/resume','thread/read','thread/turns/list','thread/items/list'])
        for case in ['unknown_error','old_version','wrong_thread','changed_wire']:
            with self.subTest(case=case):
                original=error;version='0.163.0';read_id=ID;wire=ITEM
                if case=='unknown_error':error={'code':-32600,'message':'uncharacterized failure'}
                elif case=='old_version':version='0.162.1'
                elif case=='wrong_thread':read_id='ffffffff-1111-4222-8333-444444444444'
                else:wire={**ITEM,'id':'changed'}
                with patch.object(native,'NativeRpc',Rpc),patch.object(native,'binary_identity',return_value={'version':version}):
                    with self.assertRaises(native.NativeVerificationError):native.verify_native(self.home,{},'/fixture/codex')
                error=original

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


class RpcTransportTests(unittest.TestCase):
    def test_response_budget_and_split_frame_preserve_following_message(self):
        import io
        from types import SimpleNamespace
        rpc=native.NativeRpc('/fixture',Path('/tmp'),[])
        rpc.process=SimpleNamespace(stdin=io.BytesIO(),stdout=SimpleNamespace(fileno=lambda:0))
        rpc.selector=SimpleNamespace(select=lambda timeout:[True])
        payload=json.dumps({'id':1,'result':{'dataBase64':'x'*1000}}).encode()+b'\n'+b'{"id":2,"result":{"ok":true}}\n'
        chunks=iter([payload[:500],payload[500:]])
        with patch.object(native.os,'read',side_effect=lambda *args:next(chunks)):
            self.assertEqual(len(rpc.call('fs/readFile',{'path':'/fixture'},response_limit=2048)['dataBase64']),1000)
            self.assertTrue(rpc.call('thread/read',{'threadId':ID})['ok'])

    def test_per_request_budget_rejects_oversized_response(self):
        import io
        from types import SimpleNamespace
        rpc=native.NativeRpc('/fixture',Path('/tmp'),[])
        rpc.process=SimpleNamespace(stdin=io.BytesIO(),stdout=SimpleNamespace(fileno=lambda:0))
        rpc.selector=SimpleNamespace(select=lambda timeout:[True])
        with patch.object(native.os,'read',return_value=b'x'*1024):
            with self.assertRaisesRegex(native.NativeVerificationError,'response limit'):
                rpc.call('fs/readFile',{'path':'/fixture'},response_limit=128)

    def test_file_budget_uses_exact_encoded_size_and_rejects_unbounded_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'raw';path.write_bytes(b'sentinel')
            self.assertEqual(native.file_response_limit(path),4096+12)
            with patch.object(Path,'stat',return_value=type('Info',(),{'st_size':129*1024*1024})()):
                with self.assertRaises(native.NativeVerificationError):native.file_response_limit(path)


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

    def make_history(self, turns=1, extra_rows=()):
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
        rows[-1:-1]=extra_rows
        encoded = []
        for ordinal,row in enumerate(rows):
            encoded.append(json.dumps({'timestamp':'2026-10-01T00:00:00Z','ordinal':ordinal,**row})+'\n')
        path.write_text(''.join(encoded))
        self.raw_rows = encoded; self.rollout = path
        self.resume(self.home, ID)
        # Independent literal expected wire shape, not derived from Native output.
        if not extra_rows:
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

    def test_real_0163_unloaded_subagent_read_preserves_full_history(self):
        self.make_history()
        (self.home/'config.toml').write_text('[features]\nmulti_agent = true\n')
        source={'subagent':{'thread_spawn':{
            'parent_thread_id':'ffffffff-1111-4222-8333-444444444444','depth':1,
            'agent_path':'/root/fixture','agent_nickname':'Fixture','agent_role':'default'}}}
        rows=[json.loads(row) for row in self.rollout.read_text().splitlines()]
        rows[0]['payload']['source']=source
        rows[0]['payload'].update(multi_agent_version='v2',thread_source='subagent',
            parent_thread_id=source['subagent']['thread_spawn']['parent_thread_id'],
            agent_path='/root/fixture',agent_nickname='Fixture',agent_role='default')
        self.rollout.write_text(''.join(json.dumps(row)+'\n' for row in rows))
        parent=source['subagent']['thread_spawn']['parent_thread_id']
        parent_rows=json.loads(json.dumps(rows));parent_rows[0]['payload']['id']=parent
        parent_rows[0]['payload']['source']='cli'
        for key in ['multi_agent_version','thread_source','parent_thread_id','agent_path','agent_nickname','agent_role']:
            parent_rows[0]['payload'].pop(key,None)
        for row in parent_rows:
            if 'thread_id' in row.get('payload',{}):row['payload']['thread_id']=parent
        parent_path=self.rollout.parent/('rollout-2026-10-01T00-00-00-'+parent+'.jsonl')
        parent_path.write_text(''.join(json.dumps(row)+'\n' for row in parent_rows))
        with sqlite3.connect(self.home/'state_5.sqlite') as db:
            db.row_factory=sqlite3.Row
            record=dict(db.execute('SELECT * FROM threads WHERE id=?',(ID,)).fetchone())
            record.update(id=parent,rollout_path=str(parent_path))
            db.execute('INSERT INTO threads ('+','.join(record)+') VALUES ('+','.join('?' for _ in record)+')',tuple(record.values()))
            db.execute("UPDATE threads SET source=?,thread_source='subagent',agent_path='/root/fixture',agent_nickname='Fixture',agent_role='default' WHERE id=?",(json.dumps(source),ID))
            db.execute("INSERT INTO thread_spawn_edges VALUES (?,?,'open')",(parent,ID))
        db.close()
        with sqlite3.connect(self.home/'thread_history_1.sqlite') as db:
            db.row_factory=sqlite3.Row
            for table in ['thread_turns','thread_items','thread_history_projection_state']:
                for original in db.execute('SELECT * FROM '+table+' WHERE thread_id=?',(ID,)).fetchall():
                    record=dict(original);record['thread_id']=parent
                    if 'next_rollout_byte_offset' in record:record['next_rollout_byte_offset']=parent_path.stat().st_size
                    db.execute('INSERT INTO '+table+' ('+','.join(record)+') VALUES ('+','.join('?' for _ in record)+')',tuple(record.values()))
            db.execute('UPDATE thread_history_projection_state SET next_rollout_byte_offset=? WHERE thread_id=?',
                       (self.rollout.stat().st_size,ID))
        db.close()
        with native.NativeRpc(self.binary,self.home,[]) as rpc:
            with self.assertRaises(native.NativeVerificationError):
                rpc.call('thread/resume',{'threadId':ID,'cwd':str(self.home),'excludeTurns':True})
            self.assertEqual(rpc.last_error,native.SUBAGENT_READ_ERROR)
        proof=self.restored()
        self.assertEqual(proof['threads'][0]['item_count'],1)
        self.assertEqual(len(proof['threads']),2)

    def test_real_raw_read_larger_than_default_response_budget(self):
        path=self.home/'large-raw.jsonl';path.write_bytes(b'x'*(49*1024*1024))
        with native.NativeRpc(self.binary,self.home,[]) as rpc:
            result=rpc.call('fs/readFile',{'path':str(path)},response_limit=native.file_response_limit(path))
        raw=base64.b64decode(result['dataBase64'],validate=True)
        self.assertEqual(native.hashlib.sha256(raw).hexdigest(),native.file_digest(path))

    def image_history(self, inline_type='input_image'):
        # A code-mode image item has a different id from the outer tool call.
        self.image=self.home.parent.parent/'fixture.png'
        self.image_bytes=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
        self.image.write_bytes(self.image_bytes)
        turn='bbbbbbbb-cccc-4ddd-8eee-000000000000'
        self.make_history(extra_rows=[{'type':'event_msg','payload':{'type':'item_completed','thread_id':ID,
            'turn_id':turn,'started_at_ms':1790812800000,'completed_at_ms':1790812800000,
            'item':{'type':'ImageView','id':'exec-image','path':self.image.as_uri()}}},
            {'type':'response_item','payload':{'type':'custom_tool_call_output',
            'call_id':'unrelated-outer-call','output':[{'type':inline_type,'image_url':
                'data:image/png;base64,'+base64.b64encode(self.image_bytes).decode()}]}}])

    def test_real_image_bytes_and_wire_survive_original_disappearance(self):
        self.image_history()
        proof=self.restored()
        self.assertEqual(proof['work_image_count'],1)
        self.assertEqual(proof['threads'][0]['item_count'],2)
        manifest=json.loads((self.base/'catalog'/'snapshots'/self.snapshot_id/'manifest.json').read_text())
        custody=manifest['work_image_custody'][0]
        self.assertEqual(custody['item_id'],'exec-image')
        self.assertEqual((self.base/'catalog'/'snapshots'/self.snapshot_id/'data'/custody['relative_image_path']).read_bytes(),self.image_bytes)

    def test_real_parent_cut_inherits_preserved_image_without_new_owner(self):
        self.image_history()
        child='ffffffff-1111-4222-8333-444444444444'
        header=json.loads(self.raw_rows[0]);header['payload']['id']=child
        header['payload']['history_base']={'thread_id':ID,'end_ordinal_exclusive':len(self.raw_rows),
                                         'end_byte_offset':len(''.join(self.raw_rows).encode())}
        path=self.home/'sessions'/('rollout-2026-10-01T00-00-01-'+child+'.jsonl')
        path.write_text(json.dumps(header)+'\n');self.resume(self.home,child)
        self.assertEqual(native.expected_history(self.home)[child],native.expected_history(self.home)[ID])
        proof=self.restored()
        self.assertEqual(proof['work_image_count'],1)
        self.assertEqual({row['native_id']:row['item_count'] for row in proof['threads']},{ID:2,child:2})

    def test_image_without_same_turn_inline_bytes_is_held(self):
        self.image_history('input_text')
        with self.assertRaisesRegex(Exception,'image|native history probe'):self.restored()

    def test_image_custody_rejects_changed_tuple_turn_path_and_bytes(self):
        self.image_history()
        self.restored()
        archive=self.base/'catalog'/'snapshots'/self.snapshot_id
        manifest=json.loads((archive/'manifest.json').read_text());home=archive/'data'
        for key,value in [('thread_id','wrong'),('turn_id','wrong'),('item_id','wrong'),
                          ('original_path','/wrong'),('relative_image_path','../escape'),
                          ('sha256','0'*64),('bytes',0)]:
            changed=json.loads(json.dumps(manifest));changed['work_image_custody'][0][key]=value
            with self.subTest(key=key),self.assertRaises(native.NativeVerificationError):native.verify_native(home,changed,self.binary)
        image=home/manifest['work_image_custody'][0]['relative_image_path']
        image.write_bytes(b'corrupt')
        with self.assertRaises(native.NativeVerificationError):native.verify_native(home,manifest,self.binary)

    def test_work_image_symlink_is_held(self):
        self.image_history()
        target=self.base/'outside.png';target.write_bytes(self.image_bytes)
        self.image.unlink();self.image.symlink_to(target)
        with self.assertRaisesRegex(Exception,'work image'):self.restored()

    def test_native_image_readback_mismatch_is_held(self):
        self.image_history();self.restored()
        archive=self.base/'catalog'/'snapshots'/self.snapshot_id
        manifest=json.loads((archive/'manifest.json').read_text())
        original=native.NativeRpc
        class ChangedRead(original):
            def call(self,method,params):
                if method=='fs/readFile' and '/attachments/work-image-' in params.get('path',''):
                    return {'dataBase64':base64.b64encode(b'wrong native bytes').decode()}
                return super().call(method,params)
        with patch.object(native,'NativeRpc',ChangedRead),self.assertRaisesRegex(native.NativeVerificationError,'differs'):
            native.verify_native(archive/'data',manifest,self.binary)

    def test_work_image_size_bound_is_enforced(self):
        self.image_history()
        with self.image.open('wb') as stream:stream.truncate(32*1024*1024+1)
        with self.assertRaisesRegex(Exception,'bounds'):self.restored()

    def test_inline_image_in_another_turn_does_not_authorize_custody(self):
        self.image_history()
        rows=[json.loads(row) for row in self.rollout.read_text().splitlines()]
        index=next(i for i,row in enumerate(rows) if row.get('payload',{}).get('type')=='custom_tool_call_output')
        rows.insert(index,{'type':'event_msg','payload':{'type':'task_started','turn_id':'different-turn'}})
        for ordinal,row in enumerate(rows):row['ordinal']=ordinal
        self.rollout.write_text(''.join(json.dumps(row)+'\n' for row in rows))
        with self.assertRaisesRegex(Exception,'same-turn'):self.restored()

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
