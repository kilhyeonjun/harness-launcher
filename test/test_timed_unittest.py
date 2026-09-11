import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("timed_unittest.py")


class TimedUnittestTests(unittest.TestCase):
    def load_module(self):
        if not MODULE_PATH.is_file():
            self.fail("timed unittest runner is missing")
        spec = importlib.util.spec_from_file_location("timed_unittest_test", MODULE_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_real_tests_emit_individual_wall_times_as_json(self):
        module = self.load_module()

        class Samples(unittest.TestCase):
            def test_first(self):
                pass

            def test_second(self):
                pass

        clock_values = iter((10.0, 10.25, 20.0, 20.5))
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "timings.json"
            runner = module.TimingTextTestRunner(
                stream=io.StringIO(),
                verbosity=0,
                timing_report=report,
                clock=lambda: next(clock_values),
            )
            result = runner.run(unittest.defaultTestLoader.loadTestsFromTestCase(Samples))
            self.assertTrue(result.wasSuccessful())
            payload = json.loads(report.read_text(encoding="utf-8"))

        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(
            [(entry["id"].rsplit(".", 1)[-1], entry["elapsed_s"]) for entry in payload["tests"]],
            [("test_first", 0.25), ("test_second", 0.5)],
        )


if __name__ == "__main__":
    unittest.main()
