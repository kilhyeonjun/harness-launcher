#!/usr/bin/env python3
"""herdr plugin: session titles, tab labels, sidebar tokens and desktop notifications.

herdr runs this with /usr/bin/python3 (3.9) on startup and on the pane/tab
events listed in herdr-plugin.toml. The hook never fails: errors go to stderr,
which herdr keeps in the plugin log, and the exit code stays 0.

Session titles: a rename reaches the agent's own records before its terminal
title, so the title comes from those first: for Codex the thread's latest name
in its CODEX_HOME session index, for Claude the latest custom title in its
transcript, then the terminal title, then Claude's AI title. Each agent pane
gets it as its herdr metadata title (the sidebar `pane` token), with Korean
state labels and a `$model` token (model and reasoning effort of the latest
turn, read when the agent's status changes).

Tab labels: a tab that holds a detected agent takes the session title of its
first agent with a usable title, cut to TAB_LABEL_CELLS display cells; more
agents in the same tab show as " +N" inside that width, plain shells are not
counted. A tab keeps its label when the user named it (the label is neither the
default label, the tab's position in its workspace, nor the label this plugin
set last). A tab the plugin labeled goes back to its position label once it no
longer holds an agent with a usable title.

Watcher: herdr has no plugin event for a title change, so each run makes sure
one background watcher (`watch`) runs. It subscribes to pane.updated over the
API socket (terminal titles) and checks the session indexes and transcripts
once a second for appended title records, then syncs at once. It exits when
this file changes (an upgrade: the next run starts the new one) or herdr stops
answering. Plan usage is not per pane: `harness-herdr-web usage` serves the tab
bar and a popup.

Notifications: working -> idle or done (a finish the user has not seen yet)
announces completion and a switch to blocked
announces a request for input, after the state held for the notify delay. The
visible tab stays silent while its host terminal app is frontmost, as herdr's
own toasts do. Clicking the notification activates the host terminal app and
focuses the agent pane.
"""

import fcntl
import glob
import hashlib
import json
import os
import plistlib
import re
import select
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import time
import unicodedata
from contextlib import contextmanager

TAB_LABEL_CELLS = 20
TITLE_MAX_CHARS = 200
DEFAULT_NOTIFY_DELAY_SECONDS = 1.0
MAX_NOTIFY_DELAY_SECONDS = 30.0
CODEX_HARNESS_SUFFIX = re.compile(r"\s+\|\s+[\w.-]*harness\s*$")
# Codex prefixes its title while a turn waits for approval and blinks the marker.
CODEX_ACTION_PREFIX = re.compile(r"^\[ . \] Action Required \|\s*")
# Session ids; Codex titles a session without a task by its thread id, which names nothing.
THREAD_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
HOMEBREW_HERDR = re.compile(r"^(.*)/Cellar/herdr/[^/]+/bin/herdr$")
# The outermost bundle, so an app's nested helper (…/Frameworks/X Helper.app) maps to the app.
APP_BUNDLE = re.compile(r"^(.*?\.app)/")
EXPECTED_LIVE_STATUS = {"attention": "blocked"}
# herdr reports a finished turn as `done` until the user sees the pane, `idle` after
# (app/api_helpers.rs pane_agent_status); a tab out of sight finishes working -> done.
FINISHED = ("idle", "done")


def same_status(a, b):
    """`done` and `idle` are one finished turn: seen by the user or not yet."""
    return a == b or (a in FINISHED and b in FINISHED)
# A harness Codex home, looked up from the pane's directory upward.
CODEX_INDEX = os.path.join(".harness", "codex", "session_index.jsonl")
CODEX_INDEX_MAX_BYTES = 16 * 1024 * 1024
CODEX_HOME_DEPTH = 8
# A harness Claude config directory, looked up the same way; ~/.claude is the last candidate.
CLAUDE_HOME = os.path.join(".harness", "claude")
METADATA_SOURCE = "harness.launcher"
STATE_LABELS = (("idle", "대기"), ("working", "작업 중"), ("blocked", "입력 필요"), ("done", "응답 종료"))
# A harness answer that leaves a choice to the user marks its recommended option.
DECISION_MARK = "← 추천"
DECISION_LABEL = "결정 필요"
MODEL_PREFIX = re.compile(r"^(gpt-|claude-)")
TAIL_BYTES = 512 * 1024
TAIL_MAX_BYTES = 32 * 1024 * 1024
MISSING_RETRY_SECONDS = 60
TITLE_MARKERS = (b'"thread_name"', b'"custom-title"', b'"ai-title"')
WATCH_POLL_SECONDS = 1.0
WATCH_REFRESH_SECONDS = 15.0
WATCH_RECONNECT_SECONDS = 5.0
WATCH_MAX_FAILURES = 3
WATCH_LOG_MAX_BYTES = 256 * 1024
SESSION_KEEP_SECONDS = 7 * 86400
PLUGIN_ID = "harness.launcher"


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


def herdr_ok(*args):
    """Run a herdr command that answers with nothing; True when it succeeded."""
    return run([herdr_bin()] + list(args)) is not None


def state_dir():
    path = os.environ.get("HERDR_PLUGIN_STATE_DIR") or os.path.expanduser(
        "~/.local/state/harness-herdr-plugin")
    os.makedirs(path, exist_ok=True)
    return path


def session_key():
    """herdr gives a plugin one state directory for all herdr sessions (named sessions
    included), so per-session records and the watcher are keyed by the API socket."""
    return hashlib.sha1((os.environ.get("HERDR_SOCKET_PATH") or "").encode()).hexdigest()[:12]


def session(state):
    """This herdr session's records: labels the plugin gave tabs (`tabs`), pane statuses
    (`panes`), reported metadata (`meta`), transcript read offsets (`scans`) and found
    file paths (`paths`). Tab and pane ids repeat across sessions, and each session
    prunes only its own records."""
    entry = state["sessions"].get(session_key())
    if not isinstance(entry, dict):
        entry = state["sessions"][session_key()] = {}
    entry["seen"] = time.time()
    if not isinstance(entry.get("tabs"), dict):
        # Before 0.40.0 tab labels were one shared record; the first session adopts it.
        legacy = state.pop("tabs", None)
        entry["tabs"] = legacy if isinstance(legacy, dict) else {}
    for key in ("panes", "meta", "scans", "paths"):
        if not isinstance(entry.get(key), dict):
            entry[key] = {}
    return entry


@contextmanager
def locked_state():
    directory = state_dir()
    path = os.path.join(directory, "state.json")
    with open(os.path.join(directory, "state.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path, encoding="utf-8") as handle:
                state = json.load(handle)
        except (OSError, ValueError):
            state = {}
        if not isinstance(state, dict):
            state = {}
        state.pop("panes", None)  # before 0.40.0 pane statuses were not per session
        if not isinstance(state.get("sessions"), dict):
            state["sessions"] = {}
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


def clean(value):
    return "".join(c for c in value if not unicodedata.category(c).startswith("C")).strip()


def display_title(title):
    """A session title without Codex's approval marker and harness suffix; "" for a thread id."""
    text = CODEX_ACTION_PREFIX.sub("", clean(title))
    text = CODEX_HARNESS_SUFFIX.sub("", text).strip()
    return "" if THREAD_ID.match(text) else text[:TITLE_MAX_CHARS]


def tab_label(title, others=0):
    """A title cut to the label width; `others` more agents in the tab show as " +N"."""
    text = display_title(title)
    if not text:
        return ""
    suffix = " +%d" % others if others else ""
    room = TAB_LABEL_CELLS - len(suffix)
    if sum(cells(char) for char in text) <= room:
        return text + suffix
    kept, used = "", 0
    for char in text:
        if used + cells(char) > room - 1:
            break
        kept += char
        used += cells(char)
    return kept.rstrip() + "…" + suffix


def open_owned(path):
    """A binary handle on a regular file you own, never through a symlink; or None."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except (OSError, TypeError, ValueError):
        return None
    handle = os.fdopen(fd, "rb")
    info = os.fstat(handle.fileno())
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        handle.close()
        return None
    return handle


def thread_names(path, cache, positions=None):
    """{thread id: latest name} from a Codex session index; the index is append-only.

    `positions` receives [inode, offset after the last complete line read]."""
    if path in cache:
        return cache[path]
    names = {}
    handle = open_owned(path)
    if handle is not None:
        with handle:
            info = os.fstat(handle.fileno())
            offset = 0
            if info.st_size > CODEX_INDEX_MAX_BYTES:
                handle.seek(info.st_size - CODEX_INDEX_MAX_BYTES)
                offset = info.st_size - CODEX_INDEX_MAX_BYTES + len(handle.readline())  # partial line
            for raw in handle:
                if not raw.endswith(b"\n"):
                    break  # still being written
                offset += len(raw)
                try:
                    record = json.loads(raw)
                except ValueError:
                    continue
                if (isinstance(record, dict) and isinstance(record.get("id"), str)
                        and isinstance(record.get("thread_name"), str)):
                    names[record["id"].lower()] = record["thread_name"]
            if positions is not None:
                positions[path] = [info.st_ino, offset]
    cache[path] = names
    return names


def scan_titles(path, session, entry):
    """Fold a Claude transcript's custom and AI titles, reading only what was appended
    since `entry` (this file's previous result, kept in the plugin state)."""
    handle = open_owned(path)
    if handle is None:
        return {"ino": None, "offset": 0, "custom": "", "ai": ""}
    with handle:
        info = os.fstat(handle.fileno())
        if (not isinstance(entry, dict) or entry.get("ino") != info.st_ino
                or not isinstance(entry.get("offset"), int) or entry["offset"] > info.st_size):
            entry = {"ino": info.st_ino, "offset": 0, "custom": "", "ai": ""}
        entry = dict(entry)
        handle.seek(entry["offset"])
        for raw in handle:
            if not raw.endswith(b"\n"):
                break  # still being written; read it next time
            entry["offset"] += len(raw)
            if b'"custom-title"' not in raw and b'"ai-title"' not in raw:
                continue
            try:
                record = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                continue
            if not isinstance(record, dict) or record.get("sessionId") != session:
                continue
            if record.get("type") == "custom-title" and isinstance(record.get("customTitle"), str):
                entry["custom"] = clean(record["customTitle"]) or entry["custom"]
            elif record.get("type") == "ai-title" and isinstance(record.get("aiTitle"), str):
                entry["ai"] = clean(record["aiTitle"]) or entry["ai"]
    return entry


def tail_record(path, *kinds):
    """The last record of one of the types `kinds` in the file's last TAIL_MAX_BYTES, or None.

    A long Codex turn writes megabytes after its turn_context, so the file is read
    backwards in TAIL_BYTES chunks, each byte once, carrying the partial first line."""
    handle = open_owned(path)
    if handle is None:
        return None
    markers = [('"%s"' % kind).encode() for kind in kinds]
    with handle:
        size = position = os.fstat(handle.fileno()).st_size
        carry = b""
        while position > 0 and size - position < TAIL_MAX_BYTES:
            step = min(TAIL_BYTES, position)
            position -= step
            handle.seek(position)
            lines = (handle.read(step) + carry).split(b"\n")
            carry = lines.pop(0) if position > 0 else b""
            for raw in reversed(lines):
                if not any(marker in raw for marker in markers):
                    continue
                try:
                    record = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    continue
                if isinstance(record, dict) and record.get("type") in kinds:
                    return record
    return None


def ends_on_choice(transcript):
    """Whether a Claude turn's last answer leaves a choice to the user: the harness
    recommendation mark outside code blocks. A turn stopped before any answer ends
    on the user's record, so an older answer does not count."""
    record = tail_record(transcript, "user", "assistant") or {}
    if record.get("type") != "assistant":
        return False
    message = record.get("message") if isinstance(record.get("message"), dict) else {}
    content = message.get("content") if isinstance(message.get("content"), list) else []
    text = "".join(block.get("text") or "" for block in content
                   if isinstance(block, dict) and block.get("type") == "text")
    return DECISION_MARK in "".join(text.split("```")[::2])


def model_text(model, effort):
    if not isinstance(model, str) or not clean(model):
        return ""
    text = MODEL_PREFIX.sub("", clean(model))
    if isinstance(effort, str) and clean(effort):
        text += " " + clean(effort)
    return text[:40]


def upward(pane, relative):
    """`relative` joined to the pane's directories and their parents, nearest first."""
    found = []
    for start in (pane.get("foreground_cwd"), pane.get("cwd")):
        directory = start if isinstance(start, str) and os.path.isabs(start) else None
        for _ in range(CODEX_HOME_DEPTH):
            if directory is None:
                break
            candidate = os.path.join(directory, relative)
            if candidate not in found:
                found.append(candidate)
            parent = os.path.dirname(directory)
            directory = parent if parent != directory else None
    return found


def session_of(pane, agent):
    session = pane.get("agent_session")
    value = session.get("value") if isinstance(session, dict) else None
    if pane.get("agent") != agent or not isinstance(value, str) or not THREAD_ID.match(value):
        return ""
    return value


class Titles:
    """Session titles and models of agent panes, read from the agents' own records.

    `state` is the plugin state: it keeps transcript read offsets and found paths
    between runs, so a run reads only what was appended since the last one.
    `watched` maps each file a title came from, or would come from, to the
    [inode, offset] read so far ([None, 0] for a file that does not exist yet).
    """

    def __init__(self, state):
        self.indexes = {}
        self.scans = state.setdefault("scans", {})
        self.paths = state.setdefault("paths", {})
        self.used = set()
        self.watched = {}

    def codex(self, pane):
        """(latest thread name, CODEX_HOME or None) of a Codex pane.

        Codex renames a thread from another app-server connection (a title hook),
        which the running TUI never sees, so its terminal title keeps the thread id
        or the name it resumed with. The first index on the way up from the pane's
        directory that knows the thread wins; ~/.codex is the last candidate.
        """
        thread = session_of(pane, "codex")
        if not thread:
            return "", None
        self.used.add("codex:" + thread)  # keep the rollout path found for $model
        home = None
        candidates = upward(pane, CODEX_INDEX) + [
            os.path.join(os.path.expanduser("~"), ".codex", "session_index.jsonl")]
        for index in candidates:
            positions = {}
            names = thread_names(index, self.indexes, positions)
            if os.path.isdir(os.path.dirname(index)):
                # A Codex home: where the thread's first name will appear.
                self.watched.setdefault(index, positions.get(index, [None, 0]))
                home = home or os.path.dirname(index)
            name = names.get(thread.lower())
            if name is not None:
                return clean(name), os.path.dirname(index)
        return "", home

    def found(self, key, finder):
        """A cached file path for `key`; a miss is retried after a while."""
        self.used.add(key)
        known = self.paths.get(key)
        if isinstance(known, dict):
            if known.get("path") and os.path.isfile(known["path"]):
                return known["path"]
            if not known.get("path") and time.time() - known.get("checked", 0) < MISSING_RETRY_SECONDS:
                return None
        path = finder()
        self.paths[key] = {"path": path, "checked": time.time()}
        return path

    def claude_transcript(self, pane):
        session = session_of(pane, "claude")
        if not session:
            return None

        def finder():
            homes = upward(pane, CLAUDE_HOME) + [os.path.join(os.path.expanduser("~"), ".claude")]
            for home in homes:
                matches = sorted(glob.glob(os.path.join(glob.escape(home), "projects", "*",
                                                        session + ".jsonl")))
                if matches:
                    return matches[0]
            return None
        return self.found("claude:" + session, finder)

    def codex_rollout(self, home, thread):
        def finder():
            matches = sorted(glob.glob(os.path.join(glob.escape(home), "sessions", "*", "*", "*",
                                                    "rollout-*-%s.jsonl" % thread)))
            return matches[-1] if matches else None
        return self.found("codex:" + thread, finder)

    def claude(self, pane):
        """(custom title, AI title) of a Claude pane's transcript."""
        path = self.claude_transcript(pane)
        if not path:
            return "", ""
        self.used.add(path)
        entry = scan_titles(path, session_of(pane, "claude"), self.scans.get(path))
        self.scans[path] = entry
        self.watched[path] = [entry["ino"], entry["offset"]]
        return entry["custom"], entry["ai"]

    def title(self, pane):
        terminal = (pane.get("terminal_title_stripped") or "").strip()
        agent = pane.get("agent")
        if agent == "codex":
            return self.codex(pane)[0] or terminal
        if agent == "claude":
            custom, ai = self.claude(pane)
            return custom or terminal or ai
        return terminal

    def model(self, pane):
        """`<model> <effort>` of the pane's latest turn, or ""."""
        if pane.get("agent") == "codex":
            home = self.codex(pane)[1]
            path = home and self.codex_rollout(home, session_of(pane, "codex"))
            record = tail_record(path, "turn_context") if path else None
            payload = record.get("payload") if record else None
            if isinstance(payload, dict):
                return model_text(payload.get("model"), payload.get("effort"))
        elif pane.get("agent") == "claude":
            path = self.claude_transcript(pane)
            record = tail_record(path, "assistant") if path else None
            message = record.get("message") if record else None
            if isinstance(message, dict):
                return model_text(message.get("model"), record.get("effort"))
        return ""

    def prune(self):
        for store in (self.scans, self.paths):
            for key in [key for key in store if key not in self.used]:
                del store[key]


def report_metadata(pane_id, agent, title, model, previous):
    """One metadata report per pane: title and state labels (guarded by the agent) and $model.

    herdr replaces a source's title and labels together, so every report carries both."""
    argv = ["pane", "report-metadata", pane_id, "--source", METADATA_SOURCE]
    if agent:
        argv += ["--agent", agent] + (["--title", title] if title else ["--clear-title"])
        for status, label in STATE_LABELS:
            argv += ["--state-label", "%s=%s" % (status, label)]
    else:
        argv += ["--clear-title", "--clear-state-labels"]
    if model != previous.get("model", ""):
        argv += ["--token", "model=" + model] if model else ["--clear-token", "model"]
    return herdr_ok(*argv)


def sync_metadata(panes, titles, meta, refresh_model):
    for pane in panes:
        pane_id = pane.get("pane_id")
        if not pane_id:
            continue
        agent = pane.get("agent") or ""
        previous = meta.get(pane_id) if isinstance(meta.get(pane_id), dict) else {}
        if not agent:
            if previous and report_metadata(pane_id, "", "", "", previous):
                del meta[pane_id]
            continue
        same_agent = previous.get("agent") == agent
        model = previous.get("model", "") if same_agent else ""
        if refresh_model == pane_id or not same_agent or "model" not in previous:
            model = titles.model(pane) or model
        wanted = {"agent": agent, "title": display_title(titles.title(pane)), "model": model}
        if all(previous.get(key) == value for key, value in wanted.items()):
            continue
        if report_metadata(pane_id, agent, wanted["title"], model, previous):
            meta[pane_id] = wanted


def sync_tabs(refresh_model=None, forget=None):
    """Sync tab labels and pane metadata; return (panes, {watched file: position}).

    `forget` drops the record of what was reported, for one pane id or "all", so
    the next report goes out even when unchanged: herdr loses pane metadata when
    its server restarts (pane ids repeat) and when an agent leaves a pane."""
    # Read herdr's lists under the lock so a concurrent run cannot act on an older snapshot.
    with locked_state() as state:
        records = session(state)
        for key, other in list(state["sessions"].items()):
            if not isinstance(other, dict) or time.time() - other.get("seen", 0) > SESSION_KEEP_SECONDS:
                del state["sessions"][key]  # a herdr session gone for a week
        meta = records["meta"]
        if forget == "all":
            meta.clear()
        elif forget:
            meta.pop(forget, None)
        tabs = herdr("tab", "list")["tabs"]
        panes = herdr("pane", "list")["panes"]
        panes_by_tab = {}
        for pane in panes:
            panes_by_tab.setdefault(pane.get("tab_id"), []).append(pane)
        owned = records["tabs"]
        live_tabs = {tab["tab_id"] for tab in tabs}
        for tab_id in [tab_id for tab_id in owned if tab_id not in live_tabs]:
            del owned[tab_id]
        live_panes = {pane.get("pane_id") for pane in panes}
        for kept in (records["panes"], meta):
            for pane_id in [pane_id for pane_id in kept if pane_id not in live_panes]:
                del kept[pane_id]
        titles = Titles(records)
        sync_metadata(panes, titles, meta, refresh_model)
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
            if tab.get("pane_count") == len(members):
                # The first agent with a usable title names the tab; the other agents
                # beside it are counted. Plain shells are not.
                agents = [member for member in members if member.get("agent")]
                for member in agents:
                    wanted = tab_label(titles.title(member), len(agents) - 1)
                    if wanted:
                        break
            if not wanted:
                # No agent title any more (agent exited, thread-id title, or the tab was
                # caught mid-change): hand the tab back its position label. herdr cannot
                # clear a tab name, so the plugin keeps owning that label.
                wanted = position
            if wanted != current:
                # Record first: if the rename fails the old label is still the plugin's
                # or the position, so the next run retries.
                owned[tab_id] = wanted
                try:
                    herdr("tab", "rename", tab_id, wanted)
                except Exception as error:  # noqa: BLE001 - one tab must not stop the rest
                    log("rename %s: %s" % (tab_id, error))
        titles.prune()
        return panes, titles.watched


def own_rename(payload):
    """Whether a tab.renamed event reports the label this plugin set last."""
    data = payload.get("data") or {}
    tab_id, label = data.get("tab_id"), data.get("label")
    if not tab_id or label is None:
        return False
    with locked_state() as state:
        return session(state)["tabs"].get(tab_id) == label


def record_status(payload):
    data = payload.get("data") or {}
    pane_id = data.get("pane_id") or os.environ.get("HERDR_PANE_ID")
    status = data.get("agent_status")
    if not pane_id or not status:
        return None
    with locked_state() as state:
        statuses = session(state)["panes"]
        entry = statuses.get(pane_id) or {}
        previous = entry.get("status")
        seq = int(entry.get("seq", 0)) + (not same_status(previous, status))
        entry.update(status=status, seq=seq)
        statuses[pane_id] = entry
    if status == "blocked" and previous != "blocked":
        kind = "attention"
    elif status in FINISHED and previous == "working":
        kind = "finished"
    else:
        return None
    return {"kind": kind, "pane_id": pane_id, "seq": seq, "agent": data.get("agent") or "agent"}


def settle_decision(payload, pending):
    """Show `$decision` while a Claude turn that ended on a choice waits for the answer.

    A finished turn sets or clears it from its last answer; any status but idle or done (the
    user answered, or the agent asks for input) clears it; another idle keeps it."""
    data = payload.get("data") or {}
    pane_id = data.get("pane_id") or os.environ.get("HERDR_PANE_ID")
    status = data.get("agent_status")
    finished = bool(pending) and pending["kind"] == "finished"
    if not pane_id or not status or (status in FINISHED and not finished):
        return
    wanted = False
    if finished and pending["agent"] == "claude":
        pane = next((item for item in herdr("pane", "list")["panes"]
                     if item.get("pane_id") == pane_id), None)
        # A stale idle event read while the agent works again sets nothing.
        live = pane and pane.get("agent_status") in FINISHED
        transcript = live and Titles({}).claude_transcript(pane)
        wanted = bool(transcript) and ends_on_choice(transcript)
    with locked_state() as state:
        entry = session(state)["panes"].get(pane_id)
        # Events run in separate processes: a newer status settles it instead.
        if not entry or not same_status(entry.get("status"), status) or (finished and entry.get("seq") != pending["seq"]):
            return
        if bool(entry.get("decision")) != wanted:
            argv = ["pane", "report-metadata", pane_id, "--source", METADATA_SOURCE]
            # herdr drops a report guarded by an agent that has exited, so a set never
            # lands on the shell left behind; a clear has no guard and always lands.
            argv += (["--agent", "claude", "--token", "decision=" + DECISION_LABEL] if wanted
                     else ["--clear-token", "decision"])
            if herdr_ok(*argv):
                entry["decision"] = wanted
    if wanted:
        pending["decision"] = True


def still_current(pending):
    with locked_state() as state:
        return (session(state)["panes"].get(pending["pane_id"]) or {}).get("seq") == pending["seq"]


def activity_of(pane):
    tokens = pane.get("tokens") or {}
    return tokens.get("herdr_activity"), tokens.get("herdr_activity_id")


def reconcile_activity(panes):
    """Only a fresh explicit settle can release an observed background completion."""
    ready = []
    with locked_state() as state:
        records = session(state)["panes"]
        for pane in panes:
            pane_id = pane.get("pane_id")
            entry = records.setdefault(pane_id, {})
            phase, identity = activity_of(pane)
            owner = (pane.get("agent"), session_of(pane, pane.get("agent") or ""), pane.get("terminal_id"))
            if entry.get("activity_owner") != list(owner):
                entry.pop("deferred", None)
                entry.pop("activity_id", None)
                entry.pop("activity_phase", None)
                entry["activity_owner"] = list(owner)
            if pane.get("agent_status") in ("working", "blocked"):
                entry.pop("deferred", None)
            pending = entry.get("deferred")
            if phase in ("waiting", "stalled") and identity:
                if entry.get("activity_id") not in (None, identity):
                    entry.pop("deferred", None)
                entry.update(activity_id=identity, activity_phase=phase)
            elif phase == "settled" and identity:
                if pending and entry.get("activity_id") == identity and entry.get("seq") == pending.get("seq"):
                    ready.append(pending)
                entry.pop("deferred", None)
                entry.update(activity_id=identity, activity_phase="settled")
            elif entry.get("activity_phase") in ("waiting", "stalled", "unknown"):
                entry["activity_phase"] = "unknown"
    return ready


def defer_finished(pending, pane):
    if pending["kind"] != "finished":
        return False
    phase, identity = activity_of(pane)
    with locked_state() as state:
        entry = session(state)["panes"].get(pending["pane_id"]) or {}
        if entry.get("seq") != pending.get("seq"):
            return True
        # A decision requests input; it does not claim the background work ended.
        if pending.get("decision"):
            return False
        if phase in ("waiting", "stalled") and identity:
            entry.update(activity_phase=phase, activity_id=identity)
        unresolved = entry.get("activity_phase") in ("waiting", "stalled", "unknown")
        if unresolved and not (phase == "settled" and identity == entry.get("activity_id")):
            entry["deferred"] = pending
            session(state)["panes"][pending["pane_id"]] = entry
            return True
    return False


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
    valid = FINISHED if pending["kind"] == "finished" else (EXPECTED_LIVE_STATUS[pending["kind"]],)
    if pane is None or pane.get("agent_status") not in valid:
        return
    if defer_finished(pending, pane):
        return
    workspace = next((item for item in herdr("workspace", "list")["workspaces"]
                      if item.get("workspace_id") == pane.get("workspace_id")), {})
    hosts = host_bundle_ids()
    front = front_bundle_id()
    visible = workspace.get("focused") and workspace.get("active_tab_id") == pane.get("tab_id")
    if visible and (not hosts or front in hosts):
        return
    host = front if front in hosts else (hosts[0] if hosts else None)
    if pending.get("decision"):
        template = "🔘 %s " + DECISION_LABEL
    else:
        template = "✅ %s 응답 종료" if pending["kind"] == "finished" else "⏳ %s 입력 필요"
    title = template % pending["agent"]
    subtitle = workspace.get("label") or pane.get("workspace_id") or ""
    # The title the last sync reported, which the run that queued this notification made.
    with locked_state() as state:
        reported = session(state)["meta"].get(pane_id) or {}
    message = ((pane.get("label") or "").strip() or (pane.get("title") or "").strip()
               or reported.get("title") or display_title(pane.get("terminal_title_stripped") or "")
               or pane_id)
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


def env_seconds(name, default):
    try:
        value = float(os.environ.get(name, ""))
    except ValueError:
        return default
    return value if value > 0 else default


def script_signature():
    try:
        info = os.stat(os.path.realpath(__file__))
    except OSError:
        return None
    return info.st_ino, info.st_size, info.st_mtime_ns


def pane_key(pane):
    """What a pane.updated event must change before the watcher syncs again; a shell's
    own title changes (each command) do not count."""
    agent = pane.get("agent") or ""
    return agent, display_title(pane.get("terminal_title_stripped") or "") if agent else "", activity_of(pane), pane.get("agent_status")


def watch_paths():
    """(lock, log) of this herdr session's watcher."""
    directory = state_dir()
    return (os.path.join(directory, "watch-%s.lock" % session_key()),
            os.path.join(directory, "watch-%s.log" % session_key()))


def trim_log(path):
    try:
        if os.path.getsize(path) > WATCH_LOG_MAX_BYTES:
            os.truncate(path, 0)
    except OSError:
        pass


def plugin_enabled():
    """False once herdr lists this plugin as disabled or no longer lists it; None when the
    list cannot be read or does not look like herdr 0.9.1's (`result.plugins[]` entries
    with `plugin_id` and `enabled`), so an unexpected format never stops the watcher."""
    try:
        plugins = herdr("plugin", "list", "--json").get("plugins")
    except Exception:  # noqa: BLE001 - herdr down is the sync's to notice
        return None
    if not isinstance(plugins, list):
        return None
    entries = [item for item in plugins if isinstance(item, dict) and "plugin_id" in item]
    if len(entries) != len(plugins):
        return None
    plugin_id = os.environ.get("HERDR_PLUGIN_ID") or PLUGIN_ID
    entry = next((item for item in entries if item["plugin_id"] == plugin_id), None)
    if entry is None:
        return False
    return entry.get("enabled") is not False


def appended_title(path, position):
    """(whether lines appended after `position` hold a title record, new position).

    `position` is [inode, offset]; a replaced or truncated file counts as changed."""
    handle = open_owned(path)
    if handle is None:
        return False, position
    with handle:
        info = os.fstat(handle.fileno())
        inode, offset = position
        if inode != info.st_ino or offset > info.st_size:
            return True, [info.st_ino, info.st_size]
        if info.st_size == offset:
            return False, position
        handle.seek(offset)
        chunk = handle.read(info.st_size - offset)
    end = chunk.rfind(b"\n")
    if end < 0:
        return False, position
    chunk = chunk[:end + 1]
    return any(marker in chunk for marker in TITLE_MARKERS), [inode, offset + len(chunk)]


class Watcher:
    """The background `watch` loop; see the module docstring."""

    def __init__(self, log_path):
        self.poll = env_seconds("HARNESS_HERDR_WATCH_POLL_SECONDS", WATCH_POLL_SECONDS)
        self.refresh_every = env_seconds("HARNESS_HERDR_WATCH_REFRESH_SECONDS", WATCH_REFRESH_SECONDS)
        self.reconnect_every = env_seconds("HARNESS_HERDR_WATCH_RECONNECT_SECONDS", WATCH_RECONNECT_SECONDS)
        self.log_path = log_path
        self.signature = script_signature()
        self.files = {}      # path -> [inode, offset]
        self.keys = {}       # pane id -> pane_key()
        self.sock = None
        self.buffer = b""
        self.next_connect = 0.0
        self.next_refresh = 0.0
        self.failures = 0
        self.dirty = False
        self.forget = None   # "all" after herdr's socket closed: a restart drops metadata

    def run(self):
        while True:
            if script_signature() != self.signature:
                log("watch: plugin changed; exiting")
                return
            now = time.monotonic()
            if now >= self.next_refresh:
                if plugin_enabled() is False:
                    log("watch: plugin disabled or removed; exiting")
                    return
                trim_log(self.log_path)
            if self.dirty or now >= self.next_refresh:
                self.dirty = False
                self.next_refresh = now + self.refresh_every
                if self.sync():
                    self.failures = 0
                else:
                    self.failures += 1
                    if self.failures >= WATCH_MAX_FAILURES:
                        log("watch: herdr does not answer; exiting")
                        return
            if self.sock is None and now >= self.next_connect:
                self.connect()
            self.wait(self.poll)
            self.scan()

    def sync(self):
        try:
            panes, watched = sync_tabs(forget=self.forget)
        except Exception as error:  # noqa: BLE001 - the loop keeps going
            log("watch sync: %s" % error)
            return False
        self.forget = None
        # Start where the sync stopped reading, so nothing written in between is missed.
        self.files = {path: self.files.get(path) or position for path, position in watched.items()}
        self.keys = {pane.get("pane_id"): pane_key(pane) for pane in panes}
        for pending in reconcile_activity(panes):
            if still_current(pending):
                announce(pending)
        return True

    def scan(self):
        for path, position in list(self.files.items()):
            changed, self.files[path] = appended_title(path, position)
            self.dirty = self.dirty or changed

    def connect(self):
        self.next_connect = time.monotonic() + self.reconnect_every
        path = os.environ.get("HERDR_SOCKET_PATH")
        if not path:
            return
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.settimeout(2)
            sock.connect(path)
            sock.sendall(json.dumps({"id": "harness-launcher-watch", "method": "events.subscribe",
                                     "params": {"subscriptions": [{"type": "pane.updated"}]}}
                                    ).encode() + b"\n")
            sock.setblocking(False)
        except OSError:
            sock.close()
            return
        self.sock, self.buffer = sock, b""
        self.dirty = True  # changes before the subscription started

    def disconnect(self):
        if self.sock is not None:
            self.sock.close()
        self.sock, self.buffer = None, b""

    def wait(self, timeout):
        if self.sock is None:
            time.sleep(timeout)
            return
        try:
            ready = select.select([self.sock], [], [], timeout)[0]
            chunk = self.sock.recv(65536) if ready else None
        except BlockingIOError:
            return
        except (OSError, ValueError):
            chunk = b""
        if chunk is None:
            return
        if not chunk:
            # herdr closed the stream: a server restart drops every pane's metadata.
            self.disconnect()
            self.forget = "all"
            self.dirty = True
            return
        self.buffer += chunk
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            self.handle(line)

    def handle(self, line):
        try:
            message = json.loads(line)
        except ValueError:
            return
        if not isinstance(message, dict):
            return
        if "error" in message:  # such as events_lost: resubscribe and resync
            self.disconnect()
            self.dirty = True
            return
        data = message.get("data")
        pane = data.get("pane") if isinstance(data, dict) else None
        if isinstance(pane, dict) and self.keys.get(pane.get("pane_id")) != pane_key(pane):
            self.keys[pane.get("pane_id")] = pane_key(pane)
            self.dirty = True


def watch():
    lock_path, log_path = watch_paths()
    with open(lock_path, "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0  # another watcher runs
        Watcher(log_path).run()
    return 0


def ensure_watcher():
    """Start this herdr session's watcher unless one runs; a second one started in a race
    exits at once."""
    if os.environ.get("HARNESS_HERDR_WATCH", "1") == "0":
        return
    lock_path, log_path = watch_paths()
    with open(lock_path, "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return
    trim_log(log_path)
    with open(log_path, "a") as output:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "watch"],
                         cwd=os.path.dirname(os.path.abspath(__file__)), stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=output, close_fds=True,
                         start_new_session=True)


def main():
    if sys.argv[1:2] == ["install"]:
        return install(sys.argv[2:])
    if sys.argv[1:2] == ["watch"]:
        return watch()
    event = os.environ.get("HERDR_PLUGIN_EVENT")
    try:
        payload = json.loads(os.environ.get("HERDR_PLUGIN_EVENT_JSON") or "{}")
    except ValueError:
        payload = {}
    payload = payload if isinstance(payload, dict) else {}
    pending = None
    if event == "pane.agent_status_changed":
        try:
            pending = record_status(payload)
        except Exception as error:  # noqa: BLE001 - a hook must never fail
            log("status: %s" % error)
    try:
        if not (event == "tab.renamed" and own_rename(payload)):
            data = payload.get("data") if isinstance(payload.get("data"), dict) else {}
            pane_id = data.get("pane_id")
            # A new server has no pane metadata; a newly detected agent has none either.
            forget = "all" if event == "startup" else pane_id if event == "pane.agent_detected" else None
            if event == "startup":
                with locked_state() as state:
                    session(state)["panes"].clear()
            panes, _ = sync_tabs(refresh_model=pane_id if event == "pane.agent_status_changed" else None,
                                 forget=forget)
            for deferred in reconcile_activity(panes):
                if still_current(deferred):
                    announce(deferred)
    except Exception as error:  # noqa: BLE001
        log("tabs: %s" % error)
    if event == "pane.agent_status_changed":
        try:
            settle_decision(payload, pending)
        except Exception as error:  # noqa: BLE001
            log("decision: %s" % error)
    try:
        ensure_watcher()
    except Exception as error:  # noqa: BLE001
        log("watch: %s" % error)
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
