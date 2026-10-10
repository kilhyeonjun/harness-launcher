"""Behavioral tests for the side-effect-free terminal/Web launch planner."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "harness_launch_plan", ROOT / "bin" / "harness_launch_plan.py"
)
assert SPEC and SPEC.loader
launch_plan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launch_plan)


class LaunchPlanTest(unittest.TestCase):
    def test_claude_context_summary_preserves_native_preset_alias(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)
            presets=[{"id":"rich","label":"Rich","model":"opus[1m]","effort":"xhigh"}]
            default=launch_plan.plan(source,"claude","rich",presets)
            standard=launch_plan.plan(source,"claude","rich",presets,options={"context":"standard"})
            capability=launch_plan.capabilities(source,"claude",presets)
        self.assertEqual(default['summary']['context'],'1m')
        self.assertEqual(capability['contexts'],['standard','1m'])
        self.assertEqual(standard['summary']['context'],'standard')
        self.assertEqual(standard['args'],['rich','--passthrough','--model','opus'])

    def test_real_model_cache_shape_exposes_supported_efforts_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory);cache=source/'.harness/codex/models_cache.json';cache.parent.mkdir(parents=True)
            cache.write_text(json.dumps({'models':[{'slug':'fixture-model','supported_reasoning_levels':[{'effort':'low'},{'effort':'ultra'},{'effort':'invalid'}]},{'slug':'unconfigured','supported_reasoning_levels':[{'effort':'high'}]}]}))
            result=launch_plan.capabilities(source,'codex',[{'id':'base','label':'Base','model':'fixture-model','effort':'medium'}])
        self.assertEqual(result['efforts_by_model'],{'fixture-model':['medium','low','ultra']})

    def test_saved_bypass_is_visible_as_full_access_in_preview(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory).resolve();owner='11111111-2222-4333-8444-555555555555'
            result=launch_plan.plan(source,'codex','base',[{'id':'base','label':'Base','model':'fixture-model','effort':'medium'}],session={'native_id':'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee','action':'resume','runtime':'codex','launcher_session_id':owner,'source_root':str(source),'native_home':'/private/owner-home','archived':False},grant={'source_root':str(source),'isolated':'1','harness_session_id':owner,'bypass':'1'})
        self.assertTrue(result['can_launch'])
        self.assertEqual(result['summary']['approval'],'never')
        self.assertEqual(result['summary']['sandbox'],'danger-full-access')
        self.assertIn('--dangerously-bypass-approvals-and-sandbox',result['args'])

    def test_resume_renders_preview_model_effort_and_context_explicitly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory).resolve();owner='11111111-2222-4333-8444-555555555555'
            result=launch_plan.plan(source,'codex','base',[{'id':'base','label':'Base','model':'fixture-model','effort':'medium'}],session={'native_id':'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee','action':'resume','runtime':'codex','launcher_session_id':owner,'source_root':str(source),'native_home':'/private/owner-home','archived':False},options={'approval':'on-request','sandbox':'read-only'})
        self.assertEqual(result['args'][:4],['codex','base','272k','--passthrough'])
        self.assertIn('-m',result['args'])
        self.assertIn(result['summary']['model'],result['args'])
        self.assertIn('model_reasoning_effort="medium"',result['args'])

    def test_existing_slack_approval_policy_is_reflected_in_capabilities_and_plan(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory);config=source/'config/launcher.env';config.parent.mkdir()
            config.write_text('HARNESS_CODEX_SLACK_APPS="asdk_app_fixture"\n')
            presets=[{'id':'base','label':'Base','model':'fixture-model','effort':'medium'}]
            capability=launch_plan.capabilities(source,'codex',presets)
            result=launch_plan.plan(source,'codex','base',presets)
            with self.assertRaisesRegex(launch_plan.PlanError,'unsupported_approval'):
                launch_plan.plan(source,'codex','base',presets,options={'approval':'never'})
        self.assertEqual(capability['approvals'],['on-request'])
        self.assertEqual(result['summary']['approval'],'on-request')
        self.assertEqual(result['args'][-2:],['-a','on-request'])

    def test_current_native_uuid_v7_can_resume_exactly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory).resolve()
            native='aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeeeee'
            result=launch_plan.plan(source,'codex','base',[{'id':'base','label':'Base','model':'fixture-model','effort':'medium'}],options={'approval':'on-request','sandbox':'read-only'},session={'native_id':native,'action':'resume','runtime':'codex','launcher_session_id':None,'source_root':str(source),'native_home':'/private/legacy-home','archived':False})
        self.assertTrue(result['can_launch'])
        self.assertIn(native,result['args'])

    def test_codex_capabilities_expose_only_configured_preset_models(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            presets = [
                {"id": "fast", "label": "Fast", "model": "gpt-6-luna", "effort": "low"},
                {"id": "base", "label": "Base", "model": "gpt-6-sol", "effort": "medium"},
            ]

            result = launch_plan.capabilities(source, "codex", presets)

        self.assertEqual(result["models"], ["gpt-6-luna", "gpt-6-sol"])
        self.assertEqual(result["efforts_by_model"], {
            "gpt-6-luna": ["low"],
            "gpt-6-sol": ["medium"],
        })
        self.assertEqual(result["contexts"], ["272k", "1m"])
        self.assertEqual(result["approvals"], ["on-request", "never"])
        self.assertEqual(result["sandboxes"], ["read-only", "workspace-write", "danger-full-access"])

    def test_claude_explicit_long_context_uses_its_native_model_alias(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = launch_plan.plan(
                Path(directory),
                "claude",
                "base",
                [{"id": "base", "label": "Base", "model": "claude-sonnet-4", "effort": "medium"}],
                options={"context": "1m"},
            )

        self.assertEqual(result["args"], [
            "base", "--passthrough", "--model", "claude-sonnet-4[1m]",
        ])
        self.assertEqual(result["summary"]["context"], "1m")

    def test_malformed_grant_provenance_requires_explicit_codex_permissions(self) -> None:
        session_id = "11111111-2222-4333-8444-555555555555"
        native_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            source_binding = str(source.resolve())
            result = launch_plan.plan(
                source,
                "codex",
                "base",
                [{"id": "base", "label": "Base", "model": "gpt-6-sol", "effort": "medium"}],
                session={
                    "native_id": native_id, "action": "resume", "runtime": "codex",
                    "launcher_session_id": session_id, "source_root": source_binding,
                    "native_home": "/private/session-home", "archived": False,
                },
                grant={
                    "source_root": source_binding, "isolated": "1", "harness_session_id": session_id,
                    "approval": "on-request", "sandbox": "workspace-write",
                    "grant_provenance": "not-a-bound-provenance-object",
                },
            )

        self.assertFalse(result["can_launch"])
        self.assertEqual(result["reason"], "explicit_permission_required")

    def test_claude_rejects_codex_approval_control(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(launch_plan.PlanError, "unsupported_approval"):
                launch_plan.plan(
                    Path(directory), "claude", "base",
                    [{"id": "base", "label": "Base", "model": "claude-sonnet-4", "effort": "medium"}],
                    options={"approval": "never"},
                )


if __name__ == "__main__":
    unittest.main()
