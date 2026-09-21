"""MCP script paths must keep their harness-root meaning in nested workspaces."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest


MODULE = Path(__file__).resolve().parents[1] / "bin" / "mcp_paths.py"
BIN = MODULE.parent
spec = importlib.util.spec_from_file_location("mcp_paths", MODULE)
mcp_paths = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp_paths)


class McpPathsTest(unittest.TestCase):
    def test_interpreter_script_is_rooted_and_other_arguments_are_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / "core" / "scripts" / "rag-cli.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            servers = {
                "rag": {"command": "bash", "args": ["${HARNESS_ROOT}/core/scripts/rag-cli.sh", "serve-mcp"]},
                "remote": {"command": "npx", "args": ["-y", "@example/mcp"]},
            }

            result = mcp_paths.normalize_servers(servers, root)

            self.assertEqual(result["rag"]["args"], [str(script.resolve()), "serve-mcp"])
            self.assertEqual(result["remote"], servers["remote"])
            self.assertEqual(servers["rag"]["args"][0], "${HARNESS_ROOT}/core/scripts/rag-cli.sh")

    def test_explicit_relative_script_outside_root_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "harness"
            root.mkdir()
            servers = {"bad": {"command": "bash", "args": ["${HARNESS_ROOT}/../outside.sh"]}}
            with self.assertRaisesRegex(ValueError, "outside harness root"):
                mcp_paths.normalize_servers(servers, root)

    def test_missing_root_relative_script_fails_before_launch(self):
        with tempfile.TemporaryDirectory() as temp:
            servers = {"bad": {"command": "bash", "args": ["${HARNESS_ROOT}/core/scripts/missing.sh"]}}
            with self.assertRaisesRegex(ValueError, "not a file"):
                mcp_paths.normalize_servers(servers, Path(temp))

    def test_relative_command_path_is_rejected_before_launch(self):
        with tempfile.TemporaryDirectory() as temp:
            servers = {"bad": {"command": "core/scripts/rag-cli.sh", "args": []}}
            with self.assertRaisesRegex(ValueError, "relative command path"):
                mcp_paths.normalize_servers(servers, Path(temp))

    def test_interpreter_script_after_options_or_without_slash_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            for command, args in (("bash", ["-e", "core/scripts/rag-cli.sh"]),
                                  ("bash", ["rag-cli.sh"]),
                                  ("python3.12", ["core/scripts/rag-cli.py"])):
                with self.subTest(command=command, args=args), self.assertRaisesRegex(ValueError, "relative script path"):
                    mcp_paths.normalize_servers({"bad": {"command": command, "args": args}}, Path(temp))

    def test_interpreter_option_values_are_not_mistaken_for_scripts(self):
        with tempfile.TemporaryDirectory() as temp:
            for command, args in (
                ("bash", ["-o", "pipefail", "/bin/bash"]),
                ("python3", ["-W", "ignore", "/bin/bash"]),
                ("node", ["--require", "ts-node/register", "/bin/bash"]),
            ):
                with self.subTest(command=command, args=args):
                    self.assertEqual(
                        mcp_paths.normalize_servers({"server": {"command": command, "args": args}}, Path(temp))["server"]["args"],
                        args,
                    )

    def test_runtime_adapters_materialize_the_same_nested_project_script(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "harness"
            nested = root / "projects" / "app"
            script = root / "core" / "scripts" / "rag-cli.sh"
            nested.mkdir(parents=True)
            script.parent.mkdir(parents=True)
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            (root / "CLAUDE.md").write_text("# Test harness\n", encoding="utf-8")
            (root / "mcp.local.json").write_text(json.dumps({"mcpServers": {
                "rag": {"command": "bash", "args": ["${HARNESS_ROOT}/core/scripts/rag-cli.sh", "serve-mcp"]}
            }}), encoding="utf-8")
            expected = str(script.resolve())
            fake_home = Path(temp) / "home"
            fake_home.mkdir()
            fake_codex = Path(temp) / "codex"
            fake_codex.write_text("#!/bin/sh\necho codex-cli 0.153.2\n", encoding="utf-8")
            fake_codex.chmod(0o755)
            environment = os.environ.copy()
            environment.update({"HOME": str(fake_home), "HARNESS_CODEX_BIN": str(fake_codex)})

            codex = subprocess.run(["bash", str(BIN / "codex-home-prepare.sh"), str(root)],
                                   cwd=nested, env=environment, capture_output=True, text=True)
            self.assertEqual(codex.returncode, 0, codex.stderr)
            with (root / ".harness/codex/config.toml").open("rb") as stream:
                self.assertEqual(tomllib.load(stream)["mcp_servers"]["rag"]["args"][0], expected)

            kiro = subprocess.run(["bash", str(BIN / "kiro-home-prepare.sh"), str(root)],
                                  cwd=nested, env=environment, capture_output=True, text=True)
            self.assertEqual(kiro.returncode, 0, kiro.stderr)
            kiro_config = json.loads((root / ".harness/kiro/settings/mcp.json").read_text())
            self.assertEqual(kiro_config["mcpServers"]["rag"]["args"][0], expected)

            for function in ("harness_claude_mcp_runtime_config", "harness_claude_light_mcp_config"):
                shell = subprocess.run(["bash", "-c", f'source "{BIN / "harness-common.sh"}"; {function} "{root}" "{BIN}"'],
                                       cwd=nested, env=environment, capture_output=True, text=True)
                self.assertEqual(shell.returncode, 0, shell.stderr)
                rendered = json.loads(Path(shell.stdout.strip()).read_text())
                self.assertEqual(rendered["mcpServers"]["rag"]["args"][0], expected)

    def test_kiro_light_does_not_validate_an_excluded_ssh_script(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "CLAUDE.md").write_text("# Harness\n", encoding="utf-8")
            (root / ".mcp.json").write_text(json.dumps({"mcpServers": {
                "ssh_rag": {"command": "bash", "args": ["${HARNESS_ROOT}/core/bin/start-ssh-mcp.sh", "rag"]},
                "docs": {"type": "http", "url": "https://example.test/mcp"},
            }}), encoding="utf-8")
            environment = os.environ.copy()
            environment.update({"HOME": str(root), "HARNESS_KIRO_MCP_PROFILE": "light"})
            result = subprocess.run(["bash", str(BIN / "kiro-home-prepare.sh"), str(root)],
                                    env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            rendered = json.loads((root / ".harness/kiro/settings/mcp.json").read_text())
            self.assertEqual(set(rendered["mcpServers"]), {"docs"})

    def test_claude_full_does_not_write_an_empty_runtime_config(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shell = subprocess.run(
                ["bash", "-c", f'source "{BIN / "harness-common.sh"}"; '
                 f'harness_claude_mcp_runtime_config "{root}" "{BIN}"'],
                capture_output=True, text=True,
            )
            self.assertEqual(shell.returncode, 0, shell.stderr)
            self.assertEqual(shell.stdout, "")
            self.assertFalse((root / ".harness/claude/mcp-full.json").exists())

    def test_isolated_claude_materializes_nonempty_config_outside_git_worktree(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "worktrees" / "session"
            root.mkdir(parents=True)
            (root / "mcp.local.json").write_text(json.dumps({"mcpServers": {
                "docs": {"command": "echo", "args": ["ready"]}
            }}), encoding="utf-8")
            session_id = "12345678-1234-1234-1234-123456789abc"
            state = base / "state"
            (state / "sessions" / session_id).mkdir(parents=True)
            environment = os.environ.copy()
            environment.update({"HARNESS_SESSION_ID": session_id,
                                "HARNESS_SESSION_ROOT": str(root),
                                "HARNESS_SESSION_STATE_HOME": str(state)})
            for function, filename in (("harness_claude_mcp_runtime_config", "mcp-full.json"),
                                       ("harness_claude_light_mcp_config", "mcp-light.json")):
                shell = subprocess.run(
                    ["bash", "-c", f'source "{BIN / "harness-common.sh"}"; '
                     f'{function} "{root}" "{BIN}"'],
                    env=environment, capture_output=True, text=True,
                )
                self.assertEqual(shell.returncode, 0, shell.stderr)
                expected = state / "sessions" / session_id / filename
                self.assertEqual(shell.stdout.strip(), str(expected))
                self.assertEqual(json.loads(expected.read_text())["mcpServers"]["docs"]["args"], ["ready"])
                self.assertEqual(expected.stat().st_mode & 0o777, 0o600)
                self.assertFalse((root / ".harness").exists())


if __name__ == "__main__":
    unittest.main()
