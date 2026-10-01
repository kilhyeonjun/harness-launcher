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
    {"id": "claude", "plan": "max", "windows": [
        {"kind": "session", "used_percent": 14, "resets_at": iso(NOW + datetime.timedelta(hours=1, minutes=25))},
        {"kind": "week", "used_percent": 60, "resets_at": iso(NOW + datetime.timedelta(hours=116))}]},
    {"id": "codex", "plan": "pro", "windows": [
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

    def test_summary_records_samples(self):
        store = {}
        usage.summarize(PROVIDERS, NOW, store)
        self.assertEqual(sorted(store), ["claude:session", "claude:week", "codex:week"])

    def test_a_scoped_window_keeps_its_own_history_and_label(self):
        reset = iso(NOW + datetime.timedelta(hours=100))
        store = {}
        summary = usage.summarize([{"id": "claude", "windows": [
            {"kind": "week", "scope": None, "used_percent": 60, "resets_at": reset},
            {"kind": "week", "scope": "opus", "used_percent": 20, "resets_at": reset}]}], NOW, store)
        self.assertEqual(sorted(store), ["claude:week", "claude:week:opus"])
        self.assertEqual([window["label"] for window in summary[0][1]], ["7d", "7d opus"])

    def test_accounts_name_the_plan_or_the_problem(self):
        self.assertEqual(usage.accounts(PROVIDERS + [{"id": "codex", "problem": "expired"}]),
                         {"claude": {"plan": "max", "problem": None}, "codex": {"plan": None, "problem": "expired"}})

    def test_nothing_to_show(self):
        self.assertEqual(usage.line([], NOW), "usage —")

    def test_a_damaged_store_starts_over(self):
        store = {"claude:week": "x", "claude:session": {"reset": 5, "samples": [["a"], [1, 2, 3], 5, [1.0, 2]]},
                 "codex:week": {"samples": "none"}}
        line = usage.line(usage.summarize(PROVIDERS, NOW, store), NOW)
        self.assertTrue(line.startswith("🔴 Claude 5h 14%"), line)
        self.assertEqual(store["claude:week"]["samples"], [[NOW.timestamp(), 60]])


BOARD = """\
 플랜 사용량 · 10:45 기준

 🔴 Claude  max
    5h  ██░░░░░░░░░░│░░░░   14%   0.2×  ↻ 12:10 · 1시간 25분 후
    7d  █████│████░░░░░░░   60%   1.9×  ↻ 화 06:45 · 4일 20시간 후
        ⚠ 이 속도면 내일 21:25 소진 · 1일 10시간 후

 🟢 Codex  pro
    7d  ████████░░│░░░░░░   48%   0.8×  ↻ 일 03:45 · 2일 17시간 후

 █ 사용량 · │ 경과 시간 · 1.0× = 초기화 때 딱 맞게 다 씀
 q 닫기 · r 새로고침 · 60초마다 갱신"""


class DashboardTest(unittest.TestCase):
    def board(self, **options):
        summary = usage.summarize(PROVIDERS, NOW, {})
        options.setdefault("columns", 70)
        return usage.dashboard(summary, usage.accounts(PROVIDERS), NOW, NOW, **options)

    def test_durations_read_in_the_two_largest_units(self):
        self.assertEqual(usage.until(20), "1분 후")
        self.assertEqual(usage.until(25 * 60 + 30), "25분 후")
        self.assertEqual(usage.until(3600), "1시간 후")
        self.assertEqual(usage.until(5100), "1시간 25분 후")
        self.assertEqual(usage.until(34 * 3600 + 40 * 60), "1일 10시간 후")
        self.assertEqual(usage.until(2 * 86400 + 59), "2일 후")

    def test_times_name_the_day_unless_today(self):
        def at(hours):
            return NOW + datetime.timedelta(hours=hours)
        self.assertEqual(usage.clock(at(1.5), NOW), "12:15")
        self.assertEqual(usage.clock(at(14), NOW), "내일 00:45")
        self.assertEqual(usage.clock(at(116), NOW), "화 06:45")
        self.assertEqual(usage.clock(at(24 * 9), NOW), "10/10 10:45")

    def test_bar_fills_the_used_share_and_marks_the_elapsed_time(self):
        self.assertEqual(usage.bar(50, 0.25, 10), "██│██░░░░░")
        self.assertEqual(usage.bar(30, None, 10), "███░░░░░░░")
        self.assertEqual(usage.bar(120, 1.0, 4), "███│")
        self.assertEqual(usage.bar(0, 0.0, 4), "│░░░")

    def test_board_lays_out_every_window(self):
        self.assertEqual("\n".join(self.board()), BOARD)

    def test_board_without_keys_drops_the_key_help(self):
        self.assertEqual("\n".join(self.board(keys=False)), BOARD.rsplit("\n", 1)[0])

    def test_board_warns_near_and_at_the_limit(self):
        reset = iso(NOW + datetime.timedelta(hours=84))
        providers = [{"id": "codex", "windows": [
            {"kind": "week", "used_percent": 45, "resets_at": reset},
            {"kind": "week", "scope": "spark", "used_percent": 100, "resets_at": reset}]}]
        lines = usage.dashboard(usage.summarize(providers, NOW, {}), {}, NOW, NOW, columns=70)
        self.assertIn("        이 속도면 초기화 때 약 90%", lines)
        self.assertIn("        다 씀 · 초기화까지 대기", lines)

    def test_board_names_a_provider_it_cannot_read(self):
        lines = usage.dashboard([], {"claude": {"plan": None, "problem": "expired"}}, NOW, NOW, columns=70)
        self.assertIn(" ⚪ Claude  확인 불가: expired", lines)

    def test_a_failed_refresh_keeps_the_last_reading(self):
        later = NOW + datetime.timedelta(minutes=5)
        lines = usage.dashboard(usage.summarize(PROVIDERS, NOW, {}), usage.accounts(PROVIDERS), later, NOW,
                                columns=70, error="web ui 연결 안 됨")
        self.assertEqual(lines[0], " 플랜 사용량 · 10:45 기준 · ⚠ 갱신 실패: web ui 연결 안 됨")
        self.assertIn("↻ 12:10 · 1시간 20분 후", "\n".join(lines))

    def test_no_reading_explains_where_to_look(self):
        lines = usage.dashboard(None, {}, NOW, None, columns=70, error="HTTP 401")
        self.assertEqual(lines[:4], [" 플랜 사용량", "", " 사용량을 불러오지 못했습니다: HTTP 401",
                                     " 'harness-herdr-web check'로 herdr web ui를 확인하세요."])

    def test_color_marks_severity(self):
        text = "\n".join(self.board(color=True))
        self.assertIn("\x1b[31m⚠ 이 속도면", text)
        self.assertIn("\x1b[32m████████\x1b[0m", text)
        self.assertEqual(usage.ANSI.sub("", text), BOARD)

    def test_server_text_cannot_steer_the_terminal(self):
        providers = [{"id": "claude", "plan": "max\x1b]52;c;eA==\x07", "windows": [
            {"kind": "week", "scope": "op\x9bus", "used_percent": 5,
             "resets_at": iso(NOW + datetime.timedelta(hours=100))}]},
            {"id": "codex", "plan": 5, "problem": {"code": "expired"}}]
        plans = usage.accounts(providers)
        self.assertEqual(plans, {"claude": {"plan": "max]52;c;eA==", "problem": None},
                                 "codex": {"plan": "5", "problem": "{'code': 'expired'}"}})
        summary = usage.summarize(providers, NOW, {})
        self.assertEqual(summary[0][1][0]["label"], "7d opus")
        text = "\n".join(usage.dashboard(summary, plans, NOW, NOW, columns=70))
        self.assertNotRegex(text, "[\x00-\x09\x0b-\x1f\x7f-\x9f]")

    def test_odd_window_values_still_draw(self):
        providers = [{"id": "codex", "windows": [
            {"kind": None, "used_percent": 5}, {"kind": 7, "used_percent": 6},
            {"kind": "week", "used_percent": float("nan")}, {"kind": "week", "used_percent": float("inf")}]}]
        lines = usage.dashboard(usage.summarize(providers, NOW, {}), {}, NOW, NOW, columns=70)
        self.assertEqual([line.split()[0] for line in lines if line.startswith("    ")], ["None", "7"])

    def test_a_past_time_reads_as_passed(self):
        later = NOW + datetime.timedelta(hours=2)
        lines = usage.dashboard(usage.summarize(PROVIDERS, NOW, {}), usage.accounts(PROVIDERS), later, NOW,
                                columns=70, error="HTTP 500")
        self.assertIn("↻ 12:10 · 지남", "\n".join(lines))

    def test_a_steep_pace_keeps_its_column(self):
        recent = [[(NOW - datetime.timedelta(minutes=40)).timestamp(), 0]]
        window = usage.describe("week", 90, iso(NOW + datetime.timedelta(hours=100)), NOW, recent)
        self.assertGreater(window["pace"], 100)
        row = usage.board_rows(window, NOW, 2, 10, lambda value, *styles: value)[0]
        self.assertIn("   90%   >99×  ↻", row)

    def test_an_empty_reading_says_so(self):
        lines = usage.dashboard([], {}, NOW, NOW, columns=70, keys=False)
        self.assertEqual(lines[2], " 표시할 사용량이 없습니다.")

    def test_errors_read_without_details(self):
        import urllib.error
        self.assertEqual(usage.reason(urllib.error.HTTPError("u", 401, "x", {}, None)), "HTTP 401")
        self.assertEqual(usage.reason(urllib.error.URLError("refused")), "web ui 연결 안 됨")
        self.assertEqual(usage.reason(usage.web.Refused("herdr web ui has no token")), "herdr web ui has no token")
        self.assertEqual(usage.reason(ValueError("bad json")), "응답 형식 오류")


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

    def usage_env(self):
        return {"HOME": str(self.root), "PATH": "/usr/bin:/bin", "HERDR_BIN_PATH": str(self.herdr),
                "FAKE_CONFIG_DIR": str(self.config), "XDG_STATE_HOME": str(self.root / "state")}

    def run_usage(self, *args):
        return subprocess.run([str(WRAPPER), "usage", *args], env=self.usage_env(),
                              capture_output=True, text=True, timeout=60)

    def test_watch_without_a_terminal_prints_the_board_once(self):
        self.write_env(self.server.port)
        result = self.run_usage("--watch")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("\n 🟢 Codex\n    7d  ", result.stdout)
        self.assertNotIn("\x1b", result.stdout)
        self.assertNotIn("q 닫기", result.stdout)

    def board(self):
        """`usage --watch` on a pty: (process, send, read_until, output)."""
        import fcntl
        import pty
        import select
        import struct
        import termios
        import time
        self.write_env(self.server.port)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 90, 0, 0))
        proc = subprocess.Popen([str(WRAPPER), "usage", "--watch"], env=self.usage_env(),
                                stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        self.addCleanup(os.close, master)

        def stop():
            if proc.poll() is None:
                proc.kill()
                proc.wait()
        self.addCleanup(stop)
        output = bytearray()

        def read_until(predicate, timeout=20):
            deadline = time.monotonic() + timeout
            while not predicate() and time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError:
                        break
            return predicate()

        return proc, lambda data: os.write(master, data), read_until, output

    def test_watch_redraws_on_r_and_closes_on_esc(self):
        proc, send, read_until, output = self.board()
        self.assertTrue(read_until(lambda: "Codex".encode() in output), output)
        self.assertIn(b"\x1b[?1049h", output)
        self.assertLess(output.index("불러오는 중".encode()), output.index("Codex".encode()))
        send(b"r")
        self.assertTrue(read_until(lambda: len(self.server.seen) == 2), self.server.seen)
        send("ㄱ".encode())  # r under the Korean input method
        self.assertTrue(read_until(lambda: len(self.server.seen) == 3), self.server.seen)
        send(b"\x1b[A")  # an arrow key is not Esc
        read_until(lambda: False, timeout=0.5)
        self.assertIsNone(proc.poll())
        send(b"\x1b")
        self.assertTrue(read_until(lambda: proc.poll() is not None, timeout=10))
        self.assertEqual(proc.returncode, 0)
        read_until(lambda: b"\x1b[?1049l" in output, timeout=2)
        self.assertIn(b"\x1b[?1049l", output)
        self.assertNotIn(TOKEN.encode(), output)

    def test_watch_closes_on_korean_q(self):
        proc, send, read_until, output = self.board()
        self.assertTrue(read_until(lambda: "Codex".encode() in output), output)
        send("ㅂ".encode())  # q under the Korean input method
        self.assertTrue(read_until(lambda: proc.poll() is not None, timeout=10))
        self.assertEqual(proc.returncode, 0)

    def test_watch_restores_the_terminal_on_sigterm(self):
        proc, send, read_until, output = self.board()
        self.assertTrue(read_until(lambda: "Codex".encode() in output), output)
        proc.terminate()
        self.assertTrue(read_until(lambda: proc.poll() is not None, timeout=10))
        read_until(lambda: b"\x1b[?25h\x1b[?1049l" in output, timeout=2)
        self.assertIn(b"\x1b[?25h\x1b[?1049l", output)

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
    """herdr's tab bar and popup may run this module with /usr/bin/python3."""

    @unittest.skipUnless(os.path.exists(SYSTEM_PYTHON), "no system python")
    def test_module_runs_under_system_python(self):
        script = ("import sys, datetime; sys.path.insert(0, %r); import harness_herdr_usage as u; "
                  "now = datetime.datetime(2026, 10, 1, 10, 45, tzinfo=datetime.timezone.utc); "
                  "print(u.text(u.describe('week', 60, '2026-10-05T22:00:00.093Z', now, []), now))"
                  % str(BIN))
        result = subprocess.run([SYSTEM_PYTHON, "-c", script], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"^7d 60% 1\.\d× →")

    @unittest.skipUnless(os.path.exists(SYSTEM_PYTHON), "no system python")
    def test_board_renders_under_system_python(self):
        script = ("import sys, datetime; sys.path.insert(0, %r); import harness_herdr_usage as u; "
                  "now = datetime.datetime(2026, 10, 1, 10, 45, tzinfo=datetime.timezone.utc); "
                  "p = [{'id': 'codex', 'plan': 'pro', 'windows': [{'kind': 'week', 'used_percent': 60, "
                  "'resets_at': '2026-10-05T22:00:00.093Z'}]}]; "
                  "print(chr(10).join(u.dashboard(u.summarize(p, now, {}), u.accounts(p), now, now, color=True)))"
                  % str(BIN))
        result = subprocess.run([SYSTEM_PYTHON, "-c", script], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Codex", result.stdout)
        self.assertIn("\x1b[31m⚠ 이 속도면", result.stdout)


if __name__ == "__main__":
    unittest.main()
