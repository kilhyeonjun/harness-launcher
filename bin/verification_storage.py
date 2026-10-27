#!/usr/bin/env python3
"""Resolve host-local verification scratch policy; never create or repair storage."""
from __future__ import annotations

import json
import os
import plistlib
import pwd
import stat
import subprocess
import sys
import uuid
from pathlib import Path


class VerificationStorageError(RuntimeError):
    """Configured verification storage is unsafe or unavailable."""


def _plain_path(value: object, label: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise VerificationStorageError(f"{label} must be an absolute normalized path")
    path = Path(value)
    if not path.is_absolute() or str(path) != value or ".." in path.parts:
        raise VerificationStorageError(f"{label} must be an absolute normalized path")
    return path


def _no_symlinks(path: Path) -> os.stat_result:
    for part in (*reversed(path.parents), path):
        info = part.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise VerificationStorageError(f"symlink in storage path: {part}")
        trusted_sticky = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
        if info.st_uid not in (0, os.getuid()) or (info.st_mode & 0o022 and not trusted_sticky):
            raise VerificationStorageError(f"unsafe storage ancestor ownership or permissions: {part}")
    return info


def private_directory(path: Path) -> Path:
    """Validate an already-admitted private scratch directory (not policy authority)."""
    path = _plain_path(str(path), "private scratch")
    try:
        info = _no_symlinks(path)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise VerificationStorageError(f"private scratch must be a uid-owned 0700 directory: {path}")
    except OSError as exc:
        raise VerificationStorageError(f"private scratch unavailable: {path}: {exc}") from exc
    return path


NESTED_LEASE_PREFIX = ".verification-lease-"


def nested_lifetimes_settled(path: Path) -> bool:
    """Observe parent-facing leases without granting authority or removing data."""
    private_directory(path)
    try:
        return not any(child.name.startswith(NESTED_LEASE_PREFIX) for child in path.iterdir())
    except OSError as exc:
        raise VerificationStorageError(f"cannot inspect nested verification lifetimes: {path}: {exc}") from exc


def _volume_info(mount: Path) -> dict:
    result = subprocess.run(
        ["/usr/sbin/diskutil", "info", "-plist", str(mount)],
        stdin=subprocess.DEVNULL, capture_output=True, timeout=5,
    )
    if result.returncode or len(result.stdout) > 65536:
        raise VerificationStorageError("diskutil volume inspection failed or exceeded size limit")
    try:
        info = plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException) as exc:
        raise VerificationStorageError("diskutil returned invalid volume metadata") from exc
    if not isinstance(info, dict):
        raise VerificationStorageError("diskutil returned invalid volume metadata")
    return info


def configured_root(home: Path | None = None) -> Path | None:
    """Return validated configured scratch, or None only for an absent policy.

    Default home belongs to the current account, independent of caller HOME.
    Explicit home is for controlled callers/tests, not an environment override.
    """
    try:
        account_home = Path(pwd.getpwuid(os.getuid()).pw_dir) if home is None else home
        policy = account_home / ".config" / "harness" / "verification-storage.json"
        # Check the chain even when the final file is absent: a dangling symlink
        # must never silently turn a configured policy into the default path.
        for part in (*reversed(policy.parents), policy):
            try:
                info = part.lstat()
            except FileNotFoundError:
                return None
            if stat.S_ISLNK(info.st_mode):
                raise VerificationStorageError(f"symlink in policy path: {part}")
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise VerificationStorageError("policy must be a uid-owned, non-group/world-writable regular file")
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        fd = os.open(policy, flags)
        with os.fdopen(fd, "rb") as handle:
            opened = os.fstat(handle.fileno())
            if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                raise VerificationStorageError("policy changed during validation")
            data = handle.read(8193)
        if len(data) > 8192:
            raise VerificationStorageError("policy exceeds 8192-byte limit")
        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise VerificationStorageError(f"duplicate policy key: {key}")
                result[key] = value
            return result
        config = json.loads(data, object_pairs_hook=unique_object)
        if not isinstance(config, dict) or set(config) != {"version", "mount", "volume_uuid", "root"} or type(config["version"]) is not int or config["version"] != 1:
            raise VerificationStorageError("policy requires exactly version=1, mount, volume_uuid and root")
        mount = _plain_path(config["mount"], "mount")
        root = _plain_path(config["root"], "root")
        try:
            expected_uuid = str(uuid.UUID(config["volume_uuid"]))
        except (ValueError, TypeError, AttributeError) as exc:
            raise VerificationStorageError("invalid policy volume_uuid") from exc
        if mount == root or mount not in root.parents:
            raise VerificationStorageError("scratch root must be strictly beneath mount")
        if sys.platform != "darwin":
            raise VerificationStorageError("configured verification storage requires Darwin")
        mount_info = _no_symlinks(mount)
        if not stat.S_ISDIR(mount_info.st_mode) or mount_info.st_dev == mount.parent.stat().st_dev:
            raise VerificationStorageError("configured mount is not a mounted filesystem")
        private_directory(root)
        if root.stat().st_dev != mount_info.st_dev:
            raise VerificationStorageError("scratch root is not on configured mount")
        live = _volume_info(mount)
        if live.get("MountPoint") != str(mount) or str(live.get("VolumeUUID", "")).lower() != expected_uuid:
            raise VerificationStorageError("live volume UUID or mount point does not match policy")
        if (live.get("FilesystemType") != "apfs" or live.get("Internal") is not False
                or live.get("GlobalPermissionsEnabled") is not True or live.get("Writable") is not True
                or live.get("ReadOnlyVolume") is True or live.get("ReadOnlyMedia") is True):
            raise VerificationStorageError("verification volume must be external, writable, ownership-enabled APFS")
        if not os.access(root, os.W_OK | os.X_OK):
            raise VerificationStorageError("verification scratch is not writable")
        return root
    except VerificationStorageError:
        raise
    except (OSError, KeyError, ValueError, subprocess.SubprocessError) as exc:
        raise VerificationStorageError(f"cannot resolve verification storage: {exc}") from exc


def main() -> int:
    check_lifetimes = len(sys.argv) == 3 and sys.argv[1] == "--settled"
    if len(sys.argv) != 1 and not check_lifetimes:
        print("usage: verification_storage.py [--settled PRIVATE_DIRECTORY]", file=sys.stderr)
        return 2
    try:
        if check_lifetimes:
            if not nested_lifetimes_settled(Path(sys.argv[2])):
                print("verification-storage: nested verification lifetime unresolved", file=sys.stderr)
                return 1
            return 0
        root = configured_root()
    except VerificationStorageError as exc:
        print(f"verification-storage: {exc}", file=sys.stderr)
        return 1
    if root is not None:
        print(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
