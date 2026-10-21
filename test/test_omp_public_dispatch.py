"""UNRUN test draft for an owned checkout AFTER independent design approval.

All namespaces, profile/provenance labels, registry files and binary are synthetic
inside TemporaryDirectory. This never imports production configuration or auth.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
OLD_REVISION = '5faf9b91411faeb33f48beb0ab8b69a8575a0813'
OLD_MANIFEST_SHA256 = '9257d40f68c855094699dd44b26cb6a47895173c74324f161f374306ea2a94f7'
OLD_SNAPSHOT_CAPSULE = None  # Mandatory explicit runner argument; never an env lookup.


class PublicOmpDispatch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name).resolve()
        self.source = ROOT / 'bin'
        self.package = self.home / 'Cellar/harness-launcher/0.66.0/share/harness-launcher'
        self.package.mkdir(parents=True)
        for p in self.source.iterdir():
            if p.is_file() and not p.is_symlink():
                shutil.copy2(p, self.package / p.name)
        opt = self.home / 'opt'
        opt.mkdir()
        (opt / 'harness-launcher').symlink_to(self.package.parents[1], target_is_directory=True)
        self.registry = self.home / '.config/harness-launcher/profiles'
        self.registry.mkdir(parents=True, mode=0o700)
        self.harness = self.home / 'synthetic kh'
        (self.harness / 'config').mkdir(parents=True)
        (self.harness / 'config/launcher.env').write_text(
            'HARNESS_NAME="synthetic kh"\nHARNESS_PREFIX="kh"\n'
            'HARNESS_SESSION_ISOLATION_DEFAULT="0"\n')
        self.write(self.registry / 'kh', str(self.harness).encode() + b'\n')
        self.public = self.home / '.local/bin/kh'
        self.public.parent.mkdir(parents=True)
        self.public.symlink_to(self.package / 'harness-profile')
        self.runtime = self.home / '.local/state/kilhyeonjun-harness/launcher-runtimes'
        self.runtime.mkdir(parents=True, mode=0o700)
        self.assertIsNotNone(OLD_SNAPSHOT_CAPSULE, 'exact old closure custody required')
        old = OLD_SNAPSHOT_CAPSULE
        self.assertEqual(OLD_MANIFEST_SHA256, self.sha(old / 'manifest.json'))
        self.old_manifest = (old / 'manifest.json').read_bytes()
        manifest = json.loads(self.old_manifest)
        self.assertEqual(OLD_REVISION, manifest['revision'])
        self.old_package = self.home / 'old-package-bin'
        self.old_package.mkdir()
        for name in manifest['files']:
            if name.startswith('bin/'):
                p = old / name
                self.assertFalse(p.is_symlink())
                self.assertEqual(manifest['files'][name]['sha256'], self.sha(p))
                shutil.copy2(p, self.old_package / p.name)
        self.old_public = self.home / 'old-public/kh'
        self.old_public.parent.mkdir()
        self.old_public.symlink_to(self.old_package / 'harness-profile')
        self.snapshot = self.runtime / OLD_REVISION
        if self._testMethodName == 'test_repaired_current_snapshot_entry_does_not_reexec_forever':
            self.snapshot = self.runtime / ('a' * 40)
            (self.snapshot / 'bin').mkdir(parents=True)
            inventory = {}
            for p in self.package.iterdir():
                dest = self.snapshot / 'bin' / p.name
                shutil.copy2(p, dest)
                mode = 0o500 if os.access(p, os.X_OK) else 0o400
                dest.chmod(mode)
                inventory['bin/' + p.name] = {'mode': mode, 'sha256': self.sha(dest)}
            self.write(self.snapshot / 'manifest.json', self.encode({
                'version': '0.66.0', 'revision': 'a' * 40, 'files': inventory}), 0o400)
        else:
            self.snapshot.mkdir()
            for name, item in manifest['files'].items():
                source = old / name
                self.assertFalse(source.is_symlink())
                self.assertEqual(item['sha256'], self.sha(source))
                dest = self.snapshot / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, dest)
                dest.chmod(item['mode'])
            self.write(self.snapshot / 'manifest.json', self.old_manifest, 0o400)
        for root, dirs, files in os.walk(self.snapshot):
            Path(root).chmod(0o500)
        self.snapshot.chmod(0o500)
        self.write(self.runtime / 'current.json', self.encode({
            'version': '0.66.0', 'revision': self.snapshot.name, 'path': str(self.snapshot),
            'manifest_sha256': self.sha(self.snapshot / 'manifest.json')}))
        self.binary = self.home / 'fixture-omp'
        self.witness = self.home / 'fake-help-invocations.jsonl'
        fake = (
            f'#!{sys.executable}\n'
            'import json, os, sys\n'
            'if sys.argv[1:] != ["--help"]: raise SystemExit(99)\n'
            f'with open({str(self.witness)!r}, "a") as out:\n'
            '    out.write(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd(),\n'
            '                          "exe": os.path.realpath(sys.argv[0])}) + "\\n")\n'
            'print("SYNTHETIC_OMP_HELP")\n')
        self.write(self.binary, fake.encode(), 0o555)
        self.namespace = self.home / 'synthetic-native'
        self.namespace.mkdir(mode=0o700)
        for name in ('home', 'agent', 'history', 'cwd', 'tmp', 'cache', 'config', 'state', 'data', 'native-cache'):
            (self.namespace / name).mkdir(mode=0o700)
        self.write(self.namespace / '.owner.json', self.encode({
            'schema': 'p0-normal-omp-owner-v1', 'prefix': str(self.namespace),
            'binary': str(self.binary), 'asset_sha256': self.sha(self.binary),
            'identity': {'test': 'synthetic-only'}}))
        spec = importlib.util.spec_from_file_location('omp_dispatch_fixture', self.package / 'harness_omp_projection.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        provenance = {'binding_sha256': '1' * 64, 'review_sha256': '2' * 64,
                      'selection_sha256': '3' * 64, 'operation_sha256': '4' * 64,
                      'controller': {'native': 'synthetic', 'pane': 'synthetic', 'managed': 'synthetic'},
                      'scope': 'OMP3_CONFIGURATION', 'ssot': None}
        with mock.patch.object(self.module.Path, 'home', return_value=self.home):
            publisher = self.module.Publisher()
            publisher.prepare(provenance)
            row = self.module.capture_row('kh', str(self.harness),
                str(self.snapshot / 'bin/aliases.zsh'), str(self.binary), str(self.namespace),
                '2099-01-01T00:00:00Z', {'version': '18.11.3', 'source_revision': 'b' * 40}, provenance)
            publisher.publish('kh', row, publisher.token())
        self.config_root = self.home / '.config/harness-launcher/omp-projection-v1'
        self.before = {n: (self.config_root / n).read_bytes() for n in ('enrollment.json', 'state.json')}
        self.current_before = (self.runtime / 'current.json').read_bytes()
        self.snapshot_before = {str(p.relative_to(self.snapshot)): p.read_bytes()
                                for p in self.snapshot.rglob('*') if p.is_file()}
        (self.home / 'tmp').mkdir()
        self.nested = self.harness / 'nested work/child with spaces'
        self.nested.mkdir(parents=True)

    def child_env(self):
        # Deliberate test-only allowlist, including every consulted registry override.
        # No inherited launcher/history/auth/shell/Python configuration is forwarded.
        return {
            'HOME': str(self.home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
            'HARNESS_PYTHON_BIN': sys.executable, 'LC_ALL': 'C',
            'HARNESS_PROFILE_HOME': str(self.registry.parent),
            'HARNESS_PROFILE_BIN_DIR': str(self.public.parent),
            'XDG_CONFIG_HOME': str(self.home / '.config'),
            'XDG_STATE_HOME': str(self.home / '.local/state'),
            'XDG_DATA_HOME': str(self.home / '.local/share'),
            'XDG_CACHE_HOME': str(self.home / '.cache'), 'TMPDIR': str(self.home / 'tmp'),
        }

    @staticmethod
    def encode(value):
        return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def write(path, value, mode=0o600):
        path.write_bytes(value)
        path.chmod(mode)

    def run_entry(self, argv):
        return subprocess.run(argv, cwd=self.harness, env=self.child_env(), stdin=subprocess.DEVNULL,
                              capture_output=True, timeout=10, check=False)

    def assert_preserved(self):
        self.assertEqual(self.before, {n: (self.config_root / n).read_bytes() for n in self.before})

    def assert_snapshot_preserved(self):
        self.assertEqual(self.current_before, (self.runtime / 'current.json').read_bytes())
        self.assertEqual(self.snapshot_before, {
            str(p.relative_to(self.snapshot)): p.read_bytes()
            for p in self.snapshot.rglob('*') if p.is_file()})

    def calls(self):
        if not self.witness.exists():
            return []
        return [json.loads(line) for line in self.witness.read_text().splitlines()]

    def tearDown(self):
        for root, dirs, files in os.walk(self.home):
            Path(root).chmod(0o700)
            for name in files:
                p = Path(root) / name
                if not p.is_symlink():
                    p.chmod(0o600)
        self.tmp.cleanup()

    def test_public_package_dispatches_actual_snapshot_after_healthy_control(self):
        # This first control proves the real selector/profile/join/namespace and
        # fake native --help are legal before targeting the package route.
        direct = self.run_entry(['/bin/zsh', str(self.snapshot / 'bin/harness-exec'),
                                 str(self.harness), 'omp', '--help'])
        self.assertEqual((0, b'SYNTHETIC_OMP_HELP\n'), (direct.returncode, direct.stdout), direct.stderr)
        public = self.run_entry([str(self.public), 'omp', '--help'])
        # BEFORE implementation the actual package/opt consumer fails BINDING;
        # this outcome assertion is the own RED, not a missing mode/import.
        self.assertEqual((0, b'SYNTHETIC_OMP_HELP\n'), (public.returncode, public.stdout), public.stderr)
        self.assertEqual(2, len(self.calls()))
        self.assertEqual([['--help'], ['--help']], [c['argv'] for c in self.calls()])
        self.assertTrue(all(c['exe'] == str(self.binary) for c in self.calls()))
        self.assert_snapshot_preserved()
        self.assert_preserved()

    def test_exact_old_package_public_binding_red_control(self):
        direct = self.run_entry(['/bin/zsh', str(self.snapshot / 'bin/harness-exec'),
                                 str(self.harness), 'omp', '--help'])
        self.assertEqual((0, b'SYNTHETIC_OMP_HELP\n'), (direct.returncode, direct.stdout), direct.stderr)
        old = self.run_entry([str(self.old_public), 'omp', '--help'])
        self.assertEqual(2, old.returncode)
        self.assertEqual(b'', old.stdout)
        self.assertIn(b'OMP_BINDING_MISMATCH', old.stderr)
        self.assertEqual(1, len(self.calls()))
        self.assert_snapshot_preserved()
        self.assert_preserved()

    def test_fixture_allowlist_ignores_controlled_external_overrides(self):
        external = self.home / 'controlled-external'
        registry = external / 'profile-home/profiles'
        registry.mkdir(parents=True)
        config = external / 'harness/config'
        config.mkdir(parents=True)
        marker = external / 'REACHED'
        self.write(registry / 'kh', str(config.parent).encode() + b'\n')
        self.write(config / 'launcher.env', f'touch {str(marker)!r}\nreturn 97\n'.encode())
        poison = {
            'HARNESS_PROFILE_HOME': str(registry.parent),
            'XDG_CONFIG_HOME': str(external / 'xdg'),
            'HARNESS_PROFILE_BIN_DIR': str(external / 'bin'),
            'HARNESS_CODEX_HISTORY_LEASE_FD': '99999',
            'HARNESS_SOURCE_ROOT': str(external / 'source'),
            'HARNESS_SESSION_ROOT': str(external / 'session'),
            'HARNESS_DIR': str(config.parent), 'BASH_ENV': str(config / 'launcher.env'),
            'ZDOTDIR': str(external), 'PYTHONPATH': str(external),
            'PATH': str(external / 'bin'), 'HOME': str(external),
        }
        external_before = {str(p): p.read_bytes() for p in external.rglob('*') if p.is_file()}
        with mock.patch.dict(os.environ, poison):
            env = self.child_env()
            self.assertNotIn('HARNESS_CODEX_HISTORY_LEASE_FD', env)
            self.assertNotIn('BASH_ENV', env)
            self.assertNotIn('ZDOTDIR', env)
            self.assertNotIn('PYTHONPATH', env)
            self.assertFalse(any(str(external) in value for value in env.values()))
            direct = self.run_entry(['/bin/zsh', str(self.snapshot / 'bin/harness-exec'),
                                     str(self.harness), 'omp', '--help'])
            self.assertEqual((0, b'SYNTHETIC_OMP_HELP\n'), (direct.returncode, direct.stdout), direct.stderr)
            public = self.run_entry([str(self.public), 'omp', '--help'])
            self.assertEqual((0, b'SYNTHETIC_OMP_HELP\n'), (public.returncode, public.stdout), public.stderr)
        self.assertFalse(marker.exists())
        self.assertEqual(external_before, {str(p): p.read_bytes()
                                         for p in external.rglob('*') if p.is_file()})
        self.assertEqual(2, len(self.calls()))
        self.assertTrue(all(c['exe'] == str(self.binary) for c in self.calls()))
        self.assert_snapshot_preserved()
        self.assert_preserved()

    def test_original_consumer_guard_still_rejects_package_and_opt(self):
        with mock.patch.object(self.module.Path, 'home', return_value=self.home):
            for consumer in (self.package / 'aliases.zsh', self.home / 'opt/harness-launcher/share/harness-launcher/aliases.zsh'):
                with self.assertRaisesRegex(self.module.ProjectionError, '^OMP_BINDING_MISMATCH$'):
                    self.module.launcher_binding(str(consumer))
        self.assert_preserved()

    def test_tampered_snapshot_dependency_fails_before_native(self):
        p = self.snapshot / 'bin/harness-common.sh'
        before_mode = stat.S_IMODE(p.stat().st_mode)
        p.chmod(0o600)
        p.write_bytes(p.read_bytes() + b'\n# tampered fixture\n')
        p.chmod(before_mode)
        result = self.run_entry([str(self.public), 'omp', '--help'])
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b'', result.stdout)
        self.assertIn(b'OMP_BINDING_MISMATCH', result.stderr)
        self.assert_preserved()

    def test_unlisted_dependency_fails_closed(self):
        self.snapshot.chmod(0o700)
        self.write(self.snapshot / 'extra.py', b'# unlisted fixture\n', 0o400)
        self.snapshot.chmod(0o500)
        result = self.run_entry([str(self.public), 'omp', '--help'])
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b'', result.stdout)
        self.assert_preserved()

    def test_namespace_marker_binding_is_not_bypassed(self):
        p = self.namespace / '.owner.json'
        data = json.loads(p.read_bytes())
        data['asset_sha256'] = 'c' * 64
        self.write(p, self.encode(data))
        result = self.run_entry([str(self.public), 'omp', '--help'])
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b'', result.stdout)
        self.assertIn(b'OMP_BINDING_MISMATCH', result.stderr)
        self.assert_preserved()


    def test_symlink_current_snapshot_fails_closed(self):
        current = self.runtime / 'current.json'
        data = json.loads(current.read_bytes())
        link = self.runtime / 'snapshot-alias'
        link.symlink_to(self.snapshot, target_is_directory=True)
        data['path'] = str(link)
        self.write(current, self.encode(data))
        result = self.run_entry([str(self.public), 'omp', '--help'])
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b'', result.stdout)
        self.assert_preserved()

    def test_current_and_row_join_drift_are_not_refreshed(self):
        current = self.runtime / 'current.json'
        data = json.loads(current.read_bytes())
        data['version'] = '0.66.1'
        self.write(current, self.encode(data))
        result = self.run_entry([str(self.public), 'omp', '--help'])
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b'', result.stdout)
        self.assert_preserved()

    def test_repaired_current_snapshot_entry_does_not_reexec_forever(self):
        result = self.run_entry(['/bin/zsh', str(self.snapshot / 'bin/harness-exec'),
                                 str(self.harness), '--cwd', str(self.nested), '--no-isolated', 'omp', '--help'])
        self.assertEqual((0, b'SYNTHETIC_OMP_HELP\n'), (result.returncode, result.stdout), result.stderr)
        self.assert_preserved()

    def test_nested_cwd_spaces_and_exact_help_argv_readback(self):
        result = self.run_entry([str(self.public), '--cwd', str(self.nested),
                                 '--no-isolated', 'omp', '--help'])
        self.assertEqual((0, b'SYNTHETIC_OMP_HELP\n'), (result.returncode, result.stdout), result.stderr)
        self.assertEqual([{'argv': ['--help'], 'cwd': str(self.nested),
                           'exe': str(self.binary)}], self.calls())
        before = self.witness.read_bytes()
        rejected = self.run_entry([str(self.public), '--cwd', str(self.nested),
                                   '--no-isolated', 'omp', '--help', '--',
                                   'literal $(touch NOT_EXECUTED); value', 'codex'])
        self.assertNotEqual(0, rejected.returncode)
        self.assertEqual(before, self.witness.read_bytes())
        self.assertFalse((self.nested / 'NOT_EXECUTED').exists())
        self.assert_snapshot_preserved()
        self.assert_preserved()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--old-snapshot-capsule', type=Path, required=True)
    options, remaining = parser.parse_known_args()
    OLD_SNAPSHOT_CAPSULE = options.old_snapshot_capsule.resolve(strict=True)
    unittest.main(argv=[sys.argv[0], *remaining])
