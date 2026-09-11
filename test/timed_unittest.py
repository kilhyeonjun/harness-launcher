#!/usr/bin/env python3
"""unittest runner that optionally writes one wall-time record per test."""

import json
import os
from pathlib import Path
import time
import unittest


REPORT_ENV = "HARNESS_UNITTEST_TIMING_REPORT"


class TimingTextTestResult(unittest.TextTestResult):
    def __init__(self, *args, clock=time.monotonic, **kwargs):
        super().__init__(*args, **kwargs)
        self.clock = clock
        self.started_at = {}
        self.timings = []

    def startTest(self, test):
        self.started_at[id(test)] = self.clock()
        super().startTest(test)

    def stopTest(self, test):
        started = self.started_at.pop(id(test))
        self.timings.append(
            {"id": test.id(), "elapsed_s": max(0.0, self.clock() - started)}
        )
        super().stopTest(test)


class TimingTextTestRunner(unittest.TextTestRunner):
    resultclass = TimingTextTestResult

    def __init__(self, *args, timing_report=None, clock=time.monotonic, **kwargs):
        super().__init__(*args, **kwargs)
        self.timing_report = Path(timing_report) if timing_report else None
        self.clock = clock

    def _makeResult(self):
        return self.resultclass(
            self.stream,
            self.descriptions,
            self.verbosity,
            clock=self.clock,
        )

    def run(self, test):
        result = super().run(test)
        if self.timing_report:
            payload = {"schema_version": 1, "tests": result.timings}
            self.timing_report.write_text(
                json.dumps(payload, indent=2) + "\n",
                encoding="utf-8",
            )
        return result


def runner_from_env():
    return TimingTextTestRunner(timing_report=os.environ.get(REPORT_ENV))
