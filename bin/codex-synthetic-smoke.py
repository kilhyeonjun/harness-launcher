#!/usr/bin/env python3
"""Send one bounded metadata-only Codex smoke event to the launcher Collector."""
import http.client
import json
import re
import secrets
import sys
import time

EVENT = "codex.synthetic_smoke"
VERIFICATION_EVENT = "codex.instrumentation_verified"
ENDPOINT = "http://127.0.0.1:4318"
PROFILE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")


def _attribute(key, value):
    return {"key": key, "value": {"stringValue": value}}


def _payload(profile, marker):
    timestamp = str(time.time_ns())
    return {
        "resourceLogs": [{
            "resource": {"attributes": [
                _attribute("service.name", "harness-agent"),
                _attribute("obs.runtime", "codex"),
                _attribute("obs.profile", profile),
            ]},
            "scopeLogs": [{"logRecords": [{
                "timeUnixNano": timestamp,
                "body": {"stringValue": EVENT},
                "attributes": [
                    _attribute("status", "observed"),
                    _attribute("session.id", marker),
                ],
            }, {
                "timeUnixNano": timestamp,
                "body": {"stringValue": VERIFICATION_EVENT},
                "attributes": [_attribute("status", "ok")],
            }]}],
        }]
    }


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2 or not PROFILE.fullmatch(argv[0]) or argv[1] != ENDPOINT:
        print("usage: codex-synthetic-smoke.py <profile> http://127.0.0.1:4318", file=sys.stderr)
        return 2

    profile = argv[0]
    marker = secrets.token_hex(32)
    connection = http.client.HTTPConnection("127.0.0.1", 4318, timeout=0.75)
    delivery = "unconfirmed"
    try:
        connection.request(
            "POST", "/v1/logs",
            json.dumps(_payload(profile, marker), separators=(",", ":")),
            {"Content-Type": "application/json"},
        )
        response = connection.getresponse()
        response.read(1)
        if 200 <= response.status < 300:
            delivery = "accepted"
    except Exception:
        pass
    finally:
        connection.close()

    print(f"{EVENT} profile={profile} marker={marker} delivery={delivery}")
    return 0 if delivery == "accepted" else 1


if __name__ == "__main__":
    raise SystemExit(main())
