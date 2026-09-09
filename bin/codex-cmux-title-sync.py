#!/usr/bin/env python3
"""Fail-open Codex thread-name synchronizer for cmux tab titles."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import math
import threading
import time
from pathlib import Path


VALID_PREFIX = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")
CMUX_COMMAND_TIMEOUT_SECONDS = 8
BROKER_REQUEST_TIMEOUT_SECONDS = 120
RENAME_ATTEMPTS = 3
RETRY_DELAYS_SECONDS = (1, 2)


def sanitize_title(value: str) -> str:
    return "".join(
        ch for ch in value if not (ord(ch) < 32 or 127 <= ord(ch) < 160)
    ).strip()


def valid_prefix(value: str) -> bool:
    return bool(VALID_PREFIX.fullmatch(value))


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


def rename_tab(cmux: str, surface: str, title: str) -> str:
    try:
        result = subprocess.run(
            [cmux, "rename-tab", "--surface", surface, "--", title],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=CMUX_COMMAND_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return "rename_timeout"
    except (OSError, subprocess.SubprocessError):
        return "rename_failed"
    return "ok" if result.returncode == 0 else "rename_failed"


def current_tab_title(cmux: str, surface: str, workspace: str) -> str | None:
    command = [cmux, "--id-format", "both", "--json", "tree"]
    command.extend(["--workspace", workspace] if workspace else ["--all"])
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=1.5, check=False)
        tree = json.loads(result.stdout) if result.returncode == 0 else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    def surfaces(node):
        if isinstance(node, dict):
            if node.get("ref") == surface or node.get("surface_ref") == surface or node.get("id") == surface:
                yield node
            for value in node.values():
                yield from surfaces(value)
        elif isinstance(node, list):
            for value in node:
                yield from surfaces(value)
    for current in surfaces(tree):
        value = current.get("title") if isinstance(current, dict) else None
        if isinstance(value, str):
            return sanitize_title(value)
    return None


def wait_for_retry(owner_pid: int, delay_seconds: int) -> bool:
    deadline = time.monotonic() + delay_seconds
    while time.monotonic() < deadline:
        if not process_is_alive(owner_pid):
            return False
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(0.05, remaining))
    return process_is_alive(owner_pid)


def remove_status(status_path: Path) -> None:
    try:
        metadata = status_path.lstat()
        if stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid() and metadata.st_nlink == 1:
            status_path.unlink()
    except OSError:
        pass


def write_status(status_path: Path, owner_pid: int, attempt: int, state: str, error: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(status_path, flags, 0o600)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
            os.close(descriptor)
            return
        os.ftruncate(descriptor, 0)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump({"owner_pid": owner_pid, "attempt": attempt, "state": state, "error_category": error}, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
    except OSError:
        pass


def rename_with_retry(cmux: str, surface: str, title: str, owner_pid: int, status_path: Path) -> bool:
    last_error = "rename_failed"
    for attempt in range(1, RENAME_ATTEMPTS + 1):
        error = rename_tab(cmux, surface, title)
        if error == "ok":
            if attempt == 1:
                remove_status(status_path)
            else:
                write_status(status_path, owner_pid, attempt, "recovered", last_error)
            return True
        last_error = error
        if attempt < RENAME_ATTEMPTS and not wait_for_retry(owner_pid, RETRY_DELAYS_SECONDS[attempt - 1]):
            return False
    write_status(status_path, owner_pid, RENAME_ATTEMPTS, "exhausted", last_error)
    return False


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


def discover_claude_owner_pid() -> int | None:
    override = os.environ.get("CLAUDE_CMUX_TITLE_OWNER_PID", "")
    if override:
        return int(override) if override.isdecimal() and process_is_alive(int(override)) else None
    pid = os.getppid()
    for _ in range(24):
        if pid <= 1:
            return None
        try:
            command = subprocess.run(
                ["ps", "-p", str(pid), "-o", "comm="], capture_output=True,
                text=True, timeout=1, check=False,
            ).stdout.strip()
            parent = subprocess.run(
                ["ps", "-p", str(pid), "-o", "ppid="], capture_output=True,
                text=True, timeout=1, check=False,
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None
        if Path(command).name.startswith("claude"):
            return pid
        if not parent.isdecimal():
            return None
        pid = int(parent)
    return None


def resolve_cmux() -> str | None:
    override = os.environ.get("CLAUDE_CMUX_TITLE_CMUX_BIN", "") or os.environ.get("CODEX_CMUX_TITLE_CMUX_BIN", "")
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


def safe_regular_file(path: Path) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == os.getuid()
        and metadata.st_nlink == 1
    )


def open_private_read(path: Path):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
    except OSError:
        return None
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
        os.close(descriptor)
        return None
    return os.fdopen(descriptor, "r", encoding="utf-8", errors="replace")


def safe_state_dir(path: Path) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISDIR(metadata.st_mode)
        and metadata.st_uid == os.getuid()
        and not (stat.S_IMODE(metadata.st_mode) & 0o077)
        and path.name.startswith("launch.")
    )


def atomic_json(path: Path, payload: dict[str, object]) -> bool:
    """Write private launcher state without ever exposing a partial record."""
    if not safe_state_dir(path.parent):
        return False
    try:
        temporary = path.parent / f".{path.name}.{os.getpid()}.{time.time_ns()}"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(temporary, flags, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        return True
    except OSError:
        try:
            temporary.unlink()
        except (OSError, UnboundLocalError):
            pass
        return False


def read_claude_request(request_path: Path, state_dir: Path) -> tuple[str, str, int] | None:
    if request_path.parent != state_dir:
        return None
    try:
        stream = open_private_read(request_path)
        if stream is None:
            return None
        with stream:
            payload = json.load(stream)
    except (OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    session_id = payload.get("session_id")
    transcript_path = payload.get("transcript_path")
    owner_pid = payload.get("owner_pid")
    if not isinstance(session_id, str) or not session_id:
        return None
    if not isinstance(transcript_path, str) or not transcript_path:
        return None
    if not isinstance(owner_pid, int) or owner_pid <= 1:
        return None
    return session_id, transcript_path, owner_pid


def claude_title(transcript_path: Path, session_id: str) -> str | None:
    """Return the manual title when present; late automatic titles cannot replace it."""
    ai_title = None
    custom_title = None
    try:
        stream = open_private_read(transcript_path)
        if stream is None:
            return None
        with stream:
            for raw in stream:
                try:
                    record = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict) or record.get("sessionId") != session_id:
                    continue
                if record.get("type") == "custom-title":
                    value = record.get("customTitle")
                    if isinstance(value, str) and (cleaned := sanitize_title(value)):
                        custom_title = cleaned
                elif record.get("type") == "ai-title":
                    value = record.get("aiTitle")
                    if isinstance(value, str) and (cleaned := sanitize_title(value)):
                        ai_title = cleaned
    except OSError:
        return None
    return custom_title or ai_title


def transcript_signature(path: Path) -> tuple[int, int] | None:
    stream = open_private_read(path)
    if stream is None:
        return None
    try:
        metadata = os.fstat(stream.fileno())
        return metadata.st_size, metadata.st_mtime_ns
    finally:
        stream.close()


def write_claude_request(request_path: Path, state_dir: Path, session_id: str, transcript_path: str, owner_pid: int) -> bool:
    if request_path.parent != state_dir or not safe_state_dir(state_dir):
        return False
    return atomic_json(request_path, {
        "session_id": session_id,
        "transcript_path": transcript_path,
        "owner_pid": owner_pid,
    })


def remove_claude_ack(status_path: Path) -> None:
    try:
        stream = open_private_read(status_path)
        if stream is None:
            return
        with stream:
            payload = json.load(stream)
        if isinstance(payload, dict) and payload.get("broker_pid") == os.getpid():
            status_path.unlink()
    except (OSError, ValueError):
        pass


def cleanup_claude_launch_state(state_dir: Path, launcher_pid: int) -> None:
    """TUI exec has no shell finally; remove only this broker's seeded child."""
    owner = state_dir / "owner"
    try:
        if not safe_state_dir(state_dir) or not safe_regular_file(owner):
            return
        with open_private_read(owner) as stream:
            lines = stream.read().splitlines()
        if len(lines) != 2 or lines[0] != str(launcher_pid) or lines[1] != str(os.getpid()):
            return
        for name in ("request.json", "active.json", "owner", "claude.status.json"):
            candidate = state_dir / name
            if candidate.exists() and safe_regular_file(candidate):
                candidate.unlink()
        state_dir.rmdir()
    except (OSError, ValueError, AttributeError):
        pass


def rename_with_claude_heartbeat(
    cmux: str, surface: str, title: str, owner_pid: int, status_path: Path, ack_path: Path,
    ack_payload: dict[str, object], poll_seconds: float,
) -> bool:
    """Keep the exact-session lease fresh while cmux is allowed its bounded wait."""
    stop = threading.Event()

    def heartbeat() -> None:
        while not stop.wait(min(poll_seconds, 0.5)):
            atomic_json(ack_path, {**ack_payload, "heartbeat_unix": int(time.time())})

    worker = threading.Thread(target=heartbeat, daemon=True)
    worker.start()
    try:
        return rename_with_retry(cmux, surface, title, owner_pid, status_path)
    finally:
        stop.set()
        worker.join(timeout=1)


def write_legacy_owner(workspace: str, surface: str, title: str) -> None:
    """Reuse the Claude fallback's owner registry across a fresh launcher."""
    root = Path(os.environ.get("CMUX_TITLE_STATE_DIR", str(Path(os.environ.get("TMPDIR", "/tmp")) / "cmux-title-persist")))
    owners = root / "owners"
    try:
        if root.exists() or root.is_symlink():
            if not safe_state_dir_legacy(root):
                return
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if not safe_state_dir_legacy(root):
            return
        if owners.exists() or owners.is_symlink():
            if not safe_state_dir_legacy(owners):
                return
        owners.mkdir(mode=0o700, exist_ok=True)
        os.chmod(root, 0o700)
        os.chmod(owners, 0o700)
        if not safe_state_dir_legacy(root) or not safe_state_dir_legacy(owners):
            return
        key = hashlib.sha256(f"{workspace}\0{surface}".encode()).hexdigest()
        target = owners / key
        temporary = owners / f".{key}.{os.getpid()}.{time.time_ns()}"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(f"{workspace}\n{surface}\n{title}\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    except OSError:
        pass


def safe_state_dir_legacy(path: Path) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return stat.S_ISDIR(metadata.st_mode) and metadata.st_uid == os.getuid() and not (stat.S_IMODE(metadata.st_mode) & 0o077)


def claude_session_start() -> int:
    try:
        payload = json.load(sys.stdin)
    except (OSError, ValueError):
        return 0
    if not isinstance(payload, dict) or payload.get("hook_event_name") != "SessionStart":
        return 0
    session_id = payload.get("session_id")
    transcript_path = payload.get("transcript_path")
    request_raw = os.environ.get("CLAUDE_CMUX_TITLE_REQUEST_FILE", "")
    state_raw = os.environ.get("CLAUDE_CMUX_TITLE_STATE_DIR", "")
    if not isinstance(session_id, str) or not session_id or not isinstance(transcript_path, str) or not transcript_path:
        return 0
    if not request_raw or not state_raw:
        return 0
    owner_pid = discover_claude_owner_pid()
    if owner_pid is None or not process_is_alive(owner_pid):
        return 0
    write_claude_request(Path(request_raw), Path(state_raw), session_id, transcript_path, owner_pid)
    return 0


def claude_broker(request_raw: str, surface: str, prefix: str, runtime_home: str, launcher_pid_raw: str) -> int:
    if not valid_prefix(prefix) or not launcher_pid_raw.isdecimal():
        return 0
    request_path = Path(request_raw)
    state_dir = Path(os.environ.get("CLAUDE_CMUX_TITLE_STATE_DIR", str(Path(runtime_home) / ".cmux-title-sync")))
    if request_path.parent != state_dir or not safe_state_dir(state_dir):
        return 0
    cmux = resolve_cmux()
    if not cmux:
        return 0
    try:
        poll_seconds = float(os.environ.get("CLAUDE_CMUX_TITLE_POLL_SECONDS", "0.5"))
    except ValueError:
        return 0
    if not math.isfinite(poll_seconds):
        return 0
    poll_seconds = max(poll_seconds, 0.02)
    launcher_pid = int(launcher_pid_raw)
    status_path = state_dir / "active.json"
    last_request = None
    last_title = None
    prior_owned_title = None
    title_frozen = False
    last_transcript_signature = None
    observed_title = None
    try:
        while process_is_alive(launcher_pid):
            request = read_claude_request(request_path, state_dir)
            if request:
                session_id, transcript_raw, owner_pid = request
                assignment = (session_id, transcript_raw, owner_pid)
                if assignment != last_request:
                    prior_owned_title = last_title
                    last_request, last_title = assignment, None
                    last_transcript_signature, observed_title = None, None
                    title_frozen = False
                if process_is_alive(owner_pid):
                    transcript = Path(transcript_raw)
                    signature = transcript_signature(transcript)
                    if signature is not None and signature != last_transcript_signature:
                        observed_title = claude_title(transcript, session_id)
                        last_transcript_signature = signature
                    if signature is None:
                        time.sleep(poll_seconds)
                        continue
                    ack_payload: dict[str, object] = {
                        "uid": os.getuid(), "broker_pid": os.getpid(), "launcher_pid": launcher_pid,
                        "owner_pid": owner_pid, "session_id": session_id, "surface": surface,
                        "workspace": os.environ.get("CMUX_WORKSPACE_ID", ""),
                    }
                    atomic_json(status_path, {**ack_payload, "heartbeat_unix": int(time.time())})
                    if observed_title:
                        rendered = f"{observed_title} | {prefix}"
                        if rendered != last_title and not title_frozen:
                            current = current_tab_title(cmux, surface, str(ack_payload["workspace"]))
                            native = observed_title
                            spinner_native = native.lstrip("✳✻✽✶✢· ")
                            allowed = {"", "Claude Code", rendered, native, spinner_native}
                            allowed.update(f"{mark} {native}" for mark in "✳✻✽✶✢·")
                            if last_title is not None:
                                allowed.add(last_title)
                            if prior_owned_title is not None:
                                allowed.add(prior_owned_title)
                            # A cleared tab briefly exposes the shell title; wait for Claude's OSC.
                            if current is None or (current and (current.startswith(("~/", "/")) or "@" in current and ":" in current)):
                                time.sleep(poll_seconds)
                                continue
                            if current not in allowed:
                                title_frozen = True
                                time.sleep(poll_seconds)
                                continue
                            if not rename_with_claude_heartbeat(
                                cmux, surface, rendered, owner_pid, state_dir / "claude.status.json",
                                status_path, ack_payload, poll_seconds,
                            ):
                                break
                            last_title = rendered
                            write_legacy_owner(str(ack_payload["workspace"]), surface, rendered)
            time.sleep(poll_seconds)
    finally:
        remove_claude_ack(status_path)
        cleanup_claude_launch_state(state_dir, launcher_pid)
    return 0


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
    if not valid_prefix(prefix) or not launcher_pid_raw.isdecimal():
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
            f"{request_path}.status.json",
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
    status_path_raw: str = "",
) -> int:
    if not valid_prefix(prefix) or not owner_pid_raw.isdecimal():
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
        status_path = Path(status_path_raw) if status_path_raw else state_dir / f"{lock_key}.status.json"
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
                    if not rename_with_retry(cmux, surface, title, owner_pid, status_path):
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
    if not valid_prefix(prefix) or not codex_home or not surface:
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
        "",
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
    if len(sys.argv) == 2 and sys.argv[1] == "--claude-session-start":
        return claude_session_start()
    if len(sys.argv) == 7 and sys.argv[1] == "--claude-broker":
        return claude_broker(*sys.argv[2:])
    if len(sys.argv) in (10, 11) and sys.argv[1] == "--watch":
        return watch(*sys.argv[2:])
    if len(sys.argv) == 7 and sys.argv[1] == "--broker":
        return broker(*sys.argv[2:])
    return session_start()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(0)
