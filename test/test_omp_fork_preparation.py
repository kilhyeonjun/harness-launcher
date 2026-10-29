"""Run with TEST_HARNESS_DIR pointing at the integrated canonical source tree.

Only Publisher selection/profile authority is injected. Rendering, owned source
admission, immutable bundle writes and structural preparation are real.
"""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

PUBLIC = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('fork_projection', PUBLIC / 'bin/harness_omp_projection.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


@unittest.skipUnless('TEST_HARNESS_DIR' in os.environ,
    'optional real-private-compiler integration requires TEST_HARNESS_DIR')
class ForkPreparation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'source'
        source = Path(os.environ['TEST_HARNESS_DIR']).resolve()
        self.root.mkdir(mode=0o700)
        # load_source/check_source consume .claude source/settings/catalogs/rules
        # plus core's shared registry, compiler helpers and OMP model modes.
        for name in ('.claude', 'core'):
            shutil.copytree(source / name, self.root / name,
                ignore=shutil.ignore_patterns('scratchpad', '__pycache__', 'node_modules', '.git', '.harness'))
        compiler = self.root / 'core/scripts/harness_compile.py'
        spec = importlib.util.spec_from_file_location('fixture_fork_compiler', compiler)
        self.c = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.c)
        self.record = self.root / self.c.OMP_FORK_RECORD
        self.row = json.loads(self.record.read_bytes())
        release = copy.deepcopy(self.row['release'])
        binary = b'owned fixture executable'
        self.row['binary'] = dict(self.row['binary'],
            sha256=hashlib.sha256(binary).hexdigest(), bytes=len(binary))
        self.record.write_text(self.c.omp_json(self.row) + '\n')
        self.record.chmod(0o600)
        self.current = dict(binary_path='/fixture/bin/omp', namespace_path='/fixture/namespace',
            binary_release=release, binary_sha256=self.row['binary']['sha256'], binary_size=len(binary))
        # This is the existing trusted resolver boundary, not a compiler stub.
        self.consumer = Path(self.temp.name) / 'consumer/entry.py'
        self.consumer.parent.mkdir(mode=0o700)
        (self.consumer.parent / 'harness_profile_resolver.py').write_text(
            'from types import SimpleNamespace\n'
            f'def resolve(source, registry): return SimpleNamespace(profile={self.row["profile"]!r}, harness_root=source)\n')

    def prepare(self, currents=None):
        if currents is None:
            currents = [self.current, self.current]
        with patch.object(p, 'select_continuation_source', side_effect=copy.deepcopy(currents)), \
                patch.object(p, 'required_dependencies', return_value=[]):
            return p.required_preparation(self.root, str(self.consumer), self.root,
                self.current['binary_path'], self.current['namespace_path'], [])

    def test_selected_fork_survives_real_prepared_bundle(self):
        self.prepare()
        selections = list((self.root / '.harness/omp').glob('*/selection.json'))
        manifest = json.loads(selections[0].read_text())
        self.assertEqual(manifest['runtime_version'], self.row['release']['version'])
        sealed = selections[0].parent / 'native-fork-artifact.json'
        changed = json.loads(sealed.read_text())
        self.assertEqual(changed, self.row)
        changed['binary']['bytes'] += 1
        sealed.write_text(self.c.omp_json(changed) + '\n')
        with self.assertRaises(self.c.HarnessCompileError):
            self.c.prepare_omp_bundle(selections[0].parent, manifest, [])

    def test_current_mismatch_and_late_selection_change_refuse(self):
        for key, value in [('binary_size', self.current['binary_size'] + 1), ('binary_sha256', 'f' * 64)]:
            original = copy.deepcopy(self.current)
            self.current[key] = value
            with self.assertRaises(p.ProjectionError): self.prepare()
            self.current = original
        changed = dict(self.current, binary_sha256='f' * 64)
        with self.assertRaises(p.ProjectionError): self.prepare([self.current, changed])

    def test_malformed_or_unowned_resource_cannot_prepare(self):
        original = self.record.read_bytes()
        for field in ('release', 'binary'):
            row = copy.deepcopy(self.row)
            row[field] = list(row[field])
            self.record.write_text(self.c.omp_json(row) + '\n')
            with self.assertRaises(p.ProjectionError): self.prepare()
        row = dict(self.row, unregistered=True)
        self.record.write_text(self.c.omp_json(row) + '\n')
        with self.assertRaises(p.ProjectionError): self.prepare()
        self.record.write_bytes(original)
        self.record.chmod(0o620)
        with self.assertRaises(p.ProjectionError): self.prepare()
        self.record.chmod(0o600)
        other = self.record.with_name('mutable-record.json')
        self.record.rename(other)
        self.record.symlink_to(other)
        with self.assertRaises(p.ProjectionError): self.prepare()

    def test_stock_needs_no_record_and_bare_fork_refuses(self):
        self.record.unlink()
        with self.assertRaises(p.ProjectionError): self.prepare()
        self.current['binary_release'] = dict(version='18.11.3', source_revision='96894a6147d8cc64b7e00ad3a7d7178fd93b9531')
        self.prepare()
        manifest = json.loads(next((self.root / '.harness/omp').glob('*/selection.json')).read_text())
        self.assertNotIn('native_distribution', manifest)
        self.assertNotIn('native-fork-artifact.json', [row['relative_path'] for row in manifest['artifacts']])


if __name__ == '__main__':
    unittest.main()
