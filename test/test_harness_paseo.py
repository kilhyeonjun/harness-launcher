#!/usr/bin/env python3
"""Contract for harness-paseo config management (temp dirs only)."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

BIN = Path(__file__).resolve().parents[1] / "bin"
WRAPPER = BIN / "harness-paseo"


class PaseoTestCase(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.home = self.root / "home"
        self.profile_home = self.root / "launcher"
        self.paseo_home = self.root / "paseo"
        self.tools = self.root / "tools"
        for directory in (self.home, self.profile_home / "profiles", self.paseo_home, self.tools):
            directory.mkdir(parents=True)
        self.config = self.paseo_home / "config.json"
        self.sidecar = self.profile_home / "paseo-managed.json"
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        for tool in ("harness-auto", "harness-codex"):
            path = self.bin_dir / tool
            path.write_text("#!/bin/sh\n")
            path.chmod(0o755)

    def register(self, name):
        root = self.root / f"root-{name}"
        (root / "config").mkdir(parents=True, exist_ok=True)
        (root / "config" / "launcher.env").write_text("X=1\n")
        (self.profile_home / "profiles" / name).write_text(f"{root}\n")

    def write_config(self, data, mode=0o644):
        self.config.write_text(json.dumps(data))
        self.config.chmod(mode)

    def load(self):
        return json.loads(self.config.read_text())

    def env(self, **extra):
        env = {
            "HOME": str(self.home),
            "PATH": f"{self.tools}:/opt/homebrew/bin:/usr/bin:/bin",
            "HARNESS_PROFILE_HOME": str(self.profile_home),
            "PASEO_HOME": str(self.paseo_home),
        }
        env.update(extra)
        return env

    def run_cli(self, *args, wrapper=WRAPPER, **extra):
        return subprocess.run([str(wrapper), *args], capture_output=True, text=True,
                              env=self.env(**extra))

    def sync(self, *args, **extra):
        return self.run_cli("sync", "--config", str(self.config), "--bin-dir", str(self.bin_dir),
                            *args, **extra)

    def check(self, *args):
        return self.run_cli("check", "--config", str(self.config), "--bin-dir", str(self.bin_dir),
                            *args)

    def providers(self):
        return self.load()["agents"]["providers"]


class PrintTest(PaseoTestCase):
    def test_print_two_profiles(self):
        self.register("alpha")
        self.register("gamma_x")
        result = self.run_cli("print", "--bin-dir", "/x/bin")
        self.assertEqual(result.returncode, 0, result.stderr)
        providers = json.loads(result.stdout)["providers"]
        self.assertEqual(sorted(providers),
                         ["harness-claude", "harness-codex-alpha", "harness-codex-gamma-x"])
        self.assertEqual(providers["harness-claude"], {
            "extends": "claude", "label": "Harness Claude",
            "command": ["/x/bin/harness-auto", "claude", "base", "--passthrough"]})
        self.assertEqual(providers["harness-codex-gamma-x"], {
            "extends": "codex", "label": "gamma_x Codex",
            "command": ["/x/bin/harness-codex", "--profile", "gamma_x"]})

    def test_invalid_profile_ids_skipped(self):
        self.register("_lead")
        self.register("alpha")
        result = self.run_cli("print", "--bin-dir", "/x/bin")
        self.assertEqual(sorted(json.loads(result.stdout)["providers"]),
                         ["harness-claude", "harness-codex-alpha"])

    def test_collision_fails_and_skips_both(self):
        self.register("a_b")
        self.register("a-b")
        result = self.run_cli("print", "--bin-dir", "/x/bin")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL provider ID collision harness-codex-a-b", result.stderr)
        self.assertEqual(sorted(json.loads(result.stdout)["providers"]),
                         ["harness-claude"])


class SyncTest(PaseoTestCase):
    def test_missing_config_fails_without_creating(self):
        self.register("alpha")
        result = self.sync()
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL", result.stdout)
        self.assertIn("start Paseo once", result.stdout)
        self.assertFalse(self.config.exists())

    def test_merge_preserves_user_keys_and_provider_settings(self):
        self.register("alpha")
        self.write_config({
            "daemon": {"relay": {"enabled": False}},
            "agents": {"providers": {
                "custom": {"extends": "claude"},
                "harness-claude": {"extends": "old", "enabled": False, "order": 3,
                                   "env": {"A": "1"}, "models": ["m"]},
            }},
        })
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stdout)
        data = self.load()
        self.assertEqual(data["daemon"], {"relay": {"enabled": False}})
        providers = data["agents"]["providers"]
        self.assertEqual(providers["custom"], {"extends": "claude"})
        claude = providers["harness-claude"]
        self.assertEqual(claude["extends"], "claude")
        self.assertEqual((claude["enabled"], claude["order"], claude["env"], claude["models"]),
                         (False, 3, {"A": "1"}, ["m"]))
        self.assertEqual(providers["harness-codex-alpha"]["command"],
                         [f"{self.bin_dir}/harness-codex", "--profile", "alpha"])
        recorded = json.loads(self.sidecar.read_text())
        self.assertEqual(recorded["version"], 1)
        self.assertEqual(recorded["configs"][os.path.realpath(self.config)],
                         ["harness-claude", "harness-codex-alpha"])

    def test_owned_stale_removed_including_metadata(self):
        self.register("alpha")
        self.write_config({"agents": {"providers": {}}})
        self.sync()
        self.register("gamma")
        self.sync()
        data = self.load()
        data["agents"]["metadataGeneration"] = {
            "providers": {"harness-codex-gamma": {"x": 1}, "other": {}}}
        self.config.write_text(json.dumps(data))
        (self.profile_home / "profiles" / "gamma").unlink()
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stdout)
        data = self.load()
        self.assertNotIn("harness-codex-gamma", data["agents"]["providers"])
        self.assertEqual(data["agents"]["metadataGeneration"]["providers"], {"other": {}})

    def test_unowned_harness_provider_kept_with_warn(self):
        self.register("alpha")
        self.write_config({"agents": {"providers": {"harness-hand": {"extends": "codex"}}}})
        result = self.sync()
        self.assertIn("WARN unowned provider left untouched: harness-hand", result.stdout)
        self.assertIn("harness-hand", self.providers())

    def test_idempotent_second_sync_writes_nothing(self):
        self.register("alpha")
        self.write_config({"agents": {}})
        self.sync()
        backup = self.paseo_home / "config.json.harness-paseo.bak"
        self.assertTrue(backup.exists())
        backup.unlink()
        before = self.config.stat().st_mtime_ns
        result = self.sync()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.config.stat().st_mtime_ns, before)
        self.assertFalse(backup.exists())

    def test_backup_is_0600_original_bytes_and_mode_kept(self):
        self.register("alpha")
        self.write_config({"k": 1}, mode=0o640)
        original = self.config.read_bytes()
        self.sync()
        backup = self.paseo_home / "config.json.harness-paseo.bak"
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o640)

    def test_concurrent_change_aborts(self):
        self.register("alpha")
        self.write_config({"k": 1})
        sys.path.insert(0, str(BIN))
        self.addCleanup(sys.path.remove, str(BIN))
        spec = importlib.util.spec_from_file_location("harness_paseo_under_test", BIN / "harness_paseo.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        real_atomic_write = module.atomic_write

        def racing_atomic_write(path, data, mode):
            temp = real_atomic_write(path, data, mode)
            if path == self.config:
                self.config.write_text('{"k": 2}')  # Paseo rewrites between write and rename
            return temp

        module.atomic_write = racing_atomic_write
        out = io.StringIO()
        with mock.patch.dict(os.environ, self.env(), clear=True), contextlib.redirect_stdout(out):
            status = module.main(["sync", "--config", str(self.config), "--bin-dir", str(self.bin_dir)])
        self.assertEqual(status, 1)
        self.assertIn("FAIL", out.getvalue())
        self.assertEqual(self.load(), {"k": 2})
        self.assertEqual([p.name for p in self.paseo_home.iterdir() if p.name.startswith(".")], [])
        self.assertFalse((self.paseo_home / "config.json.harness-paseo.bak").exists())

    def test_symlinked_config_is_written_through(self):
        self.register("alpha")
        target = self.root / "dotfiles" / "config.json"
        target.parent.mkdir()
        target.write_text("{}")
        self.config.symlink_to(target)
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.config.is_symlink())
        self.assertIn("harness-claude", json.loads(target.read_text())["agents"]["providers"])

    def test_non_object_agents_fails_without_writing(self):
        self.register("alpha")
        self.write_config({"agents": []})
        original = self.config.read_bytes()
        result = self.sync()
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL Paseo config agents is not an object", result.stdout)
        self.assertEqual(self.config.read_bytes(), original)

    def test_stale_metadata_is_removed_when_the_provider_is_already_gone(self):
        self.register("alpha")
        self.register("gamma")
        self.write_config({})
        self.sync()
        data = self.load()
        del data["agents"]["providers"]["harness-codex-gamma"]
        data["agents"]["metadataGeneration"] = {"providers": ["harness-codex-gamma", "other"]}
        self.config.write_text(json.dumps(data))
        (self.profile_home / "profiles" / "gamma").unlink()
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.load()["agents"]["metadataGeneration"]["providers"], ["other"])

    def test_new_collision_keeps_the_owned_provider(self):
        self.register("a_b")
        self.write_config({})
        self.sync()
        self.register("a-b")
        result = self.sync()
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL provider ID collision harness-codex-a-b", result.stdout)
        self.assertIn("harness-codex-a-b", self.providers())
        recorded = json.loads(self.sidecar.read_text())["configs"][os.path.realpath(self.config)]
        self.assertIn("harness-codex-a-b", recorded)

    def test_adopting_a_hand_written_expected_provider_warns(self):
        self.register("alpha")
        self.write_config({"agents": {"providers": {"harness-claude": {"extends": "claude", "enabled": False}}}})
        result = self.sync()
        self.assertIn("WARN adopted existing provider: harness-claude", result.stdout)
        self.assertEqual(self.providers()["harness-claude"]["enabled"], False)
        self.assertNotIn("adopted", self.sync().stdout)

    def test_reload_runs_paseo_and_fails_open(self):
        self.register("alpha")
        self.write_config({})
        marker = self.root / "reloaded"
        fake = self.tools / "paseo"
        fake.write_text(f'#!/bin/sh\necho "$@" > "{marker}"\nexit 3\n')
        fake.chmod(0o755)
        result = self.sync("--reload")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(marker.read_text().strip(), "daemon reload")
        self.assertIn("WARN paseo daemon reload failed", result.stdout)


class CheckTest(PaseoTestCase):
    def synced(self, relay=False):
        self.register("alpha")
        self.write_config({"daemon": {"relay": {"enabled": relay}}})
        self.sync()

    def test_clean_check_passes(self):
        self.synced()
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("FAIL", result.stdout)
        self.assertNotIn("WARN", result.stdout)
        self.assertIn("OK provider harness-claude matches", result.stdout)

    def test_relay_not_false_warns(self):
        self.synced(relay=True)
        result = self.check()
        self.assertEqual(result.returncode, 0)
        self.assertIn("WARN daemon.relay.enabled is not false", result.stdout)

    def test_missing_bin_executables_fail(self):
        self.synced()
        (self.bin_dir / "harness-codex").unlink()
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL missing executable", result.stdout)

    def test_missing_provider_and_mismatch_fail(self):
        self.synced()
        data = self.load()
        del data["agents"]["providers"]["harness-claude"]
        data["agents"]["providers"]["harness-codex-alpha"]["label"] = "x"
        self.config.write_text(json.dumps(data))
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL missing provider: harness-claude", result.stdout)
        self.assertIn("FAIL provider harness-codex-alpha differs in: label", result.stdout)

    def test_stale_owned_fails(self):
        self.synced()
        (self.profile_home / "profiles" / "alpha").unlink()
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL stale owned provider: harness-codex-alpha", result.stdout)

    def test_missing_config_fails(self):
        self.register("alpha")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL Paseo config not found", result.stdout)
        self.assertFalse(self.config.exists())

    def test_unowned_warns_and_unregistered_profile_warns(self):
        self.synced()
        data = self.load()
        data["agents"]["providers"]["harness-hand"] = {}
        self.config.write_text(json.dumps(data))
        result = self.check("--profile", "nope")
        self.assertIn("WARN unowned provider left untouched: harness-hand", result.stdout)
        self.assertIn("WARN profile is not registered: nope", result.stdout)
        self.assertEqual(result.returncode, 0)

    def test_profile_filter_ignores_other_profiles(self):
        self.synced()
        self.register("gamma")
        result = self.check("--profile", "alpha")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_collision_fails(self):
        self.synced()
        self.register("a_b")
        self.register("a-b")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL provider ID collision", result.stdout)

    def test_bin_in_git_checkout_warns_only_for_tracked_files(self):
        self.synced()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        result = self.check()
        self.assertNotIn("Git checkout", result.stdout)  # untracked, like a Homebrew prefix
        subprocess.run(["git", "-C", str(self.root), "add", "bin/harness-auto"], check=True)
        result = self.check()
        self.assertIn("WARN bin directory resolves into a Git checkout", result.stdout)


class BinDirDefaultTest(PaseoTestCase):
    def test_default_bin_dir_is_unresolved_invocation_dir(self):
        link_dir = self.root / "link-bin"
        link_dir.mkdir()
        link = link_dir / "harness-paseo"
        link.symlink_to(WRAPPER)
        result = self.run_cli("print", wrapper=link)
        self.assertEqual(result.returncode, 0, result.stderr)
        command = json.loads(result.stdout)["providers"]["harness-claude"]["command"]
        self.assertEqual(command[0], f"{link_dir}/harness-auto")


if __name__ == "__main__":
    unittest.main()
