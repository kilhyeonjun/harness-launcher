#!/usr/bin/env python3
"""Resolve the per-harness opt-ins of the Codex runtime hook registry.

Each registry row is enabled by one literal assignment in
``<harness>/config/launcher.env``:

    orca           HARNESS_ORCA_AGENT_HOOKS=1
    herdr          HARNESS_HERDR_AGENT_HOOKS=1
    launch_record  HARNESS_LAUNCH_RECORD_HOOKS=1

The process environment is ignored on purpose: Claude-side resyncs call the
prepare script without launcher state, and every caller must resolve the same
values. Both keys share one parsing rule: an optional ``export``, an optional
matching pair of quotes, the last assignment wins, and only the value ``1``
opts in.

Command line: ``runtime_hooks_optin.py HARNESS_DIR`` prints the resolved pair
as one line, ``orca=<0|1> herdr=<0|1> launch_record=<0|1>`` (for example
``orca=1 herdr=0 launch_record=0``),
followed by a newline. The shell caller passes that line to the hook generator
unchanged, so a change to either opt-in changes the argument.
"""

import os
import re
import sys

# Registry order is the order rows are appended to hooks.json.
KEYS = {
    "orca": "HARNESS_ORCA_AGENT_HOOKS",
    "herdr": "HARNESS_HERDR_AGENT_HOOKS",
    "launch_record": "HARNESS_LAUNCH_RECORD_HOOKS",
}
_LINES = {
    name: re.compile(r"^\s*(?:export\s+)?" + key + r"=(.*?)\s*$")
    for name, key in KEYS.items()
}


def resolve(harness_dir):
    """Return {row name: bool} for every registry row from launcher.env."""
    values = {name: "" for name in KEYS}
    try:
        with open(os.path.join(harness_dir, "config", "launcher.env"), encoding="utf-8") as stream:
            for line in stream:
                line = line.rstrip("\n")
                for name, pattern in _LINES.items():
                    match = pattern.match(line)
                    if not match:
                        continue
                    raw = match.group(1)
                    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
                        raw = raw[1:-1]
                    values[name] = raw
    except (OSError, UnicodeDecodeError):
        return {name: False for name in KEYS}
    return {name: value == "1" for name, value in values.items()}


def render(resolved):
    """Return the stable single-line form printed by the command line."""
    return " ".join(f"{name}={int(resolved[name])}" for name in KEYS)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: runtime_hooks_optin.py HARNESS_DIR")
    sys.stdout.write(render(resolve(sys.argv[1])) + "\n")
