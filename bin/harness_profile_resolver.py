"""Read-only, runtime-neutral registered harness profile resolution.

The registry remains the only profile-to-root authority.  This module never
creates registrations, changes runtime state, or grants an outside worktree.
"""

from pathlib import Path
import re
from typing import NamedTuple, Optional


PROFILE_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")


class ResolutionError(ValueError):
    pass


class Selection(NamedTuple):
    profile: str
    harness_root: Path
    work_root: Path
    reason: str


def _registered_roots(registry: Path):
    if not registry.is_dir():
        return
    try:
        entries = list(registry.iterdir())
    except OSError:
        return
    for entry in entries:
        if not PROFILE_NAME.fullmatch(entry.name) or entry.is_symlink() or not entry.is_file():
            continue
        try:
            first_line = entry.read_text(encoding="utf-8").splitlines()[0]
            root = Path(first_line).resolve(strict=True)
        except (IndexError, OSError, RuntimeError, UnicodeError, ValueError):
            continue
        if root.is_dir() and (root / "config" / "launcher.env").is_file():
            yield entry.name, root


def resolve(cwd: Path, registry: Path, explicit_profile: Optional[str] = None) -> Selection:
    """Select exactly one registered ancestor or fail closed."""
    try:
        work_root = Path(cwd).resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ResolutionError(f"current directory is unavailable: {cwd}") from exc
    if not work_root.is_dir():
        raise ResolutionError(f"current directory is not a directory: {cwd}")
    if explicit_profile is not None and not PROFILE_NAME.fullmatch(explicit_profile):
        raise ResolutionError(f"invalid profile: {explicit_profile}")

    matches = [(profile, root) for profile, root in _registered_roots(Path(registry))
               if work_root == root or root in work_root.parents]
    if not matches:
        raise ResolutionError("no registered harness contains the current directory")
    deepest = max(len(root.parts) for _, root in matches)
    matches = [(profile, root) for profile, root in matches if len(root.parts) == deepest]
    if len(matches) != 1:
        raise ResolutionError(f"ambiguous registered harness boundary: {work_root}")
    profile, root = matches[0]
    if explicit_profile is not None and explicit_profile != profile:
        raise ResolutionError(f"profile {explicit_profile} does not own the current directory")
    return Selection(profile, root, work_root, "registered-ancestor")
