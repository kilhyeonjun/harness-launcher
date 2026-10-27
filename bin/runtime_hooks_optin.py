#!/usr/bin/env python3
"""Resolve the per-harness opt-ins of the Codex runtime hook registry.

The original registry rows are enabled by one literal assignment in
``<harness>/config/launcher.env``:

    orca           HARNESS_ORCA_AGENT_HOOKS=1
    herdr          HARNESS_HERDR_AGENT_HOOKS=1
    launch_record  HARNESS_LAUNCH_RECORD_HOOKS=1

The optional ``ssot`` row reads only ``config/ssot-session-hooks.json`` with
exactly ``{"enabled": true}``. Missing or malformed JSON disables the row.

The process environment is ignored on purpose: Claude-side resyncs call the
prepare script without launcher state, and every caller must resolve the same
values. These keys share one parsing rule: an optional ``export``, an optional
matching pair of quotes, the last assignment wins, and only the value ``1``
opts in.

Command line: ``runtime_hooks_optin.py HARNESS_DIR [--ssot-file FILE]``
uses the explicit SSOT source when supplied (without worktree fallback) and prints the resolved pair
as one line, ``orca=<0|1> herdr=<0|1> launch_record=<0|1> ssot=<0|1>`` (for example
``orca=1 herdr=0 launch_record=0 ssot=0``),
followed by a newline. The shell caller passes that line to the hook generator
unchanged, so a change to either opt-in changes the argument.
"""

import json
import os
import re
import sys

# Registry order is the order rows are appended to hooks.json.
KEYS = {
    "orca": "HARNESS_ORCA_AGENT_HOOKS",
    "herdr": "HARNESS_HERDR_AGENT_HOOKS",
    "launch_record": "HARNESS_LAUNCH_RECORD_HOOKS",
    "ssot": None,
}
_LINES = {
    name: re.compile(r"^\s*(?:export\s+)?" + key + r"=(.*?)\s*$")
    for name, key in KEYS.items() if key is not None
}


def resolve(harness_dir, *, ssot_file=None):
    """Resolve literal profile opt-ins, optionally using a verified SSOT file.

    An explicit missing/malformed file disables SSOT; it never falls back to
    the worktree. Other rows still read the profile's launcher.env.
    """
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
        values = {name: "" for name in KEYS}
    resolved = {name: value == "1" for name, value in values.items()}
    if ssot_file is None:
        ssot_file = os.path.join(harness_dir, "config", "ssot-session-hooks.json")
    try:
        with open(ssot_file, encoding="utf-8") as stream:
            raw = stream.read(4097)
        if len(raw) > 4096:
            return resolved
        data = json.loads(raw)
        resolved["ssot"] = isinstance(data, dict) and set(data) == {"enabled"} and data["enabled"] is True
    except (OSError, UnicodeDecodeError, ValueError):
        pass
    return resolved


def render(resolved):
    """Return the stable single-line form printed by the command line."""
    return " ".join(f"{name}={int(resolved[name])}" for name in KEYS)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("harness_dir")
    parser.add_argument("--ssot-file", help="Explicit verified SSOT opt-in source (no worktree fallback)")
    args = parser.parse_args()
    sys.stdout.write(render(resolve(args.harness_dir, ssot_file=args.ssot_file)) + "\n")
