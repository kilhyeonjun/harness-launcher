import importlib.util
import json
import os
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / 'bin/slack-approval-policy.py'

class SlackPolicyTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('slack_policy', PATH)
        self.policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.policy)

    def test_only_explicit_slack_apps_are_prompted(self):
        with patch.dict(os.environ, {'HARNESS_CODEX_SLACK_APPS': 'asdk_app_slacktest', 'HARNESS_CODEX_APPS_ALLOWLIST': 'asdk_app_slacktest,asdk_app_othertest'}):
            config = self.policy.codex_config()
        self.assertEqual(config['apps.asdk_app_slacktest.tools.slack_slack_send_message.approval_mode'], 'prompt')
        self.assertEqual(config['approvals_reviewer'], 'user')
        self.assertEqual(config['apps.asdk_app_slacktest.links'], {})
        self.assertFalse(any('asdk_app_othertest' in key for key in config))
        self.assertFalse(any('reaction' in key or 'draft' in key or 'read_thread' in key for key in config))

    def test_final_argv_overrides_cannot_disable_prompt(self):
        with patch.dict(os.environ, {'HARNESS_CODEX_SLACK_APPS': 'asdk_app_slacktest', 'HARNESS_CODEX_APPS_ALLOWLIST': 'asdk_app_slacktest', 'CODEX_HOME': ''}):
            args = self.policy.codex_argv(['resume', '-p', 'rich', '--dangerously-bypass-approvals-and-sandbox', '-c', 'approvals_reviewer="guardian_subagent"', '-a', 'never'])
        self.assertNotIn('--dangerously-bypass-approvals-and-sandbox', args)
        self.assertNotIn('never', args)
        self.assertIn('sandbox_mode="danger-full-access"', args)
        self.assertEqual(args[-2:], ['-c', 'apps.asdk_app_slacktest.tools.slack_slack_edit_message.approval_mode="prompt"'])
        self.assertIn('approval_policy="on-request"', args)

    def test_never_preserves_sandbox_and_no_slack_is_untouched(self):
        args = ['-a', 'never', '-s', 'read-only']
        with patch.dict(os.environ, {'HARNESS_CODEX_SLACK_APPS': 'asdk_app_slacktest', 'HARNESS_CODEX_APPS_ALLOWLIST': 'asdk_app_slacktest'}):
            protected = self.policy.codex_argv(args)
        self.assertFalse(any('danger-full' in arg for arg in protected))
        with patch.dict(os.environ, {'HARNESS_CODEX_SLACK_APPS': ''}):
            self.assertEqual(self.policy.codex_argv(args), args)

    def test_prompt_boundary_is_not_parsed_as_flags(self):
        with patch.dict(os.environ, {'HARNESS_CODEX_SLACK_APPS': 'asdk_app_slacktest', 'HARNESS_CODEX_APPS_ALLOWLIST': 'asdk_app_slacktest'}):
            args = self.policy.codex_argv(['--', '--dangerously-bypass-approvals-and-sandbox'])
        self.assertEqual(args[args.index('--') + 1:], ['--dangerously-bypass-approvals-and-sandbox'])
        self.assertNotIn('sandbox_mode="danger-full-access"', args)
        self.assertLess(args.index('-a'), args.index('--'))

    def full_access_home(self, root):
        Path(root, 'config.toml').write_text(
            'approval_policy = "on-request"\n'
            '[mcp_servers.alpha]\ncommand = "alpha-mcp"\n'
            '[mcp_servers.beta-kg]\nurl = "https://example.invalid/mcp"\n'
            '[mcp_servers."bad name"]\ncommand = "x"\n'
            '[mcp_servers.Slack-Bot]\ncommand = "slack-mcp"\n'
            '[mcp_servers.gamma]\ncommand = "gamma-mcp"\ndefault_tools_approval_mode = "writes"\n'
            '[mcp_servers.delta]\ncommand = "delta-mcp"\n'
            '[apps._default]\nenabled = false\n'
            '[apps.asdk_app_slacktest]\nenabled = true\n'
            '[apps.asdk_app_othertest]\nenabled = true\n'
            '[apps.asdk_app_offtest]\nenabled = false\n')
        return {'CODEX_HOME': root, 'HARNESS_CODEX_SLACK_APPS': 'asdk_app_slacktest',
                'HARNESS_CODEX_APPS_ALLOWLIST': 'asdk_app_slacktest,asdk_app_othertest'}

    def test_full_access_keeps_non_slack_tools_unprompted(self):
        # Codex auto-approves MCP prompts only under never + full disk access;
        # the forced on-request must not start prompting for other tools.
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, self.full_access_home(root)):
            for argv in (['--dangerously-bypass-approvals-and-sandbox', 'resume', 'x'],
                         ['-a', 'on-request', '-s', 'danger-full-access', 'resume', 'x'],
                         ['--sandbox=danger-full-access', 'resume', 'x']):
                argv = ['-c', 'mcp_servers.delta.default_tools_approval_mode="prompt"'] + argv
                args = self.policy.codex_argv(argv)
                # Slack-named servers, home-level modes and caller overrides keep their policy.
                self.assertFalse(any('Slack-Bot' in arg or 'mcp_servers.gamma' in arg for arg in args), argv)
                self.assertNotIn('mcp_servers.delta.default_tools_approval_mode="approve"', args)
                self.assertIn('mcp_servers.delta.default_tools_approval_mode="prompt"', args)
                self.assertIn('mcp_servers.alpha.default_tools_approval_mode="approve"', args, argv)
                self.assertIn('mcp_servers.beta-kg.default_tools_approval_mode="approve"', args, argv)
                self.assertIn('apps.asdk_app_othertest.default_tools_approval_mode="approve"', args, argv)
                self.assertFalse(any('bad name' in arg for arg in args), argv)
                self.assertFalse(any('asdk_app_slacktest.default_tools' in arg for arg in args), argv)
                self.assertFalse(any('asdk_app_offtest' in arg or '_default' in arg for arg in args), argv)
                self.assertIn('apps.asdk_app_slacktest.tools.slack_slack_send_message.approval_mode="prompt"', args)

    def test_restricted_sandbox_and_missing_home_add_no_auto_approval(self):
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, self.full_access_home(root)):
            for argv in (['-a', 'never', '-s', 'read-only'], ['-s', 'workspace-write'], [],
                         ['--', '--dangerously-bypass-approvals-and-sandbox'],
                         ['-s', 'danger-full-access', '-s', 'read-only']):
                args = self.policy.codex_argv(argv)
                self.assertFalse(any('default_tools_approval_mode' in arg for arg in args), argv)
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, {**self.full_access_home(root), 'CODEX_HOME': root + '/missing'}):
            args = self.policy.codex_argv(['--dangerously-bypass-approvals-and-sandbox'])
        self.assertIn('approval_policy="on-request"', args)
        self.assertFalse(any('default_tools_approval_mode' in arg for arg in args))

    def test_claude_caller_settings_cannot_remove_ask(self):
        args = self.policy.claude_argv(['--permission-mode', 'bypassPermissions', '--settings', '{"hooks":{"SessionStart":[]},"permissions":{"ask":[]},"alwaysThinkingEnabled":false}', '--', 'prompt'])
        settings = json.loads(args[args.index('--settings') + 1])
        self.assertIn('mcp__codex_apps__slack_slack_send_message', settings['permissions']['ask'])
        self.assertFalse(settings['alwaysThinkingEnabled'])
        self.assertEqual(args[args.index('--') + 1:], ['prompt'])

    def test_file_settings_secret_is_not_serialized_into_argv(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'settings.json'
            path.write_text('{"env":{"ANTHROPIC_API_KEY":"dummy-test-secret"}}')
            args = self.policy.claude_argv(['--settings', str(path)])
            self.assertNotIn('dummy-test-secret', ' '.join(args))
            merged = Path(args[args.index('--settings') + 1])
            try:
                self.assertEqual(merged.stat().st_mode & 0o777, 0o600)
                self.assertEqual(json.loads(merged.read_text())['env']['ANTHROPIC_API_KEY'], 'dummy-test-secret')
            finally:
                merged.unlink(missing_ok=True)

    def test_claude_settings_preserve_existing_content(self):
        settings = {'alwaysThinkingEnabled': True, 'hooks': {'SessionStart': []}, 'permissions': {'ask': ['Bash(rm *)']}}
        result = self.policy.claude_settings(settings)
        self.assertTrue(result['alwaysThinkingEnabled'])
        self.assertEqual(result['hooks'], settings['hooks'])
        self.assertIn('Bash(rm *)', result['permissions']['ask'])
        self.assertIn('mcp__codex_apps__slack_slack_send_message', result['permissions']['ask'])
        self.assertNotIn('mcp__codex_apps__slack_slack_read_thread', result['permissions']['ask'])

if __name__ == '__main__':
    unittest.main()
