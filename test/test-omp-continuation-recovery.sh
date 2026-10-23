#!/usr/bin/env bash
# Upstream-OMP continuation recovery: drift-tolerant origin, any-state resume
# admission, herdr's bare resume argv and live-handle refusal. Fake native only.
# Kept apart from test-omp-continuation.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_TEST_OMP_SOURCE="$(python3 -I -S -B "$ROOT/test/omp-fixture-source.py")"
export HARNESS_TEST_OMP_SOURCE
python3 -I -S -B - "$ROOT" <<'PYTEST'
import copy, hashlib, importlib.util, json, os, shutil, signal, subprocess, sys, tempfile, time, unittest
from pathlib import Path
from unittest.mock import patch

REPO = Path(sys.argv.pop(1))
KERNEL = Path(os.environ['HARNESS_TEST_OMP_SOURCE'])
W = '12345678-1234-4234-8234-123456789ABC'
H = W.replace('-', '').lower()
NATIVE_ID = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def encoded(v): return json.dumps(v, sort_keys=True, separators=(',', ':')).encode()
def put(p, v, mode=0o600):
    if p.exists(): p.chmod(0o600)
    p.write_bytes(encoded(v)); p.chmod(mode)

class Recovery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='omp-recovery-')
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.unseal)
        self.base = Path(self.tmp.name).resolve()
        self.home = self.base/'home'; self.home.mkdir(mode=0o700)
        env = patch.dict(os.environ, {'HOME': str(self.home)}); env.start(); self.addCleanup(env.stop)
        self.registry = self.home/'.config/harness-launcher/profiles'; self.registry.mkdir(parents=True, mode=0o700)
        self.profile = self.base/'registered project'; (self.profile/'config').mkdir(parents=True)
        (self.profile/'config/launcher.env').write_text('HARNESS_NAME=fixture\nHARNESS_PREFIX=ex\nHARNESS_SESSION_ISOLATION_DEFAULT=0\n')
        (self.registry/'ex').write_text(str(self.profile)+'\n'); (self.registry/'ex').chmod(0o600)
        self.calls = self.base/'native-calls'; self.ready = self.base/'native-ready'; self.release_file = self.base/'native-release'
        self.binary = self.base/'fake-native'
        self.binary.write_text('#!'+sys.executable+' -I\n'+'''
import json,os,sys,time
from pathlib import Path
args=sys.argv[1:];sessions=Path(args[args.index('--session-dir')+1])
target=sessions/('fixture_'+NATIVE_ID+'.jsonl')
if '--resume' in args:
    assert args[args.index('--resume')+1]==str(target)
    with target.open('ab') as f:f.write(b'APPENDED\\n')
else:
    header={'type':'session','version':3,'id':NATIVE_ID,'cwd':os.getcwd(),'timestamp':'2026-01-01T00:00:00.000Z'}
    fd=os.open(target,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    with os.fdopen(fd,'w') as f:f.write('title\\n'+json.dumps(header)+'\\n')
with Path(CALLS).open('a') as f:f.write(json.dumps({'argv':args,'cwd':os.getcwd(),'pid':os.getpid()})+'\\n')
if args[-1:]==['wait']:
    Path(READY).touch()
    while not Path(RELEASE).exists():time.sleep(0.02)
raise SystemExit(int(args[-1]) if args[-1:] and args[-1].isdigit() else 0)
'''.replace('NATIVE_ID', repr(NATIVE_ID)).replace('CALLS', repr(str(self.calls)))
   .replace('READY', repr(str(self.ready))).replace('RELEASE', repr(str(self.release_file))))
        self.binary.chmod(0o555)
        self.ns = self.base/'namespace'; self.ns.mkdir(mode=0o700)
        for leaf in ('home','agent','history','cwd','tmp','cache','config','state','data','native-cache'):
            (self.ns/leaf).mkdir(mode=0o700)
        put(self.ns/'.owner.json', {'schema':'p0-normal-omp-owner-v1','prefix':str(self.ns),
            'binary':str(self.binary),'asset_sha256':digest(self.binary),'identity':{'owner':'fixture'}})
        self.runtime = self.home/'.local/state/kilhyeonjun-harness/launcher-runtimes'
        self.snapshot = self.install_snapshot('a'*40)
        self.consumer = self.snapshot/'bin/aliases.zsh'
        spec = importlib.util.spec_from_file_location('projection', REPO/'bin/harness_omp_projection.py')
        self.projection = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.projection)
        self.provenance = {'binding_sha256':'1'*64,'review_sha256':'2'*64,'selection_sha256':'3'*64,
            'operation_sha256':'4'*64,'controller':{'native':'fixture','pane':'fixture','managed':'fixture'},
            'scope':'OMP3_CONFIGURATION','ssot':None}
        self.publisher = self.projection.Publisher(); self.publisher.prepare(self.provenance)
        # Upstream release shape: version + source revision only.
        self.release = {'version':'18.11.3','source_revision':'96894a6147d8cc64b7e00ad3a7d7178fd93b9531'}
        self.publish()
        spec = importlib.util.spec_from_file_location('continuation', self.snapshot/'bin/harness_omp_continuation.py')
        self.m = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.m)
        self.state = self.runtime/'session-state'; self.record_dir = self.state/'sessions'/W
        self.record_dir.mkdir(parents=True, mode=0o700)
        self.work = self.state/'worktrees'/W; self.work.mkdir(parents=True, mode=0o700)
        for name, value in [('source-root', str(self.profile)+'\n'), ('session-root', str(self.work)+'\n'),
                            ('lease-v1', '1\n'), ('runtime.lock', '')]:
            (self.record_dir/name).write_text(value); (self.record_dir/name).chmod(0o600)
        (self.runtime/'bindings').mkdir(mode=0o700); (self.runtime/'binding-locks').mkdir(mode=0o700)
        put(self.runtime/'bindings'/(W.lower()+'.json'), {'source_root':str(self.profile),
            'runtime':json.loads((self.runtime/'current.json').read_bytes())})
        row = self.m.initial_record(str(self.state), str(self.profile), W, str(self.consumer))
        self.record = self.record_dir/'omp-continuation.json'; put(self.record, row)
        self.slot = self.ns/'launcher-continuations'/H; self.sessions = self.slot/'sessions'

    def unseal(self):
        for p in [self.base, *self.base.rglob('*')]:
            if p.is_dir() and not p.is_symlink(): p.chmod(0o700)

    def install_snapshot(self, revision):
        snapshot = self.runtime/revision; (snapshot/'bin').mkdir(parents=True)
        for p in (REPO/'bin').iterdir():
            if p.is_file():
                target = snapshot/'bin'/p.name; shutil.copyfile(p, target)
                target.chmod(0o500 if p.stat().st_mode & 0o111 else 0o400)
        files = {str(p.relative_to(snapshot)):{'mode':p.stat().st_mode & 0o777,'sha256':digest(p)}
                 for p in (snapshot/'bin').iterdir()}
        put(snapshot/'manifest.json', {'version':'0.77.0','revision':revision,'files':files}, 0o400)
        put(self.runtime/'current.json', {'version':'0.77.0','revision':revision,'path':str(snapshot),
            'manifest_sha256':digest(snapshot/'manifest.json')})
        self.runtime.chmod(0o700)
        return snapshot

    def publish(self):
        row = self.projection.capture_row('ex', str(self.profile), str(self.consumer), str(self.binary),
            str(self.ns), '2099-01-01T00:00:00Z', self.release, self.provenance)
        self.publisher.publish('ex', row, self.publisher.token())

    def payload(self, mode, terminal=None):
        row = json.loads(self.record.read_bytes())
        return {'schema':'omp-continuation-operation/v1','mode':mode,'state_root':str(self.state),
            'source_root':str(self.profile),'launcher_session_id':W,'consumer':str(self.consumer),
            'handle':H,'expected_sha256':digest(self.record),'lifecycle_nonce':row['lifecycle_nonce'],
            'terminal_status':terminal}

    def op(self, mode, terminal=None):
        return self.m.operate(self.payload(mode, terminal))

    def native_file(self, name=None, body=b''):
        header = {'type':'session','version':3,'id':NATIVE_ID,'cwd':str(self.work),'timestamp':'2026-01-01T00:00:00.000Z'}
        path = self.sessions/(name or ('fixture_'+NATIVE_ID+'.jsonl'))
        path.write_bytes(b'private title\n'+encoded(header)+b'\n'+body); path.chmod(0o600)
        return path

    def row(self): return json.loads(self.record.read_bytes())

    def edit_origin(self, change):
        row = self.row(); change(row['kernel_origin']); put(self.record, row)

    def load(self):
        return self.m.load_record(str(self.state), str(self.profile), H, str(self.consumer))

    def refused(self, call, label=None):
        with self.assertRaises(self.m.ContinuationError) as caught: call()
        if label: self.assertEqual(caught.exception.label, label)

    # --- B.2 origin volatility -------------------------------------------------
    def test_volatile_origin_provenance_is_ignored(self):
        def drift(origin):
            for key in ('runtime_pin_revision',):
                origin[key] = 'f'*40
            for key in ('runtime_manifest_sha256','binary_sha256','namespace_marker_sha256','original_binding_sha256'):
                origin[key] = 'f'*64
            for key in ('size','mtime_ns','ctime_ns'):
                origin['runtime_lock_identity'][key] += 7
        self.edit_origin(drift)
        self.load()
        self.op('NEW_PREPARE')

    def test_stable_origin_keys_stay_exact(self):
        good = self.record.read_bytes()
        for change in (lambda o: o['workspace_identity'].update(ino=o['workspace_identity']['ino']+1),
                       lambda o: o['runtime_lock_identity'].update(ino=o['runtime_lock_identity']['ino']+1),
                       lambda o: o['runtime_lock_identity'].update(mode=0o644),
                       lambda o: o.update(source_root_marker_sha256='f'*64),
                       lambda o: o.update(session_root_marker_sha256='f'*64),
                       lambda o: o.update(profile_binding_sha256='f'*64),
                       lambda o: o.update(host_binding_sha256='f'*64),
                       lambda o: o['namespace_identity'].update(ino=o['namespace_identity']['ino']+1)):
            with self.subTest(change=change):
                self.edit_origin(change); self.refused(self.load, 'OMP_CONTINUATION_IDENTITY_CHANGED')
                self.record.write_bytes(good)

    def test_new_launcher_release_and_binary_keep_the_handle(self):
        self.op('NEW_PREPARE'); self.native_file(); self.op('FINALIZE', 0)
        # A new launcher snapshot (new revision/manifest) and a new upstream binary.
        self.snapshot = self.install_snapshot('c'*40); self.consumer = self.snapshot/'bin/aliases.zsh'
        self.binary.chmod(0o755); self.binary.write_text(self.binary.read_text()+'\n# upgraded\n'); self.binary.chmod(0o555)
        owner = json.loads((self.ns/'.owner.json').read_bytes()); owner['asset_sha256'] = digest(self.binary)
        put(self.ns/'.owner.json', owner)
        self.publish()
        self.assertEqual(self.op('RESUME_ADMIT')['status'], 'IN_FLIGHT')

    def test_binding_requires_source_and_runtime_under_launcher_runtimes(self):
        bound = self.runtime/'bindings'/(W.lower()+'.json'); good = json.loads(bound.read_bytes())
        for change in (lambda b: b.update(source_root=str(self.base/'other')),
                       lambda b: b['runtime'].update(path=str(self.base/'elsewhere'/('a'*40))),
                       lambda b: b['runtime'].update(path=str(self.runtime))):
            value = copy.deepcopy(good); change(value); put(bound, value)
            with self.subTest(value=value): self.refused(self.load)
        value = copy.deepcopy(good); value['runtime'].update(revision='d'*40, path=str(self.runtime/('d'*40)),
                                                             manifest_sha256='e'*64)
        put(bound, value); self.load()

    # --- B.2 RESUME_ADMIT acceptance ------------------------------------------
    def test_resume_admits_pending_with_unknown_identity_by_adopting_single_jsonl(self):
        self.op('NEW_PREPARE'); native = self.native_file()
        self.assertEqual(self.row()['status'], 'PENDING'); self.assertIsNone(self.row()['native_identity'])
        selected = self.op('RESUME_ADMIT')
        self.assertEqual(selected['status'], 'IN_FLIGHT'); self.assertEqual(selected['native_path'], str(native))
        self.assertEqual(self.row()['native_identity']['id'], NATIVE_ID)
        self.assertEqual(self.op('FINALIZE', 0)['status'], 'READY')

    def test_resume_admits_blocked_and_in_flight_with_same_native(self):
        self.op('NEW_PREPARE'); self.native_file(); self.op('FINALIZE', 7)
        self.assertEqual(self.row()['status'], 'BLOCKED')
        self.assertEqual(self.op('RESUME_ADMIT')['status'], 'IN_FLIGHT')
        nonce = self.row()['lifecycle_nonce']
        # A crashed launcher left IN_FLIGHT behind; the caller's locks prove no live owner.
        self.assertEqual(self.op('RESUME_ADMIT')['status'], 'IN_FLIGHT')
        self.assertNotEqual(self.row()['lifecycle_nonce'], nonce)
        self.assertEqual(self.op('FINALIZE', 0)['status'], 'READY')
        self.assertEqual(self.op('RESUME_ADMIT')['status'], 'IN_FLIGHT')

    def test_resume_refuses_missing_forked_or_replaced_native_without_mutation(self):
        self.op('NEW_PREPARE'); before = self.record.read_bytes()
        self.refused(lambda: self.op('RESUME_ADMIT'), 'OMP_CONTINUATION_NOT_PERSISTED')
        self.assertEqual(self.record.read_bytes(), before)
        native = self.native_file(); self.native_file('second_'+NATIVE_ID+'.jsonl')
        self.refused(lambda: self.op('RESUME_ADMIT'), 'OMP_CONTINUATION_NATIVE_FORK')
        self.assertEqual(self.record.read_bytes(), before)
        (self.sessions/('second_'+NATIVE_ID+'.jsonl')).unlink(); self.op('FINALIZE', 7)
        replacement = native.with_suffix('.new'); replacement.write_bytes(native.read_bytes()); replacement.chmod(0o600)
        os.replace(replacement, native); before = self.record.read_bytes()
        self.refused(lambda: self.op('RESUME_ADMIT'), 'OMP_CONTINUATION_IDENTITY_CHANGED')
        self.assertEqual(self.record.read_bytes(), before)

    def test_large_native_jsonl_is_admitted_reading_only_the_header(self):
        self.op('NEW_PREPARE'); self.native_file(body=b'x'*(3*1048576)+b'\n')
        self.assertEqual(self.op('RESUME_ADMIT')['status'], 'IN_FLIGHT')

    def test_mode_peek_is_gone(self):
        self.op('NEW_PREPARE'); self.native_file(); self.op('FINALIZE', 0)
        self.refused(lambda: self.op('MODE_PEEK'))
        self.assertFalse(hasattr(self.projection, 'validate_model_mode_peek'))

    # --- explicit runtime rebind for the installed Entry ----------------------
    def rebind(self, snapshot, source=None):
        return subprocess.run([sys.executable, '-I', '-S', '-B', str(snapshot/'bin/harness_omp_continuation.py'),
            '--rebind-runtime', str(self.state), str(source or self.profile), W],
            env={'HOME': str(self.home), 'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, capture_output=True, timeout=30)

    def test_rebind_moves_session_to_the_current_runtime_only(self):
        self.op('NEW_PREPARE'); self.native_file()
        bound = self.runtime/'bindings'/(W.lower()+'.json'); before = bound.read_bytes()
        old = self.snapshot
        self.snapshot = self.install_snapshot('c'*40); self.consumer = self.snapshot/'bin/aliases.zsh'
        self.publish()
        # Only the currently selected snapshot may claim the session.
        done = self.rebind(old); self.assertEqual(done.returncode, 2)
        self.assertNotIn(b'BUSY', done.stderr); self.assertEqual(bound.read_bytes(), before)
        other = self.base/'other'; other.mkdir(mode=0o700)
        self.assertEqual(self.rebind(self.snapshot, other).returncode, 2); self.assertEqual(bound.read_bytes(), before)
        import fcntl
        for lock in (self.record_dir/'runtime.lock',):
            fd = os.open(lock, os.O_RDWR)
            try:
                fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                done = self.rebind(self.snapshot)
                self.assertEqual(done.returncode, 2); self.assertIn(b'OMP_CONTINUATION_BUSY', done.stderr)
            finally: os.close(fd)
        self.assertEqual(bound.read_bytes(), before)
        done = self.rebind(self.snapshot)
        self.assertEqual(done.returncode, 0, done.stderr.decode())
        current = json.loads((self.runtime/'current.json').read_bytes())
        self.assertEqual(json.loads(bound.read_bytes()), {'source_root': str(self.profile), 'runtime': current})
        # The installed Entry's own encoding and private mode.
        self.assertEqual(bound.read_bytes(), json.dumps({'source_root': str(self.profile), 'runtime': current}, sort_keys=True).encode())
        self.assertEqual(bound.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.rebind(self.snapshot).returncode, 0)
        # The installed Entry's helper calls against the newly bound runtime.
        def load(name):
            spec = importlib.util.spec_from_file_location('entry_'+name, self.snapshot/'bin'/name)
            module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
        cont, proj = load('harness_omp_continuation.py'), load('harness_omp_projection.py')
        self.assertIsNotNone(cont.request(['omp', '--session-resume', H, '--']))
        cont.current_context(self.profile, self.consumer)
        row = cont.resolve(self.state, self.profile, H, self.consumer)
        self.assertEqual((row['status'], row['launcher_session_id']), ('PENDING', W))
        artifact, values, check = proj.model_mode_request(str(self.profile), ['--session-resume', H, '--'])
        self.assertEqual((artifact, check), (None, False))
        self.assertEqual(self.op('RESUME_ADMIT')['status'], 'IN_FLIGHT')

    # --- public herdr resume argv and live-handle refusal ---------------------
    def public_fixture(self):
        def source_file(name, body):
            path = self.profile/name; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body); path.chmod(0o600)
        for name in ('runtime-contract.yaml','budgets.yaml','claude-md.yaml'):
            source_file('.claude/source/'+name, (KERNEL/'.claude/source'/name).read_text())
        for kind in ('agents','commands','skills'):
            source_file('.claude/source/'+kind+'.yaml', kind+':\n  source: .claude/'+kind+'\n')
        source_file('.claude/source/settings.yaml',
            (KERNEL/'.claude/source/settings.yaml').read_text().split('\nhooks:', 1)[0]+'\nhooks:\n  entries:\n')
        for name in ('core/scripts/harness_compile.py','core/scripts/omp_required_extension.ts',
                     'core/omp/model_modes.py','.claude/source/omp-model-modes.json','core/omp/policy-omp.md'):
            source_file(name, (KERNEL/name).read_text())
        (self.profile/'.claude/rules').mkdir()
        self.tools = self.base/'tools'; self.tools.mkdir()
        for name in ('omp','claude','codex','kiro-cli','kiro'):
            tool = self.tools/name; tool.write_text('#!/bin/sh\nexit 97\n'); tool.chmod(0o700)
        jq = shutil.which('jq', path='/usr/bin:/bin') or shutil.which('jq')
        self.assertIsNotNone(jq, 'requires real jq')
        path = ':'.join(dict.fromkeys([str(self.tools), str(Path(jq).resolve(strict=True).parent), '/usr/bin', '/bin']))
        self.env = {'HOME':str(self.home),'PATH':path,'LC_ALL':'C','TERM':'dumb','TMPDIR':str(self.base),
            'HARNESS_PYTHON_BIN':sys.executable,'HARNESS_SESSION_STATE_HOME':str(self.state),
            'HARNESS_CLAUDE_PLUGIN_MIRROR':'0','HARNESS_AGENT_USAGE_TEST_MODE':'1',
            'HARNESS_AGENT_USAGE_STATE_DIR':str(self.base/'usage'),
            'HARNESS_POST_EDIT_CODEX_SYNC':'0','HARNESS_POST_COMMIT_CODEX_SYNC':'0'}
        for p in [self.snapshot, *self.snapshot.rglob('*')]:
            if p.is_dir(): p.chmod(0o500)

    def herdr(self, *tail, wait=False):
        # herdr's exact 6-element HERDR_RESUME_ARGV form, run from an unrelated cwd.
        argv = ['/bin/zsh', str(self.snapshot/'bin/harness-exec'), str(self.profile), 'omp', '--session-resume', H, '--', *tail]
        if wait:
            return subprocess.Popen(argv, cwd=self.base, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    start_new_session=True)
        return subprocess.run(argv, cwd=self.base, env=self.env, capture_output=True, timeout=60)

    def native_calls(self):
        return [json.loads(x) for x in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_installed_entry_model_mode_plan_admits_new_explicit_and_resume(self):
        # Verbatim body of the harness's installed Entry omp_model_mode_plan (core/scripts/herdr_launcher_entry.py);
        # only the store and helper loader are stubbed to the snapshot under test.
        self.public_fixture()
        snapshot, test = self.snapshot, self
        class OpsError(Exception): pass
        class Store:
            def verify(self, pin): return pin
            def selected(self): return {'path': str(snapshot), 'revision': 'a'*40, 'version': '0.77.0'}
        class Entry:
            store = Store()
            def runtime_helper(self, pin, name):
                spec = importlib.util.spec_from_file_location('entry_helper', Path(pin['path'])/'bin'/name)
                module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
            def omp_model_mode_plan(self,source,args,pin,env):
                tail=list(args);offset=2 if tail[:1]==['--cwd'] else 0
                if tail[offset:offset+1]==['--isolated-session']:offset+=2
                elif tail[offset:offset+1] in (['--isolated'],['--no-isolated']):offset+=1
                if tail[offset:offset+1]!=['omp']:return None
                words=tail[offset+1:]
                controls=words[:words.index('--')] if '--' in words else words
                present=os.path.lexists(source/'.claude/source/omp-model-modes.json')
                explicit=any(s.split('=',1)[0] in ('--model-mode','--model-mode-check') for s in controls)
                if not present and not explicit:return None
                if not explicit and words[:1] in (['--help'],['--version'],['login'],['models']):return None
                try:
                    pin=self.store.verify(pin) if pin is not None else self.store.selected()
                    helper=self.runtime_helper(pin,'harness_omp_projection.py')
                    artifact,_,check=helper.model_mode_request(str(source),words)
                    if check:
                        env.update(HARNESS_LAUNCHER_RUNTIME_REVISION=pin['revision'],
                                   HARNESS_LAUNCHER_RUNTIME_VERSION=pin['version'])
                        return {'legacy':False,'runtime':pin,'env':env,
                                'argv':[str(Path(pin['path'])/'bin/harness-exec'),str(source),*args]}
                    if artifact is not None:
                        helper.model_mode_admit(str(source),str(Path(pin['path'])/'bin/aliases.zsh'),artifact)
                except (OSError,ValueError,TypeError,KeyError,AttributeError) as exc:
                    raise OpsError('OMP_MODEL_MODE_UNSUPPORTED: '+str(exc)) from None
                return None
        entry = Entry()
        for args in (['omp'], ['omp', '--model-mode', 'gpt-only'], ['omp', '--session-resume', H, '--']):
            with self.subTest(args=args):
                self.assertIsNone(entry.omp_model_mode_plan(self.profile, args, None, {}))
        # The Entry does not catch ProjectionError (a plain Exception), so an
        # unknown mode escapes as the helper's own error, not OpsError.
        with self.assertRaises(Exception) as caught:
            entry.omp_model_mode_plan(self.profile, ['omp', '--model-mode', 'foreign'], None, {})
        self.assertEqual(type(caught.exception).__name__, 'ProjectionError')

    def test_herdr_bare_resume_of_pending_record_uses_default_mode_overlay(self):
        self.public_fixture(); self.op('NEW_PREPARE'); native = self.native_file()
        done = self.herdr()
        self.assertEqual(done.returncode, 0, done.stderr.decode())
        calls = self.native_calls(); self.assertEqual(len(calls), 1)
        argv = calls[0]['argv']
        self.assertEqual(calls[0]['cwd'], str(self.work))
        self.assertEqual(argv[-5:], ['--session-dir', str(self.sessions), '--resume', str(native), '--'])
        self.assertFalse(any(a.startswith('--harness-required-bundle') for a in argv))
        self.assertFalse(any(a.startswith('--model-mode') for a in argv))
        bundle = Path(next(a.split('=', 1)[1] for a in argv if a.startswith('--append-system-prompt='))).parent
        self.assertIn('--trusted-extension='+str(bundle/'required-extension.ts'), argv)
        self.assertIn('--config='+str(bundle/'omp-settings.yml'), argv)
        selection = json.loads((bundle/'selection.json').read_text())
        self.assertEqual(selection['schema'], 1); self.assertEqual(selection['runtime_version'], '18.11.3')
        self.assertIn('model-mode:hybrid-opus-lead', selection['bundle_ids'])
        self.assertFalse({'contract_id','native_release','current_projection'} & set(selection))
        self.assertEqual(self.row()['status'], 'READY')
        self.assertIn(b'OMP_CONTINUATION_HANDLE='+H.encode(), done.stderr)

    def test_herdr_resume_with_explicit_mode_and_blocked_record(self):
        self.public_fixture(); self.op('NEW_PREPARE'); self.native_file(); self.op('FINALIZE', 7)
        argv = ['/bin/zsh', str(self.snapshot/'bin/harness-exec'), str(self.profile), 'omp', '--model-mode', 'gpt-only',
                '--session-resume', H, '--']
        done = subprocess.run(argv, cwd=self.base, env=self.env, capture_output=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr.decode())
        bundle = Path(next(a.split('=', 1)[1] for a in self.native_calls()[0]['argv']
                           if a.startswith('--append-system-prompt='))).parent
        self.assertIn('model-mode:gpt-only', json.loads((bundle/'selection.json').read_text())['bundle_ids'])

    def test_native_nonzero_prints_resumable_hint_and_resume_recovers(self):
        self.public_fixture(); self.op('NEW_PREPARE'); self.native_file()
        done = self.herdr('9')
        self.assertEqual(done.returncode, 9, done.stderr.decode())
        self.assertEqual(self.row()['status'], 'BLOCKED')
        self.assertIn(b'omp --session-resume '+H.encode(), done.stderr)
        self.assertNotIn(b'OMP_CONTINUATION_UNBOUND', done.stderr)
        self.assertEqual(self.herdr().returncode, 0)
        self.assertEqual(self.row()['status'], 'READY')

    def activate(self):
        # A launcher activation: a new current snapshot; the session stays bound to the old one.
        old = self.snapshot
        self.snapshot = self.install_snapshot('c'*40); self.consumer = self.snapshot/'bin/aliases.zsh'
        self.publish(); return old

    def bound(self): return self.runtime/'bindings'/(W.lower()+'.json')

    def resumed_after_activation(self, finalize):
        self.op('NEW_PREPARE'); self.native_file()
        if finalize: self.op('FINALIZE', 0)
        old = self.activate(); self.public_fixture()
        self.assertEqual(json.loads(self.bound().read_bytes())['runtime']['path'], str(old))
        done = self.herdr()
        self.assertEqual(done.returncode, 0, done.stderr.decode())
        self.assertEqual(len(self.native_calls()), 1); self.assertEqual(self.row()['status'], 'READY')
        current = json.loads((self.runtime/'current.json').read_bytes())
        self.assertEqual(self.bound().read_bytes(),
                         json.dumps({'source_root': str(self.profile), 'runtime': current}, sort_keys=True).encode())

    def test_shell_resume_after_activation_rebinds_and_launches(self):
        self.resumed_after_activation(finalize=True)

    def test_shell_resume_after_activation_rebinds_a_pending_record(self):
        self.resumed_after_activation(finalize=False)

    def test_shell_resume_after_activation_refuses_another_source(self):
        self.op('NEW_PREPARE'); self.native_file(); self.op('FINALIZE', 0)
        self.activate(); self.public_fixture()
        value = json.loads(self.bound().read_bytes()); value['source_root'] = str(self.base/'other'); put(self.bound(), value)
        before = (self.bound().read_bytes(), self.record.read_bytes())
        done = self.herdr()
        self.assertEqual(done.returncode, 2); self.assertIn(b'OMP_CONTINUATION_UNBOUND', done.stderr)
        self.assertEqual((self.bound().read_bytes(), self.record.read_bytes()), before)
        self.assertEqual(self.native_calls(), [])

    def test_shell_resume_after_activation_with_a_held_lock_is_busy_without_change(self):
        import fcntl
        self.op('NEW_PREPARE'); self.native_file(); self.op('FINALIZE', 0)
        self.activate(); self.public_fixture()
        binding_lock = self.runtime/'binding-locks'/(W.lower()+'.lock'); binding_lock.write_bytes(b''); binding_lock.chmod(0o600)
        native_lock = self.slot/'native.lock'; native_lock.write_bytes(b''); native_lock.chmod(0o600)
        before = (self.bound().read_bytes(), self.record.read_bytes())
        for lock, take in ((binding_lock, fcntl.flock), (self.record_dir/'runtime.lock', fcntl.lockf), (native_lock, fcntl.lockf)):
            fd = os.open(lock, os.O_RDWR)
            try:
                take(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                done = self.herdr()
                with self.subTest(lock=lock.name):
                    self.assertEqual(done.returncode, 2); self.assertIn(b'OMP_CONTINUATION_BUSY', done.stderr)
                    self.assertEqual((self.bound().read_bytes(), self.record.read_bytes()), before)
            finally: os.close(fd)
        self.assertEqual(self.native_calls(), [])
        self.assertEqual(self.herdr().returncode, 0)

    def test_bare_resume_refuses_unknown_handle_and_bare_new(self):
        self.public_fixture()
        bad = 'f'*32
        done = subprocess.run(['/bin/zsh', str(self.snapshot/'bin/harness-exec'), str(self.profile), 'omp',
                               '--session-resume', bad, '--'], cwd=self.base, env=self.env, capture_output=True, timeout=60)
        self.assertEqual(done.returncode, 2, done.stderr.decode())
        done = subprocess.run(['/bin/zsh', str(self.snapshot/'bin/harness-exec'), str(self.profile), 'omp',
                               '--session-new', '--'], cwd=self.base, env=self.env, capture_output=True, timeout=60)
        self.assertEqual(done.returncode, 2, done.stderr.decode())
        self.assertEqual(self.native_calls(), [])

    def wait_ready(self, proc):
        deadline = time.monotonic()+30
        while not self.ready.exists():
            self.assertIsNone(proc.poll(), proc.stderr.read().decode() if proc.poll() is not None else '')
            self.assertLess(time.monotonic(), deadline); time.sleep(0.05)

    def test_second_resume_of_live_handle_is_busy_even_after_launcher_killed(self):
        self.public_fixture(); self.op('NEW_PREPARE'); self.native_file()
        first = self.herdr('wait', wait=True)
        self.addCleanup(lambda: (self.release_file.touch(), first.poll() is None and first.kill(), first.wait(), first.stdout.close(), first.stderr.close()))
        self.wait_ready(first)
        before = self.record.read_bytes()
        done = self.herdr()
        self.assertEqual(done.returncode, 2); self.assertIn(b'is already active', done.stderr)
        self.assertEqual(self.record.read_bytes(), before); self.assertEqual(len(self.native_calls()), 1)
        # Kill every launcher shell (entry and continuation subshell, which held
        # the workspace lease); the native keeps running.
        native_pid = self.native_calls()[0]['pid']
        pid, launchers = native_pid, []
        while pid != first.pid:
            pid = int(subprocess.run(['ps', '-o', 'ppid=', '-p', str(pid)], capture_output=True, text=True).stdout)
            launchers.append(pid)
        for pid in launchers: os.kill(pid, signal.SIGKILL)
        first.wait(); time.sleep(0.2)
        os.kill(native_pid, 0)
        done = self.herdr()
        self.assertEqual(done.returncode, 2, done.stderr.decode())
        self.assertIn(b'OMP_CONTINUATION_BUSY', done.stderr)
        self.assertEqual(self.record.read_bytes(), before); self.assertEqual(len(self.native_calls()), 1)
        self.release_file.touch()
        deadline = time.monotonic()+10
        while True:
            try: os.kill(native_pid, 0)
            except ProcessLookupError: break
            self.assertLess(time.monotonic(), deadline); time.sleep(0.05)
        time.sleep(0.2)
        # The killed launcher never finalized: IN_FLIGHT is recovered by the next resume.
        self.assertEqual(self.row()['status'], 'IN_FLIGHT')
        done = self.herdr()
        self.assertEqual(done.returncode, 0, done.stderr.decode()); self.assertEqual(self.row()['status'], 'READY')

    def test_caller_trusted_extension_is_refused(self):
        self.public_fixture(); self.op('NEW_PREPARE'); self.native_file(); before = self.record.read_bytes()
        for tail in (['--trusted-extension=/foreign.ts'], ['--trusted-extension', '/foreign.ts']):
            argv = ['/bin/zsh', str(self.snapshot/'bin/harness-exec'), str(self.profile), 'omp', '--session-resume', H,
                    *tail, '--']
            done = subprocess.run(argv, cwd=self.base, env=self.env, capture_output=True, timeout=60)
            self.assertEqual(done.returncode, 2, done.stderr.decode())
        self.assertEqual(self.native_calls(), []); self.assertEqual(self.record.read_bytes(), before)

if __name__ == '__main__': unittest.main(verbosity=2)
PYTEST
