"""Unit tests for the allowlisted global Codex MCP resolver."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "bin" / "codex_global_mcp.py"
SPEC = importlib.util.spec_from_file_location("codex_global_mcp", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class GlobalMcpResolverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="codex-global-mcp-"))
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.config = self.home / "config.toml"

    def write_config(self, contents: str) -> None:
        self.config.write_text(contents, encoding="utf-8")

    def test_resolves_trimmed_deduplicated_allowlist_with_canonical_digest(self) -> None:
        self.write_config(
            """
[mcp_servers.glider]
command = "/Users/example/.local/bin/glider"
args = ["mcp", "serve"]

[mcp_servers.other]
url = "https://other.example/mcp"
""".lstrip()
        )

        result = MODULE.resolve_global_mcp(
            self.config, " glider, glider ", self.home
        )

        self.assertEqual(result.normalized_allowlist, ("glider",))
        self.assertEqual(result.definitions["glider"]["command"], "/Users/example/.local/bin/glider")
        self.assertEqual(len(result.digest), 64)
        self.assertNotIn("other", result.definitions)

    def test_rejects_disabled_or_ambiguous_or_missing_transport(self) -> None:
        for name, body in {
            "disabled": 'enabled = false\ncommand = "safe"',
            "dual": 'command = "safe"\nurl = "https://example.test/mcp"',
            "missing": 'args = ["serve"]',
        }.items():
            with self.subTest(name=name):
                self.write_config(f"[mcp_servers.{name}]\n{body}\n")
                with self.assertRaises(MODULE.GlobalMcpError) as raised:
                    MODULE.resolve_global_mcp(self.config, name, self.home)
                self.assertIn(name, str(raised.exception))

    def test_rejects_secret_fields_without_disclosing_values(self) -> None:
        self.write_config(
            """
[mcp_servers.glider]
command = "safe"
[mcp_servers.glider.env]
TOKEN = "top-secret-value"
""".lstrip()
        )

        with self.assertRaises(MODULE.GlobalMcpError) as raised:
            MODULE.resolve_global_mcp(self.config, "glider", self.home)

        message = str(raised.exception)
        self.assertIn("glider", message)
        self.assertIn("env", message)
        self.assertIn(str(self.config), message)
        self.assertNotIn("top-secret-value", message)

    def test_rejects_static_http_headers_without_disclosing_values(self) -> None:
        self.write_config(
            """
[mcp_servers.glider]
url = "https://example.test/mcp"
[mcp_servers.glider.http_headers]
Authorization = "Bearer very-secret"
""".lstrip()
        )
        with self.assertRaises(MODULE.GlobalMcpError) as raised:
            MODULE.resolve_global_mcp(self.config, "glider", self.home)
        self.assertIn("http_headers", str(raised.exception))
        self.assertNotIn("very-secret", str(raised.exception))

    def test_projection_normalizes_type_and_home_prefix_without_profile_fields(self) -> None:
        projected = MODULE.definition_projection(
            {
                "command": str(self.home / ".local/bin/glider"),
                "args": ["mcp", "serve"],
                "enabled": True,
            },
            self.home,
        )

        self.assertEqual(
            projected,
            {
                "type": "stdio",
                "command": "${HOME}/.local/bin/glider",
                "args": ["mcp", "serve"],
            },
        )

    def test_rejects_invalid_allowlist_names_and_preserves_input_order(self) -> None:
        self.write_config('[mcp_servers.alpha]\ncommand = "alpha"\n')
        self.assertEqual(
            MODULE.resolve_global_mcp(self.config, " alpha,alpha ", self.home).normalized_allowlist,
            ("alpha",),
        )
        with self.assertRaises(MODULE.GlobalMcpError):
            MODULE.resolve_global_mcp(self.config, "bad.name", self.home)

    def test_rejects_dates_arrays_of_tables_heterogeneous_arrays_and_nonfinite_numbers(self) -> None:
        cases = {
            "date": 'command = "safe"\n[ mcp_servers.date.env_vars ]\nstart = 2026-08-10',
            "array_table": 'command = "safe"\n[ mcp_servers.array_table.env_vars ]\nitems = [{ key = "value" }]',
            "heterogeneous": 'command = "safe"\nargs = ["one", 2]',
            "nan": 'command = "safe"\ntool_timeout_sec = nan',
        }
        for name, body in cases.items():
            with self.subTest(name=name):
                self.write_config(f"[mcp_servers.{name}]\n{body}\n")
                with self.assertRaises(MODULE.GlobalMcpError) as raised:
                    MODULE.resolve_global_mcp(self.config, name, self.home)
                self.assertIn(name, str(raised.exception))
                self.assertNotIn("fixture-secret", str(raised.exception))

    def test_accepts_nested_scalar_values_and_emits_projection_equivalent_toml(self) -> None:
        self.write_config(
            """
[mcp_servers.glider]
command = "/Users/example/.local/bin/glider"
args = ["mcp", "serve"]
env_vars = { LOG_LEVEL = "debug", RETRIES = 2 }
tool_timeout_sec = 1.5
""".lstrip()
        )
        result = MODULE.resolve_global_mcp(self.config, "glider", self.home)

        emitted = MODULE.emit_toml(result.definitions, enabled={"glider"})
        parsed = MODULE.tomllib.loads(emitted)["mcp_servers"]["glider"]

        self.assertEqual(
            MODULE.definition_projection(parsed, self.home),
            MODULE.definition_projection(result.definitions["glider"], self.home),
        )
        self.assertTrue(parsed["enabled"])
        self.assertEqual(parsed["env_vars"], {"LOG_LEVEL": "debug", "RETRIES": 2})

    def test_emits_nested_tables_with_scalar_values(self) -> None:
        self.write_config(
            """
[mcp_servers.glider]
command = "glider"
[mcp_servers.glider.env_vars]
LOG_LEVEL = "debug"
[mcp_servers.glider.env_vars.retry]
attempts = 2
""".lstrip()
        )
        result = MODULE.resolve_global_mcp(self.config, "glider", self.home)

        parsed = MODULE.tomllib.loads(MODULE.emit_toml(result.definitions, enabled=set()))

        self.assertEqual(parsed["mcp_servers"]["glider"]["env_vars"]["retry"]["attempts"], 2)
        self.assertFalse(parsed["mcp_servers"]["glider"]["enabled"])

    def test_compare_cli_returns_equal_invalid_and_mismatch_exit_codes(self) -> None:
        local = self.tmp / "local.json"
        local.write_text(
            json.dumps({"mcpServers": {"glider": {"type": "stdio", "command": "${HOME}/bin/glider", "args": ["mcp"]}}}),
            encoding="utf-8",
        )
        self.write_config('[mcp_servers.glider]\ncommand = "' + str(self.home / 'bin/glider') + '"\nargs = ["mcp"]\n')
        command = [sys.executable, str(MODULE_PATH), "compare", str(local), str(self.config), "glider", str(self.home)]
        self.assertEqual(subprocess.run(command, capture_output=True, text=True).returncode, 0)

        local.write_text(json.dumps({"mcpServers": {"glider": {"command": "other"}}}), encoding="utf-8")
        self.assertEqual(subprocess.run(command, capture_output=True, text=True).returncode, 3)

        malformed = self.tmp / "malformed.json"
        malformed.write_text("not json", encoding="utf-8")
        invalid = [sys.executable, str(MODULE_PATH), "compare", str(malformed), str(self.config), "glider", str(self.home)]
        self.assertEqual(subprocess.run(invalid, capture_output=True, text=True).returncode, 2)

    def test_projection_infers_streamable_http_type(self) -> None:
        self.assertEqual(
            MODULE.definition_projection({"url": "https://example.test/mcp"}, self.home)["type"],
            "streamable_http",
        )


if __name__ == "__main__":
    unittest.main()
