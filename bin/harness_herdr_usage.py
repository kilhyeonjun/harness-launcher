#!/usr/bin/env python3
"""Claude and Codex plan usage from herdr web ui: herdr's tab bar line and a popup board.

herdr web ui serves each plan's usage windows at /api/usage (read-only; it
caches providers for up to five minutes). Each window shows its burn pace
against an even spend (1.0× uses the window up exactly at its reset) and, when
the current rate runs out before the reset, the expected exhaustion time. The
rate is the slope over the last few hours of samples kept in the launcher's
state directory, or the window average while there is no such sample.

herdr strips escape sequences from status commands, so a provider's state is an
emoji: 🔴 runs out before the reset (or is used up), 🟡 ends the window at 85%
or more (or is at 80% now), 🟢 otherwise. `--watch` draws the same numbers as a
board (bars, reset and exhaustion times) for a herdr popup. Runs under
/usr/bin/python3 (3.9). See docs/herdr-web-ui.md.
"""

from contextlib import contextmanager
import datetime
import fcntl
import json
import math
import os
import re
import select
import shutil
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness_herdr_web as web  # noqa: E402

NAMES = {"claude": "Claude", "codex": "Codex"}
KINDS = {"session": "5h", "week": "7d", "month": "mo"}
LENGTHS = {"session": 5 * 3600, "week": 7 * 86400}
# Skip the pace until this share of the window has elapsed; early ratios are noise.
MIN_ELAPSED = {"session": 0.2, "week": 0.05}
WEEKDAYS = "월화수목금토일"
GREEN, YELLOW, RED = 0, 1, 2
BADGES = {GREEN: "🟢", YELLOW: "🟡", RED: "🔴"}
YELLOW_PROJECTION = 85
YELLOW_USED = 80
SLOPE_MAX_AGE = 3 * 3600
SLOPE_MIN_AGE = 30 * 60
SAMPLE_SECONDS = 5 * 60
KEEP_SECONDS = 6 * 3600
RESET_TOLERANCE = 10 * 60
FETCH_TIMEOUT = 10
BAR_CELLS = (8, 30)
WATCH_SECONDS = 60
STYLES = {"bold": "1", "dim": "2", GREEN: "32", YELLOW: "33", RED: "31"}
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
QUIT_KEYS = (b"q", b"Q", b"\x03", "ㅂ".encode(), "ㅃ".encode())  # ㅂ: q under the Korean input method
REFRESH_KEYS = (b"r", b"R", "ㄱ".encode(), "ㄲ".encode())


def store_path():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "harness-launcher", "herdr-usage.json")


@contextmanager
def samples():
    """The sample store, locked against the tab bar and the popup running together."""
    path = store_path()
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path, encoding="utf-8") as handle:
                store = json.load(handle)
        except (OSError, ValueError):
            store = {}
        if not isinstance(store, dict):
            store = {}
        yield store
        fd, temporary = tempfile.mkstemp(prefix=".herdr-usage.", dir=os.path.dirname(path))
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(store, handle)
        os.replace(temporary, path)


def fetch():
    """Providers from the local herdr web ui, authenticated with its token."""
    env, dot = web.files(web.config_dir())
    values = web.effective(env, dot)
    token = values.get(web.TOKEN_KEY, "")
    if not token:
        raise web.Refused("herdr web ui has no token")
    try:
        port = int(values.get("PORT", web.DEFAULT_PORT))
    except ValueError:
        port = web.DEFAULT_PORT
    request = urllib.request.Request(
        "http://%s:%d/api/usage" % (web.LOOPBACK, port),
        headers={"authorization": "Bearer " + token, "x-herdr-machine": "1"})
    # urllib would carry the Authorization header along a redirect, to any host.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=FETCH_TIMEOUT) as response:
        providers = json.load(response).get("providers", [])
    return providers if isinstance(providers, list) else []


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # urllib raises HTTPError for the 3xx instead


# Python 3.9's fromisoformat takes only 3 or 6 fraction digits and no "Z".
FRACTION = re.compile(r"\.(\d+)")


def parse_time(value):
    if not isinstance(value, str):
        return None
    value = FRACTION.sub(lambda match: "." + (match.group(1) + "000000")[:6], value.replace("Z", "+00:00"), 1)
    try:
        moment = datetime.datetime.fromisoformat(value)
    except ValueError:
        return None
    return moment if moment.tzinfo else None


def when(moment, now, prefix):
    local = moment.astimezone(now.tzinfo)
    days = (local.date() - now.date()).days
    if days == 0:
        return prefix + local.strftime("%H:%M")
    if days < 7:
        return prefix + WEEKDAYS[local.weekday()] + local.strftime("%H") + "시"
    return "%s%d/%d" % (prefix, local.month, local.day)


def record(series, now, used, reset):
    """Add the current reading to one window's history and return the history."""
    stamp = now.timestamp()
    previous = parse_time(series.get("reset", ""))
    current = parse_time(reset)
    history = series.get("samples")
    history = [sample for sample in (history if isinstance(history, list) else [])
               if isinstance(sample, list) and len(sample) == 2
               and all(isinstance(value, (int, float)) for value in sample)]
    new_window = (previous is None or current is None
                  or abs((current - previous).total_seconds()) > RESET_TOLERANCE)
    if new_window or (history and used < history[-1][1]):
        history = []
    history = [sample for sample in history if stamp - sample[0] <= KEEP_SECONDS]
    if not history or stamp - history[-1][0] >= SAMPLE_SECONDS:
        history.append([stamp, used])
    series["reset"] = reset
    series["samples"] = history
    return history


def rate_per_second(history, now, used, elapsed):
    stamp = now.timestamp()
    for taken, value in history:
        if SLOPE_MIN_AGE <= stamp - taken <= SLOPE_MAX_AGE:
            return max(used - value, 0) / (stamp - taken)
    return used / elapsed


def describe(kind, used, reset, now, history, scope=None):
    """One window: label, used %, pace (or None), exhaustion and reset times, the share
    of the window elapsed and the projected use at the reset (or None), severity."""
    label = KINDS.get(kind, kind)
    window = {"label": "%s %s" % (label, scope) if scope else label, "used": used, "pace": None,
              "eta": None, "reset": parse_time(reset), "elapsed": None, "projected": None,
              "severity": RED if used >= 100 else YELLOW if used >= YELLOW_USED else GREEN}
    length = LENGTHS.get(kind)
    if window["reset"] is None or not length:
        return window
    left = (window["reset"] - now).total_seconds()
    elapsed = length - left
    window["elapsed"] = min(max(elapsed / length, 0.0), 1.0)
    if left <= 0 or elapsed < length * MIN_ELAPSED.get(kind, 0):
        return window
    rate = rate_per_second(history, now, used, elapsed)
    window["pace"] = rate * length / 100
    projected = window["projected"] = used + rate * left
    if used >= 100:
        window["severity"] = RED
    elif projected > 100:
        window["severity"] = RED
        window["eta"] = now + datetime.timedelta(seconds=(100 - used) / rate)
    elif projected >= YELLOW_PROJECTION:
        window["severity"] = YELLOW
    return window


def text(window, now, with_reset=True):
    parts = ["%s %s%%" % (window["label"], window["used"])]
    if window["pace"] is not None:
        parts.append("%.1f×" % window["pace"])
    if window["eta"] is not None:
        parts.append(when(window["eta"], now, "→"))
    if with_reset and window["reset"] is not None:
        parts.append(when(window["reset"], now, "↻"))
    return " ".join(parts)


def summarize(providers, now, store):
    """[(provider id, [window, ...])] for Claude and Codex, recording samples in `store`."""
    summary = []
    for provider in providers:
        if not isinstance(provider, dict) or provider.get("id") not in NAMES or provider.get("problem"):
            continue
        windows = []
        for raw in provider.get("windows") or []:
            used = raw.get("used_percent") if isinstance(raw, dict) else None
            if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used):
                continue
            kind = clean(str(raw.get("kind")))
            scope = clean(raw.get("scope")) if isinstance(raw.get("scope"), str) else None
            reset = raw.get("resets_at") or ""
            key = ":".join([provider["id"], kind] + ([scope] if scope else []))
            if not isinstance(store.get(key), dict):
                store[key] = {}
            series = store[key]
            windows.append(describe(kind, used, reset, now, record(series, now, used, reset), scope))
        if windows:
            summary.append((provider["id"], windows))
    return summary


def worst(windows):
    return max(windows, key=lambda window: (window["severity"], window["used"]))


def line(summary, now):
    """Tab bar text: every window of every provider."""
    parts = []
    for provider, windows in summary:
        parts.append("%s %s %s" % (BADGES[worst(windows)["severity"]], NAMES[provider],
                                   " · ".join(text(window, now) for window in windows)))
    return " │ ".join(parts) or "usage —"


def clean(value):
    """Server text made safe for a terminal: a string without control characters, or None."""
    return None if value is None else CONTROL.sub("", value if isinstance(value, str) else str(value))


def accounts(providers):
    """{provider id: {plan, problem}} for Claude and Codex; a later entry wins."""
    return {provider["id"]: {"plan": clean(provider.get("plan")), "problem": clean(provider.get("problem"))}
            for provider in providers if isinstance(provider, dict) and provider.get("id") in NAMES}


def until(seconds):
    """Time left in its two largest units, rounded down: '1일 10시간 후'."""
    minutes = max(int(seconds // 60), 1)
    days, hours, minutes = minutes // 1440, minutes // 60 % 24, minutes % 60
    if days:
        return "%d일 %d시간 후" % (days, hours) if hours else "%d일 후" % days
    if hours:
        return "%d시간 %d분 후" % (hours, minutes) if minutes else "%d시간 후" % hours
    return "%d분 후" % minutes


def left(moment, now):
    seconds = (moment - now).total_seconds()
    return until(seconds) if seconds > 0 else "지남"


def clock(moment, now):
    local = moment.astimezone(now.tzinfo)
    days = (local.date() - now.date()).days
    if days == 0:
        return local.strftime("%H:%M")
    if days == 1:
        return local.strftime("내일 %H:%M")
    if 1 < days < 7:
        return WEEKDAYS[local.weekday()] + local.strftime(" %H:%M")
    return "%d/%d %s" % (local.month, local.day, local.strftime("%H:%M"))


def bar(used, elapsed, width, paint=lambda part, cells: cells):
    """`width` cells: █ for the used share, ░ for the rest, │ where an even spend
    would be now. `paint(part, cells)` styles the fill, rest and tick parts."""
    filled = min(int(max(used, 0) * width / 100.0 + 0.5), width)
    cells = ["fill"] * filled + ["rest"] * (width - filled)
    if elapsed is not None:
        cells[min(int(elapsed * width), width - 1)] = "tick"
    glyphs = {"fill": "█", "rest": "░", "tick": "│"}
    runs = []
    for part in cells:
        if runs and runs[-1][0] == part:
            runs[-1][1] += 1
        else:
            runs.append([part, 1])
    return "".join(paint(part, glyphs[part] * count) for part, count in runs)


def cells(value):
    return sum(2 if unicodedata.east_asian_width(char) in "WF" else 1 for char in value)


def reason(error):
    """A failed reading in a few words; never the request or its token."""
    if isinstance(error, urllib.error.HTTPError):
        return "HTTP %d" % error.code
    if isinstance(error, web.Refused):
        return str(error)
    if isinstance(error, (urllib.error.URLError, OSError)):
        return "web ui 연결 안 됨"
    if isinstance(error, ValueError):
        return "응답 형식 오류"
    return type(error).__name__


def dashboard(summary, plans, now, fetched, columns=80, color=False, error=None, keys=True,
              interval=WATCH_SECONDS):
    """The popup board as lines: `summary` read at `fetched`, relative times from `now`.
    `summary` is None before the first reading."""
    def paint(value, *styles):
        codes = ";".join(STYLES[style] for style in styles)
        return "\x1b[%sm%s\x1b[0m" % (codes, value) if color and value and codes else value

    title = " " + paint("플랜 사용량", "bold")
    if fetched is not None:
        title += paint(" · %s 기준" % fetched.astimezone(now.tzinfo).strftime("%H:%M"), "dim")
    if error and summary is not None:
        title += paint(" · ⚠ 갱신 실패: " + error, YELLOW)
    lines = [title, ""]
    if summary is None:
        lines += [" 사용량을 불러오지 못했습니다: " + (error or "알 수 없음"),
                  " 'harness-herdr-web check'로 herdr web ui를 확인하세요."]
    else:
        readings = dict(summary)
        labels = max([cells(window["label"]) for _, windows in summary for window in windows] or [2])
        width = min(max(columns - 4 - labels - 47, BAR_CELLS[0]), BAR_CELLS[1])
        shown = len(lines)
        for provider in NAMES:
            plan = (plans.get(provider) or {}).get("plan")
            problem = (plans.get(provider) or {}).get("problem")
            if provider in readings:
                windows = readings[provider]
                head = " %s %s" % (BADGES[worst(windows)["severity"]], paint(NAMES[provider], "bold"))
                lines.append(head + ("  " + paint(plan, "dim") if plan else ""))
                for window in windows:
                    lines += board_rows(window, now, labels, width, paint)
            elif problem:
                lines.append(" ⚪ %s  %s" % (paint(NAMES[provider], "bold"), paint("확인 불가: " + problem, "dim")))
            else:
                continue
            lines.append("")
        if len(lines) == shown:
            lines.append(" 표시할 사용량이 없습니다.")
        else:
            lines[-1:] = ["", paint(" █ 사용량 · │ 경과 시간 · 1.0× = 초기화 때 딱 맞게 다 씀", "dim")]
    if keys:
        lines.append(paint(" q 닫기 · r 새로고침 · %d초마다 갱신" % interval, "dim"))
    return lines


def board_rows(window, now, labels, width, paint):
    severity = window["severity"]
    styles = {"fill": (severity,), "rest": ("dim",), "tick": ("bold",)}
    pace = window["pace"]
    row = "    %s  %s  %3d%%  %s" % (
        window["label"] + " " * (labels - cells(window["label"])),
        bar(window["used"], window["elapsed"], width, lambda part, value: paint(value, *styles[part])),
        window["used"], " " * 5 if pace is None else "%4.1f×" % pace if pace < 99.95 else " >99×")
    if window["reset"] is not None:
        row += "  " + paint("↻ %s · %s" % (clock(window["reset"], now), left(window["reset"], now)), "dim")
    rows = [row]
    if window["used"] >= 100:
        rows.append("        " + paint("다 씀 · 초기화까지 대기", RED))
    elif window["eta"] is not None:
        rows.append("        " + paint("⚠ 이 속도면 %s 소진 · %s" % (
            clock(window["eta"], now), left(window["eta"], now)), RED))
    elif severity == YELLOW and window["projected"] is not None:
        rows.append("        " + paint("이 속도면 초기화 때 약 %d%%" % min(window["projected"], 100), YELLOW))
    return rows


def current(now=None):
    """(summary, plans, now) of the live usage, with this reading added to the sample store."""
    now = now or datetime.datetime.now().astimezone()
    providers = fetch()
    with samples() as store:
        return summarize(providers, now, store), accounts(providers), now


class Board:
    """The last reading for `--watch`, kept across failed refreshes."""

    def __init__(self, interval):
        self.interval = interval
        self.summary = None
        self.plans = {}
        self.fetched = None
        self.error = None

    def refresh(self):
        try:
            self.summary, self.plans, self.fetched = current()
            self.error = None
        except Exception as error:  # noqa: BLE001 - the board shows why
            self.error = reason(error)

    def lines(self, columns, color, keys):
        return dashboard(self.summary, self.plans, datetime.datetime.now().astimezone(), self.fetched,
                         columns, color, self.error, keys, self.interval)


def watch(interval=WATCH_SECONDS):
    """Draw the board, redraw every `interval` seconds or on r, close on q, Esc or ^C.
    Without a terminal on both ends, print it once."""
    board = Board(interval)
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        board.refresh()
        print("\n".join(board.lines(shutil.get_terminal_size().columns, False, False)))
        return 0
    import signal
    import termios
    import tty
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    out = sys.stdout

    def leave(signum, frame):
        raise SystemExit(128 + signum)  # through `finally`, which restores the terminal

    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, leave)
    try:
        tty.setcbreak(fd, termios.TCSANOW)  # keep a key typed before the first draw
        out.write("\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J 플랜 사용량\n\n 불러오는 중…")
        out.flush()
        board.refresh()
        due = time.monotonic() + interval
        drawn = None
        while True:
            size = os.get_terminal_size(out.fileno())
            if drawn != (size, board.fetched, board.error):
                drawn = (size, board.fetched, board.error)
                out.write("\x1b[H\x1b[2J" + "\n".join(board.lines(size.columns, True, True)))
                out.flush()
            if not select.select([fd], [], [], max(min(due - time.monotonic(), 1.0), 0))[0]:
                if time.monotonic() >= due:
                    board.refresh()
                    due = time.monotonic() + interval
                    drawn = None
                continue
            keys = os.read(fd, 64)
            if not keys or keys == b"\x1b":
                return 0
            if keys.startswith(b"\x1b"):
                continue  # an arrow or function key
            if any(key in keys for key in QUIT_KEYS):
                return 0
            if any(key in keys for key in REFRESH_KEYS):
                board.refresh()
                due = time.monotonic() + interval
                drawn = None
    except KeyboardInterrupt:
        return 0
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, saved)  # never wait on a reader that left
        try:
            out.write("\x1b[?25h\x1b[?1049l")
            out.flush()
        except OSError:
            pass


def main(argv=None):
    if "--watch" in (sys.argv[1:] if argv is None else argv):
        return watch()
    try:
        summary, _, now = current()
        print(line(summary, now))
    except Exception:  # a status command prints one line and never a traceback
        print("usage n/a")
    return 0


if __name__ == "__main__":
    sys.exit(main())
