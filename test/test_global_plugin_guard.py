"""A session snapshot may use an existing Chrome bridge, never replace it."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

GUARD = Path(__file__).resolve().parents[1]/'bin/codex-global-plugin-guard.py'


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name);self.local=self.base/'local'
        self.home=self.base/'home';self.global_=self.home/'.codex/plugins/cache/openai-bundled/chrome/latest'
        for name,data in {'.codex-plugin/plugin.json':'{"version":"1.0.0"}',
                          'scripts/browser-client.mjs':'old bridge',
                          'scripts/extension-id.json':'{"extensionId":"owned-fixture"}',
                          'extension-host/macos/arm64/Codex for Chrome':'owned executable'}.items():
            p=self.local/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(data)
        (self.local/'extension-host/macos/arm64/Codex for Chrome').chmod(0o700)
        keg=self.global_.with_name('1.0.0');shutil.copytree(self.local,keg)
        self.global_.symlink_to(keg.name,target_is_directory=True)
        self.config=self.global_/'extension-host/macos/arm64/extension-host-config.json'
        self.config.write_text(json.dumps({'schemaVersion':1,'channel':'prod',
            'browserClientPath':str(self.global_/'scripts/browser-client.mjs'),
            'codexCliPath':'/Applications/Codex.app/Contents/Resources/codex',
            'extensionId':'owned-fixture','nodePath':'/Applications/Codex.app/Contents/Resources/cua_node/bin/node',
            'nodeReplPath':'/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl',
            'proxyHost':'127.0.0.1','proxyPort':0}))

    def check(self):
        return subprocess.run([sys.executable,'-B',str(GUARD),str(self.local),str(self.global_)],capture_output=True,text=True)

    def test_compatible_bridge_is_read_only(self):
        before=self.config.read_bytes()
        self.assertEqual(self.check().returncode,0)
        self.assertEqual(self.config.read_bytes(),before)

    def test_new_plugin_or_changed_bridge_never_claims_compatibility(self):
        (self.local/'scripts/browser-client.mjs').write_text('new bridge')
        result=self.check();self.assertNotEqual(result.returncode,0)
        self.assertIn('global_plugin_incompatible',result.stderr)
        self.assertEqual((self.global_/'scripts/browser-client.mjs').read_text(),'old bridge')

    def test_missing_or_incompatible_native_config_fails_without_repair(self):
        original=self.config.read_bytes();self.config.unlink()
        self.assertNotEqual(self.check().returncode,0);self.assertFalse(self.config.exists())
        self.config.write_text('{}');bad=self.config.read_bytes()
        self.assertNotEqual(self.check().returncode,0);self.assertEqual(self.config.read_bytes(),bad)

    def prepare(self):
        harness=self.base/'harness';harness.mkdir(exist_ok=True)
        (harness/'CLAUDE.md').write_text('# owned fixture')
        marketplace=self.base/'marketplace';shutil.copytree(self.local,marketplace/'plugins/chrome')
        codex=self.base/'codex';codex.write_text('#!/bin/sh\necho "codex-cli 0.153.2"\n');codex.chmod(0o700)
        env={k:v for k,v in os.environ.items() if not k.startswith('HARNESS_')}
        env.update(HOME=str(self.home),HARNESS_CODEX_BIN=str(codex),
            HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE=str(marketplace),HARNESS_CODEX_GLOBAL_PLUGIN_POLICY='preserve')
        for key in ('HARNESS_SESSION_ROOT','HARNESS_SOURCE_ROOT','CODEX_HOME','HARNESS_SESSION_ID'):env.pop(key,None)
        return subprocess.run(['/bin/bash',str(GUARD.with_name('codex-home-prepare.sh')),str(harness)],env=env,capture_output=True,text=True,timeout=90)

    def test_preserve_preparation_rejects_drift_before_global_write(self):
        (self.local/'scripts/browser-client.mjs').write_text('new bridge')
        before=self.config.read_bytes();result=self.prepare()
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('global_plugin_incompatible',result.stderr)
        self.assertEqual((self.global_/'scripts/browser-client.mjs').read_text(),'old bridge')
        self.assertEqual(self.config.read_bytes(),before)

    def test_preserve_preparation_uses_compatible_assets_without_global_publish(self):
        before=self.config.read_bytes();result=self.prepare()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.config.read_bytes(),before)
        self.assertFalse((self.home/'.codex/.tmp/bundled-marketplaces/openai-bundled').exists())


if __name__=='__main__':unittest.main()
