#!/usr/bin/env python3
"""Claude and Codex plan usage from herdr web ui, for herdr's tab bar and sidebar.

herdr web ui serves each plan's usage windows at /api/usage (read-only; it
caches providers for up to five minutes). Each window shows its burn pace
against an even spend (1.0× uses the window up exactly at its reset) and, when
the current rate runs out before the reset, the expected exhaustion time. The
rate is the slope over the last few hours of samples kept in the launcher's
state directory, or the window average while there is no such sample.

herdr strips escape sequences from status commands, so a provider's state is an
emoji: 🔴 runs out before the reset (or is used up), 🟡 ends the window at 85%
or more (or is at 80% now), 🟢 otherwise. Runs under /usr/bin/python3 (3.9)
because the herdr plugin imports it. See docs/terminal-runtimes.md.
"""

from contextlib import contextmanager
import datetime
import fcntl
import json
import os
import sys
import tempfile
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


def store_path():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "harness-launcher", "herdr-usage.json")


@contextmanager
def samples():
    """The sample store, locked against the tab bar and the plugin running together."""
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
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=FETCH_TIMEOUT) as response:
        providers = json.load(response).get("providers", [])
    return providers if isinstance(providers, list) else []


def parse_time(value):
    try:
        moment = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
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
    history = history if isinstance(history, list) else []
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


def describe(kind, used, reset, now, history):
    """One window: label, used %, pace (or None), exhaustion and reset times, severity."""
    window = {"label": KINDS.get(kind, kind), "used": used, "pace": None, "eta": None,
              "reset": parse_time(reset),
              "severity": RED if used >= 100 else YELLOW if used >= YELLOW_USED else GREEN}
    length = LENGTHS.get(kind)
    if window["reset"] is None or not length:
        return window
    left = (window["reset"] - now).total_seconds()
    elapsed = length - left
    if left <= 0 or elapsed < length * MIN_ELAPSED.get(kind, 0):
        return window
    rate = rate_per_second(history, now, used, elapsed)
    window["pace"] = rate * length / 100
    projected = used + rate * left
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
            if not isinstance(used, (int, float)):
                continue
            kind = raw.get("kind")
            reset = raw.get("resets_at") or ""
            series = store.setdefault("%s:%s" % (provider["id"], kind), {})
            windows.append(describe(kind, used, reset, now, record(series, now, used, reset)))
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


def badges(summary, now):
    """{provider id: sidebar text}: the provider's most pressing window, no reset time."""
    result = {}
    for provider, windows in summary:
        window = worst(windows)
        result[provider] = "%s %s" % (BADGES[window["severity"]], text(window, now, with_reset=False))
    return result


def current(now=None):
    """Summary of the live usage, with this reading added to the sample store."""
    now = now or datetime.datetime.now().astimezone()
    providers = fetch()
    with samples() as store:
        return summarize(providers, now, store), now


def main():
    try:
        summary, now = current()
        print(line(summary, now))
    except Exception:  # a status command prints one line and never a traceback
        print("usage n/a")
    return 0


if __name__ == "__main__":
    sys.exit(main())
