#!/usr/bin/env python3
"""NUL-safe path operations for session release overlays.

The delivery shell code keeps its own Git commands.  This helper owns the
Unicode comparison and the exact pathspec/argv boundary so each delivery
choke point can use the same values without shell word splitting.
"""

from __future__ import annotations

import argparse
import os
import sys
import unicodedata
from pathlib import Path
from typing import Iterable, Sequence


ARG_MAX_BYTES = 262_144
ARG_MAX_ENTRIES = 4_096
HARNESS_OUTPUT = ".harness/"
_PREFIXES = {
    "exclude": ":(exclude,literal,icase)",
    "reset": ":(literal,icase)",
}


def fold_path(path: str) -> str:
    """Apply Unicode D145-style normalization and case folding to all parts."""
    return unicodedata.normalize("NFD", unicodedata.normalize("NFD", path).casefold())


def path_matches(candidate: str, overlays: Iterable[str]) -> bool:
    """Return whether *candidate* is an overlay path or lies below one."""
    folded_candidate = fold_path(candidate).rstrip("/")
    for overlay in overlays:
        folded_overlay = fold_path(overlay).rstrip("/")
        if folded_candidate == folded_overlay or folded_candidate.startswith(folded_overlay + "/"):
            return True
    return False


def read_nul_paths(path: Path) -> list[str]:
    data = path.read_bytes()
    if data and not data.endswith(b"\0"):
        raise ValueError(f"path list is not NUL terminated: {path}")
    return [os.fsdecode(item) for item in data.split(b"\0") if item]


def pathspecs(paths: Iterable[str], mode: str) -> list[str]:
    try:
        prefix = _PREFIXES[mode]
    except KeyError as error:
        raise ValueError(f"unsupported pathspec mode: {mode}") from error
    return [prefix + path for path in paths]


def pathspecs_from_file(path: Path, mode: str) -> list[str]:
    return pathspecs(read_nul_paths(path), mode)


def pathspecs_for_reset(overlays: Iterable[str]) -> list[str]:
    """Return reset-safe literals, including generated harness output.

    `.harness/` is delivery output, rather than an authored overlay member;
    callers performing only the overlay submission comparison must not pass it
    to :func:`path_matches`.
    """
    return pathspecs([*overlays, HARNESS_OUTPUT], "reset")


def can_use_argv(paths: Sequence[str], mode: str) -> bool:
    specs = pathspecs(paths, mode)
    return len(specs) <= ARG_MAX_ENTRIES and sum(len(os.fsencode(item)) for item in specs) <= ARG_MAX_BYTES


def filter_paths(candidates: Iterable[str], overlays: Iterable[str]) -> list[str]:
    overlay_list = list(overlays)
    return [candidate for candidate in candidates if not path_matches(candidate, overlay_list)]


def filter_path_statuses(
    statuses: Iterable[tuple[str, str | None, str | None]], overlays: Iterable[str]
) -> list[tuple[str, str | None, str | None]]:
    """Remove overlay sides while preserving a non-overlay rename as add/delete.

    Git's NUL rename record has old and new names.  At the over-limit fallback
    each name is filtered independently, which intentionally turns a rename
    across the boundary into a one-sided delete or add.
    """
    overlay_list = list(overlays)
    filtered = []
    for status, old, new in statuses:
        old = None if old is not None and path_matches(old, overlay_list) else old
        new = None if new is not None and path_matches(new, overlay_list) else new
        if old is not None or new is not None:
            filtered.append((status, old, new))
    return filtered


def _write_nul(values: Iterable[str]) -> None:
    sys.stdout.buffer.write(b"".join(os.fsencode(value) + b"\0" for value in values))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    specs = subcommands.add_parser("pathspecs", help="emit NUL-delimited Git pathspecs")
    specs.add_argument("--paths", type=Path, required=True)
    specs.add_argument("--mode", choices=sorted(_PREFIXES), required=True)
    limit = subcommands.add_parser("within-argv-limit", help="test the fixed argv boundary")
    limit.add_argument("--paths", type=Path, required=True)
    limit.add_argument("--mode", choices=sorted(_PREFIXES), required=True)
    args = parser.parse_args(argv)
    paths = read_nul_paths(args.paths)
    if args.command == "pathspecs":
        _write_nul(pathspecs(paths, args.mode))
        return 0
    return 0 if can_use_argv(paths, args.mode) else 1


if __name__ == "__main__":
    raise SystemExit(main())
