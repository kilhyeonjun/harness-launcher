#!/usr/bin/env python3
"""Carry exact approved source hooks into a broker-bound isolated home.

This never approves a new hook. Missing or changed evidence leaves native
Codex review intact. The caller publishes the returned config under its CAS.

Operator command (never run by the launcher itself):

  codex-hook-trust.py capture --session-id UUID [--state-home DIR]
                              [--profile base] [--dry-run]

records an approval the owner already gave natively in an OPEN launcher session.
It invents nothing: every hook must have a trusted, enabled decision in the
session's profile whose hash equals the generated hook hash.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time
import tomllib
import uuid

EVENTS = {
    "SessionStart": "session_start", "UserPromptSubmit": "user_prompt_submit",
    "PreToolUse": "pre_tool_use", "PostToolUse": "post_tool_use",
    "PermissionRequest": "permission_request", "Stop": "stop",
    "SubagentStart": "subagent_start", "SubagentStop": "subagent_stop",
    "PreCompact": "pre_compact", "PostCompact": "post_compact",
}
PROFILE_FILES = {f"{name}.config.toml" for name in ("fast", "base", "sol", "astra", "plan", "rich")}
PROFILE_NAMES = {name.removesuffix(".config.toml") for name in PROFILE_FILES}
KEEP_BACKUPS = 5
ALGORITHM = "codex-0.161-command-hooks"
NORMALIZATION = "literal-core-and-approved-callback-paths-v1"
STATUS_SCRIPTS = (("$HOME/.orca/agent-hooks/codex-hook.sh", ""),
                  ("$HOME/.codex/herdr-agent-state.sh", " session"))
PACKAGE_CALLBACKS = {"codex-hook-adapter.sh", "codex-pretool-adapter.py", "codex-cmux-title-sync.py", "harness-launch-record"}


def split_profile_state(text):
    """Separate native hook decisions without ignoring other profile content."""
    tomllib.loads(text)
    managed, state = [], []
    in_state = False
    for line in text.splitlines(keepends=True):
        if re.match(r"^\s*\[.*\]\s*(?:#.*)?$", line):
            in_state = bool(re.match(r"^\s*\[hooks\.state(?:\.|\])", line))
        (state if in_state else managed).append(line)
    return "".join(managed).rstrip() + "\n", "".join(state)


def profile_signature(path):
    try:
        raw = Path(path).read_bytes()
    except OSError:
        return "invalid-profile:unreadable"
    try:
        managed, _ = split_profile_state(raw.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError):
        return "invalid-profile:" + hashlib.sha256(raw).hexdigest()
    return "sha256:" + hashlib.sha256(managed.encode()).hexdigest()


def preserve_profile(candidate, live):
    managed, _ = split_profile_state(candidate)
    try:
        if isinstance(live, bytes):
            live = live.decode("utf-8")
        _, state = split_profile_state(live)
    except (UnicodeDecodeError, tomllib.TOMLDecodeError):
        state = ""
    result = managed + ("\n" + state if state else "")
    tomllib.loads(result)
    return result


def fingerprint(event, matcher, handler):
    """Command subset verified against native 0.161 hooks/list currentHash."""
    if event not in EVENTS or handler.get("type") != "command":
        raise ValueError("unsupported hook")
    if set(handler) - {"type", "command", "timeout", "async", "statusMessage"}:
        raise ValueError("unsupported hook fields")
    timeout = handler.get("timeout", 600)
    if type(timeout) is not int or type(handler.get("async", False)) is not bool:
        raise ValueError("unsupported hook values")
    if not isinstance(handler.get("command"), str):
        raise ValueError("missing command")
    normalized = dict(type="command", command=handler["command"],
                      timeout=max(1, timeout), **{"async": handler.get("async", False)})
    if handler.get("statusMessage") is not None:
        normalized["statusMessage"] = handler["statusMessage"]
    identity = {"event_name": EVENTS[event], "hooks": [normalized]}
    if matcher is not None and event not in ("UserPromptSubmit", "Stop"):
        identity["matcher"] = matcher
    payload = json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "sha256:" + hashlib.sha256(payload.encode()).hexdigest()


def regular(path, boundary=None, limit=2 * 1024 * 1024, private=False):
    """Bounded fd reads; broker/source paths are walked without links."""
    path = Path(path)
    directory = None
    try:
        if boundary is not None:
            parts = path.relative_to(boundary).parts
            directory = os.open(boundary, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            for component in parts[:-1]:
                info = os.fstat(directory)
                if info.st_uid != os.getuid() or info.st_mode & 0o022:
                    raise ValueError("unsafe evidence directory")
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                os.close(directory)
                directory = child
            info = os.fstat(directory)
            if info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise ValueError("unsafe evidence directory")
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        else:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                    info.st_nlink != 1 or info.st_mode & 0o022 or info.st_size > limit or
                    (private and stat.S_IMODE(info.st_mode) != 0o600)):
                raise ValueError("unsafe evidence file")
            raw = stream.read(limit + 1)
            if len(raw) > limit:
                raise ValueError("evidence grew")
            return raw
    finally:
        if directory is not None:
            os.close(directory)


def git_output(target, *args):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
    return subprocess.run(
        ["git", "--no-optional-locks", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
         "-C", str(target), *args], env=env, capture_output=True, timeout=5, check=True).stdout


def root_pattern(source):
    return re.compile(r"(?<![A-Za-z0-9_./-])" + re.escape(str(source)) +
                      r"(/core/hooks/[A-Za-z0-9_.-]+\.sh)(?=$|[\s\"'])")


def approved_package_command(command, grant):
    """Normalize one generator-owned callback token after both byte proofs."""
    tokens = shlex.split(command)
    references = [(index, token) for index, token in enumerate(tokens) if Path(token).name in PACKAGE_CALLBACKS]
    if not references:
        return command
    if len(references) != 1 or references[0][0] != 1 or command != shlex.join(tokens):
        raise ValueError("unsupported callback argv")
    _, token = references[0]
    path = Path(token)
    name = path.name
    shapes = {"codex-hook-adapter.sh": (len(tokens) == 4 and tokens[0] == "bash"),
              "codex-pretool-adapter.py": len(tokens) == 3,
              "codex-cmux-title-sync.py": len(tokens) == 2,
              "harness-launch-record": tokens[2:] in (["codex"], ["codex", "--callback"])}
    if not shapes[name] or path not in {Path(__file__).parent / name, Path(__file__).resolve().parent / name}:
        raise ValueError(f"callback outside current verified package {Path(__file__).resolve().parent}")
    approved = [p for p in grant["callbacks"] if Path(p).name == name]
    if len(approved) != 1:
        raise ValueError("ambiguous callback approval")
    old = approved[0]
    expected = grant["callbacks"][old]
    if hashlib.sha256(regular(path)).hexdigest() != expected or hashlib.sha256(regular(old)).hexdigest() != expected:
        raise ValueError("callback bytes changed")
    tokens[1] = old
    return shlex.join(tokens)


def identity_stat(path):
    return os.lstat(path)


def root_identity_matches(recorded, path):
    """Recorded "<dev> <ino>" names `path` (a real directory, never followed).

    Same inode and either the same device, or a whole-volume device renumbering
    (reboot) where the root still sits on the device of its worktrees directory.
    A root replaced by another filesystem has a different device from its parent.
    """
    fields = recorded.split()
    if len(fields) != 2 or not all(re.fullmatch(r"[0-9]+", field) for field in fields):
        return False
    device, inode = int(fields[0]), int(fields[1])
    try:
        path = Path(path)
        info = identity_stat(path)
        if not stat.S_ISDIR(info.st_mode) or info.st_ino != inode:
            return False
        return info.st_dev == device or identity_stat(path.parent).st_dev == info.st_dev
    except OSError:
        return False


def state_home():
    return Path(os.environ.get("HARNESS_SESSION_STATE_HOME") or
                Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "harness-launcher").resolve()


def broker_source(published):
    target = published.parent.parent
    sid = os.environ.get("HARNESS_SESSION_ID", "")
    uuid.UUID(sid)
    state = state_home()
    record = state / "sessions" / sid
    if target != state / "worktrees" / sid or target.resolve() != target:
        raise ValueError("not a physical broker root")
    if record.is_symlink() or record.stat().st_uid != os.getuid():
        raise ValueError("foreign broker record")
    source = Path(regular(record / "source-root", state).decode().strip())
    if source.resolve() != source or source == target:
        raise ValueError("invalid source root")
    expected = regular(record / "session-root", state).decode().strip()
    if expected != str(target) or os.environ.get("HARNESS_SESSION_ROOT") != str(target):
        raise ValueError("session association changed")
    if os.environ.get("HARNESS_SOURCE_ROOT") != str(source):
        raise ValueError("source association changed")
    if not root_identity_matches(regular(record / "root-inode", state).decode(), target):
        raise ValueError("session root replaced")
    if [line for line in regular(record / "journal", state).decode().splitlines() if line.startswith("state=")] != ["state=OPEN"]:
        raise ValueError("session is not open")
    base = regular(record / "base-sha", state).decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        raise ValueError("invalid snapshot")
    return source, target, base, state


def equivalent_command(command, desired, source, target, base, grant):
    """Only literal core/hooks script arguments may change roots."""
    pattern = root_pattern(source)
    paths = [match.group(1).lstrip("/") for match in pattern.finditer(command)]
    normalized = root_pattern(target).sub(lambda match: str(source) + match.group(1),
                                         approved_package_command(desired, grant))
    if command != normalized:
        return False
    tokens = shlex.split(command)
    if paths:
        # The generator emits a direct bash hook or one of two adapters.
        valid = ((len(tokens) == 2 and tokens[0] == "bash") or
                 (len(tokens) == 4 and tokens[0] == "bash" and
                  Path(tokens[1]).name == "codex-hook-adapter.sh") or
                 (len(tokens) == 3 and Path(tokens[1]).name == "codex-pretool-adapter.py"))
        if not valid:
            return False
        if len(tokens) > 2 and not callback_approved(Path(tokens[1]), grant):
            return False
        for relative in paths:
            original = regular(source / relative, source)
            isolated = regular(target / relative, target)
            approved_script = grant["scripts"].get(relative, {})
            approved_sha = approved_script.get("sha256")
            if hashlib.sha256(isolated).hexdigest() != approved_sha:
                return False
            approved_blob = git_output(target, "show", f"{grant['approved_snapshot']['base_sha']}:{relative}")
            if hashlib.sha256(approved_blob).hexdigest() != approved_sha or approved_script.get("base_blob_sha256") != approved_sha:
                return False
            blob = git_output(target, "show", f"{base}:{relative}")
            if isolated != blob:
                return False
        return True
    # Existing status-only registry commands stay literal, with no root rewrite.
    for script, argument in STATUS_SCRIPTS:
        if command == status_command(script, argument):
            return callback_approved(Path(script.replace("$HOME", str(Path.home()))), grant)
    carried_callback = len(tokens) == 4
    return (len(tokens) in (2, 3, 4) and callback_approved(Path(tokens[1]), grant) and
            Path(tokens[1]).name in {"codex-cmux-title-sync.py", "harness-launch-record"} and
            (len(tokens) == 2 or tokens[2] == "codex") and
            (not carried_callback or
             (tokens[3] == "--callback" and Path(tokens[1]).name == "harness-launch-record" and
              # The row also runs the host collector callback: its bytes need the same grant as the orca/herdr scripts.
              callback_approved(Path.home() / ".local/share/harness-service/bin/harness-session-hook", grant))))


def status_command(script, argument):
    return (f"/bin/sh -c 's=\"{script}\"; [ -x \"$s\" ] && {{ /bin/sh \"$s\"{argument} "
            ">/dev/null 2>&1; exit 0; }; cat >/dev/null'")


def callback_approved(path, grant):
    expected = grant["callbacks"].get(str(path))
    return bool(expected and hashlib.sha256(regular(path)).hexdigest() == expected)


def normalized_hooks(hooks, target, source, grant):
    result = json.loads(json.dumps(hooks))
    for groups in result.get("hooks", {}).values():
        for group in groups:
            for handler in group.get("hooks", []):
                if isinstance(handler.get("command"), str):
                    handler["command"] = root_pattern(target).sub(lambda match: str(source) + match.group(1),
                                                                  approved_package_command(handler["command"], grant))
    return result


def hooks_digest(normalized):
    return hashlib.sha256(json.dumps(normalized, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def native_identity(expected_digest=None):
    """Binary digest first; an unapproved executable is never run for its version."""
    native = Path(os.environ.get("HARNESS_CODEX_BIN") or shutil.which("codex") or "")
    digest = hashlib.sha256(regular(native.resolve(), limit=256 * 1024 * 1024)).hexdigest()
    if expected_digest is not None and digest != expected_digest:
        raise ValueError("native executable changed (the codex on PATH or HARNESS_CODEX_BIN must be the approved one)")
    version = subprocess.run([str(native), "--version"], text=True, capture_output=True, timeout=5, check=True).stdout.strip()
    return digest, version


def approval_record(state, source, target, hooks, base):
    path = state / "hook-approvals" / (hashlib.sha256(str(source).encode()).hexdigest() + ".json")
    return validate_grant(json.loads(regular(path, state, private=True)), source, target, hooks, base)


def validate_grant(grant, source, target, hooks, base):
    if grant.get("schema_version") != 1 or grant.get("source") != str(source):
        raise ValueError("foreign approval")
    if grant.get("algorithm") != ALGORITHM or not re.fullmatch(r"[0-9a-f]{64}", grant.get("approval_receipt_sha256", "")):
        raise ValueError("missing approval provenance")
    snapshot = grant.get("approved_snapshot", {})
    if not re.fullmatch(r"[0-9a-f]{40}", snapshot.get("base_sha", "")) or not re.fullmatch(r"[0-9a-f]{64}", snapshot.get("audit_raw_hooks_sha256", "")):
        raise ValueError("missing approved snapshot")
    for commit in (base, snapshot["base_sha"]):
        if git_output(target, "cat-file", "-t", commit).strip() != b"commit":
            raise ValueError("missing source snapshot commit")
    normalized = normalized_hooks(hooks, target, source, grant)
    if (grant.get("normalization") != NORMALIZATION or
            grant.get("normalized_hooks_sha256") != hooks_digest(normalized) or grant.get("hooks") != normalized):
        raise ValueError("approved hook set changed")
    _, version = native_identity(grant.get("codex_binary_sha256"))
    if version != grant.get("codex_version"):
        raise ValueError("native version changed")
    return grant


def inherit(config, candidate_hooks, published, grant=None):
    """Append verified entries only; existing target decisions always win."""
    try:
        source, target, base, state = broker_source(published)
        source_home = source / ".harness/codex"
        old_hooks = json.loads(regular(source_home / "hooks.json", source))
        new_hooks = json.loads(regular(candidate_hooks))
        grant = (validate_grant(grant, source, target, new_hooks, base) if grant is not None
                 else approval_record(state, source, target, new_hooks, base))
        old_state = tomllib.loads(regular(source_home / "config.toml", source).decode()).get("hooks", {}).get("state", {})
        live_state = tomllib.loads(config).get("hooks", {}).get("state", {})
    except (OSError, ValueError, UnicodeError, KeyError, subprocess.SubprocessError):
        return config
    entries = []
    for event, groups in new_hooks.get("hooks", {}).items():
        for gi, group in enumerate(groups):
            for hi, handler in enumerate(group.get("hooks", [])):
                try:
                    if event not in EVENTS or set(group) - {"hooks", "matcher"}:
                        continue
                    key = f"{published / 'hooks.json'}:{EVENTS[event]}:{gi}:{hi}"
                    old_key = f"{source_home / 'hooks.json'}:{EVENTS[event]}:{gi}:{hi}"
                    approved = old_state.get(old_key, {})
                    old_group = old_hooks["hooks"][event][gi]
                    old_handler = old_group["hooks"][hi]
                    if key in live_state or old_group.get("matcher") != group.get("matcher"):
                        continue
                    if approved.get("trusted_hash") != fingerprint(event, old_group.get("matcher"), old_handler):
                        continue
                    if {k: v for k, v in old_handler.items() if k != "command"} != {k: v for k, v in handler.items() if k != "command"}:
                        continue
                    if not equivalent_command(old_handler["command"], handler["command"], source, target, base, grant):
                        continue
                    fields = f"\n[hooks.state.{json.dumps(key)}]\ntrusted_hash = {json.dumps(fingerprint(event, group.get('matcher'), handler))}\n"
                    if "enabled" in approved:
                        if type(approved["enabled"]) is not bool:
                            continue
                        fields += "enabled = " + str(approved["enabled"]).lower() + "\n"
                    entries.append(fields)
                except (OSError, ValueError, UnicodeError, KeyError, IndexError, subprocess.SubprocessError):
                    continue
    result = config.rstrip() + "\n" + "".join(entries) if entries else config
    tomllib.loads(result)
    return result


def callback_paths(command):
    """Byte-pinned files a hook command may call: status scripts and package callbacks."""
    for script, argument in STATUS_SCRIPTS:
        if command == status_command(script, argument):
            return [Path(script.replace("$HOME", str(Path.home())))]
    tokens = shlex.split(command)
    paths = [Path(token) for token in tokens if Path(token).name in PACKAGE_CALLBACKS]
    if (len(tokens) == 4 and Path(tokens[1]).name == 'harness-launch-record' and
            tokens[2:] == ['codex', '--callback']):
        paths.append(Path.home() / '.local/share/harness-service/bin/harness-session-hook')
    return paths


def native_decisions(home, target, profile, hooks):
    """Every hook needs a trusted, enabled native decision equal to its generated hash."""
    text = regular(home / f"{profile}.config.toml", target).decode()
    decided = tomllib.loads(text).get("hooks", {}).get("state", {})
    evidence = {}
    for event, groups in hooks.get("hooks", {}).items():
        for gi, group in enumerate(groups):
            if set(group) - {"hooks", "matcher"}:
                raise ValueError("unsupported hook group")
            for hi, handler in enumerate(group["hooks"]):
                expected = fingerprint(event, group.get("matcher"), handler)
                key = f"{home / 'hooks.json'}:{EVENTS[event]}:{gi}:{hi}"
                decision = decided.get(key)
                if (not isinstance(decision, dict) or decision.get("trusted_hash") != expected or
                        decision.get("enabled", True) is not True):
                    raise ValueError(f"no trusted enabled native decision for {EVENTS[event]}:{gi}:{hi} in {profile}")
                evidence[key] = {"trusted_hash": expected, "enabled": True}
    if not evidence:
        raise ValueError("no command hooks to record")
    return evidence


def build_grant(published, profile):
    if profile not in PROFILE_NAMES:
        raise ValueError("unknown profile")
    source, target, base, state = broker_source(published)
    if published != target / ".harness/codex":
        raise ValueError("not the session codex home")
    raw = regular(published / "hooks.json", target)
    hooks = json.loads(raw)
    evidence = native_decisions(published, target, profile, hooks)
    commands = [handler["command"] for groups in hooks["hooks"].values() for group in groups for handler in group["hooks"]]
    callbacks = {str(path): hashlib.sha256(regular(path)).hexdigest()
                 for command in commands for path in callback_paths(command)}
    scripts = {}
    for relative in sorted({m.group(1).lstrip("/") for command in commands for m in root_pattern(target).finditer(command)}):
        digest = hashlib.sha256(regular(target / relative, target)).hexdigest()
        if digest != hashlib.sha256(git_output(target, "show", f"{base}:{relative}")).hexdigest():
            raise ValueError(f"script differs from the session snapshot: {relative}")
        scripts[relative] = {"sha256": digest, "base_blob_sha256": digest}
    grant = {"schema_version": 1, "source": str(source), "algorithm": ALGORITHM,
             "approved_snapshot": {"base_sha": base, "audit_raw_hooks_sha256": hashlib.sha256(raw).hexdigest()},
             "normalization": NORMALIZATION, "callbacks": callbacks, "scripts": scripts}
    grant["hooks"] = normalized_hooks(hooks, target, source, grant)
    grant["normalized_hooks_sha256"] = hooks_digest(grant["hooks"])
    grant["codex_binary_sha256"], grant["codex_version"] = native_identity()
    evidence_doc = {"native_decisions": evidence, "profile": profile, "source": str(source), "base_sha": base,
                    "normalized_hooks_sha256": grant["normalized_hooks_sha256"],
                    "codex_binary_sha256": grant["codex_binary_sha256"], "codex_version": grant["codex_version"]}
    grant["approval_evidence"] = evidence_doc  # audit only: reads do not enforce it
    grant["approval_receipt_sha256"] = hashlib.sha256(
        json.dumps(evidence_doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    validate_grant(grant, source, target, hooks, base)
    # Dry-run the launcher's own inheritance: a record that carries nothing is refused.
    inherited = tomllib.loads(inherit("", published / "hooks.json", published, grant)).get("hooks", {}).get("state", {})
    if not inherited:
        raise ValueError("record would inherit no hook: the canonical source home has no matching trusted decision")
    summary = {"source": str(source), "session_id": os.environ["HARNESS_SESSION_ID"], "profile": profile,
               "base_sha": base, "hooks": len(evidence), "inheritable_hooks": len(inherited),
               "scripts": len(scripts), "callbacks": sorted(Path(p).name for p in callbacks),
               "codex_version": grant["codex_version"], "codex_binary_sha256": grant["codex_binary_sha256"],
               "approval_receipt_sha256": grant["approval_receipt_sha256"]}
    return state, source, grant, summary


def write_private(directory, name, data):
    """Create `name` atomically with mode 0600; never follows or overwrites a link."""
    temp = directory / f".{name}.tmp-{uuid.uuid4().hex}"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, directory / name)
        dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except BaseException:
        temp.unlink(missing_ok=True)
        raise


def confirm_on_tty(grant, summary):
    """The operator, not the session, approves: show the exact hooks on the controlling terminal."""
    try:  # like getpass: Linux cannot open /dev/tty with mode "r+"
        fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError as error:
        raise ValueError("capture needs the operator's interactive terminal") from error
    with io.TextIOWrapper(io.FileIO(fd, "r+"), encoding="utf-8") as tty:
        tty.write(json.dumps({"hooks": grant["hooks"], "scripts": grant["scripts"], "callbacks": grant["callbacks"],
                              "record": summary["record"]}, indent=2, sort_keys=True) + "\n")
        tty.write("Record these exact hooks as approved for every fresh isolated session? Type 'record': ")
        tty.flush()
        return tty.readline().strip() == "record"


def capture(published, profile="base", dry_run=False, confirm=None):
    try:
        state, source, grant, summary = build_grant(Path(published), profile)
    except (OSError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
        raise ValueError(f"unreadable or unsupported evidence: {error}") from error
    directory = state / "hook-approvals"
    name = hashlib.sha256(str(source).encode()).hexdigest() + ".json"
    summary["record"] = str(directory / name)
    summary["replaces_existing"] = os.path.lexists(directory / name)
    if dry_run:
        return summary
    # The session can write its own profile, so its native decision is evidence, not approval.
    if confirm is not None and not confirm(grant, summary):
        raise ValueError("the operator did not confirm the hook set")
    try:
        os.mkdir(directory, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("hook-approvals is not a private directory (owner-only 0700, not a link)")
    if summary["replaces_existing"]:
        previous = regular(directory / name, state, private=True)
        write_private(directory, f"{name}.bak-{time.time_ns()}", previous)
        for old in sorted(directory.glob(f"{name}.bak-*"))[:-KEEP_BACKUPS]:
            old.unlink(missing_ok=True)
    write_private(directory, name, (json.dumps(grant, indent=2, sort_keys=True) + "\n").encode())
    return summary


SESSION_ENV = ("HARNESS_SESSION_ID", "HARNESS_SESSION_ROOT", "HARNESS_SOURCE_ROOT", "HARNESS_SESSION_STATE_HOME")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="codex-hook-trust.py", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    cap = commands.add_parser("capture", help="record the owner's native approval for the session's hook set")
    cap.add_argument("--session-id", required=False, help="open launcher session UUID (required)")
    cap.add_argument("--state-home", help="launcher session state directory")
    cap.add_argument("--profile", default="base", choices=sorted(PROFILE_NAMES), help="native profile holding the approval")
    cap.add_argument("--dry-run", action="store_true", help="print what would be recorded; write nothing")
    args = parser.parse_args(argv)
    sandboxed = any(key.startswith("CODEX_SANDBOX") for key in os.environ)
    inherited = any(key in os.environ for key in SESSION_ENV[:3])
    if sandboxed or inherited:
        print("codex-hook-trust: refused: capture must be operator-run from a shell outside any session; "
              "an agent must never run it", file=sys.stderr)
        return 1
    saved = {key: os.environ.get(key) for key in SESSION_ENV}
    try:
        if not args.session_id:
            raise ValueError("pass --session-id UUID explicitly; the session is never taken from the environment")
        args.session_id = str(uuid.UUID(args.session_id))
        if args.state_home:
            os.environ["HARNESS_SESSION_STATE_HOME"] = args.state_home
        state = state_home()
        os.environ["HARNESS_SESSION_ID"] = args.session_id
        os.environ["HARNESS_SESSION_ROOT"] = str(state / "worktrees" / args.session_id)
        os.environ["HARNESS_SOURCE_ROOT"] = regular(state / "sessions" / args.session_id / "source-root", state).decode().strip()
        summary = capture(Path(os.environ["HARNESS_SESSION_ROOT"]) / ".harness/codex", args.profile, args.dry_run,
                          confirm=confirm_on_tty)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"codex-hook-trust: {'refused' if isinstance(error, ValueError) else 'failed'}: {error}", file=sys.stderr)
        return 1
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    print(("DRY RUN: nothing written\n" if args.dry_run else "recorded\n") + json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
