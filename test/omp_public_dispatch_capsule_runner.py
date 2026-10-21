"""Stage the explicit pinned Git baseline for the public dispatch regression.

No network, production HOME/current lookup, fetch, imported old helper, or skip.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tempfile
import time

REVISION = "5faf9b91411faeb33f48beb0ab8b69a8575a0813"
MANIFEST_SHA256 = "9257d40f68c855094699dd44b26cb6a47895173c74324f161f374306ea2a94f7"
ROOT = Path(__file__).resolve().parents[1]


def run(options):
    # Only the exact source-controlled manifest supplies paths and sealed modes.
    raw = options.manifest.read_bytes()
    if hashlib.sha256(raw).hexdigest() != MANIFEST_SHA256:
        raise ValueError("OLD_CAPSULE_MANIFEST_MISMATCH")
    manifest = json.loads(raw)
    if manifest["revision"] != REVISION or len(manifest["files"]) != 102:
        raise ValueError("OLD_CAPSULE_MANIFEST_SHAPE")
    repository = options.baseline_repository.resolve(strict=True)
    staged = {}
    deadline = time.monotonic() + 30
    for name, item in manifest["files"].items():
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or str(path) != name:
            raise ValueError("OLD_CAPSULE_PATH")
        if item["mode"] not in (0o400, 0o500):
            raise ValueError("OLD_CAPSULE_MODE")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("OLD_CAPSULE_STAGE_TIMEOUT")
        # Exact already-present Git objects only; missing custody is a hard FAIL.
        result = subprocess.run(
            ["git", "--no-lazy-fetch", "-C", str(repository), "show", REVISION + ":" + name],
            stdin=subprocess.DEVNULL, capture_output=True, timeout=remaining,
            check=False,
        )
        if result.returncode or hashlib.sha256(result.stdout).hexdigest() != item["sha256"]:
            raise ValueError("OLD_CAPSULE_BLOB_MISMATCH: " + name)
        staged[name] = result.stdout
    # The fixture budget includes the manifest and all 102 historical payloads.
    if sum(map(len, staged.values())) != 1751525 or len(raw) != 12350:
        raise ValueError("OLD_CAPSULE_SIZE_MISMATCH")
    with tempfile.TemporaryDirectory(prefix="omp-old-capsule-") as temporary:
        capsule = Path(temporary) / "capsule"
        capsule.mkdir()
        try:
            for name, data in staged.items():
                target = capsule / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                target.chmod(manifest["files"][name]["mode"])
            (capsule / "manifest.json").write_bytes(raw)
            (capsule / "manifest.json").chmod(0o400)
            for current, _, _ in os.walk(capsule, topdown=False):
                Path(current).chmod(0o500)
            # Explicit operand reaches the same wrapper; nonempty args bypass
            # this staging branch and are forwarded unchanged to test-v3.
            result = subprocess.run(
                [options.shell, str(ROOT / "test/test-omp-public-dispatch.sh"),
                 "--old-snapshot-capsule", str(capsule)],
                stdin=subprocess.DEVNULL, timeout=180, check=False,
            )
            return result.returncode
        finally:
            # Reverse only this owned temporary sealing, on all exit paths.
            for current, _, files in os.walk(capsule):
                Path(current).chmod(0o700)
                for name in files:
                    target = Path(current) / name
                    if stat.S_ISREG(target.lstat().st_mode):
                        target.chmod(0o600)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-repository", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--shell", required=True)
    options = parser.parse_args()
    try:
        raise SystemExit(run(options))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("OMP_OLD_CAPSULE_STAGE_FAILED: " + str(error), file=sys.stderr)
        raise SystemExit(2)
