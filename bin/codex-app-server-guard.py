#!/usr/bin/env python3
"""Relay a Codex app-server stream and keep execution roots inside one harness.

SDK hosts start one `codex app-server` per agent and send each thread's working
directory over JSON-RPC, so the launcher's cwd-based profile boundary cannot
bind the session by itself. This relay forwards newline-delimited JSON-RPC in
both directions and answers client messages whose execution-root fields leave
the harness with an error instead of forwarding them.

It is a profile-consistency boundary for a trusted local client, not a sandbox:
only Slack approval keys within `config` are guarded; explicit file operations are not inspected.

Usage: codex-app-server-guard.py --root <harness-root> --server-cwd <dir>
       --prefix <prefix> [--registry <profiles-dir>] -- <argv...>
"""

import json
import importlib.util
import os
import signal
import subprocess
import sys
import threading
import tomllib

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

from harness_profile_resolver import registered_profiles  # noqa: E402

# Keys that decide where Codex executes or which instructions it loads. They
# are matched at any depth of every client message.
GUARDED_KEYS = frozenset({"cwd", "cwds", "runtimeWorkspaceRoots", "extraRoots", "selectedCapabilityRoots"})

# Schema path fields (see test/fixtures/codex-app-server-path-fields.json) that
# are reached only through a guarded key.
CHECKED_FIELDS = frozenset({"CapabilityRootLocation.path"})

# Schema path fields that are deliberately not inspected, with the reason.
EXEMPT_FIELDS = {
    "AdditionalFileSystemPermissions.read": "permission grant chosen by the client",
    "AdditionalFileSystemPermissions.write": "permission grant chosen by the client",
    "FileSystemPath.path": "permission grant chosen by the client",
    "FileSystemSandboxEntry.path": "permission grant chosen by the client",
    "FileSystemSpecialPath.path": "permission grant chosen by the client",
    "FileSystemSpecialPath.subpath": "permission grant chosen by the client",
    "ConfigBatchWriteParams.filePath": "config write target; config is not a boundary",
    "ConfigValueWriteParams.filePath": "config write target; config is not a boundary",
    "ConfigEdit.keyPath": "TOML key path, not a filesystem path",
    "ConfigValueWriteParams.keyPath": "TOML key path, not a filesystem path",
    "FsCopyParams.destinationPath": "explicit client file operation",
    "FsCopyParams.sourcePath": "explicit client file operation",
    "FsCreateDirectoryParams.path": "explicit client file operation",
    "FsGetMetadataParams.path": "explicit client file operation",
    "FsReadDirectoryParams.path": "explicit client file operation",
    "FsReadFileParams.path": "explicit client file operation",
    "FsRemoveParams.path": "explicit client file operation",
    "FsWatchParams.path": "explicit client file operation",
    "FsWriteFileParams.path": "explicit client file operation",
    "FuzzyFileSearchParams.roots": "search roots chosen by the client; no execution",
    "FuzzyFileSearchSessionStartParams.roots": "search roots chosen by the client; no execution",
    "MarketplaceAddParams.sparsePaths": "repository sparse-checkout paths",
    "PluginInstallParams.marketplacePath": "plugin management path",
    "PluginReadParams.marketplacePath": "plugin management path",
    "PluginShareSaveParams.pluginPath": "plugin management path",
    "ProjectCreateParams.roots": "project record; threads still carry a checked cwd",
    "ProjectImportParams.roots": "project record; threads still carry a checked cwd",
    "ProjectRoot.path": "project record; threads still carry a checked cwd",
    "ProjectUpdateParams.roots": "project record; threads still carry a checked cwd",
    "SandboxPolicy.writableRoots": "sandbox grant chosen by the client",
    "SessionMigration.path": "imported session file",
    "SkillsConfigWriteParams.path": "skill enablement toggle",
    "ThreadForkParams.path": "rollout file to load; the thread cwd is injected or checked",
    "ThreadResumeParams.path": "rollout file to load; the thread cwd is injected or checked",
    "UserInput.path": "turn input attachment",
}

_policy_spec = importlib.util.spec_from_file_location("slack_policy", os.path.join(os.path.dirname(__file__), "slack-approval-policy.py"))
slack_policy = importlib.util.module_from_spec(_policy_spec)
_policy_spec.loader.exec_module(slack_policy)

INVALID_PARAMS = -32602
INVALID_REQUEST = -32600
PARSE_ERROR = -32700


def classify_field(field):
    """Return how a schema path field is handled, or None when unclassified."""
    if field.rsplit(".", 1)[-1] in GUARDED_KEYS or field in CHECKED_FIELDS:
        return "guarded"
    reason = EXEMPT_FIELDS.get(field)
    return f"exempt: {reason}" if reason else None


def usage():
    print("usage: codex-app-server-guard.py --root <harness-root> --server-cwd <dir> "
          "--prefix <prefix> [--registry <profiles-dir>] -- <argv...>", file=sys.stderr)
    return 2


def parse_args(argv):
    options = {"--root": None, "--server-cwd": None, "--prefix": None, "--registry": None}
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--":
            command = argv[index + 1:]
            required = (options["--root"], options["--server-cwd"], options["--prefix"])
            return (options, command) if all(required) and command else None
        if arg in options and index + 1 < len(argv):
            options[arg] = argv[index + 1]
            index += 2
            continue
        return None
    return None


class DuplicateKey(ValueError):
    pass


def unique_object(pairs):
    """json object hook: reject duplicate keys so no parser's choice matters."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKey(key)
        result[key] = value
    return result


def within(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


class Guard:
    def __init__(self, root, server_cwd, prefix, registry=None):
        self.root = os.path.realpath(root)
        self.server_cwd = server_cwd
        self.prefix = prefix
        # Nested harness roots are compared by inode: realpath keeps the
        # caller's letter case, which a case-insensitive volume accepts.
        self.nested = set()
        if registry:
            for _name, other in registered_profiles(registry):
                other = os.path.realpath(other)
                if other != self.root and within(other, self.root):
                    info = os.stat(other)
                    self.nested.add((info.st_dev, info.st_ino))

    def inside_nested(self, real):
        current = real
        while current != self.root and within(current, self.root):
            try:
                info = os.stat(current)
            except OSError:
                pass  # missing tail
            else:
                if (info.st_dev, info.st_ino) in self.nested:
                    return True
            current = os.path.dirname(current)
        return False

    def allowed(self, value):
        if not isinstance(value, str):
            return False
        path = os.path.expanduser(value)
        if not os.path.isabs(path):
            return False
        # realpath resolves every existing component and keeps a missing tail
        # lexical, so `..` after a symlink is applied to its target.
        real = os.path.realpath(path)
        if not within(real, self.root):
            return False
        return not self.inside_nested(real)

    def values(self, key, value):
        """Yield the path values carried by one guarded key."""
        if value is None:
            return
        items = value if isinstance(value, list) else [value]
        for item in items:
            if key == "selectedCapabilityRoots":
                location = item.get("location") if isinstance(item, dict) else None
                yield location.get("path") if isinstance(location, dict) else item
            else:
                yield item

    def violations(self, node):
        """Yield (field, value) for every guarded value outside the boundary."""
        if isinstance(node, dict):
            for key, value in node.items():
                if key in GUARDED_KEYS:
                    for item in self.values(key, value):
                        if not self.allowed(item):
                            yield key, item
                else:
                    yield from self.violations(value)
        elif isinstance(node, list):
            for item in node:
                yield from self.violations(item)

    def describe(self, method, field, value):
        return (f"harness-launcher: {method} {field} is outside the {self.prefix} "
                f"harness boundary: {value}")

    @staticmethod
    def error(rid, code, text):
        return {"id": rid, "error": {"code": code, "message": text}}

    def filter_line(self, raw):
        """Return (bytes to forward or None, error response for the client or None)."""
        if not raw.strip():
            return None, None
        try:
            message = json.loads(raw, object_pairs_hook=unique_object)
        except DuplicateKey as exc:
            # Parse again (last key wins) only to route the refusal.
            return self.reject(json.loads(raw), f"harness-launcher: duplicate JSON key: {exc}")
        except (ValueError, UnicodeDecodeError, RecursionError):
            return None, self.error(None, PARSE_ERROR, "harness-launcher: unparseable JSON-RPC line")
        if not isinstance(message, dict):
            return None, self.error(None, INVALID_REQUEST, "harness-launcher: batches and non-object messages are not supported")
        try:
            return self.filter_message(raw, message)
        except (ValueError, RecursionError):
            # For example an embedded NUL in a path, or nesting too deep to scan.
            return self.reject(message, "harness-launcher: message cannot be checked")

    def reject(self, message, text):
        """Refuse a message that cannot be forwarded.

        A client response to a server request (id, no method) is answered to
        the server with an error so its pending request completes; anything
        else gets an error to the client.
        """
        rid = message.get("id") if isinstance(message, dict) else None
        rid = rid if isinstance(rid, (str, int)) else None
        if isinstance(message, dict) and "method" not in message and rid is not None:
            return (json.dumps(self.error(rid, INVALID_REQUEST, text)) + "\n").encode(), None
        return None, self.error(rid, INVALID_REQUEST, text)

    @staticmethod
    def canonical_config_key(key):
        if not isinstance(key, str):
            return key
        try:
            parsed = tomllib.loads(key + " = 0")
            parts = []
            while isinstance(parsed, dict) and len(parsed) == 1:
                part, parsed = next(iter(parsed.items()))
                parts.append(part)
            return ".".join(parts) if parsed == 0 else key
        except tomllib.TOMLDecodeError:
            return key

    def protected_slack_key(self, key):
        key = self.canonical_config_key(key)
        config = slack_policy.codex_config()
        if not config or not isinstance(key, str):
            return False
        return any(key == target or target.startswith(key + ".") or key.startswith(target + ".") for target in config)

    def slack_config_write(self, node):
        if isinstance(node, dict):
            if self.protected_slack_key(node.get("keyPath")):
                return True
            return any(self.slack_config_write(value) for value in node.values())
        if isinstance(node, list):
            return any(self.slack_config_write(value) for value in node)
        return False

    def filter_message(self, raw, message):
        method = message.get("method")
        rid = message.get("id")
        if isinstance(method, str):
            params = message.get("params")
            policy = slack_policy.codex_config()
            if policy and method.startswith("config/") and method.lower().endswith("write") and self.slack_config_write(params):
                return None, self.error(rid, INVALID_PARAMS, "harness-launcher: Slack user approval policy cannot be overridden")
            if policy and method in ("thread/start", "thread/resume", "thread/fork", "turn/start") and isinstance(params, dict):
                params["approvalPolicy"] = "on-request"
                params["approvalsReviewer"] = "user"
                if method != "turn/start":
                    config = params.setdefault("config", {})
                    if not isinstance(config, dict):
                        return None, self.error(rid, INVALID_PARAMS, "harness-launcher: Slack policy requires object config")
                    # Native config maps can contain nested parents and dotted
                    # children; refuse overlap rather than depend on map order.
                    if any(self.protected_slack_key(key) and (self.canonical_config_key(key) != key or key not in policy) for key in config):
                        return None, self.error(rid, INVALID_PARAMS, "harness-launcher: use flattened config fields outside the protected Slack approval policy")
                    config.update(policy)
                raw = (json.dumps(message) + "\n").encode()

            if method in ("thread/resume", "thread/fork") and "id" in message and isinstance(params, dict) \
                    and params.get("cwd") is None:
                params["cwd"] = self.server_cwd
                raw = (json.dumps(message) + "\n").encode()
            for field, value in self.violations(params):
                text = self.describe(method, field, value)
                if "id" in message:
                    return None, self.error(rid, INVALID_PARAMS, text)
                print(text, file=sys.stderr, flush=True)
                return None, None
            return raw, None
        if "id" in message and ("result" in message or "error" in message):
            # Responses to server requests (approvals, elicitations) carry
            # grants, not execution roots; a violating one becomes a refusal.
            for field, value in self.violations(message.get("result")):
                refusal = self.error(rid, INVALID_PARAMS, self.describe("response", field, value))
                return (json.dumps(refusal) + "\n").encode(), None
            return raw, None
        return None, self.error(rid if "id" in message else None, INVALID_REQUEST,
                                "harness-launcher: message has no method")


def main(argv):
    parsed = parse_args(argv)
    if parsed is None:
        return usage()
    options, command = parsed
    root, server_cwd = options["--root"], options["--server-cwd"]
    if not os.path.isdir(root):
        print(f"codex-app-server-guard: harness root is not a directory: {root}", file=sys.stderr)
        return 2
    guard = Guard(root, server_cwd, options["--prefix"], options["--registry"])
    if not guard.allowed(server_cwd):
        print(f"codex-app-server-guard: server cwd is outside the harness root: {server_cwd}", file=sys.stderr)
        return 2
    try:
        # Buffered pipes: readline on an unbuffered pipe reads one byte per
        # system call, which stalls multi-megabyte messages.
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    except OSError as exc:
        print(f"codex-app-server-guard: cannot start {command[0]}: {exc}", file=sys.stderr)
        return 127

    def forward_signal(signum, _frame):
        try:
            child.send_signal(signum)
        except OSError:
            pass

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, forward_signal)

    out = sys.stdout.buffer
    out_lock = threading.Lock()

    def emit(data):
        with out_lock:
            out.write(data)
            out.flush()

    def relay_child_output():
        try:
            for line in iter(child.stdout.readline, b""):
                emit(line)
        except (BrokenPipeError, ValueError):
            # The client is gone; nothing can receive the server's output.
            try:
                child.terminate()
            except OSError:
                pass

    def relay_client_input():
        try:
            for raw in iter(sys.stdin.buffer.readline, b""):
                forward, response = guard.filter_line(raw)
                if response is not None:
                    emit((json.dumps(response) + "\n").encode())
                if forward is not None:
                    child.stdin.write(forward)
                    child.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass
        finally:
            try:
                child.stdin.close()
            except OSError:
                pass

    # Both relays are daemon threads; the process lifetime follows the child,
    # so a signal-terminated server ends the guard even while the client keeps
    # its end of stdin open.
    relay_out = threading.Thread(target=relay_child_output, daemon=True)
    relay_in = threading.Thread(target=relay_client_input, daemon=True)
    relay_out.start()
    relay_in.start()
    status = child.wait()
    relay_out.join(timeout=5)
    with out_lock:
        try:
            out.flush()
        except (BrokenPipeError, ValueError):
            pass
    # The input relay may still be blocked in a buffered stdin read; a normal
    # interpreter shutdown would abort on that reader's lock.
    os._exit(status if status >= 0 else 128 - status)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
