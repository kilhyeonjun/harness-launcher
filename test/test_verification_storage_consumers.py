"""Consumer boundaries use injected policy decisions, never the host's policy.

The policy resolver has its own filesystem/volume validation tests. These tests
exercise real verifier subprocesses, copies, bytes, sockets and cleanup after
that boundary, without requiring a mounted external disk or Seatbelt.
"""
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('storage_headless', ROOT / 'bin/harness_headless.py')
hh = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hh)


class StorageConsumers(unittest.TestCase):
    def setUp(self):
        # Keep AF_UNIX addresses below the platform limit.
        self.tmp = tempfile.TemporaryDirectory(prefix='vs.', dir='/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.storage = self.base / 'ssd'
        self.storage.mkdir(mode=0o700)
        self.state = self.base / 'state'
        self.state.mkdir()
        self.candidate = self.base / 'candidate'
        self.candidate.mkdir()
        self.agent_tmp = self.base / 'agent'
        self.agent_tmp.mkdir()
        self.report = self.base / 'report.json'
        self.home = self.base / 'home'
        self.home.mkdir()
        self.sandbox = self.base / 'sandbox'
        self.sandbox.write_text('#!/bin/sh\nshift 2\nexec "$@"\n')
        self.sandbox.chmod(0o755)
        self.probe = '''import json, os, pathlib, socket, sys
p = pathlib.Path(os.environ['TMPDIR'])
assert os.environ['HARNESS_VERIFICATION_TMPDIR'] == str(p)
(p / 'bytes').write_bytes(b'verifier bytes')
s = socket.socket(socket.AF_UNIX)
s.bind(str(p / 's'))
pathlib.Path('copy-write').write_text('disposable')
pathlib.Path(sys.argv[1]).write_text(json.dumps({'tmp': str(p), 'cwd': os.getcwd(),
    'home': os.environ['HOME'], 'bytes': (p / 'bytes').read_text(), 'socket': (p / 's').exists()}))
s.close()
sys.exit(int(sys.argv[2]))
'''
        (self.candidate / 'probe.py').write_text(self.probe)
        self.session = SimpleNamespace(
            target={'entry': {'test': {'run': ['python', 'probe.py', str(self.report), '0'], 'timeout_min': 1}}},
            run_dir=str(self.state), python=sys.executable)
        self.env = {'HOME': str(self.home), 'TMPDIR': str(self.agent_tmp), 'SECRET': 'must-not-inherit'}

    def target_run(self, root, code=0):
        self.session.target['entry']['test']['run'][-1] = str(code)
        grants = []
        def profile(session, copy, tmp, env):
            grants.extend((copy, tmp))
            return 'exact child paths only'
        with mock.patch.object(hh, 'configured_root', return_value=root), \
             mock.patch.object(hh, 'SANDBOX_EXEC', str(self.sandbox)), \
             mock.patch.object(hh, 'verifier_profile', side_effect=profile), \
             mock.patch.object(hh, 'kill_lingering', return_value=[]), \
             tempfile.TemporaryFile(mode='w+', dir=self.base) as log:
            result = hh.run_target_verifier(self.session, str(self.candidate), log, self.env)
        return result, grants

    def test_target_routes_real_bytes_and_socket_to_private_children(self):
        result, grants = self.target_run(self.storage)
        self.assertTrue(result)
        report = json.loads(self.report.read_text())
        self.assertEqual(report['bytes'], 'verifier bytes')
        self.assertTrue(report['socket'])
        self.assertEqual(report['home'], str(self.home))
        self.assertEqual(grants, [report['cwd'], report['tmp']])
        for name in grants:
            self.assertEqual(Path(name).parent, self.storage)
            self.assertFalse(Path(name).exists())
        self.assertNotEqual(report['tmp'], str(self.agent_tmp))
        self.assertTrue(self.agent_tmp.exists())
        self.assertFalse((self.candidate / 'copy-write').exists())
        self.assertEqual(list(self.storage.iterdir()), [])

    def test_target_retains_artifacts_and_refuses_unresolved_nested_lifetime(self):
        probe = self.probe.replace('sys.exit(int(sys.argv[2]))',
                                  '(p / ".verification-lease-unresolved").touch(); sys.exit(0)')
        (self.candidate / 'probe.py').write_text(probe)
        result, grants = self.target_run(self.storage)
        self.assertFalse(result)
        report = json.loads(self.report.read_text())
        self.assertEqual((Path(report['tmp']) / 'bytes').read_bytes(), b'verifier bytes')
        self.assertEqual((Path(report['cwd']) / 'copy-write').read_text(), 'disposable')
        self.assertTrue(all(Path(path).is_dir() for path in grants))

    @unittest.skipUnless(Path('/private/tmp').is_dir(), 'legacy macOS temp directory unavailable')
    def test_target_unconfigured_retains_copy_and_temp_defaults_and_status(self):
        result, grants = self.target_run(None, code=7)
        self.assertFalse(result)
        self.assertEqual(Path(grants[0]).parent, self.state)
        self.assertEqual(Path(grants[1]).parent, Path('/private/tmp').resolve())
        self.assertTrue(all(not Path(path).exists() for path in grants))

    def test_target_timeout_removes_owned_scratch(self):
        self.session.target['entry']['test']['timeout_min'] = 0.02
        (self.candidate / 'probe.py').write_text(self.probe.replace(
            'sys.exit(int(sys.argv[2]))', 'import time; time.sleep(60)'))
        result, grants = self.target_run(self.storage)
        self.assertFalse(result)
        self.assertTrue(all(not Path(path).exists() for path in grants))
        self.assertEqual(list(self.storage.iterdir()), [])
        self.assertTrue(self.agent_tmp.exists())

    def test_target_invalid_policy_refuses_before_copy_or_launch(self):
        with mock.patch.object(hh, 'configured_root', side_effect=hh.VerificationStorageError('wrong UUID')), \
             mock.patch.object(hh.tempfile, 'mkdtemp') as allocate, \
             mock.patch.object(hh.subprocess, 'Popen') as launch:
            with self.assertRaises(hh.Refused):
                hh.run_target_verifier(self.session, str(self.candidate), io.StringIO(), self.env)
        allocate.assert_not_called()
        launch.assert_not_called()
        self.assertFalse(self.report.exists())

    def test_target_second_allocation_failure_removes_first(self):
        allocate = tempfile.mkdtemp
        calls = []
        def fail_second(*args, **kwargs):
            if calls:
                raise OSError('allocation refused')
            child = allocate(*args, **kwargs)
            calls.append(child)
            return child
        with mock.patch.object(hh, 'configured_root', return_value=self.storage), \
             mock.patch.object(hh.tempfile, 'mkdtemp', side_effect=fail_second):
            with self.assertRaises(OSError):
                hh.run_target_verifier(self.session, str(self.candidate), io.StringIO(), self.env)
        self.assertEqual(len(calls), 1)
        self.assertFalse(Path(calls[0]).exists())

    def test_target_child_start_failure_cleans_both_allocations(self):
        with mock.patch.object(hh, 'configured_root', return_value=self.storage), \
             mock.patch.object(hh, 'verifier_profile', return_value='profile'), \
             mock.patch.object(hh.subprocess, 'Popen', side_effect=OSError('spawn refused')), \
             mock.patch.object(hh, 'kill_lingering', return_value=[]):
            with self.assertRaises(OSError):
                hh.run_target_verifier(self.session, str(self.candidate), io.StringIO(), self.env)
        self.assertEqual(list(self.storage.iterdir()), [])

    def shell_fixture(self, headless=False, invalid=False, configured=True, code=0, fail_copy=False):
        bindir = self.base / 'bin'
        bindir.mkdir()
        # This is the consumer boundary's injected decision, not a second
        # policy implementation or a production config-path override.
        helper = bindir / 'verification_storage.py'
        selection = 'sys.exit("invalid storage")' if invalid else 'print(' + repr(str(self.storage) if configured else '') + ')'
        helper.write_text('import runpy,sys\nif len(sys.argv)>1:\n    runpy.run_path(' +
                          repr(str(ROOT / 'bin/verification_storage.py')) +
                          ',run_name="__main__")\nelse:\n    ' + selection + '\n')
        release = bindir / 'release'
        release.write_text('#!/bin/sh\nexit 0\n')
        release.chmod(0o755)
        repo = self.base / 'repo'
        repo.mkdir()
        (repo / 'core/bin').mkdir(parents=True)
        verifier = repo / 'core/bin/auto-deliver.sh'
        verifier.write_text('#!/bin/bash\n[[ "${1:-}" != --help ]] || exit 0\nexec ' +
                            shlex.quote(sys.executable) + ' probe.py ' + shlex.quote(str(self.report)) + ' ' + str(code) + '\n')
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                        '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], check=True)
        baseline = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        subprocess.run(['git', 'init', '-q', str(self.candidate)], check=True)
        subprocess.run(['git', '-C', str(self.candidate), 'fetch', '-q', str(repo), baseline], check=True)
        session = self.state / 'sessions/fixture'
        session.mkdir(parents=True)
        (session / 'source-root').write_text(str(repo))
        if headless:
            (session / 'headless').touch()
        source = (ROOT / 'bin/session-isolation.sh').read_text()
        # Source the actual function block, leaving the CLI dispatch untouched.
        functions = source[source.index('run_repository_verifier() {'):source.index('write_manifest_pathset() {')]
        script = self.base / 'run.sh'
        script.write_text('''#!/bin/bash
set -euo pipefail
state_home() { printf '%s\\n' "$STATE"; }
session_dir() { printf '%s/sessions/%s\\n' "$STATE" "$1"; }
phys() { (cd "$1" && pwd -P); }
session_git() { git "$@"; }
verifier_sandbox_profile() { printf '%s\\n' "$1" "$2" "$5" > "$GRANTS"; }
''' + functions + ('\nmktemp() { [[ "$*" != *verifier-copy.* ]] || return 1; command mktemp "$@"; }\n' if fail_copy else '') +
                          '\nrun_repository_verifier "$CANDIDATE" fixture "$REPO" "$BASELINE"\n')
        env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.agent_tmp), STATE=str(self.state),
                   OVERLAY_PATH_HELPER=str(bindir / 'unused'), RELEASE_CLIENT=str(release), SANDBOX_EXEC=str(self.sandbox),
                   GRANTS=str(self.base / 'grants'), CANDIDATE=str(self.candidate), REPO=str(repo), BASELINE=baseline)
        return subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True)

    def test_shell_normal_verifier_uses_private_temp_and_preserves_exit(self):
        completed = self.shell_fixture(code=9)
        self.assertEqual(completed.returncode, 9, completed.stderr)
        report = json.loads(self.report.read_text())
        self.assertEqual(Path(report['tmp']).parent, self.storage)
        self.assertEqual(report['cwd'], str(self.candidate))
        self.assertTrue(report['socket'])
        self.assertEqual(list(self.storage.iterdir()), [])
        self.assertTrue(self.agent_tmp.exists())

    def test_shell_sandbox_uses_only_exact_allocated_paths(self):
        completed = self.shell_fixture(headless=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(self.report.read_text())
        grants = (self.base / 'grants').read_text().splitlines()
        self.assertEqual(grants[:2], [report['cwd'], report['tmp']])
        self.assertEqual(len(grants), 3)
        for path in grants:
            self.assertEqual(Path(path).parent, self.storage)
            self.assertFalse(Path(path).exists())
        self.assertFalse((self.candidate / 'copy-write').exists())
        self.assertEqual(list(self.storage.iterdir()), [])

    def assert_shell_retains_unresolved(self, headless):
        probe = self.probe.replace('sys.exit(int(sys.argv[2]))',
                                  '(p / ".verification-lease-unresolved").touch(); sys.exit(0)')
        (self.candidate / 'probe.py').write_text(probe)
        completed = self.shell_fixture(headless=headless)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        report = json.loads(self.report.read_text())
        self.assertEqual((Path(report['tmp']) / 'bytes').read_bytes(), b'verifier bytes')
        self.assertEqual((Path(report['cwd']) / 'copy-write').read_text(), 'disposable')
        if headless:
            for path in (self.base / 'grants').read_text().splitlines():
                self.assertTrue(Path(path).is_dir())

    def test_shell_normal_refuses_unresolved_nested_lifetime(self):
        self.assert_shell_retains_unresolved(False)

    def test_shell_sandbox_refuses_unresolved_nested_lifetime(self):
        self.assert_shell_retains_unresolved(True)

    def test_shell_copy_allocation_failure_cleans_trusted_and_temp(self):
        completed = self.shell_fixture(headless=True, fail_copy=True)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertFalse(self.report.exists())
        self.assertEqual(list(self.storage.iterdir()), [])
        self.assertTrue(self.agent_tmp.exists())

    def test_shell_invalid_policy_refuses_before_clone(self):
        completed = self.shell_fixture(invalid=True)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertFalse(self.report.exists())
        self.assertEqual(list(self.storage.iterdir()), [])
        self.assertEqual(list(self.state.glob('verifier*')), [])

    @unittest.skipUnless(Path('/private/tmp').is_dir(), 'legacy macOS temp directory unavailable')
    def test_shell_unconfigured_keeps_internal_trusted_copy(self):
        completed = self.shell_fixture(headless=True, configured=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        grants = (self.base / 'grants').read_text().splitlines()
        self.assertEqual(Path(grants[0]).parent, self.state)
        self.assertEqual(Path(grants[1]).parent, Path('/private/tmp').resolve())
        self.assertEqual(Path(grants[2]).parent, self.state)
        self.assertTrue(all(not Path(path).exists() for path in grants))


if __name__ == '__main__':
    unittest.main()
