#!/usr/bin/env bash
# Regression coverage for opt-in isolated harness sessions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISOLATION="$ROOT/bin/session-isolation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SOURCE="$TMP/source"
STATE="$TMP/state"
mkdir -p "$SOURCE/config/.local" "$SOURCE/projects/product" "$SOURCE/core/bin"
git -C "$SOURCE" init -q -b main
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" config user.name test
printf '%s\n' 'HARNESS_NAME="test"' 'HARNESS_PREFIX="test"' > "$SOURCE/config/launcher.env"
printf '%s\n' 'tracked' > "$SOURCE/tracked.txt"
printf '%s\n' one two three > "$SOURCE/merge.txt"
printf '%s\n' rename-me > "$SOURCE/rename-old.txt"
printf '%s\n' 'secret' > "$SOURCE/config/.local/secret.env"
cat > "$SOURCE/core/bin/auto-deliver.sh" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *' --staged-only '* && " $* " == *' --dry-run '* && " $* " == *' --no-push '* ]] || exit 91
[[ "${HARNESS_SESSION_TEST_VERIFY_FAIL:-0}" != 1 ]] || exit 92
[[ -z "${HARNESS_TEST_VERIFIER:-}" ]] || "$HARNESS_TEST_VERIFIER"
EOF
chmod +x "$SOURCE/core/bin/auto-deliver.sh"
git -C "$SOURCE" add config/launcher.env tracked.txt merge.txt rename-old.txt core/bin/auto-deliver.sh
git -C "$SOURCE" commit -qm initial
printf '%s\n' 'canonical dirty' > "$SOURCE/tracked.txt"

create() {
  HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" create "$SOURCE"
}

first="$(create)"
second="$(create)"
first_root="$(printf '%s\n' "$first" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
second_root="$(printf '%s\n' "$second" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
first_id="$(printf '%s\n' "$first" | sed -n 's/^HARNESS_SESSION_ID=//p')"
second_id="$(printf '%s\n' "$second" | sed -n 's/^HARNESS_SESSION_ID=//p')"

[[ -n "$first_id" && "$first_root" != "$second_root" ]] || { echo 'FAIL: isolated sessions must have separate roots'; exit 1; }
[[ "$(git -C "$first_root" rev-parse --absolute-git-dir)" != "$(git -C "$SOURCE" rev-parse --absolute-git-dir)" ]] || { echo 'FAIL: session must not share canonical refs or index'; exit 1; }
[[ -z "$(git -C "$first_root" remote)" ]] || { echo 'FAIL: session workspace must not retain a canonical push transport'; exit 1; }
source_main_before="$(git -C "$SOURCE" rev-parse main)"
git -C "$first_root" update-ref refs/heads/main HEAD
[[ "$(git -C "$SOURCE" rev-parse main)" == "$source_main_before" ]] || { echo 'FAIL: session ref writes must not move canonical main'; exit 1; }
[[ "$(<"$first_root/tracked.txt")" == tracked ]] || { echo 'FAIL: canonical dirty files must not be imported'; exit 1; }
[[ ! -e "$first_root/config/.local/secret.env" ]] || { echo 'FAIL: config/.local must not be copied'; exit 1; }
SOURCE_REAL="$(cd "$SOURCE" && pwd -P)"
[[ -L "$first_root/projects" && "$(readlink "$first_root/projects")" == "$SOURCE_REAL/projects" ]] || { echo 'FAIL: projects access must be preserved safely'; exit 1; }
[[ -f "$STATE/sessions/$first_id/journal" ]] || { echo 'FAIL: create must write an OPEN journal'; exit 1; }
grep -qx 'state=OPEN' "$STATE/sessions/$first_id/journal" || { echo 'FAIL: journal must start OPEN'; exit 1; }

HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" transition "$second_id" SUBMITTED submit-one
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" transition "$second_id" SUBMITTED submit-one
grep -qx 'state=SUBMITTED' "$STATE/sessions/$second_id/journal" || { echo 'FAIL: idempotent submit must retain SUBMITTED'; exit 1; }
if HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" resume "$SOURCE" "$second_id" 2>"$TMP/submitted-resume.err"; then
  echo 'FAIL: SUBMITTED sessions must not reopen'; exit 1
fi
grep -q 'cannot resume SUBMITTED session; run harness-session integrate or recover' "$TMP/submitted-resume.err" || { echo 'FAIL: SUBMITTED rejection must name the recovery action'; exit 1; }

printf '%s\n' dirty > "$first_root/new.txt"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" exit "$first_id"
grep -qx 'state=ABANDONED' "$STATE/sessions/$first_id/journal" || { echo 'FAIL: dirty exit must be ABANDONED'; exit 1; }
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" recover "$first_id" | grep -qx "HARNESS_SESSION_ROOT=$first_root" || { echo 'FAIL: abandoned session must be recoverable'; exit 1; }

stale="$(create)"
stale_id="$(printf '%s\n' "$stale" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf '%s\n' '2000-01-01T00:00:00Z' > "$STATE/sessions/$stale_id/heartbeat"
stale_list="$(HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_STALE_SECONDS=1 "$ISOLATION" list)"
printf '%s\n' "$stale_list" | grep -qx "$stale_id ABANDONED" || { printf '%s\n' "$stale_list"; echo 'FAIL: stale OPEN session must become ABANDONED in list'; exit 1; }
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" recover "$stale_id" | grep -q '^HARNESS_SESSION_ROOT=' || { echo 'FAIL: stale abandoned session must retain workspace'; exit 1; }

REMOTE="$TMP/remote.git"
git init --bare -q "$REMOTE"
git -C "$SOURCE" add tracked.txt && git -C "$SOURCE" commit -qm source-clean
git -C "$SOURCE" remote add origin "$REMOTE"
git -C "$SOURCE" push -q -u origin main
clean_close="$(create)"; clean_close_id="$(printf '%s\n' "$clean_close" | sed -n 's/^HARNESS_SESSION_ID=//p')"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" close "$clean_close_id"
grep -qx state=CLOSED "$STATE/sessions/$clean_close_id/journal" || { echo 'FAIL: closing a clean session must terminate it without submission'; exit 1; }
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" resume "$SOURCE" "$clean_close_id" >/dev/null
grep -qx state=OPEN "$STATE/sessions/$clean_close_id/journal" || { echo 'FAIL: retained CLOSED sessions must reopen with the same UUID'; exit 1; }
clean_exit="$(create)"; clean_exit_id="$(printf '%s\n' "$clean_exit" | sed -n 's/^HARNESS_SESSION_ID=//p')"
clean_exit_root="$(printf '%s\n' "$clean_exit" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" exit "$clean_exit_id"
grep -qx state=CLOSED "$STATE/sessions/$clean_exit_id/journal" || { echo 'FAIL: a clean normal exit must not remain OPEN until stale'; exit 1; }
grep -qx 1 "$STATE/sessions/$clean_exit_id/lease-v1" || { echo 'FAIL: new sessions must opt into the runtime lease contract'; exit 1; }

tampered_root="$(create)"; tampered_root_id="$(printf '%s\n' "$tampered_root" | sed -n 's/^HARNESS_SESSION_ID=//p')"; tampered_root_path="$(printf '%s\n' "$tampered_root" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" exit "$tampered_root_id"
printf '%s\n' "$SOURCE" > "$STATE/sessions/$tampered_root_id/session-root"
if HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" resume "$SOURCE" "$tampered_root_id"; then echo 'FAIL: resume must reject a journal-controlled canonical root'; exit 1; fi
grep -qx state=CLOSED "$STATE/sessions/$tampered_root_id/journal" || { echo 'FAIL: rejected tampered root must not reopen the journal'; exit 1; }
printf '%s\n' "$tampered_root_path" > "$STATE/sessions/$tampered_root_id/session-root"
if HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" resume "$SOURCE" '../not-a-uuid'; then echo 'FAIL: resume must reject path traversal IDs'; exit 1; fi

# Terminal roots survive the grace period, then GC retires only an exact,
# unlocked launcher-owned direct child. Journals remain as audit evidence.
HARNESS_SESSION_RETENTION_SECONDS=86400 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -d "$clean_exit_root" ]] || { echo 'FAIL: GC must retain a fresh CLOSED root during grace'; exit 1; }
python3 - "$STATE/sessions/$clean_exit_id/journal" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text().splitlines()
p.write_text("\n".join("heartbeat=2000-01-01T00:00:00Z" if line.startswith("heartbeat=") else line for line in lines) + "\n")
PY
exec 8>"$STATE/sessions/$clean_exit_id/runtime.lock"
/usr/bin/lockf -s -t 0 8
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -d "$clean_exit_root" ]] || { echo 'FAIL: GC must retain a terminal root while its runtime lease is held'; exit 1; }
exec 8>&-
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ ! -e "$clean_exit_root" && -f "$STATE/sessions/$clean_exit_id/journal" ]] || { echo 'FAIL: GC must retire an expired unlocked CLOSED root and retain its journal'; exit 1; }

legacy="$(create)"; legacy_id="$(printf '%s\n' "$legacy" | sed -n 's/^HARNESS_SESSION_ID=//p')"; legacy_root="$(printf '%s\n' "$legacy" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" exit "$legacy_id"
printf 'legacy\n' > "$STATE/sessions/$legacy_id/lease-v1"
python3 - "$STATE/sessions/$legacy_id/journal" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace(next(line for line in p.read_text().splitlines() if line.startswith("heartbeat=")), "heartbeat=2000-01-01T00:00:00Z"))
PY
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -d "$legacy_root" ]] || { echo 'FAIL: GC must retain records outside the exact lease-v1 contract'; exit 1; }
suffix_tomb="$STATE/worktrees/.retired-$legacy_id-1-userdata"
exact_tomb="$STATE/worktrees/.retired-$legacy_id-1"
mkdir "$suffix_tomb" "$exact_tomb"; printf keep > "$suffix_tomb/sentinel"
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -f "$suffix_tomb/sentinel" ]] || { echo 'FAIL: tomb cleanup must reject a numeric prefix with arbitrary suffix'; exit 1; }
[[ ! -e "$exact_tomb" ]] || { echo 'FAIL: exact stale tombstones must be cleaned'; exit 1; }

malformed="$(create)"; malformed_id="$(printf '%s\n' "$malformed" | sed -n 's/^HARNESS_SESSION_ID=//p')"; malformed_root="$(printf '%s\n' "$malformed" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" exit "$malformed_id"
python3 - "$STATE/sessions/$malformed_id/journal" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
lines = p.read_text().splitlines()
lines = ["heartbeat=2000-01-01T00:00:00Z" if line.startswith("heartbeat=") else line for line in lines]
p.write_text("\n".join(lines + ["garbage=1"]) + "\n")
PY
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -d "$malformed_root" ]] || { echo 'FAIL: GC must retain a journal with unknown fields'; exit 1; }
sed -i '' '/^garbage=/d;/^identity=/d' "$STATE/sessions/$malformed_id/journal"
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -d "$malformed_root" ]] || { echo 'FAIL: GC must retain a journal missing identity'; exit 1; }
printf 'identity=\nidentity=duplicate\n' >> "$STATE/sessions/$malformed_id/journal"
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -d "$malformed_root" ]] || { echo 'FAIL: GC must retain duplicate journal fields'; exit 1; }

future="$(create)"; future_id="$(printf '%s\n' "$future" | sed -n 's/^HARNESS_SESSION_ID=//p')"; future_root="$(printf '%s\n' "$future" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" exit "$future_id"
sed -i '' 's/^heartbeat=.*/heartbeat=2999-01-01T00:00:00Z/' "$STATE/sessions/$future_id/journal"
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -d "$future_root" ]] || { echo 'FAIL: GC must retain future-dated terminal journals'; exit 1; }
ADVANCE_CLONE="$TMP/create-advance"
git clone -q "$REMOTE" "$ADVANCE_CLONE"
git -C "$ADVANCE_CLONE" config user.email test@example.invalid
git -C "$ADVANCE_CLONE" config user.name test
printf '%s\n' remote-latest > "$ADVANCE_CLONE/remote-latest.txt"
git -C "$ADVANCE_CLONE" add remote-latest.txt
git -C "$ADVANCE_CLONE" commit -qm remote-latest
git -C "$ADVANCE_CLONE" push -q origin main
latest_session="$(create)"
latest_root="$(printf '%s\n' "$latest_session" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
[[ -f "$latest_root/remote-latest.txt" ]] || { echo 'FAIL: create must fetch and base a new session on latest origin/main'; exit 1; }
closed="$(create)"; closed_root="$(printf '%s\n' "$closed" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; closed_id="$(printf '%s\n' "$closed" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf close > "$closed_root/closed.txt"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" close "$closed_id"
git --git-dir="$REMOTE" show main:closed.txt >/dev/null || { echo 'FAIL: public close command must submit and deliver the current session'; exit 1; }
third="$(create)"
third_root="$(printf '%s\n' "$third" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
third_id="$(printf '%s\n' "$third" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf '%s\n' broker-change > "$third_root/broker.txt"
git -C "$third_root" add broker.txt
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$third_id"
[[ -s "$STATE/sessions/$third_id/submission.patch" && -s "$STATE/sessions/$third_id/manifest" ]] || { echo 'FAIL: submit must persist immutable patch and manifest'; exit 1; }
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$third_id"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$third_id"
git --git-dir="$REMOTE" show main:broker.txt | grep -qx broker-change || { echo 'FAIL: broker must deliver submitted paths'; exit 1; }
grep -qx 'state=DELIVERED' "$STATE/sessions/$third_id/journal" || { echo 'FAIL: successful readback must mark DELIVERED'; exit 1; }
if HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" resume "$SOURCE" "$third_id" 2>"$TMP/delivered-resume.err"; then
  echo 'FAIL: DELIVERED sessions must be permanently terminal'; exit 1
fi
grep -q 'cannot resume DELIVERED session; start a fresh isolated session' "$TMP/delivered-resume.err" || { echo 'FAIL: DELIVERED rejection must require a fresh session'; exit 1; }
if grep -R -- '--force' "$STATE/sessions/$third_id"; then echo 'FAIL: broker must never record force push'; exit 1; fi
python3 - "$STATE/sessions/$third_id/journal" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
p.write_text(p.read_text().replace(next(line for line in p.read_text().splitlines() if line.startswith("heartbeat=")), "heartbeat=2000-01-01T00:00:00Z"))
PY
mv "$STATE/sessions/$third_id/delivered-manifest" "$TMP/delivered-manifest"
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -d "$third_root" ]] || { echo 'FAIL: GC must retain DELIVERED roots with incomplete delivery evidence'; exit 1; }
: > "$STATE/sessions/$third_id/delivered-manifest"
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -d "$third_root" ]] || { echo 'FAIL: GC must retain DELIVERED roots with an empty manifest'; exit 1; }
printf 'F\0' > "$STATE/sessions/$third_id/delivered-manifest"
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -d "$third_root" ]] || { echo 'FAIL: GC must retain DELIVERED roots with a truncated manifest'; exit 1; }
mv "$TMP/delivered-manifest" "$STATE/sessions/$third_id/delivered-manifest"
mv "$STATE/sessions/$third_id/delivered-sha" "$TMP/delivered-sha"
printf 'garbage\n' > "$STATE/sessions/$third_id/delivered-sha"
HARNESS_SESSION_RETENTION_SECONDS=0 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" gc
[[ -d "$third_root" ]] || { echo 'FAIL: GC must retain DELIVERED roots with a malformed delivered SHA'; exit 1; }
mv "$TMP/delivered-sha" "$STATE/sessions/$third_id/delivered-sha"

tampered="$(create)"; tampered_root="$(printf '%s\n' "$tampered" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; tampered_id="$(printf '%s\n' "$tampered" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf tampered > "$tampered_root/tampered.txt"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$tampered_id"
chmod u+w "$STATE/sessions/$tampered_id/submission.patch"; printf '\n' >> "$STATE/sessions/$tampered_id/submission.patch"
if HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$tampered_id"; then echo 'FAIL: mutable submission bytes must fail identity verification'; exit 1; fi
grep -qx state=CONFLICT "$STATE/sessions/$tampered_id/journal" || { echo 'FAIL: tampered submission must become CONFLICT'; exit 1; }

same_a="$(create)"; same_b="$(create)"
same_a_root="$(printf '%s\n' "$same_a" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; same_b_root="$(printf '%s\n' "$same_b" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
same_a_id="$(printf '%s\n' "$same_a" | sed -n 's/^HARNESS_SESSION_ID=//p')"; same_b_id="$(printf '%s\n' "$same_b" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf '%s\n' first > "$same_a_root/same.txt"; printf '%s\n' second > "$same_b_root/same.txt"
git -C "$same_a_root" add same.txt; git -C "$same_b_root" add same.txt
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$same_a_id"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$same_b_id"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$same_a_id"
if HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$same_b_id"; then echo 'FAIL: same-file submission must conflict explicitly'; exit 1; fi
grep -qx 'state=CONFLICT' "$STATE/sessions/$same_b_id/journal" || { echo 'FAIL: same-file conflict must be durable'; exit 1; }

line_a="$(create)"; line_b="$(create)"
line_a_root="$(printf '%s\n' "$line_a" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; line_b_root="$(printf '%s\n' "$line_b" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
line_a_id="$(printf '%s\n' "$line_a" | sed -n 's/^HARNESS_SESSION_ID=//p')"; line_b_id="$(printf '%s\n' "$line_b" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf '%s\n' ONE two three > "$line_a_root/merge.txt"; printf '%s\n' one two THREE > "$line_b_root/merge.txt"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$line_a_id"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$line_b_id"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$line_a_id"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$line_b_id"
[[ "$(git --git-dir="$REMOTE" show main:merge.txt)" == $'ONE\ntwo\nTHREE' ]] || { echo 'FAIL: 3-way integration must preserve disjoint line edits'; exit 1; }

renamed="$(create)"; renamed_root="$(printf '%s\n' "$renamed" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; renamed_id="$(printf '%s\n' "$renamed" | sed -n 's/^HARNESS_SESSION_ID=//p')"
git -C "$renamed_root" mv rename-old.txt rename-new.txt
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$renamed_id"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$renamed_id"
git --git-dir="$REMOTE" cat-file -e main:rename-old.txt 2>/dev/null && { echo 'FAIL: rename source must be deleted'; exit 1; }
[[ "$(git --git-dir="$REMOTE" show main:rename-new.txt)" == rename-me ]] || { echo 'FAIL: rename destination must retain its blob'; exit 1; }

advance="$(create)"; advance_root="$(printf '%s\n' "$advance" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; advance_id="$(printf '%s\n' "$advance" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf '%s\n' candidate > "$advance_root/candidate.txt"; git -C "$advance_root" add candidate.txt
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$advance_id"
COUNT="$TMP/verify-count"; VERIFY="$TMP/verify-advance.sh"
cat > "$VERIFY" <<'EOF'
#!/usr/bin/env bash
n=0; [[ -f "$COUNT" ]] && n="$(<"$COUNT")"; n=$((n + 1)); printf '%s\n' "$n" > "$COUNT"
if [[ "$n" == 1 ]]; then
  d="$(mktemp -d)"; git clone -q "$REMOTE" "$d"; git -C "$d" config user.email test@example.invalid; git -C "$d" config user.name test; printf '%s\n' advance > "$d/advance.txt"; git -C "$d" add advance.txt; git -C "$d" commit -qm advance; git -C "$d" push -q origin HEAD:main; rm -rf "$d"
fi
EOF
chmod +x "$VERIFY"
COUNT="$COUNT" REMOTE="$REMOTE" HARNESS_TEST_VERIFIER="$VERIFY" HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$advance_id"
[[ "$(<"$COUNT")" -ge 2 ]] || { echo 'FAIL: remote advance must force verifier re-run'; exit 1; }

readback="$(create)"; readback_root="$(printf '%s\n' "$readback" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; readback_id="$(printf '%s\n' "$readback" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf '%s\n' readback > "$readback_root/readback.txt"; git -C "$readback_root" add readback.txt; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$readback_id"
if HARNESS_SESSION_TEST_READBACK_FAIL=1 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$readback_id"; then echo 'FAIL: readback outage must defer delivery'; exit 1; fi
grep -qx 'state=INTEGRATING' "$STATE/sessions/$readback_id/journal" || { echo 'FAIL: post-push readback outage must remain indeterminate'; exit 1; }
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" recover "$readback_id" | grep -qx state=DELIVERED || { echo 'FAIL: recover must prove an indeterminate pushed commit from fresh remote history'; exit 1; }

disjoint_a="$(create)"; disjoint_b="$(create)"; da_root="$(printf '%s\n' "$disjoint_a" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; db_root="$(printf '%s\n' "$disjoint_b" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; da_id="$(printf '%s\n' "$disjoint_a" | sed -n 's/^HARNESS_SESSION_ID=//p')"; db_id="$(printf '%s\n' "$disjoint_b" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf a > "$da_root/disjoint-a"; printf b > "$db_root/disjoint-b"; git -C "$da_root" add disjoint-a; git -C "$db_root" add disjoint-b
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$da_id"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$db_id"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$da_id" & pa=$!; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$db_id" & pb=$!; wait "$pa"; wait "$pb"
git --git-dir="$REMOTE" show main:disjoint-a >/dev/null && git --git-dir="$REMOTE" show main:disjoint-b >/dev/null || { echo 'FAIL: disjoint concurrent submissions must both deliver'; exit 1; }

git -C "$SOURCE" fetch -q origin main:refs/remotes/origin/main
paths="$(create)"; paths_root="$(printf '%s\n' "$paths" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; paths_id="$(printf '%s\n' "$paths" | sed -n 's/^HARNESS_SESSION_ID=//p')"
rm "$paths_root/tracked.txt"; printf '#!/bin/sh\n' > "$paths_root/space file"; chmod +x "$paths_root/space file"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$paths_id"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$paths_id"
git --git-dir="$REMOTE" cat-file -e main:tracked.txt 2>/dev/null && { echo 'FAIL: deleted path must not survive delivery'; exit 1; }
mode="$(git --git-dir="$REMOTE" ls-tree main -- 'space file' | awk '{print $1}')"; [[ "$mode" == 100755 ]] || { echo 'FAIL: executable mode and space path must survive delivery'; exit 1; }

git -C "$SOURCE" fetch -q origin main:refs/remotes/origin/main
weird="$(create)"; weird_root="$(printf '%s\n' "$weird" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; weird_id="$(printf '%s\n' "$weird" | sed -n 's/^HARNESS_SESSION_ID=//p')"
weird_name=$'tab\tand\nnewline'; printf target > "$weird_root/$weird_name"; ln -s "$weird_name" "$weird_root/link"; git -C "$weird_root" add -A
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$weird_id"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$weird_id"
[[ "$(git --git-dir="$REMOTE" show "main:$weird_name")" == target ]] || { echo 'FAIL: tab/newline path must survive'; exit 1; }
[[ "$(git --git-dir="$REMOTE" show main:link)" == "$weird_name" ]] || { echo 'FAIL: symlink blob must survive'; exit 1; }

git -C "$SOURCE" fetch -q origin main:refs/remotes/origin/main
verify_fail="$(create)"; verify_fail_root="$(printf '%s\n' "$verify_fail" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; verify_fail_id="$(printf '%s\n' "$verify_fail" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf fail > "$verify_fail_root/verifier-failure"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$verify_fail_id"
if HARNESS_SESSION_TEST_VERIFY_FAIL=1 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$verify_fail_id"; then echo 'FAIL: verifier failure must fail integration'; exit 1; fi
grep -qx 'state=CONFLICT' "$STATE/sessions/$verify_fail_id/journal" || { echo 'FAIL: verifier failure must reach terminal CONFLICT'; exit 1; }
printf stale > "$STATE/sessions/$verify_fail_id/pending-sha"; printf stale > "$STATE/sessions/$verify_fail_id/push-ack"; printf stale > "$STATE/sessions/$verify_fail_id/.candidate-manifest"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" resume "$SOURCE" "$verify_fail_id" | grep -qx "HARNESS_SESSION_ROOT=$verify_fail_root" || { echo 'FAIL: --isolated-session resume must retain a conflicted workspace'; exit 1; }
[[ ! -e "$STATE/sessions/$verify_fail_id/pending-sha" && ! -e "$STATE/sessions/$verify_fail_id/push-ack" && ! -e "$STATE/sessions/$verify_fail_id/.candidate-manifest" ]] || { echo 'FAIL: reopening a conflict must discard stale broker receipts'; exit 1; }
grep -qx 'state=OPEN' "$STATE/sessions/$verify_fail_id/journal" || { echo 'FAIL: conflict recovery must reopen the same UUID'; exit 1; }
printf repaired > "$verify_fail_root/verifier-failure"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" close "$verify_fail_id"
[[ "$(git --git-dir="$REMOTE" show main:verifier-failure)" == repaired ]] || { echo 'FAIL: recovered conflict must support a fresh submission'; exit 1; }

verifier_tamper="$(create)"; verifier_tamper_root="$(printf '%s\n' "$verifier_tamper" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; verifier_tamper_id="$(printf '%s\n' "$verifier_tamper" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$verifier_tamper_root/core/bin/auto-deliver.sh"
printf blocked > "$verifier_tamper_root/verifier-tamper"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$verifier_tamper_id"
if HARNESS_SESSION_TEST_VERIFY_FAIL=1 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$verifier_tamper_id"; then echo 'FAIL: candidate must not replace its repository-owned baseline verifier'; exit 1; fi

remote_arg="$(create)"; remote_arg_root="$(printf '%s\n' "$remote_arg" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; remote_arg_id="$(printf '%s\n' "$remote_arg" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf no > "$remote_arg_root/remote-override"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$remote_arg_id"
if HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$remote_arg_id" "$TMP/other.git"; then echo 'FAIL: public integrate must reject caller-supplied remote or verifier'; exit 1; fi
grep -qx state=SUBMITTED "$STATE/sessions/$remote_arg_id/journal" || { echo 'FAIL: rejected remote override must not mutate journal'; exit 1; }

git -C "$SOURCE" fetch -q origin main:refs/remotes/origin/main
retry="$(create)"; retry_root="$(printf '%s\n' "$retry" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; retry_id="$(printf '%s\n' "$retry" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf retry > "$retry_root/retry-exhausted"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$retry_id"
RETRY_COUNT="$TMP/retry-count"; RETRY_VERIFY="$TMP/retry-advance.sh"
cat > "$RETRY_VERIFY" <<'EOF'
#!/usr/bin/env bash
n=0; [[ -f "$RETRY_COUNT" ]] && n="$(<"$RETRY_COUNT")"; n=$((n + 1)); printf '%s\n' "$n" > "$RETRY_COUNT"
d="$(mktemp -d)"; git clone -q "$REMOTE" "$d"; git -C "$d" config user.email test@example.invalid; git -C "$d" config user.name test
touch "$d/remote-advance-$n"; git -C "$d" add .; git -C "$d" commit -qm "advance $n"; git -C "$d" push -q origin HEAD:main; rm -rf "$d"
EOF
chmod +x "$RETRY_VERIFY"
if RETRY_COUNT="$RETRY_COUNT" REMOTE="$REMOTE" HARNESS_TEST_VERIFIER="$RETRY_VERIFY" HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$retry_id"; then echo 'FAIL: repeated remote advance must exhaust bounded retries'; exit 1; fi
[[ "$(<"$RETRY_COUNT")" == 2 ]] || { echo 'FAIL: remote retry count must be bounded at two attempts'; exit 1; }
grep -qx 'state=CONFLICT' "$STATE/sessions/$retry_id/journal" || { echo 'FAIL: retry exhaustion must reach terminal CONFLICT'; exit 1; }

git -C "$SOURCE" fetch -q origin main:refs/remotes/origin/main
crash_a="$(create)"; crash_b="$(create)"
crash_a_root="$(printf '%s\n' "$crash_a" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; crash_b_root="$(printf '%s\n' "$crash_b" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
crash_a_id="$(printf '%s\n' "$crash_a" | sed -n 's/^HARNESS_SESSION_ID=//p')"; crash_b_id="$(printf '%s\n' "$crash_b" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf a > "$crash_a_root/crash-a"; printf b > "$crash_b_root/crash-b"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$crash_a_id"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$crash_b_id"
if HARNESS_SESSION_TEST_CRASH_BEFORE_PUSH=1 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$crash_a_id" >/dev/null 2>&1; then echo 'FAIL: pre-push crash injection must terminate integration'; exit 1; fi
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$crash_b_id"
git --git-dir="$REMOTE" show main:crash-b >/dev/null || { echo 'FAIL: process crash must release integration lock'; exit 1; }
crash_recovery="$(HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" recover "$crash_a_id")"
printf '%s\n' "$crash_recovery" | grep -qx state=SUBMITTED || { printf '%s\n' "$crash_recovery"; grep '^state=' "$STATE/sessions/$crash_a_id/journal"; echo 'FAIL: pre-push crash must reconcile to retryable SUBMITTED'; exit 1; }
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$crash_a_id"

postpush="$(create)"; postpush_root="$(printf '%s\n' "$postpush" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; postpush_id="$(printf '%s\n' "$postpush" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf delivered > "$postpush_root/postpush-crash"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$postpush_id"
if HARNESS_SESSION_TEST_CRASH_AFTER_PUSH=1 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$postpush_id" >/dev/null 2>&1; then echo 'FAIL: post-push crash injection must terminate integration'; exit 1; fi
grep -qx state=INTEGRATING "$STATE/sessions/$postpush_id/journal" || { echo 'FAIL: post-push crash fixture must retain INTEGRATING'; exit 1; }
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" recover "$postpush_id" | grep -qx state=DELIVERED || { echo 'FAIL: post-push crash must reconcile exact remote delivery'; exit 1; }
git --git-dir="$REMOTE" show main:postpush-crash | grep -qx delivered || { echo 'FAIL: reconciled post-push commit missing remotely'; exit 1; }

preack="$(create)"; preack_root="$(printf '%s\n' "$preack" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; preack_id="$(printf '%s\n' "$preack" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf delivered > "$preack_root/preack-crash"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$preack_id"
if HARNESS_SESSION_TEST_CRASH_BEFORE_ACK=1 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$preack_id" >/dev/null 2>&1; then echo 'FAIL: pre-ack crash injection must terminate integration'; exit 1; fi
[[ ! -f "$STATE/sessions/$preack_id/push-ack" ]] || { echo 'FAIL: pre-ack crash fixture must stop before local acknowledgement'; exit 1; }
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" recover "$preack_id" | grep -qx state=DELIVERED || { echo 'FAIL: recovery must prove a pushed candidate from fresh remote history without a local acknowledgement'; exit 1; }
git --git-dir="$REMOTE" show main:preack-crash | grep -qx delivered || { echo 'FAIL: pre-ack recovery lost the remotely accepted commit'; exit 1; }

postpush_race="$(create)"; postpush_race_root="$(printf '%s\n' "$postpush_race" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"; postpush_race_id="$(printf '%s\n' "$postpush_race" | sed -n 's/^HARNESS_SESSION_ID=//p')"
printf delivered > "$postpush_race_root/postpush-race"; HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$postpush_race_id"
HARNESS_SESSION_TEST_POST_PUSH_DELAY=2 HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" integrate "$postpush_race_id" & race_pid=$!
for _ in {1..100}; do [[ -f "$STATE/sessions/$postpush_race_id/push-ack" ]] && break; sleep 0.05; done
[[ -f "$STATE/sessions/$postpush_race_id/push-ack" ]] || { echo 'FAIL: successful push must persist an acknowledgement before readback'; exit 1; }
race_advance="$TMP/postpush-race-advance"; git clone -q "$REMOTE" "$race_advance"; git -C "$race_advance" config user.email test@example.invalid; git -C "$race_advance" config user.name test
printf advanced > "$race_advance/after-race"; git -C "$race_advance" add after-race; git -C "$race_advance" commit -qm after-race; git -C "$race_advance" push -q origin HEAD:main
wait "$race_pid"
grep -qx state=DELIVERED "$STATE/sessions/$postpush_race_id/journal" || { echo 'FAIL: a later remote descendant must not invalidate an acknowledged delivery'; exit 1; }
git --git-dir="$REMOTE" merge-base --is-ancestor "$(<"$STATE/sessions/$postpush_race_id/delivered-sha")" main || { echo 'FAIL: acknowledged delivery must remain in remote history'; exit 1; }

echo 'PASS: isolated sessions retain clean canonical base and durable recovery state'
