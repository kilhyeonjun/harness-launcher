#!/usr/bin/env python3
"""Validate, project, compare, and serialize allowlisted global Codex MCPs."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import re
import sys
import tomllib
from typing import Any


NAME = re.compile(r"^[A-Za-z0-9_-]+$")
SUPPORTED_FIELDS = {
    "type", "command", "url", "args", "enabled", "env_vars",
    "bearer_token_env_var", "env_http_headers", "startup_timeout_sec",
    "tool_timeout_sec",
}
FORBIDDEN_FIELDS = {"env", "http_headers"}
PROFILE_FIELDS = {"enabled", "tools", "enabled_tools", "disabled_tools"}


class GlobalMcpError(RuntimeError):
    pass


@dataclass(frozen=True)
class GlobalMcpResolution:
    definitions: dict[str, dict[str, Any]]
    normalized_allowlist: tuple[str, ...]
    digest: str


def fail(path: Path, server: str, field: str, reason: str) -> None:
    raise GlobalMcpError(f"global MCP {server!r} field {field!r} in {path}: {reason}")


def normalize_allowlist(raw_allowlist: str) -> tuple[str, ...]:
    names: list[str] = []
    for raw in raw_allowlist.split(","):
        name = raw.strip()
        if not name:
            continue
        if not NAME.fullmatch(name):
            raise GlobalMcpError(f"invalid global MCP allowlist name: {name!r}")
        if name not in names:
            names.append(name)
    return tuple(names)


def validate_value(value: Any, *, path: Path, server: str, field: str) -> None:
    if isinstance(value, (str, bool, int)):
        return
    if isinstance(value, float):
        if math.isfinite(value):
            return
        fail(path, server, field, "must be finite")
    if isinstance(value, list):
        if any(isinstance(item, (list, dict)) for item in value):
            fail(path, server, field, "must be a homogeneous scalar array")
        types = {type(item) for item in value}
        if len(types) > 1:
            fail(path, server, field, "must be a homogeneous scalar array")
        for item in value:
            validate_value(item, path=path, server=server, field=field)
        return
    if isinstance(value, dict):
        for key, nested in value.items():
            if not isinstance(key, str):
                fail(path, server, field, "nested table keys must be strings")
            validate_value(nested, path=path, server=server, field=f"{field}.{key}")
        return
    fail(path, server, field, "has an unsupported value type")


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def validate_field(value: Any, *, path: Path, server: str, field: str) -> None:
    if field in {"type", "command", "url", "bearer_token_env_var"}:
        if not isinstance(value, str) or not value:
            fail(path, server, field, "must be a non-empty string")
        return
    if field == "enabled":
        if type(value) is not bool:
            fail(path, server, field, "must be a boolean")
        return
    if field == "args":
        if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
            fail(path, server, field, "must be an array of strings")
        return
    if field == "env_vars":
        if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
            fail(path, server, field, "must be an array of strings")
        return
    if field == "env_http_headers":
        if not isinstance(value, dict):
            fail(path, server, field, "must be a table")
        validate_value(value, path=path, server=server, field=field)
        return
    if not is_number(value) or not math.isfinite(value):
        fail(path, server, field, "must be a finite number")


def validate_definition(
    value: Any, *, path: Path, server: str, allow_disabled: bool = False
) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(path, server, "definition", "must be a table")
    for field, nested in value.items():
        if field in FORBIDDEN_FIELDS:
            fail(path, server, field, "is not permitted")
        if field not in SUPPORTED_FIELDS:
            fail(path, server, field, "is not supported")
        validate_field(nested, path=path, server=server, field=field)
    command, url = value.get("command"), value.get("url")
    if (command is None) == (url is None):
        fail(path, server, "transport", "requires exactly one of command or url")
    declared_type = value.get("type")
    expected_type = "stdio" if command else "streamable_http"
    if declared_type is not None and declared_type != expected_type:
        fail(path, server, "type", f"must be {expected_type!r}")
    if value.get("enabled") is False and not allow_disabled:
        fail(path, server, "enabled", "must not be false")
    return {key: value[key] for key in sorted(value)}


def resolve_global_mcp(config_path: Path, raw_allowlist: str, home: Path) -> GlobalMcpResolution:
    names = normalize_allowlist(raw_allowlist)
    if not names:
        payload = json.dumps({"allowlist": [], "definitions": {}}, sort_keys=True, separators=(",", ":"))
        return GlobalMcpResolution({}, names, hashlib.sha256(payload.encode()).hexdigest())
    try:
        with config_path.open("rb") as stream:
            config = tomllib.load(stream)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise GlobalMcpError(f"cannot read global Codex config {config_path}: {error.__class__.__name__}") from error
    servers = config.get("mcp_servers")
    if not isinstance(servers, dict):
        raise GlobalMcpError(f"global Codex config {config_path} has no mcp_servers table")
    definitions: dict[str, dict[str, Any]] = {}
    for name in names:
        if name not in servers:
            raise GlobalMcpError(f"global MCP {name!r} is missing from {config_path}")
        definitions[name] = validate_definition(servers[name], path=config_path, server=name)
    canonical = json.dumps({"allowlist": list(names), "definitions": definitions}, sort_keys=True, separators=(",", ":"))
    return GlobalMcpResolution(definitions, names, hashlib.sha256(canonical.encode()).hexdigest())


def definition_projection(value: dict[str, Any], home: Path) -> dict[str, Any]:
    projected = {key: item for key, item in value.items() if key not in PROFILE_FIELDS}
    if "type" not in projected:
        projected["type"] = "stdio" if "command" in projected else "streamable_http"
    if projected.get("type") == "stdio":
        projected["type"] = "stdio"
    prefix = str(home)
    for field in ("command", "url"):
        raw = projected.get(field)
        if isinstance(raw, str):
            if raw == prefix or raw.startswith(prefix + "/"):
                projected[field] = "${HOME}" + raw[len(prefix):]
            elif raw == "${HOME}" or raw.startswith("${HOME}/"):
                projected[field] = raw
    return {key: projected[key] for key in sorted(projected)}


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def toml_scalar(value: Any) -> str:
    if isinstance(value, str):
        return toml_string(value)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_scalar(item) for item in value) + "]"
    raise TypeError(type(value).__name__)


def toml_key(value: str) -> str:
    return value if re.fullmatch(r"[A-Za-z0-9_-]+", value) else toml_string(value)


def emit_table(lines: list[str], path: list[str], value: dict[str, Any]) -> None:
    lines.append("[" + ".".join(toml_key(part) for part in path) + "]")
    for key, item in value.items():
        if not isinstance(item, dict):
            lines.append(f"{toml_key(key)} = {toml_scalar(item)}")
    for key, item in value.items():
        if isinstance(item, dict):
            lines.append("")
            emit_table(lines, [*path, key], item)


def emit_toml(definitions: dict[str, dict[str, Any]], *, enabled: set[str]) -> str:
    lines: list[str] = []
    for name in sorted(definitions):
        value = dict(definitions[name])
        value["enabled"] = name in enabled
        emit_table(lines, ["mcp_servers", name], value)
        lines.append("")
    return "\n".join(lines)


def compare(local_json: Path, global_toml: Path, name: str, home: Path) -> int:
    try:
        document = json.loads(local_json.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise GlobalMcpError(f"local MCP JSON {local_json} must be an object")
        servers = document.get("mcpServers")
        if not isinstance(servers, dict) or name not in servers:
            raise GlobalMcpError(f"local MCP {name!r} is missing from {local_json}")
        local = validate_definition(
            {key: value for key, value in servers[name].items() if key not in PROFILE_FIELDS}
            if isinstance(servers[name], dict) else servers[name],
            path=local_json,
            server=name,
            allow_disabled=True,
        )
        global_value = resolve_global_mcp(global_toml, name, home).definitions[name]
    except (OSError, TypeError, KeyError, json.JSONDecodeError, GlobalMcpError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0 if definition_projection(local, home) == definition_projection(global_value, home) else 3


def main(argv: list[str]) -> int:
    if len(argv) == 6 and argv[1] == "compare":
        return compare(Path(argv[2]), Path(argv[3]), argv[4], Path(argv[5]))
    if len(argv) == 6 and argv[1] == "emit":
        try:
            resolution = resolve_global_mcp(Path(argv[2]), argv[3], Path(argv[4]))
            enabled = set(filter(None, argv[5].split(",")))
            emitted = emit_toml(resolution.definitions, enabled=enabled)
            parsed = tomllib.loads(emitted)
            for name, definition in resolution.definitions.items():
                if definition_projection(parsed["mcp_servers"][name], Path(argv[4])) != definition_projection(definition, Path(argv[4])):
                    raise GlobalMcpError(f"global MCP {name!r} failed definition projection round-trip")
            print(emitted, end="")
            return 0
        except GlobalMcpError as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 2
    print("usage: codex_global_mcp.py compare LOCAL_JSON GLOBAL_TOML NAME HOME | emit GLOBAL_TOML ALLOWLIST HOME ENABLED", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
