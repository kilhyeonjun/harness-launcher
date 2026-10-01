#!/usr/bin/env python3
"""Contract for herdr plan usage: pace, exhaustion time, sample history, CLI output."""

import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

BIN = Path(__file__).resolve().parents[1] / "bin"
WRAPPER = BIN / "harness-herdr-web"
TOKEN = "b" * 64
SYSTEM_PYTHON = "/usr/bin/python3"

sys.path.insert(0, str(BIN))
SPEC = importlib.util.spec_from_file_location("harness_herdr_usage", BIN / "harness_herdr_usage.py")
usage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(usage)

KST = datetime.timezone(datetime.timedelta(hours=9))
NOW = datetime.datetime(2026, 10, 1, 10, 45, tzinfo=KST)  # a Thursday


def iso(moment):
    return moment.astimezone(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def week(used, hours_left, history=()):
    return usage.describe("week", used, iso(NOW + datetime.timedelta(hours=hours_left)), NOW, list(history))


class DescribeTest(unittest.TestCase):
    def test_fast_burn_runs_out_before_the_reset(self):
        window = week(60, 116)
        self.assertEqual(window["severity"], usage.RED)
        self.assertEqual(usage.text(window, NOW), "7d 60% 1.9× →금21시 ↻화06시")

    def test_slow_burn_is_green_without_an_exhaustion_time(self):
        window = week(48, 65)
        self.assertEqual(window["severity"], usage.GREEN)
        self.assertEqual(usage.text(window, NOW), "7d 48% 0.8× ↻일03시")

    def test_projection_near_the_limit_is_yellow(self):
        window = week(45, 84)  # half the week elapsed
        self.assertEqual(window["severity"], usage.YELLOW)
        self.assertEqual(usage.text(window, NOW, with_reset=False), "7d 45% 0.9×")

    def test_early_session_window_has_no_pace(self):
        window = usage.describe("session", 3, iso(NOW + datetime.timedelta(hours=4, minutes=30)), NOW, [])
        self.assertEqual(usage.text(window, NOW), "5h 3% ↻15:15")
        self.assertEqual(window["severity"], usage.GREEN)

    def test_recent_slope_beats_the_window_average(self):
        two_hours_ago = (NOW - datetime.timedelta(hours=2)).timestamp()
        window = week(48, 65, [[two_hours_ago, 38]])  # 5%/h for 65h
        self.assertEqual(window["severity"], usage.RED)
        self.assertIsNotNone(window["eta"])

    def test_idle_recent_slope_drops_the_exhaustion_time(self):
        two_hours_ago = (NOW - datetime.timedelta(hours=2)).timestamp()
        window = week(60, 116, [[two_hours_ago, 60]])
        self.assertIsNone(window["eta"])
        self.assertEqual(usage.text(window, NOW, with_reset=False), "7d 60% 0.0×")

    def test_used_up_window_is_red(self):
        self.assertEqual(week(100, 20)["severity"], usage.RED)

    def test_unknown_kind_and_far_reset_keep_the_plain_value(self):
        window = usage.describe("month", 20, iso(NOW + datetime.timedelta(days=10)), NOW, [])
        self.assertEqual(usage.text(window, NOW), "mo 20% ↻10/11")
        self.assertEqual(window["severity"], usage.GREEN)

    def test_any_fraction_length_parses_on_python_3_9(self):
        for value in ("2026-10-05T22:00:00.093Z", "2026-10-05T22:00:00.123456789Z",
                      "2026-10-05T22:00:00.5+00:00", "2026-10-05T22:00:00Z"):
            with self.subTest(value=value):
                self.assertIsNotNone(usage.parse_time(value))
        self.assertIsNone(usage.parse_time("2026-10-05T22:00:00"))  # no zone

    def test_unparsable_reset_keeps_the_value(self):
        window = usage.describe("week", 85, "soon", NOW, [])
        self.assertEqual(usage.text(window, NOW), "7d 85%")
        self.assertEqual(window["severity"], usage.YELLOW)


class HistoryTest(unittest.TestCase):
    def test_a_new_window_clears_the_history(self):
        series = {"reset": iso(NOW + datetime.timedelta(hours=1)), "samples": [[NOW.timestamp() - 600, 40]]}
        self.assertEqual(usage.record(series, NOW, 5, iso(NOW + datetime.timedelta(hours=5))),
                         [[NOW.timestamp(), 5]])

    def test_a_drop_in_usage_clears_the_history(self):
        reset = iso(NOW + datetime.timedelta(hours=5))
        series = {"reset": reset, "samples": [[NOW.timestamp() - 600, 40]]}
        self.assertEqual(usage.record(series, NOW, 10, reset), [[NOW.timestamp(), 10]])

    def test_old_samples_are_pruned_and_samples_are_spaced(self):
        reset = iso(NOW + datetime.timedelta(hours=50))
        recent = NOW.timestamp() - 60
        series = {"reset": reset, "samples": [[NOW.timestamp() - usage.KEEP_SECONDS - 1, 10], [recent, 20]]}
        self.assertEqual(usage.record(series, NOW, 21, reset), [[recent, 20]])

    def test_reset_jitter_keeps_the_history(self):
        reset = NOW + datetime.timedelta(hours=50)
        series = {"reset": iso(reset), "samples": [[NOW.timestamp() - 900, 20]]}
        self.assertEqual(len(usage.record(series, NOW, 21, iso(reset + datetime.timedelta(seconds=1)))), 2)


PROVIDERS = [
    {"id": "claude", "windows": [
        {"kind": "session", "used_percent": 14, "resets_at": iso(NOW + datetime.timedelta(hours=1, minutes=25))},
        {"kind": "week", "used_percent": 60, "resets_at": iso(NOW + datetime.timedelta(hours=116))}]},
    {"id": "codex", "windows": [
        {"kind": "week", "used_percent": 48, "resets_at": iso(NOW + datetime.timedelta(hours=65))}]},
    {"id": "cursor", "problem": "expired", "windows": []},
    {"id": "claude-like", "windows": [{"kind": "week", "used_percent": 1}]},
    "not a provider",
]


class SummaryTest(unittest.TestCase):
    def test_line_shows_every_window_and_the_worst_badge(self):
        line = usage.line(usage.summarize(PROVIDERS, NOW, {}), NOW)
        self.assertEqual(line, "🔴 Claude 5h 14% 0.2× ↻12:10 · 7d 60% 1.9× →금21시 ↻화06시"
                               " │ 🟢 Codex 7d 48% 0.8× ↻일03시")

    def test_badges_name_the_most_pressing_window_without_the_reset(self):
        self.assertEqual(usage.badges(usage.summarize(PROVIDERS, NOW, {}), NOW),
                         {"claude": "🔴 7d 60% 1.9× →금21시", "codex": "🟢 7d 48% 0.8×"})

    def test_summary_records_samples(self):
        store = {}
        usage.summarize(PROVIDERS, NOW, store)
        self.assertEqual(sorted(store), ["claude:session", "claude:week", "codex:week"])

    def test_nothing_to_show(self):
        self.assertEqual(usage.line([], NOW), "usage —")

    def test_a_damaged_store_starts_over(self):
        store = {"claude:week": "x", "claude:session": {"reset": 5, "samples": [["a"], [1, 2, 3], 5, [1.0, 2]]},
                 "codex:week": {"samples": "none"}}
        line = usage.line(usage.summarize(PROVIDERS, NOW, store), NOW)
        self.assertTrue(line.startswith("🔴 Claude 5h 14%"), line)
        self.assertEqual(store["claude:week"]["samples"], [[NOW.timestamp(), 60]])


class UsageServer:
    def __init__(self, providers, redirect=None):
        seen = self.seen = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.path, self.headers.get("authorization"), self.headers.get("x-herdr-machine")))
                if redirect:
                    self.send_response(302)
                    self.send_header("Location", redirect)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                ok = self.path == "/api/usage" and self.headers.get("authorization") == "Bearer " + TOKEN
                data = json.dumps({"providers": providers} if ok else {"error": "auth"}).encode()
                self.send_response(200 if ok else 401)
                self.send_header("Content-Type", "application/json")
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


FAKE_HERDR = '#!/bin/sh\n[ "$1 $2" = "plugin config-dir" ] && printf "%s\\n" "$FAKE_CONFIG_DIR"\n'


class CommandTest(unittest.TestCase):
    """`harness-herdr-web usage` as herdr's tab bar runs it: a launchd PATH without herdr."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.config = self.root / "config"
        self.config.mkdir(mode=0o700)
        self.herdr = self.root / "elsewhere" / "herdr"
        self.herdr.parent.mkdir()
        self.herdr.write_text(FAKE_HERDR)
        self.herdr.chmod(0o755)
        later = NOW.astimezone(datetime.timezone.utc)
        self.server = UsageServer([{"id": "codex", "windows": [
            {"kind": "week", "used_percent": 48, "resets_at": iso(later + datetime.timedelta(days=3))}]}])
        self.addCleanup(self.server.close)

    def write_env(self, port):
        env = self.config / "env"
        env.write_text("HERDR_WEB_TOKEN=%s\nHOST=127.0.0.1\nPORT=%d\n" % (TOKEN, port))
        env.chmod(0o600)

    def run_usage(self):
        env = {"HOME": str(self.root), "PATH": "/usr/bin:/bin", "HERDR_BIN_PATH": str(self.herdr),
               "FAKE_CONFIG_DIR": str(self.config), "XDG_STATE_HOME": str(self.root / "state")}
        return subprocess.run([str(WRAPPER), "usage"], env=env, capture_output=True, text=True, timeout=60)

    def test_prints_the_usage_line_with_the_token_and_records_samples(self):
        self.write_env(self.server.port)
        result = self.run_usage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout.strip(), r"^🟢 Codex 7d 48% ")
        self.assertEqual(self.server.seen, [("/api/usage", "Bearer " + TOKEN, "1")])
        store = json.loads((self.root / "state" / "harness-launcher" / "herdr-usage.json").read_text())
        self.assertIn("codex:week", store)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_a_redirect_is_not_followed_with_the_token(self):
        elsewhere = UsageServer([])
        self.addCleanup(elsewhere.close)
        redirecting = UsageServer([], redirect="http://127.0.0.1:%d/api/usage" % elsewhere.port)
        self.addCleanup(redirecting.close)
        self.write_env(redirecting.port)
        result = self.run_usage()
        self.assertEqual(result.stdout.strip(), "usage n/a")
        self.assertEqual(len(redirecting.seen), 1)
        self.assertEqual(elsewhere.seen, [])

    def test_unreachable_web_ui_prints_a_placeholder(self):
        self.server.close()
        self.write_env(self.server.port)
        result = self.run_usage()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "usage n/a")
        self.assertEqual(result.stderr, "")


class SystemPythonTest(unittest.TestCase):
    """The herdr plugin imports this module with /usr/bin/python3."""

    @unittest.skipUnless(os.path.exists(SYSTEM_PYTHON), "no system python")
    def test_module_runs_under_system_python(self):
        script = ("import sys, datetime; sys.path.insert(0, %r); import harness_herdr_usage as u; "
                  "now = datetime.datetime(2026, 10, 1, 10, 45, tzinfo=datetime.timezone.utc); "
                  "print(u.text(u.describe('week', 60, '2026-10-05T22:00:00.093Z', now, []), now))"
                  % str(BIN))
        result = subprocess.run([SYSTEM_PYTHON, "-c", script], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"^7d 60% 1\.\d× →")


if __name__ == "__main__":
    unittest.main()
