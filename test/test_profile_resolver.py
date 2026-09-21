#!/usr/bin/env python3
"""Fail-closed contract for the portable profile resolver."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "bin" / "harness_profile_resolver.py"
SPEC = importlib.util.spec_from_file_location("harness_profile_resolver", SOURCE)
resolver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resolver)


class ProfileResolverTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.registry = self.root / "profiles"
        self.registry.mkdir()
        self.alpha = self.root / "alpha"
        self.gamma = self.root / "gamma"
        for name, root in (("alpha", self.alpha), ("gamma", self.gamma)):
            (root / "config").mkdir(parents=True)
            (root / "config" / "launcher.env").write_text(f'HARNESS_PREFIX="{name}"\n')
            (self.registry / name).write_text(str(root) + "\n")

    def test_inside_project_and_worktree(self):
        worktree = self.alpha / "projects" / "app" / "worktrees" / "feature"
        worktree.mkdir(parents=True)
        selected = resolver.resolve(worktree, self.registry)
        self.assertEqual((selected.profile, selected.harness_root, selected.work_root),
                         ("alpha", self.alpha.resolve(), worktree.resolve()))

    def test_deepest_registered_boundary(self):
        nested = self.alpha / "projects" / "nested"
        (nested / "config").mkdir(parents=True)
        (nested / "config" / "launcher.env").write_text('HARNESS_PREFIX="nested"\n')
        (self.registry / "nested").write_text(str(nested) + "\n")
        self.assertEqual(resolver.resolve(nested, self.registry).profile, "nested")

    def test_duplicate_boundary_is_ambiguous(self):
        (self.registry / "duplicate").write_text(str(self.alpha) + "\n")
        with self.assertRaisesRegex(resolver.ResolutionError, "ambiguous"):
            resolver.resolve(self.alpha, self.registry)

    def test_outside_and_symlink_escape_fail(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.alpha / "escape").symlink_to(outside, target_is_directory=True)
        for cwd in (outside, self.alpha / "escape"):
            with self.subTest(cwd=cwd), self.assertRaisesRegex(resolver.ResolutionError, "no registered"):
                resolver.resolve(cwd, self.registry)

    def test_symlink_registry_entry_is_ignored(self):
        (self.registry / "linked").symlink_to(self.registry / "alpha")
        self.assertEqual(resolver.resolve(self.alpha, self.registry).profile, "alpha")

    def test_explicit_profile_must_match_location(self):
        with self.assertRaisesRegex(resolver.ResolutionError, "does not own"):
            resolver.resolve(self.alpha, self.registry, explicit_profile="gamma")
        self.assertEqual(resolver.resolve(self.alpha, self.registry, explicit_profile="alpha").profile, "alpha")

    def test_path_component_boundary(self):
        lookalike = self.root / "alphabet"
        lookalike.mkdir()
        with self.assertRaisesRegex(resolver.ResolutionError, "no registered"):
            resolver.resolve(lookalike, self.registry)

    def test_invalid_registry_or_missing_config_is_ignored(self):
        (self.registry / "gamma").write_text(str(self.root / "missing") + "\n")
        with self.assertRaisesRegex(resolver.ResolutionError, "no registered"):
            resolver.resolve(self.gamma, self.registry)

    def test_malformed_registry_path_is_ignored(self):
        (self.registry / "gamma").write_text("bad\x00path\n")
        with self.assertRaisesRegex(resolver.ResolutionError, "no registered"):
            resolver.resolve(self.gamma, self.registry)


if __name__ == "__main__":
    unittest.main()
