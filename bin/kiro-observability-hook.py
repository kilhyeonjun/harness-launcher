#!/usr/bin/env python3
"""Metadata-only, nonblocking Kiro hook adapter for a fixed local OTLP collector."""
from __future__ import annotations

import fcntl
import http.client
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
from typing import Any

OTLP_HOST = "127.0.0.1"
OTLP_PORT = 4318
OTLP_PATH = "/v1/logs"
MAX_INPUT_BYTES = 1_048_576
MAX_QUEUE_FILES = 256
MAX_DRAIN_FILES = 64
QUEUE_TTL_SECONDS = 3600
_ALLOWED_PROFILES = {"kh", "gp", "gd"}
_SAFE_TOOL_NAMES = {
    "execute_bash", "fs_read", "fs_write", "web_search", "use_aws",
    "knowledge", "thinking", "todo_list", "introspect",
}
_ALLOWED_EVENTS = {
    "agentSpawn": "kiro.session.start",
    "postToolUse": "kiro.tool_call",
}


def _default_queue_dir() -> Path:
    override = os.environ.get("HARNESS_KIRO_OBS_QUEUE_DIR")
    return Path(override) if override else Path(f"/tmp/harness-kiro-observability-{os.getuid()}")


def _value(value: Any) -> dict[str, Any]:
    if isinstance(value, bool):
        return {"boolValue": value}
    if isinstance(value, int):
        return {"intValue": str(value)}
    return {"stringValue": str(value)}


def _attrs(values: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {"key": key, "value": _value(value)}
        for key, value in values.items()
        if value is not None and value != ""
    ]


def _payload(event_name: str, profile: str, tool_name: str = "") -> dict[str, Any]:
    return {
        "resourceLogs": [
            {
                "resource": {
                    "attributes": _attrs(
                        {
                            "service.name": "kiro_cli",
                            "obs.runtime": "kiro",
                            "obs.profile": profile,
                        }
                    )
                },
                "scopeLogs": [
                    {
                        "scope": {"name": "agent.obs.v0.1.kiro"},
                        "logRecords": [
                            {
                                "timeUnixNano": str(time.time_ns()),
                                "severityText": "INFO",
                                "body": {"stringValue": event_name},
                                "attributes": _attrs(
                                    {
                                        "status": "observed",
                                        "tool.name": tool_name,
                                    }
                                ),
                            }
                        ],
                    }
                ],
            }
        ]
    }


def _queue_files(queue_dir: Path) -> list[Path]:
    try:
        return sorted(queue_dir.glob("*.json"), key=lambda path: path.name)
    except OSError:
        return []


def _prepare_queue(queue_dir: Path) -> bool:
    try:
        queue_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        queue_dir.chmod(0o700)
        return True
    except OSError:
        return False


def _enqueue(payload: dict[str, Any], queue_dir: Path) -> bool:
    if not _prepare_queue(queue_dir) or len(_queue_files(queue_dir)) >= MAX_QUEUE_FILES:
        return False
    path = queue_dir / f"{time.time_ns():020d}-{os.getpid()}-{secrets.token_hex(4)}.json"
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, separators=(",", ":"))
        return True
    except OSError:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        return False


def _spawn_worker(queue_dir: Path) -> None:
    if not _prepare_queue(queue_dir):
        return
    lock = None
    try:
        lock = (queue_dir / ".drain.lock").open("a+")
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, BlockingIOError):
        if lock is not None:
            lock.close()
        return
    try:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--drain-locked", str(queue_dir), str(lock.fileno())],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
            pass_fds=(lock.fileno(),),
        )
    except OSError:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
    finally:
        lock.close()


def _post_json(payload: dict[str, Any]) -> bool:
    connection = http.client.HTTPConnection(OTLP_HOST, OTLP_PORT, timeout=0.75)
    try:
        connection.request(
            "POST",
            OTLP_PATH,
            body=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        response = connection.getresponse()
        response.read(1)
        return 200 <= response.status < 300
    except Exception:
        return False
    finally:
        connection.close()


def drain(queue_dir: Path | None = None, inherited_lock_fd: int | None = None) -> int:
    queue = queue_dir or _default_queue_dir()
    if not _prepare_queue(queue):
        return 0
    if inherited_lock_fd is not None:
        try:
            lock = os.fdopen(inherited_lock_fd, "a+")
        except OSError:
            return 0
    else:
        try:
            lock = (queue / ".drain.lock").open("a+")
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, BlockingIOError):
            return 0
    now = time.time()
    try:
        for path in _queue_files(queue)[:MAX_DRAIN_FILES]:
            try:
                if now - path.stat().st_mtime > QUEUE_TTL_SECONDS:
                    path.unlink(missing_ok=True)
                    continue
                payload = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                try:
                    path.unlink(missing_ok=True)
                except OSError:
                    pass
                continue
            if not _post_json(payload):
                break
            try:
                path.unlink(missing_ok=True)
            except OSError:
                pass
    finally:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
            lock.close()
        except OSError:
            pass
    return 0


def handle(event: str, profile: str, raw: str, queue_dir: Path | None = None) -> int:
    if profile not in _ALLOWED_PROFILES or event not in _ALLOWED_EVENTS:
        return 0
    if len(raw.encode("utf-8", "replace")) > MAX_INPUT_BYTES:
        return 0
    try:
        data = json.loads(raw or "{}")
    except (json.JSONDecodeError, TypeError):
        return 0
    if not isinstance(data, dict):
        return 0
    tool_name = ""
    if event == "postToolUse":
        candidate = data.get("tool_name", data.get("toolName", ""))
        tool_name = candidate if isinstance(candidate, str) and candidate in _SAFE_TOOL_NAMES else "unknown"
    queue = queue_dir or _default_queue_dir()
    if _enqueue(_payload(_ALLOWED_EVENTS[event], profile, tool_name), queue):
        _spawn_worker(queue)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--drain":
        return drain(Path(argv[2]))
    if len(argv) == 4 and argv[1] == "--drain-locked":
        try:
            return drain(Path(argv[2]), int(argv[3]))
        except ValueError:
            return 0
    if len(argv) != 3:
        return 0
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1).decode("utf-8", "replace")
    return handle(argv[1], argv[2], raw)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
