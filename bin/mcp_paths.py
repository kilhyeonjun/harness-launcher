"""Materialize explicit harness-root MCP paths without touching credentials."""

import json
import os
from pathlib import Path
import re
import sys


PREFIX = "${HARNESS_ROOT}/"
INTERPRETERS = {"bash", "sh", "zsh", "python", "python3", "node"}


def _interpreter_script(command, args):
    """Return the first script operand; inline-code/module modes have none."""
    executable = os.path.basename(command)
    if re.fullmatch(r"python3\.\d+", executable):
        executable = "python3"
    if executable not in INTERPRETERS:
        return None
    value_options = {
        "bash": {"-o", "+o", "-O", "+O", "--init-file", "--rcfile"},
        "sh": {"-o", "+o"},
        "zsh": {"-o", "+o"},
        "python": {"-W", "-X"},
        "python3": {"-W", "-X"},
        "node": {"-r", "--require", "--loader", "--import", "--conditions", "-C"},
    }[executable]
    skip_value = False
    for arg in args:
        if not isinstance(arg, str):
            raise ValueError("stdio args must be strings")
        if skip_value:
            skip_value = False
            continue
        if executable in {"bash", "sh", "zsh"} and arg.startswith("-") and "c" in arg[1:]:
            return None
        if executable in {"python", "python3"} and arg in {"-c", "-m"}:
            return None
        if executable == "node" and arg in {"-e", "--eval", "-p", "--print"}:
            return None
        if arg in value_options:
            skip_value = True
            continue
        if arg.startswith("-"):
            continue
        return arg
    return None


def _path(value, root, server):
    if not isinstance(value, str) or not value.startswith(PREFIX):
        return value
    root = Path(root).resolve()
    suffix = value[len(PREFIX):]
    target = (root / suffix).resolve()
    if not target.is_relative_to(root):
        raise ValueError(f"MCP '{server}': path outside harness root: {value}")
    if not target.is_file():
        raise ValueError(f"MCP '{server}': path is not a file: {value}")
    return str(target)


def normalize_servers(servers, root):
    """Return a new server map with only explicit harness-root paths expanded."""
    result = {}
    for name, spec in servers.items():
        if not isinstance(spec, dict):
            raise ValueError(f"MCP '{name}': definition must be an object")
        entry = dict(spec)
        command = entry.get("command")
        if command is not None:
            if isinstance(command, str) and "/" in command and not command.startswith(("/", PREFIX)):
                raise ValueError(
                    f"MCP '{name}': relative command path {command!r}; "
                    f"use {PREFIX}{command.removeprefix('./')}"
                )
            entry["command"] = _path(command, root, name)
        args = entry.get("args")
        if args is not None:
            if not isinstance(args, list):
                raise ValueError(f"MCP '{name}': args must be an array")
            entry["args"] = [_path(arg, root, name) for arg in args]
        if isinstance(command, str) and args:
            script = _interpreter_script(command, args)
            if script and not script.startswith(("/", PREFIX)):
                raise ValueError(
                    f"MCP '{name}': relative script path {script!r}; "
                    f"use {PREFIX}{script.removeprefix('./')}"
                )
        result[name] = entry
    return result


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: mcp_paths.py <harness-root> <source-json>")
    root, source = sys.argv[1:]
    try:
        with open(source, encoding="utf-8") as stream:
            data = json.load(stream)
        if not isinstance(data, dict) or not isinstance(data.get("mcpServers"), dict):
            raise ValueError("mcpServers must be an object")
        data["mcpServers"] = normalize_servers(data["mcpServers"], root)
    except (OSError, ValueError) as error:
        print(f"ERROR: {source}: {error}", file=sys.stderr)
        return 1
    json.dump(data, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
