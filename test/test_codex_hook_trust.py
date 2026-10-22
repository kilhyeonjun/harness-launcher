"""Native-compatible approved hook trust across fresh isolated homes."""
import contextlib
import hashlib
import io
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_codex_surface as fixtures

@unittest.skipUnless(Path("/usr/bin/lockf").is_file(), "requires macOS /usr/bin/lockf")
class IsolatedTrustIntegrationTests(unittest.TestCase):
    def build(self, tweak=lambda source, target, record: None, post_prepare=None):
        fixture = fixtures.PrepareIntegrationTests('runTest')
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        source = fixture.repo.resolve()
        fixture.repo = source
        fixture.home.joinpath('.codex').mkdir(exist_ok=True)
        global_config=fixture.home/'.codex/config.toml'
        global_config.write_text('# untouched global fixture\n')
        global_before=global_config.read_bytes()
        package = fixture.tmp.resolve()/'launcher-bin'
        shutil.copytree(ROOT/'bin',package,ignore=shutil.ignore_patterns('__pycache__'))
        prepare_patch=mock.patch.object(fixtures,'PREPARE',package/'codex-home-prepare.sh')
        prepare_patch.start();self.addCleanup(prepare_patch.stop)
        script = source / 'core/hooks/session-start.sh'
        settings = {'hooks': {'SessionStart': [{'hooks': [{'type':'command','command':'bash ' + str(script),'timeout':7}]}]}}
        (source / '.claude/settings.json').write_text(json.dumps(settings))
        fixture.prepare(HARNESS_CODEX_SLACK_APPS="")
        home = source / '.harness/codex'
        hook_file = home / 'hooks.json'
        h = json.loads(hook_file.read_text())['hooks']['SessionStart'][0]['hooks'][0]
        # Native 0.161 hooks/list verified normalization for this command subset.
        normalized = {'event_name':'session_start','hooks':[dict(type='command', command=h['command'], timeout=7, **{'async':False})]}
        fingerprint = 'sha256:' + hashlib.sha256(json.dumps(normalized,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        with (home/'config.toml').open('a') as f:
            f.write('\n[hooks.state.'+json.dumps(str(hook_file)+':session_start:0:0')+']\ntrusted_hash = '+json.dumps(fingerprint)+'\nenabled = false\n')
        (source/'.gitignore').write_text('.harness/\n')
        subprocess.run(['git','init','-q',str(source)],check=True)
        subprocess.run(['git','-C',str(source),'add','.'],check=True)
        env=fixture.environment(GIT_AUTHOR_NAME='Fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='Fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid')
        subprocess.run(['git','-C',str(source),'-c','core.hooksPath=/dev/null','commit','-qm','fixture'],env=env,check=True)
        sid='11111111-1111-4111-8111-111111111111'
        state=fixture.tmp.resolve()/'launcher-state'; target=state/'worktrees'/sid; record=state/'sessions'/sid
        shutil.copytree(source,target,ignore=shutil.ignore_patterns('.harness'))
        record.mkdir(parents=True)
        for name,value in {'source-root':str(source),'session-root':str(target),'base-sha':subprocess.check_output(['git','-C',str(target),'rev-parse','HEAD'],text=True).strip(),'root-inode':f'{target.stat().st_dev} {target.stat().st_ino}','journal':'state=OPEN'}.items():
            (record/name).write_text(value+'\n')
        approvals=state/'hook-approvals';approvals.mkdir()
        grant=approvals/(hashlib.sha256(str(source).encode()).hexdigest()+'.json')
        grant.write_text(json.dumps({'schema_version':1,'source':str(source),'algorithm':'codex-0.161-command-hooks','approval_receipt_sha256':'a'*64,'approved_snapshot':{'base_sha':(record/'base-sha').read_text().strip(),'audit_raw_hooks_sha256':hashlib.sha256(hook_file.read_bytes()).hexdigest()},'hooks':json.loads(hook_file.read_text()),'normalization':'literal-core-and-approved-callback-paths-v1','normalized_hooks_sha256':hashlib.sha256(json.dumps(json.loads(hook_file.read_text()),sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest(),'codex_binary_sha256':hashlib.sha256(fixture.codex_bin.read_bytes()).hexdigest(),'codex_version':'codex-cli 0.153.2','callbacks':{str(package/name):hashlib.sha256((package/name).read_bytes()).hexdigest() for name in ('codex-hook-adapter.sh','codex-pretool-adapter.py','codex-cmux-title-sync.py','harness-launch-record')},'scripts':{'core/hooks/session-start.sh':{'sha256':hashlib.sha256(script.read_bytes()).hexdigest(),'base_blob_sha256':hashlib.sha256(script.read_bytes()).hexdigest()}}}))
        grant.chmod(0o600)
        tweak(source, target, record)
        fixture.repo=target
        fixture.prepare(HARNESS_CODEX_SLACK_APPS="",HARNESS_SOURCE_ROOT=str(source),HARNESS_SESSION_ROOT=str(target),HARNESS_SESSION_ID=sid,HARNESS_SESSION_STATE_HOME=str(state))
        config=tomllib.loads((target/'.harness/codex/config.toml').read_text())
        key=str(target/'.harness/codex/hooks.json')+':session_start:0:0'
        if post_prepare:
            post_prepare(fixture, source, target, record)
        first=(target/'.harness/codex/config.toml').read_bytes()
        overlay_before=(target/'.harness/codex/rich.config.toml').read_bytes()
        fixture.prepare(HARNESS_CODEX_SLACK_APPS="",HARNESS_SOURCE_ROOT=str(source),HARNESS_SESSION_ROOT=str(target),HARNESS_SESSION_ID=sid,HARNESS_SESSION_STATE_HOME=str(state))
        self.assertEqual(first,(target/'.harness/codex/config.toml').read_bytes(),'warm prep changed runtime trust state')
        self.assertEqual(overlay_before,(target/'.harness/codex/rich.config.toml').read_bytes(),'profile hook approval was erased by preparation')
        self.assertEqual(global_before,global_config.read_bytes(),'global config changed')
        return config, key

    def test_fresh_isolated_home_inherits_only_approved_unchanged_hook(self):
        config, key = self.build()
        self.assertIn(key,config.get('hooks',{}).get('state',{}),'fresh isolated home lost an already approved unchanged hook')
        self.assertFalse(config['hooks']['state'][key]['enabled'])
        self.assertEqual(len(config['hooks']['state']),1,'unapproved launcher hooks must stay untrusted')

    def test_changed_or_unapproved_evidence_does_not_gain_trust(self):
        def stale(source, target, record):
            p=source/'.harness/codex/config.toml'
            p.write_text(p.read_text().replace('trusted_hash = "sha256:', 'trusted_hash = "sha256:bad'))
        def changed_script(source, target, record):
            (target/'core/hooks/session-start.sh').write_text('#!/bin/sh\nexit 42\n')
        def forged_record(source, target, record):
            (record/'source-root').write_text(str(target)+'\n')
        def wrong_inode(source, target, record):
            (record/'root-inode').write_text('0 0\n')
        def missing_approval(source, target, record):
            (source/'.harness/codex/config.toml').write_text('model="fixture"\n')
        def changed_matcher(source, target, record):
            p=target/'.claude/settings.json'; d=json.loads(p.read_text());d['hooks']['SessionStart'][0]['matcher']='changed';p.write_text(json.dumps(d))
        def stale_open_record(source, target, record):
            (record/'journal').write_text('state=OPEN\nstate=DELIVERED\n')
        def no_grant(source, target, record):
            next((record.parents[1]/'hook-approvals').glob('*.json')).unlink()
        def wrong_grant_source(source, target, record):
            p=next((record.parents[1]/'hook-approvals').glob('*.json'));d=json.loads(p.read_text());d['source']=str(target);p.write_text(json.dumps(d))
        def wrong_grant_mode(source, target, record):
            next((record.parents[1]/'hook-approvals').glob('*.json')).chmod(0o644)
        def changed_grant_set(source, target, record):
            p=next((record.parents[1]/'hook-approvals').glob('*.json'));d=json.loads(p.read_text());d['hooks']['hooks']['SessionStart'].reverse();p.write_text(json.dumps(d))
        def native_drift(source, target, record):
            p=next((record.parents[1]/'hook-approvals').glob('*.json'));d=json.loads(p.read_text());d['codex_binary_sha256']='0'*64;p.write_text(json.dumps(d))
        def wrong_grant_base(source, target, record):
            p=next((record.parents[1]/'hook-approvals').glob('*.json'));d=json.loads(p.read_text());d['approved_snapshot']['base_sha']='0'*40;p.write_text(json.dumps(d))
        def wrong_base_blob(source,target,record):
            p=next((record.parents[1]/'hook-approvals').glob('*.json'));d=json.loads(p.read_text());d['scripts']['core/hooks/session-start.sh']['base_blob_sha256']='0'*64;p.write_text(json.dumps(d))
        def symlink_script(source, target, record):
            p=target/'core/hooks/session-start.sh';p.unlink();p.symlink_to(source/'core/hooks/session-start.sh')
        for tweak in (stale, changed_script, forged_record, wrong_inode, missing_approval, changed_matcher, symlink_script, stale_open_record, no_grant, wrong_grant_source, wrong_grant_mode, changed_grant_set, native_drift, wrong_grant_base, wrong_base_blob):
            with self.subTest(case=tweak.__name__):
                config,key=self.build(tweak)
                self.assertNotIn(key,config.get('hooks',{}).get('state',{}))

    def test_root_identity_tolerates_device_renumbering_only(self):
        def renumbered(source,target,record):
            i=target.stat();(record/'root-inode').write_text(f'{i.st_dev+1} {i.st_ino}\n')
        def other_inode(source,target,record):
            i=target.stat();(record/'root-inode').write_text(f'{i.st_dev+1} {i.st_ino+1}\n')
        config,key=self.build(renumbered)
        self.assertIn(key,config.get('hooks',{}).get('state',{}),'renumbered device must keep approved hooks')
        config,key=self.build(other_inode)
        self.assertNotIn(key,config.get('hooks',{}).get('state',{}))

    def test_root_identity_rule_unit(self):
        spec=importlib.util.spec_from_file_location('hook_trust_identity',ROOT/'bin/codex-hook-trust.py')
        m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        with tempfile.TemporaryDirectory() as tmp:
            wt=Path(tmp).resolve()/'worktrees';root=wt/'id';root.mkdir(parents=True)
            i=root.stat()
            self.assertTrue(m.root_identity_matches(f'{i.st_dev} {i.st_ino}',root))
            self.assertTrue(m.root_identity_matches(f'{i.st_dev+1} {i.st_ino}',root))
            self.assertFalse(m.root_identity_matches(f'{i.st_dev+1} {i.st_ino+1}',root))
            self.assertFalse(m.root_identity_matches('bogus',root))
            real=m.identity_stat
            def other_device(path):
                r=real(path)
                return os.stat_result((r.st_mode,r.st_ino,r.st_dev+9,*tuple(r)[3:])) if Path(path)==root else r
            with mock.patch.object(m,'identity_stat',other_device):
                self.assertFalse(m.root_identity_matches(f'{i.st_dev+1} {i.st_ino}',root))
            fresh=wt/'fresh';fresh.mkdir()
            self.assertFalse(m.root_identity_matches(f'{i.st_dev+1} {i.st_ino}',fresh))

    def test_normalized_grant_digest_is_verified(self):
        def bad_digest(source,target,record):
            p=next((record.parents[1]/'hook-approvals').glob('*.json'));d=json.loads(p.read_text());d['normalized_hooks_sha256']='0'*64;p.write_text(json.dumps(d))
        config,key=self.build(bad_digest)
        self.assertNotIn(key,config.get('hooks',{}).get('state',{}))

    def test_unrelated_new_snapshot_preserves_approved_hooks(self):
        def unrelated_commit(source,target,record):
            (target/'unrelated.txt').write_text('unrelated metadata')
            subprocess.run(['git','-C',str(target),'add','unrelated.txt'],check=True)
            subprocess.run(['git','-C',str(target),'-c','core.hooksPath=/dev/null','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','unrelated'],check=True)
            (record/'base-sha').write_bytes(subprocess.check_output(['git','-C',str(target),'rev-parse','HEAD']))
        config,key=self.build(unrelated_commit)
        self.assertIn(key,config.get('hooks',{}).get('state',{}))

    def test_identical_callback_in_new_verified_package_path_inherits(self):
        def new_package(source,target,record):
            parent=record.parents[1].parent
            original=parent/'launcher-bin';current=parent/'current-runtime-bin'
            shutil.copytree(original,current)
            switch=mock.patch.object(fixtures,'PREPARE',current/'codex-home-prepare.sh');switch.start();self.addCleanup(switch.stop)
        config,key=self.build(new_package)
        self.assertIn(key,config.get('hooks',{}).get('state',{}))

    def test_modified_external_callback_does_not_gain_trust(self):
        def changed_external(source, target, record):
            package=record.parents[1].parent/'launcher-bin'
            (package/'codex-hook-adapter.sh').write_text('#!/bin/sh\nexit 42\n')
        config,key=self.build(changed_external)
        self.assertNotIn(key,config.get('hooks',{}).get('state',{}))

    def test_existing_target_and_foreign_decisions_are_preserved(self):
        def decisions(source, target, record):
            home=target/'.harness/codex';home.mkdir(parents=True)
            key=str(home/'hooks.json')+':session_start:0:0'
            text='[hooks.state.'+json.dumps(key)+']\ntrusted_hash="sha256:user-decision"\nenabled=false # keep exact\n\n[hooks.state."foreign@plugin:source:stop:0:0"]\ntrusted_hash="sha256:foreign"\nenabled=false # foreign exact\n'
            (home/'config.toml').write_text(text)
        config,key=self.build(decisions)
        self.assertEqual(config['hooks']['state'][key]['trusted_hash'],'sha256:user-decision')
        self.assertFalse(config['hooks']['state']['foreign@plugin:source:stop:0:0']['enabled'])

    def test_native_profile_approval_survives_preparation(self):
        def approved_profile(fixture, source, target, record):
            p=target/'.harness/codex/rich.config.toml'
            key=str(target/'.harness/codex/hooks.json')+':session_start:0:0'
            with p.open('a') as f:
                for i in range(48):
                    selected=key if i==0 else f'foreign@plugin:source:stop:{i}:0'
                    f.write('\n[hooks.state.'+json.dumps(selected)+']\ntrusted_hash="sha256:profile-user-decision"\nenabled=false # exact profile choice\n')
            before=p.read_bytes(); calls=fixture.counter.read_bytes()
            env=dict(HARNESS_CODEX_SLACK_APPS='',HARNESS_SOURCE_ROOT=str(source),HARNESS_SESSION_ROOT=str(target),HARNESS_SESSION_ID=record.name,HARNESS_SESSION_STATE_HOME=str(record.parents[1]))
            fixture.prepare(**env)
            self.assertEqual(calls,fixture.counter.read_bytes(),'native profile trust unnecessarily invalidated warm state')
            self.assertEqual(before,p.read_bytes())
            manifest=target/'config/codex-surface.json';d=json.loads(manifest.read_text());d['repo']='changed';manifest.write_text(json.dumps(d))
            fixture.prepare(**env)
            self.assertEqual(before,p.read_bytes(),'cold prep erased native/foreign profile approvals')
            p.write_bytes(b'unknown_profile_key=true\n'+before)
            fixture.prepare(**env)
            self.assertEqual(before,p.read_bytes(),'repair of unmanaged profile drift lost hook decisions')
            self.assertEqual(len(tomllib.loads(p.read_text())['hooks']['state']),48)
        self.build(post_prepare=approved_profile)

    def test_malformed_native_profile_repairs_without_inheriting_bad_state(self):
        def malformed_profile(fixture, source, target, record):
            p = target / '.harness/codex/rich.config.toml'
            env = dict(HARNESS_CODEX_SLACK_APPS='', HARNESS_SOURCE_ROOT=str(source),
                       HARNESS_SESSION_ROOT=str(target), HARNESS_SESSION_ID=record.name,
                       HARNESS_SESSION_STATE_HOME=str(record.parents[1]))
            for content in (b'[hooks.state.\"broken\"\ntrusted_hash=\"unverified\"\n', b'\xff\xfeinvalid'):
                with self.subTest(content=content):
                    p.write_bytes(content)
                    fixture.prepare(**env)
                    repaired = tomllib.loads(p.read_text())
                    self.assertNotIn('state', repaired.get('hooks', {}))
                    self.assertEqual(repaired['model'], 'gpt-6.1-sol')
        self.build(post_prepare=malformed_profile)

    def test_native_0161_current_hash_fixture(self):
        spec=importlib.util.spec_from_file_location('codex_hook_trust_test',ROOT/'bin/codex-hook-trust.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        command='/bin/sh -c \'s="$HOME/.orca/agent-hooks/codex-hook.sh"; [ -x "$s" ] && { /bin/sh "$s" >/dev/null 2>&1; exit 0; }; cat >/dev/null\''
        handler={'type':'command','command':command,'timeout':5}
        self.assertEqual(module.fingerprint('Stop',None,handler),'sha256:e15f2c7d58c59e58ca47fd189969fe9041eaed2f185bb5e4e8d43b24c1f01427')

@unittest.skipUnless(Path("/usr/bin/lockf").is_file(), "requires macOS /usr/bin/lockf")
class CaptureApprovalTests(unittest.TestCase):
    def test_native_binary_digest_is_checked_before_it_runs(self):
        spec = importlib.util.spec_from_file_location('identity_order', ROOT / 'bin/codex-hook-trust.py')
        m = importlib.util.module_from_spec(spec)
        with mock.patch.object(sys, 'dont_write_bytecode', True):
            spec.loader.exec_module(m)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); marker = root / 'ran'; binary = root / 'codex'
            binary.write_text(f'#!/bin/sh\ntouch {marker}\necho codex-cli 1\n'); binary.chmod(0o755)
            with mock.patch.dict(os.environ, {'HARNESS_CODEX_BIN': str(binary)}):
                with self.assertRaisesRegex(ValueError, 'native executable changed'):
                    m.native_identity('0' * 64)
                self.assertFalse(marker.exists(), 'unapproved native binary was executed')
                digest, version = m.native_identity(hashlib.sha256(binary.read_bytes()).hexdigest())
            self.assertEqual(version, 'codex-cli 1')

    """Operator capture records only an approval the owner already gave natively."""

    def test_capture_records_only_complete_native_approval(self):
        self.ran = False
        IsolatedTrustIntegrationTests.build(self, post_prepare=self.scenarios)
        self.assertTrue(self.ran)

    def scenarios(self, fixture, source, target, record):
        self.ran = True
        package = fixture.tmp.resolve() / 'launcher-bin'
        spec = importlib.util.spec_from_file_location('hook_capture', package / 'codex-hook-trust.py')
        m = importlib.util.module_from_spec(spec)
        with mock.patch.object(sys, 'dont_write_bytecode', True):  # keep the package tree unchanged
            spec.loader.exec_module(m)
        state = record.parents[1]; home = target / '.harness/codex'; published = home
        hooks_path = home / 'hooks.json'; hooks = json.loads(hooks_path.read_text())
        approvals = state / 'hook-approvals'
        grant_path = approvals / (hashlib.sha256(str(source).encode()).hexdigest() + '.json')
        original = grant_path.read_bytes()
        shutil.rmtree(approvals)
        profile = home / 'base.config.toml'
        existed = profile.exists(); profile_before = profile.read_bytes() if existed else b''
        entries = []
        for event, groups in hooks['hooks'].items():
            for gi, group in enumerate(groups):
                for hi, handler in enumerate(group['hooks']):
                    entries.append((f'{hooks_path}:{m.EVENTS[event]}:{gi}:{hi}', m.fingerprint(event, group.get('matcher'), handler)))
        self.assertGreater(len(entries), 1, 'fixture needs several hooks to test partial approval')

        def write_profile(skip=None, hash_for=None, enabled=None, raw=None):
            text = profile_before.decode()
            for key, digest in entries:
                if key == skip:
                    continue
                text += '\n[hooks.state.' + json.dumps(key) + ']\ntrusted_hash = ' + json.dumps(hash_for.get(key, digest) if hash_for else digest) + '\n'
                if enabled is not None and key == entries[0][0]:
                    text += 'enabled = ' + enabled + '\n'
            profile.write_text(raw if raw is not None else text)
        env = {'HARNESS_SESSION_ID': record.name, 'HARNESS_SESSION_STATE_HOME': str(state),
               'HARNESS_SESSION_ROOT': str(target), 'HARNESS_SOURCE_ROOT': str(source),
               'HARNESS_CODEX_BIN': str(fixture.codex_bin)}
        patch = mock.patch.dict(os.environ, env); patch.start()

        def refused(label, why, **kw):
            with self.subTest(refusal=label):
                write_profile(**kw)
                with self.assertRaisesRegex(ValueError, why):
                    m.capture(published)
                self.assertFalse(approvals.exists(), 'refusal must not create a record')

        # Refusals: partial, untrusted, hash mismatch, disabled, unreadable, foreign source.
        refused('missing-decision', 'no trusted enabled native decision', skip=entries[-1][0])
        refused('hash-mismatch', 'no trusted enabled native decision', hash_for={entries[0][0]: 'sha256:' + '0' * 64})
        refused('disabled', 'no trusted enabled native decision', enabled='false')
        refused('malformed', '', raw='[hooks.state.\n')
        profile.write_bytes(b'\xff\xfe')
        with self.assertRaises(ValueError):
            m.capture(published)
        profile.unlink()
        with self.assertRaisesRegex(ValueError, 'unreadable or unsupported evidence'):
            m.capture(published)
        write_profile()
        with self.assertRaisesRegex(ValueError, 'unknown profile'):
            m.capture(published, profile='../base')
        journal = (record / 'journal').read_text()
        (record / 'source-root').write_text(str(target) + '\n')
        with self.assertRaisesRegex(ValueError, 'invalid source root'):
            m.capture(published)
        (record / 'source-root').write_text(str(source) + '\n')
        (record / 'journal').write_text('state=OPEN\nstate=DELIVERED\n')
        with self.assertRaisesRegex(ValueError, 'not open'):
            m.capture(published)
        (record / 'journal').write_text(journal)
        real_git = m.git_output  # the session script no longer matches its snapshot blob
        with mock.patch.object(m, 'git_output', lambda t, *a: b'other' if a[0] == 'show' else real_git(t, *a)):
            with self.assertRaisesRegex(ValueError, 'differs from the session snapshot'):
                m.capture(published)
        self.assertFalse(approvals.exists())

        # Same hash under another path (source home or another session) is not this session's decision.
        for other in (str(source / '.harness/codex/hooks.json'), str(state / 'worktrees/22222222-2222-4222-8222-222222222222/.harness/codex/hooks.json')):
            profile.write_text(profile_before.decode() + ''.join(
                '\n[hooks.state.' + json.dumps(key.replace(str(hooks_path), other)) + ']\ntrusted_hash = ' + json.dumps(digest) + '\n'
                for key, digest in entries))
            with self.assertRaisesRegex(ValueError, 'no trusted enabled native decision'):
                m.capture(published)
        for value in ('"true"', '1'):
            refused('non-bool-enabled', 'no trusted enabled native decision', enabled=value)
        write_profile()
        # Links never count as evidence: profile, hooks.json.
        moved = profile.with_name('moved.toml'); profile.rename(moved); profile.symlink_to(moved)
        with self.assertRaisesRegex(ValueError, 'unreadable or unsupported evidence'):
            m.capture(published)
        profile.unlink(); moved.rename(profile)
        moved = hooks_path.with_name('moved.json'); hooks_path.rename(moved); hooks_path.symlink_to(moved)
        with self.assertRaisesRegex(ValueError, 'unreadable or unsupported evidence'):
            m.capture(published)
        hooks_path.unlink(); moved.rename(hooks_path)
        inode = (record / 'root-inode').read_text()
        (record / 'root-inode').write_text('0 0\n')
        with self.assertRaisesRegex(ValueError, 'session root replaced'):
            m.capture(published)
        (record / 'root-inode').write_text(inode)
        # Sandbox or inherited session environment must not select the session implicitly.
        with mock.patch.dict(os.environ, {'CODEX_SANDBOX': 'seatbelt'}), mock.patch('sys.stderr') as err:
            self.assertEqual(m.main(['capture', '--dry-run']), 1)
        self.assertIn('operator', ''.join(c.args[0] for c in err.write.call_args_list))
        with mock.patch('sys.stderr') as err:  # HARNESS_SESSION_* is inherited here
            self.assertEqual(m.main(['capture', '--dry-run']), 1)
        self.assertIn('--session-id', ''.join(c.args[0] for c in err.write.call_args_list))
        # Unsafe record directory: link, or not private.
        other_dir = state / 'elsewhere'; other_dir.mkdir()
        approvals.symlink_to(other_dir)
        with self.assertRaises((ValueError, OSError)):
            m.capture(published)
        approvals.unlink(); other_dir.rmdir()
        approvals.mkdir(0o755); approvals.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'private directory'):
            m.capture(published)
        approvals.rmdir()
        self.assertFalse(approvals.exists())

        with mock.patch.object(m, 'inherit', lambda config, hooks, published, grant=None: config):
            with self.assertRaisesRegex(ValueError, 'would inherit no hook'):
                m.capture(published)
        # Dry run reports without writing and exposes no hook command text.
        summary = m.capture(published, dry_run=True)
        self.assertFalse(approvals.exists(), 'dry-run wrote a record')
        self.assertEqual(summary['hooks'], len(entries))
        self.assertNotIn(str(target), json.dumps(summary))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = m.main(['capture', '--session-id', record.name, '--dry-run', '--profile', 'base'])
        self.assertEqual(code, 0)
        for groups in hooks['hooks'].values():
            for group in groups:
                for handler in group['hooks']:
                    self.assertNotIn(handler['command'], out.getvalue())
                    self.assertNotIn(str(target), out.getvalue())
        self.assertFalse(approvals.exists())

        # Capture writes a private atomic record that the launcher accepts and inherits from.
        self.assertEqual(m.main(['capture', '--session-id', record.name]), 0)
        self.assertEqual(stat.S_IMODE(approvals.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(grant_path.stat().st_mode), 0o600)
        grant = m.approval_record(state, source, target, hooks, record.joinpath('base-sha').read_text().strip())
        self.assertEqual(grant['approval_receipt_sha256'], summary['approval_receipt_sha256'])
        self.assertRegex(grant['approval_receipt_sha256'], '^[0-9a-f]{64}$')
        evidence = grant['approval_evidence']
        self.assertEqual(hashlib.sha256(json.dumps(evidence, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest(), grant['approval_receipt_sha256'])
        self.assertEqual(evidence['normalized_hooks_sha256'], grant['normalized_hooks_sha256'])
        stripped = m.split_profile_state((home / 'config.toml').read_text())[0]
        self.assertNotIn('hooks', tomllib.loads(stripped))
        inherited = tomllib.loads(m.inherit(stripped, hooks_path, published))
        key = str(hooks_path) + ':session_start:0:0'
        self.assertIn(key, inherited['hooks']['state'])
        self.assertEqual(sorted(p.name for p in approvals.iterdir()), [grant_path.name])

        # Recapture backs up the previous record; a failed replace leaves it intact.
        first = grant_path.read_bytes()
        self.assertEqual(m.main(['capture', '--session-id', record.name]), 0)
        backups = [p for p in approvals.iterdir() if p != grant_path]
        self.assertEqual([p.read_bytes() for p in backups], [first])
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)
        for backup in backups:
            backup.unlink()
        with mock.patch.object(m.os, 'replace', side_effect=OSError('boom')):
            self.assertNotEqual(m.main(['capture', '--session-id', record.name]), 0)
        self.assertEqual(grant_path.read_bytes(), first)
        self.assertEqual([p.name for p in approvals.iterdir() if '.tmp' in p.name], [], 'failed write left a temp file')
        # Existing record must stay a private regular file; only the newest five backups stay.
        grant_path.chmod(0o644)
        self.assertNotEqual(m.main(['capture', '--session-id', record.name]), 0)
        grant_path.chmod(0o600)
        grant_path.rename(grant_path.with_name('moved-record')); grant_path.symlink_to(grant_path.with_name('moved-record'))
        self.assertNotEqual(m.main(['capture', '--session-id', record.name]), 0)
        grant_path.unlink(); grant_path.with_name('moved-record').rename(grant_path)
        for _ in range(7):
            self.assertEqual(m.main(['capture', '--session-id', record.name]), 0)
        self.assertEqual(len([p for p in approvals.iterdir() if '.bak-' in p.name]), 5)
        first = grant_path.read_bytes()
        # Refusal exits non-zero with a message and leaves the record alone.
        write_profile(skip=entries[-1][0])
        with mock.patch('sys.stderr') as err:
            self.assertEqual(m.main(['capture', '--session-id', record.name]), 1)
        self.assertIn('refused', ''.join(c.args[0] for c in err.write.call_args_list))
        self.assertEqual(grant_path.read_bytes(), first)
        # Operator shells have no session environment: --session-id selects it.
        for name in env:
            os.environ.pop(name)
        os.environ['HARNESS_SESSION_STATE_HOME'] = str(state); os.environ['HARNESS_CODEX_BIN'] = str(fixture.codex_bin)
        write_profile()
        self.assertEqual(m.main(['capture', '--dry-run', '--session-id', record.name]), 0)
        self.assertEqual(m.main(['capture', '--dry-run', '--session-id', 'not-a-uuid']), 1)
        self.assertEqual(m.main(['capture', '--dry-run']), 1)
        self.assertNotEqual(original, first, 'fixture grant used a placeholder receipt')
        # Leave the fixture as found so the warm-preparation checks in build() stay meaningful.
        shutil.rmtree(approvals); approvals.mkdir(); grant_path.write_bytes(original); grant_path.chmod(0o600)
        profile.write_bytes(profile_before) if existed else profile.unlink()
        patch.stop()


class ApprovalFileSafetyTests(unittest.TestCase):
    def test_public_writable_and_hardlinked_files_are_rejected(self):
        spec=importlib.util.spec_from_file_location('approval_reader',ROOT/'bin/codex-hook-trust.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();p=root/'evidence';p.write_bytes(b'approved');p.chmod(0o666)
            with self.assertRaises((OSError,ValueError)):m.regular(p,root)
            p.chmod(0o644);os.link(p,root/'alias')
            with self.assertRaises((OSError,ValueError)):m.regular(p,root)

    def test_symlink_swap_during_open_is_rejected(self):
        spec=importlib.util.spec_from_file_location('approval_reader_swap',ROOT/'bin/codex-hook-trust.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();p=root/'evidence';p.write_bytes(b'approved');other=root/'other';other.write_bytes(b'foreign')
            original_open=os.open
            def swapped(path, flags, *args, **kwargs):
                if str(path)=='evidence':p.unlink();p.symlink_to(other)
                return original_open(path,flags,*args,**kwargs)
            with mock.patch.object(m.os,'open',side_effect=swapped):
                with self.assertRaises((OSError,ValueError)):m.regular(p,root)

class CallbackMappingSafetyTests(unittest.TestCase):
    def test_mapping_is_limited_to_verified_package_token_and_unique_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();current=root/'current';old=root/'old';other=root/'other'
            for d in (current,old,other):d.mkdir()
            name='codex-cmux-title-sync.py'
            for d in (current,old,other):(d/name).write_bytes(b'approved callback')
            helper=current/'codex-hook-trust.py';helper.write_bytes((ROOT/'bin/codex-hook-trust.py').read_bytes())
            spec=importlib.util.spec_from_file_location('mapping_fixture',helper);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
            approved=hashlib.sha256((old/name).read_bytes()).hexdigest();grant={'callbacks':{str(old/name):approved}}
            command='python3 '+str(current/name)
            self.assertEqual(m.approved_package_command(command,grant),'python3 '+str(old/name))
            with self.assertRaisesRegex(ValueError,re.escape(str(current))):m.approved_package_command('python3 '+str(other/name),grant)
            with self.assertRaises((OSError,ValueError)):m.approved_package_command('python3 "'+str(current/name)+'"',grant)
            with self.assertRaises((OSError,ValueError)):m.approved_package_command(command+' extra',grant)
            duplicate={'callbacks':{str(old/name):approved,str(other/name):approved}}
            with self.assertRaises((OSError,ValueError)):m.approved_package_command(command,duplicate)
            (current/name).write_bytes(b'changed callback')
            with self.assertRaises((OSError,ValueError)):m.approved_package_command(command,grant)

if __name__ == '__main__': unittest.main()
