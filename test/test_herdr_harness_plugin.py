"""herdr harness plugin: tab labels from agent session titles and rich notifications.

The plugin runs the way herdr runs it: /usr/bin/python3 with a minimal PATH,
HERDR_PLUGIN_EVENT(_JSON), HERDR_BIN_PATH and HERDR_PLUGIN_STATE_DIR. herdr,
terminal-notifier, osascript, lsappinfo and ps are stubs on PATH.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11
    tomllib = None


BIN_DIR = Path(__file__).resolve().parents[1] / "bin"
PLUGIN_DIR = Path(__file__).resolve().parents[1] / "herdr-plugin"
SCRIPT = PLUGIN_DIR / "harness_herdr_plugin.py"
MANIFEST = PLUGIN_DIR / "herdr-plugin.toml"
TARGET_PYTHON = "/usr/bin/python3"

# herdr 0.9.1 src/api/schema/events.rs PLUGIN_HOOK_EVENT_KINDS (pane/tab subset)
HOOKABLE = {
    "tab.created", "tab.closed", "tab.renamed", "tab.moved", "tab.focused",
    "pane.created", "pane.closed", "pane.focused", "pane.moved", "pane.exited",
    "pane.agent_detected", "pane.agent_status_changed",
}

FAKE_HERDR = r'''#!/usr/bin/env python3
import json, os, sys
state_path = os.environ["FAKE_HERDR_STATE"]
with open(os.environ["FAKE_HERDR_CALLS"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
with open(os.environ["FAKE_HERDR_CALLS"] + ".socket", "a") as log:
    log.write(os.environ.get("HERDR_SOCKET_PATH", "") + "\n")
state = json.load(open(state_path))
args = sys.argv[1:]
def out(result):
    print(json.dumps({"id": "cli", "result": result}))
if args[:2] == ["plugin", "config-dir"]:
    print(os.environ.get("FAKE_CONFIG_DIR", ""))
elif args[:2] == ["workspace", "list"]:
    out({"workspaces": state["workspaces"], "type": "workspace_list"})
elif args[:2] == ["tab", "list"]:
    out({"tabs": state["tabs"], "type": "tab_list"})
elif args[:2] == ["pane", "list"]:
    out({"panes": state["panes"], "type": "pane_list"})
elif args[:2] == ["tab", "rename"]:
    if args[2] == os.environ.get("FAKE_RENAME_FAIL"):
        sys.exit(1)
    for tab in state["tabs"]:
        if tab["tab_id"] == args[2]:
            tab["label"] = args[3]
    json.dump(state, open(state_path, "w"))
    out({"type": "tab_renamed"})
else:
    out({"type": "ok"})
'''

LOG_ARGV = '''#!/bin/sh
/usr/bin/python3 -c 'import json,sys; open(sys.argv[1],"a").write(json.dumps(sys.argv[2:])+"\\n")' "{log}" "$@"
'''

FAKE_LSAPPINFO = '''#!/bin/sh
case "$1" in
  front) echo "ASN:0x0-0x1:" ;;
  info) printf '"CFBundleIdentifier"="%s"\\n' "$FAKE_FRONT_BUNDLE" ;;
esac
'''

FAKE_PS = '''#!/bin/sh
cat "$FAKE_PS_TABLE"
'''

FIRST_TITLE = "herdr 사용법 + 하네스·런처 herdr 대응 검토"
LONG_TITLE = "TASK-2545 relay 2단계 — agent 상태 보고·증명 배달·집행 구현"
CODEX_TITLE = "TASK-2578 런타임 CI/CD 구축 | acme-platform-harness"


def workspace(ws_id, label, focused=False, active_tab=None):
    return {"workspace_id": ws_id, "label": label, "number": 1, "focused": focused,
            "active_tab_id": active_tab or f"{ws_id}:t1", "tab_count": 1, "pane_count": 1}


def tab(tab_id, number, label=None, pane_count=1):
    return {"tab_id": tab_id, "workspace_id": tab_id.split(":")[0], "number": number,
            "label": str(number) if label is None else label, "pane_count": pane_count,
            "focused": False, "agent_status": "idle"}


def pane(pane_id, tab_id, agent="claude", title=FIRST_TITLE, status="idle"):
    return {"pane_id": pane_id, "tab_id": tab_id, "workspace_id": tab_id.split(":")[0],
            "agent": agent, "agent_status": status, "terminal_title_stripped": title,
            "focused": False}


class PluginHarness:
    def __init__(self, root: Path):
        self.root = root
        self.stubs = root / "stubs"
        self.stubs.mkdir()
        self.state_dir = root / "plugin-state"
        self.state_dir.mkdir()
        self.herdr_state = root / "herdr-state.json"
        self.herdr_calls = root / "herdr-calls.jsonl"
        self.notify_log = root / "notify.jsonl"
        self.osascript_log = root / "osascript.jsonl"
        self.ps_table = root / "ps.txt"
        herdr = root / "herdr"
        herdr.write_text(FAKE_HERDR, encoding="utf-8")
        herdr.chmod(0o755)
        self.herdr_bin = herdr
        self._stub("terminal-notifier", LOG_ARGV.format(log=self.notify_log))
        self._stub("osascript", LOG_ARGV.format(log=self.osascript_log))
        self._stub("lsappinfo", FAKE_LSAPPINFO)
        self._stub("ps", FAKE_PS)
        app = root / "Host.app" / "Contents"
        (app / "MacOS").mkdir(parents=True)
        with open(app / "Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "com.example.host"}, handle)
        self.ps_table.write_text(
            "  100     1 /opt/homebrew/opt/herdr/bin/herdr\n"
            "  140     1 %s/Host.app/Contents/MacOS/host\n"
            "  150   140 zsh (kiro-cli-term)\n"
            "  160   150 /bin/zsh\n"
            "  200   160 herdr\n" % root,
            encoding="utf-8",
        )
        self.front_bundle = "com.example.other"
        self.rename_fail = ""

    def _stub(self, name, body):
        path = self.stubs / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def set_state(self, workspaces, tabs, panes):
        self.herdr_state.write_text(json.dumps(
            {"workspaces": workspaces, "tabs": tabs, "panes": panes}), encoding="utf-8")

    def state(self):
        return json.loads(self.herdr_state.read_text(encoding="utf-8"))

    def env(self, event, payload=None, pane_id=None, delay="0"):
        env = {
            "PATH": f"{self.stubs}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.root),
            "HERDR_ENV": "1",
            "HERDR_PLUGIN_EVENT": event,
            "HERDR_BIN_PATH": str(self.herdr_bin),
            "HERDR_PLUGIN_STATE_DIR": str(self.state_dir),
            "FAKE_HERDR_STATE": str(self.herdr_state),
            "FAKE_HERDR_CALLS": str(self.herdr_calls),
            "FAKE_FRONT_BUNDLE": self.front_bundle,
            "FAKE_PS_TABLE": str(self.ps_table),
            "HARNESS_HERDR_NOTIFY_DELAY_SECONDS": delay,
            "HERDR_SOCKET_PATH": str(self.root / "herdr test.sock"),
            "FAKE_RENAME_FAIL": self.rename_fail,
            "HARNESS_HERDR_WATCH": "0",
        }
        if payload is not None:
            env["HERDR_PLUGIN_EVENT_JSON"] = json.dumps(payload)
        if pane_id:
            env["HERDR_PANE_ID"] = pane_id
        return env

    def run(self, event, payload=None, pane_id=None, delay="0"):
        return subprocess.run(
            [TARGET_PYTHON, str(SCRIPT)], cwd=PLUGIN_DIR,
            env=self.env(event, payload, pane_id, delay),
            capture_output=True, text=True, timeout=30,
        )

    def status(self, pane_id, status, agent="claude", delay="0", live=None):
        state = self.state()
        for item in state["panes"]:
            if item["pane_id"] == pane_id:
                item["agent_status"] = live or status
        self.set_state(state["workspaces"], state["tabs"], state["panes"])
        payload = {"event": "pane_agent_status_changed",
                   "data": {"type": "pane_agent_status_changed", "pane_id": pane_id,
                            "workspace_id": pane_id.split(":")[0],
                            "agent_status": status, "agent": agent}}
        return self.run("pane.agent_status_changed", payload, pane_id, delay)

    def calls(self):
        if not self.herdr_calls.exists():
            return []
        return [json.loads(line) for line in self.herdr_calls.read_text().splitlines()]

    def renames(self):
        return [call[2:] for call in self.calls() if call[:2] == ["tab", "rename"]]

    def reports(self):
        return [call[2:] for call in self.calls() if call[:2] == ["pane", "report-metadata"]]

    def notifications(self, log=None):
        path = log or self.notify_log
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]


def flag(argv, name):
    return argv[argv.index(name) + 1] if name in argv else None


class HerdrPluginTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.h = PluginHarness(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def assertRan(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)


class InstallTest(HerdrPluginTestCase):
    """herdr stores a linked manifest by its resolved path, so a manifest inside the
    Homebrew Cellar would vanish on upgrade. install writes one outside it."""

    def install(self, script, target):
        if not self.h.herdr_state.exists():
            self.h.set_state([], [], [])
        env = self.h.env("install")
        return subprocess.run([TARGET_PYTHON, str(SCRIPT), "install", "--dir", str(target),
                               "--script", script], env=env, capture_output=True, text=True,
                              timeout=60)

    def calls(self):
        return [json.loads(line) for line in self.h.herdr_calls.read_text().splitlines()]

    def test_install_links_a_stable_manifest_that_runs_the_given_script(self):
        target = self.h.root / "stable"
        result = self.install("/opt/homebrew/opt/harness-launcher/share/x/harness_herdr_plugin.py",
                              target)
        self.assertRan(result)
        text = (target / "herdr-plugin.toml").read_text(encoding="utf-8")
        self.assertNotIn('"harness_herdr_plugin.py"', text)
        self.assertIn('["/usr/bin/python3", '
                      '"/opt/homebrew/opt/harness-launcher/share/x/harness_herdr_plugin.py"]', text)
        self.assertEqual(text.count("harness_herdr_plugin.py"), MANIFEST.read_text().count(
            "harness_herdr_plugin.py"))
        self.assertEqual(self.calls()[-2:], [["plugin", "unlink", "harness.launcher"],
                                             ["plugin", "link", str(target)]])

    def test_install_maps_a_versioned_cellar_script_to_the_opt_path(self):
        target = self.h.root / "stable"
        result = self.install(
            "/opt/homebrew/Cellar/harness-launcher/0.37.0/share/harness-launcher/"
            "herdr-plugin/harness_herdr_plugin.py", target)
        self.assertRan(result)
        text = (target / "herdr-plugin.toml").read_text(encoding="utf-8")
        self.assertIn('"/opt/homebrew/opt/harness-launcher/share/harness-launcher/'
                      'herdr-plugin/harness_herdr_plugin.py"', text)
        self.assertNotIn("/Cellar/", text)

    @unittest.skipIf(tomllib is None, "tomllib requires Python 3.11+")
    def test_installed_manifest_keeps_the_packaged_hooks(self):
        target = self.h.root / "stable"
        self.assertRan(self.install("/opt/x/harness_herdr_plugin.py", target))
        installed = tomllib.loads((target / "herdr-plugin.toml").read_text(encoding="utf-8"))
        packaged = tomllib.loads(MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(installed["id"], packaged["id"])
        self.assertEqual([hook["on"] for hook in installed["events"]],
                         [hook["on"] for hook in packaged["events"]])

    def test_install_reports_a_failed_link(self):
        self.h.herdr_state.write_text("not json", encoding="utf-8")
        result = self.install("/opt/x/harness_herdr_plugin.py", self.h.root / "stable")
        self.assertNotEqual(result.returncode, 0)


class ManifestTest(unittest.TestCase):
    @unittest.skipIf(tomllib is None, "tomllib requires Python 3.11+")
    def test_manifest_runs_system_python_on_hookable_events(self):
        manifest = tomllib.loads(MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(manifest["id"], "harness.launcher")
        self.assertIn("macos", manifest["platforms"])
        hooks = [hook["on"] for hook in manifest["events"]]
        self.assertIn("pane.agent_status_changed", hooks)
        self.assertIn("tab.renamed", hooks)  # renaming a tab back to its position
        self.assertTrue(set(hooks) <= HOOKABLE, set(hooks) - HOOKABLE)
        commands = [hook["command"] for hook in manifest["events"]] + [
            entry["command"] for entry in manifest["startup"]]
        for command in commands:
            self.assertEqual(command, [TARGET_PYTHON, "harness_herdr_plugin.py"])

    def test_script_compiles_under_system_python(self):
        result = subprocess.run([TARGET_PYTHON, "-m", "py_compile", str(SCRIPT)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


class TabLabelTest(HerdrPluginTestCase):
    def test_single_agent_tab_with_default_number_takes_the_session_title(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [pane("w2:p1", "w2:t1", title="mkt 스킬")])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [["w2:t1", "mkt 스킬"]])

    def test_default_label_is_the_tab_position_not_its_number(self):
        # herdr 0.9.1 keeps numbering after a tab closes (t1, t5) but labels unnamed
        # tabs by position ("1", "2").
        self.h.set_state([workspace("w5", "beta")],
                         [tab("w5:t1", 1), dict(tab("w5:t5", 5), label="2")],
                         [pane("w5:p1", "w5:t1", title="one"),
                          pane("w5:p5", "w5:t5", title="five")])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [["w5:t1", "one"], ["w5:t5", "five"]])

    def test_long_title_is_cut_to_twenty_display_cells(self):
        self.h.set_state([workspace("w5", "beta")], [tab("w5:t4", 4, label="1")],
                         [pane("w5:p4", "w5:t4", title=LONG_TITLE)])
        self.assertRan(self.h.run("pane.focused"))
        self.assertEqual(self.h.renames(), [["w5:t4", "TASK-2545 relay 2단…"]])

    def test_codex_harness_suffix_is_dropped(self):
        self.h.set_state([workspace("w5", "beta")], [tab("w5:t7", 7, label="1")],
                         [pane("w5:p7", "w5:t7", agent="codex", title=CODEX_TITLE)])
        self.assertRan(self.h.run("tab.created"))
        self.assertEqual(self.h.renames(), [["w5:t7", "TASK-2578 런타임 CI…"]])

    def test_codex_thread_id_title_is_not_a_label(self):
        # Codex titles a session without a task by its thread id.
        self.h.set_state([workspace("w5", "beta")], [tab("w5:t9", 9, label="1")],
                         [pane("w5:p9", "w5:t9", agent="codex",
                               title="01a0ed4e-e2cc-7213-91d9-6fe5bf1017e0 | acme-platform-harness")])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [])

    # Codex renames a thread from another app-server connection, which the running
    # TUI never sees: its terminal title keeps the thread id or the name it resumed
    # with. The thread's latest name is in <CODEX_HOME>/session_index.jsonl.
    THREAD = "0199aaaa-1111-7222-8333-444455556666"

    def codex_home(self, root, records):
        index = root / ".harness" / "codex" / "session_index.jsonl"
        index.parent.mkdir(parents=True, exist_ok=True)
        index.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records),
                         encoding="utf-8")
        return index

    def codex_pane(self, pane_id, tab_id, cwd, title=None, thread=None):
        item = pane(pane_id, tab_id, agent="codex",
                    title=title or "%s | acme-platform-harness" % (thread or self.THREAD))
        item["cwd"] = str(cwd)
        item["agent_session"] = {"agent": "codex", "kind": "id", "source": "hook",
                                 "value": thread or self.THREAD}
        return item

    def test_codex_tab_takes_the_latest_thread_name_from_the_session_index(self):
        harness = self.h.root / "acme-platform-harness"
        self.codex_home(harness, [
            {"id": self.THREAD, "thread_name": "작업 목표 확인 중", "updated_at": "1"},
            {"id": "0199bbbb-1111-7222-8333-444455556666", "thread_name": "other", "updated_at": "2"},
            {"id": self.THREAD, "thread_name": "릴리스 노트 검토", "updated_at": "3"},
            "not a record", {"id": self.THREAD}])
        (harness / "sub" / "dir").mkdir(parents=True)
        self.h.set_state([workspace("w5", "beta")], [tab("w5:tE", 14, label="1")],
                         [self.codex_pane("w5:pE", "w5:tE", harness / "sub" / "dir")])
        self.assertRan(self.h.run("pane.agent_status_changed"))
        self.assertEqual(self.h.renames(), [["w5:tE", "릴리스 노트 검토"]])

    def test_codex_thread_name_replaces_a_stale_resumed_title(self):
        harness = self.h.root / "acme-platform-harness"
        self.codex_home(harness, [{"id": self.THREAD, "thread_name": "TASK-2619 인계"}])
        self.h.set_state([workspace("w5", "beta")], [tab("w5:t7", 7, label="1")],
                         [self.codex_pane("w5:p7", "w5:t7", harness,
                                          title="sandbox 확인 | acme-platform-harness")])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [["w5:t7", "TASK-2619 인계"]])

    def test_codex_without_an_indexed_name_keeps_the_terminal_title_rules(self):
        harness = self.h.root / "acme-platform-harness"
        self.codex_home(harness, [{"id": "0199bbbb-1111-7222-8333-444455556666", "thread_name": "x"},
                                  {"id": self.THREAD, "thread_name": ""}])
        self.h.set_state([workspace("w5", "beta")],
                         [tab("w5:t1", 1), tab("w5:t2", 2)],
                         [self.codex_pane("w5:p1", "w5:t1", harness),
                          self.codex_pane("w5:p2", "w5:t2", self.h.root / "elsewhere",
                                          title=CODEX_TITLE)])
        self.assertRan(self.h.run("startup"))
        # an empty latest name and a thread-id title name nothing; no index falls back
        self.assertEqual(self.h.renames(), [["w5:t2", "TASK-2578 런타임 CI…"]])

    def test_codex_default_home_is_the_last_candidate(self):
        self.codex_home(self.h.root, [])  # creates ~/.harness/codex, not ~/.codex
        index = self.h.root / ".codex" / "session_index.jsonl"
        index.parent.mkdir()
        index.write_text(json.dumps({"id": self.THREAD, "thread_name": "plain codex"}) + "\n",
                         encoding="utf-8")
        self.h.set_state([workspace("w5", "beta")], [tab("w5:t1", 1)],
                         [self.codex_pane("w5:p1", "w5:t1", self.h.root / "project")])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [["w5:t1", "plain codex"]])

    def test_codex_index_that_is_a_symlink_or_names_control_characters_is_handled(self):
        harness = self.h.root / "acme-platform-harness"
        real = self.codex_home(self.h.root / "real", [{"id": self.THREAD, "thread_name": "linked"}])
        (harness / ".harness" / "codex").mkdir(parents=True)
        (harness / ".harness" / "codex" / "session_index.jsonl").symlink_to(real)
        self.h.set_state([workspace("w5", "beta")], [tab("w5:t1", 1)],
                         [self.codex_pane("w5:p1", "w5:t1", harness, title="terminal | x-harness")])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [["w5:t1", "terminal"]])
        (harness / ".harness" / "codex" / "session_index.jsonl").unlink()
        self.codex_home(harness, [{"id": self.THREAD, "thread_name": "a\x1b]0;evil\x07b\nc"}])
        self.assertRan(self.h.run("pane.focused"))
        self.assertEqual(self.h.renames()[-1], ["w5:t1", "a]0;evilbc"])

    def test_plugin_label_returns_to_the_position_when_the_agent_leaves(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [pane("w2:p1", "w2:t1", title="task")])
        self.assertRan(self.h.run("startup"))
        state = self.h.state()
        state["panes"][0]["agent"] = None
        self.h.set_state(state["workspaces"], state["tabs"], state["panes"])
        self.assertRan(self.h.run("pane.focused"))
        self.assertRan(self.h.run("pane.focused"))
        self.assertEqual(self.h.renames(), [["w2:t1", "task"], ["w2:t1", "1"]])

    def test_split_of_a_plugin_labeled_tab_returns_it_to_the_position(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [pane("w2:p1", "w2:t1", title="task")])
        self.assertRan(self.h.run("startup"))
        state = self.h.state()
        state["tabs"][0]["pane_count"] = 2
        state["panes"].append(pane("w2:p2", "w2:t1", title="other"))
        self.h.set_state(state["workspaces"], state["tabs"], state["panes"])
        self.assertRan(self.h.run("pane.created"))
        self.assertEqual(self.h.renames(), [["w2:t1", "task"], ["w2:t1", "1"]])

    def test_user_named_tab_is_left_alone(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1, label="logs")],
                         [pane("w2:p1", "w2:t1")])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [])

    def test_label_set_by_plugin_follows_a_new_title(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [pane("w2:p1", "w2:t1", title="first task")])
        self.assertRan(self.h.run("startup"))
        state = self.h.state()
        state["panes"][0]["terminal_title_stripped"] = "second task"
        self.h.set_state(state["workspaces"], state["tabs"], state["panes"])
        self.assertRan(self.h.run("pane.focused"))
        self.assertEqual(self.h.renames(), [["w2:t1", "first task"], ["w2:t1", "second task"]])

    def test_unchanged_label_is_not_renamed_again(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [pane("w2:p1", "w2:t1", title="same")])
        self.assertRan(self.h.run("startup"))
        self.assertRan(self.h.run("pane.focused"))
        self.assertEqual(self.h.renames(), [["w2:t1", "same"]])

    def test_user_rename_of_a_plugin_label_is_kept_when_the_title_changes(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [pane("w2:p1", "w2:t1", title="first task")])
        self.assertRan(self.h.run("startup"))
        state = self.h.state()
        state["tabs"][0]["label"] = "mine"
        state["panes"][0]["terminal_title_stripped"] = "second task"
        self.h.set_state(state["workspaces"], state["tabs"], state["panes"])
        self.assertRan(self.h.run("pane.focused"))
        self.assertEqual(self.h.renames(), [["w2:t1", "first task"]])

    def test_renaming_a_tab_back_to_its_number_returns_it_to_the_plugin(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1, label="mine")],
                         [pane("w2:p1", "w2:t1", title="task")])
        self.assertRan(self.h.run("startup"))
        state = self.h.state()
        state["tabs"][0]["label"] = "1"
        self.h.set_state(state["workspaces"], state["tabs"], state["panes"])
        self.assertRan(self.h.run("tab.renamed"))
        self.assertEqual(self.h.renames(), [["w2:t1", "task"]])

    def test_failed_rename_keeps_ownership_of_tabs_renamed_before_it(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1), tab("w2:t2", 2)],
                         [pane("w2:p1", "w2:t1", title="one"),
                          pane("w2:p2", "w2:t2", title="two")])
        self.h.rename_fail = "w2:t2"
        self.assertRan(self.h.run("startup"))
        self.h.rename_fail = ""
        state = self.h.state()
        state["panes"][0]["terminal_title_stripped"] = "one again"
        self.h.set_state(state["workspaces"], state["tabs"], state["panes"])
        self.assertRan(self.h.run("pane.focused"))
        self.assertIn(["w2:t1", "one again"], self.h.renames())
        self.assertIn(["w2:t2", "two"], self.h.renames())

    def test_state_file_that_is_not_an_object_is_reset(self):
        (self.h.state_dir / "state.json").write_text("[]", encoding="utf-8")
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [pane("w2:p1", "w2:t1", title="task")])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [["w2:t1", "task"]])

    def test_split_tab_and_plain_shell_tab_are_left_alone(self):
        self.h.set_state(
            [workspace("w2", "alpha")],
            [tab("w2:t1", 1, pane_count=2), tab("w2:t2", 2)],
            [pane("w2:p1", "w2:t1"), pane("w2:p2", "w2:t1"),
             pane("w2:p3", "w2:t2", agent=None, title="~/dev")],
        )
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [])


class NotificationTest(HerdrPluginTestCase):
    def setUp(self):
        super().setUp()
        self.h.set_state([workspace("w5", "beta", focused=True, active_tab="w5:t1")],
                         [tab("w5:t1", 1), tab("w5:t4", 4)],
                         [pane("w5:p1", "w5:t1", title="other"),
                          pane("w5:p4", "w5:t4", title=LONG_TITLE)])

    def test_working_to_idle_sends_finished_notification_that_focuses_the_pane(self):
        self.assertRan(self.h.status("w5:p4", "working"))
        self.assertRan(self.h.status("w5:p4", "idle"))
        sent = self.h.notifications()
        self.assertEqual(len(sent), 1, sent)
        argv = sent[0]
        self.assertEqual(flag(argv, "-title"), "✅ claude 완료")
        self.assertEqual(flag(argv, "-subtitle"), "beta")
        self.assertEqual(flag(argv, "-message"), LONG_TITLE)
        self.assertEqual(flag(argv, "-group"), "herdr-harness.w5:p4")
        self.assertEqual(flag(argv, "-activate"), "com.example.host")
        # terminal-notifier runs the click command without herdr's environment.
        click_env = {key: value for key, value in self.h.env("click").items()
                     if not key.startswith("HERDR_")}
        click = subprocess.run(["/bin/sh", "-c", flag(argv, "-execute")],
                               env=click_env, capture_output=True, text=True)
        self.assertEqual(click.returncode, 0, click.stderr)
        calls = [json.loads(line) for line in self.h.herdr_calls.read_text().splitlines()]
        self.assertEqual(calls[-1], ["agent", "focus", "w5:p4"])
        sockets = Path(str(self.h.herdr_calls) + ".socket").read_text().splitlines()
        self.assertEqual(sockets[-1], str(self.h.root / "herdr test.sock"))

    def test_codex_notification_names_the_latest_thread_name(self):
        harness = self.h.root / "acme-platform-harness"
        index = harness / ".harness" / "codex" / "session_index.jsonl"
        index.parent.mkdir(parents=True)
        thread = "0199aaaa-1111-7222-8333-444455556666"
        index.write_text(json.dumps({"id": thread, "thread_name": "릴리스 노트 검토"},
                                    ensure_ascii=False) + "\n", encoding="utf-8")
        state = self.h.state()
        codex = dict(pane("w5:p4", "w5:t4", agent="codex",
                          title="%s | acme-platform-harness" % thread),
                     cwd=str(harness), agent_session={"agent": "codex", "kind": "id", "value": thread})
        self.h.set_state(state["workspaces"], state["tabs"], [state["panes"][0], codex])
        self.assertRan(self.h.status("w5:p4", "working", agent="codex"))
        self.assertRan(self.h.status("w5:p4", "idle", agent="codex"))
        sent = self.h.notifications()
        self.assertEqual(len(sent), 1, sent)
        self.assertEqual(flag(sent[0], "-message"), "릴리스 노트 검토")

    def test_idle_event_processed_after_the_agent_resumed_work_is_silent(self):
        self.assertRan(self.h.status("w5:p4", "working"))
        self.assertRan(self.h.status("w5:p4", "idle", live="working"))
        self.assertEqual(self.h.notifications(), [])

    def test_host_is_the_outermost_app_bundle(self):
        helper = self.h.root / "Host.app" / "Contents" / "Frameworks" / "Helper.app" / "Contents"
        (helper / "MacOS").mkdir(parents=True)
        with open(helper / "Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "com.example.host.helper"}, handle)
        self.h.ps_table.write_text(
            "  140     1 %s/Host.app/Contents/MacOS/host\n"
            "  145   140 %s/MacOS/helper\n"
            "  160   145 /bin/zsh\n"
            "  200   160 herdr\n" % (self.h.root, helper), encoding="utf-8")
        self.assertRan(self.h.status("w5:p4", "working"))
        self.assertRan(self.h.status("w5:p4", "idle"))
        self.assertEqual(flag(self.h.notifications()[0], "-activate"), "com.example.host")

    def test_blocked_sends_needs_input_notification(self):
        self.assertRan(self.h.status("w5:p4", "blocked", agent="codex"))
        self.assertEqual(flag(self.h.notifications()[0], "-title"), "⏳ codex 입력 필요")

    def test_idle_without_prior_work_is_silent(self):
        self.assertRan(self.h.status("w5:p4", "idle"))
        self.assertRan(self.h.status("w5:p4", "idle"))
        self.assertEqual(self.h.notifications(), [])

    def test_visible_tab_is_silent_while_host_app_is_frontmost(self):
        self.h.front_bundle = "com.example.host"
        self.assertRan(self.h.status("w5:p1", "working"))
        self.assertRan(self.h.status("w5:p1", "idle"))
        self.assertEqual(self.h.notifications(), [])

    def test_visible_tab_notifies_when_another_app_is_frontmost(self):
        self.h.front_bundle = "com.example.other"
        self.assertRan(self.h.status("w5:p1", "working"))
        self.assertRan(self.h.status("w5:p1", "idle"))
        self.assertEqual(len(self.h.notifications()), 1)

    def test_state_superseded_during_delay_is_not_announced(self):
        self.assertRan(self.h.status("w5:p4", "working"))
        env = self.h.env("pane.agent_status_changed", {
            "event": "pane_agent_status_changed",
            "data": {"pane_id": "w5:p4", "workspace_id": "w5",
                     "agent_status": "idle", "agent": "claude"}}, "w5:p4", delay="4")
        pending = subprocess.Popen([TARGET_PYTHON, str(SCRIPT)], cwd=PLUGIN_DIR, env=env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        time.sleep(0.4)
        self.assertRan(self.h.status("w5:p4", "working"))
        _, err = pending.communicate(timeout=30)
        self.assertEqual(pending.returncode, 0, err)
        self.assertEqual(self.h.notifications(), [])

    def test_missing_terminal_notifier_falls_back_to_osascript(self):
        (self.h.stubs / "terminal-notifier").unlink()
        self.assertRan(self.h.status("w5:p4", "working"))
        self.assertRan(self.h.status("w5:p4", "idle"))
        self.assertEqual(self.h.notifications(), [])
        fallback = self.h.notifications(self.h.osascript_log)
        self.assertEqual(len(fallback), 1)
        self.assertIn(LONG_TITLE, fallback[0])

    def test_terminal_notifier_is_found_next_to_a_homebrew_herdr(self):
        # herdr runs plugins with PATH=/usr/bin:/bin:/usr/sbin:/sbin, and Homebrew links
        # both opt/herdr and bin/herdr to the versioned Cellar directory.
        (self.h.stubs / "terminal-notifier").unlink()
        prefix = self.h.root / "homebrew"
        cellar_bin = prefix / "Cellar" / "herdr" / "0.9.1" / "bin"
        cellar_bin.mkdir(parents=True)
        self.h.herdr_bin.rename(cellar_bin / "herdr")
        (prefix / "opt").mkdir()
        (prefix / "opt" / "herdr").symlink_to("../Cellar/herdr/0.9.1")
        (prefix / "bin").mkdir()
        (prefix / "bin" / "herdr").symlink_to("../Cellar/herdr/0.9.1/bin/herdr")
        notifier = prefix / "bin" / "terminal-notifier"
        notifier.write_text(LOG_ARGV.format(log=self.h.notify_log), encoding="utf-8")
        notifier.chmod(0o755)
        for herdr_path in (prefix / "opt" / "herdr" / "bin" / "herdr",
                           prefix / "bin" / "herdr",
                           cellar_bin / "herdr"):
            with self.subTest(herdr_path=str(herdr_path.relative_to(prefix))):
                self.h.notify_log.unlink(missing_ok=True)
                self.h.osascript_log.unlink(missing_ok=True)
                self.h.herdr_bin = herdr_path
                self.assertRan(self.h.status("w5:p4", "working"))
                self.assertRan(self.h.status("w5:p4", "idle"))
                self.assertEqual(len(self.h.notifications()), 1)
                self.assertEqual(self.h.notifications(self.h.osascript_log), [])

    def test_herdr_failure_does_not_fail_the_hook(self):
        self.h.herdr_state.write_text("not json", encoding="utf-8")
        result = self.h.run("pane.agent_status_changed", {
            "event": "pane_agent_status_changed",
            "data": {"pane_id": "w5:p4", "agent_status": "blocked", "agent": "claude"}}, "w5:p4")
        self.assertEqual(result.returncode, 0, result.stderr)


THREAD = "0199aaaa-1111-7222-8333-444455556666"
SESSION = "5b6c7d8e-1111-4222-8333-444455556666"
LABELS = ["--state-label", "idle=대기", "--state-label", "working=작업 중",
          "--state-label", "blocked=입력 필요", "--state-label", "done=완료"]


def jsonl(path, records, append=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a" if append else "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def codex_agent(pane_id, tab_id, cwd, title=None):
    item = pane(pane_id, tab_id, agent="codex", title=title or "%s | acme-platform-harness" % THREAD)
    item["cwd"] = str(cwd)
    item["agent_session"] = {"agent": "codex", "kind": "id", "source": "hook", "value": THREAD}
    return item


def claude_agent(pane_id, tab_id, cwd, title=""):
    item = pane(pane_id, tab_id, agent="claude", title=title)
    item["cwd"] = str(cwd)
    item["agent_session"] = {"agent": "claude", "kind": "id", "source": "herdr:claude", "value": SESSION}
    return item


class SessionRecordsMixin:
    def codex_index(self, records, append=False):
        index = self.h.root / "acme-platform-harness" / ".harness" / "codex" / "session_index.jsonl"
        jsonl(index, records, append)
        return index.parents[2]

    def codex_turn(self, model, effort, append=False):
        rollout = (self.h.root / "acme-platform-harness" / ".harness" / "codex" / "sessions" / "2026" /
                   "10" / "01" / ("rollout-2026-10-01T10-00-00-%s.jsonl" % THREAD))
        jsonl(rollout, [{"type": "turn_context", "payload": {"model": model, "effort": effort}},
                        {"type": "event_msg", "payload": {"type": "token_count"}}], append)

    def transcript(self, records, append=False):
        path = (self.h.root / "acme-platform-harness" / ".harness" / "claude" / "projects" /
                "-acme-platform-harness" / (SESSION + ".jsonl"))
        jsonl(path, records, append)
        return path


def custom_title(title):
    return {"type": "custom-title", "customTitle": title, "sessionId": SESSION}


def ai_title(title):
    return {"type": "ai-title", "aiTitle": title, "sessionId": SESSION}


def assistant(model, effort):
    return {"type": "assistant", "sessionId": SESSION, "effort": effort,
            "message": {"role": "assistant", "model": model, "content": []}}


class SessionTitleTest(HerdrPluginTestCase, SessionRecordsMixin):
    """A rename reaches the agent's own records before its terminal title."""

    def test_claude_custom_title_in_the_transcript_beats_the_terminal_title(self):
        harness = self.h.root / "acme-platform-harness"
        self.transcript([ai_title("자동 제목"), {"type": "user", "sessionId": SESSION},
                         custom_title("세션 이름 변경 반영"), custom_title(""),
                         dict(custom_title("다른 세션"), sessionId="other")])
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [claude_agent("w2:p1", "w2:t1", harness / "sub", title="옛 터미널 제목")])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [["w2:t1", "세션 이름 변경 반영"]])

    def test_claude_ai_title_only_fills_a_missing_terminal_title(self):
        harness = self.h.root / "acme-platform-harness"
        self.transcript([ai_title("자동 제목")])
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1), tab("w2:t2", 2)],
                         [claude_agent("w2:p1", "w2:t1", harness, title="터미널 제목"),
                          dict(claude_agent("w2:p2", "w2:t2", harness), pane_id="w2:p2")])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [["w2:t1", "터미널 제목"], ["w2:t2", "자동 제목"]])

    def test_appended_custom_title_is_read_on_the_next_run(self):
        harness = self.h.root / "acme-platform-harness"
        path = self.transcript([custom_title("첫 이름")])
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [claude_agent("w2:p1", "w2:t1", harness, title="x")])
        self.assertRan(self.h.run("startup"))
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(custom_title("둘째 이름"), ensure_ascii=False) + "\n")
            handle.write('{"type": "custom-title", "customTitle": "쓰는 중')  # partial line
        self.assertRan(self.h.run("pane.focused"))
        self.assertEqual(self.h.renames(), [["w2:t1", "첫 이름"], ["w2:t1", "둘째 이름"]])

    def test_codex_approval_marker_is_not_part_of_the_title(self):
        self.h.set_state([workspace("w5", "beta")], [tab("w5:t1", 1), tab("w5:t2", 2)],
                         [codex_agent("w5:p1", "w5:t1", self.h.root / "x",
                                      title="[ . ] Action Required | %s | acme-platform-harness" % THREAD),
                          dict(codex_agent("w5:p2", "w5:t2", self.h.root / "x",
                                           title="[ ! ] Action Required | 배포 점검 | acme-platform-harness"),
                               agent_session=None)])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.renames(), [["w5:t2", "배포 점검"]])


class MetadataTest(HerdrPluginTestCase, SessionRecordsMixin):
    """Each agent pane gets its full title, Korean state labels and a $model token."""

    def setUp(self):
        super().setUp()
        harness = self.codex_index([{"id": THREAD, "thread_name": "릴리스 노트 검토와 배포 체크리스트 정리"}])
        self.codex_turn("gpt-6.1-sol", "xhigh")
        self.h.set_state([workspace("w5", "beta")], [tab("w5:t1", 1)],
                         [codex_agent("w5:p1", "w5:t1", harness)])

    def test_report_carries_the_full_title_labels_and_model(self):
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.reports(), [
            ["w5:p1", "--source", "harness.launcher", "--agent", "codex",
             "--title", "릴리스 노트 검토와 배포 체크리스트 정리"] + LABELS + ["--token", "model=6.1-sol xhigh"]])
        self.assertEqual(self.h.renames(), [["w5:t1", "릴리스 노트 검토와…"]])

    def test_unchanged_metadata_is_not_reported_again(self):
        self.assertRan(self.h.run("startup"))
        self.assertRan(self.h.run("pane.focused"))
        self.assertEqual(len(self.h.reports()), 1)

    def test_model_is_read_again_only_when_the_agent_status_changes(self):
        self.assertRan(self.h.run("startup"))
        self.codex_turn("gpt-6.1-sol", "high", append=True)
        self.assertRan(self.h.run("pane.focused"))
        self.assertEqual(len(self.h.reports()), 1)
        self.assertRan(self.h.status("w5:p1", "working", agent="codex"))
        self.assertEqual(self.h.reports()[-1][-2:], ["--token", "model=6.1-sol high"])
        self.assertIn("--title", self.h.reports()[-1])

    def test_claude_model_and_effort_come_from_the_latest_assistant_record(self):
        harness = self.h.root / "acme-platform-harness"
        self.transcript([assistant("claude-sonnet-5-5", "high"), custom_title("작업"),
                         assistant("claude-opus-5-5", "xhigh"), {"type": "user", "sessionId": SESSION}])
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [claude_agent("w2:p1", "w2:t1", harness, title="x")])
        self.assertRan(self.h.run("startup"))
        self.assertEqual(self.h.reports()[-1][-2:], ["--token", "model=opus-5-5 xhigh"])

    def test_metadata_is_cleared_when_the_agent_leaves(self):
        self.assertRan(self.h.run("startup"))
        state = self.h.state()
        state["panes"][0]["agent"] = None
        self.h.set_state(state["workspaces"], state["tabs"], state["panes"])
        self.assertRan(self.h.run("pane.focused"))
        self.assertEqual(self.h.reports()[-1], ["w5:p1", "--source", "harness.launcher", "--clear-title",
                                                "--clear-state-labels", "--clear-token", "model"])
        self.assertRan(self.h.run("pane.focused"))
        self.assertEqual(len(self.h.reports()), 2)


class OwnRenameTest(HerdrPluginTestCase):
    def setUp(self):
        super().setUp()
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [pane("w2:p1", "w2:t1", title="mkt 스킬")])
        self.assertRan(self.h.run("startup"))
        self.h.herdr_calls.unlink()

    def renamed(self, label):
        return self.h.run("tab.renamed", {"event": "tab_renamed",
                                          "data": {"type": "tab_renamed", "tab_id": "w2:t1", "label": label}})

    def test_the_plugins_own_rename_does_not_run_a_sync(self):
        self.assertRan(self.renamed("mkt 스킬"))
        self.assertEqual(self.h.calls(), [])

    def test_a_users_rename_still_syncs(self):
        self.assertRan(self.renamed("1"))
        self.assertIn(["tab", "list"], self.h.calls())


class UsageServer:
    def __init__(self, providers, token):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                ok = self.path == "/api/usage" and self.headers.get("authorization") == "Bearer " + token
                data = json.dumps({"providers": providers} if ok else {}).encode()
                self.send_response(200 if ok else 401)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class FakeEvents:
    """A herdr API socket that acknowledges one subscription and pushes lines on demand."""

    def __init__(self, path):
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(path))
        self.server.listen(1)
        self.requests = []
        self.client = None
        self.ready = threading.Event()
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        self.client, _ = self.server.accept()
        self.requests.append(json.loads(self.client.makefile("rb").readline()))
        self.push({"id": "harness-launcher-watch", "result": {"type": "subscription_started"}})
        self.ready.set()

    def push(self, message):
        self.client.sendall(json.dumps(message, ensure_ascii=False).encode() + b"\n")

    def close(self):
        for sock in (self.client, self.server):
            if sock is not None:
                sock.close()


class WatcherTest(HerdrPluginTestCase, SessionRecordsMixin):
    """The background watcher, run from a copy of the plugin so a test can 'upgrade' it."""

    def setUp(self):
        super().setUp()
        package = self.h.root / "pkg"
        (package / "herdr-plugin").mkdir(parents=True)
        (package / "bin").mkdir()
        self.script = package / "herdr-plugin" / "harness_herdr_plugin.py"
        shutil.copy(SCRIPT, self.script)
        for name in ("harness_herdr_usage.py", "harness_herdr_web.py"):
            shutil.copy(BIN_DIR / name, package / "bin" / name)
        self.procs = []
        self.addCleanup(self.stop_all)

    def watch_env(self, **extra):
        env = self.h.env("watch")
        env.update({"HARNESS_HERDR_WATCH_POLL_SECONDS": "0.05",
                    "HARNESS_HERDR_WATCH_REFRESH_SECONDS": "60",
                    "HARNESS_HERDR_USAGE_SECONDS": "3600",
                    "XDG_STATE_HOME": str(self.h.root / "state")})
        env.update(extra)
        return env

    def start(self, **extra):
        proc = subprocess.Popen([TARGET_PYTHON, str(self.script), "watch"], env=self.watch_env(**extra),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(proc)
        return proc

    def stop_all(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=10)

    def until(self, predicate, timeout=10.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return True
            time.sleep(0.05)
        return predicate()

    def lock_is_held(self):
        import fcntl
        with open(self.h.state_dir / "watch.lock", "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return True
        return False

    def test_codex_rename_in_the_index_relabels_without_a_herdr_event(self):
        harness = self.codex_index([{"id": THREAD, "thread_name": "첫 이름"}])
        self.h.set_state([workspace("w5", "beta")], [tab("w5:t1", 1)], [codex_agent("w5:p1", "w5:t1", harness)])
        self.start()
        self.assertTrue(self.until(lambda: ["w5:t1", "첫 이름"] in self.h.renames()))
        self.codex_index([{"id": THREAD, "thread_name": "바뀐 이름"}], append=True)
        self.assertTrue(self.until(lambda: self.h.renames()[-1] == ["w5:t1", "바뀐 이름"], timeout=5),
                        self.h.renames())

    def test_claude_custom_title_in_the_transcript_relabels_without_a_herdr_event(self):
        harness = self.h.root / "acme-platform-harness"
        self.transcript([custom_title("첫 이름")])
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)],
                         [claude_agent("w2:p1", "w2:t1", harness, title="x")])
        self.start()
        self.assertTrue(self.until(lambda: ["w2:t1", "첫 이름"] in self.h.renames()))
        self.transcript([{"type": "user", "sessionId": SESSION}, custom_title("바뀐 이름")], append=True)
        self.assertTrue(self.until(lambda: self.h.renames()[-1] == ["w2:t1", "바뀐 이름"], timeout=5),
                        self.h.renames())

    def test_terminal_title_event_syncs_and_a_blinking_marker_does_not(self):
        sock_path = Path(tempfile.mkdtemp(prefix="hw", dir="/tmp")) / "s.sock"
        self.addCleanup(shutil.rmtree, sock_path.parent, True)
        events = FakeEvents(sock_path)
        self.addCleanup(events.close)
        codex = codex_agent("w5:p2", "w5:t2", self.h.root / "x",
                            title="[ . ] Action Required | %s | acme-platform-harness" % THREAD)
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1), tab("w5:t2", 2)],
                         [pane("w2:p1", "w2:t1", title="첫 작업"), codex])
        self.start(HERDR_SOCKET_PATH=str(sock_path))
        self.assertTrue(events.ready.wait(10))
        self.assertEqual(events.requests[0]["params"], {"subscriptions": [{"type": "pane.updated"}]})
        self.assertTrue(self.until(lambda: ["w2:t1", "첫 작업"] in self.h.renames()))
        time.sleep(0.5)
        lists = self.h.calls().count(["tab", "list"])
        blink = dict(codex, terminal_title_stripped="[ ! ] Action Required | %s | acme-platform-harness" % THREAD)
        events.push({"event": "pane_updated", "data": {"type": "pane_updated", "pane": blink}})
        time.sleep(0.5)
        self.assertEqual(self.h.calls().count(["tab", "list"]), lists)
        state = self.h.state()
        state["panes"][0]["terminal_title_stripped"] = "다음 작업"
        self.h.set_state(state["workspaces"], state["tabs"], state["panes"])
        events.push({"event": "pane_updated", "data": {"type": "pane_updated", "pane": state["panes"][0]}})
        self.assertTrue(self.until(lambda: self.h.renames()[-1] == ["w2:t1", "다음 작업"], timeout=5))

    def test_usage_is_reported_on_claude_and_codex_panes(self):
        token = "c" * 64
        server = UsageServer([{"id": "codex", "windows": [{"kind": "week", "used_percent": 100,
                                                          "resets_at": "2099-01-01T00:00:00Z"}]}], token)
        self.addCleanup(server.close)
        config = self.h.root / "web-config"
        config.mkdir(mode=0o700)
        (config / "env").write_text("HERDR_WEB_TOKEN=%s\nPORT=%d\n" % (token, server.port))
        (config / "env").chmod(0o600)
        self.h.set_state([workspace("w5", "beta")], [tab("w5:t1", 1), tab("w5:t2", 2)],
                         [codex_agent("w5:p1", "w5:t1", self.h.root / "x"),
                          pane("w5:p2", "w5:t2", agent="pi", title="other")])
        self.start(FAKE_CONFIG_DIR=str(config))
        quota = ["w5:p1", "--source", "harness.launcher.usage", "--token", "quota=🔴 7d 100%",
                 "--ttl-ms", "900000"]
        self.assertTrue(self.until(lambda: quota in self.h.reports()), self.h.reports())
        self.assertFalse([report for report in self.h.reports() if report[0] == "w5:p2" and "quota" in str(report)])

    def test_only_one_watcher_runs(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)], [pane("w2:p1", "w2:t1", title="a")])
        first = self.start()
        self.assertTrue(self.until(self.lock_is_held))
        second = self.start()
        self.assertEqual(second.wait(timeout=10), 0)
        self.assertIsNone(first.poll())

    def test_watcher_exits_when_the_plugin_is_upgraded(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)], [pane("w2:p1", "w2:t1", title="a")])
        proc = self.start()
        self.assertTrue(self.until(lambda: self.h.renames() != []))
        with open(self.script, "a", encoding="utf-8") as handle:
            handle.write("\n# upgraded\n")
        self.assertEqual(proc.wait(timeout=10), 0)

    def test_watcher_exits_when_herdr_stops_answering(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)], [pane("w2:p1", "w2:t1", title="a")])
        proc = self.start(HARNESS_HERDR_WATCH_REFRESH_SECONDS="0.1")
        self.assertTrue(self.until(lambda: self.h.renames() != []))
        self.h.herdr_state.write_text("not json", encoding="utf-8")
        self.assertEqual(proc.wait(timeout=10), 0)
        self.assertFalse(self.lock_is_held())

    def test_a_hook_starts_the_watcher_once(self):
        self.h.set_state([workspace("w2", "alpha")], [tab("w2:t1", 1)], [pane("w2:p1", "w2:t1", title="a")])
        env = self.watch_env(HARNESS_HERDR_WATCH="1", HARNESS_HERDR_WATCH_REFRESH_SECONDS="0.1")
        env["HERDR_PLUGIN_EVENT"] = "startup"
        for _ in range(2):
            result = subprocess.run([TARGET_PYTHON, str(self.script)], env=env, capture_output=True,
                                    text=True, timeout=30)
            self.assertRan(result)
        self.assertTrue(self.until(self.lock_is_held))
        self.h.herdr_state.write_text("not json", encoding="utf-8")
        self.assertTrue(self.until(lambda: not self.lock_is_held(), timeout=15))


if __name__ == "__main__":
    unittest.main()
