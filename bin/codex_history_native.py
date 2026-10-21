"""Offline Native full-history proof. Never sends a model turn or tool response."""
import hashlib
import base64
import json
import os
import platform
from pathlib import Path
import re
import selectors
import sqlite3
import stat
import subprocess
import tempfile
import time

UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
CHARACTERIZED_VERSIONS = {b"0.161.0", b"0.162.1", b"0.163.0"}
RPC_RESPONSE_LIMIT = 64 * 1024 * 1024
RAW_FILE_LIMIT = 128 * 1024 * 1024
MAX_FILE_RESPONSE = 4 * ((RAW_FILE_LIMIT + 2) // 3) + 4096
SUBAGENT_READ_ERROR = {'code': -32600, 'message':
    'cannot resume an unloaded multi-agent v2 sub-agent through its parent; resume the parent first, or use thread/read to inspect it'}


class NativeVerificationError(Exception):
    pass


def fail(message):
    raise NativeVerificationError(message)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def retiring_path(value, root):
    return isinstance(value,str) and (value.removeprefix('file://')==str(root) or
        value.removeprefix('file://').startswith(str(root)+'/'))


def inline_images(home):
    """Typed inline image bytes, attributed to the physical rollout and turn."""
    result={}
    def images(value):
        if not isinstance(value,list):return
        for block in value:
            if not isinstance(block,dict) or block.get('type')!='input_image' or not set(block)<={'type','image_url','detail'}:continue
            url=block.get('image_url','')
            if isinstance(url,str) and re.fullmatch(r'data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+',url):
                try:yield hashlib.sha256(base64.b64decode(url.split(',',1)[1],validate=True)).hexdigest()
                except ValueError:fail('invalid inline image bytes')
    for directory in ('sessions','archived_sessions'):
        for path in sorted((Path(home)/directory).rglob('*.jsonl')):
            thread=None;turn=None
            with path.open() as stream:
                for line in stream:
                    if not line.strip():continue
                    row=json.loads(line);payload=row.get('payload',{})
                    if row.get('type')=='session_meta' and thread is None:thread=payload.get('id','').lower()
                    if row.get('type')=='event_msg' and payload.get('type')=='task_started':turn=payload.get('turn_id')
                    if row.get('type')=='event_msg' and payload.get('type') in ('task_complete','task_aborted','turn_aborted'):turn=None
                    if thread and turn and row.get('type')=='response_item' and payload.get('type') in ('custom_tool_call_output','function_call_output'):
                        result.setdefault((thread,turn),set()).update(images(payload.get('output')))
    return result


def history_ancestors(home):
    # expected_history has already validated all primary headers and parent cuts.
    parents={}
    for directory in ('sessions','archived_sessions'):
        for path in sorted((Path(home)/directory).rglob('*.jsonl')):
            with path.open() as stream:
                for line in stream:
                    if not line.strip():continue
                    row=json.loads(line)
                    if row.get('type')=='session_meta':
                        meta=row['payload'];parent=(meta.get('history_base') or {}).get('thread_id')
                        if parent:parents[meta['id'].lower()]=parent.lower()
                        break
    result={}
    for thread in parents:
        seen=set();current=thread
        while current in parents:
            current=parents[current]
            if current in seen:fail('cyclic image lineage')
            seen.add(current)
        result[thread]=seen
    return result


def image_references(home, root):
    database=Path(home)/'thread_history_1.sqlite'
    if not database.exists():return []
    if database.is_symlink():fail('unsafe image projection')
    connection=sqlite3.connect(database.as_uri()+'?mode=ro',uri=True)
    try:
        if not connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='thread_items'").fetchone():return []
        references=[]
        for thread,turn,value in connection.execute('SELECT thread_id,turn_id,item_json FROM thread_items ORDER BY thread_id,turn_id,item_id'):
            item=json.loads(value)
            if item.get('type')=='imageView' and retiring_path(item.get('path'),root):
                if set(item)!={'type','id','path'} or not isinstance(item['id'],str):fail('unsupported image item')
                references.append({'thread_id':thread,'turn_id':turn,'item_id':item['id'],'original_path':item['path']})
        return references
    except sqlite3.Error as error:raise NativeVerificationError('unsupported image projection') from error
    finally:connection.close()


def read_work_image(root, value):
    """Anchor all components to the retiring owner, rejecting links and races."""
    relative=Path(value.removeprefix('file://')).relative_to(root)
    if not relative.parts or any(part in ('.','..') for part in relative.parts):fail('unsafe work image path')
    descriptors=[]
    try:
        fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);descriptors.append(fd)
        for part in relative.parts[:-1]:
            fd=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd);descriptors.append(fd)
        image=os.open(relative.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=fd);descriptors.append(image)
        before=os.fstat(image)
        if not stat.S_ISREG(before.st_mode) or before.st_size>32*1024*1024:fail('work image exceeds supported bounds')
        chunks=[];size=0
        while True:
            chunk=os.read(image,1024*1024)
            if not chunk:break
            size+=len(chunk)
            if size>32*1024*1024:fail('work image exceeds supported bounds')
            chunks.append(chunk)
        after=os.fstat(image)
        if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns) or size!=before.st_size:
            fail('work image changed during preservation')
        return b''.join(chunks)
    except (OSError,ValueError) as error:raise NativeVerificationError('unsafe work image') from error
    finally:
        for fd in reversed(descriptors):os.close(fd)


def preserve_work_images(data, source):
    root=Path(source).parent.parent
    references=image_references(data,root)
    if not references:return []
    inline=inline_images(data);result=[]
    for reference in references:
        contents=read_work_image(root,reference['original_path']);checksum=hashlib.sha256(contents).hexdigest()
        if checksum not in inline.get((reference['thread_id'],reference['turn_id']),set()):
            fail('work image lacks same-turn inline bytes')
        relative='attachments/work-image-'+checksum+'.png';path=Path(data)/relative
        path.parent.mkdir(mode=0o700,exist_ok=True)
        if path.exists():
            if path.is_symlink() or path.read_bytes()!=contents:fail('conflicting work image attachment')
        else:
            fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'wb') as stream:stream.write(contents);stream.flush();os.fsync(stream.fileno())
        if path.read_bytes()!=contents:fail('work image readback differs')
        result.append({**reference,'relative_image_path':relative,'bytes':len(contents),'sha256':checksum})
    return result


def expected_history(home):
    """Read the preserved projection before Native can migrate derived copies."""
    home = Path(home)
    headers = {}; content = {}; parents = {}; owners = set(); primary_paths={}; embedded=[]
    for directory in ("sessions", "archived_sessions"):
        for path in sorted((home / directory).rglob("*.jsonl")):
            if path.is_symlink(): fail("unsafe Native rollout")
            thread = None; primary_seen = False
            # Segments without a header belong to the UUID encoded in their name.
            matches = re.findall(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", path.name)
            if matches: thread = matches[-1].lower()
            filename_thread = thread
            with path.open(encoding="utf-8") as stream:
                for line in stream:
                    if not line.strip(): continue
                    row = json.loads(line)
                    if row.get("type") == "session_meta":
                        meta = row.get("payload", {}); metadata_thread = str(meta.get("id", "")).lower()
                        if not UUID.fullmatch(metadata_thread): fail("invalid Native thread metadata")
                        if primary_seen:
                            # 0.163 fork copies include their parent's metadata
                            # in the raw history. Native keeps the file's first
                            # header as owner; every embedded header must also
                            # have its identical standalone original preserved.
                            ordinal=row.get('ordinal')
                            if type(ordinal) is not int or ordinal<1:fail('unsupported embedded Native metadata')
                            embedded.append(meta);continue
                        primary_seen=True;thread=metadata_thread
                        if filename_thread and filename_thread != thread: fail("Native filename and metadata disagree")
                        previous = headers.get(thread)
                        if previous and previous != meta: fail("conflicting Native thread metadata")
                        headers[thread] = meta
                        primary_paths[thread]=path
                        parent = (meta.get("history_base") or {}).get("thread_id")
                        if parent: parents[thread] = parent.lower()
                    if thread and row.get("type") == "response_item": content[thread] = True
                    if row.get('type') != 'session_meta':
                        if not thread: fail('Native rollout has no attributable UUID')
                        owners.add(thread)
    if not headers:
        # A Native process can exit before its first conversation. Only an
        # actually empty known catalog is admissible; lost rollouts are not.
        if any(path.is_file() for directory in ('sessions','archived_sessions')
               for path in (home/directory).rglob('*.jsonl')):
            fail("Native history has no readable thread metadata")
        state=home/'state_5.sqlite'
        if not state.is_file() or state.is_symlink():fail('empty Native catalog is unverified')
        try:
            for path,tables in ((state,('threads',)),(home/'thread_history_1.sqlite',('thread_turns','thread_items'))):
                if not path.exists():continue
                if path.is_symlink():fail('unsafe empty Native catalog')
                connection=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True)
                try:
                    known={row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                    extra=('thread_history_projection_state','rollout_migration_skipped_rollouts')
                    for table in (*tables,*(name for name in extra if name in known)):
                        if connection.execute('SELECT 1 FROM '+table+' LIMIT 1').fetchone():
                            fail('Native catalog has no preserved rollouts')
                finally:connection.close()
            for name in ('history.jsonl','session_index.jsonl'):
                if (home/name).exists() and (home/name).stat().st_size:
                    fail('Native history list has no preserved rollouts')
        except sqlite3.Error as error:
            raise NativeVerificationError('empty Native catalog schema is unsupported') from error
        return {}
    if any(headers.get(str(meta.get('id','')).lower())!=meta for meta in embedded):
        fail('embedded Native metadata has no identical preserved primary')
    if not owners <= set(headers): fail('Native rollout segment has no preserved thread metadata')
    if any(parent not in headers for parent in parents.values()): fail("Native parent history is missing")
    for thread in parents:
        seen = set(); current = thread
        while current in parents:
            if current in seen: fail("cyclic Native parent history")
            seen.add(current); current = parents[current]
    # Older rollout-only readers need independent characterization. Fail closed.
    if any(meta.get("history_mode") != "paginated" for meta in headers.values()):
        fail("Native history format is not characterized")
    database = home / "thread_history_1.sqlite"
    if not database.is_file() or database.is_symlink(): fail("Native history projection is missing")
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
    try:
        tables={row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if 'thread_history_projection_state' in tables:
            for thread,offset in connection.execute('SELECT thread_id,next_rollout_byte_offset FROM thread_history_projection_state'):
                if thread not in primary_paths or offset<0 or offset>primary_paths[thread].stat().st_size:
                    fail('Native projection cursor is outside preserved rollout')
        stored={}
        for thread in sorted(headers):
            turns = list(connection.execute(
                "SELECT turn_id,rollout_ordinal FROM thread_turns WHERE thread_id=? ORDER BY rollout_ordinal,turn_id", (thread,)))
            items = list(connection.execute(
                "SELECT turn_id,item_json,rollout_ordinal FROM thread_items WHERE thread_id=? ORDER BY rollout_ordinal,item_id", (thread,)))
            stored[thread]={'turns':turns,'items':items}
        projected=set(row[0] for row in connection.execute('SELECT DISTINCT thread_id FROM thread_items UNION SELECT DISTINCT thread_id FROM thread_turns'))
        if not projected<=set(headers):fail('Native projection has no preserved rollout metadata')
        def projection(thread,cut=None):
            inherited={'turns':[],'items':[]}
            if thread in parents:
                base=headers[thread]['history_base'];parent=parents[thread]
                ordinal=base.get('end_ordinal_exclusive');offset=base.get('end_byte_offset')
                if not isinstance(ordinal,int) or ordinal<0 or not isinstance(offset,int) or offset<0:
                    fail('Native parent cut is not characterized')
                path=primary_paths[parent];boundaries={0:0};position=0
                with path.open('rb') as stream:
                    for line in stream:
                        position+=len(line);row=json.loads(line);index=row.get('ordinal')
                        if not isinstance(index,int):fail('Native parent ordinal layout is unsupported')
                        boundaries[position]=index+1
                if boundaries.get(offset)!=ordinal:fail('Native parent cut is outside preserved history')
                inherited=projection(parent,ordinal)
            own=stored[thread]
            return {key:inherited[key]+[row for row in own[key] if cut is None or row[-1]<cut] for key in ('turns','items')}
        result={}
        for thread in sorted(headers):
            rows=projection(thread)
            turns=[row[0] for row in rows['turns']]
            items=[{'turnId':row[0],'item':json.loads(row[1])} for row in rows['items']]
            if content.get(thread) and (not turns or not items): fail("Native projection omits transcript content")
            if any(row["turnId"] not in turns for row in items): fail("Native item has no preserved turn")
            result[thread] = {"turns": turns, "items": items}
        return result
    except (sqlite3.Error, json.JSONDecodeError) as error:
        raise NativeVerificationError("Native projection is unsupported or invalid") from error
    finally:
        connection.close()


def sandbox_command(binary, arguments, denied=(), home=None):
    sandbox = Path("/usr/bin/sandbox-exec")
    if not sandbox.is_file(): fail("offline Native sandbox is unavailable")
    profile = '(version 1)(allow default)(deny network*)'
    profile += '(deny file-write*)'
    if home:profile += '(allow file-write* (subpath '+json.dumps(str(Path(home).resolve()))+'))'
    profile += '(allow file-write-data (literal "/dev/null"))'
    # No other catalog or Native home can supply missing restored artifacts.
    profile += '(deny file-read-data)'
    readable=['/System','/usr','/dev','/private/etc']
    if home: readable.append(str(Path(home).resolve()))
    for path in readable:
        profile += '(allow file-read-data (subpath '+json.dumps(path)+'))'
    profile += '(allow file-read-data (literal '+json.dumps(str(Path(binary).resolve()))+'))'
    # dyld also reads ancestor directories. Allow listing those exact dirs,
    # without admitting any sibling transcript or catalog file contents.
    ancestors=set(Path(binary).resolve().parents)
    if home:ancestors.update(Path(home).resolve().parents)
    for path in sorted(ancestors,key=str):
        profile += '(allow file-read-data (literal '+json.dumps(str(path))+'))'
    for path in denied:
        profile += '(deny file-read* (subpath ' + json.dumps(str(Path(path).absolute())) + '))'
    return [str(sandbox), "-p", profile, str(binary), *arguments]


def private_env(home):
    # Credentials, proxies, selected config and parent-process model settings are
    # deliberately absent. Node-backed distributions still need a system PATH.
    return {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": str(home),
            "CODEX_HOME": str(home), "LANG": "en_US.UTF-8"}


def file_digest(path):
    checksum=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024),b''):checksum.update(chunk)
    return checksum.hexdigest()


def binary_identity(binary):
    wrapper = Path(binary).resolve(strict=True);path=wrapper
    if wrapper.name=='codex.js' and wrapper.parent.name=='bin' and wrapper.parent.parent.name=='codex':
        target={'arm64':'aarch64-apple-darwin','x86_64':'x86_64-apple-darwin'}.get(platform.machine())
        package={'arm64':'codex-darwin-arm64','x86_64':'codex-darwin-x64'}.get(platform.machine())
        if not target:fail('Native package architecture is not characterized')
        root=wrapper.parent.parent
        candidates=[root/'node_modules/@openai'/package/'vendor'/target/'bin/codex',
                    root.parent/package/'vendor'/target/'bin/codex',root/'vendor'/target/'bin/codex']
        found=[p.resolve() for p in candidates if p.is_file()]
        if len(set(found))!=1:fail('Native package backend is missing or ambiguous')
        path=found[0]
    if not path.is_file() or not os.access(path, os.X_OK): fail("Native executable unavailable")
    with tempfile.TemporaryDirectory(prefix="native-version-") as temp:
        process = subprocess.run(sandbox_command(path, ["--version"],home=temp), env=private_env(temp),
                                 capture_output=True, timeout=10, check=False)
    version = re.search(rb"codex-cli (\d+\.\d+\.\d+)", process.stdout)
    if process.returncode or not version: fail("Native version unavailable")
    # The paginated wire protocol was verified against these versions; future
    # versions require characterization rather than implied compatibility.
    if version.group(1) not in CHARACTERIZED_VERSIONS: fail("Native version lacks characterized history verification")
    return {"version": version.group(1).decode(), "sha256": file_digest(path),
            'executable':str(path),'wrapper':str(wrapper),'wrapper_sha256':file_digest(wrapper)}


def file_response_limit(path):
    size=Path(path).stat().st_size
    if size < 0 or size > RAW_FILE_LIMIT:fail('Native raw file exceeds verification limit')
    return 4 * ((size + 2) // 3) + 4096


class NativeRpc:
    def __init__(self, binary, home, denied):
        self.binary = binary; self.home = Path(home); self.denied = denied
        self.buffer = bytearray(); self.sequence = 0; self.process = None
        self.last_error = None

    def __enter__(self):
        self.process = subprocess.Popen(sandbox_command(self.binary, ["app-server", "--listen", "stdio://"], self.denied,home=self.home),
            env=private_env(self.home), cwd=self.home, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0)
        self.selector = selectors.DefaultSelector(); self.selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            self.call("initialize", {"clientInfo": {"name": "harness_history_verifier", "version": "1"},
                                     "capabilities": {"experimentalApi": True}})
            self.send({"method": "initialized", "params": {}})
        except Exception:
            self.__exit__(None, None, None); raise
        return self

    def __exit__(self, *unused):
        if self.process is not None:
            self.process.terminate()
            try: self.process.wait(timeout=3)
            except subprocess.TimeoutExpired: self.process.kill(); self.process.wait(timeout=3)
            self.process.stdin.close(); self.process.stdout.close(); self.selector.close()

    def send(self, value):
        self.process.stdin.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
        self.process.stdin.flush()

    def call(self, method, params, *, response_limit=RPC_RESPONSE_LIMIT):
        if (type(response_limit) is not int or response_limit <= 0 or response_limit > MAX_FILE_RESPONSE
                or (response_limit != RPC_RESPONSE_LIMIT and method != 'fs/readFile')):
            fail('invalid Native response limit')
        self.last_error = None
        self.sequence += 1; request = self.sequence
        self.send({"id": request, "method": method, "params": params})
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            newline = self.buffer.find(b'\n')
            scanned = len(self.buffer)
            while newline < 0:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not self.selector.select(remaining): fail("Native history RPC timed out")
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk: fail("Native history RPC closed unexpectedly")
                self.buffer.extend(chunk)
                newline = self.buffer.find(b'\n', scanned)
                scanned = len(self.buffer)
                if (newline if newline >= 0 else len(self.buffer)) > response_limit:
                    fail("Native history RPC exceeded response limit")
            if newline > response_limit:fail("Native history RPC exceeded response limit")
            line = bytes(self.buffer[:newline]); del self.buffer[:newline+1]
            try: response = json.loads(line)
            except json.JSONDecodeError: fail("Native history RPC returned invalid JSON")
            if "method" in response and "id" in response:
                fail("Native history probe requested tool execution or approval")
            if response.get("id") != request: continue
            if "error" in response:
                self.last_error=response['error']
                fail("Native rejected the full-history probe")
            result = response.get("result")
            if not isinstance(result, dict): fail("Native history RPC result is invalid")
            return result
        fail("Native history RPC timed out")


def pages(rpc, method, thread):
    rows = []; cursor = None; seen = set()
    for unused in range(10000):
        params = {"threadId": thread, "limit": 100, "sortDirection": "asc"}
        if cursor: params["cursor"] = cursor
        result = rpc.call(method, params)
        if not isinstance(result.get("data"), list): fail("Native history page is invalid")
        rows.extend(result["data"]); cursor = result.get("nextCursor")
        if not cursor: return rows
        if cursor in seen: fail("Native history cursor repeated")
        seen.add(cursor)
    fail("Native history page limit exceeded")


def verify_native(restored_home, manifest, codex_bin):
    expected = expected_history(restored_home)
    identity = binary_identity(codex_bin)
    executable=identity.get('executable',str(Path(codex_bin).resolve()))
    custody=manifest.get('work_image_custody',[]);image_files=[]
    if manifest.get('source'):
        original=Path(manifest['source']);ephemeral=str(original.parent.parent)
        references=image_references(restored_home,ephemeral);inline=inline_images(restored_home)
        ancestors=history_ancestors(restored_home)
        if not isinstance(custody,list) or len(custody)!=len(references):fail('work image custody is incomplete')
        for reference,entry in zip(references,custody):
            keys={'thread_id','turn_id','item_id','original_path','relative_image_path','bytes','sha256'}
            if not isinstance(entry,dict) or set(entry)!=keys or any(entry.get(key)!=value for key,value in reference.items()):fail('work image custody tuple differs')
            checksum=entry['sha256']
            if not isinstance(checksum,str) or not re.fullmatch('[0-9a-f]{64}',checksum):fail('invalid work image checksum')
            relative='attachments/work-image-'+checksum+'.png'
            if entry['relative_image_path']!=relative or checksum not in inline.get((entry['thread_id'],entry['turn_id']),set()):fail('work image lacks same-turn inline bytes')
            path=Path(restored_home)/relative
            if path.parent.is_symlink() or path.is_symlink() or not path.is_file():fail('restored work image is unavailable')
            if path.stat().st_size!=entry['bytes'] or file_digest(path)!=checksum:fail('restored work image differs')
            image_files.append((path,checksum))
        def check_paths(value):
            if isinstance(value,dict):
                for key,item in value.items():
                    if key in ('path','image_path','file_path','local_path','artifact_path','image_url') and isinstance(item,str):
                        path=item.removeprefix('file://')
                        if retiring_path(path,ephemeral):
                            fail('Native attachment refers to the retiring workspace')
                    check_paths(item)
            elif isinstance(value,list):
                for item in value:check_paths(item)
        for thread,projection in expected.items():
            for row in projection['items']:
                # Only characterized historical metadata fields are exempt.
                item=json.loads(json.dumps(row['item']))
                if item.get('type')=='commandExecution':
                    for action in item.get('commandActions',[]):
                        if isinstance(action,dict) and set(action)=={'type','command','name','path'} and action.get('type')=='read':action.pop('path',None)
                elif item.get('type')=='fileChange':
                    for change in item.get('changes',[]):
                        if isinstance(change,dict) and set(change)=={'path','kind','diff'} and isinstance(change['kind'],dict):change.pop('path',None)
                elif item.get('type')=='imageView':
                    if any((entry['thread_id']==thread or entry['thread_id'] in ancestors.get(thread,set()))
                           and entry['turn_id']==row['turnId'] and entry['item_id']==item.get('id')
                           and entry['original_path']==item.get('path')
                           and row in expected[entry['thread_id']]['items'] for entry in custody):item.pop('path',None)
                check_paths(item)
    elif custody:fail('work image custody has no owner')
    denied = [manifest[key] for key in ("source", "retained_source") if manifest.get(key)]
    receipts = []; files = []
    # Native itself reads every raw JSONL byte, including segments and parents.
    # The wire projection and the model-visible rollout are separate artifacts.
    for directory in ('sessions','archived_sessions'):
        for path in sorted((Path(restored_home)/directory).rglob('*.jsonl')):
            files.append((path,hashlib.sha256(path.read_bytes()).hexdigest()))
    with NativeRpc(executable, restored_home, denied) as rpc:
        if not expected:
            for archived in (False,True):
                result=rpc.call('thread/list',{'limit':100,'archived':archived})
                if result.get('data')!=[] or result.get('nextCursor'):
                    fail('restored Native catalog is not empty')
        for path,checksum in [*files,*image_files]:
            limit=file_response_limit(path)
            if limit > RPC_RESPONSE_LIMIT:
                result=rpc.call('fs/readFile',{'path':str(path)},response_limit=limit)
            else:result=rpc.call('fs/readFile',{'path':str(path)})
            try: contents=base64.b64decode(result['dataBase64'],validate=True)
            except (KeyError,ValueError,TypeError): fail('Native raw history read is invalid')
            if hashlib.sha256(contents).hexdigest()!=checksum: fail('Native raw history differs from restored archive')
        for thread, projection in expected.items():
            try:
                result = rpc.call("thread/resume", {"threadId": thread, "cwd": str(restored_home),
                                  "excludeTurns": True, "sandbox": "read-only", "approvalPolicy": "untrusted"})
            except NativeVerificationError:
                if identity['version'] != '0.163.0' or getattr(rpc,'last_error',None) != SUBAGENT_READ_ERROR:raise
                result=rpc.call('thread/read',{'threadId':thread,'includeTurns':False})
            if result.get("thread", {}).get("id") != thread: fail("Native resumed a different thread")
            turns = pages(rpc, "thread/turns/list", thread)
            items = pages(rpc, "thread/items/list", thread)
            turn_ids = [row.get("id") for row in turns]
            actual = [{"turnId": row.get("turnId"), "item": row.get("item")} for row in items]
            if turn_ids != projection["turns"] or actual != projection["items"]:
                fail("Native full history differs from preserved projection")
            receipts.append({"native_id": thread, "turn_count": len(turns), "item_count": len(items),
                             "history_sha256": digest(actual)})
    if identity.get('executable') and binary_identity(codex_bin)!=identity:
        fail('Native executable changed during verification')
    return {"schema_version": 1, "native": identity, "threads": receipts,
            'work_image_count':len(custody),
            'raw_rollout_count':len(files), 'empty_catalog_verified':not bool(expected),
            "model_requests": 0, "network": "sandbox-denied"}
