#!/usr/bin/env python3
"""herdr plugin: tab labels from agent session titles and desktop notifications.

herdr runs this with /usr/bin/python3 (3.9) on startup and on the pane/tab
events listed in herdr-plugin.toml. The hook never fails: errors go to stderr,
which herdr keeps in the plugin log, and the exit code stays 0.

Tab labels: a tab with exactly one pane that runs a detected agent takes that
agent's session title, cut to TAB_LABEL_CELLS display cells: the terminal title,
or for Codex the thread's latest name in its CODEX_HOME session index. A tab keeps its
label when the user named it (the label is neither the default label, the tab's
position in its workspace, nor the label this plugin set last). A tab the
plugin labeled goes back to its position label once it no longer holds one
agent with a usable title.

Notifications: working -> idle announces completion and a switch to blocked
announces a request for input, after the state held for the notify delay. The
visible tab stays silent while its host terminal app is frontmost, as herdr's
own toasts do. Clicking the notification activates the host terminal app and
focuses the agent pane.
"""

import fcntl
import json
import os
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time
import unicodedata
from contextlib import contextmanager

TAB_LABEL_CELLS = 20
DEFAULT_NOTIFY_DELAY_SECONDS = 1.0
MAX_NOTIFY_DELAY_SECONDS = 30.0
CODEX_HARNESS_SUFFIX = re.compile(r"\s+\|\s+[\w.-]*harness\s*$")
# Codex titles a session without a task by its thread id, which names nothing.
THREAD_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
HOMEBREW_HERDR = re.compile(r"^(.*)/Cellar/herdr/[^/]+/bin/herdr$")
# The outermost bundle, so an app's nested helper (…/Frameworks/X Helper.app) maps to the app.
APP_BUNDLE = re.compile(r"^(.*?\.app)/")
EXPECTED_LIVE_STATUS = {"finished": "idle", "attention": "blocked"}
# A harness Codex home, looked up from the pane's directory upward.
CODEX_INDEX = os.path.join(".harness", "codex", "session_index.jsonl")
CODEX_INDEX_MAX_BYTES = 16 * 1024 * 1024
CODEX_HOME_DEPTH = 8


def log(message):
    sys.stderr.write("harness-herdr-plugin: %s\n" % message)


def run(argv):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        log("%s failed: %s" % (argv[0], error))
        return None
    if done.returncode != 0:
        log("%s exited %s: %s" % (argv[0], done.returncode, done.stderr.strip()[:200]))
        return None
    return done.stdout


def herdr_bin():
    return os.environ.get("HERDR_BIN_PATH") or shutil.which("herdr") or "herdr"


def herdr(*args):
    out = run([herdr_bin()] + list(args))
    if out is None:
        raise RuntimeError("herdr %s failed" % " ".join(args))
    return json.loads(out)["result"]


@contextmanager
def locked_state():
    state_dir = os.environ.get("HERDR_PLUGIN_STATE_DIR") or os.path.expanduser(
        "~/.local/state/harness-herdr-plugin")
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, "state.json")
    with open(os.path.join(state_dir, "state.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path, encoding="utf-8") as handle:
                state = json.load(handle)
        except (OSError, ValueError):
            state = {}
        if not isinstance(state, dict):
            state = {}
        for key in ("tabs", "panes"):
            if not isinstance(state.get(key), dict):
                state[key] = {}
        try:
            yield state
        finally:
            # Save even after a failure so work already done (a rename) keeps its record.
            temporary = path + ".tmp"
            with open(temporary, "w", encoding="utf-8") as handle:
                json.dump(state, handle, ensure_ascii=False)
            os.replace(temporary, path)


def cells(char):
    return 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1


def tab_label(title):
    text = CODEX_HARNESS_SUFFIX.sub("", title).strip()
    if THREAD_ID.match(text):
        return ""
    if sum(cells(char) for char in text) <= TAB_LABEL_CELLS:
        return text
    kept, used = "", 0
    for char in text:
        if used + cells(char) > TAB_LABEL_CELLS - 1:
            break
        kept += char
        used += cells(char)
    return kept.rstrip() + "…"


def thread_names(path, cache):
    """{thread id: latest name} from a Codex session index; the index is append-only."""
    if path in cache:
        return cache[path]
    names = {}
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        fd = None
    if fd is not None:
        with os.fdopen(fd, "rb") as handle:
            info = os.fstat(handle.fileno())
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid():
                if info.st_size > CODEX_INDEX_MAX_BYTES:
                    handle.seek(info.st_size - CODEX_INDEX_MAX_BYTES)
                    handle.readline()  # partial line
                for raw in handle:
                    try:
                        record = json.loads(raw)
                    except ValueError:
                        continue
                    if (isinstance(record, dict) and isinstance(record.get("id"), str)
                            and isinstance(record.get("thread_name"), str)):
                        names[record["id"].lower()] = record["thread_name"]
    cache[path] = names
    return names


def codex_thread_name(pane, cache):
    """The latest name of a Codex pane's thread, or "".

    Codex renames a thread from another app-server connection (a title hook), which
    the running TUI never sees, so its terminal title keeps the thread id or the name
    it resumed with. The first index on the way up from the pane's directory that
    knows the thread wins; ~/.codex is the last candidate.
    """
    session = pane.get("agent_session")
    thread = session.get("value") if isinstance(session, dict) else None
    if pane.get("agent") != "codex" or not isinstance(thread, str) or not THREAD_ID.match(thread):
        return ""
    candidates = []
    for start in (pane.get("foreground_cwd"), pane.get("cwd")):
        directory = start if isinstance(start, str) and os.path.isabs(start) else None
        for _ in range(CODEX_HOME_DEPTH):
            if directory is None:
                break
            index = os.path.join(directory, CODEX_INDEX)
            if index not in candidates:
                candidates.append(index)
            parent = os.path.dirname(directory)
            directory = parent if parent != directory else None
    candidates.append(os.path.join(os.path.expanduser("~"), ".codex", "session_index.jsonl"))
    for index in candidates:
        name = thread_names(index, cache).get(thread.lower())
        if name is not None:
            return "".join(c for c in name if not unicodedata.category(c).startswith("C")).strip()
    return ""


def session_title(pane, cache):
    return codex_thread_name(pane, cache) or (pane.get("terminal_title_stripped") or "").strip()


def sync_tabs():
    # Read herdr's lists under the lock so a concurrent run cannot act on an older snapshot.
    with locked_state() as state:
        tabs = herdr("tab", "list")["tabs"]
        panes = herdr("pane", "list")["panes"]
        panes_by_tab = {}
        for pane in panes:
            panes_by_tab.setdefault(pane.get("tab_id"), []).append(pane)
        owned = state["tabs"]
        indexes = {}
        live_tabs = {tab["tab_id"] for tab in tabs}
        for tab_id in [tab_id for tab_id in owned if tab_id not in live_tabs]:
            del owned[tab_id]
        live_panes = {pane.get("pane_id") for pane in panes}
        for pane_id in [pane_id for pane_id in state["panes"] if pane_id not in live_panes]:
            del state["panes"][pane_id]
        # An unnamed tab shows its position in the workspace, not its `number`, which
        # keeps counting after a tab closes.
        positions, seen_in_workspace = {}, {}
        for tab in tabs:
            workspace_id = tab.get("workspace_id")
            seen_in_workspace[workspace_id] = seen_in_workspace.get(workspace_id, 0) + 1
            positions[tab["tab_id"]] = str(seen_in_workspace[workspace_id])
        for tab in tabs:
            tab_id = tab["tab_id"]
            position = positions[tab_id]
            current = tab.get("label") or ""
            if current != position and current != owned.get(tab_id):
                continue  # the user named this tab
            members = panes_by_tab.get(tab_id, [])
            wanted = ""
            if tab.get("pane_count") == 1 and len(members) == 1 and members[0].get("agent"):
                wanted = tab_label(session_title(members[0], indexes))
            if not wanted:
                # No single agent title any more (agent exited, tab split, thread-id title):
                # hand the tab back its position label. herdr cannot clear a tab name, so
                # the plugin keeps owning that label.
                wanted = position
            if wanted != current:
                # Record first: if the rename fails the old label is still the plugin's
                # or the position, so the next run retries.
                owned[tab_id] = wanted
                try:
                    herdr("tab", "rename", tab_id, wanted)
                except Exception as error:  # noqa: BLE001 - one tab must not stop the rest
                    log("rename %s: %s" % (tab_id, error))


def record_status(payload):
    data = payload.get("data") or {}
    pane_id = data.get("pane_id") or os.environ.get("HERDR_PANE_ID")
    status = data.get("agent_status")
    if not pane_id or not status:
        return None
    with locked_state() as state:
        entry = state["panes"].get(pane_id) or {}
        previous = entry.get("status")
        seq = int(entry.get("seq", 0)) + 1
        state["panes"][pane_id] = {"status": status, "seq": seq}
    if status == "blocked" and previous != "blocked":
        kind = "attention"
    elif status == "idle" and previous == "working":
        kind = "finished"
    else:
        return None
    return {"kind": kind, "pane_id": pane_id, "seq": seq, "agent": data.get("agent") or "agent"}


def still_current(pending):
    with locked_state() as state:
        return (state["panes"].get(pending["pane_id"]) or {}).get("seq") == pending["seq"]


def notify_delay():
    try:
        delay = float(os.environ.get("HARNESS_HERDR_NOTIFY_DELAY_SECONDS", ""))
    except ValueError:
        return DEFAULT_NOTIFY_DELAY_SECONDS
    return min(max(0.0, delay), MAX_NOTIFY_DELAY_SECONDS)


def host_bundle_ids():
    out = run(["ps", "-Ao", "pid=,ppid=,comm="]) or ""
    processes = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            processes[parts[0]] = (parts[1], parts[2])
    hosts = []
    for ppid, command in processes.values():
        if os.path.basename(command) != "herdr" or ppid == "1":
            continue
        current, seen = ppid, set()
        while current in processes and current not in seen:
            seen.add(current)
            parent, name = processes[current]
            match = APP_BUNDLE.match(name)
            if match:
                bundle = app_bundle_id(match.group(1))
                if bundle and bundle not in hosts:
                    hosts.append(bundle)
                break
            current = parent
    return hosts


def app_bundle_id(app_path):
    try:
        with open(os.path.join(app_path, "Contents", "Info.plist"), "rb") as handle:
            return plistlib.load(handle).get("CFBundleIdentifier")
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None


def front_bundle_id():
    asn = (run(["lsappinfo", "front"]) or "").strip()
    if not asn:
        return None
    match = re.search(r'"CFBundleIdentifier"="([^"]*)"',
                      run(["lsappinfo", "info", "-only", "bundleid", asn]) or "")
    return match.group(1) if match else None


def terminal_notifier():
    found = shutil.which("terminal-notifier")
    if found:
        return found
    homebrew = HOMEBREW_HERDR.match(os.path.realpath(herdr_bin()))
    candidate = homebrew and os.path.join(homebrew.group(1), "bin", "terminal-notifier")
    return candidate if candidate and os.access(candidate, os.X_OK) else None


def announce(pending):
    pane_id = pending["pane_id"]
    pane = next((item for item in herdr("pane", "list")["panes"]
                 if item.get("pane_id") == pane_id), None)
    # Events run in separate processes and can take the lock out of order; announce only
    # what herdr still reports for the pane.
    if pane is None or pane.get("agent_status") != EXPECTED_LIVE_STATUS[pending["kind"]]:
        return
    workspace = next((item for item in herdr("workspace", "list")["workspaces"]
                      if item.get("workspace_id") == pane.get("workspace_id")), {})
    hosts = host_bundle_ids()
    front = front_bundle_id()
    visible = workspace.get("focused") and workspace.get("active_tab_id") == pane.get("tab_id")
    if visible and (not hosts or front in hosts):
        return
    host = front if front in hosts else (hosts[0] if hosts else None)
    template = "✅ %s 완료" if pending["kind"] == "finished" else "⏳ %s 입력 필요"
    title = template % pending["agent"]
    subtitle = workspace.get("label") or pane.get("workspace_id") or ""
    message = CODEX_HARNESS_SUFFIX.sub("", session_title(pane, {})).strip() or pane_id
    notifier = terminal_notifier()
    if notifier:
        # terminal-notifier runs the click command without herdr's environment, so carry
        # the socket of this herdr session (named sessions use a non-default one).
        click = "%s agent focus %s" % (shlex.quote(herdr_bin()), shlex.quote(pane_id))
        socket = os.environ.get("HERDR_SOCKET_PATH")
        if socket:
            click = "HERDR_SOCKET_PATH=%s %s" % (shlex.quote(socket), click)
        argv = [notifier, "-title", title, "-subtitle", subtitle, "-message", message,
                "-group", "herdr-harness." + pane_id, "-execute", click]
        if host:
            argv += ["-activate", host]
        run(argv)
        return
    run(["osascript", "-e", "on run argv",
         "-e", "display notification (item 2 of argv) with title (item 1 of argv) "
               "subtitle (item 3 of argv)",
         "-e", "end run", title, message, subtitle])


CELLAR_PATH = re.compile(r"^(.*)/Cellar/harness-launcher/[^/]+/(.*)$")
DEFAULT_INSTALL_DIR = "~/.local/share/harness-launcher/herdr-plugin"
PACKAGED_SCRIPT = '"harness_herdr_plugin.py"'


def install(argv):
    """Link a manifest that survives upgrades.

    herdr stores a linked manifest by its resolved path, so linking the packaged
    directory would pin a versioned Homebrew Cellar path that the next upgrade
    removes. Write the manifest outside the package instead, pointing its
    commands at this script through the unversioned `opt` path.
    """
    import argparse

    parser = argparse.ArgumentParser(prog="harness_herdr_plugin.py install")
    parser.add_argument("--dir", default=os.path.expanduser(DEFAULT_INSTALL_DIR),
                        help="where to write the linked manifest (default: %(default)s)")
    parser.add_argument("--script", default=os.path.abspath(__file__),
                        help="script path the manifest runs (default: this file)")
    args = parser.parse_args(argv)
    script = args.script
    cellar = CELLAR_PATH.match(script)
    if cellar:
        script = "%s/opt/harness-launcher/%s" % cellar.groups()
    packaged = os.path.join(os.path.dirname(os.path.abspath(__file__)), "herdr-plugin.toml")
    with open(packaged, encoding="utf-8") as handle:
        manifest = handle.read().replace(PACKAGED_SCRIPT, json.dumps(script))
    os.makedirs(args.dir, exist_ok=True)
    with open(os.path.join(args.dir, "herdr-plugin.toml"), "w", encoding="utf-8") as handle:
        handle.write(manifest)
    run([herdr_bin(), "plugin", "unlink", "harness.launcher"])  # absent on first install
    if run([herdr_bin(), "plugin", "link", args.dir]) is None:
        sys.stderr.write("herdr plugin link %s failed\n" % args.dir)
        return 1
    print("linked %s (runs %s)" % (args.dir, script))
    print('set ui.toast.delivery = "off" in ~/.config/herdr/config.toml, then run '
          "herdr server reload-config")
    return 0


def main():
    if sys.argv[1:2] == ["install"]:
        return install(sys.argv[2:])
    pending = None
    if os.environ.get("HERDR_PLUGIN_EVENT") == "pane.agent_status_changed":
        try:
            pending = record_status(json.loads(os.environ.get("HERDR_PLUGIN_EVENT_JSON") or "{}"))
        except Exception as error:  # noqa: BLE001 - a hook must never fail
            log("status: %s" % error)
    try:
        sync_tabs()
    except Exception as error:  # noqa: BLE001
        log("tabs: %s" % error)
    if pending:
        try:
            time.sleep(notify_delay())
            if still_current(pending):
                announce(pending)
        except Exception as error:  # noqa: BLE001
            log("notify: %s" % error)
    return 0


if __name__ == "__main__":
    sys.exit(main())
