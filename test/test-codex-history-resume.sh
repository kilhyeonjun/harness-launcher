#!/usr/bin/env zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ID_ONE='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
ID_TWO='ffffffff-1111-4222-8333-444444444444'

cat > "$TMP/catalog.py" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1] == "restore":
    pathlib.Path(os.environ["RESTORE_LOG"]).write_text(" ".join(sys.argv[1:]))
    receipt = pathlib.Path(sys.argv[sys.argv.index("--receipt") + 1])
    receipt.write_text("{}\n")
    raise SystemExit(0)
if sys.argv[1] == "prepare":
    pathlib.Path(os.environ["PREPARE_LOG"]).write_text(" ".join(sys.argv[1:]))
    print(json.dumps({"native_id": sys.argv[sys.argv.index("--native-id") + 1], "snapshot_id": "1" * 64, "status": "snapshot"}))
    raise SystemExit(0)
print(json.dumps({"schema_version": 1, "entries": [
 {"native_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "home": "/retired/home", "source_root": "/fixture", "isolation_id": "11111111-2222-4333-8444-555555555555", "origin_runtime": "a" * 40, "snapshot_id": "1" * 64, "updated_at": "2026-10-10T01:00:00Z", "status": "snapshot", "reason": None, "source_local": True},
 {"native_id": "ffffffff-1111-4222-8333-444444444444", "home": "/live/home", "source_root": "/fixture", "isolation_id": "22222222-2222-4222-8222-222222222222", "origin_runtime": "b" * 40, "snapshot_id": None, "updated_at": "2026-10-10T02:00:00Z", "status": "live", "reason": None, "source_local": True}
]}))
PY
chmod +x "$TMP/catalog.py"

mkdir -p "$TMP/bin"
cp "$TMP/catalog.py" "$TMP/bin/codex-history.py"
export HARNESS_SESSION_STATE_HOME="$TMP/state"
source "$ROOT/bin/aliases.zsh"
typeset -g _HARNESS_LAUNCHER_BIN="$TMP/bin"

unset HARNESS_CODEX_HISTORY_NATIVE_ID HARNESS_CODEX_HISTORY_SNAPSHOT_ID HARNESS_CODEX_HISTORY_ORIGIN_RUNTIME HARNESS_CODEX_HISTORY_HOME HARNESS_CODEX_HISTORY_ORIGIN_ISOLATION
mkdir -p "$TMP/no-history-home"
_harness_launcher_codex_history_restore /fixture "$TMP/no-history-home" || { echo 'FAIL: ordinary Codex launches must skip history restore with no selection environment'; exit 1; }

export PREPARE_LOG="$TMP/prepare.log"
_harness_launcher_codex_history_prepare /fixture "$ID_TWO" >/dev/null
grep -Fq -- "--native-id $ID_TWO" "$TMP/prepare.log" || { echo 'FAIL: snapshotless canonical selection must prepare through the trusted helper'; exit 1; }

_harness_launcher_codex_history_lease_acquire "$ID_ONE"
[[ -f "$TMP/state/native-history/leases/$ID_ONE.lock" ]] || { echo 'FAIL: selected native UUID must receive a private logical lease'; exit 1; }
if ROOT="$ROOT" HARNESS_SESSION_STATE_HOME="$TMP/state" NATIVE_ID="$ID_ONE" zsh -c 'source "$ROOT/bin/aliases.zsh"; _harness_launcher_codex_history_lease_acquire "$NATIVE_ID"'; then
  echo 'FAIL: a second process must not acquire the same native history lease'; exit 1
fi
_harness_launcher_codex_history_lease_release

python3 - "$ROOT" "$TMP/state" "$ID_ONE" <<'PY'
import fcntl, os, pathlib, sys
root, state, native = sys.argv[1:]
lock = pathlib.Path(state) / "native-history" / "leases" / (native + ".lock")
original = os.open(lock, os.O_RDWR)
fd = fcntl.fcntl(original, fcntl.F_DUPFD, 10)
os.close(original)
fcntl.lockf(fd, fcntl.LOCK_EX)
os.set_inheritable(fd, True)
env = dict(os.environ, HARNESS_CODEX_HISTORY_LEASE_FD=str(fd), NATIVE_ID=native, ROOT=root)
script = '''source "$ROOT/bin/aliases.zsh"
_harness_launcher_codex_history_lease_adopt "$NATIVE_ID" || exit 1
if HARNESS_SESSION_STATE_HOME="$HARNESS_SESSION_STATE_HOME" NATIVE_ID="$NATIVE_ID" ROOT="$ROOT" zsh -c 'source "$ROOT/bin/aliases.zsh"; _harness_launcher_codex_history_lease_acquire "$NATIVE_ID"'; then exit 1; fi
'''
os.execve("/bin/zsh", ["zsh", "-c", script], env)
PY
_harness_launcher_codex_history_lease_acquire "$ID_ONE" || { echo 'FAIL: inherited Entry lease was not released when its process exited'; exit 1; }
_harness_launcher_codex_history_lease_release

FAIL_HOME="$TMP/fail-home"
CONTENDER="$TMP/contender.zsh"
cat > "$CONTENDER" <<'EOF'
#!/usr/bin/env zsh
source "$ROOT/bin/aliases.zsh"
_harness_launcher_codex_history_lease_acquire "$NATIVE_ID"
EOF
chmod +x "$CONTENDER"
mkdir -p "$FAIL_HOME/bin" "$TMP/fail-harness/config"
cat > "$FAIL_HOME/bin/codex-history.py" <<'PY'
#!/usr/bin/env python3
import json, sys
if sys.argv[1] == "prepare": raise SystemExit(2)
source = sys.argv[sys.argv.index("--source-root") + 1]
print(json.dumps({"entries":[{"native_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","home":"/fixture/live","source_root":source,"isolation_id":None,"origin_runtime":None,"snapshot_id":None,"updated_at":"1","status":"canonical","reason":None,"source_local":True}]}))
PY
chmod +x "$FAIL_HOME/bin/codex-history.py"
print -r -- 'HARNESS_NAME="fixture"' 'HARNESS_PREFIX="fixture"' "HARNESS_SESSION_STATE_HOME=\"$TMP/state\"" > "$TMP/fail-harness/config/launcher.env"
if ROOT="$ROOT" CONTENDER="$CONTENDER" FAIL_HOME="$FAIL_HOME" HARNESS="$TMP/fail-harness" HARNESS_SESSION_STATE_HOME="$TMP/state" NATIVE_ID="$ID_ONE" zsh -c '
  source "$ROOT/bin/aliases.zsh"; _HARNESS_LAUNCHER_BIN="$FAIL_HOME/bin"
  _harness_launcher_run "$HARNESS" codex resume "$NATIVE_ID" >/dev/null 2>&1 && exit 1
  zsh "$CONTENDER"
'; then :; else
  echo 'FAIL: failed preparation retained the native UUID lease'; exit 1
fi
_harness_launcher_codex_history_lease_release

RECAT_HOME="$TMP/recatalog-home"
mkdir -p "$RECAT_HOME/bin" "$TMP/recatalog-harness/config"
cat > "$RECAT_HOME/bin/codex-history.py" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
counter = pathlib.Path(os.environ["RECAT_COUNTER"])
if sys.argv[1] == "prepare":
    print(json.dumps({"snapshot_id": "1" * 64}))
    raise SystemExit(0)
seen = int(counter.read_text() if counter.exists() else "0")
counter.write_text(str(seen + 1))
if seen:
    print(json.dumps({"entries": []}))
    raise SystemExit(0)
source = sys.argv[sys.argv.index("--source-root") + 1]
print(json.dumps({"entries":[{"native_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","home":"/fixture/live","source_root":source,"isolation_id":None,"origin_runtime":None,"snapshot_id":None,"updated_at":"1","status":"canonical","reason":None,"source_local":True}]}))
PY
chmod +x "$RECAT_HOME/bin/codex-history.py"
print -r -- 'HARNESS_NAME="fixture"' 'HARNESS_PREFIX="fixture"' "HARNESS_SESSION_STATE_HOME=\"$TMP/state\"" > "$TMP/recatalog-harness/config/launcher.env"
if ROOT="$ROOT" CONTENDER="$CONTENDER" RECAT_HOME="$RECAT_HOME" HARNESS="$TMP/recatalog-harness" HARNESS_SESSION_STATE_HOME="$TMP/state" RECAT_COUNTER="$TMP/recatalog-count" NATIVE_ID="$ID_ONE" zsh -c '
  source "$ROOT/bin/aliases.zsh"; _HARNESS_LAUNCHER_BIN="$RECAT_HOME/bin"
  _harness_launcher_run "$HARNESS" codex resume "$NATIVE_ID" >/dev/null 2>&1 && exit 1
  [[ "$(<$RECAT_COUNTER)" == 2 ]] || exit 1
  zsh "$CONTENDER"
'; then :; else
  echo 'FAIL: recatalog failure retained the native UUID lease'; exit 1
fi
_harness_launcher_codex_history_lease_release

list="$(_harness_launcher_codex_history_select /fixture list)"
[[ "$list" == *"$ID_ONE"* && "$list" == *"$ID_TWO"* ]] || { echo 'FAIL: --list must return the local catalog JSON'; exit 1; }

exact="$(_harness_launcher_codex_history_select /fixture "$ID_ONE")"
[[ "$exact" == *$'native_id='"$ID_ONE"* && "$exact" == *$'snapshot_id='* ]] || { echo 'FAIL: exact native UUID must select its archived catalog entry'; exit 1; }

if _harness_launcher_codex_history_select /fixture continue </dev/null >/dev/null 2>&1; then
  echo 'FAIL: noninteractive continue must require an exact ID when catalog is ambiguous'; exit 1
fi

SESSION_ID='33333333-3333-4333-8333-333333333333'
mkdir -p "$TMP/state/sessions/$SESSION_ID" "$TMP/generated-home"
print -r -- generated > "$TMP/generated-home/config.toml"
export RESTORE_LOG="$TMP/restore.log"
export HARNESS_SESSION_ID="$SESSION_ID"
export HARNESS_CODEX_HISTORY_NATIVE_ID="$ID_ONE"
export HARNESS_CODEX_HISTORY_SNAPSHOT_ID="$(printf '1%.0s' {1..64})"
export HARNESS_CODEX_HISTORY_ORIGIN_RUNTIME="$(printf 'a%.0s' {1..40})"
export HARNESS_CODEX_HISTORY_HOME=/wrong-history-home
if _harness_launcher_codex_history_restore /fixture "$TMP/generated-home" >/dev/null 2>&1; then
  echo 'FAIL: restore must reject environment provenance that disagrees with the source-local catalog'; exit 1
fi
unset HARNESS_CODEX_HISTORY_HOME
_harness_launcher_codex_history_restore /fixture "$TMP/generated-home"
[[ -f "$TMP/state/sessions/$SESSION_ID/native-history-restore.json" ]] || { echo 'FAIL: restore must record private session provenance'; exit 1; }
grep -Fq -- "--native-id $ID_ONE" "$TMP/restore.log" || { echo 'FAIL: restore must preserve native origin id'; exit 1; }
grep -Fq -- "--origin-runtime $(printf 'a%.0s' {1..40})" "$TMP/restore.log" || { echo 'FAIL: restore must preserve origin runtime'; exit 1; }

[[ "$(_harness_launcher_codex_history_request codex resume --list)" == list ]] || { echo 'FAIL: generic resume --list must be recognized before a native launch'; exit 1; }
[[ "$(_harness_launcher_codex_history_request codex continue)" == continue ]] || { echo 'FAIL: continue must use the same catalog selection route'; exit 1; }

HARNESS="$TMP/harness"
mkdir -p "$HARNESS/config"
print -r -- 'HARNESS_NAME="fixture"' 'HARNESS_PREFIX="fixture"' > "$HARNESS/config/launcher.env"
_harness_launcher_run "$HARNESS" codex resume --list > "$TMP/list.json"
grep -Fq "$ID_ONE" "$TMP/list.json" || { echo 'FAIL: public codex resume --list must return catalog entries'; exit 1; }

unset HARNESS_CODEX_HISTORY_NATIVE_ID HARNESS_CODEX_HISTORY_SNAPSHOT_ID HARNESS_CODEX_HISTORY_ORIGIN_RUNTIME HARNESS_CODEX_HISTORY_HOME HARNESS_CODEX_HISTORY_ORIGIN_ISOLATION
cat > "$TMP/codex" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" > "$CODEX_CALL_LOG"
EOF
chmod +x "$TMP/codex"
PATH="$TMP:$PATH" CODEX_CALL_LOG="$TMP/codex-call.log" _harness_launcher_run "$HARNESS" codex --passthrough --version
grep -Fq -- '--version' "$TMP/codex-call.log" || { echo 'FAIL: ordinary Codex launch must proceed when no history selection exists'; exit 1; }

echo 'PASS: durable Codex resume catalog selection is source-local and noninteractive-safe'
