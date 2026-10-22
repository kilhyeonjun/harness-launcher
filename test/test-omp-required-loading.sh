#!/usr/bin/env bash
# Structural normal dispatcher fixture. Canonical compiler/template
# are source equal; fake file consumption does not prove native skill discovery.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Admit only the pinned synthetic default or an explicitly equal owned source.
HARNESS_TEST_OMP_SOURCE="$(python3 -I -S -B "$ROOT/test/omp-fixture-source.py")"
export HARNESS_TEST_OMP_SOURCE
python3 -I -S -B "$ROOT/test/test_omp_required_fixture_path.py"
python3 -I -S -B - "$ROOT" <<'PYTEST'
import hashlib, importlib.util, json, os, shlex, shutil, subprocess, sys, tempfile, unittest
from unittest.mock import patch
from pathlib import Path

REPO = Path(sys.argv.pop())
KERNEL = os.environ.get('HARNESS_TEST_OMP_SOURCE')

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def settings_yaml(text):
    # The compiler's overlay: block mappings of JSON scalars/flow lists only.
    import re
    root={}; stack=[(-1,root)]
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'): continue
        indent=len(line)-len(line.lstrip())
        key,value=re.fullmatch(r'("(?:[^"\\]|\\.)*"|[^:"]+):(?: (.*))?',line.strip()).groups()
        key=json.loads(key) if key.startswith('"') else key
        while stack[-1][0]>=indent: stack.pop()
        if value is None: stack[-1][1][key]={}; stack.append((indent,stack[-1][1][key]))
        else: stack[-1][1][key]=json.loads(value)
    return root
def put(path, value, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value if isinstance(value, str) else json.dumps(value))
    path.chmod(mode)

@unittest.skipUnless(KERNEL, 'set HARNESS_TEST_OMP_SOURCE to the reviewed canonical source fixture')
class RequiredLoading(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='omp-required-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root/'home'; self.profile = self.root/'registered profile'
        self.ns = self.root/'namespace'; self.capture = self.root/'consumed.json'
        for path in [self.home, self.profile, self.ns, *[self.ns/x for x in
                     ('home','agent','history','cwd','tmp','cache','config','state','data','native-cache')]]:
            path.mkdir(parents=True, mode=0o700)
        self.saved_home = os.environ.get('HOME'); os.environ['HOME'] = str(self.home)
        self.addCleanup(self.restore_home)
        self.registry = self.home/'.config/harness-launcher/profiles'
        put(self.registry/'ex', str(self.profile)+'\n')
        # Owned canonical test input. Compiler/template/shared guards stay byte
        # equal to the reviewed kernel, never a fake replacement compiler.
        kernel = Path(KERNEL)
        for name in ('runtime-contract.yaml','budgets.yaml','agents.yaml','commands.yaml','skills.yaml','claude-md.yaml'):
            put(self.profile/'.claude/source'/name, (kernel/'.claude/source'/name).read_text())
        for kind in ('agents','commands'):
            put(self.profile/'.claude/source'/f'{kind}.yaml', f'{kind}:\n  source: .claude/{kind}\n  entries: []\n')
        put(self.profile/'.claude/source/skills.yaml', 'skills:\n  source: .claude/skills\n  entries:\n    - name: fixture-required\n      path: fixture-required/SKILL.md\n      description: Required fixture skill\n      omp_mode: required\n      omp_required: true\n')
        put(self.profile/'.claude/skills/fixture-required/SKILL.md', '---\nname: fixture-required\ndescription: Fixture activation contract\n---\nCANONICAL_SKILL_MARKER\n')
        put(self.profile/'.claude/rules/required.md', '<rule_contract id="fixture-required">CANONICAL_REQUIRED_MARKER</rule_contract>\n')
        settings = (kernel/'.claude/source/settings.yaml').read_text().split('\nhooks:',1)[0]
        put(self.profile/'.claude/source/settings.yaml', settings+'\nhooks:\n  omp_default_mode: required\n  entries:\n    - event: PreToolUse\n      matcher: Bash\n      script: pre-bash-curl-block.sh\n      runtimes: claude, omp\n      omp_decision_only: true\n    - event: UserPromptSubmit\n      script: fixture-prompt.sh\n      runtimes: claude, omp\n      omp_decision_only: true\n')
        for name in ('core/scripts/harness_compile.py','core/scripts/omp_required_extension.ts',
                     'core/bin/harness-python','core/hooks/pre-bash-curl-block.sh','core/omp/policy-omp.md'):
            src = kernel/name; put(self.profile/name, src.read_text(), src.stat().st_mode&0o777)
        put(self.profile/'core/hooks/fixture-prompt.sh', '#!/bin/bash\nexit 0\n', 0o700)
        self.binary = self.root/'fake-native'
        # The owned fake reads policy/skill bytes instead of accepting argv alone.
        # It is not the original native resolver or an activation proof.
        put(self.binary, '#!'+sys.executable+'\n'+'''import hashlib,json,sys
from pathlib import Path
args=sys.argv[1:]
policy=next((a.split('=',1)[1] for a in args if a.startswith('--append-system-prompt=')),None)
if policy is None: raise SystemExit(84)
bundle=Path(policy).parent
m=json.loads((bundle/'selection.json').read_text())
assert 'CANONICAL_REQUIRED_MARKER' in Path(policy).read_text()
assert '--trusted-extension='+str(bundle/'required-extension.ts') in args
assert '--no-extensions' in args
assert not any(a.startswith('--harness-required-bundle') for a in args)
assert m['schema']==1 and m['runtime_version']=='18.11.3'
skills=[{'name':s['name'],'sha256':hashlib.sha256((bundle/s['path']).read_bytes()).hexdigest()} for s in m['selected_skills']]
assert [s['name'] for s in skills]==['fixture-required']
assert 'CANONICAL_SKILL_MARKER' in (bundle/'skills/fixture-required/SKILL.md').read_text()
Path('''+repr(str(self.capture))+''').write_text(json.dumps({'policy_sha256':hashlib.sha256(Path(policy).read_bytes()).hexdigest(),'skills':skills,'selection':m['effective_selection_sha256'],'inventory_admitted':False,'ready':False,'proof':'structural-fake-only','argv':args,'mode':(bundle/'omp-settings.yml').read_text() if (bundle/'omp-settings.yml').exists() else None}))
''', 0o555)
        put(self.ns/'.owner.json', {'schema':'p0-normal-omp-owner-v1','prefix':str(self.ns),
            'binary':str(self.binary),'asset_sha256':sha(self.binary),'identity':{'owner':'fixture'}})
        config = {'HARNESS_NAME':'fixture','HARNESS_PREFIX':'ex','HARNESS_SESSION_ISOLATION_DEFAULT':'0',
                  'HARNESS_OMP_BIN':str(self.binary),'HARNESS_OMP_ROOT':str(self.ns),'HARNESS_OMP_SHA256':sha(self.binary)}
        put(self.profile/'config/launcher.env', '\n'.join(k+'='+shlex.quote(v) for k,v in config.items())+'\n')
        runtime = self.home/'.local/state/kilhyeonjun-harness/launcher-runtimes'
        runtime.mkdir(parents=True, mode=0o700)
        runtime.chmod(0o700)
        self.snapshot = runtime/('a'*40)
        for src in (REPO/'bin').iterdir():
            if src.is_file(): put(self.snapshot/'bin'/src.name, src.read_text(), 0o500 if src.stat().st_mode&0o111 else 0o400)
        files = {str(p.relative_to(self.snapshot)):{'mode':p.stat().st_mode&0o777,'sha256':sha(p)} for p in (self.snapshot/'bin').iterdir()}
        put(self.snapshot/'manifest.json', {'version':'0.64.0','revision':'a'*40,'files':files}, 0o400)
        put(runtime/'current.json', {'version':'0.64.0','revision':'a'*40,'path':str(self.snapshot),'manifest_sha256':sha(self.snapshot/'manifest.json')})
        self.snapshot.chmod(0o500)
        (self.snapshot/'bin').chmod(0o500)
        self.addCleanup(self.unseal_snapshot)
        spec = importlib.util.spec_from_file_location('projection', self.snapshot/'bin/harness_omp_projection.py')
        self.p = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.p)
        self.assertTrue(callable(getattr(self.p,'prepare_required',None)), 'missing normal structural prepare')
        self.assertTrue(callable(getattr(self.p,'validate_required_prepared',None)), 'missing readonly prepared validation')
        self.publisher = self.p.Publisher()
        provenance = {'binding_sha256':'1'*64,'review_sha256':'2'*64,'selection_sha256':'3'*64,'operation_sha256':'4'*64,
                      'controller':{'native':'fixture','pane':'fixture','managed':'fixture'},'scope':'OMP3_CONFIGURATION','ssot':None}
        self.publisher.prepare(provenance)
        self.row = self.p.capture_row('ex',str(self.profile),str(self.snapshot/'bin/aliases.zsh'),str(self.binary),str(self.ns),
             '2099-01-01T00:00:00Z',{'version':'18.11.3',
             'source_revision':'96894a6147d8cc64b7e00ad3a7d7178fd93b9531'},provenance)
        self.publisher.publish('ex', self.row, self.publisher.token())
        # Match the continuation fixture: admit the selected real jq directory,
        # never a shared bin prefix that could shadow declared system children.
        jq = shutil.which('jq', path='/usr/bin:/bin') or shutil.which('jq')
        self.assertIsNotNone(jq, 'the OMP required-loading fixture requires real jq')
        jq_parent = str(Path(jq).resolve(strict=True).parent)
        preparation_path = ':'.join(dict.fromkeys([jq_parent, '/usr/bin', '/bin']))
        self.env = {'HOME':str(self.home),'PATH':preparation_path,'LC_ALL':'C','TERM':'dumb',
                    'HARNESS_CLAUDE_PLUGIN_MIRROR':'0','PYTHONDONTWRITEBYTECODE':'1'}
        # Readonly in-process and CLI checks must use the entry child's PATH.
        environment = patch.dict(os.environ, {'PATH': preparation_path})
        environment.start(); self.addCleanup(environment.stop)


    def install_mode_source(self):
        for name in ('core/omp/model_modes.py','.claude/source/omp-model-modes.json'):
            put(self.profile/name,(Path(KERNEL)/name).read_text())

    def overlay(self, mode):
        spec=json.loads((self.profile/'.claude/source/omp-model-modes.json').read_text())
        models={i:spec['modeled_selectors'][x] for i,x in spec['modes'][mode].items()}
        chains={'anthropic/claude-opus-5-5':['openai-codex/gpt-6.1-sol'],
                'openai-codex/gpt-6.1-sol':['anthropic/claude-opus-5-5']}
        return {'modelRoles':{w:models[i]+':'+e for w,(i,e) in spec['workloads'].items()},
                'task':{'agentModelOverrides':{a:'@advisor' if i=='reviewer' else '@task'
                                               for a,i in spec['named_agent_roles'].items()}},
                'retry':{'modelFallback':True,'fallbackOn':'usage-limit',
                         'fallbackRevertPolicy':'cooldown-expiry','fallbackChains':chains},
                'contextPromotion':{'enabled':False}}

    def public_exec(self,args):
        return subprocess.run(['/bin/zsh',str(self.snapshot/'bin/harness-exec'),str(self.profile),'omp',*args],
            cwd=self.profile,env=self.env,input='',text=True,capture_output=True,timeout=30)

    def file_state(self):
        return {str(p):(sha(p),p.stat().st_mode,p.stat().st_mtime_ns)
                for p in self.root.rglob('*') if p.is_file()}

    def unseal_snapshot(self):
        self.snapshot.chmod(0o700)
        (self.snapshot/'bin').chmod(0o700)

    def test_MM4_same_public_sealed_healthy_and_retired_check_refused(self):
        healthy = self.public_exec([])
        self.assertEqual(healthy.returncode, 0, healthy.stderr)
        self.assertEqual(json.loads(self.capture.read_text())['proof'],'structural-fake-only')
        self.install_mode_source()
        self.capture.unlink()
        before=self.file_state()
        # The fork-only metadata check is retired; it is now an unknown option.
        result=self.public_exec(['--model-mode-check','gpt-only'])
        self.assertEqual(result.returncode,2,result.stderr)
        self.assertFalse(self.capture.exists())
        self.assertEqual(before,self.file_state())

    def test_MM4_four_modes_and_fresh_default_bind_settings_overlay(self):
        self.install_mode_source()
        for mode in (None,'gpt-only','opus-only','hybrid-gpt-lead','hybrid-opus-lead'):
            with self.subTest(mode=mode):
                args=[] if mode is None else ['--model-mode',mode]
                self.run_entry(args)
                loaded=json.loads(self.capture.read_text())
                self.assertEqual(settings_yaml(loaded['mode']),self.overlay(mode or 'hybrid-opus-lead'))
                wanted,_=self.p.model_mode_request(str(self.profile),args)
                self.assertEqual(wanted['selected_mode'],mode or 'hybrid-opus-lead')
                self.assertFalse(any(a.startswith('--model-mode') for a in loaded['argv']))
                bundle=self.profile/'.harness/omp'/loaded['selection']
                self.assertIn('--config='+str(bundle/'omp-settings.yml'),loaded['argv'])
                self.assertFalse((bundle/'model-mode.json').exists())
                manifest=json.loads((bundle/'selection.json').read_text())
                self.assertIn('model-mode:'+(mode or 'hybrid-opus-lead'),manifest['bundle_ids'])
                prepared=self.p.validate_required_prepared(str(self.profile),
                    str(self.snapshot/'bin/aliases.zsh'),str(self.ns/'cwd'),str(self.binary),
                    str(self.ns),str(bundle/'selection.json'))
                self.assertEqual(prepared['model_mode'],
                                 {'mode_id':wanted['selected_mode'],'recipe_sha256':wanted['recipe_sha256']})
                self.assertFalse(prepared['ready']);self.assertFalse(prepared['inventory_admitted'])

    def test_MM4_literal_values_and_double_dash_are_not_controls(self):
        self.install_mode_source()
        prompt='--model-mode opus-only\n--model-mode-check gpt-only'
        artifact,argv=self.p.model_mode_request(str(self.profile),['--tools','Read','--',prompt])
        self.assertEqual(artifact['selected_mode'],'hybrid-opus-lead')
        self.assertEqual(argv,['--tools','Read','--',prompt])
        _,argv=self.p.model_mode_request(str(self.profile),['--model-mode=gpt-only','--','--model-mode-check'])
        self.assertEqual(argv,['--','--model-mode-check'])

    def test_MM4_malformed_override_stock_and_stale_source_stop_without_effects(self):
        self.install_mode_source()
        before=self.file_state()
        bad=(['--model-mode'],['--model-mode','foreign'],
             ['--model-mode','gpt-only','--model-mode','opus-only'],
             ['--model-mode-check','gpt-only','extra'],['--model-mode','gpt-only','--thinking','low'],
             ['--model-mode','gpt-only','--model=foreign'])
        for args in bad:
            with self.subTest(args=args):
                result=self.public_exec(args)
                self.assertEqual(result.returncode,2,result.stderr)
                self.assertFalse(self.capture.exists())
                self.assertEqual(before,self.file_state())
        self.run_entry(['--model-mode','gpt-only'])
        loaded=json.loads(self.capture.read_text())
        bundle=self.profile/'.harness/omp'/loaded['selection']
        source=self.profile/'.claude/source/omp-model-modes.json'
        value=json.loads(source.read_text());value['default']='gpt-only'
        source.write_text(json.dumps(value,indent=2)+'\n')
        before=self.file_state()
        with self.assertRaises(self.p.ProjectionError):
            self.p.validate_required_prepared(str(self.profile),str(self.snapshot/'bin/aliases.zsh'),
                str(self.ns/'cwd'),str(self.binary),str(self.ns),str(bundle/'selection.json'))
        self.assertEqual(before,self.file_state())

    def test_MM4_public_entry_each_mode_same_fallback_chains(self):
        self.install_mode_source()
        for mode in ('gpt-only','opus-only','hybrid-gpt-lead','hybrid-opus-lead'):
            with self.subTest(mode=mode):
                result=self.public_exec(['--model-mode',mode])
                self.assertEqual(result.returncode,0,result.stderr)
                loaded=json.loads(self.capture.read_text())
                self.assertEqual(settings_yaml(loaded['mode']),self.overlay(mode))
                self.assertEqual(settings_yaml(loaded['mode'])['retry']['fallbackChains'],
                                 self.overlay('gpt-only')['retry']['fallbackChains'])
                self.capture.unlink()

    def restore_home(self):
        if self.saved_home is None: os.environ.pop('HOME',None)
        else: os.environ['HOME'] = self.saved_home

    def run_entry(self, args=(), expected=0, cwd=None):
        self.capture.unlink(missing_ok=True)
        result = subprocess.run(['/bin/zsh','-f','-c','source "$1/bin/aliases.zsh"; shift; _harness_launcher_run "$@"',
             'fixture',str(self.snapshot),str(self.profile),'omp',*args], cwd=cwd or self.profile, env=self.env,
             input='',text=True,capture_output=True,timeout=30)
        self.assertEqual(result.returncode,expected, result.stderr)
        self.assertEqual(self.capture.exists(),expected==0, result.stderr)
        return result

    def test_normal_entry_prepares_policy_and_selected_skill_without_native_admission(self):
        self.run_entry()
        loaded = json.loads(self.capture.read_text())
        self.assertEqual([s['name'] for s in loaded['skills']],['fixture-required'])
        self.assertRegex(loaded['policy_sha256'], '^[0-9a-f]{64}$')
        self.assertFalse(loaded['ready']); self.assertFalse(loaded['inventory_admitted'])
        bundle = next(p for p in (self.profile/'.harness/omp').iterdir() if p.is_dir())
        manifest = json.loads((bundle/'selection.json').read_text())
        workspace = manifest['workspace']
        self.assertEqual(workspace,str(self.ns/'cwd'))
        before = {str(f):sha(f) for f in self.profile.rglob('*') if f.is_file()}
        prepared = self.p.validate_required_prepared(str(self.profile),str(self.snapshot/'bin/aliases.zsh'),
            workspace,str(self.binary),str(self.ns),str(bundle/'selection.json'))
        self.assertFalse(prepared['ready']); self.assertFalse(prepared['inventory_admitted'])
        self.assertEqual(prepared['expected_inventory'][0]['name'],'fixture-required')
        result = subprocess.run([sys.executable,'-I','-S','-B',str(self.snapshot/'bin/harness_omp_projection.py'),
            'validate-required-prepared',str(self.profile),str(self.snapshot/'bin/aliases.zsh'),workspace,
            str(self.binary),str(self.ns),str(bundle/'selection.json')],capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout),prepared)
        self.assertEqual(before,{str(f):sha(f) for f in self.profile.rglob('*') if f.is_file()})
        with self.assertRaises(self.p.ProjectionError):
            self.p.validate_required_prepared(str(self.profile),str(self.snapshot/'bin/aliases.zsh'),
                workspace,str(self.binary),str(self.ns),str(self.root/'foreign/selection.json'))
        (bundle/'policy.md').write_text('changed')
        with self.assertRaises(self.p.ProjectionError):
            self.p.validate_required_prepared(str(self.profile),str(self.snapshot/'bin/aliases.zsh'),
                workspace,str(self.binary),str(self.ns),str(bundle/'selection.json'))

    def test_required_disabling_and_startup_operands_refuse_before_child(self):
        for args in (['--no-skills'],['--no-extensions'],['--skills=foreign'],['--','fixture prompt'],['--print'],['--harness-required-bundle=/foreign'],['--','--harness-required-bundle=/foreign'],['--trusted-extension=/foreign.ts'],['--trusted-extension','/foreign.ts']):
            with self.subTest(args=args): self.run_entry(args,2)

    def test_fork_release_version_is_refused_and_malformed_release_is_invalid(self):
        # A row published for the retired fork stays readable, but its version is
        # not an upstream semver, so the compiler refuses the schema-1 selection.
        self.publisher.block('ex', self.publisher.token(), self.row['provenance'], 'fixture-handover')
        fork = {'version':'18.11.3-kh.w07.mm.1','source_revision':'1'*40,
                'contract_id':'w07.required-resolver-consumer.v1','upstream_base_version':'18.11.3',
                'upstream_base_revision':'96894a6147d8cc64b7e00ad3a7d7178fd93b9531',
                'source_patch_sha256':'2'*64,'build_provenance_sha256':'3'*64}
        row = self.p.capture_row('ex',str(self.profile),str(self.snapshot/'bin/aliases.zsh'),str(self.binary),
            str(self.ns),'2099-01-01T00:00:00Z',fork,self.row['provenance'])
        self.publisher.publish('ex',row,self.publisher.token())
        self.run_entry(expected=2)
        bad = dict(fork); bad.pop('build_provenance_sha256')
        with self.assertRaises(self.p.ProjectionError): self.p.check_binary_release(bad)

    def test_source_missing_or_current_revoked_refuses_before_child(self):
        template = self.profile/'core/scripts/omp_required_extension.ts'
        template.unlink(); self.run_entry(expected=2)
        self.publisher.block('ex', self.publisher.token(), self.row['provenance'], 'fixture-revoked', revoke=True)
        self.run_entry(expected=2)

unittest.main()
PYTEST
