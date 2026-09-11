#!/usr/bin/env python3
"""Run isolated codex-home-prepare integration groups with bounded concurrency."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "test" / "test-codex-home-prepare.sh"
GROUP_ENV = "HARNESS_HOME_PREPARE_TEST_GROUP"
GROUPS = ("config-skills", "hooks", "generated")


def run_group(label):
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix=f"home-prepare-{label}.") as home:
        auth = Path(home) / ".codex" / "auth.json"
        auth.parent.mkdir(parents=True)
        auth.write_text("{}\n", encoding="utf-8")
        environment = dict(os.environ)
        environment["HOME"] = home
        environment[GROUP_ENV] = label
        command = [environment.get("ZSH_BIN", "/bin/zsh"), str(SCRIPT)]
        try:
            result = subprocess.run(
                command,
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            returncode, stdout, stderr = result.returncode, result.stdout, result.stderr
        except OSError as error:
            returncode, stdout, stderr = 127, "", str(error)
    return {
        "label": label,
        "returncode": returncode,
        "elapsed_s": time.monotonic() - started,
        "stdout": stdout,
        "stderr": stderr,
    }


def execute(groups, jobs, run=run_group):
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        return list(pool.map(run, groups))


def successful(reports):
    return all(report["returncode"] == 0 for report in reports)


def effective_jobs(requested_jobs, groups):
    return min(requested_jobs, len(groups))


def build_summary(reports, jobs, elapsed_s):
    return {
        "schema_version": 1,
        "jobs": jobs,
        "elapsed_s": elapsed_s,
        "groups": [
            {
                "label": report["label"],
                "returncode": report["returncode"],
                "elapsed_s": report["elapsed_s"],
            }
            for report in reports
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--jobs",
        type=int,
        choices=(1, 2, 3),
        default=os.environ.get("HARNESS_HOME_PREPARE_TEST_JOBS", "3"),
    )
    parser.add_argument("--group", action="append", choices=GROUPS)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    groups = tuple(args.group or GROUPS)
    if len(groups) != len(set(groups)):
        parser.error("duplicate --group selection")
    jobs = effective_jobs(args.jobs, groups)

    for group in groups:
        print(f"==> {group}", flush=True)
    started = time.monotonic()
    reports = execute(groups, jobs=jobs)
    elapsed_s = time.monotonic() - started
    for report in reports:
        print(
            f"--- {report['label']} ({report['elapsed_s']:.3f}s, "
            f"exit={report['returncode']}) ---",
            flush=True,
        )
        print(report["stdout"], end="")
        print(report["stderr"], end="", file=sys.stderr)

    summary = build_summary(reports, jobs=jobs, elapsed_s=elapsed_s)
    if args.report:
        args.report.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(
        f"HOME_PREPARE_TEST_TOTAL seconds={elapsed_s:.3f} "
        f"groups={len(groups)} jobs={jobs}"
    )
    return 0 if successful(reports) else 1


if __name__ == "__main__":
    raise SystemExit(main())
