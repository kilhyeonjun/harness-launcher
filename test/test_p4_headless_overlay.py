"""Headless delivery consumes the broker's release refusal output contract."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('headless_release_under_test', ROOT / 'bin/harness_headless.py')
hh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hh)


class ReleaseDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name)
        self.sid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
        self.record = self.state / 'sessions' / self.sid
        self.record.mkdir(parents=True)
        self.log = io.StringIO()
        self.calls = []
        self.journal('ABANDONED')

    def journal(self, state):
        (self.record / 'journal').write_text(f'state={state}\nbase=unchanged-base\nsubmission=unchanged-submission\n')

    def refuse(self, rc, stderr, after='SUBMITTED'):
        # Only the process boundary is substituted: delivery, journal reads,
        # message recording/removal and the consumer-visible reason are real.
        def broker(command, **kwargs):
            self.calls.append(command[1:])
            self.assertEqual(command[-1], self.sid)
            if command[1] == 'recover':
                self.assertEqual(len(self.calls), 1, 'a release refusal must not retry integration')
                self.journal('ACTIVE')
                return subprocess.CompletedProcess(command, 0)
            self.assertEqual(command[1], 'close')
            self.assertEqual(kwargs['stderr'], subprocess.PIPE)
            self.journal(after)
            return subprocess.CompletedProcess(command, rc, stderr=stderr)

        with patch.object(hh.subprocess, 'run', side_effect=broker):
            outcome = hh.deliver(self.sid, self.state, {}, str(self.state), self.log, 'feat: release consumer\n')
        self.assertEqual(self.calls, [['recover', self.sid], ['close', self.sid]])
        self.assertEqual(hh.journal_state(self.state, self.sid), after)
        self.assertEqual((self.record / 'journal').read_text(),
                         f'state={after}\nbase=unchanged-base\nsubmission=unchanged-submission\n')
        self.assertFalse((self.record / hh.COMMIT_MESSAGE).exists())
        self.assertIn(stderr, self.log.getvalue())
        return outcome

    def test_overlay_drift_reports_exact_paths_from_stderr_json(self):
        paths = ['config/rules.md', '.harness/codex/AGENTS.md', 'rules/a name\nwith newline.md', 'rules/한글.md']
        stderr = 'release resume: pinned release\n' + json.dumps({'drift_paths': paths}) + '\n'
        status, commit, reason = self.refuse(12, stderr)
        self.assertEqual((status, commit), ('failed', None))
        token, payload = reason.split(' ', 1)
        self.assertEqual(token, 'overlay_drift')
        self.assertEqual(json.loads(payload), {'drift_paths': paths})

    def test_overlay_drift_accepts_reason_prefixed_json(self):
        status, commit, reason = self.refuse(12, 'overlay_drift {"drift_paths":["AGENTS.md"]}\n')
        self.assertEqual((status, commit), ('failed', None))
        self.assertEqual(json.loads(reason.split(' ', 1)[1])['drift_paths'], ['AGENTS.md'])

    def test_invalid_or_missing_drift_output_still_fails_without_invented_paths(self):
        for stderr in ('', 'overlay_drift\n', '{bad json}\n', '{"drift_paths":[]}\n',
                       '{"drift_paths":"AGENTS.md"}\n', '{"drift_paths":[null]}\n'):
            with self.subTest(stderr=stderr):
                self.calls.clear()
                self.journal('ABANDONED')
                self.assertEqual(self.refuse(12, stderr), ('failed', None, 'overlay_drift'))

    def test_verifier_policy_unavailable_preserves_submission_and_stops(self):
        self.assertEqual(self.refuse(17, 'verifier_policy_unavailable\n'),
                         ('failed', None, 'verifier_policy_unavailable'))

    def test_verifier_policy_unavailable_never_triggers_indeterminate_recovery(self):
        self.assertEqual(self.refuse(17, 'verifier_policy_unavailable\n', after='INTEGRATING'),
                         ('failed', None, 'verifier_policy_unavailable'))


if __name__ == '__main__':
    unittest.main()
