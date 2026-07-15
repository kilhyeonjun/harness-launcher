#!/usr/bin/env python3
"""Fail-open Codex thread-name synchronizer for cmux tab titles."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


VALID_PREFIXES = {"kh", "gp", "gd"}
CMUX_COMMAND_TIMEOUT_SECONDS = 8


def sanitize_title(value: str) -> str:
    return "".join(
        ch for ch in value if not (ord(ch) < 32 or 127 <= ord(ch) < 160)
    ).strip()


def latest_thread_name(index_path: Path, session_id: str) -> str | None:
    latest = None
    try:
        with index_path.open(encoding="utf-8", errors="replace") as stream:
            for raw in stream:
                try:
                    record = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict) or record.get("id") != session_id:
                    continue
                name = record.get("thread_name")
                if isinstance(name, str):
                    cleaned = sanitize_title(name)
                    if cleaned:
                        latest = cleaned
    except OSError:
        return None
    return latest


def process_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except (OSError, ValueError):
        return False
    return True


def rename_tab(cmux: str, surface: str, title: str) -> bool:
    try:
        result = subprocess.run(
            [cmux, "rename-tab", "--surface", surface, title],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=CMUX_COMMAND_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def discover_codex_owner_pid() -> int | None:
    override = os.environ.get("CODEX_CMUX_TITLE_OWNER_PID", "")
    if override:
        if override.isdecimal() and process_is_alive(int(override)):
            return int(override)
        return None

    pid = os.getppid()
    for _ in range(24):
        if pid <= 1:
            return None
        try:
            command = subprocess.run(
                ["ps", "-p", str(pid), "-o", "comm="],
                capture_output=True,
                text=True,
                timeout=1,
                check=False,
            ).stdout.strip()
            parent = subprocess.run(
                ["ps", "-p", str(pid), "-o", "ppid="],
                capture_output=True,
                text=True,
                timeout=1,
                check=False,
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None
        if Path(command).name.startswith("codex"):
            return pid
        if not parent.isdecimal():
            return None
        pid = int(parent)
    return None


def resolve_cmux() -> str | None:
    override = os.environ.get("CODEX_CMUX_TITLE_CMUX_BIN", "")
    if override:
        return override if os.path.isfile(override) and os.access(override, os.X_OK) else None
    located = shutil.which("cmux")
    if located:
        return located
    bundled = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    if os.path.isfile(bundled) and os.access(bundled, os.X_OK):
        return bundled
    return None


def watch(
    session_id: str,
    surface: str,
    prefix: str,
    codex_home: str,
    owner_pid_raw: str,
    cmux: str,
    state_dir_raw: str,
    poll_seconds_raw: str,
) -> int:
    if prefix not in VALID_PREFIXES or not owner_pid_raw.isdecimal():
        return 0
    owner_pid = int(owner_pid_raw)
    try:
        poll_seconds = max(float(poll_seconds_raw), 0.02)
    except ValueError:
        return 0

    state_dir = Path(state_dir_raw)
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        lock_key = hashlib.sha256(f"{session_id}\0{surface}".encode()).hexdigest()
        lock_path = state_dir / f"{lock_key}.lock"
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        lock_stream = os.fdopen(lock_fd, "a+")
        try:
            fcntl.flock(lock_stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            lock_stream.close()
            return 0
    except OSError:
        return 0

    index_path = Path(codex_home) / "session_index.jsonl"
    last_title = None
    try:
        while process_is_alive(owner_pid):
            name = latest_thread_name(index_path, session_id)
            if name:
                title = f"{name} | {prefix}"
                if title != last_title:
                    if not rename_tab(cmux, surface, title):
                        break
                    last_title = title
            time.sleep(poll_seconds)
    finally:
        lock_stream.close()
    return 0


def session_start() -> int:
    try:
        payload = json.load(sys.stdin)
    except (OSError, ValueError):
        return 0
    if not isinstance(payload, dict) or payload.get("hook_event_name") != "SessionStart":
        return 0

    session_id = payload.get("session_id")
    prefix = os.environ.get("HARNESS_PREFIX", "")
    codex_home = os.environ.get("CODEX_HOME", "")
    surface = os.environ.get("CMUX_SURFACE_ID", "")
    if not isinstance(session_id, str) or not session_id:
        return 0
    if prefix not in VALID_PREFIXES or not codex_home or not surface:
        return 0

    cmux = resolve_cmux()
    owner_pid = discover_codex_owner_pid()
    if not cmux or owner_pid is None:
        return 0

    state_dir = os.environ.get(
        "CODEX_CMUX_TITLE_STATE_DIR",
        str(Path(codex_home) / ".cmux-title-sync"),
    )
    poll_seconds = os.environ.get("CODEX_CMUX_TITLE_POLL_SECONDS", "0.5")
    watch_args = [
        session_id,
        surface,
        prefix,
        codex_home,
        str(owner_pid),
        cmux,
        state_dir,
        poll_seconds,
    ]
    try:
        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--watch", *watch_args],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except (OSError, subprocess.SubprocessError):
        return 0
    return 0


def main() -> int:
    if len(sys.argv) == 10 and sys.argv[1] == "--watch":
        return watch(*sys.argv[2:])
    return session_start()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(0)
