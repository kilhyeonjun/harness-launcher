#!/usr/bin/env python3
"""Fail-open Codex thread-name synchronizer for cmux tab titles."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path


VALID_PREFIXES = {"kh", "gp", "gd"}
CMUX_COMMAND_TIMEOUT_SECONDS = 8
BROKER_REQUEST_TIMEOUT_SECONDS = 120


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


def write_broker_request(
    request_path_raw: str,
    state_dir_raw: str,
    session_id: str,
    owner_pid: int,
) -> bool:
    request_path = Path(request_path_raw)
    try:
        if request_path.parent.resolve() != Path(state_dir_raw).resolve():
            return False
        metadata = request_path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
        ):
            return False
        flags = os.O_WRONLY | os.O_TRUNC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(request_path, flags)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump({"session_id": session_id, "owner_pid": owner_pid}, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
    except OSError:
        return False
    return True


def read_broker_request(request_path: Path) -> tuple[str, int] | None:
    try:
        payload = json.loads(request_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    session_id = payload.get("session_id")
    owner_pid = payload.get("owner_pid")
    if (
        not isinstance(session_id, str)
        or not session_id
        or not isinstance(owner_pid, int)
        or owner_pid <= 1
    ):
        return None
    return session_id, owner_pid


def broker(
    request_path_raw: str,
    surface: str,
    prefix: str,
    codex_home: str,
    launcher_pid_raw: str,
) -> int:
    request_path = Path(request_path_raw)
    state_dir = os.environ.get(
        "CODEX_CMUX_TITLE_STATE_DIR",
        str(Path(codex_home) / ".cmux-title-sync"),
    )
    request_is_owned = False

    def finish(result: int = 0) -> int:
        if request_is_owned:
            try:
                request_path.unlink()
            except OSError:
                pass
        return result

    try:
        metadata = request_path.lstat()
        if (
            request_path.parent.resolve() != Path(state_dir).resolve()
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
        ):
            return 0
        request_is_owned = True
    except OSError:
        return 0
    if prefix not in VALID_PREFIXES or not launcher_pid_raw.isdecimal():
        return finish()
    launcher_pid = int(launcher_pid_raw)
    cmux = resolve_cmux()
    if not cmux:
        return finish()
    try:
        poll_seconds = max(
            float(os.environ.get("CODEX_CMUX_TITLE_POLL_SECONDS", "0.5")),
            0.02,
        )
    except ValueError:
        return finish()

    deadline = time.monotonic() + BROKER_REQUEST_TIMEOUT_SECONDS
    request = None
    while process_is_alive(launcher_pid) and time.monotonic() < deadline:
        request = read_broker_request(request_path)
        if request:
            break
        time.sleep(poll_seconds)
    if not request:
        return finish()
    session_id, owner_pid = request
    return finish(
        watch(
            session_id,
            surface,
            prefix,
            codex_home,
            str(owner_pid),
            cmux,
            state_dir,
            str(poll_seconds),
        )
    )


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

    owner_pid = discover_codex_owner_pid()
    if owner_pid is None:
        return 0

    state_dir = os.environ.get(
        "CODEX_CMUX_TITLE_STATE_DIR",
        str(Path(codex_home) / ".cmux-title-sync"),
    )
    poll_seconds = os.environ.get("CODEX_CMUX_TITLE_POLL_SECONDS", "0.5")
    request_path = os.environ.get("CODEX_CMUX_TITLE_REQUEST_FILE", "")
    if request_path:
        write_broker_request(request_path, state_dir, session_id, owner_pid)
        return 0
    cmux = resolve_cmux()
    if not cmux:
        return 0
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
    if len(sys.argv) == 7 and sys.argv[1] == "--broker":
        return broker(*sys.argv[2:])
    return session_start()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(0)
