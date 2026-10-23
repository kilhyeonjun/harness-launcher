import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('receipt', ROOT / 'bin/omp_print_receipt.py')
protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocol)
NONCE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
SESSION = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'


class PrintReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.path = self.root / 'receipt.json'
        self.env = dict(zip(protocol.KEYS, (SESSION, '/source', '/session', '/run')))

    def ready(self, denied=False):
        protocol.receipt(str(self.path), NONCE, 'create', self.env)
        row = json.loads(self.path.read_text())
        row.update(native_session=SESSION, native_pid=os.getpid(), started=True, denied=denied)
        self.path.write_text(json.dumps(row))
        identity = self.root / 'identity.json'
        identity.write_text(json.dumps({'nonce': NONCE, 'native_session': SESSION, 'native_pid': os.getpid()}))
        identity.chmod(0o600)

    def test_started_allow_and_deny(self):
        self.ready()
        self.assertEqual(protocol.receipt(str(self.path), NONCE, 'collect', self.env, os.getpid()), 0)
        row = json.loads(self.path.read_text()); row['denied'] = True
        self.path.write_text(json.dumps(row))
        self.assertEqual(protocol.receipt(str(self.path), NONCE, 'collect', self.env, os.getpid()), 2)

    def test_missing_startup_nonce_session_schema_tuple_and_mode_tampering(self):
        self.ready()
        original = json.loads(self.path.read_text())
        for key, value in [('nonce', SESSION), ('native_session', ''), ('native_session', NONCE), ('schema', True),
                           ('tuple', {}), ('native_pid', os.getpid() + 1), ('started', False), ('denied', 1)]:
            self.path.write_text(json.dumps({**original, key: value}))
            with self.assertRaises(ValueError):
                protocol.receipt(str(self.path), NONCE, 'collect', self.env, os.getpid())
        self.path.write_text(json.dumps(original)); self.path.chmod(0o644)
        with self.assertRaises(ValueError):
            protocol.receipt(str(self.path), NONCE, 'collect', self.env, os.getpid())

    def test_symlink_and_hardlink_receipts_refused(self):
        self.ready(); target = self.root / 'target'; self.path.rename(target)
        self.path.symlink_to(target)
        with self.assertRaises(OSError):
            protocol.receipt(str(self.path), NONCE, 'collect', self.env, os.getpid())
        self.path.unlink(); os.link(target, self.path)
        with self.assertRaises(ValueError):
            protocol.receipt(str(self.path), NONCE, 'collect', self.env, os.getpid())

    def test_state_home_requires_genuine_absolute_existing_real_directory(self):
        self.assertEqual(protocol.state_home(str(self.root)), str(self.root))
        link = self.root / 'link'; link.symlink_to(self.root, target_is_directory=True)
        for value in ('relative', str(link), str(self.root / 'missing'), str(self.path)):
            with self.assertRaises(ValueError):
                protocol.state_home(value)

    def launch(self, mode, outcome, caller=None, local_tuple=False, forward_signal=None):
        namespace = self.root / 'native'
        for child in ('tmp', 'cwd', 'home', 'agent', 'history', 'cache', 'config', 'state', 'data', 'native-cache'):
            (namespace / child).mkdir(parents=True, exist_ok=True)
        finished = namespace / 'tmp/native-finished'
        finished.unlink(missing_ok=True)
        binary = self.root / 'native-fixture'
        binary.write_text('#!' + sys.executable + '\n' + '''import json,os,signal,sys,time
from pathlib import Path
p=Path(os.environ['HARNESS_OMP_PRINT_RECEIPT'])
r=json.loads(p.read_text())
assert r['nonce']==os.environ['HARNESS_OMP_PRINT_NONCE']
assert r['nonce']!='caller-nonce'
assert 'CALLER_AUTHORITY' not in os.environ
assert os.environ['HARNESS_SESSION_STATE_HOME']==str(p.parents[2].parent)
assert r['tuple']=={k:os.environ.get(k,'') for k in ('HARNESS_SESSION_ID','HARNESS_SOURCE_ROOT','HARNESS_SESSION_ROOT','HARNESS_RUN_DIR')}
outcome=sys.argv[-1]
if outcome!='missing':
 r.update(started=True,native_session='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',native_pid=os.getpid(),denied=outcome=='denied')
 identity=p.with_name('identity.json')
 identity.write_text(json.dumps({k:r[k] for k in ('nonce','native_session','native_pid')}))
 identity.chmod(0o600)
 if outcome=='tamper':r['nonce']='caller-nonce'
 p.write_text(json.dumps(r))
if outcome=='terminal':
 assert os.isatty(0), 'terminal stdin was detached'
 print(int(input())+1)
if outcome=='signal':
 def stop(sig,frame):
  time.sleep(0.15)
  assert p.is_file(), 'receipt removed before native shutdown finished'
  Path(os.environ['TMPDIR'],'native-finished').write_text(str(sig))
  sys.exit(17)
 for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,stop)
 print(json.dumps({'native_pid':os.getpid(),'wrapper_pid':os.getppid()}),flush=True)
 signal.pause()
''')
        binary.chmod(0o700)
        tuple_setup = ''
        if local_tuple:
            tuple_setup = f'HARNESS_SESSION_ID={SESSION} HARNESS_SOURCE_ROOT=/source HARNESS_SESSION_ROOT=/session HARNESS_RUN_DIR=/run\n'
        script = '''source "$1/bin/aliases.zsh"
function harness_python3_resolve() { builtin print -r -- "$fixture_python"; }
fixture_python="$2"
''' + tuple_setup + '''HARNESS_OMP_ROOT="$3" HARNESS_OMP_BIN="$4" omp_required_selected=true
_harness_launcher_omp_native "$3/cwd" "${@:5}"
'''
        argv = ['/bin/zsh', '-f', '-c', script, 'fixture', str(ROOT), sys.executable,
                str(namespace), str(binary), *mode, outcome]
        env = {'HOME': str(self.root), 'PATH': '/usr/bin:/bin',
               'HARNESS_SESSION_STATE_HOME': str(self.root),
               'HARNESS_OMP_PRINT_RECEIPT': '/caller/receipt', 'HARNESS_OMP_PRINT_NONCE': 'caller-nonce',
               'CALLER_AUTHORITY': 'secret', **(caller or {})}
        if outcome == 'terminal':
            process = subprocess.Popen(['/usr/bin/script', '-q', '/dev/null', *argv],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            try:
                process.stdin.write(b'41\n')
                process.stdin.flush()
                # Keep the terminal open until the child consumes input and exits.
                process.wait(timeout=10)
                stdout, stderr = process.communicate(timeout=5)
                return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
        if forward_signal is None:
            return subprocess.run(argv, input=b'', capture_output=True, env=env, timeout=10)
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        ready = {}
        try:
            self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'native startup timed out')
            ready = json.loads(process.stdout.readline())
            os.kill(ready['wrapper_pid'], forward_signal)
            stdout, stderr = process.communicate(b'', timeout=10)
            self.assertEqual(finished.read_text(), str(int(forward_signal)))
            return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
        except BaseException:
            for pid in set([process.pid, *ready.values()]):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.communicate(timeout=5)
            raise

    def test_parent_wrapper_maps_denials_and_invalid_receipts_to_two(self):
        for mode in (['-p'], ['--mode', 'json'], []):
            for outcome, expected in [('allowed', 0), ('denied', 2), ('missing', 2), ('tamper', 2)]:
                result = self.launch(mode, outcome)
                self.assertEqual(result.returncode, expected, result.stderr.decode())

    def test_shell_local_continuation_tuple_matches_native_receipt(self):
        result = self.launch(['-p'], 'allowed', local_tuple=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_terminal_stdin_remains_interactive_and_readable(self):
        result = self.launch(['-p'], 'terminal')
        self.assertEqual(result.returncode, 0, result.stdout.decode(errors='replace'))
        self.assertIn(b'42\r\n', result.stdout)

    def test_signals_keep_native_alive_until_shutdown_finishes(self):
        for forwarded in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=forwarded):
                result = self.launch(['-p'], 'signal', forward_signal=forwarded)
                self.assertEqual(result.returncode, 17, result.stderr.decode())

    def test_public_mode_admission_is_text_json_only(self):
        for argv, expected in [(['--mode','text'],0), (['--mode=json'],0),
                               (['--mode','rpc'],2), (['--mode=rpc-ui'],2), (['--mode','acp'],2)]:
            result=subprocess.run(['/bin/zsh','-f','-c',
                'source "$1/bin/aliases.zsh"; shift; _harness_launcher_omp_check_args "$@"',
                'fixture',str(ROOT),*argv],capture_output=True,timeout=5)
            self.assertEqual(result.returncode,expected,result.stderr.decode())

    def test_relative_spoofed_state_aborts_before_native(self):
        result = self.launch(['-p'], 'allowed', {'HARNESS_SESSION_STATE_HOME': 'relative'})
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
