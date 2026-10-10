#!/usr/bin/env bash
# Real GC must not erase unsupported Native artifacts or an unverified old tomb.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
SOURCE="$TMP/source"; STATE="$TMP/state"
mkdir -p "$SOURCE/config"
git -C "$SOURCE" init -q -b main
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" config user.name test
printf '%s\n' 'HARNESS_NAME="test"' 'HARNESS_PREFIX="test"' > "$SOURCE/config/launcher.env"
git -C "$SOURCE" add config/launcher.env
git -C "$SOURCE" commit -qm fixture
out="$(HARNESS_SESSION_STATE_HOME="$STATE" "$ROOT/bin/session-isolation.sh" create "$SOURCE")"
id="$(printf '%s\n' "$out" | sed -n 's/^HARNESS_SESSION_ID=//p')"
work="$(printf '%s\n' "$out" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
mkdir -p "$work/.harness/codex/sessions/2026/10/10"
printf '%s\n' 'retained native conversation sentinel' > "$work/.harness/codex/sessions/2026/10/10/rollout-sentinel.jsonl"
printf '%s\n' 'unknown must hold retirement' > "$work/.harness/codex/future-native-format.bin"
HARNESS_SESSION_STATE_HOME="$STATE" "$ROOT/bin/session-isolation.sh" transition "$id" CLOSED
HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_RETENTION_SECONDS=0 "$ROOT/bin/session-isolation.sh" gc
[[ -f "$work/.harness/codex/future-native-format.bin" ]] || { echo 'FAIL: GC erased Native history before verified archive/restore'; exit 1; }
tomb="$STATE/worktrees/.retired-22222222-2222-4222-8222-222222222222-42"
mkdir -p "$tomb/.harness/codex/sessions"
printf '%s\n' 'unverified recovery sentinel' > "$tomb/.harness/codex/sessions/native.jsonl"
HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_RETENTION_SECONDS=0 "$ROOT/bin/session-isolation.sh" gc
[[ -f "$tomb/.harness/codex/sessions/native.jsonl" ]] || { echo 'FAIL: GC deleted an unverified old tomb'; exit 1; }
echo 'PASS: unknown Native data and unverified old tomb retained by real GC'
