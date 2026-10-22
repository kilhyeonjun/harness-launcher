#!/usr/bin/env zsh
# Real dispatcher/entry, fake native only; no real OMP/auth/history is opened.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -B - "$ROOT" <<'PYTEST'
from pathlib import Path
import hashlib, json, os, shlex, signal, subprocess, sys, tempfile, time

repo=Path(sys.argv[1]); passed=0; observations=[]
import pwd
# The account (passwd) home, never the caller's $HOME, and its exact OMP bash prefix.
account_home=pwd.getpwuid(os.getuid()).pw_dir
def shell_prefix(home):
    return "export HOME='"+home+"'; unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_DATA_HOME;"
def omp_native_path():
    """Env contract v2 PATH: /usr/bin:/bin plus the CPU's Homebrew bin when it
    is a real user/root-owned directory without other-write (group write only
    for the Darwin admin group). Computed from the host, not the caller PATH."""
    import platform, stat as _stat
    tool = '/opt/homebrew/bin' if platform.machine() == 'arm64' else '/usr/local/bin'
    try: s = os.lstat(tool)
    except OSError: return '/usr/bin:/bin'
    ok = (_stat.S_ISDIR(s.st_mode) and s.st_uid in (0, os.getuid()) and not s.st_mode & 0o002 and
          (not s.st_mode & 0o020 or (sys.platform == 'darwin' and s.st_gid == 80)))
    return '/usr/bin:/bin' + (':' + tool if ok else '')
with tempfile.TemporaryDirectory(prefix='omp-routing-') as tmp:
    root=Path(tmp).resolve(); home=root/'caller-home'; profile=root/'project with spaces'; ns=root/'normal'; tools=root/'tools'; capture=root/'capture.json'; wire=root/'wire.argv'; ready=root/'ready'; release=root/'release'
    leaves=['home','agent','history','cwd','tmp','cache','config','state','data','native-cache']
    for p in [home,profile/'config',profile/'projects/sub dir',tools,ns,*[ns/x for x in leaves]]:
        p.mkdir(parents=True,exist_ok=True);p.chmod(0o700)
    binary=tools/'native-omp'
    calls=root/'native-calls.jsonl'; behavior=root/'native-behavior'
    # Use this real interpreter rather than Apple's /usr/bin/python3 shim,
    # which injects Xcode/SDK environment before it reaches the fake body.
    binary.write_text('#!'+sys.executable+'\nimport json,os,sys,signal\nfrom pathlib import Path\nPath('+repr(str(capture))+').write_text(json.dumps({"argv":sys.argv[1:],"cwd":os.getcwd(),"env":dict(os.environ)}))\nwith Path('+repr(str(calls))+').open("a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\nmode=Path('+repr(str(behavior))+').read_text() if Path('+repr(str(behavior))+').exists() else ""\nif mode=="signal": os.kill(os.getpid(),signal.SIGTERM)\nif sys.argv[1:]==["--","fixture-wait"] or mode=="wait":\n import time\n Path('+repr(str(ready))+').touch()\n while not Path('+repr(str(release))+').exists(): time.sleep(0.02)\nraise SystemExit(23 if mode=="exit" or sys.argv[1:]==["--", "fixture-exit"] else 0)\n')
    binary.chmod(0o555); digest=hashlib.sha256(binary.read_bytes()).hexdigest()
    marker=ns/'.owner.json'
    owner={'schema':'p0-normal-omp-owner-v1','identity':{'CODEX_THREAD_ID':'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'},'prefix':str(ns),'binary':str(binary),'asset_sha256':digest}
    marker.write_text(json.dumps(owner));marker.chmod(0o600)
    config=profile/'config/launcher.env'
    def configuration(**override):
        values={'HARNESS_NAME':'fixture','HARNESS_PREFIX':'fixture','HARNESS_SESSION_ISOLATION_DEFAULT':'0','HARNESS_OMP_BIN':str(binary),'HARNESS_OMP_ROOT':str(ns),'HARNESS_OMP_SHA256':digest}
        values.update(override)
        config.write_text('\n'.join(k+'='+shlex.quote(v) for k,v in values.items())+'\n')
    configuration()
    for name in ['claude','codex','gum']:
        p=tools/name;p.write_text('#!/bin/sh\nexit 97\n');p.chmod(0o700)
    env={'HOME':str(home),'PATH':str(tools)+':/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','TERM':'dumb','TMPDIR':str(root),'HARNESS_CLAUDE_PLUGIN_MIRROR':'0','PYTHONDONTWRITEBYTECODE':'1','OPENAI_API_KEY':'fixture-secret-must-not-leak','ANTHROPIC_API_KEY':'fixture-secret-must-not-leak','NODE_OPTIONS':'fixture-must-not-leak','HARNESS_SESSION_HEARTBEAT_SECONDS':'0.05','HARNESS_POST_EDIT_CODEX_SYNC':'0','HARNESS_POST_COMMIT_CODEX_SYNC':'0','HARNESS_KIRO_BIN':str(tools/'absent-kiro')}
    state=root/'sessions';env['HARNESS_SESSION_STATE_HOME']=str(state)
    # The new selector is activated only after first-rollout preparation. Keep
    # this legacy-routing fixture explicitly never-enrolled in its own HOME.
    import importlib.util
    registry=home/'.config/harness-launcher/profiles';registry.mkdir(parents=True,mode=0o700)
    spec=importlib.util.spec_from_file_location('omp_projection_fixture',repo/'bin/harness_omp_projection.py')
    projection=importlib.util.module_from_spec(spec);spec.loader.exec_module(projection)
    previous_home=os.environ.get('HOME');os.environ['HOME']=str(home)
    try:
        assert Path.home()==home and binary.parent==tools
        projection.Publisher().prepare({'binding_sha256':'1'*64,'review_sha256':'2'*64,'selection_sha256':'3'*64,'operation_sha256':'4'*64,'controller':{'native':'fixture','pane':'fixture','managed':'fixture'},'scope':'OMP3_CONFIGURATION','ssot':None})
    finally:
        if previous_home is None:os.environ.pop('HOME',None)
        else:os.environ['HOME']=previous_home
    # Public entry verifies a complete current closure before legacy selection.
    # Keep the original never-enrolled adapter cases inside a synthetic runtime.
    import shutil
    runtime = home / '.local/state/kilhyeonjun-harness/launcher-runtimes'
    runtime.mkdir(parents=True, mode=0o700)
    snapshot = runtime / ('a' * 40)
    (snapshot / 'bin').mkdir(parents=True)
    inventory = {}
    for source in (repo / 'bin').iterdir():
        if source.is_file() and not source.is_symlink():
            destination = snapshot / 'bin' / source.name
            shutil.copyfile(source, destination)
            mode = 0o500 if source.stat().st_mode & 0o111 else 0o400
            destination.chmod(mode)
            inventory['bin/' + source.name] = {
                'mode': mode,
                'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
            }
    manifest = snapshot / 'manifest.json'
    manifest.write_text(json.dumps({
        'version': '0.66.0', 'revision': snapshot.name, 'files': inventory,
    }))
    manifest.chmod(0o400)
    for directory, _, _ in os.walk(snapshot):
        Path(directory).chmod(0o500)
    current = runtime / 'current.json'
    current.write_text(json.dumps({
        'version': '0.66.0', 'revision': snapshot.name, 'path': str(snapshot),
        'manifest_sha256': hashlib.sha256(manifest.read_bytes()).hexdigest(),
    }))
    current.chmod(0o600)
    expected_env={'HOME':str(ns/'home'),'PATH':omp_native_path(),'LANG':'C','LC_ALL':'C','TMPDIR':str(ns/'tmp'),'XDG_CACHE_HOME':str(ns/'cache'),'XDG_CONFIG_HOME':str(ns/'config'),'XDG_STATE_HOME':str(ns/'state'),'XDG_DATA_HOME':str(ns/'data'),'PI_CODING_AGENT_DIR':str(ns/'agent'),'PI_CODING_AGENT_SESSION_DIR':str(ns/'history'),'PI_NATIVES_DIR':str(ns/'native-cache'),'TERM':'xterm-256color','PI_AUTO_QA':'0','PI_SHELL_PREFIX':shell_prefix(account_home)}
    # Calibrate only the fake interpreter startup, not the OMP contract. macOS
    # adds this nonsecret field even to a directly launched empty-env Python.
    baseline=subprocess.run([sys.executable,'-c','import os,json;print(json.dumps(dict(os.environ)))'],env=expected_env,text=True,capture_output=True,check=True)
    fake_env=json.loads(baseline.stdout)
    assert {k:v for k,v in fake_env.items() if k in expected_env}==expected_env
    assert set(fake_env)-set(expected_env) <= {'__CF_USER_TEXT_ENCODING'}
    spy='function /usr/bin/env() { builtin printf \'%s\\0\' "$@" > '+shlex.quote(str(wire))+'; command /usr/bin/env "$@"; }; '
    def allocation():
        return [(str(p.relative_to(root)),p.is_dir(),p.stat().st_size,p.stat().st_mtime_ns)
                for base in (state,profile/'.harness',home/'.local/state') if base.exists()
                for p in sorted([base,*base.rglob('*')])]
    def count():return len(calls.read_text().splitlines()) if calls.exists() else 0
    def run(args,expected=0,entry=False,tail=None,cwd=None,no_allocate=False,stdin=b'',caller=None,extra=None):
        global passed
        capture.unlink(missing_ok=True);wire.unlink(missing_ok=True)
        before=count();before_allocation=allocation()
        if entry:command=['/bin/zsh',str(repo/'bin/harness-exec'),str(profile),*args]
        else:command=['/bin/zsh','-f','-c','source "$1/bin/aliases.zsh"; '+spy+'shift; _harness_launcher_run "$@"','test',str(repo),str(profile),*args]
        result=subprocess.run(command,cwd=profile,env={**env,**(caller or {})},input=stdin,capture_output=True,timeout=20)
        assert result.returncode==expected,(args,result.returncode,expected,result.stderr.decode())
        assert count()-before==(0 if tail is None else 1),('native invocation count',args,result.stdout.decode()[-2000:],result.stderr.decode()[-2000:])
        if no_allocate:assert allocation()==before_allocation,('management allocated or changed launcher state',args)
        if tail is None:
            assert not capture.exists(),('refusal launched native',args)
        else:
            assert capture.exists(),('native not called',args,result.stderr.decode())
            got=json.loads(capture.read_text());assert got['argv']==tail,(args,got)
            assert got['cwd']==str(cwd or ns/'cwd'),(args,got['cwd'])
            extra=dict(extra or {})
            if 'HARNESS_SESSION_ID' in got['env']:
                # Isolated sessions: the real runner supplies the whole valid tuple.
                import re
                tuple_keys=['HARNESS_SESSION_ID','HARNESS_SOURCE_ROOT','HARNESS_SESSION_ROOT','HARNESS_RUN_DIR']
                assert re.fullmatch(r'[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}',got['env']['HARNESS_SESSION_ID']),got['env']
                assert all(got['env'][k].startswith('/') for k in tuple_keys[1:]),got['env']
                extra={**{k:got['env'][k] for k in tuple_keys},**extra}
            assert got['env']=={**fake_env,**extra},(args,got['env'])
            if not entry:
                outgoing=wire.read_bytes().split(b'\0')[:-1]
                assert [x.decode() for x in outgoing]==['-u','_',*[k+'='+v for k,v in {**expected_env,**(extra or {})}.items()],str(binary),*tail],(args,outgoing)
        observations.append({'input':args,'exit':result.returncode,'entry':entry,'native':json.loads(capture.read_text()) if capture.exists() else None,'outgoing':wire.read_bytes().split(b'\0')[:-1] if wire.exists() else None})
        passed+=1
    # Break caught: OMP falls through into the Claude route rather than native.
    run(['omp','--version'],tail=['--version'])
    # Env contract v2 (decision 038). Optional groups are forwarded whole or not
    # at all; nothing else from the caller leaks. Every case sets or clears the
    # HARNESS_*/HERDR_* variables explicitly, so a developer's own herdr
    # environment cannot change the result.
    uid='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    tuple_env={'HARNESS_SESSION_ID':uid,'HARNESS_SOURCE_ROOT':'/src','HARNESS_SESSION_ROOT':'/sess','HARNESS_RUN_DIR':'/run'}
    herdr_env={'HERDR_ENV':'1','HERDR_SOCKET_PATH':'/tmp/herdr.sock','HERDR_PANE_ID':'p_1'}
    leak={'HERDR_PANE_ID_X':'x','HARNESS_PREFIX':'leak','CODEX_THREAD_ID':'leak','PI_CODING_AGENT_DIR':'/leak','PI_AUTO_QA':'1',
          'GH_TOKEN':'caller-token-must-not-leak','XDG_CONFIG_HOME':'/leak-xdg','PI_SHELL_PREFIX':'leak;'}
    # Through the public dispatcher the runner discards the caller's own session
    # tuple and the runtime filter drops a herdr pane without a live socket, so
    # nothing optional (and nothing from `leak`) reaches the native.
    for caller in [{},{**tuple_env,**herdr_env,**leak}]:
        run(['omp','--version'],tail=['--version'],caller=caller,extra={})
    # Direct call of the env builder: the tuple is what the outer runner set.
    def native_env(setup,expected=0,path=None,full=False):
        capture.unlink(missing_ok=True)
        script='source "$1/bin/aliases.zsh"; HARNESS_OMP_ROOT="$2" HARNESS_OMP_BIN="$3"; '+setup+'; _harness_launcher_omp_native "$2/cwd" --version'
        done=subprocess.run(['/bin/zsh','-f','-c',script,'test',str(repo),str(ns),str(binary)],cwd=profile,env={**env,**leak,**({'PATH':path} if path else {})},capture_output=True,timeout=20)
        assert done.returncode==expected,(setup,done.returncode,done.stderr.decode())
        if expected:
            assert not capture.exists(),('refusal launched native',setup)
            return done
        got=json.loads(capture.read_text())['env']
        return (got,done) if full else got
    def assign(values):return '; '.join(k+'='+shlex.quote(v) for k,v in values.items())
    for values,extra in [
        (tuple_env,tuple_env),
        ({**tuple_env,**herdr_env},{**tuple_env,**herdr_env,'HERDR_RESUME_ARGV':''}),
        ({**tuple_env,'HARNESS_SESSION_ID':'not-a-uuid'},{}),
        ({k:v for k,v in tuple_env.items() if k!='HARNESS_RUN_DIR'},{}),
        ({**tuple_env,'HARNESS_SOURCE_ROOT':'rel/path'},{}),
        ({**tuple_env,'HARNESS_SESSION_ROOT':''},{}),
        ({**tuple_env,'HARNESS_RUN_DIR':'run'},{}),
        (herdr_env,{**herdr_env,'HERDR_RESUME_ARGV':''}),
        ({**herdr_env,'HERDR_ENV':'0'},{}),
        ({**herdr_env,'HERDR_SOCKET_PATH':'rel.sock'},{}),
        ({**herdr_env,'HERDR_PANE_ID':''},{}),
        ({k:v for k,v in herdr_env.items() if k!='HERDR_SOCKET_PATH'},{}),
        ({**tuple_env,**{**herdr_env,'HERDR_ENV':'0'}},tuple_env),
        ({**{**tuple_env,'HARNESS_SESSION_ID':'x'},**herdr_env},{**herdr_env,'HERDR_RESUME_ARGV':''}),
    ]:
        got=native_env(assign(values))
        assert got=={**fake_env,**extra},(values,got)
        passed+=1
    # OMP bash tool account shell: PI_SHELL_PREFIX restores the passwd home
    # (never the caller's $HOME) and drops the namespace XDG roots for the
    # model's commands only. Breaks caught: caller HOME, unquoted or missing
    # prefix, admitting a relative/missing/shell-special home.
    def passwd(home):
        return "_harness_launcher_passwd_record(){ print -r -- "+shlex.quote('u:*:501:20::0:0:G:E:C:O:S:'+home+':/bin/zsh')+"; }"
    spaced=root/'account home'
    spaced.mkdir()
    got=native_env(passwd(str(spaced)))
    assert got=={**fake_env,'PI_SHELL_PREFIX':shell_prefix(str(spaced))},got
    shell=subprocess.run(['/bin/sh','-c',got['PI_SHELL_PREFIX']+' printf "%s|%s" "$HOME" "${XDG_CONFIG_HOME-unset}"'],
                         env={'HOME':'/wrong','XDG_CONFIG_HOME':'/wrong'},capture_output=True,text=True,check=True)
    assert shell.stdout==str(spaced)+'|unset',shell.stdout
    passed+=1
    for bad in ['relative/home','',str(root/'missing'),str(marker),str(root)+"/it's",str(root)+'/$(touch x)',str(root)+'/a`b',str(root)+'/a;b']:
        if bad.startswith(str(root)+'/') and not bad.endswith(('missing','.json')):Path(bad).mkdir(exist_ok=True)
        done=native_env(passwd(bad),expected=2)
        assert b'OMP_ACCOUNT_HOME_INVALID' in done.stderr,(bad,done.stderr)
        passed+=1
    done=native_env('_harness_launcher_passwd_record(){ return 1; }',expected=2)
    assert b'OMP_ACCOUNT_HOME_INVALID' in done.stderr,done.stderr
    passed+=1
    # Per-harness GH_TOKEN: forwarded only when harness_gh_token_load succeeds
    # for this profile, never the caller's value, never empty, never printed.
    ghdir=root/'gh-stub';ghdir.mkdir()
    token='ghs_fixture_token_value_never_printed'
    gh=ghdir/'gh';gh.write_text('#!/bin/sh\n[ "$1 $2 $3 $4" = "auth token --user fixture-user" ] || exit 9\nmode=$(cat '+shlex.quote(str(ghdir/'mode'))+' 2>/dev/null)\n[ "$mode" = fail ] && exit 1\n[ "$mode" = empty ] && exit 0\nprintf "%s\\n" '+token+'\n');gh.chmod(0o700)
    ghprofile=root/'gh profile';(ghprofile/'config').mkdir(parents=True)
    ghpath=str(ghdir)+':/usr/bin:/bin'
    for mode,ghconfig,setup,forwarded in [
        ('','github_user: fixture-user\n','',True),
        ('fail','github_user: fixture-user\n','',False),
        ('empty','github_user: fixture-user\n','',False),
        ('','other: x\n','',False),
        ('','github_user: fixture-user\n','HARNESS_HEADLESS=1; ',False),
    ]:
        (ghdir/'mode').write_text(mode);(ghprofile/'config/config.yaml').write_text(ghconfig)
        wire.unlink(missing_ok=True)
        got,done=native_env(spy+setup+'HARNESS_DIR='+shlex.quote(str(ghprofile)),path=ghpath,full=True)
        assert got=={**fake_env,**({'GH_TOKEN':token} if forwarded else {})},(mode,ghconfig,setup,got)
        # The token travels in environ only: never in env's argv or any output.
        assert wire.read_bytes().split(b'\0')[:2]==[b'-u',b'_'] and token.encode() not in wire.read_bytes()
        assert token.encode() not in done.stdout+done.stderr
        passed+=1
    # An export the launcher cannot clear refuses instead of leaking.
    done=native_env('typeset -rx READONLY_CALLER_VAR=leak',expected=2)
    assert b'OMP_ENV_NOT_CLOSED' in done.stderr,done.stderr
    passed+=1
    # Launcher tool dirs (A2): appended after /usr/bin:/bin in candidate order,
    # only for a real directory owned by the user/root with no other-write;
    # group write only for the Darwin admin group (gid 80). Breaks caught:
    # following a symlink, admitting a world/group-writable dir, reordering.
    tooldirs=root/'tooldirs';tooldirs.mkdir()
    def tooldir(name,mode,gid=None):
        p=tooldirs/name;p.mkdir();p.chmod(mode)
        if gid is not None:os.chown(p,-1,gid)
        return str(p)
    good=tooldir('good',0o755);good2=tooldir('good2',0o700)
    other_write=tooldir('other-write',0o757)
    (tooldirs/'link').symlink_to(good);link=str(tooldirs/'link')
    plain=tooldirs/'file';plain.write_text('');plain.chmod(0o755)
    cases=[([good],[good]),([other_write],[]),([link],[]),([str(plain)],[]),
           ([str(tooldirs/'missing')],[]),(['relative'],[]),([good,other_write,good2],[good,good2]),
           ([good2,good],[good2,good])]
    if os.getgid()!=80:cases.append(([tooldir('group-write',0o775)],[]))
    if 80 in os.getgroups():cases.append(([tooldir('admin-group',0o775,80)],[tooldirs.joinpath('admin-group').as_posix()]))
    for candidates,admitted in cases:
        setup='_harness_launcher_omp_tool_dirs(){ print -rl -- '+' '.join(shlex.quote(c) for c in candidates)+'; }'
        got=native_env(setup)
        assert got['PATH']==':'.join(['/usr/bin:/bin',*admitted]),(candidates,got['PATH'])
        passed+=1
    # The constant itself: arm64 selects /opt/homebrew/bin, any other CPU /usr/local/bin.
    for cpu,dirs in [('arm64','/opt/homebrew/bin'),('x86_64','/usr/local/bin')]:
        done=subprocess.run(['/bin/zsh','-f','-c','source "$1/bin/aliases.zsh"; CPUTYPE=$2; _harness_launcher_omp_tool_dirs','test',str(repo),cpu],
                            env={**env,**leak},capture_output=True,text=True,timeout=20)
        assert done.returncode==0 and done.stdout==dirs+'\n',(cpu,done.stdout,done.stderr)
        passed+=1
    # HERDR_RESUME_ARGV comes only from the continuation caller's own local.
    # Breaks caught: forwarding a caller/exported value, or forwarding without the triple.
    resume='["harness-exec","/h a\\"b","omp","--session-resume","'+'a'*32+'","--"]'
    local_resume='f(){ local _harness_omp_herdr_resume='+shlex.quote(resume)+'; _harness_launcher_omp_native "$2/cwd" --version; }; '
    herdr_out={**herdr_env,'HERDR_RESUME_ARGV':''}
    for values,setup,extra in [
        (herdr_env,'',herdr_out),
        ({**herdr_env,'HERDR_RESUME_ARGV':'["evil"]'},'',herdr_out),
        ({**herdr_env,'_harness_omp_herdr_resume':'["evil"]'},'export _harness_omp_herdr_resume; ',herdr_out),
        ({**herdr_env,'_harness_omp_herdr_resume':'["evil"]'},'',herdr_out),
        (herdr_env,local_resume,{**herdr_env,'HERDR_RESUME_ARGV':resume}),
        ({**herdr_env,'HERDR_ENV':'0'},local_resume,{}),
    ]:
        capture.unlink(missing_ok=True)
        call=setup+('f "$@"' if setup==local_resume else '_harness_launcher_omp_native "$2/cwd" --version')
        script='source "$1/bin/aliases.zsh"; HARNESS_OMP_ROOT="$2" HARNESS_OMP_BIN="$3"; '+assign(values)+'; '+call
        done=subprocess.run(['/bin/zsh','-f','-c',script,'test',str(repo),str(ns),str(binary)],cwd=profile,env={**env,**leak},capture_output=True,timeout=20)
        assert done.returncode==0,(values,setup,done.stderr.decode())
        got=json.loads(capture.read_text())['env']
        assert got=={**fake_env,**extra},(values,setup,got)
        passed+=1
    # Exact management tuples must bypass workspace/session preparation. These
    # expectations come from the public command contract, not its classifier.
    management=[['--version'],['--help'],['login','anthropic'],['login','openai-codex'],
                ['models','ls','anthropic','--json','--kind','chat','--no-extensions'],
                ['models','ls','openai-codex','--json','--kind','chat','--no-extensions']]
    for tail in management:run(['omp',*tail],tail=tail,no_allocate=True)
    owner_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    for control in [[],['--no-isolated'],['--isolated'],['--isolated-session',owner_id]]:
        for tail in management[2:]:
            run(['--cwd',str(profile/'projects/sub dir'),*control,'omp',*tail],tail=tail,no_allocate=True)
    configuration(HARNESS_SESSION_ISOLATION_DEFAULT='1')
    for tail in management[2:]:run(['omp',*tail],tail=tail,no_allocate=True)
    configuration()
    for tail in management[2:]:run(['omp',*tail],entry=True,tail=tail,no_allocate=True)
    invalid_management=[['login'],['login','other'],['login','anthropic','extra'],['login','anthropic','--'],
        ['login','--','anthropic'],['--passthrough','login','anthropic'],
        ['models'],['models','ls'],['models','ls','other','--json','--kind','chat','--no-extensions'],
        ['models','ls','anthropic'],['models','ls','anthropic','--kind','chat','--json','--no-extensions'],
        ['models','ls','anthropic','--json','--kind','embedding','--no-extensions'],
        ['models','ls','anthropic','--json','--kind','chat'],
        [*management[4],'extra'],[*management[5],'--'],['--version','extra'],['--help','--']]
    for tail in invalid_management:run(['omp',*tail],expected=2,no_allocate=True)
    # The same pin/owner/link/mode checks protect nonpublic management.
    configuration(HARNESS_OMP_SHA256='0'*64);run(['omp',*management[2]],expected=2,no_allocate=True);configuration()
    marker.write_text(json.dumps({**owner,'asset_sha256':'0'*64}));run(['omp',*management[3]],expected=2,no_allocate=True);marker.write_text(json.dumps(owner))
    marker.chmod(0o644);run(['omp',*management[4]],expected=2,no_allocate=True);marker.chmod(0o600)
    binary.chmod(0o755);run(['omp',*management[5]],expected=2,no_allocate=True);binary.chmod(0o555)
    linked_management=tools/'linked-management';linked_management.symlink_to(binary)
    configuration(HARNESS_OMP_BIN=str(linked_management));run(['omp',*management[2]],expected=2,no_allocate=True);configuration()
    linked_namespace=root/'linked-namespace';linked_namespace.symlink_to(ns)
    configuration(HARNESS_OMP_ROOT=str(linked_namespace));run(['omp',*management[2]],expected=2,no_allocate=True);configuration()
    # Exit/signal statuses propagate and only acquired kernel locks unwind.
    lock=ns/'.launcher.lock';lock_identity=(lock.stat().st_dev,lock.stat().st_ino)
    for mode,status in [('exit',23),('signal',143)]:
        behavior.write_text(mode)
        run(['omp',*management[2]],expected=status,tail=management[2],no_allocate=True)
        behavior.unlink()
        run(['omp',*management[3]],tail=management[3],no_allocate=True)
        assert (lock.stat().st_dev,lock.stat().st_ino)==lock_identity
    for args,tail in [(['omp','--help'],['--help']),(['omp'],[]),(['omp','omp','--','text'],['omp','--','text']),(['omp','--model','claude','--','a b',''],['--model','claude','--','a b','']),(['omp','--','--resume','literal'],['--','--resume','literal'])]:
        run(args,tail=tail)
    run(['omp','--','fixture-exit'],expected=23,tail=['--','fixture-exit'])
    owner_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    for control in [[],['--no-isolated'],['--isolated-session',owner_id]]:
        run(['--cwd',str(profile/'projects/sub dir'),*control,'omp','--version'],tail=['--version'],cwd=profile/'projects/sub dir')
    run(['omp','--help'],entry=True,tail=['--help'],cwd=profile)
    for args in [['claude','omp'],['omp','claude'],['omp','codex'],['omp','--resume','not-a-uuid'],['omp','--model','claude','--restore','not-a-uuid'],['omp','--profile','foreign'],['omp','--session-dir','foreign'],['omp','--cwd','foreign'],['omp','--from-claude'],['omp','auth'],['omp','--unknown'],['--isolated-session'],['--cwd']]:
        run(args,expected=2)
    configuration(HARNESS_OMP_SHA256='0'*64);run(['omp','--version'],expected=2);configuration()
    marker.chmod(0o644);run(['omp','--version'],expected=2);marker.chmod(0o600)
    configuration(HARNESS_OMP_BIN=str(tools/'absent'));run(['omp','--version'],expected=2);configuration()
    linked=tools/'linked-omp';linked.symlink_to(binary)
    configuration(HARNESS_OMP_BIN=str(linked));run(['omp','--version'],expected=2);configuration()
    marker.write_text(json.dumps({**owner,'asset_sha256':'0'*64}));run(['omp','--version'],expected=2);marker.write_text(json.dumps(owner))
    configuration(HARNESS_OMP_ROOT=str(root/'not-prepared'));run(['omp','--version'],expected=2);configuration()
    # Launcher-only locator must not be supplied as an option or operand,
    # including never-enrolled routing. No state allocation or native call.
    for tail in [['--harness-required-bundle=/foreign'],['--harness-required-bundle','/foreign'],
                 ['--','--harness-required-bundle=/foreign']]:
        run(['omp',*tail],expected=2,no_allocate=True)
    # Real isolated-session helper, owner lease, cwd rebinding and finish path.
    # All repositories/history remain disposable and the native remains fake.
    subprocess.run(['git','init','-q','-b','main',str(profile)],env=env,check=True)
    subprocess.run(['git','-C',str(profile),'add','config/launcher.env'],env=env,check=True)
    subprocess.run(['git','-c','core.hooksPath=/dev/null','-c','user.name=fixture','-c','user.email=fixture@example.invalid','-C',str(profile),'commit','-qm','fixture'],env=env,check=True)
    run(['--cwd',str(profile/'projects/sub dir'),'--isolated','omp','omp','--','text'],tail=['omp','--','text'],cwd=profile/'projects/sub dir')
    records=list((state/'sessions').iterdir());assert len(records)==1,records
    actual_owner=records[0].name
    run(['--cwd',str(profile/'projects/sub dir'),'--isolated-session',actual_owner,'omp','omp','--','text'],tail=['omp','--','text'],cwd=profile/'projects/sub dir')
    assert 'state=CLOSED' in (records[0]/'journal').read_text()
    assert len(list((state/'sessions').iterdir()))==1
    configuration(HARNESS_SESSION_ISOLATION_DEFAULT='1')
    run(['omp','--model','resume','--','literal'],tail=['--model','resume','--','literal'])
    configuration()
    # Fresh sessions share the normal-home lease; management stays exclusive.
    command=['/bin/zsh','-f','-c','source "$1/bin/aliases.zsh"; shift; _harness_launcher_run "$@"','test',str(repo),str(profile),'omp','--','fixture-wait']
    active=subprocess.Popen(command,cwd=profile,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        deadline=time.monotonic()+10
        while not ready.exists() and active.poll() is None and time.monotonic()<deadline:time.sleep(.02)
        assert ready.exists(),('native barrier missing',active.poll())
        run(['omp'],tail=[])
        busy_identity=(lock.stat().st_dev,lock.stat().st_ino)
        for tail in management[2:]:run(['omp',*tail],expected=2,no_allocate=True)
        assert (lock.stat().st_dev,lock.stat().st_ino)==busy_identity
    finally:
        release.touch()
        out,err=active.communicate(timeout=10)
    assert active.returncode==0,(active.returncode,err)
    run(['omp'],tail=[])
    # Bare menu: the third composer is OMP; the runner then starts the same
    # fresh native session after its own checks. A bad pin is refused there and
    # the menu returns (here to EOF) without launching native.
    run(['--no-isolated'],tail=[],stdin=b'3\n')
    configuration(HARNESS_OMP_SHA256='0'*64);run(['--no-isolated'],stdin=b'3\n');configuration()
    # Another runtime from the same menu cannot queue an OMP launch through the
    # handoff file: only the menu's own OMP exit status is honored.
    planted=tools/'claude';original=planted.read_text()
    planted.write_text('#!/bin/sh\nfor d in "$TMPDIR"/harness-omp-handoff.*; do printf "omp\\n" > "$d/argv"; done\nexit 0\n')
    run(['--no-isolated'],stdin=b'1\n1\n2\n1\n');planted.write_text(original)
    # Without any OMP configuration the menu does not offer it at all.
    (profile/'.harness/launcher-history').unlink(missing_ok=True)
    configuration(HARNESS_OMP_BIN='',HARNESS_OMP_ROOT='',HARNESS_OMP_SHA256='')
    run(['--no-isolated'],stdin=b'3\n');configuration()
    # Terminate only the owned fake process group, then prove reacquisition.
    ready.unlink();release.unlink();behavior.write_text('wait')
    signaled=subprocess.Popen(command[:-2]+management[2],cwd=profile,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try:
        deadline=time.monotonic()+10
        while not ready.exists() and signaled.poll() is None and time.monotonic()<deadline:time.sleep(.02)
        assert ready.exists(),('management signal barrier missing',signaled.poll())
        run(['omp'],expected=2)
        os.killpg(signaled.pid,signal.SIGTERM)
        out,err=signaled.communicate(timeout=10)
        assert signaled.returncode in (-signal.SIGTERM,143),(signaled.returncode,err)
    finally:
        if signaled.poll() is None:os.killpg(signaled.pid,signal.SIGKILL);signaled.communicate(timeout=10)
        behavior.unlink()
    run(['omp',*management[3]],tail=management[3],no_allocate=True)
    # A preexisting symlink/hardlink or public lock cannot be adopted.
    lock=ns/'.launcher.lock';lock.unlink();lock.symlink_to(marker)
    run(['omp',*management[2]],expected=2,no_allocate=True);assert lock.is_symlink();lock.unlink()
    os.link(marker,lock);run(['omp',*management[2]],expected=2,no_allocate=True);assert marker.stat().st_nlink==2;lock.unlink()
    lock.write_text('');lock.chmod(0o644);run(['omp',*management[2]],expected=2,no_allocate=True);assert lock.exists();lock.unlink()
    print('SAVED_FAKE_PROOF='+json.dumps({'schema':'omp-routing-fake-v1','startup_baseline':fake_env,'cases':[{**x,'outgoing':[b.decode() for b in x['outgoing']] if x['outgoing'] is not None else None} for x in observations]},separators=(',',':')))
    print('PASS:',passed,'OMP real-entry/dispatcher argv/env/cwd/exit and fail-closed cases; native fake only')
    for directory, _, files in os.walk(snapshot):
        Path(directory).chmod(0o700)
        for name in files:
            (Path(directory) / name).chmod(0o600)
PYTEST
