#!/usr/bin/env python3
"""Compatibility wrapper for the per-harness Orca agent hook opt-in.

The opt-in is now one row of the runtime hook registry, resolved by
``runtime_hooks_optin.py`` from the literal ``HARNESS_ORCA_AGENT_HOOKS``
assignment in ``<harness>/config/launcher.env``. This wrapper keeps the
``v0.34.0`` interface for existing callers: ``resolve`` returns ``"1"`` when
opted in, else ``""``, and the command line writes that bare value with no
newline.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import runtime_hooks_optin
finally:
    sys.path.pop(0)

KEY = runtime_hooks_optin.KEYS["orca"]


def resolve(harness_dir):
    """Return "1" when opted in, else ""."""
    return "1" if runtime_hooks_optin.resolve(harness_dir)["orca"] else ""


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: orca_hooks_optin.py HARNESS_DIR")
    sys.stdout.write(resolve(sys.argv[1]))
