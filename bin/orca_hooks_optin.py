#!/usr/bin/env python3
"""Resolve the per-harness Orca agent hook opt-in.

The single source is the literal ``HARNESS_ORCA_AGENT_HOOKS`` assignment in
``<harness>/config/launcher.env``. The process environment is ignored on
purpose: Claude-side resyncs call the prepare script without launcher state,
and every caller must resolve the same value.
"""

import os
import re
import sys

KEY = "HARNESS_ORCA_AGENT_HOOKS"
_LINE = re.compile(r"^\s*(?:export\s+)?" + KEY + r"=(.*?)\s*$")


def resolve(harness_dir):
    """Return "1" when opted in, else ""."""
    value = ""
    try:
        with open(os.path.join(harness_dir, "config", "launcher.env"), encoding="utf-8") as stream:
            for line in stream:
                match = _LINE.match(line.rstrip("\n"))
                if not match:
                    continue
                raw = match.group(1)
                if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
                    raw = raw[1:-1]
                value = raw
    except (OSError, UnicodeDecodeError):
        return ""
    return "1" if value == "1" else ""


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: orca_hooks_optin.py HARNESS_DIR")
    sys.stdout.write(resolve(sys.argv[1]))
