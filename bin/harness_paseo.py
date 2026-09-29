"""Manage harness-owned provider entries in the Paseo config.

The profile registry is the source of truth.  A sidecar file records which
provider IDs a sync wrote, so sync only ever edits or removes its own entries
and only touches their `extends`, `label`, and `command` fields.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from harness_profile_resolver import registered_profiles

PROVIDER_ID = re.compile(r"^[a-z][a-z0-9-]*$")
BACKUP_SUFFIX = ".harness-paseo.bak"


class Report:
    """Collects OK/WARN/FAIL lines and derives the exit status."""

    def __init__(self, stream=None):
        self.failed = False
        self.stream = stream or sys.stdout

    def ok(self, text):
        print(f"OK {text}", file=self.stream)

    def warn(self, text):
        print(f"WARN {text}", file=self.stream)

    def fail(self, text):
        self.failed = True
        print(f"FAIL {text}", file=self.stream)

    @property
    def status(self):
        return 1 if self.failed else 0


def profile_home():
    configured = os.environ.get("HARNESS_PROFILE_HOME")
    if configured:
        return Path(configured)
    config_home = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(config_home) / "harness-launcher"


def default_config_path():
    paseo_home = os.environ.get("PASEO_HOME")
    base = Path(paseo_home) if paseo_home else Path.home() / ".paseo"
    return base / "config.json"


def default_bin_dir():
    invoked = os.environ.get("HARNESS_PASEO_INVOKED_AS") or sys.argv[0]
    return Path(os.path.abspath(invoked)).parent


def expected_providers(bin_dir, report):
    """Return ({provider id: managed fields}, colliding ids) for the registry."""
    bin_dir = str(bin_dir)
    expected = {
        "harness-claude": {
            "extends": "claude",
            "label": "Harness Claude",
            "command": [f"{bin_dir}/harness-auto", "claude", "base", "--passthrough"],
        }
    }
    by_id = {}
    for profile, _root in registered_profiles(profile_home() / "profiles"):
        provider = "harness-codex-" + profile.lower().replace("_", "-")
        suffix = provider[len("harness-codex-"):]
        if not PROVIDER_ID.fullmatch(suffix):
            report.warn(f"skipped profile with unusable provider id: {profile}")
            continue
        by_id.setdefault(provider, []).append(profile)
    collided = set()
    for provider, profiles in sorted(by_id.items()):
        if len(profiles) > 1:
            report.fail(f"provider ID collision {provider}: {', '.join(profiles)}")
            collided.add(provider)
            continue
        profile = profiles[0]
        expected[provider] = {
            "extends": "codex",
            "label": f"{profile} Codex",
            "command": [f"{bin_dir}/harness-codex", "--profile", profile],
        }
    return expected, collided


def load_owned(config_path):
    try:
        data = json.loads((profile_home() / "paseo-managed.json").read_text(encoding="utf-8"))
        owned = data["configs"][os.path.realpath(config_path)]
        return {item for item in owned if isinstance(item, str)}
    except (OSError, ValueError, KeyError, TypeError):
        return set()


def atomic_write(path, data, mode):
    """Write bytes next to `path` and return the temp path, not yet renamed."""
    fd, temp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        os.unlink(temp)
        raise
    return temp


def store_owned(config_path, owned):
    sidecar = profile_home() / "paseo-managed.json"
    try:
        data = json.loads(sidecar.read_text(encoding="utf-8"))
        configs = data["configs"]
        if not isinstance(configs, dict):
            raise ValueError
    except (OSError, ValueError, KeyError, TypeError):
        configs = {}
    key = os.path.realpath(config_path)
    if owned:
        configs[key] = sorted(owned)
    else:
        configs.pop(key, None)
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"version": 1, "configs": configs}, indent=2) + "\n"
    temp = atomic_write(sidecar, payload.encode("utf-8"), 0o600)
    os.replace(temp, sidecar)


def read_config(path, report):
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        report.fail(f"Paseo config not found, start Paseo once: {path}")
        return None, None
    except OSError as exc:
        report.fail(f"cannot read Paseo config {path}: {exc}")
        return None, None
    try:
        config = json.loads(raw)
    except ValueError:
        config = None
    if not isinstance(config, dict):
        report.fail(f"Paseo config is not a JSON object: {path}")
        return None, None
    return raw, config


def provider_table(config):
    agents = config.get("agents")
    providers = agents.get("providers") if isinstance(agents, dict) else None
    return providers if isinstance(providers, dict) else {}


def drop_from_metadata(config, provider):
    agents = config.get("agents")
    metadata = agents.get("metadataGeneration") if isinstance(agents, dict) else None
    entries = metadata.get("providers") if isinstance(metadata, dict) else None
    if isinstance(entries, dict) and provider in entries:
        del entries[provider]
        return True
    if isinstance(entries, list) and provider in entries:
        entries[:] = [item for item in entries if item != provider]
        return True
    return False


def warn_unowned(providers, expected, owned, report):
    for provider in sorted(providers):
        if provider.startswith("harness-") and provider not in expected and provider not in owned:
            report.warn(f"unowned provider left untouched: {provider}")


def config_shape_error(config):
    agents = config.get("agents")
    if agents is not None and not isinstance(agents, dict):
        return "agents is not an object"
    providers = agents.get("providers") if isinstance(agents, dict) else None
    if providers is not None and not isinstance(providers, dict):
        return "agents.providers is not an object"
    return None


def merge(config, expected, owned, keep, report):
    """Apply expected fields and drop stale owned IDs except `keep`; return changes."""
    agents = config.setdefault("agents", {})
    providers = agents.setdefault("providers", {})
    changes = []
    for provider, fields in expected.items():
        entry = providers.get(provider)
        if provider not in owned and isinstance(entry, dict):
            report.warn(f"adopted existing provider: {provider}")
        if not isinstance(entry, dict):
            entry = {}
        merged = dict(entry)
        merged.update(fields)
        if providers.get(provider) != merged:
            providers[provider] = merged
            changes.append(f"updated {provider}")
    for provider in sorted(owned - set(expected) - keep):
        if provider in providers:
            del providers[provider]
            changes.append(f"removed {provider}")
        if drop_from_metadata(config, provider):
            changes.append(f"removed {provider} from agents.metadataGeneration.providers")
    return changes


def write_config(path, original, config, report):
    """Replace the config unless Paseo changed it meanwhile, backing it up first."""
    mode = path.stat().st_mode & 0o777
    payload = (json.dumps(config, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    temp = atomic_write(path, payload, mode)
    try:
        if path.read_bytes() != original:
            report.fail(f"Paseo changed {path} during sync; nothing written, rerun sync")
            return False
        backup = path.with_name(path.name + BACKUP_SUFFIX)
        backup_temp = atomic_write(backup, original, 0o600)
        os.replace(backup_temp, backup)
        os.replace(temp, path)
        return True
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def reload_daemon(report):
    try:
        result = subprocess.run(["paseo", "daemon", "reload"], capture_output=True, text=True)
    except OSError as exc:
        report.warn(f"paseo daemon reload failed: {exc}")
        return
    if result.returncode != 0:
        report.warn(f"paseo daemon reload failed with exit {result.returncode}")
    else:
        report.ok("paseo daemon reloaded")


def command_print(args):
    report = Report(stream=sys.stderr)  # stdout stays pure JSON
    expected, _collided = expected_providers(args.bin_dir, report)
    print(json.dumps({"providers": expected}, indent=2))
    return report.status


def command_sync(args):
    report = Report()
    expected, collided = expected_providers(args.bin_dir, report)
    # Write through a symlinked config (dotfiles) instead of replacing the link.
    path = Path(os.path.realpath(args.config))
    original, config = read_config(path, report)
    if config is None:
        return report.status
    shape_error = config_shape_error(config)
    if shape_error:
        report.fail(f"Paseo config {shape_error}: {path}")
        return report.status
    owned = load_owned(path)
    warn_unowned(provider_table(config), expected, owned, report)
    keep = owned & collided  # a new collision must not remove a working provider
    changes = merge(config, expected, owned, keep, report)
    if changes:
        if not write_config(path, original, config, report):
            return report.status
        for change in changes:
            report.ok(change)
        report.ok(f"wrote {path}")
    else:
        report.ok("Paseo config already up to date")
    if owned != set(expected) | keep:
        try:
            store_owned(path, set(expected) | keep)
        except OSError as exc:
            report.fail(f"cannot record ownership: {exc}")
    if args.reload:
        reload_daemon(report)
    return report.status


def tracked_in_git(path):
    """True when `path` resolves to a file tracked by a Git checkout.

    A provider command that points into a source checkout changes with every
    branch switch. Package managers whose prefix is itself a repository
    (Homebrew) install into untracked directories, so they do not match.
    """
    real = os.path.realpath(path)
    try:
        result = subprocess.run(["git", "-C", os.path.dirname(real), "ls-files", "--error-unmatch", real],
                                capture_output=True)
    except OSError:
        return False
    return result.returncode == 0


def command_check(args):
    report = Report()
    registered = {name for name, _root in registered_profiles(profile_home() / "profiles")}
    if args.profile is not None and args.profile not in registered:
        report.warn(f"profile is not registered: {args.profile}")
    expected, collided = expected_providers(args.bin_dir, report)
    path = Path(os.path.realpath(args.config))
    _raw, config = read_config(path, report)
    bin_dir = Path(args.bin_dir)
    for tool in ("harness-auto", "harness-codex"):
        candidate = bin_dir / tool
        if candidate.is_file() and os.access(candidate, os.X_OK):
            report.ok(f"{candidate} is executable")
        else:
            report.fail(f"missing executable: {candidate}")
    if tracked_in_git(bin_dir / "harness-auto"):
        report.warn(f"bin directory resolves into a Git checkout: {bin_dir}")
    if config is None:
        return report.status

    daemon = config.get("daemon")
    relay = daemon.get("relay") if isinstance(daemon, dict) else None
    relay_enabled = relay.get("enabled") if isinstance(relay, dict) else None
    if relay_enabled is False:
        report.ok("daemon.relay.enabled is false")
    else:
        report.warn("daemon.relay.enabled is not false")

    providers = provider_table(config)
    owned = load_owned(path)
    selected = expected
    if args.profile is not None:
        wanted = "harness-codex-" + args.profile.lower().replace("_", "-")
        selected = {k: v for k, v in expected.items() if k in ("harness-claude", wanted)}
    for provider, fields in sorted(selected.items()):
        entry = providers.get(provider)
        if not isinstance(entry, dict):
            report.fail(f"missing provider: {provider}")
            continue
        wrong = [key for key, value in fields.items() if entry.get(key) != value]
        if wrong:
            report.fail(f"provider {provider} differs in: {', '.join(wrong)}")
        else:
            report.ok(f"provider {provider} matches")
    for provider in sorted(owned - set(expected) - collided):
        if provider in providers:
            report.fail(f"stale owned provider: {provider}")
    warn_unowned(providers, expected, owned, report)
    return report.status


def build_parser():
    parser = argparse.ArgumentParser(prog="harness-paseo")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("print", "sync", "check"):
        command = sub.add_parser(name)
        command.add_argument("--bin-dir", default=str(default_bin_dir()))
        if name != "print":
            command.add_argument("--config", default=str(default_config_path()))
        if name == "sync":
            command.add_argument("--reload", action="store_true")
        if name == "check":
            command.add_argument("--profile")
    return parser


def main(argv):
    args = build_parser().parse_args(argv)
    handler = {"print": command_print, "sync": command_sync, "check": command_check}
    return handler[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
