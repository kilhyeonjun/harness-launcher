import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
PATH = Path(__file__).resolve().parents[1] / 'bin/claude-plugin-scope-mirror.py'
SESSION_ID = '0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D'
OTHER_ID = '11111111-2222-4333-8444-555555555555'
GONE_ID = '99999999-8888-4777-8666-555555555555'


def load_module():
    spec = importlib.util.spec_from_file_location('claude_plugin_scope_mirror', PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def record(scope, project_path=None, **extra):
    rec = {'scope': scope}
    if project_path is not None:
        rec['projectPath'] = project_path
    rec.update({
        'installPath': '/cache/example/slack/1.3.0',
        'version': '1.3.0',
        'installedAt': '2026-09-06T23:59:18.598Z',
        'lastUpdated': '2026-09-09T06:06:28.802Z',
        'gitCommitSha': '1251c73cb0ef34d4ce66cada7d045751fc1d1edc',
    })
    rec.update(extra)
    return rec


class MirrorTest(unittest.TestCase):
    def setUp(self):
        self.mirror = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(os.path.realpath(self.tmp.name))
        self.home = base / 'home'
        self.config = base / 'claude-config'
        self.plugins = self.config / 'plugins'
        self.plugins.mkdir(parents=True)
        self.home.mkdir()
        self.registry = self.plugins / 'installed_plugins.json'
        self.source = base / 'harness'
        self.source.mkdir()
        self.worktrees = base / 'state' / 'worktrees'
        self.session = self.worktrees / SESSION_ID
        self.session.mkdir(parents=True)
        (self.worktrees / OTHER_ID).mkdir()
        self.env = {'HOME': str(self.home), 'CLAUDE_CONFIG_DIR': str(self.config)}

    def tearDown(self):
        self.tmp.cleanup()

    def write_registry(self, data):
        self.registry.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')

    def read_registry(self):
        return json.loads(self.registry.read_text(encoding='utf-8'))

    def ensure(self, env=None, source=None, session=None, worktrees=None):
        err = io.StringIO()
        rc = self.mirror.ensure(
            str(source or self.source), str(session or self.session), str(worktrees or self.worktrees),
            env=self.env if env is None else env, stderr=err)
        return rc, err.getvalue()

    def lock_path(self):
        return Path(str(self.registry) + '.harness-launcher.lock')

    def test_mirrors_project_and_local_records_preserving_fields(self):
        data = {
            'version': 2,
            'plugins': {
                'slack@official': [
                    record('project', str(self.source), directoryRepositoryKey='repo-key'),
                    record('project', '/elsewhere/project'),
                ],
                'notes@market': [record('local', str(self.source))],
                'tool@market': [record('user')],
            },
            'futureTopLevel': {'kept': True},
        }
        self.write_registry(data)
        rc, err = self.ensure()
        self.assertEqual((rc, err), (0, ''))
        after = self.read_registry()
        self.assertEqual(list(after), ['version', 'plugins', 'futureTopLevel'])
        self.assertEqual(after['futureTopLevel'], {'kept': True})
        slack = after['plugins']['slack@official']
        self.assertEqual(slack[:2], data['plugins']['slack@official'])
        self.assertEqual(slack[2], dict(data['plugins']['slack@official'][0], projectPath=str(self.session)))
        self.assertEqual(list(slack[2]), list(data['plugins']['slack@official'][0]))
        notes = after['plugins']['notes@market']
        self.assertEqual(notes[1], dict(data['plugins']['notes@market'][0], projectPath=str(self.session)))
        self.assertEqual(after['plugins']['tool@market'], data['plugins']['tool@market'])
        raw = self.registry.read_text(encoding='utf-8')
        self.assertFalse(raw.endswith('\n'))
        self.assertEqual(raw, json.dumps(after, indent=2, ensure_ascii=False))

    def test_second_run_is_a_no_op_without_lock_file(self):
        self.write_registry({'version': 2, 'plugins': {'slack@official': [record('project', str(self.source))]}})
        self.assertEqual(self.ensure(), (0, ''))
        self.lock_path().unlink()
        before = self.registry.read_bytes()
        mtime = self.registry.stat().st_mtime_ns
        self.assertEqual(self.ensure(), (0, ''))
        self.assertEqual(self.registry.read_bytes(), before)
        self.assertEqual(self.registry.stat().st_mtime_ns, mtime)
        self.assertFalse(self.lock_path().exists())

    def test_updated_source_record_replaces_mirror_in_place(self):
        self.write_registry({'version': 2, 'plugins': {'slack@official': [record('project', str(self.source))]}})
        self.ensure()
        data = self.read_registry()
        data['plugins']['slack@official'][0].update(version='1.4.0', installPath='/cache/example/slack/1.4.0')
        self.write_registry(data)
        self.assertEqual(self.ensure(), (0, ''))
        slack = self.read_registry()['plugins']['slack@official']
        self.assertEqual(len(slack), 2)
        self.assertEqual(slack[1]['version'], '1.4.0')
        self.assertEqual(slack[1]['installPath'], '/cache/example/slack/1.4.0')
        self.assertEqual(slack[1]['projectPath'], str(self.session))

    def test_prune_removes_only_missing_launcher_owned_sessions(self):
        gone = str(self.worktrees / GONE_ID)
        other = str(self.worktrees / OTHER_ID)
        non_uuid = str(self.worktrees / 'not-a-session')
        outside = '/elsewhere/' + GONE_ID
        self.write_registry({'version': 2, 'plugins': {
            'slack@official': [record('project', gone), record('project', other), record('local', non_uuid),
                               record('project', outside), record('user')],
            'only-gone@market': [record('project', gone), record('local', gone)],
            'empty@market': [],
        }})
        self.assertEqual(self.ensure(), (0, ''))
        after = self.read_registry()['plugins']
        self.assertEqual([r.get('projectPath') for r in after['slack@official']], [other, non_uuid, outside, None])
        self.assertNotIn('only-gone@market', after)
        self.assertEqual(after['empty@market'], [])

    def test_missing_registry_or_plugins_dir_creates_nothing(self):
        self.assertEqual(self.ensure(), (0, ''))
        self.assertFalse(self.registry.exists())
        self.assertFalse(self.lock_path().exists())
        env = {'HOME': str(self.home), 'CLAUDE_CONFIG_DIR': str(self.config / 'absent')}
        self.assertEqual(self.ensure(env=env), (0, ''))
        self.assertFalse((self.config / 'absent').exists())

    def test_invalid_registries_are_left_unchanged(self):
        cases = {
            'json': '{not json',
            'nan': '{"version": 2, "plugins": {"a@b": [{"scope": "project", "x": NaN}]}}',
            'v1': json.dumps({'version': 1, 'plugins': {}}),
            'non-array': json.dumps({'version': 2, 'plugins': {'a@b': {'scope': 'user'}}}),
            'non-object-record': json.dumps({'version': 2, 'plugins': {'a@b': ['user']}}),
            'top-array': json.dumps([]),
        }
        for name, raw in cases.items():
            with self.subTest(name):
                self.registry.write_text(raw, encoding='utf-8')
                rc, err = self.ensure()
                self.assertEqual(rc, 0)
                self.assertEqual(len(err.strip().splitlines()), 1)
                self.assertIn('harness-launcher: warning:', err)
                self.assertEqual(self.registry.read_text(encoding='utf-8'), raw)

    def test_out_of_range_number_is_not_rewritten_as_infinity(self):
        rec = json.dumps(record('project', str(self.source)))
        raw = '{"version": 2, "plugins": {"slack@official": [' + rec[:-1] + ', "size": 1e400}]}}'
        self.registry.write_text(raw, encoding='utf-8')
        rc, err = self.ensure()
        self.assertEqual(rc, 0)
        self.assertIn('harness-launcher: warning:', err)
        self.assertEqual(self.registry.read_text(encoding='utf-8'), raw)

    def test_relative_project_paths_are_ignored(self):
        self.write_registry({'version': 2, 'plugins': {'slack@official': [
            record('project', '.'), record('local', ''), record('project', SESSION_ID)]}})
        before = self.registry.read_bytes()
        cwd = os.getcwd()
        try:
            os.chdir(self.source)
            self.assertEqual(self.ensure(), (0, ''))
            os.chdir(self.worktrees)
            self.assertEqual(self.ensure(), (0, ''))
        finally:
            os.chdir(cwd)
        self.assertEqual(self.registry.read_bytes(), before)

    def test_symlinked_or_hard_linked_registry_is_left_unchanged(self):
        real = self.plugins / 'real.json'
        raw = json.dumps({'version': 2, 'plugins': {'slack@official': [record('project', str(self.source))]}}, indent=2)
        real.write_text(raw, encoding='utf-8')
        self.registry.symlink_to(real)
        rc, err = self.ensure()
        self.assertEqual(rc, 0)
        self.assertIn('harness-launcher: warning:', err)
        self.assertTrue(self.registry.is_symlink())
        self.assertEqual(real.read_text(encoding='utf-8'), raw)
        self.registry.unlink()
        os.link(real, self.registry)
        rc, err = self.ensure()
        self.assertEqual(rc, 0)
        self.assertIn('harness-launcher: warning:', err)
        self.assertEqual(self.registry.read_text(encoding='utf-8'), raw)

    def test_symlinked_and_nfd_source_paths_match(self):
        link = self.source.parent / 'harness-link'
        link.symlink_to(self.source)
        self.write_registry({'version': 2, 'plugins': {'slack@official': [record('project', str(self.source))]}})
        self.assertEqual(self.ensure(source=link), (0, ''))
        self.assertEqual(self.read_registry()['plugins']['slack@official'][1]['projectPath'], str(self.session))

        nfc_source = self.source.parent / unicodedata.normalize('NFC', 'härness')
        nfc_source.mkdir()
        self.write_registry({'version': 2, 'plugins': {'slack@official': [record('project', str(nfc_source))]}})
        nfd_arg = str(self.source.parent / unicodedata.normalize('NFD', 'härness'))
        self.assertEqual(self.ensure(source=nfd_arg), (0, ''))
        self.assertEqual(len(self.read_registry()['plugins']['slack@official']), 2)

    def test_registry_location_rules(self):
        cache_dir = self.home / 'plugin-cache'
        cache_dir.mkdir()
        cowork = self.config / 'cowork_plugins'
        cowork.mkdir()
        payload = {'version': 2, 'plugins': {'slack@official': [record('project', str(self.source))]}}
        for directory in (cache_dir, cowork):
            (directory / 'installed_plugins.json').write_text(json.dumps(payload, indent=2), encoding='utf-8')
        self.write_registry(payload)
        self.assertEqual(self.ensure(env=dict(self.env, CLAUDE_CODE_PLUGIN_CACHE_DIR=str(cache_dir))), (0, ''))
        self.assertEqual(len(json.loads((cache_dir / 'installed_plugins.json').read_text())['plugins']['slack@official']), 2)
        self.assertEqual(len(self.read_registry()['plugins']['slack@official']), 1)
        self.assertEqual(self.ensure(env=dict(self.env, CLAUDE_CODE_USE_COWORK_PLUGINS='1')), (0, ''))
        self.assertEqual(len(json.loads((cowork / 'installed_plugins.json').read_text())['plugins']['slack@official']), 2)
        self.assertEqual(len(self.read_registry()['plugins']['slack@official']), 1)
        self.assertEqual(self.ensure(env={'HOME': str(self.home)}), (0, ''))
        self.assertEqual(self.mirror.registry_path({'HOME': str(self.home)}),
                         str(self.home / '.claude' / 'plugins' / 'installed_plugins.json'))

    def test_concurrent_change_before_replace_is_retried(self):
        self.write_registry({'version': 2, 'plugins': {'slack@official': [record('project', str(self.source))]}})
        real_read = self.mirror.read_bytes
        calls = {'n': 0}

        def racing_read(path):
            calls['n'] += 1
            if calls['n'] == 3:
                data = json.loads(real_read(path))
                data['plugins']['new@market'] = [record('user')]
                Path(path).write_text(json.dumps(data, indent=2), encoding='utf-8')
            return real_read(path)

        with patch.object(self.mirror, 'read_bytes', racing_read):
            self.assertEqual(self.ensure(), (0, ''))
        after = self.read_registry()['plugins']
        self.assertIn('new@market', after)
        self.assertEqual(after['slack@official'][1]['projectPath'], str(self.session))

    def test_persistent_conflict_gives_up_with_warning(self):
        raw = json.dumps({'version': 2, 'plugins': {'slack@official': [record('project', str(self.source))]}}, indent=2)
        self.registry.write_text(raw, encoding='utf-8')
        real_read = self.mirror.read_bytes
        calls = {'n': 0}

        def always_changed(path):
            calls['n'] += 1
            value = real_read(path)
            return value + (b' ' * calls['n'])

        with patch.object(self.mirror, 'read_bytes', always_changed):
            rc, err = self.ensure()
        self.assertEqual(rc, 0)
        self.assertIn('harness-launcher: warning:', err)
        self.assertEqual(self.registry.read_text(encoding='utf-8'), raw)
        self.assertEqual(sorted(p.name for p in self.plugins.iterdir()),
                         ['installed_plugins.json', 'installed_plugins.json.harness-launcher.lock'])

    def test_invalid_arguments_exit_2_without_reading(self):
        self.write_registry({'version': 2, 'plugins': {}})
        outside = self.source.parent / SESSION_ID
        outside.mkdir()
        named = self.worktrees / 'not-a-uuid'
        named.mkdir()
        link_worktrees = self.source.parent / 'worktrees-link'
        link_worktrees.symlink_to(self.worktrees)
        cases = [
            dict(session=outside),
            dict(session=named),
            dict(session=self.worktrees / GONE_ID),
            dict(worktrees=link_worktrees, session=link_worktrees / SESSION_ID),
            dict(source=self.session),
            dict(source=self.source.parent / 'missing'),
        ]
        with patch.object(self.mirror, 'read_bytes', side_effect=AssertionError('registry read')):
            for case in cases:
                with self.subTest(case=case):
                    rc, err = self.ensure(**case)
                    self.assertEqual(rc, 2)
                    self.assertIn('harness-launcher:', err)

    def test_held_lock_warns_and_skips(self):
        import fcntl
        raw = json.dumps({'version': 2, 'plugins': {'slack@official': [record('project', str(self.source))]}}, indent=2)
        self.registry.write_text(raw, encoding='utf-8')
        fd = os.open(self.lock_path(), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            with patch.object(self.mirror, 'LOCK_TIMEOUT_SECONDS', 0.2):
                rc, err = self.ensure()
        finally:
            os.close(fd)
        self.assertEqual(rc, 0)
        self.assertIn('harness-launcher: warning:', err)
        self.assertEqual(self.registry.read_text(encoding='utf-8'), raw)

    def test_registry_mode_is_preserved(self):
        self.write_registry({'version': 2, 'plugins': {'slack@official': [record('project', str(self.source))]}})
        os.chmod(self.registry, 0o640)
        self.assertEqual(self.ensure(), (0, ''))
        self.assertEqual(self.registry.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.lock_path().stat().st_mode & 0o777, 0o600)

    def test_cli_runs_isolated_and_reports_usage_errors(self):
        self.write_registry({'version': 2, 'plugins': {'slack@official': [record('project', str(self.source))]}})
        env = dict(self.env, PATH=os.environ.get('PATH', ''))
        ok = subprocess.run([sys.executable, '-I', str(PATH), 'ensure', '--source-root', str(self.source),
                             '--session-root', str(self.session), '--worktrees-dir', str(self.worktrees)],
                            env=env, capture_output=True, text=True)
        self.assertEqual((ok.returncode, ok.stdout, ok.stderr), (0, '', ''))
        self.assertEqual(len(self.read_registry()['plugins']['slack@official']), 2)
        bad = subprocess.run([sys.executable, '-I', str(PATH), 'ensure', '--source-root', str(self.source)],
                             env=env, capture_output=True, text=True)
        self.assertEqual(bad.returncode, 2)


if __name__ == '__main__':
    unittest.main()
