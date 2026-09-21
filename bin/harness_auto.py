"""Location-aware, fail-closed adapter to the existing harness launcher."""

import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from harness_profile_resolver import ResolutionError, resolve


def validate_codex_working_dirs(args, cwd, harness_root):
    """Reject explicit Codex working directories outside the selected profile."""
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            break
        value = None
        if arg in ("--cd", "-C"):
            if index + 1 >= len(args):
                raise ResolutionError(f"{arg} requires a directory")
            value = args[index + 1]
            index += 1
        elif arg.startswith("--cd="):
            value = arg.split("=", 1)[1]

        if value is not None:
            target = Path(value)
            if not target.is_absolute():
                target = cwd / target
            try:
                target = target.resolve(strict=True)
            except (OSError, RuntimeError):
                raise ResolutionError(f"Codex working directory is unavailable: {value}")
            if not target.is_dir():
                raise ResolutionError(f"Codex working directory is not a directory: {value}")
            try:
                target.relative_to(harness_root)
            except ValueError:
                raise ResolutionError(
                    f"Codex working directory is outside selected harness boundary: {value}"
                )
        index += 1


def main(argv):
    explain = False
    explicit_profile = None
    args = list(argv)
    if args and args[0] == "--explain":
        explain = True
        args.pop(0)
    if args and args[0] == "--profile":
        if len(args) < 2:
            print("harness-auto: --profile requires a name", file=sys.stderr)
            return 2
        explicit_profile = args[1]
        del args[:2]
    if not explain and not args:
        print("harness-auto: agent command is required", file=sys.stderr)
        return 2

    agent = args.pop(0) if args else None
    if agent not in (None, "claude", "claude-management", "codex", "kiro-cli"):
        print(f"harness-auto: unsupported agent: {agent}", file=sys.stderr)
        return 2
    if agent is None and args:
        print("harness-auto: agent command is required", file=sys.stderr)
        return 2

    profile_home = os.environ.get("HARNESS_PROFILE_HOME")
    if not profile_home:
        config_home = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
        profile_home = str(Path(config_home) / "harness-launcher")
    try:
        cwd = Path.cwd().resolve(strict=True)
        selection = resolve(cwd, Path(profile_home) / "profiles", explicit_profile)
        if agent == "codex":
            validate_codex_working_dirs(args, cwd, selection.harness_root)
    except ResolutionError as exc:
        print(f"harness-auto: {exc}", file=sys.stderr)
        return 2

    if explain:
        print(json.dumps({"profile": selection.profile,
                          "harness_root": str(selection.harness_root),
                          "work_root": str(selection.work_root),
                          "reason": selection.reason,
                          "agent": agent}, ensure_ascii=False))
        return 0

    launcher = Path(__file__).resolve().with_name("harness-exec")
    if not os.access(launcher, os.X_OK):
        print(f"harness-auto: missing executable: {launcher}", file=sys.stderr)
        return 2
    launcher_args = args if agent == "claude" else [agent] + args
    os.execv(str(launcher), [str(launcher), str(selection.harness_root)] + launcher_args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
