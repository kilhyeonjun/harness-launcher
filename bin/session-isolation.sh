#!/usr/bin/env bash
# Durable, opt-in isolated harness session repositories.
set -euo pipefail

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
reopen_session() {
  local id="$1" dir
  dir="$(session_dir "$id")"
  chmod u+w "$dir/submission.patch" "$dir/manifest" "$dir/remote-url" 2>/dev/null || true
  rm -f "$dir/pending-sha" "$dir/push-ack" "$dir/.candidate-manifest"
  transition "$id" OPEN
  write_heartbeat "$dir"
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
  git clone -q --no-checkout "$source" "$root"
  git -C "$root" remote remove origin
  git -C "$root" checkout -q --detach "$sha"
  rm -rf "$root/config/.local"
  if [[ -d "$source/projects" ]]; then rm -rf "$root/projects"; ln -s "$source/projects" "$root/projects"; fi
  for local_file in .mcp.local.json mcp.local.json .claude/settings.local.json; do
    if [[ -f "$source/$local_file" && ! -e "$root/$local_file" ]]; then
      mkdir -p "$(dirname "$root/$local_file")"
      ln -s "$source/$local_file" "$root/$local_file"
    fi
  done
  printf '%s\n' "$source" > "$dir/source-root"
  printf '%s\n' "$root" > "$dir/session-root"
  printf '%s\n' "$sha" > "$dir/base-sha"
  write_journal "$dir" OPEN ""
  write_heartbeat "$dir"
  printf 'HARNESS_SESSION_ID=%s\nHARNESS_SOURCE_ROOT=%s\nHARNESS_SESSION_ROOT=%s\nHARNESS_RUN_DIR=%s\n' "$id" "$source" "$root" "$root"
}
resume_session() {
  local source="$1" id="$2" dir recorded root state
  source="$(cd "$source" && pwd -P)"; dir="$(session_dir "$id")"
  [[ -d "$dir" && -f "$dir/source-root" && -f "$dir/session-root" && -f "$dir/journal" ]] || return 2
  recorded="$(cd "$(<"$dir/source-root")" && pwd -P)"; [[ "$recorded" == "$source" ]] || return 2
  root="$(<"$dir/session-root")"; [[ -d "$root" ]] || return 2; state="$(field "$dir/journal" state)"
  case "$state" in
    OPEN) ;;
    ABANDONED|CONFLICT|CLOSED) reopen_session "$id" ;;
    *) echo "cannot resume $state session" >&2; return 2 ;;
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
session_has_changes() {
  [[ -n "$(git -C "$1" status --porcelain --untracked-files=all -- . ':!config/.local' ':!projects' ':!.mcp.local.json' ':!mcp.local.json' ':!.claude/settings.local.json')" ]]
}
exit_session() {
  local id="$1" dir root state
  dir="$(session_dir "$id")"; root="$(<"$dir/session-root")"; state="$(field "$dir/journal" state)"
  if [[ "$state" == OPEN ]]; then
    if session_has_changes "$root"; then transition "$id" ABANDONED; else transition "$id" CLOSED; fi
  fi
}
recover_unlocked() {
  local id="$1" dir state source remote pending readback kind mode hash path actual_mode actual_type actual_oid actual_path
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
          read -r actual_mode actual_type actual_oid actual_path < <(git -C "$readback" ls-tree "$pending" -- "$path")
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
  local root="$1" base="$2" output="$3" status path mode oid stage path2
  : > "$output"
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    if [[ "$status" == D* ]]; then printf 'D\0-\0-\0%s\0' "$path" >> "$output"; continue; fi
    read -r mode oid stage path2 < <(git -C "$root" ls-files -s -- "$path")
    printf 'F\0%s\0%s\0%s\0' "$mode" "$oid" "$path" >> "$output"
  done < <(git -C "$root" diff --cached --name-status --no-renames -z "$base")
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
  git -C "$root" add -A -- . ':!config/.local' ':!projects' ':!.mcp.local.json' ':!mcp.local.json' ':!.claude/settings.local.json'
  git -C "$root" diff --cached --binary "$base" > "$dir/submission.patch"
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
    entry=""
    IFS= read -r -d '' entry < <(git -C "$repo" ls-tree -z "$tree" -- "$path") || true
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
run_repository_verifier() {
  local candidate="$1" id="$2" remote="$3" baseline="$4" trusted verifier help_output
  local -a verifier_args
  trusted="$(mktemp -d "$(state_home)/verifier.XXXXXX")"
  git clone -q "$remote" "$trusted"
  git -C "$trusted" checkout -q --detach "$baseline"
  verifier="$trusted/core/bin/auto-deliver.sh"
  [[ -f "$verifier" ]] || { echo 'ERROR: repository-owned core/bin/auto-deliver.sh verifier is required' >&2; rm -rf "$trusted"; return 2; }
  verifier_args=("verify isolated session $id" --staged-only --dry-run --no-push)
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
  local id="$1" dir source remote attempt candidate current delivered readback
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
    run_repository_verifier "$candidate" "$id" "$remote" "$current" || { rm -rf "$candidate"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 3; }
    verify_submission_identity "$dir" || { rm -rf "$candidate"; transition "$id" CONFLICT "$(field "$dir/journal" identity)"; return 2; }
    [[ "${HARNESS_SESSION_TEST_CRASH_BEFORE_PUSH:-0}" == 1 ]] && kill -9 "$BASHPID"
    git -C "$candidate" -c user.name=harness-broker -c user.email=broker@invalid commit -qm "harness session $id"
    delivered="$(git -C "$candidate" rev-parse HEAD)"
    write_candidate_manifest "$candidate" "$delivered" "$dir/manifest" "$dir/.candidate-manifest"
    printf '%s\n' "$delivered" > "$dir/pending-sha"
    git -C "$candidate" fetch -q origin main
    [[ "$(git -C "$candidate" rev-parse origin/main)" == "$current" ]] || { rm -rf "$candidate"; continue; }
    if git -C "$candidate" push -q origin HEAD:refs/heads/main; then
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
        read -r actual_mode actual_type actual_oid actual_path < <(git -C "$readback" ls-tree "$delivered" -- "$path")
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
  if [[ "$state" == OPEN ]] && ! session_has_changes "$root"; then transition "$id" CLOSED; return 0; fi
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
  submit) shift; submit "$1" ;;
  integrate) shift; [[ $# -eq 1 ]] || exit 2; integrate "$1" ;;
  close) shift; [[ $# -eq 1 ]] || exit 2; close_session "$1" ;;
  *) echo 'usage: harness-session {create|resume|transition|exit|recover|list|heartbeat|submit|integrate|close}' >&2; exit 2 ;;
esac
