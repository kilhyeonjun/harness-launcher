import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest
from unittest import mock
import importlib.util


ROOT = Path(__file__).resolve().parents[1]
RESOLVER = ROOT / "bin" / "codex-surface.py"
PREPARE = ROOT / "bin" / "codex-home-prepare.sh"
GLOBAL_MCP_MODULE_PATH = ROOT / "bin" / "codex_global_mcp.py"
GLOBAL_MCP_SPEC = importlib.util.spec_from_file_location(
    "codex_global_mcp_surface_test", GLOBAL_MCP_MODULE_PATH
)
assert GLOBAL_MCP_SPEC and GLOBAL_MCP_SPEC.loader
GLOBAL_MCP_MODULE = importlib.util.module_from_spec(GLOBAL_MCP_SPEC)
sys.modules[GLOBAL_MCP_SPEC.name] = GLOBAL_MCP_MODULE
GLOBAL_MCP_SPEC.loader.exec_module(GLOBAL_MCP_MODULE)


def write_skill(root: Path, directory: str, name: str, body: str, *, implicit=True) -> Path:
    skill_dir = root / directory
    skill_dir.mkdir(parents=True, exist_ok=True)
    (skill_dir / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: {name} fixture\n---\n\n{body}\n",
        encoding="utf-8",
    )
    agents = skill_dir / "agents"
    agents.mkdir(exist_ok=True)
    (agents / "openai.yaml").write_text(
        "policy:\n  allow_implicit_invocation: " + ("true\n" if implicit else "false\n"),
        encoding="utf-8",
    )
    return skill_dir / "SKILL.md"


def base_manifest() -> dict:
    return {
        "schema_version": 1,
        "repo": "fixture",
        "skills": {
            "source_precedence": [
                "codex-product",
                "repo-claude",
                "claude-plugin",
                "global-agents",
                "codex-only",
            ],
            "preserve_product_managed": True,
            "disabled_roots": [
                ".agents/skills",
                "${HOME}/.codex/superpowers/skills",
                "${CODEX_HOME}/plugins/cache/openai-curated-remote/superpowers",
            ],
            "duplicate_choices": {
                "project:*": "repo-claude",
                "skill-creator": "codex-product",
                "superpowers:*": "claude-plugin:superpowers@superpowers-marketplace",
            },
            "project": {
                "root": ".claude/skills",
                "implicit": ["alpha"],
                "explicit_only": ["project-explicit"],
                "unlisted": "disabled",
            },
            "commands": {
                "root": ".claude/commands",
                "explicit_only": [],
                "unlisted": "disabled",
            },
            "global_agents": {
                "root": "${HOME}/.agents/skills",
                "implicit": [],
                "explicit_only": ["agentation"],
                "unlisted": "disabled",
            },
            "claude_plugins": {
                "root": "${HOME}/.claude/plugins/cache",
                "unlisted_packages": "disabled",
                "packages": [
                    {
                        "id": "superpowers@superpowers-marketplace",
                        "implicit": ["brainstorming"],
                        "explicit_only": [],
                        "unlisted": "disabled",
                    },
                    {
                        "id": "watch@claude-video",
                        "implicit": [],
                        "explicit_only": ["watch"],
                        "unlisted": "disabled",
                    },
                ],
            },
            "codex_only": {
                "root": ".codex-only/repos/taste-skill/skills",
                "namespace": "taste-skill",
                "unlisted": "disabled",
                "profiles": {"default": [], "design": ["taste-skill:minimalist-ui"]},
            },
        },
        "mcp": {
            "definition_sources": [".mcp.json", "mcp.local.json", "codex-product"],
            "default_profile": "default",
            "mode": "exact",
            "required_in_all_profiles": ["harness-rag"],
            "profiles": {
                "default": {"enabled": ["context7", "harness-rag"]},
                "work": {"enabled": ["computer-use", "context7", "harness-rag", "jira"]},
            },
        },
    }


class SurfaceFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="codex-surface-test."))
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        self.home = self.tmp / "home"
        self.repo = self.tmp / "repo"
        self.codex_home = self.repo / ".harness" / "codex"
        self.home.mkdir()
        self.repo.mkdir()
        self.codex_home.mkdir(parents=True)

        self.alpha = write_skill(self.repo / ".claude" / "skills", "alpha-dir", "alpha", "canonical")
        self.project_explicit = write_skill(
            self.repo / ".claude" / "skills", "project-explicit", "project-explicit", "explicit"
        )
        self.mirror_alpha = write_skill(
            self.repo / ".agents" / "skills", "alpha", "alpha", "divergent mirror"
        )
        write_skill(self.repo / ".agents" / "skills", "unused-project", "unused-project", "unused")
        self.agentation = write_skill(self.tmp / "agent-store", "agentation", "agentation", "global")
        global_skills = self.home / ".agents" / "skills"
        global_skills.mkdir(parents=True)
        (global_skills / "agentation").symlink_to(self.agentation.parent, target_is_directory=True)
        write_skill(self.home / ".agents" / "skills", "unused-global", "unused-global", "unused")

        plugin_root = self.home / ".claude" / "plugins" / "cache"
        self.superpower = write_skill(
            plugin_root / "superpowers-marketplace" / "superpowers" / "6.1.1" / "skills",
            "brainstorming",
            "superpowers:brainstorming",
            "claude plugin",
        )
        write_skill(
            plugin_root / "superpowers-marketplace" / "superpowers" / "6.0.0" / "skills",
            "brainstorming",
            "superpowers:brainstorming",
            "old plugin",
        )
        self.watch = write_skill(
            plugin_root / "claude-video" / "watch" / "0.2.0" / "skills",
            "watch",
            "watch:watch",
            "watch plugin",
        )
        write_skill(
            plugin_root / "ykdojo" / "dx" / "1.0.0" / "skills", "gha", "dx:gha", "disallowed"
        )
        self.native_superpower = write_skill(
            self.home / ".codex" / "superpowers" / "skills",
            "brainstorming",
            "superpowers:brainstorming",
            "native divergent",
        )
        self.curated_superpower = write_skill(
            self.codex_home / "plugins" / "cache" / "openai-curated-remote" / "superpowers" / "1" / "skills",
            "brainstorming",
            "superpowers:brainstorming",
            "curated divergent",
        )
        self.taste = write_skill(
            self.repo / ".codex-only" / "repos" / "taste-skill" / "skills",
            "minimalist",
            "minimalist-ui",
            "taste",
        )

        system_root = self.home / ".codex" / "skills" / ".system"
        write_skill(system_root, "skill-creator", "skill-creator", "system")

        self.manifest = self.repo / "config" / "codex-surface.json"
        self.manifest.parent.mkdir()
        self.manifest.write_text(json.dumps(base_manifest(), indent=2) + "\n", encoding="utf-8")
        (self.repo / ".mcp.json").write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "context7": {"command": "context7"},
                        "harness-rag": {"command": "rag"},
                        "jira": {"command": "jira"},
                    }
                }
            ),
            encoding="utf-8",
        )

    def resolver_environment(self, **updates):
        env = dict(os.environ)
        for inherited in (
            "HARNESS_CODEX_MCP_PROFILE",
            "HARNESS_CODEX_SKILL_PROFILE",
            "HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST",
        ):
            env.pop(inherited, None)
        env.update(updates)
        return env

    def run_resolver(self, *extra, expect=0, **env_updates):
        command = [
            sys.executable,
            str(RESOLVER),
            "resolve",
            "--manifest",
            str(self.manifest),
            "--repo-root",
            str(self.repo),
            "--codex-home",
            str(self.codex_home),
            "--home",
            str(self.home),
            *extra,
        ]
        result = subprocess.run(
            command,
            env=self.resolver_environment(**env_updates),
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, expect, result.stderr)
        return result

    def read_catalog(self):
        return json.loads((self.codex_home / "skill-catalog.json").read_text(encoding="utf-8"))


class ResolverTests(SurfaceFixture):
    def test_exact_resolution_explicit_policy_and_managed_pruning(self):
        (self.project_explicit.parent / "agents" / "openai.yaml").write_text(
            "interface:\n  display_name: Project explicit\n"
            "policy:\n  allow_implicit_invocation: true\n"
            "dependencies:\n  tools:\n    - type: mcp\n      value: fixture\n",
            encoding="utf-8",
        )
        skills_dir = self.codex_home / "skills"
        skills_dir.mkdir()
        unmanaged = skills_dir / "user-owned"
        unmanaged.mkdir()
        (unmanaged / "keep").write_text("keep", encoding="utf-8")
        stale_target = self.tmp / "stale"
        stale_target.mkdir()
        (skills_dir / "old-managed").symlink_to(stale_target, target_is_directory=True)
        (skills_dir / ".harness-managed").write_text("old-managed\n", encoding="utf-8")

        self.run_resolver()
        catalog = self.read_catalog()
        by_name = {entry["name"]: entry for entry in catalog["skills"]}
        self.assertEqual(
            set(by_name),
            {
                "agentation",
                "alpha",
                "project-explicit",
                "skill-creator",
                "superpowers:brainstorming",
                "watch:watch",
            },
        )
        self.assertEqual(Path(by_name["alpha"]["source_path"]), self.alpha.resolve())
        self.assertEqual(Path(by_name["superpowers:brainstorming"]["source_path"]), self.superpower.resolve())
        self.assertEqual(
            by_name["skill-creator"]["exposed_path"],
            by_name["skill-creator"]["source_path"],
        )
        self.assertFalse((skills_dir / "skill-creator").exists())
        self.assertEqual(by_name["agentation"]["invocation"], "explicit_only")
        self.assertTrue((unmanaged / "keep").is_file())
        self.assertFalse((skills_dir / "old-managed").exists())

        explicit_path = Path(by_name["project-explicit"]["exposed_path"])
        explicit_yaml = (explicit_path.parent / "agents" / "openai.yaml").read_text()
        self.assertIn("allow_implicit_invocation: false", explicit_yaml)
        self.assertIn("display_name: Project explicit", explicit_yaml)
        self.assertIn("value: fixture", explicit_yaml)
        self.assertTrue(explicit_path.is_file())
        self.assertFalse(explicit_path.is_symlink())

        config = (self.codex_home / "surface.config.toml").read_text(encoding="utf-8")
        for disabled in (self.mirror_alpha, self.native_superpower, self.curated_superpower):
            self.assertIn(f'path = {json.dumps(str(disabled.resolve()))}', config)
        self.assertNotIn("${HOME}", json.dumps(catalog))
        self.assertNotIn("${CODEX_HOME}", json.dumps(catalog))
        self.assertFalse(any("dx:gha" == entry["name"] for entry in catalog["skills"]))

        before = (self.codex_home / "skill-catalog.json").stat().st_mtime_ns
        self.run_resolver()
        self.assertEqual(before, (self.codex_home / "skill-catalog.json").stat().st_mtime_ns)

    def test_design_profile_is_exact_and_missing_source_fails(self):
        self.run_resolver("--skill-profile", "design")
        names = {entry["name"] for entry in self.read_catalog()["skills"]}
        self.assertIn("taste-skill:minimalist-ui", names)
        self.taste.unlink()
        result = self.run_resolver("--skill-profile", "design", expect=2)
        self.assertIn("taste-skill:minimalist-ui", result.stderr)

    def test_divergent_duplicate_requires_manifest_choice(self):
        manifest = base_manifest()
        del manifest["skills"]["duplicate_choices"]["project:*"]
        self.manifest.write_text(json.dumps(manifest), encoding="utf-8")
        result = self.run_resolver(expect=2)
        self.assertIn("divergent duplicate", result.stderr)
        self.assertIn("alpha", result.stderr)

    def test_identical_selected_duplicates_follow_source_precedence(self):
        self.mirror_alpha.write_bytes(self.alpha.read_bytes())
        project = write_skill(
            self.repo / ".claude" / "skills", "identical", "identical", "same bytes"
        )
        global_target = write_skill(self.tmp / "identical-store", "identical", "identical", "same bytes")
        global_target.write_bytes(project.read_bytes())
        (self.home / ".agents" / "skills" / "identical").symlink_to(
            global_target.parent, target_is_directory=True
        )
        manifest = base_manifest()
        del manifest["skills"]["duplicate_choices"]["project:*"]
        manifest["skills"]["project"]["implicit"].append("identical")
        manifest["skills"]["global_agents"]["implicit"].append("identical")
        self.manifest.write_text(json.dumps(manifest), encoding="utf-8")
        self.run_resolver()
        entry = next(item for item in self.read_catalog()["skills"] if item["name"] == "identical")
        self.assertEqual(entry["source"], "repo-claude")
        self.assertEqual(Path(entry["source_path"]), project.resolve())

    def test_exact_mcp_profiles_validate_required_servers(self):
        self.run_resolver("--mcp-profile", "default")
        catalog = self.read_catalog()
        self.assertEqual(catalog["mcp"]["enabled"], ["context7", "harness-rag"])
        self.assertEqual(catalog["mcp"]["disabled"], ["jira"])
        self.run_resolver("--mcp-profile", "work")
        catalog = self.read_catalog()
        self.assertEqual(catalog["mcp"]["enabled"], ["computer-use", "context7", "harness-rag", "jira"])
        self.assertEqual(catalog["mcp"]["product_managed"], ["computer-use"])

        manifest = base_manifest()
        manifest["mcp"]["profiles"]["work"]["enabled"].remove("harness-rag")
        self.manifest.write_text(json.dumps(manifest), encoding="utf-8")
        result = self.run_resolver("--mcp-profile", "work", expect=2)
        self.assertIn("required_in_all_profiles", result.stderr)

    def test_global_allowlist_duplicate_with_product_source_fails(self):
        # Removing codex-product duplicate detection would silently let an
        # allowlisted global definition override the product-managed server.
        manifest = base_manifest()
        manifest["mcp"]["definition_sources"].append("codex-global-allowlist")
        self.manifest.write_text(json.dumps(manifest), encoding="utf-8")
        global_config = self.home / ".codex" / "config.toml"
        global_config.parent.mkdir(exist_ok=True)
        global_config.write_text(
            '[mcp_servers.computer-use]\ncommand = "global-computer-use"\n',
            encoding="utf-8",
        )

        result = self.run_resolver(
            expect=2,
            HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="computer-use",
        )

        self.assertIn("computer-use", result.stderr)
        self.assertIn("codex-product", result.stderr)

    def test_global_allowlist_duplicate_with_each_json_source_fails(self):
        for source_name in (".mcp.json", ".mcp.local.json", "mcp.local.json"):
            with self.subTest(source_name=source_name):
                server = {
                    ".mcp.json": "context7",
                    ".mcp.local.json": "local-dot",
                    "mcp.local.json": "local-bare",
                }[source_name]
                for local_name in (".mcp.local.json", "mcp.local.json"):
                    (self.repo / local_name).unlink(missing_ok=True)
                if source_name != ".mcp.json":
                    (self.repo / source_name).write_text(
                        json.dumps({"mcpServers": {server: {"command": "duplicate"}}}),
                        encoding="utf-8",
                    )
                manifest = base_manifest()
                manifest["mcp"]["definition_sources"].append("codex-global-allowlist")
                self.manifest.write_text(json.dumps(manifest), encoding="utf-8")
                global_config = self.home / ".codex" / "config.toml"
                global_config.parent.mkdir(exist_ok=True)
                global_config.write_text(
                    f'[mcp_servers.{server}]\ncommand = "global-{server}"\n',
                    encoding="utf-8",
                )

                result = self.run_resolver(
                    expect=2,
                    HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST=server,
                )

                self.assertIn(server, result.stderr)
                self.assertIn("codex-global-allowlist", result.stderr)

    def test_mcp_profile_policies_reject_invalid_shapes_and_membership(self):
        cases = {
            "non-object": [],
            "unknown-field": {"context7": {"tools": ["read"]}},
            "duplicate-tool": {"context7": {"enabled_tools": ["read", "read"]}},
            "empty-tool": {"context7": {"disabled_tools": [""]}},
            "overlap": {"context7": {"enabled_tools": ["read"], "disabled_tools": ["read"]}},
            "disabled-member": {"jira": {"enabled_tools": ["read"]}},
        }
        for label, policies in cases.items():
            with self.subTest(label=label):
                manifest = base_manifest()
                manifest["mcp"]["profiles"]["default"]["policies"] = policies
                self.manifest.write_text(json.dumps(manifest), encoding="utf-8")

                result = self.run_resolver(expect=2)

                self.assertIn("policies", result.stderr)

    def test_product_managed_mcp_policy_without_emitted_definition_fails(self):
        # Product/plugin-only computer-use has no generated [mcp_servers] table
        # where a tool policy could be applied.
        manifest = base_manifest()
        manifest["mcp"]["profiles"]["default"]["enabled"].append("computer-use")
        manifest["mcp"]["profiles"]["default"]["policies"] = {
            "computer-use": {"enabled_tools": ["computer-use"]}
        }
        self.manifest.write_text(json.dumps(manifest), encoding="utf-8")

        result = self.run_resolver(expect=2)

        self.assertIn("computer-use", result.stderr)
        self.assertIn("emitted MCP definition", result.stderr)

    def test_enabled_without_definition_is_dropped_not_fatal(self):
        # A server enabled in a profile but absent from every definition source
        # (e.g. a host-local MCP not present on this machine) is dropped, not fatal.
        # mcp.local.json (gitignored) thereby decides per-host exposure. A stderr
        # note keeps the drop visible so a typo does not vanish silently.
        manifest = base_manifest()
        manifest["mcp"]["profiles"]["default"]["enabled"].append("host-local-rag")
        self.manifest.write_text(json.dumps(manifest), encoding="utf-8")
        result = self.run_resolver("--mcp-profile", "default")
        catalog = self.read_catalog()
        self.assertEqual(catalog["mcp"]["enabled"], ["context7", "harness-rag"])
        self.assertNotIn("host-local-rag", catalog["mcp"]["enabled"])
        self.assertIn("host-local-rag", result.stderr)


@unittest.skipUnless(Path("/usr/bin/lockf").is_file(), "requires macOS /usr/bin/lockf")
class PrepareIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="codex-surface-prepare."))
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        self.home = self.tmp / "home"
        self.repo = self.tmp / "repo"
        self.codex_home = self.repo / ".harness" / "codex"
        self.home.mkdir()
        self.repo.mkdir()
        self.counter = self.tmp / "compiler-calls"
        self.no_marketplace = self.tmp / "no-marketplace"

        computer_plugin = self.no_marketplace / "plugins" / "computer-use"
        (computer_plugin / ".codex-plugin").mkdir(parents=True)
        (computer_plugin / ".codex-plugin" / "plugin.json").write_text(
            json.dumps({"name": "computer-use", "version": "1.0.0"}) + "\n",
            encoding="utf-8",
        )
        write_skill(
            computer_plugin / "skills",
            "computer-use",
            "computer-use",
            "bundled computer use workflow",
        )
        chrome_plugin = self.no_marketplace / "plugins" / "chrome" / ".codex-plugin"
        chrome_plugin.mkdir(parents=True)
        (chrome_plugin / "plugin.json").write_text(
            json.dumps({"name": "chrome", "version": "1.0.0"}) + "\n",
            encoding="utf-8",
        )

        write_skill(self.repo / ".claude" / "skills", "alpha", "alpha", "alpha v1")
        write_skill(
            self.repo / ".claude" / "skills", "explicit", "project-explicit", "explicit v1"
        )
        write_skill(self.repo / ".agents" / "skills", "unused-mirror", "unused-mirror", "disabled")
        plugin = write_skill(
            self.home
            / ".claude"
            / "plugins"
            / "cache"
            / "superpowers-marketplace"
            / "superpowers"
            / "6.1.1"
            / "skills",
            "brainstorming",
            "superpowers:brainstorming",
            "plugin v1",
        )
        self.plugin_skill = plugin

        manifest = base_manifest()
        manifest["skills"]["project"]["implicit"] = ["alpha"]
        manifest["skills"]["project"]["explicit_only"] = ["project-explicit"]
        manifest["skills"]["global_agents"]["explicit_only"] = []
        manifest["skills"]["claude_plugins"]["packages"] = [
            {
                "id": "superpowers@superpowers-marketplace",
                "implicit": ["brainstorming"],
                "explicit_only": [],
                "unlisted": "disabled",
            }
        ]
        manifest["skills"]["codex_only"]["profiles"] = {"default": []}
        manifest["mcp"]["profiles"] = {
            "default": {"enabled": ["context7", "harness-rag"]},
            "work": {"enabled": ["computer-use", "context7", "harness-rag", "jira"]},
        }
        (self.repo / "config").mkdir()
        self.manifest_path = self.repo / "config" / "codex-surface.json"
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        self.mcp_path = self.repo / ".mcp.json"
        self.mcp_path.write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "context7": {"command": "context7"},
                        "harness-rag": {"command": "rag"},
                        "jira": {"command": "jira"},
                    }
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        source = self.repo / ".claude" / "source"
        source.mkdir(parents=True)
        (source / "runtime-contract.yaml").write_text("version: 1\n", encoding="utf-8")
        compiler = self.repo / "core" / "scripts" / "harness_compile.py"
        compiler.parent.mkdir(parents=True)
        compiler.write_text(
            """import os
from pathlib import Path
import sys

repo = Path(sys.argv[-1])
counter = Path(os.environ["HARNESS_TEST_COMPILER_COUNTER"])
with counter.open("a", encoding="utf-8") as stream:
    stream.write("call\\n")
if os.environ.get("HARNESS_TEST_COMPILER_FAIL") == "1":
    raise SystemExit(23)
out = repo / ".harness" / "codex"
out.mkdir(parents=True, exist_ok=True)
(out / "AGENTS.md").write_text("# generated fixture\\n", encoding="utf-8")
""",
            encoding="utf-8",
        )
        (self.repo / "CLAUDE.md").write_text("# fixture\n", encoding="utf-8")
        hooks = self.repo / "core" / "hooks"
        hooks.mkdir(parents=True)
        (hooks / "session-start.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (self.repo / ".claude" / "settings.json").write_text("{\"hooks\": {}}\n", encoding="utf-8")

    def environment(self, **updates):
        env = dict(os.environ)
        for inherited in (
            "HARNESS_CODEX_MCP_PROFILE",
            "HARNESS_CODEX_SKILL_PROFILE",
            "HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST",
        ):
            env.pop(inherited, None)
        env.update(
            {
                "HOME": str(self.home),
                "HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE": str(self.no_marketplace),
                "HARNESS_TEST_COMPILER_COUNTER": str(self.counter),
            }
        )
        env.update(updates)
        return env

    def prepare(self, *, expect=0, **env_updates):
        result = subprocess.run(
            ["/bin/bash", str(PREPARE), str(self.repo)],
            env=self.environment(**env_updates),
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, expect, result.stderr)
        return result

    def compiler_calls(self):
        if not self.counter.exists():
            return 0
        return len(self.counter.read_text(encoding="utf-8").splitlines())

    def managed_output_paths(self):
        result = subprocess.run(
            [
                sys.executable,
                str(RESOLVER),
                "managed-output-paths",
                "--codex-home",
                str(self.codex_home),
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def snapshot_paths(self, relative_paths):
        snapshot = {}

        def capture(path, relative):
            if path.is_symlink():
                snapshot[relative] = ["symlink", os.readlink(path)]
            elif path.is_file():
                snapshot[relative] = ["file", hashlib.sha256(path.read_bytes()).hexdigest()]
            elif path.is_dir():
                snapshot[relative] = ["directory"]
                for child in sorted(path.iterdir(), key=lambda item: item.name):
                    capture(child, f"{relative}/{child.name}")
            else:
                snapshot[relative] = ["missing"]

        for relative in relative_paths:
            capture(self.codex_home / relative, relative)
        return snapshot

    def staging_artifacts(self):
        return sorted(self.codex_home.parent.glob(".codex-home-prepare-stage.*"))

    def enabled_value(self, server):
        config = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        match = re.search(
            rf"(?ms)^\[mcp_servers\.{re.escape(server)}\]\n(.*?)(?=^\[|\Z)", config
        )
        self.assertIsNotNone(match, f"missing MCP table for {server}")
        enabled = re.search(r"^enabled = (true|false)$", match.group(1), re.MULTILINE)
        self.assertIsNotNone(enabled, f"missing enabled flag for {server}")
        return enabled.group(1) == "true"

    def plugin_enabled(self, plugin):
        config = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        match = re.search(
            rf'(?ms)^\[plugins\."{re.escape(plugin)}@openai-bundled"\]\n(.*?)(?=^\[|\Z)',
            config,
        )
        self.assertIsNotNone(match, f"missing plugin table for {plugin}")
        return "enabled = true" in match.group(1)

    def test_profile_flags_and_warm_fingerprint_invalidation(self):
        # Installed plugins carry tests/docs/assets that are not copied into
        # the generated surface. A representative payload must not push the
        # warm launcher over its 100ms target.
        plugin_noise = self.plugin_skill.parents[2] / "tests" / "payload"
        plugin_noise.mkdir(parents=True)
        for index in range(1200):
            (plugin_noise / f"case-{index}.txt").write_text("noise\n", encoding="utf-8")
        self.prepare()
        self.assertEqual(self.compiler_calls(), 1)
        self.assertTrue(self.enabled_value("context7"))
        self.assertTrue(self.enabled_value("harness-rag"))
        self.assertFalse(self.enabled_value("jira"))
        self.assertFalse(self.plugin_enabled("computer-use"))
        self.assertFalse(self.plugin_enabled("chrome"))
        self.assertTrue((self.codex_home / ".surface-success.json").is_file())
        fingerprint_cache = json.loads(
            (self.codex_home / ".surface-fingerprint-cache.json").read_text(encoding="utf-8")
        )
        title_sync = os.path.realpath(ROOT / "bin" / "codex-cmux-title-sync.py")
        self.assertIn(
            title_sync,
            fingerprint_cache.get("files", {}),
            "cmux title helper is missing from the launcher-owned fingerprint",
        )

        warm_samples = []
        for _ in range(5):
            started = time.perf_counter()
            self.prepare()
            warm_samples.append(time.perf_counter() - started)
        elapsed = statistics.median(warm_samples)
        self.assertEqual(self.compiler_calls(), 1, "warm prepare reran the compiler")
        self.assertLess(
            elapsed,
            0.10,
            "median warm prepare took "
            f"{elapsed * 1000:.1f}ms; samples="
            + ",".join(f"{sample * 1000:.1f}" for sample in warm_samples),
        )

        # Runtime/auth state is deliberately outside the input fingerprint.
        (self.home / ".codex").mkdir(exist_ok=True)
        (self.home / ".codex" / "auth.json").write_text('{"token":"changed"}\n', encoding="utf-8")
        (self.codex_home / "sessions").mkdir()
        (self.codex_home / "sessions" / "one.jsonl").write_text("session\n", encoding="utf-8")
        with (self.codex_home / "config.toml").open("a", encoding="utf-8") as stream:
            stream.write("\n[hooks.state]\nenabled = false\n")
        self.prepare()
        self.assertEqual(self.compiler_calls(), 1)

        # Every launcher-owned source class must invalidate independently.
        alpha = self.repo / ".claude" / "skills" / "alpha" / "SKILL.md"
        alpha.write_text(alpha.read_text(encoding="utf-8") + "source change\n", encoding="utf-8")
        self.prepare()
        self.assertEqual(self.compiler_calls(), 2)

        mcp = json.loads(self.mcp_path.read_text(encoding="utf-8"))
        mcp["mcpServers"]["unused"] = {"command": "unused"}
        self.mcp_path.write_text(json.dumps(mcp, indent=2) + "\n", encoding="utf-8")
        self.prepare()
        self.assertEqual(self.compiler_calls(), 3)
        self.assertFalse(self.enabled_value("unused"))

        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["repo"] = "fixture-renamed"
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        self.prepare()
        self.assertEqual(self.compiler_calls(), 4)

        self.plugin_skill.write_text(
            self.plugin_skill.read_text(encoding="utf-8") + "plugin source change\n", encoding="utf-8"
        )
        self.prepare()
        self.assertEqual(self.compiler_calls(), 5)

        catalog = json.loads((self.codex_home / "skill-catalog.json").read_text(encoding="utf-8"))
        alpha_link = Path(next(item for item in catalog["skills"] if item["name"] == "alpha")["exposed_path"]).parent
        alpha_link.unlink()
        self.prepare()
        self.assertEqual(self.compiler_calls(), 6)

        self.prepare(HARNESS_CODEX_MCP_PROFILE="work")
        self.assertEqual(self.compiler_calls(), 7)
        self.assertTrue(self.enabled_value("jira"))
        self.assertTrue(self.plugin_enabled("computer-use"))
        self.assertFalse(self.plugin_enabled("chrome"))
        catalog = json.loads((self.codex_home / "skill-catalog.json").read_text(encoding="utf-8"))
        self.assertEqual(catalog["mcp"]["profile"], "work")
        self.assertIn(
            "computer-use:computer-use",
            {item["name"] for item in catalog["skills"]},
        )

    def test_global_allowlist_definitions_follow_exact_profiles_and_warm_digest(self):
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["mcp"]["definition_sources"].append("codex-global-allowlist")
        manifest["mcp"]["profiles"]["work"]["enabled"].append("global-tool")
        self.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        global_config = self.home / ".codex" / "config.toml"
        global_config.parent.mkdir(exist_ok=True)
        global_config.write_text(
            '[mcp_servers.global-tool]\ncommand = "global-v1"\nenabled = true\n\n'
            '[mcp_servers.unselected]\ncommand = "unselected-v1"\n',
            encoding="utf-8",
        )

        self.prepare(HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool")

        with (self.codex_home / "config.toml").open("rb") as stream:
            config = tomllib.load(stream)
        self.assertEqual(config["mcp_servers"]["global-tool"]["command"], "global-v1")
        self.assertFalse(config["mcp_servers"]["global-tool"]["enabled"])
        self.assertNotIn("unselected", config["mcp_servers"])
        self.assertEqual(self.compiler_calls(), 1)

        self.prepare(HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool")
        self.assertEqual(self.compiler_calls(), 1, "unchanged selected global MCP was not warm")

        global_config.write_text(
            '[mcp_servers.global-tool]\ncommand = "global-v1"\nenabled = true\n\n'
            '[mcp_servers.unselected]\ncommand = "unselected-v2"\n',
            encoding="utf-8",
        )
        self.prepare(HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool")
        self.assertEqual(self.compiler_calls(), 1, "unselected global MCP invalidated warm prepare")

        self.prepare(HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool,unselected")
        self.assertEqual(self.compiler_calls(), 2, "allowlist membership mutation stayed warm")

        global_config.write_text(
            '[mcp_servers.global-tool]\ncommand = "global-v2"\nenabled = true\n\n'
            '[mcp_servers.unselected]\ncommand = "unselected-v2"\n',
            encoding="utf-8",
        )
        self.prepare(HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool")
        self.assertEqual(self.compiler_calls(), 3)

        self.prepare(
            HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool",
            HARNESS_CODEX_MCP_PROFILE="work",
        )
        self.assertEqual(self.compiler_calls(), 4)
        self.assertTrue(self.enabled_value("global-tool"))

    def test_global_allowlist_emits_exact_profile_policies_without_source_drift(self):
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["mcp"]["definition_sources"].append("codex-global-allowlist")
        for profile in ("default", "work"):
            manifest["mcp"]["profiles"][profile]["enabled"].append("global-tool")
        manifest["mcp"]["profiles"]["default"]["policies"] = {
            "global-tool": {"enabled_tools": ["default-search"]}
        }
        manifest["mcp"]["profiles"]["work"]["policies"] = {
            "global-tool": {"disabled_tools": ["work-delete"]}
        }
        self.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        global_config = self.home / ".codex" / "config.toml"
        global_config.parent.mkdir(exist_ok=True)
        global_config.write_text(
            '[mcp_servers.global-tool]\ncommand = "global-command"\nargs = ["serve"]\n',
            encoding="utf-8",
        )

        self.prepare(HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool")

        catalog = json.loads((self.codex_home / "skill-catalog.json").read_text())
        with (self.codex_home / "config.toml").open("rb") as stream:
            default_config = tomllib.load(stream)["mcp_servers"]["global-tool"]
        self.assertEqual(
            catalog["mcp"]["policies"],
            {"global-tool": {"enabled_tools": ["default-search"]}},
        )
        self.assertEqual(default_config["enabled_tools"], ["default-search"])
        self.assertNotIn("disabled_tools", default_config)
        self.assertEqual(
            GLOBAL_MCP_MODULE.definition_projection(default_config, self.home),
            GLOBAL_MCP_MODULE.definition_projection(
                {"command": "global-command", "args": ["serve"]}, self.home
            ),
        )

        self.prepare(
            HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool",
            HARNESS_CODEX_MCP_PROFILE="work",
        )

        catalog = json.loads((self.codex_home / "skill-catalog.json").read_text())
        with (self.codex_home / "config.toml").open("rb") as stream:
            work_config = tomllib.load(stream)["mcp_servers"]["global-tool"]
        self.assertEqual(
            catalog["mcp"]["policies"],
            {"global-tool": {"disabled_tools": ["work-delete"]}},
        )
        self.assertEqual(work_config["disabled_tools"], ["work-delete"])
        self.assertNotIn("enabled_tools", work_config)
        self.assertEqual(
            GLOBAL_MCP_MODULE.definition_projection(work_config, self.home),
            GLOBAL_MCP_MODULE.definition_projection(
                {"command": "global-command", "args": ["serve"]}, self.home
            ),
        )
        calls = self.compiler_calls()
        self.prepare(
            HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool",
            HARNESS_CODEX_MCP_PROFILE="work",
        )
        self.assertEqual(self.compiler_calls(), calls, "matching policy fields did not stay warm")

    def test_selected_global_definition_edits_invalidate_or_fail_closed(self):
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["mcp"]["definition_sources"].append("codex-global-allowlist")
        manifest["mcp"]["profiles"]["default"]["enabled"].append("global-tool")
        self.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        global_config = self.home / ".codex" / "config.toml"
        global_config.parent.mkdir(exist_ok=True)
        valid = '[mcp_servers.global-tool]\ncommand = "global-v1"\n'
        global_config.write_text(valid, encoding="utf-8")
        self.prepare(HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool")

        global_config.write_text(valid + 'args = ["serve"]\n', encoding="utf-8")
        self.prepare(HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool")
        self.assertEqual(self.compiler_calls(), 2, "selected definition addition stayed warm")

        global_config.write_text(valid.replace("v1", "v2"), encoding="utf-8")
        self.prepare(HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool")
        self.assertEqual(self.compiler_calls(), 3, "selected definition change stayed warm")

        stamp = self.codex_home / ".surface-success.json"
        for broken in ("", ' [mcp_servers.global-tool]\nenabled = false\n', "[mcp_servers.global-tool\n"):
            with self.subTest(broken=broken):
                global_config.write_text(valid, encoding="utf-8")
                self.prepare(HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool")
                self.assertTrue(stamp.exists())
                global_config.write_text(broken, encoding="utf-8")
                result = subprocess.run(
                    ["/bin/bash", str(PREPARE), str(self.repo)],
                    env=self.environment(HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="global-tool"),
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertTrue(stamp.exists(), "failed global resolution removed the prior warm stamp")

    def test_fixture_environment_removes_inherited_surface_overrides(self):
        with mock.patch.dict(
            os.environ,
            {
                "HARNESS_CODEX_MCP_PROFILE": "work",
                "HARNESS_CODEX_SKILL_PROFILE": "design",
                "HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST": "inherited-only",
            },
        ):
            self.prepare()

        catalog = json.loads((self.codex_home / "skill-catalog.json").read_text())
        self.assertEqual(catalog["mcp"]["profile"], "default")
        self.assertFalse((self.home / ".codex" / "config.toml").exists())

    def test_nonlogin_system_python_path_falls_back_to_homebrew_python(self):
        if not any(
            path.is_file()
            for path in (
                Path("/opt/homebrew/opt/python@3.13/libexec/bin/python3"),
                Path("/usr/local/opt/python@3.13/libexec/bin/python3"),
            )
        ):
            self.skipTest("Homebrew Python path is not present")

        self.prepare(PATH="/usr/bin:/bin")

        self.assertEqual(self.compiler_calls(), 1)
        self.assertTrue((self.codex_home / ".surface-success.json").is_file())

    def test_curated_metadata_rewrite_stays_warm_but_new_version_invalidates(self):
        curated = (
            self.codex_home
            / "plugins"
            / "cache"
            / "openai-curated-remote"
            / "superpowers"
        )
        write_skill(
            curated / "1.0.0" / "skills",
            "curated-one",
            "superpowers:curated-one",
            "curated v1",
        )
        metadata = curated / ".codex-remote-plugin-install.json"
        metadata.write_text('{"schema_version":1}\n', encoding="utf-8")
        self.prepare()

        metadata.write_text('{"schema_version":1}\n', encoding="utf-8")
        self.prepare()
        self.assertEqual(
            self.compiler_calls(),
            1,
            "curated metadata-only rewrite invalidated the warm surface",
        )

        write_skill(
            curated / "2.0.0" / "skills",
            "curated-two",
            "superpowers:curated-two",
            "curated v2",
        )
        self.prepare()
        self.assertEqual(self.compiler_calls(), 2)

    def test_preflight_failure_preserves_every_managed_output(self):
        self.prepare()
        managed = self.managed_output_paths()
        self.assertEqual(
            managed,
            [
                ".surface-fingerprint-cache.json",
                ".surface-success.json",
                "AGENTS.md",
                "agents/.harness-managed",
                "base.config.toml",
                "config.toml",
                "fast.config.toml",
                "hooks.json",
                "plan.config.toml",
                "plugins/cache/openai-bundled/browser",
                "plugins/cache/openai-bundled/chrome",
                "plugins/cache/openai-bundled/computer-use",
                "rich.config.toml",
                "skill-catalog.json",
                "skills/.harness-managed",
                "skills/alpha",
                "skills/brainstorming",
                "skills/project-explicit",
                "sol.config.toml",
                "surface.config.toml",
            ],
        )
        before = self.snapshot_paths(managed)
        local_mcp = self.repo / ".mcp.local.json"
        local_mcp.write_text(
            json.dumps({"mcpServers": {"context7": {"command": "duplicate"}}}) + "\n",
            encoding="utf-8",
        )
        self.prepare(expect=2)
        self.assertEqual(self.snapshot_paths(managed), before)
        self.assertEqual(self.staging_artifacts(), [])

    def test_candidate_failure_and_signal_preserve_managed_and_runtime_state(self):
        self.prepare()
        managed = self.managed_output_paths()
        managed_before = self.snapshot_paths(managed)
        runtime = {
            "sessions/one.jsonl": "session\n",
            "history.jsonl": "history\n",
            "auth.json": "local-auth\n",
            "plugins/cache/user-runtime/state.json": "runtime-plugin\n",
            "skills/user-owned/SKILL.md": "---\nname: user-owned\n---\n",
        }
        for relative, content in runtime.items():
            path = self.codex_home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        runtime_before = self.snapshot_paths(runtime)
        alpha = self.repo / ".claude" / "skills" / "alpha" / "SKILL.md"
        alpha.write_text(alpha.read_text(encoding="utf-8") + "candidate rebuild\n", encoding="utf-8")

        self.prepare(expect=23, HARNESS_TEST_COMPILER_FAIL="1")
        self.assertEqual(self.snapshot_paths(managed), managed_before)
        self.assertEqual(self.snapshot_paths(runtime), runtime_before)
        self.assertEqual(self.staging_artifacts(), [])

        self.prepare(expect=86, HARNESS_TEST_CODEX_PREPARE_FAIL_AFTER_CANDIDATE="1")
        self.assertEqual(self.snapshot_paths(managed), managed_before)
        self.assertEqual(self.snapshot_paths(runtime), runtime_before)
        self.assertEqual(self.staging_artifacts(), [])

        process = subprocess.Popen(
            ["/bin/bash", str(PREPARE), str(self.repo)],
            env=self.environment(HARNESS_TEST_CODEX_PREPARE_PAUSE_AFTER_CANDIDATE="1"),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        for _ in range(500):
            if any(path.joinpath(".candidate-ready").exists() for path in self.staging_artifacts()):
                break
            time.sleep(0.01)
        else:
            process.kill()
            stdout, stderr = process.communicate()
            self.fail(f"candidate pause was not reached\nstdout={stdout}\nstderr={stderr}")
        process.terminate()
        process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.snapshot_paths(managed), managed_before)
        self.assertEqual(self.snapshot_paths(runtime), runtime_before)
        self.assertEqual(self.staging_artifacts(), [])

    def test_success_publishes_managed_outputs_without_touching_runtime_state(self):
        self.prepare()
        runtime = {
            "sessions/one.jsonl": "session\n",
            "history.jsonl": "history\n",
            "auth.json": "local-auth\n",
            "plugins/cache/user-runtime/state.json": "runtime-plugin\n",
            "skills/user-owned/SKILL.md": "---\nname: user-owned\n---\n",
        }
        for relative, content in runtime.items():
            path = self.codex_home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        before = self.snapshot_paths(runtime)
        alpha = self.repo / ".claude" / "skills" / "alpha" / "SKILL.md"
        alpha.write_text(alpha.read_text(encoding="utf-8") + "successful rebuild\n", encoding="utf-8")

        self.prepare()

        self.assertEqual(self.snapshot_paths(runtime), before)
        self.assertEqual(self.staging_artifacts(), [])

    def test_publish_failure_rolls_back_every_managed_output(self):
        self.prepare()
        managed = self.managed_output_paths()
        before = self.snapshot_paths(managed)
        alpha = self.repo / ".claude" / "skills" / "alpha" / "SKILL.md"
        alpha.write_text(alpha.read_text(encoding="utf-8") + "publish failure\n", encoding="utf-8")

        self.prepare(expect=1, HARNESS_TEST_CODEX_PREPARE_FAIL_DURING_PUBLISH="1")

        self.assertEqual(self.snapshot_paths(managed), before)
        self.assertEqual(self.staging_artifacts(), [])

    def test_hook_commands_shell_quote_special_harness_path(self):
        special = self.tmp / "repo 'quoted' $(not-executed) `still-not-executed`"
        self.repo.rename(special)
        self.repo = special
        self.codex_home = self.repo / ".harness" / "codex"
        self.manifest_path = self.repo / "config" / "codex-surface.json"
        self.mcp_path = self.repo / ".mcp.json"
        (self.repo / ".claude" / "settings.json").write_text(
            json.dumps(
                {
                    "hooks": {
                        "SessionStart": [
                            {
                                "hooks": [
                                    {
                                        "type": "command",
                                        "command": 'bash "$CLAUDE_PROJECT_DIR/core/hooks/session-start.sh"',
                                    }
                                ]
                            }
                        ]
                    }
                }
            )
            + "\n",
            encoding="utf-8",
        )

        self.prepare()

        hooks = json.loads((self.codex_home / "hooks.json").read_text(encoding="utf-8"))
        commands = []
        for groups in hooks.get("hooks", {}).values():
            for group in groups:
                for hook in group.get("hooks", []):
                    commands.append(hook["command"])
        self.assertTrue(commands)
        hooks_root = str(self.repo / "core" / "hooks") + os.sep
        for command in commands:
            argv = shlex.split(command)
            if "codex-cmux-title-sync.py" in command:
                self.assertEqual(len(argv), 2, command)
                self.assertEqual(
                    argv[1],
                    str(ROOT / "bin" / "codex-cmux-title-sync.py"),
                    command,
                )
                continue
            self.assertIn(len(argv), (2, 4), command)
            self.assertEqual(argv[0], "bash")
            self.assertTrue(argv[-1].startswith(hooks_root), command)

    def test_warm_path_rejects_conflicting_managed_skill_override(self):
        self.prepare()
        catalog = json.loads((self.codex_home / "skill-catalog.json").read_text(encoding="utf-8"))
        disabled = catalog["disabled_skill_paths"][0]
        with (self.codex_home / "config.toml").open("a", encoding="utf-8") as stream:
            stream.write(
                "\n[[skills.config]]\n"
                f"path = {json.dumps(disabled)}\n"
                "enabled = true\n"
            )
        self.prepare()
        self.assertEqual(self.compiler_calls(), 2)
        config = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        self.assertEqual(config.count(f"path = {json.dumps(disabled)}"), 1)
        block = config.split(f"path = {json.dumps(disabled)}", 1)[1].split("[[", 1)[0]
        self.assertIn("enabled = false", block)

    def test_selected_skill_override_is_removed(self):
        self.prepare()
        catalog = json.loads(
            (self.codex_home / "skill-catalog.json").read_text(encoding="utf-8")
        )
        selected = next(item for item in catalog["skills"] if item["name"] == "alpha")
        with (self.codex_home / "config.toml").open("a", encoding="utf-8") as stream:
            stream.write(
                "\n[[skills.config]]\n"
                f"path = {json.dumps(selected['exposed_path'])}\n"
                "enabled = false\n"
            )

        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        config = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        self.assertNotIn(f"path = {json.dumps(selected['exposed_path'])}", config)

    def test_single_quoted_commented_selected_override_is_removed(self):
        self.prepare()
        catalog = json.loads(
            (self.codex_home / "skill-catalog.json").read_text(encoding="utf-8")
        )
        selected = next(item for item in catalog["skills"] if item["name"] == "alpha")
        with (self.codex_home / "config.toml").open("a", encoding="utf-8") as stream:
            stream.write(
                "\n[[skills.config]]\n"
                f"path = '{selected['exposed_path']}'\n"
                "enabled = false # user choice\n"
            )

        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        with (self.codex_home / "config.toml").open("rb") as stream:
            config = tomllib.load(stream)
        configured = (config.get("skills") or {}).get("config") or []
        self.assertFalse(
            any(item.get("path") == selected["exposed_path"] for item in configured)
        )

    def test_unowned_generated_skill_is_preserved(self):
        self.prepare()
        rogue = write_skill(
            self.codex_home / "skills",
            "rogue-copy",
            "rogue-copy",
            "unowned generated-home drift",
        )

        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        self.assertTrue(rogue.parent.exists())
        quarantined = self.codex_home / ".surface-quarantine" / "skills" / "rogue-copy"
        self.assertFalse(quarantined.exists())

    def test_poisoned_managed_marker_cannot_claim_unowned_skill(self):
        self.prepare()
        rogue = write_skill(
            self.codex_home / "skills",
            "rogue-marker-bypass",
            "rogue-marker-bypass",
            "unowned marker poisoning",
        )
        marker = self.codex_home / "skills" / ".harness-managed"
        with marker.open("a", encoding="utf-8") as stream:
            stream.write("rogue-marker-bypass\n")

        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        self.assertTrue(rogue.parent.exists())
        quarantined = (
            self.codex_home
            / ".surface-quarantine"
            / "skills"
            / "rogue-marker-bypass"
        )
        self.assertFalse(quarantined.exists())
        self.assertNotIn("rogue-marker-bypass", marker.read_text(encoding="utf-8"))

    def test_poisoned_agent_marker_cannot_claim_unowned_agent(self):
        self.prepare()
        agents = self.codex_home / "agents"
        rogue = agents / "rogue.toml"
        rogue.write_text('name = "rogue"\n', encoding="utf-8")
        marker = agents / ".harness-managed"
        with marker.open("a", encoding="utf-8") as stream:
            stream.write("rogue.toml\n")

        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        self.assertTrue(rogue.exists())
        quarantined = (
            self.codex_home / ".surface-quarantine" / "agents" / "rogue.toml"
        )
        self.assertFalse(quarantined.exists())
        self.assertNotIn("rogue.toml", marker.read_text(encoding="utf-8"))

    def test_product_plugin_skill_drift_forces_rebuild(self):
        self.prepare(HARNESS_CODEX_MCP_PROFILE="work")
        catalog = json.loads(
            (self.codex_home / "skill-catalog.json").read_text(encoding="utf-8")
        )
        computer = next(
            item
            for item in catalog["skills"]
            if item["name"] == "computer-use:computer-use"
        )
        skill_path = Path(computer["source_path"])
        skill_path.write_text(
            skill_path.read_text(encoding="utf-8").replace(
                "name: computer-use", "name: computer-use-mutated", 1
            ),
            encoding="utf-8",
        )

        self.prepare(HARNESS_CODEX_MCP_PROFILE="work")

        self.assertEqual(self.compiler_calls(), 2)
        repaired = skill_path.read_text(encoding="utf-8")
        self.assertIn("name: computer-use\n", repaired)
        self.assertNotIn("computer-use-mutated", repaired)

    def test_warm_path_rejects_rogue_mcp_table(self):
        self.prepare()
        with (self.codex_home / "config.toml").open("a", encoding="utf-8") as stream:
            stream.write(
                "\n[mcp_servers.rogue]\n"
                'command = "rogue"\n'
                "enabled = true\n"
            )

        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        config = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        self.assertNotIn("[mcp_servers.rogue]", config)

    def test_warm_path_rejects_semantic_mcp_table_bypasses(self):
        for suffix in (
            '\n[mcp_servers]\nrogue_inline = { command = "printf", args = ["rogue"], enabled = true }\n',
            '\n[mcp_servers."rogue.dotted"]\ncommand = "printf"\nenabled = true\n',
        ):
            with self.subTest(suffix=suffix.splitlines()[1]):
                self.prepare()
                before = self.compiler_calls()
                with (self.codex_home / "config.toml").open("a", encoding="utf-8") as stream:
                    stream.write(suffix)

                self.prepare()

                self.assertEqual(self.compiler_calls(), before + 1)
                with (self.codex_home / "config.toml").open("rb") as stream:
                    config = tomllib.load(stream)
                self.assertEqual(
                    set(config.get("mcp_servers") or {}),
                    {"context7", "harness-rag", "jira"},
                )

    def test_warm_path_repairs_launcher_owned_output_drift(self):
        self.prepare()
        agents = self.codex_home / "AGENTS.md"
        with agents.open("a", encoding="utf-8") as stream:
            stream.write("ROGUE_ALWAYS_ON_SENTINEL\n")
        hooks = self.codex_home / "hooks.json"
        hooks.write_text(
            json.dumps(
                {
                    "hooks": {
                        "SessionStart": [
                            {"hooks": [{"type": "command", "command": "rogue"}]}
                        ]
                    }
                }
            )
            + "\n",
            encoding="utf-8",
        )

        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        self.assertNotIn("ROGUE_ALWAYS_ON_SENTINEL", agents.read_text(encoding="utf-8"))
        self.assertNotIn("rogue", hooks.read_text(encoding="utf-8"))

    def test_hook_entrypoint_removal_invalidates_warm_surface(self):
        self.prepare()
        hook = self.repo / "core" / "hooks" / "session-start.sh"
        hook.unlink()

        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        hooks = json.loads((self.codex_home / "hooks.json").read_text(encoding="utf-8"))
        commands = [
            item["command"]
            for groups in (hooks.get("hooks") or {}).values()
            for group in groups
            for item in group.get("hooks", [])
        ]
        self.assertFalse(any("session-start.sh" in command for command in commands))

    def test_warm_path_repairs_launcher_owned_config_semantics(self):
        self.prepare()
        config_path = self.codex_home / "config.toml"
        config = config_path.read_text(encoding="utf-8")
        config = config.replace('model = "gpt-5.6-terra"', 'model = "rogue-model"', 1)
        config = config.replace("apps = false", "apps = true", 1)
        config = config.replace("hooks = true", "hooks = false", 1)
        config = config.replace(
            'model_reasoning_effort = "medium"',
            'model_reasoning_effort = "medium"\n'
            'approval_policy = "never"\n'
            'sandbox_mode = "danger-full-access"\n'
            'model_context_window = 1000000',
            1,
        )
        config = config.replace(
            'command = "context7"', 'command = "/tmp/rogue-mcp"', 1
        )
        config_path.write_text(config, encoding="utf-8")

        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        with config_path.open("rb") as stream:
            repaired = tomllib.load(stream)
        self.assertEqual(repaired["model"], "gpt-5.6-terra")
        self.assertNotIn("approval_policy", repaired)
        self.assertNotIn("sandbox_mode", repaired)
        self.assertNotIn("model_context_window", repaired)
        self.assertEqual(repaired["mcp_servers"]["context7"]["command"], "context7")
        self.assertEqual(
            repaired["features"],
            {"apps": False, "goals": True, "hooks": True, "multi_agent": True},
        )

    def test_warm_path_rebuilds_missing_explicit_policy(self):
        self.prepare()
        catalog = json.loads(
            (self.codex_home / "skill-catalog.json").read_text(encoding="utf-8")
        )
        explicit = next(
            item for item in catalog["skills"] if item["name"] == "project-explicit"
        )
        policy = Path(explicit["exposed_path"]).parent / "agents" / "openai.yaml"
        policy.unlink()

        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        self.assertIn("allow_implicit_invocation: false", policy.read_text())

    def test_new_unapproved_plugin_invalidates_and_is_disabled(self):
        self.prepare()
        self.assertEqual(self.compiler_calls(), 1)
        unapproved = write_skill(
            self.home
            / ".claude"
            / "plugins"
            / "cache"
            / "extra-marketplace"
            / "extra-plugin"
            / "1.0.0"
            / "skills",
            "surprise",
            "surprise",
            "new unapproved plugin",
        )
        self.prepare()
        self.assertEqual(self.compiler_calls(), 2)
        catalog = json.loads(
            (self.codex_home / "skill-catalog.json").read_text(encoding="utf-8")
        )
        self.assertNotIn(
            "extra-plugin:surprise", {item["name"] for item in catalog["skills"]}
        )
        self.assertIn(str(unapproved.resolve()), catalog["disabled_skill_paths"])
        config = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        self.assertIn(f"path = {json.dumps(str(unapproved.resolve()))}", config)

    def test_new_unlisted_codex_only_skill_invalidates_empty_default_profile(self):
        self.prepare()
        self.assertEqual(self.compiler_calls(), 1)
        unlisted = write_skill(
            self.repo / ".codex-only" / "repos" / "taste-skill" / "skills",
            "surprise-design",
            "surprise-design",
            "new unlisted design skill",
        )

        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        catalog = json.loads(
            (self.codex_home / "skill-catalog.json").read_text(encoding="utf-8")
        )
        self.assertNotIn(
            "surprise-design", {item["name"] for item in catalog["skills"]}
        )
        self.assertIn(str(unlisted.resolve()), catalog["disabled_skill_paths"])

    def test_symlinked_skill_store_retarget_invalidates(self):
        first = self.tmp / "global-store-a"
        second = self.tmp / "global-store-b"
        first_skill = write_skill(first, "first", "first", "first global route")
        second_skill = write_skill(second, "second", "second", "second global route")
        global_parent = self.home / ".agents"
        global_parent.mkdir(parents=True)
        global_root = global_parent / "skills"
        global_root.symlink_to(first, target_is_directory=True)

        self.prepare()
        self.assertEqual(self.compiler_calls(), 1)
        global_root.unlink()
        global_root.symlink_to(second, target_is_directory=True)
        self.prepare()

        self.assertEqual(self.compiler_calls(), 2)
        catalog = json.loads(
            (self.codex_home / "skill-catalog.json").read_text(encoding="utf-8")
        )
        self.assertNotIn(str(first_skill.resolve()), catalog["disabled_skill_paths"])
        self.assertIn(str(second_skill.resolve()), catalog["disabled_skill_paths"])

    def test_manifest_skill_wins_command_collision_without_source_write(self):
        source_skill = write_skill(
            self.repo / ".claude" / "skills",
            "game-dev-loop",
            "game-dev-loop",
            "canonical project skill",
            implicit=True,
        )
        command_dir = self.repo / ".claude" / "commands"
        command_dir.mkdir()
        (command_dir / "game-dev-loop.md").write_text(
            "---\ndescription: generated command collision\n---\n\n# Command body\n",
            encoding="utf-8",
        )
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["skills"]["project"]["implicit"].append("game-dev-loop")
        manifest["skills"]["commands"]["explicit_only"].append("game-dev-loop")
        self.manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )

        skills_dir = self.codex_home / "skills"
        skills_dir.mkdir(parents=True)
        (skills_dir / "game-dev-loop").symlink_to(
            source_skill.parent, target_is_directory=True
        )
        (skills_dir / ".harness-managed").write_text(
            "game-dev-loop\n", encoding="utf-8"
        )
        (skills_dir / ".harness-managed-cmds").write_text(
            "game-dev-loop\n", encoding="utf-8"
        )
        skill_before = source_skill.read_bytes()
        policy = source_skill.parent / "agents" / "openai.yaml"
        policy_before = policy.read_bytes()

        self.prepare()

        self.assertEqual(source_skill.read_bytes(), skill_before)
        self.assertEqual(policy.read_bytes(), policy_before)
        self.assertIn("allow_implicit_invocation: true", policy.read_text())
        catalog = json.loads(
            (self.codex_home / "skill-catalog.json").read_text(encoding="utf-8")
        )
        entry = next(item for item in catalog["skills"] if item["name"] == "game-dev-loop")
        self.assertEqual(entry["invocation"], "implicit")
        exposed = Path(entry["exposed_path"])
        self.assertTrue(exposed.parent.is_symlink())
        self.assertEqual(exposed.resolve(), source_skill.resolve())
        self.assertFalse((skills_dir / ".harness-managed-cmds").exists())

    def test_manifest_explicit_command_remains_callable_without_prompt_exposure(self):
        command_dir = self.repo / ".claude" / "commands"
        command_dir.mkdir()
        command = command_dir / "daily-pipeline.md"
        command.write_text(
            "# Daily pipeline\n\nRun the daily pipeline in sequence.\n",
            encoding="utf-8",
        )
        before = command.read_bytes()
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["skills"]["commands"]["explicit_only"].append("daily-pipeline")
        self.manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )

        # Simulate a home prepared by the legacy command generator. Surface
        # mode must migrate this real directory before claiming the exact
        # command destination for its explicit-only wrapper.
        skills_dir = self.codex_home / "skills"
        legacy = skills_dir / "daily-pipeline"
        (legacy / "agents").mkdir(parents=True)
        (legacy / "SKILL.md").write_text(
            "---\n"
            "name: daily-pipeline\n"
            "description: Generated by codex-home-prepare.sh from "
            ".claude/commands/daily-pipeline.md\n"
            "---\n",
            encoding="utf-8",
        )
        (legacy / "agents" / "openai.yaml").write_text(
            "policy:\n  allow_implicit_invocation: false\n", encoding="utf-8"
        )
        (skills_dir / ".harness-managed-cmds").write_text(
            "daily-pipeline\n", encoding="utf-8"
        )

        self.prepare()

        self.assertEqual(command.read_bytes(), before)
        catalog = json.loads(
            (self.codex_home / "skill-catalog.json").read_text(encoding="utf-8")
        )
        entry = next(item for item in catalog["skills"] if item["name"] == "daily-pipeline")
        self.assertEqual(entry["source"], "repo-command")
        self.assertEqual(entry["invocation"], "explicit_only")
        exposed = Path(entry["exposed_path"])
        self.assertTrue((exposed.parent / ".harness-surface-wrapper").exists())
        self.assertFalse((skills_dir / ".harness-managed-cmds").exists())
        self.assertIn("name: daily-pipeline", exposed.read_text())
        self.assertIn(
            'description: "Run the daily pipeline in sequence."', exposed.read_text()
        )
        self.assertIn(
            "allow_implicit_invocation: false",
            (exposed.parent / "agents" / "openai.yaml").read_text(),
        )

    def test_legacy_command_marker_cannot_escape_skills_directory(self):
        skills_dir = self.codex_home / "skills"
        skills_dir.mkdir(parents=True)
        outside = self.codex_home / "outside"
        outside.mkdir()
        (outside / "SKILL.md").write_text(
            "---\n"
            "name: outside\n"
            "description: Generated by codex-home-prepare.sh from "
            ".claude/commands/outside.md\n"
            "---\n",
            encoding="utf-8",
        )
        (skills_dir / ".harness-managed-cmds").write_text(
            "../outside\n", encoding="utf-8"
        )

        self.prepare()

        self.assertTrue(outside.is_dir())
        self.assertTrue((outside / "SKILL.md").is_file())


if __name__ == "__main__":
    unittest.main()
