"""Location-aware, fail-closed adapter to the existing harness launcher."""

import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from harness_profile_resolver import ResolutionError, resolve


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
    if agent not in (None, "claude", "codex", "kiro-cli"):
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
        selection = resolve(Path.cwd(), Path(profile_home) / "profiles", explicit_profile)
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
