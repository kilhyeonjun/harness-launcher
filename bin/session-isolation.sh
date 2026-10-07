#!/usr/bin/env bash
# Durable, opt-in isolated harness session repositories.
set -euo pipefail
# Inherited git variables would change what every pathspec, index and git
# dir below means (GIT_LITERAL_PATHSPECS turns the icase fences into literals).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_COMMON_DIR GIT_NAMESPACE GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS

state_home() { printf '%s\n' "${HARNESS_SESSION_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/harness-launcher}"; }
session_dir() { printf '%s/sessions/%s\n' "$(state_home)" "$1"; }
new_id() { uuidgen 2>/dev/null || { date +%s%N; } | shasum -a 256 | cut -c1-32; }
write_journal() {
  local dir="$1" state="$2" identity="$3" tmp
  tmp="$(mktemp "$dir/.journal.XXXXXX")"
  { printf 'state=%s\nidentity=%s\nheartbeat=%s\n' "$state" "$identity" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$tmp"
  mv -f "$tmp" "$dir/journal"
}
write_heartbeat() {
  local dir="$1" tmp
  tmp="$(mktemp "$dir/.heartbeat.XXXXXX")"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$tmp"
  mv -f "$tmp" "$dir/heartbeat"
}
field() { sed -n "s/^$2=//p" "$1" | head -n 1; }
# Broker git on a session root: nothing named by the session's own config may
# run (fsmonitor, hooks, external diff, submodule recursion).
session_git() {
  git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c submodule.recurse=false \
    -c diff.external= -c core.untrackedCache=false "$@"
}
EXCLUDED_PATHS=(config/.local projects .mcp.local.json mcp.local.json .claude/settings.local.json)
# Case-insensitive: the agent can negate the ignore rules in .gitignore, and
# a case variant (Projects/, config/.LOCAL/) must not slip past the fence.
EXCLUDED_PATHSPEC=() EXCLUDED_ICASE=()
for _excluded in "${EXCLUDED_PATHS[@]}"; do
  EXCLUDED_PATHSPEC+=(":(exclude,icase)$_excluded"); EXCLUDED_ICASE+=(":(icase)$_excluded")
done
unset _excluded
# stage_worktree <root> <base>: stage the session work tree. `add` never names
# the excluded paths: an exclude pathspec that names a gitignored file (the
# copied or linked machine-local files are usually ignored) makes `add -A`
# exit 1. Excluded paths are then reset; headless sessions reset them to the
# base so a tracked file there keeps its base content (their trusted.git also
# ignores them through info/exclude), interactive ones to HEAD so submit can
# still refuse excluded paths the session committed.
stage_worktree() {
  local list path
  local -a aliases=()
  root_git "$1" add -A -- . || return 1
  if [[ -n "$ROOT_GIT_DIR" ]]; then
    root_git "$1" reset -q "$2" -- "${EXCLUDED_ICASE[@]}" || return 1
  else
    session_git -C "$1" reset -q -- "${EXCLUDED_ICASE[@]}" || return 1
  fi
  # Names git's ASCII-only icase misses but the filesystem folds onto an
  # excluded entry (projectſ is projects on APFS) are reset the same way.
  list="$(mktemp "$(state_home)/aliases.XXXXXX")" || return 1
  excluded_aliases "$1" "$2" > "$list" || { rm -f "$list"; return 1; }
  while IFS= read -r -d '' path; do aliases+=(":(literal)$path"); done < "$list"
  rm -f "$list"
  (( ${#aliases[@]} )) || return 0
  if [[ -n "$ROOT_GIT_DIR" ]]; then
    root_git "$1" reset -q "$2" -- "${aliases[@]}"
  else
    session_git -C "$1" reset -q -- "${aliases[@]}"
  fi
}
# excluded_aliases <root> <base>: NUL-separated staged paths (changed from
# base) that a filesystem resolves to an excluded entry: case, Unicode case
# folding and normalization are decided by probe trees of the excluded
# entries, one on the session volume (state home) and one on the volume of
# the source checkout the work lands in (its git dir), so every layer agrees
# with what a checkout on either would actually write.
excluded_aliases() {
  local root="$1" base="$2" staged probe path first second hit
  local -a probes=()
  [[ -n "$SOURCE_GIT_DIR" ]] || { echo 'harness-session: no source git dir to probe' >&2; return 1; }
  staged="$(mktemp "$(state_home)/staged.XXXXXX")" || return 1
  # Callers test the status, so errexit is off here: every step is checked,
  # and the staged list is a file, not a process substitution whose failure
  # would read as "no paths".
  for probe in "$(state_home)" "$SOURCE_GIT_DIR"; do
    probe="$(mktemp -d "$probe/harness-probe.XXXXXX")" || { rm -rf "$staged" "${probes[@]}"; return 1; }
    probes+=("$probe")
    { mkdir -p "$probe/projects" "$probe/config/.local" "$probe/.claude" \
        && : > "$probe/mcp.local.json" && : > "$probe/.mcp.local.json" && : > "$probe/.claude/settings.local.json"
    } || { rm -rf "$staged" "${probes[@]}"; return 1; }
  done
  root_git "$root" diff --no-ext-diff --ignore-submodules=all --cached --name-only --no-renames -z "$base" > "$staged" \
    || { rm -rf "$staged" "${probes[@]}"; return 1; }
  while IFS= read -r -d '' path; do
    first="${path%%/*}"; second=""
    if [[ "$path" == */* ]]; then second="${path#*/}"; second="$first/${second%%/*}"; fi
    hit=0
    for probe in "${probes[@]}"; do
      if [[ -e "$probe/$first" ]] && { [[ "$probe/$first" -ef "$probe/projects" ]] \
          || [[ "$probe/$first" -ef "$probe/mcp.local.json" ]] || [[ "$probe/$first" -ef "$probe/.mcp.local.json" ]]; }; then
        hit=1; break
      fi
      if [[ -n "$second" && -e "$probe/$second" ]] && { [[ "$probe/$second" -ef "$probe/config/.local" ]] \
          || [[ "$probe/$second" -ef "$probe/.claude/settings.local.json" ]]; }; then
        hit=1; break
      fi
    done
    [[ "$hit" == 0 ]] || printf '%s\0' "$path"
  done < "$staged"
  rm -rf "$staged" "${probes[@]}"
}
# Headless sessions (record marker `headless`, written at clone time) never
# let broker git read the session's own .git: it runs on a launcher-owned git
# dir in the record (`trusted.git`, base commit plus its own index) with the
# session root as work tree and no system or global config. Anything the agent
# put in the session .git (config, hooks, modules, alternates) is never read,
# and work-tree attributes name filter or diff drivers that are not defined.
# ROOT_GIT_DIR is set by use_session_git; empty means an interactive session.
ROOT_GIT_DIR="" SOURCE_GIT_DIR=""
use_session_git() {
  local dir; dir="$(session_dir "$1")"; ROOT_GIT_DIR=""
  # The canonical checkout's git dir: excluded_aliases probes its volume.
  # Exit 8: the source checkout is gone (moved or deleted); the work is kept.
  local source=""
  { source="$(<"$dir/source-root")" && [[ -d "$source" ]] \
      && SOURCE_GIT_DIR="$(git -C "$source" rev-parse --path-format=absolute --git-common-dir)"; } || {
    echo "harness-session: refused: the source checkout ${source:-of session $1} could not be found; the session is kept" >&2
    return 8
  }
  [[ -e "$dir/headless" ]] || return 0
  if [[ ! -d "$dir/trusted.git" || -L "$dir/trusted.git" ]]; then
    echo "harness-session: refused: headless session $1 has no trusted git directory" >&2
    return 6
  fi
  ROOT_GIT_DIR="$dir/trusted.git"
}
# root_git <root> <git args...>: broker git on a session work tree.
root_git() {
  local root="$1"; shift
  if [[ -n "$ROOT_GIT_DIR" ]]; then
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      session_git -C "$root" --git-dir="$ROOT_GIT_DIR" --work-tree="$root" "$@"
  else
    session_git -C "$root" "$@"
  fi
}
reopen_session() {
  local id="$1" dir
  dir="$(session_dir "$id")"
  chmod u+w "$dir/submission.patch" "$dir/manifest" "$dir/remote-url" 2>/dev/null || true
  rm -f "$dir/pending-sha" "$dir/push-ack" "$dir/.candidate-manifest"
  transition "$id" OPEN
  write_heartbeat "$dir"
}
# headless_local_files <source> <root>
#   HARNESS_HEADLESS=1 (set only by harness-headless): no write path back to the
#   canonical root. projects/ is never a link, local files are copied (the
#   settings env block of MCP secrets is dropped), and a symlink on any path
#   component under <root> refuses the clone instead of being followed.
headless_local_files() {
  local source="$1" root="$2" local_file part path tmp py="${HARNESS_PYTHON_BIN:-}"
  [[ ! -L "$root/projects" ]] || rm -f "$root/projects" || return 2
  for local_file in .mcp.local.json mcp.local.json .claude/settings.local.json; do
    [[ -f "$source/$local_file" ]] || continue
    path="$root"
    for part in ${local_file//\// }; do
      path="$path/$part"
      [[ ! -L "$path" ]] || { echo "harness-session: headless clone refused: symlink at $local_file" >&2; return 2; }
    done
    [[ ! -e "$root/$local_file" ]] || continue
    mkdir -p "$(dirname "$root/$local_file")" || return 2
    tmp="$(mktemp "$(dirname "$root/$local_file")/.headless-local.XXXXXX")" || return 2
    if [[ "$local_file" == .claude/settings.local.json ]]; then
      # Absolute interpreter (resolved by the launcher) in isolated mode: no
      # cwd, PYTHON* or user-site module can replace the stdlib json.
      [[ "$py" == /* && -x "$py" ]] || { echo 'harness-session: headless clone refused: HARNESS_PYTHON_BIN must be an absolute interpreter' >&2; rm -f "$tmp"; return 2; }
      "$py" -I -c 'import json,sys; s=json.load(open(sys.argv[1])); s.pop("env",None); json.dump(s,open(sys.argv[2],"w"))' \
        "$source/$local_file" "$tmp" || { rm -f "$tmp"; return 2; }
    else
      cat "$source/$local_file" > "$tmp" || { rm -f "$tmp"; return 2; }
    fi
    # rename replaces, never follows, whatever is at the target.
    mv -f "$tmp" "$root/$local_file" || { rm -f "$tmp"; return 2; }
  done
}
create() {
  local source="$1" root state id base sha dir local_file
  source="$(cd "$source" && pwd -P)"
  git -C "$source" rev-parse --is-inside-work-tree >/dev/null
  state="$(state_home)"; mkdir -p "$state/sessions" "$state/worktrees"
  if git -C "$source" remote get-url origin >/dev/null 2>&1; then
    git -C "$source" fetch -q origin main:refs/remotes/origin/main
  fi
  base="$(git -C "$source" rev-parse --verify -q origin/main 2>/dev/null || git -C "$source" rev-parse HEAD)"
  sha="$(git -C "$source" rev-parse "$base^{commit}")"
  id="$(new_id)"; dir="$state/sessions/$id"; root="$state/worktrees/$id"
  mkdir -p "$dir"
  local -a clone_flags=(-q --no-checkout)
  [[ "${HARNESS_HEADLESS:-0}" != 1 ]] || clone_flags+=(--no-hardlinks)
  git clone "${clone_flags[@]}" "$source" "$root"
  git -C "$root" remote remove origin
  git -C "$root" checkout -q --detach "$sha"
  rm -rf "$root/config/.local"
  if [[ "${HARNESS_HEADLESS:-0}" == 1 ]]; then
    headless_local_files "$source" "$root" || { rm -rf "$root" "$dir"; return 2; }
  else
    if [[ -d "$source/projects" ]]; then rm -rf "$root/projects"; ln -s "$source/projects" "$root/projects"; fi
    for local_file in .mcp.local.json mcp.local.json .claude/settings.local.json; do
      if [[ -f "$source/$local_file" && ! -e "$root/$local_file" ]]; then
        mkdir -p "$(dirname "$root/$local_file")"
        ln -s "$source/$local_file" "$root/$local_file"
      fi
    done
    # Staging adds the whole work tree; keep it out of the excluded paths even
    # when the harness .gitignore does not cover them.
    mkdir -p "$root/.git/info"
    printf '/%s\n' "${EXCLUDED_PATHS[@]}" >> "$root/.git/info/exclude"
  fi
  printf '%s\n' "$source" > "$dir/source-root"
  printf '%s\n' "$root" > "$dir/session-root"
  printf '%s\n' "$sha" > "$dir/base-sha"
  if [[ "${HARNESS_HEADLESS:-0}" == 1 ]]; then
    # Before the agent runs: the base commit and a matching index, owned by
    # the launcher record and outside the sandbox's writable paths.
    # No user template or config: a hooks-only init.templateDir would leave no
    # info/, and user hooks or config must not reach the trusted dir.
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git init -q --bare --template= "$dir/trusted.git"
    mkdir -p "$dir/trusted.git/info"
    # Match the clone's filesystem view (git sets these per volume at clone).
    git --git-dir="$dir/trusted.git" config core.ignorecase "$(git -C "$root" config --bool --default false core.ignorecase)"
    git --git-dir="$dir/trusted.git" config core.precomposeunicode "$(git -C "$root" config --bool --default false core.precomposeunicode)"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git --git-dir="$dir/trusted.git" fetch -q --no-tags "$root" "+HEAD:refs/heads/base"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git --git-dir="$dir/trusted.git" --work-tree="$root" read-tree "$sha"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git --git-dir="$dir/trusted.git" --work-tree="$root" update-index -q --refresh
    printf '/%s\n' "${EXCLUDED_PATHS[@]}" >> "$dir/trusted.git/info/exclude"
    : > "$dir/headless"
  fi
  printf '1\n' > "$dir/lease-v1"
  : > "$dir/runtime.lock"
  write_journal "$dir" OPEN ""
  write_heartbeat "$dir"
  printf 'HARNESS_SESSION_ID=%s\nHARNESS_SOURCE_ROOT=%s\nHARNESS_SESSION_ROOT=%s\nHARNESS_RUN_DIR=%s\n' "$id" "$source" "$root" "$root"
}
valid_id() { [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; }
journal_valid() {
  local journal="$1"
  [[ -f "$journal" && ! -L "$journal" ]] || return 1
  awk '
    NR == 1 && $0 ~ /^state=(OPEN|ABANDONED|CONFLICT|CLOSED|SUBMITTED|INTEGRATING|DELIVERED)$/ { state = 1; next }
    NR == 2 && $0 ~ /^identity=[^[:cntrl:]]*$/ { identity = 1; next }
    NR == 3 && $0 ~ /^heartbeat=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ { heartbeat = 1; next }
    { bad = 1 }
    END { exit !(NR == 3 && state && identity && heartbeat && !bad) }
  ' "$journal"
}
lease_marker_valid() {
  local marker="$1"
  [[ -f "$marker" && ! -L "$marker" && "$(wc -c < "$marker" | tr -d ' ')" == 2 ]] && grep -qx 1 "$marker"
}
git_object_id_file_valid() {
  local path="$1" oid bytes
  [[ -f "$path" && ! -L "$path" ]] || return 1
  oid="$(<"$path")"; bytes="$(wc -c < "$path" | tr -d ' ')"
  [[ "$oid" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ ]] || return 1
  [[ "$bytes" == 41 || "$bytes" == 65 ]]
}
delivered_manifest_valid() {
  local manifest="$1" kind mode oid path count=0
  [[ -s "$manifest" && ! -L "$manifest" ]] || return 1
  exec 7< "$manifest" || return 1
  while :; do
    kind=""
    if ! IFS= read -r -d '' kind <&7; then
      exec 7<&-
      [[ -z "$kind" && "$count" -gt 0 ]]
      return
    fi
    IFS= read -r -d '' mode <&7 && IFS= read -r -d '' oid <&7 && IFS= read -r -d '' path <&7 || { exec 7<&-; return 1; }
    case "$kind" in
      F)
        [[ "$mode" == 100644 || "$mode" == 100755 || "$mode" == 120000 || "$mode" == 160000 ]] || { exec 7<&-; return 1; }
        [[ "$oid" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ ]] || { exec 7<&-; return 1; }
        ;;
      D) [[ "$mode" == - && "$oid" == - ]] || { exec 7<&-; return 1; } ;;
      *) exec 7<&-; return 1 ;;
    esac
    case "$path" in ''|/*|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*) exec 7<&-; return 1 ;; esac
    count=$((count + 1))
  done
}
terminal_record_valid() {
  local dir="$1" journal="$dir/journal" state identity
  journal_valid "$journal" || return 1
  state="$(field "$journal" state)"; identity="$(field "$journal" identity)"
  case "$state" in
    CLOSED) [[ -z "$identity" ]] ;;
    DELIVERED)
      [[ "$identity" =~ ^[0-9A-Fa-f]{64}$ ]] && git_object_id_file_valid "$dir/delivered-sha" && delivered_manifest_valid "$dir/delivered-manifest"
      ;;
    *) return 1 ;;
  esac
}
terminal_epoch() {
  local journal="$1" value
  value="$(field "$journal" heartbeat)"
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" +%s 2>/dev/null \
    || date -u -d "$value" +%s 2>/dev/null
}
gc_unlocked() {
  local state sessions worktrees retention now started scanned=0 retired=0 retained=0
  local dir id journal status epoch age marker lock root source expected tomb tomb_name tomb_id tomb_nonce
  state="$(state_home)"; sessions="$state/sessions"; worktrees="$state/worktrees"
  retention="${HARNESS_SESSION_RETENTION_SECONDS:-86400}"
  [[ "$retention" =~ ^[0-9]+$ ]] && [[ "$retention" -le 604800 ]] || {
    echo 'ERROR: HARNESS_SESSION_RETENTION_SECONDS must be 0..604800' >&2
    return 2
  }
  mkdir -p "$sessions" "$worktrees"
  [[ ! -L "$sessions" && ! -L "$worktrees" ]] || return 2
  sessions="$(cd "$sessions" && pwd -P)"; worktrees="$(cd "$worktrees" && pwd -P)"
  now="$(date -u +%s)"; started="$now"

  for tomb in "$worktrees"/.retired-*; do
    [[ -d "$tomb" && ! -L "$tomb" ]] || continue
    tomb_name="${tomb##*/}"; tomb_id="${tomb_name#.retired-}"; tomb_id="${tomb_id%-*}"; tomb_nonce="${tomb_name##*-}"
    valid_id "$tomb_id" && [[ "$tomb_nonce" =~ ^[0-9]+$ ]] || continue
    rm -rf -- "$tomb"
  done

  for dir in "$sessions"/*; do
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    id="${dir##*/}"; valid_id "$id" || continue
    scanned=$((scanned + 1)); journal="$dir/journal"; marker="$dir/lease-v1"; lock="$dir/runtime.lock"
    [[ -f "$lock" && ! -L "$lock" ]] && lease_marker_valid "$marker" && terminal_record_valid "$dir" || { retained=$((retained + 1)); continue; }
    status="$(field "$journal" state)"
    epoch="$(terminal_epoch "$journal")" || { retained=$((retained + 1)); continue; }
    age=$((now - epoch)); [[ "$age" -ge 0 && "$age" -ge "$retention" ]] || { retained=$((retained + 1)); continue; }
    (
      exec 8>"$lock"
      /usr/bin/lockf -s -t 0 8 || exit 11
      lease_marker_valid "$marker" && terminal_record_valid "$dir" || exit 12
      status="$(field "$journal" state)"
      epoch="$(terminal_epoch "$journal")" || exit 13
      age=$(( $(date -u +%s) - epoch )); [[ "$age" -ge 0 && "$age" -ge "$retention" ]] || exit 13
      [[ -f "$dir/session-root" && ! -L "$dir/session-root" && -f "$dir/source-root" && ! -L "$dir/source-root" ]] || exit 14
      IFS= read -r root < "$dir/session-root"; IFS= read -r source < "$dir/source-root"
      expected="$worktrees/$id"
      [[ "${root##*/}" == "$id" && -d "$root" && ! -L "$root" ]] || exit 15
      [[ "$(cd "${root%/*}" && pwd -P)/${root##*/}" == "$expected" ]] || exit 16
      [[ "$(cd "$root" && pwd -P)" == "$expected" && -d "$source" && "$(cd "$source" && pwd -P)" != "$expected" ]] || exit 17
      tomb="$worktrees/.retired-$id-$BASHPID"
      [[ ! -e "$tomb" && ! -L "$tomb" ]] || exit 18
      mv "$root" "$tomb" || exit 19
      rm -rf -- "$tomb" || exit 20
    ) && retired=$((retired + 1)) || retained=$((retained + 1))
  done
  printf 'harness-session gc: scanned=%s retired=%s retained=%s elapsed_seconds=%s\n' "$scanned" "$retired" "$retained" "$(( $(date -u +%s) - started ))" >&2
}
gc_sessions() { with_lock gc_unlocked; }
resume_session() {
  local source="$1" id="$2" dir recorded root state lock worktrees expected
  valid_id "$id" || { echo "cannot resume $id: invalid session UUID" >&2; return 2; }
  source="$(cd "$source" && pwd -P)"; dir="$(session_dir "$id")"
  [[ -d "$dir" && ! -L "$dir" && -f "$dir/source-root" && ! -L "$dir/source-root" && -f "$dir/session-root" && ! -L "$dir/session-root" && -f "$dir/journal" && ! -L "$dir/journal" ]] || {
    echo "cannot resume $id: session record is missing or invalid" >&2
    return 2
  }
  lease_marker_valid "$dir/lease-v1" && [[ -f "$dir/runtime.lock" && ! -L "$dir/runtime.lock" ]] || {
    echo "cannot resume $id: invalid runtime lease record" >&2
    return 2
  }
  recorded="$(cd "$(<"$dir/source-root")" && pwd -P)"; [[ "$recorded" == "$source" ]] || { echo "cannot resume $id: source root does not match" >&2; return 2; }
  root="$(<"$dir/session-root")"; [[ -d "$root" && ! -L "$root" ]] || { echo "cannot resume $id: workspace is missing or retired; start a fresh isolated session" >&2; return 2; }
  worktrees="$(state_home)/worktrees"
  [[ -d "$worktrees" && ! -L "$worktrees" ]] || { echo "cannot resume $id: invalid workspace state root" >&2; return 2; }
  worktrees="$(cd "$worktrees" && pwd -P)"; expected="$worktrees/$id"
  [[ "${root##*/}" == "$id" && "$(cd "${root%/*}" && pwd -P)/${root##*/}" == "$expected" && "$(cd "$root" && pwd -P)" == "$expected" ]] || {
    echo "cannot resume $id: workspace is outside the isolated session root" >&2
    return 2
  }
  journal_valid "$dir/journal" || { echo "cannot resume $id: invalid session journal" >&2; return 2; }
  state="$(field "$dir/journal" state)"
  case "$state" in
    OPEN)
      lock="$dir/runtime.lock"
      [[ -f "$lock" && ! -L "$lock" ]] || { echo "cannot resume OPEN session: runtime lease is missing" >&2; return 2; }
      if ( exec 8>"$lock"; /usr/bin/lockf -s -t 0 8 ); then
        echo 'cannot resume OPEN session without an active launcher lease' >&2
        return 2
      fi
      ;;
    ABANDONED|CONFLICT|CLOSED) reopen_session "$id" ;;
    SUBMITTED) echo 'cannot resume SUBMITTED session; run harness-session integrate or recover' >&2; return 2 ;;
    INTEGRATING) echo 'cannot resume INTEGRATING session; run harness-session recover' >&2; return 2 ;;
    DELIVERED) echo 'cannot resume DELIVERED session; start a fresh isolated session' >&2; return 2 ;;
    *) echo "cannot resume $state session: invalid journal state" >&2; return 2 ;;
  esac
  write_heartbeat "$dir"
  printf 'HARNESS_SESSION_ID=%s\nHARNESS_SOURCE_ROOT=%s\nHARNESS_SESSION_ROOT=%s\nHARNESS_RUN_DIR=%s\n' "$id" "$source" "$root" "$root"
}
transition() {
  local id="$1" next="$2" identity="${3:-}" dir old old_identity
  dir="$(session_dir "$id")"; [[ -f "$dir/journal" ]] || { echo "unknown session: $id" >&2; return 2; }
  old="$(field "$dir/journal" state)"; old_identity="$(field "$dir/journal" identity)"
  [[ "$old" == "$next" && "$old_identity" == "$identity" ]] && return 0
  case "$old:$next" in OPEN:SUBMITTED|OPEN:CLOSED|SUBMITTED:INTEGRATING|INTEGRATING:SUBMITTED|INTEGRATING:DELIVERED|INTEGRATING:CONFLICT|OPEN:ABANDONED|ABANDONED:OPEN|CONFLICT:OPEN|CLOSED:OPEN) ;; *) echo "invalid transition: $old -> $next" >&2; return 2;; esac
  write_journal "$dir" "$next" "$identity"
}
# session_has_changes <root> [base-sha]: 0 when the work tree changed or the
# session committed (HEAD moved off the base), 1 when it did not, 2 when git
# could not tell. Callers test the status, so errexit is off: every git call
# is checked and an error is never read as "no changes". Call use_session_git first.
session_has_changes() {
  local rc=0 head out
  [[ -n "${2:-}" ]] || return 2
  if [[ -n "$ROOT_GIT_DIR" ]]; then
    # The work tree holds the final content, committed or not.
    stage_worktree "$1" "$2" || return 2
    root_git "$1" diff --no-ext-diff --ignore-submodules=all --cached --quiet "$2" -- . "${EXCLUDED_PATHSPEC[@]}" || rc=$?
    case "$rc" in 0) return 1 ;; 1) return 0 ;; *) return 2 ;; esac
  fi
  if [[ -n "${2:-}" ]]; then
    head="$(session_git -C "$1" rev-parse HEAD)" || return 2
    [[ "$head" == "$2" ]] || return 0
  fi
  out="$(session_git -C "$1" status --porcelain --ignore-submodules=all --untracked-files=all -- . "${EXCLUDED_PATHSPEC[@]}")" || return 2
  [[ -n "$out" ]] || return 1
}
exit_session() {
  local id="$1" dir root state
  dir="$(session_dir "$id")"; root="$(<"$dir/session-root")"; state="$(field "$dir/journal" state)"
  if [[ "$state" == OPEN ]]; then
    local refused=0
    use_session_git "$id" || refused=$?
    [[ "$refused" == 0 ]] || { transition "$id" ABANDONED; return "$refused"; }
    # Only a clean answer closes; changes or a git error keep the work.
    local rc=0
    session_has_changes "$root" "$(<"$dir/base-sha")" || rc=$?
    if [[ "$rc" == 1 ]]; then transition "$id" CLOSED; else transition "$id" ABANDONED; fi
  fi
}
recover_unlocked() {
  local id="$1" dir state source remote pending readback kind mode hash path actual_mode actual_type actual_oid actual_path entry
  dir="$(session_dir "$id")"; state="$(field "$dir/journal" state)"
  if [[ "$state" == INTEGRATING ]]; then
    source="$(<"$dir/source-root")"; remote="$(git -C "$source" remote get-url origin)"
    if [[ "$remote" == "$(<"$dir/remote-url")" && -f "$dir/pending-sha" && -f "$dir/.candidate-manifest" ]]; then
      pending="$(<"$dir/pending-sha")"
      if [[ ! -f "$dir/push-ack" || "$(<"$dir/push-ack")" == "$pending" ]]; then
        readback="$(mktemp -d "$(state_home)/recover-readback.XXXXXX")"
        git clone -q "$remote" "$readback"
        git -C "$readback" merge-base --is-ancestor "$pending" HEAD || { rm -rf "$readback"; transition "$id" SUBMITTED "$(field "$dir/journal" identity)"; printf 'HARNESS_SESSION_ROOT=%s\nstate=SUBMITTED\n' "$(<"$dir/session-root")"; return 0; }
        while IFS= read -r -d '' kind && IFS= read -r -d '' mode && IFS= read -r -d '' hash && IFS= read -r -d '' path; do
          if [[ "$kind" == D ]]; then git -C "$readback" cat-file -e "$pending:$path" 2>/dev/null && { rm -rf "$readback"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 4; }; continue; fi
          actual_mode=""; actual_oid=""; entry="$(git -C "$readback" ls-tree "$pending" -- ":(literal)$path")"; [[ -z "$entry" ]] || read -r actual_mode actual_type actual_oid actual_path <<< "$entry"
          [[ "$actual_mode" == "$mode" && "$actual_oid" == "$hash" ]] || { rm -rf "$readback"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 4; }
        done < "$dir/.candidate-manifest"
        printf '%s\n' "$pending" > "$dir/delivered-sha"
        mv -f "$dir/.candidate-manifest" "$dir/delivered-manifest"
        rm -rf "$readback"; transition "$id" DELIVERED "$(field "$dir/journal" identity)"
        printf 'HARNESS_SESSION_ROOT=%s\nstate=DELIVERED\n' "$(<"$dir/session-root")"
        return 0
      fi
    fi
    transition "$id" SUBMITTED "$(field "$dir/journal" identity)"
    printf 'HARNESS_SESSION_ROOT=%s\nstate=SUBMITTED\n' "$(<"$dir/session-root")"
    return 0
  fi
  [[ "$state" == ABANDONED || "$state" == CONFLICT ]] || return 2
  reopen_session "$id"
  printf 'HARNESS_SESSION_ROOT=%s\nstate=OPEN\n' "$(<"$dir/session-root")"
}
recover() { with_lock recover_unlocked "$1"; }
heartbeat_epoch() { date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || printf '0\n'; }
heartbeat_session() {
  local dir="$(session_dir "$1")" state
  [[ -f "$dir/journal" ]] || return 2
  state="$(field "$dir/journal" state)"
  [[ "$state" == OPEN ]] || return 0
  write_heartbeat "$dir"
}
list() {
  local dir id state heartbeat now age limit
  now="$(date -u +%s)"; limit="${HARNESS_SESSION_STALE_SECONDS:-300}"
  for dir in "$(state_home)"/sessions/*; do
    [[ -d "$dir" && -f "$dir/journal" ]] || continue
    id="${dir##*/}"; state="$(field "$dir/journal" state)"
    if [[ -f "$dir/heartbeat" ]]; then heartbeat="$(heartbeat_epoch "$(<"$dir/heartbeat")")"; else heartbeat="$(heartbeat_epoch "$(field "$dir/journal" heartbeat)")"; fi
    age=$((now - heartbeat))
    if [[ "$state" == OPEN && "$age" -gt "$limit" ]]; then transition "$id" ABANDONED; state=ABANDONED; fi
    printf '%s %s\n' "$id" "$state"
  done
}
write_index_manifest() {
  local root="$1" base="$2" output="$3" status path mode oid stage path2 entry
  root_git "$root" diff --no-ext-diff --ignore-submodules=all --cached --name-status --no-renames -z "$base" -- . "${EXCLUDED_PATHSPEC[@]}" > "$output.paths" || return 1
  : > "$output"
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    if [[ "$status" == D* ]]; then printf 'D\0-\0-\0%s\0' "$path" >> "$output"; continue; fi
    entry="$(root_git "$root" ls-files -s -- ":(literal)$path")" && [[ -n "$entry" ]] || return 1
    read -r mode oid stage path2 <<< "$entry"
    printf 'F\0%s\0%s\0%s\0' "$mode" "$oid" "$path" >> "$output"
  done < "$output.paths"
  rm -f "$output.paths"
}
submission_identity() {
  local dir="$1"
  { shasum -a 256 "$dir/base-sha" "$dir/source-root" "$dir/remote-url" "$dir/submission.patch" "$dir/manifest"; } | shasum -a 256 | awk '{print $1}'
}
submit() {
  local id="$1" dir root base state identity
  dir="$(session_dir "$id")"; root="$(<"$dir/session-root")"; base="$(<"$dir/base-sha")"; state="$(field "$dir/journal" state)"
  [[ "$state" == SUBMITTED ]] && return 0
  [[ "$state" == OPEN ]] || { echo "cannot submit $state session" >&2; return 2; }
  use_session_git "$id" || return $?
  stage_worktree "$root" "$base"
  if [[ -z "$ROOT_GIT_DIR" ]]; then
    # Interactive: committed work is in the index already, so staged excluded
    # paths are only unstaged back to HEAD; committed ones refuse instead of
    # being silently dropped. A headless index is reset to the base there.
    local touched aliases
    touched="$(session_git -C "$root" diff --no-ext-diff --ignore-submodules=all --cached --name-only "$base" -- "${EXCLUDED_ICASE[@]}")" \
      && aliases="$(excluded_aliases "$root" "$base" | tr '\0' '\n')" \
      || { echo 'harness-session: refused: could not check the submission for excluded paths' >&2; return 2; }
    touched="$touched${aliases:+$'\n'$aliases}"
    [[ -z "$touched" ]] || { printf 'harness-session: refused: submission touches excluded path(s):\n%s\n' "$touched" >&2; return 7; }
  fi
  root_git "$root" diff --no-ext-diff --no-textconv --ignore-submodules=all --cached --binary "$base" -- . "${EXCLUDED_PATHSPEC[@]}" > "$dir/submission.patch"
  [[ -s "$dir/submission.patch" ]] || { echo 'empty submission' >&2; return 2; }
  write_index_manifest "$root" "$base" "$dir/.manifest"
  mv -f "$dir/.manifest" "$dir/manifest"
  git -C "$(<"$dir/source-root")" remote get-url origin > "$dir/remote-url"
  identity="$(submission_identity "$dir")"
  chmod 0444 "$dir/base-sha" "$dir/source-root" "$dir/remote-url" "$dir/submission.patch" "$dir/manifest"
  transition "$id" SUBMITTED "$identity"
}
with_lock() {
  local lock="$(state_home)/integration.lock" timeout="${HARNESS_SESSION_LOCK_TIMEOUT:-600}"
  [[ -x /usr/bin/lockf ]] || { echo 'ERROR: /usr/bin/lockf is required for safe session integration' >&2; return 1; }
  mkdir -p "$(state_home)"
  (
    /usr/bin/lockf -s -t "$timeout" 9 || { echo 'ERROR: timed out waiting for session integration lock' >&2; return 1; }
    "$@"
  ) 9>"$lock"
}
write_candidate_manifest() {
  local repo="$1" tree="$2" submitted="$3" output="$4" kind old_mode old_oid path entry meta mode type oid
  : > "$output"
  while IFS= read -r -d '' kind && IFS= read -r -d '' old_mode && IFS= read -r -d '' old_oid && IFS= read -r -d '' path; do
    # Empty output is a deletion; an ls-tree error is not.
    entry="$(git -C "$repo" ls-tree "$tree" -- ":(literal)$path")" || return 1
    if [[ -z "$entry" ]]; then
      printf 'D\0-\0-\0%s\0' "$path" >> "$output"
      continue
    fi
    meta="${entry%%$'\t'*}"
    read -r mode type oid <<< "$meta"
    printf 'F\0%s\0%s\0%s\0' "$mode" "$oid" "$path" >> "$output"
  done < "$submitted"
}
verify_submission_identity() {
  local dir="$1" expected
  expected="$(field "$dir/journal" identity)"
  [[ -n "$expected" && "$(submission_identity "$dir")" == "$expected" ]]
}
# The headless verifier runs candidate content (repository tests the agent may
# have written), so it runs under Seatbelt, the mechanism Claude Code itself
# uses on macOS, on a throwaway copy of the candidate the broker never reads
# back. Fixed path: nothing in the environment chooses it.
SANDBOX_EXEC=/usr/bin/sandbox-exec
# Mach services a sandboxed bash, git or python needs: user and group lookup
# and logging. Everything else (launchd job submission, LaunchServices,
# AppleEvents, XPC services, the keychain) is unreachable.
SANDBOX_MACH_ALLOW=(com.apple.system.opendirectoryd.libinfo com.apple.system.logger com.apple.logd
  com.apple.diagnosticd com.apple.system.notification_center)
# phys <path>: the physical path of an existing directory (Seatbelt matches
# resolved paths), otherwise the path itself.
phys() { if [[ -d "$1" ]]; then (cd -P "$1" && pwd); else printf '%s\n' "$1"; fi; }
sbpl_str() { local value="${1//\\/\\\\}"; printf '"%s"' "${value//\"/\\\"}"; }
# verifier_sandbox_profile <copy> <tmp> <home> <source> <trusted>: the SBPL
# profile. No network (unix sockets only inside the temp dir); writes only to
# the copy and the temp dir; nothing under HOME is readable except the copy,
# the temp dir, the trusted verifier, git config and toolchains (PATH entries
# under HOME, mise); credential stores and the source checkout never are; no
# mach services beyond SANDBOX_MACH_ALLOW; no AppleEvents; signals and
# process inspection only within the sandbox.
verifier_sandbox_profile() {
  local copy tmp home source="$4" trusted path entry name
  copy="$(phys "$1")"; tmp="$(phys "$2")"; home="$(phys "$3")"; trusted="$(phys "$5")"
  local -a readable=("$copy" "$tmp" "$trusted" "$home/.config/git" "$home/.config/mise" "$home/.local/share/mise"
    "$home/.cache/mise" "$home/.local/state/mise") deny=()
  local -a path_entries=()
  IFS=: read -r -a path_entries <<< "${PATH:-}"
  for entry in "${path_entries[@]}"; do
    [[ -d "$entry" ]] || continue
    entry="$(phys "$entry")"
    [[ "$entry" != "$home" && "$entry" == "$home"/* ]] && readable+=("$entry")
  done
  for path in "$home/.ssh" "$home/.hermes" "$home/buzz" "$home/.config/gh" "$home/.aws" "$home/.claude" \
      "$home/Library/Keychains" "$source"; do
    deny+=("$path")
    [[ ! -e "$path" ]] || deny+=("$(phys "$path")")
  done
  printf '(version 1)\n(allow default)\n'
  printf '(deny network*)\n(allow network* (local unix-socket (subpath %s)))\n' "$(sbpl_str "$tmp")"
  printf '(allow network* (remote unix-socket (subpath %s)))\n' "$(sbpl_str "$tmp")"
  printf '(deny file-write*)\n(allow file-write* (subpath %s) (subpath %s)' "$(sbpl_str "$copy")" "$(sbpl_str "$tmp")"
  printf ' (literal "/dev/null") (literal "/dev/tty") (subpath "/dev/fd"))\n'
  printf '(deny file-read-data (subpath %s))\n(allow file-read-data (literal %s)' "$(sbpl_str "$home")" "$(sbpl_str "$home/.gitconfig")"
  for path in "${readable[@]}"; do printf ' (subpath %s)' "$(sbpl_str "$path")"; done
  printf ')\n(deny file-read*'
  for path in "${deny[@]}"; do printf ' (subpath %s)' "$(sbpl_str "$path")"; done
  printf ')\n(deny mach-lookup)\n(allow mach-lookup'
  for name in "${SANDBOX_MACH_ALLOW[@]}"; do printf ' (global-name "%s")' "$name"; done
  printf ')\n(deny appleevent-send)\n'
  printf '(deny signal)\n(allow signal (target same-sandbox))\n'
  printf '(deny process-info*)\n(allow process-info* (target same-sandbox))\n'
}
# sandbox_check <sandbox-exec>: does the profile load and run here?
sandbox_check() {
  local exe="$1" dir rc=0
  dir="$(mktemp -d "${TMPDIR:-/tmp}/harness-sandbox-check.XXXXXX")" || return 1
  mkdir "$dir/candidate" "$dir/tmp" "$dir/trusted" || { rm -rf "$dir"; return 1; }
  "$exe" -p "$(verifier_sandbox_profile "$dir/candidate" "$dir/tmp" "${HOME:?}" "$dir/source" "$dir/trusted")" /usr/bin/true || rc=$?
  rm -rf "$dir"
  return "$rc"
}
run_repository_verifier() {
  local candidate="$1" id="$2" remote="$3" baseline="$4" trusted verifier help_output
  local -a verifier_args
  trusted="$(mktemp -d "$(state_home)/verifier.XXXXXX")" || return 2
  { git clone -q "$remote" "$trusted" && git -C "$trusted" checkout -q --detach "$baseline"; } || { rm -rf "$trusted"; return 2; }
  verifier="$trusted/core/bin/auto-deliver.sh"
  [[ -f "$verifier" ]] || { echo 'ERROR: repository-owned core/bin/auto-deliver.sh verifier is required' >&2; rm -rf "$trusted"; return 2; }
  verifier_args=("verify isolated session $id" --staged-only --dry-run --no-push)
  if [[ -e "$(session_dir "$id")/headless" ]]; then
    run_sandboxed_verifier "$candidate" "$id" "$trusted" "$verifier" "${verifier_args[@]}"
    return
  fi
  help_output="$(bash "$verifier" --help 2>/dev/null || true)"
  if grep -q -- '--contract-checked' <<< "$help_output"; then
    verifier_args+=(--contract-checked 'broker candidate cascade verified')
  fi
  local rc=0
  (unset HARNESS_SESSION_ID HARNESS_SOURCE_ROOT HARNESS_SESSION_ROOT HARNESS_RUN_DIR HARNESS_SESSION_STATE_HOME; cd "$candidate" && TEST_HARNESS_DIR="$candidate" HARNESS_POST_COMMIT_PUSH=0 HARNESS_POST_COMMIT_CODEX_SYNC=0 HARNESS_RAG_ENABLED=0 HARNESS_SESSION_BACKLINK=0 \
    bash "$verifier" "${verifier_args[@]}") || rc=$?
  rm -rf "$trusted"
  return "$rc"
}
# run_sandboxed_verifier <candidate> <id> <trusted> <verifier> <args...>:
# headless sessions only. The verifier gets a copy of the candidate (index
# included, no hard links), a minimal environment (no agent sockets, tokens or
# GitHub variables) and a fresh temp dir; the copy and the temp dir are
# removed afterwards and nothing is read back. The broker commits and pushes
# from the candidate itself, which the sandbox never touched.
run_sandboxed_verifier() {
  local candidate="$1" id="$2" trusted="$3" verifier="$4" source vtmp vcopy profile help_output name rc=0
  shift 4
  local -a args=("$@") venv=()
  [[ -x "$SANDBOX_EXEC" ]] || { echo "harness-session: refused: $SANDBOX_EXEC is required to verify a headless session" >&2; rm -rf "$trusted"; return 2; }
  source="$(<"$(session_dir "$id")/source-root")" || { rm -rf "$trusted"; return 2; }
  vtmp="$(mktemp -d "$(state_home)/verifier-tmp.XXXXXX")" || { rm -rf "$trusted"; return 2; }
  vcopy="$(mktemp -d "$(state_home)/verifier-copy.XXXXXX")" || { rm -rf "$trusted" "$vtmp"; return 2; }
  { vtmp="$(phys "$vtmp")" && vcopy="$(phys "$vcopy")" && cp -R "$candidate/." "$vcopy/" \
      && profile="$(verifier_sandbox_profile "$vcopy" "$vtmp" "${HOME:?}" "$source" "$trusted")"; } \
    || { rm -rf "$trusted" "$vtmp" "$vcopy"; return 2; }
  venv=(HOME="$HOME" PATH="${PATH:-/usr/bin:/bin}" TMPDIR="$vtmp")
  [[ -z "${LANG:-}" ]] || venv+=(LANG="$LANG")
  for name in $(compgen -e); do [[ "$name" != LC_* ]] || venv+=("$name=${!name}"); done
  help_output="$(cd "$vcopy" && env -i "${venv[@]}" "$SANDBOX_EXEC" -p "$profile" bash "$verifier" --help 2>/dev/null || true)"
  if grep -q -- '--contract-checked' <<< "$help_output"; then
    args+=(--contract-checked 'broker candidate cascade verified')
  fi
  (cd "$vcopy" && env -i "${venv[@]}" TEST_HARNESS_DIR="$vcopy" HARNESS_POST_COMMIT_PUSH=0 HARNESS_POST_COMMIT_CODEX_SYNC=0 \
    HARNESS_RAG_ENABLED=0 HARNESS_SESSION_BACKLINK=0 "$SANDBOX_EXEC" -p "$profile" bash "$verifier" "${args[@]}") || rc=$?
  rm -rf "$trusted" "$vtmp" "$vcopy"
  return "$rc"
}
write_manifest_pathset() {
  local manifest="$1" output="$2" kind mode oid path
  : > "$output"
  while IFS= read -r -d '' kind && IFS= read -r -d '' mode && IFS= read -r -d '' oid && IFS= read -r -d '' path; do
    printf '%s\0%s\0' "$kind" "$path" >> "$output"
  done < "$manifest"
}
write_index_pathset() {
  local repo="$1" base="$2" output="$3" status path kind
  : > "$output"
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    kind=F; [[ "$status" == D* ]] && kind=D
    printf '%s\0%s\0' "$kind" "$path" >> "$output"
  done < <(git -C "$repo" diff --cached --name-status --no-renames -z "$base")
}
integrate_unlocked() {
  local id="$1" dir source remote attempt candidate current delivered readback kind mode hash path actual_mode actual_type actual_oid actual_path entry
  dir="$(session_dir "$id")"; source="$(<"$dir/source-root")"
  remote="$(git -C "$source" remote get-url origin)"
  [[ "$remote" == "$(<"$dir/remote-url")" ]] || { transition "$id" INTEGRATING "$(field "$dir/journal" identity)"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 2; }
  transition "$id" INTEGRATING "$(field "$dir/journal" identity)"
  verify_submission_identity "$dir" || { transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 2; }
  for attempt in 1 2; do
    candidate="$(mktemp -d "$(state_home)/candidate.XXXXXX")"
    git clone -q "$remote" "$candidate"
    git -C "$candidate" checkout -q main
    current="$(git -C "$candidate" rev-parse HEAD)"
    if ! git -C "$candidate" apply --3way --index "$dir/submission.patch"; then rm -rf "$candidate"; transition "$id" CONFLICT; return 3; fi
    write_manifest_pathset "$dir/manifest" "$dir/.submitted-pathset"
    write_index_pathset "$candidate" "$current" "$dir/.candidate-pathset"
    cmp -s "$dir/.submitted-pathset" "$dir/.candidate-pathset" || { rm -rf "$candidate"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 3; }
    run_repository_verifier "$candidate" "$id" "$remote" "$current" || {
      rm -rf "$candidate"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"
      # Headless: exit 9, the verifier rejected the candidate (not a merge conflict).
      if [[ -e "$dir/headless" ]]; then return 9; fi
      return 3
    }
    verify_submission_identity "$dir" || { rm -rf "$candidate"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 2; }
    [[ "${HARNESS_SESSION_TEST_CRASH_BEFORE_PUSH:-0}" == 1 ]] && kill -9 "$BASHPID"
    # Headless: no hooks, fsmonitor or external drivers on the broker's own
    # commit and push (the verifier never touched this dir; belt and braces).
    local -a cgit=(git)
    [[ ! -e "$dir/headless" ]] || cgit=(session_git)
    "${cgit[@]}" -C "$candidate" -c user.name=harness-broker -c user.email=broker@invalid commit -qm "harness session $id"
    delivered="$(git -C "$candidate" rev-parse HEAD)"
    write_candidate_manifest "$candidate" "$delivered" "$dir/manifest" "$dir/.candidate-manifest" || { rm -rf "$candidate"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 2; }
    printf '%s\n' "$delivered" > "$dir/pending-sha"
    git -C "$candidate" fetch -q origin main
    [[ "$(git -C "$candidate" rev-parse origin/main)" == "$current" ]] || { rm -rf "$candidate"; continue; }
    if "${cgit[@]}" -C "$candidate" push -q origin HEAD:refs/heads/main; then
      [[ "${HARNESS_SESSION_TEST_CRASH_BEFORE_ACK:-0}" == 1 ]] && kill -9 "$BASHPID"
      printf '%s\n' "$delivered" > "$dir/push-ack"
      [[ "${HARNESS_SESSION_TEST_CRASH_AFTER_PUSH:-0}" == 1 ]] && kill -9 "$BASHPID"
      if [[ "${HARNESS_SESSION_TEST_POST_PUSH_DELAY:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then sleep "$HARNESS_SESSION_TEST_POST_PUSH_DELAY"; fi
      # A transport/readback outage after a successful push is indeterminate,
      # not a content conflict. Keep INTEGRATING so recover can prove the
      # pending commit from fresh remote history without resubmitting it.
      [[ "${HARNESS_SESSION_TEST_READBACK_FAIL:-0}" == 1 ]] && { rm -rf "$candidate"; return 4; }
      readback="$(mktemp -d "$(state_home)/readback.XXXXXX")"
      git clone -q "$remote" "$readback"
      git -C "$readback" merge-base --is-ancestor "$delivered" HEAD || { rm -rf "$candidate" "$readback"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 4; }
      while IFS= read -r -d '' kind && IFS= read -r -d '' mode && IFS= read -r -d '' hash && IFS= read -r -d '' path; do
        if [[ "$kind" == D ]]; then git -C "$readback" cat-file -e "$delivered:$path" 2>/dev/null && { rm -rf "$candidate" "$readback"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 4; }; continue; fi
        actual_mode=""; actual_oid=""; entry="$(git -C "$readback" ls-tree "$delivered" -- ":(literal)$path")"; [[ -z "$entry" ]] || read -r actual_mode actual_type actual_oid actual_path <<< "$entry"
        [[ "$actual_mode" == "$mode" && "$actual_oid" == "$hash" ]] || { rm -rf "$candidate" "$readback"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 4; }
      done < "$dir/.candidate-manifest"
      printf '%s\n' "$delivered" > "$dir/delivered-sha"
      mv -f "$dir/.candidate-manifest" "$dir/delivered-manifest"
      rm -rf "$candidate" "$readback"; transition "$id" DELIVERED "$(field "$dir/journal" identity)"; return 0
    fi
    rm -rf "$candidate"
  done
  transition "$id" CONFLICT "$(field "$dir/journal" identity)"
  return 5
}
integrate() { with_lock integrate_unlocked "$@"; }
close_session() {
  local id="$1" dir state root
  dir="$(session_dir "$id")"; state="$(field "$dir/journal" state)"; root="$(<"$dir/session-root")"
  use_session_git "$id" || return $?
  if [[ "$state" == OPEN ]]; then
    local rc=0
    session_has_changes "$root" "$(<"$dir/base-sha")" || rc=$?
    [[ "$rc" != 2 ]] || { echo 'harness-session: refused: could not read the session changes' >&2; return 2; }
    [[ "$rc" != 1 ]] || { transition "$id" CLOSED; return 0; }
  fi
  [[ "$state" == OPEN ]] && submit "$id"
  [[ "$(field "$dir/journal" state)" == SUBMITTED ]] || { echo "cannot close $state session" >&2; return 2; }
  integrate "$id"
}
case "${1:-}" in
  create) shift; [[ $# -eq 1 ]] || exit 2; create "$1" ;;
  resume) shift; [[ $# -eq 2 ]] || exit 2; resume_session "$1" "$2" ;;
  transition) shift; transition "$@" ;;
  exit) shift; exit_session "$1" ;;
  recover) shift; recover "$1" ;;
  list) list ;;
  heartbeat) shift; heartbeat_session "$1" ;;
  gc) shift; [[ $# -eq 0 ]] || exit 2; gc_sessions ;;
  sandbox-check) shift; [[ $# -eq 1 ]] || exit 2; sandbox_check "$1" ;;
  submit) shift; submit "$1" ;;
  integrate) shift; [[ $# -eq 1 ]] || exit 2; integrate "$1" ;;
  close) shift; [[ $# -eq 1 ]] || exit 2; close_session "$1" ;;
  *) echo 'usage: harness-session {create|resume|transition|exit|recover|list|heartbeat|gc|submit|integrate|close|sandbox-check}' >&2; exit 2 ;;
esac
