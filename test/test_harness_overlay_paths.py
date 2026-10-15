#!/usr/bin/env python3
"""Contract tests for the per-session release-overlay path helper."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "bin" / "harness-overlay-paths.py"


def load_helper():
    spec = importlib.util.spec_from_file_location("harness_overlay_paths", HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class OverlayPathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helper = load_helper()

    def write_paths(self, paths):
        temporary = tempfile.NamedTemporaryFile(delete=False)
        self.addCleanup(Path(temporary.name).unlink, missing_ok=True)
        with temporary:
            temporary.write(b"\0".join(path.encode("utf-8") for path in paths) + b"\0")
        return Path(temporary.name)

    def test_deep_case_nfd_alias_matches(self):
        overlay = "a/b/c/d/e/Cafe\u0301"
        candidate = "A/B/C/D/E/CAFE\u0301/RULES/LONGS.MD"
        self.assertTrue(self.helper.path_matches(candidate, [overlay]))

    def test_nul_newline_and_literal_glob_paths(self):
        paths = ["overlay/line\nname", "overlay/[literal]*?.md"]
        path_file = self.write_paths(paths)
        pathspecs = self.helper.pathspecs_from_file(path_file, "exclude")
        self.assertEqual(
            pathspecs,
            [":(exclude,literal,icase)overlay/line\nname", ":(exclude,literal,icase)overlay/[literal]*?.md"],
        )
        self.assertEqual(
            self.helper.filter_paths(["OVERLAY/[LITERAL]*?.MD", "keep"], paths),
            ["keep"],
        )

    def test_4096_262144_boundaries(self):
        paths = [f"p/{index:04d}" for index in range(4096)]
        self.assertTrue(self.helper.can_use_argv(paths, "exclude"))
        self.assertFalse(self.helper.can_use_argv(paths + ["p/4096"], "exclude"))

        prefix = ":(exclude,literal,icase)"
        exact = ["x" * (262144 - len(prefix))]
        self.assertTrue(self.helper.can_use_argv(exact, "exclude"))
        self.assertFalse(self.helper.can_use_argv([exact[0] + "x"], "exclude"))

    def test_overlimit_rename_as_delete_add(self):
        overlays = [f"overlay/{index}" for index in range(4097)]
        self.assertEqual(
            self.helper.filter_path_statuses(
                [("R100", "overlay/0", "delivered"), ("M", "keep", None)], overlays
            ),
            [("R100", None, "delivered"), ("M", "keep", None)],
        )

    def test_harness_output_reset_but_not_overlay_compare(self):
        overlay = [".claude/skills/_index.md"]
        reset = self.helper.pathspecs_for_reset(overlay)
        self.assertIn(":(literal,icase).harness/", reset)
        self.assertFalse(self.helper.path_matches(".HARNESS/codex/AGENTS.md", overlay))
        self.assertTrue(self.helper.path_matches(".CLAUDE/SKILLS/_INDEX.MD", overlay))


if __name__ == "__main__":
    unittest.main()
