"""Real Seatbelt export boundary; exercised on hosts with sandbox-exec."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = Path(__file__).resolve().parents[1] / 'bin'


@unittest.skipUnless(Path('/usr/bin/sandbox-exec').is_file(), 'Seatbelt requires macOS')
class ExportSandboxTests(unittest.TestCase):
    def test_exact_export_is_read_only_and_siblings_unreadable(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            home = base / 'home'
            state = home / '.local/state/harness-launcher'
            export = home / '.local/state/harness-service/sample-dev/release-export'
            sibling = export.parent / 'sibling-secret'
            for directory in (state, export, base / 'copy', base / 'tmp', base / 'trusted', base / 'source'):
                directory.mkdir(parents=True, exist_ok=True)
            (export / 'policy').write_text('verified')
            sibling.write_text('secret')
            env = dict(os.environ, HOME=str(home), HARNESS_SESSION_STATE_HOME=str(state))
            profile = subprocess.check_output(['bash', str(BIN / 'session-isolation.sh'), 'verifier-sandbox-profile',
                                               str(base / 'copy'), str(base / 'tmp'), str(home), str(base / 'source'),
                                               str(base / 'trusted'), 'sample'], env=env, text=True)
            def sandbox(*command):
                return subprocess.run(['/usr/bin/sandbox-exec', '-p', profile, *command], capture_output=True)
            read = sandbox('/bin/cat', str(export / 'policy'))
            self.assertEqual(read.returncode, 0, read.stderr)
            self.assertEqual(read.stdout, b'verified')
            self.assertNotEqual(sandbox('/bin/cat', str(sibling)).returncode, 0)
            self.assertNotEqual(sandbox('/bin/sh', '-c', 'printf changed > "$1"', 'sh', str(export / 'policy')).returncode, 0)
            self.assertEqual((export / 'policy').read_text(), 'verified')
