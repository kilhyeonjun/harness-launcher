import importlib.util
import os
from pathlib import Path
import subprocess
import threading
import time
import unittest
from unittest import mock


RUNNER_PATH = Path(__file__).with_name("home_prepare_test_runner.py")


class HomePrepareRunnerTests(unittest.TestCase):
    def load_runner(self):
        if not RUNNER_PATH.is_file():
            self.fail("home prepare group runner is missing")
        spec = importlib.util.spec_from_file_location("home_prepare_runner", RUNNER_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_all_groups_run_with_bounded_parallelism_and_failures_propagate(self):
        runner = self.load_runner()
        lock = threading.Lock()
        active = 0
        max_active = 0

        def run(group):
            nonlocal active, max_active
            with lock:
                active += 1
                max_active = max(max_active, active)
            time.sleep(0.02)
            with lock:
                active -= 1
            return {
                "label": group,
                "returncode": 7 if group == "hooks" else 0,
                "elapsed_s": 0.02,
                "stdout": group,
                "stderr": "",
            }

        reports = runner.execute(runner.GROUPS, jobs=2, run=run)
        self.assertEqual([report["label"] for report in reports], list(runner.GROUPS))
        self.assertEqual(max_active, 2)
        self.assertFalse(runner.successful(reports))

    def test_summary_records_each_group_wall_time(self):
        runner = self.load_runner()
        reports = [
            {"label": "config-skills", "returncode": 0, "elapsed_s": 1.25},
            {"label": "hooks", "returncode": 0, "elapsed_s": 2.5},
        ]
        self.assertEqual(
            runner.build_summary(reports, jobs=2, elapsed_s=2.75),
            {
                "schema_version": 1,
                "jobs": 2,
                "elapsed_s": 2.75,
                "groups": [
                    {"label": "config-skills", "returncode": 0, "elapsed_s": 1.25},
                    {"label": "hooks", "returncode": 0, "elapsed_s": 2.5},
                ],
            },
        )

    def test_effective_jobs_never_exceeds_selected_groups(self):
        runner = self.load_runner()
        self.assertEqual(runner.effective_jobs(3, ("hooks",)), 1)
        self.assertEqual(runner.effective_jobs(3, runner.GROUPS), 3)

    def test_each_group_process_gets_an_isolated_home(self):
        runner = self.load_runner()
        observed_homes = []

        def completed(command, **kwargs):
            home = kwargs["env"]["HOME"]
            self.assertTrue(Path(home).is_dir())
            self.assertEqual(
                (Path(home) / ".codex" / "auth.json").read_text(encoding="utf-8"),
                "{}\n",
            )
            observed_homes.append(home)
            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

        with mock.patch.object(runner.subprocess, "run", side_effect=completed):
            runner.run_group("config-skills")
            runner.run_group("hooks")

        self.assertEqual(len(set(observed_homes)), 2)
        self.assertNotIn(os.environ.get("HOME"), observed_homes)
        self.assertTrue(all(not Path(home).exists() for home in observed_homes))


if __name__ == "__main__":
    unittest.main()
