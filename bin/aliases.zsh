#!/usr/bin/env zsh
# harness-launcher — generic zsh launcher function + tab completion
# Usage:
#   source /path/to/harness-launcher/bin/aliases.zsh
#   harness_register /path/to/some-harness

_HARNESS_LAUNCHER_BIN="$(cd "$(dirname "${(%):-%x}")" 2>/dev/null && pwd)"
typeset -ga _HARNESS_LAUNCHER_REGISTERED_DIRS=()
if (( ${+parameters[_HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED]} )) && \
    [[ "${(t)_HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED}" == *-export* ]]; then
  unset _HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED
fi
typeset -gi _HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED="${_HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED:-0}"
typeset -g +x _HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED
if (( _HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED )); then
  typeset -gi _HARNESS_LAUNCHER_SHELL_AUTO_ENABLED="${_HARNESS_LAUNCHER_SHELL_AUTO_ENABLED:-1}"
else
  typeset -gi _HARNESS_LAUNCHER_SHELL_AUTO_ENABLED=0
fi
typeset -g +x _HARNESS_LAUNCHER_SHELL_AUTO_ENABLED
typeset -g _HARNESS_LAUNCHER_CODEX_WRAPPER_BODY=""

# Single source of truth for mode tables, bin resolution, probes, MCP config
# validation, secrets export, and autocompact PCT — shared with launcher.sh.
source "$_HARNESS_LAUNCHER_BIN/harness-common.sh"

_harness_launcher_codex_bin() { harness_codex_bin_resolve "$@"; }

_harness_launcher_probe_provider_health() { harness_probe_health "$@"; }

_harness_launcher_mcp_local_configs() { harness_mcp_local_configs "$@"; }

_harness_launcher_validate_mcp_local_configs() { harness_validate_mcp_local_configs "$@"; }

_harness_launcher_isolated_session_create() {
  local source_root="$1" session_id="${2:-}" output key value
  if [[ -n "$session_id" ]]; then
    output="$("$_HARNESS_LAUNCHER_BIN/session-isolation.sh" resume "$source_root" "$session_id")" || return $?
  else
    output="$("$_HARNESS_LAUNCHER_BIN/session-isolation.sh" create "$source_root")" || return $?
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      HARNESS_SESSION_ID|HARNESS_SOURCE_ROOT|HARNESS_SESSION_ROOT) export "$key=$value" ;;
    esac
  done <<< "$output"
}

# _harness_launcher_resolve_orca_resume <source-root> [launcher argv...]
#   Orca restores an agent as `<override> <default args> --resume <id>` (Claude)
#   or `<override> codex resume <id>` (Codex). Map that single UUID back to the
#   isolated session that owns it. Prints the session directory name (uppercase
#   UUID) and returns 0 on a unique owner; 1 when there is no owner (caller keeps
#   its reject message); 3 when several sessions own the id (ambiguous).
#   Only sessions recorded for this harness (source-root) count; symlinks are
#   never followed.
_harness_launcher_resolve_orca_resume() {
  local source_root="$1"; shift
  local uuid_re='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
  local -a candidates=()
  local id="" is_codex=false arg prev=""
  if [[ "${1:-}" == codex ]]; then
    is_codex=true; shift
    for arg in "$@"; do
      [[ "$arg" == -- ]] && break
      [[ "$prev" == resume ]] && candidates+=("$arg")
      prev="$arg"
    done
  else
    for arg in "$@"; do
      [[ "$arg" == -- ]] && break
      case "$arg" in
        --resume=*) candidates+=("${arg#--resume=}") ;;
        -r?*) candidates+=("${arg#-r}") ;;
        *) [[ "$prev" == (--resume|-r) ]] && candidates+=("$arg") ;;
      esac
      prev="$arg"
    done
  fi
  (( ${#candidates} == 1 )) || return 1
  [[ "${candidates[1]}" =~ $uuid_re ]] || return 1
  id="${(L)candidates[1]}"

  local state_home="${HARNESS_SESSION_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/harness-launcher}"
  local sessions="$state_home/sessions" dir name recorded
  local -a owners=() hits=()
  if $is_codex; then
    local rollout
    for rollout in "$state_home"/worktrees/*/.harness/codex/sessions/*/*/*/rollout-*-$id.jsonl(N); do
      [[ -f "$rollout" && ! -L "$rollout" ]] || continue
      name="${${rollout#$state_home/worktrees/}%%/*}"
      hits+=("$name")
    done
  else
    for dir in "$sessions"/*(/N); do
      name="${dir:t}"
      [[ "${(L)name}" == "$id" ]] && hits+=("$name")
    done
  fi
  for name in "${hits[@]}"; do
    dir="$sessions/$name"
    [[ "$name" =~ $uuid_re && -d "$dir" && ! -L "$dir" && -f "$dir/source-root" && ! -L "$dir/source-root" ]] || continue
    recorded="$(<"$dir/source-root")"
    [[ -d "$recorded" && "${recorded:A}" == "$source_root" ]] || continue
    owners+=("$name")
  done
  owners=(${(u)owners})
  (( ${#owners} <= 1 )) || return 3
  (( ${#owners} == 1 )) || return 1
  print -r -- "${owners[1]}"
}

_harness_launcher_isolated_heartbeat() {
  local session_id="$1" interval="${HARNESS_SESSION_HEARTBEAT_SECONDS:-30}"
  while "$_HARNESS_LAUNCHER_BIN/session-isolation.sh" heartbeat "$session_id" 2>/dev/null; do
    sleep "$interval"
  done
}

_harness_launcher_isolated_finish() {
  local session_id="$1" heartbeat_pid="${2:-}" lease_fd="${3:-}"
  if [[ -n "$heartbeat_pid" ]]; then
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
  fi
  if ! "$_HARNESS_LAUNCHER_BIN/session-isolation.sh" exit "$session_id"; then
    echo "harness-launcher: warning: failed to finalize isolated session $session_id; workspace retained" >&2
  fi
  if [[ -n "$lease_fd" ]]; then
    zsystem flock -u "$lease_fd" 2>/dev/null || true
  fi
}

_harness_launcher_isolated_lease_acquire() {
  local session_id="$1" state_home record marker lock
  [[ "$session_id" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] || {
    echo "harness-launcher: invalid isolated session UUID: $session_id" >&2
    return 2
  }
  state_home="${HARNESS_SESSION_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/harness-launcher}"
  record="$state_home/sessions/$session_id"; marker="$record/lease-v1"; lock="$record/runtime.lock"
  [[ -d "$record" && ! -L "$record" && -f "$marker" && ! -L "$marker" && "$(wc -c < "$marker" | tr -d ' ')" == 2 && "$(<"$marker")" == 1 && -f "$lock" && ! -L "$lock" ]] || {
    echo "harness-launcher: invalid runtime lease record for $session_id" >&2
    return 2
  }
  zmodload zsh/system || {
    echo 'harness-launcher: zsh/system is required for isolated session leases' >&2
    return 2
  }
  if ! zsystem flock -t 0 -f HARNESS_SESSION_LEASE_FD "$lock" 2>/dev/null; then
    HARNESS_SESSION_LEASE_FD=""
    echo "harness-launcher: isolated session $session_id is already active" >&2
    return 2
  fi
}

_harness_launcher_prepare_codex_global_mcp_allowlist() {
  local raw="${HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST:-}" normalized
  [[ -n "$raw" ]] || { unset HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST; return 0; }
  normalized="$(harness_codex_global_mcp_allowlist_normalize "$raw")" || return $?
  [[ -n "$normalized" ]] && export HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="$normalized" \
    || unset HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST
}

_harness_launcher_prepare_codex_apps_allowlist() {
  local raw="${HARNESS_CODEX_APPS_ALLOWLIST:-}" normalized
  [[ -n "$raw" ]] || { unset HARNESS_CODEX_APPS_ALLOWLIST; return 0; }
  normalized="$(harness_codex_apps_allowlist_normalize "$raw")" || return $?
  [[ -n "$normalized" ]] && export HARNESS_CODEX_APPS_ALLOWLIST="$normalized" \
    || unset HARNESS_CODEX_APPS_ALLOWLIST
}

# _harness_launcher_claude_mcp_local_args <harness-dir>
#   Sets reply to the harness MCP flags (`--mcp-config <rendered>`), or to an
#   empty array when the harness has no local MCP config.
_harness_launcher_claude_mcp_local_args() {
  local rendered
  reply=()
  rendered="$(harness_claude_mcp_runtime_config "$1" "$_HARNESS_LAUNCHER_BIN")" || return $?
  [[ -z "$rendered" ]] || reply=(--mcp-config "$rendered")
}

# _harness_launcher_argv_has_option <option> [args...]
#   True when args contain `<option>` or `<option>=value`.
_harness_launcher_argv_has_option() {
  local option="$1" arg; shift
  for arg in "$@"; do
    [[ "$arg" == "$option" || "$arg" == "$option="* ]] && return 0
  done
  return 1
}

# _harness_launcher_argv_disables_thinking [args...]
#   True for an explicit thinking disable: `--thinking disabled`,
#   `--max-thinking-tokens 0`, or inline JSON `--settings` whose
#   alwaysThinkingEnabled is false. A settings file path is not read.
_harness_launcher_argv_disables_thinking() {
  local -a args=("$@")
  local i arg value
  for (( i = 1; i <= ${#args}; i++ )); do
    arg="${args[i]}"
    case "$arg" in
      --thinking|--max-thinking-tokens|--settings) value="${args[i+1]-}"; (( i++ )) ;;
      --thinking=*|--max-thinking-tokens=*|--settings=*) value="${arg#*=}"; arg="${arg%%=*}" ;;
      *) continue ;;
    esac
    case "$arg" in
      --thinking) [[ "$value" == disabled ]] && return 0 ;;
      --max-thinking-tokens) [[ "$value" == 0 ]] && return 0 ;;
      --settings)
        [[ "$value" == '{'* && "$value" =~ '"alwaysThinkingEnabled"[[:space:]]*:[[:space:]]*false' ]] && return 0 ;;
    esac
  done
  return 1
}

# _harness_launcher_passthrough_reconcile
#   Caller-wins rules for `--passthrough`: an explicit caller --model,
#   --permission-mode or --effort replaces the launcher default instead of
#   duplicating or overriding it, and an explicit caller thinking disable
#   drops the launcher's xhigh/max effort (which requires thinking). Scans
#   claude_passthrough_opts only (the caller argv before its own `--`).
#   Updates the caller's claude_args, env_effort and passthrough_force_thinking
#   (zsh dynamic scope).
_harness_launcher_passthrough_reconcile() {
  local arg caller_effort="" i
  local -a drop=() kept=()
  if [[ -n "$session_flag" ]]; then
    for arg in "${claude_passthrough_opts[@]}"; do
      case "$arg" in
        -c|--continue|-r|-r?*|--resume|--resume=*|--session-id|--session-id=*|--fork-session|--fork-session=*)
          echo "harness-launcher: launcher '${session_flag}' conflicts with '$arg' after --passthrough" >&2
          return 2 ;;
      esac
    done
  fi
  _harness_launcher_argv_has_option --model "${claude_passthrough_opts[@]}" && drop+=(--model)
  _harness_launcher_argv_has_option --permission-mode "${claude_passthrough_opts[@]}" && drop+=(--permission-mode)
  if (( ${#drop} )); then
    for (( i = 1; i <= ${#claude_args}; i++ )); do
      if (( ${drop[(Ie)${claude_args[i]}]} )); then
        (( i++ ))  # skip the option value as well
        continue
      fi
      kept+=("${claude_args[i]}")
    done
    claude_args=("${kept[@]}")
  fi
  if ! _harness_launcher_argv_has_option --effort "${claude_passthrough_opts[@]}"; then
    if [[ "$env_effort" == (xhigh|max) ]] && _harness_launcher_argv_disables_thinking "${claude_passthrough_opts[@]}"; then
      env_effort=""
    fi
    return 0
  fi
  env_effort=""
  for (( i = 1; i <= ${#claude_passthrough_opts}; i++ )); do
    case "${claude_passthrough_opts[i]}" in
      --effort) caller_effort="${claude_passthrough_opts[i+1]-}" ;;
      --effort=*) caller_effort="${claude_passthrough_opts[i]#--effort=}" ;;
    esac
  done
  # Same API constraint as the launcher's own xhigh/max efforts, unless the
  # caller sets thinking itself.
  if [[ "$caller_effort" == (xhigh|max) ]] \
    && ! _harness_launcher_argv_has_option --thinking "${claude_passthrough_opts[@]}" \
    && ! _harness_launcher_argv_has_option --max-thinking-tokens "${claude_passthrough_opts[@]}" \
    && ! _harness_launcher_argv_disables_thinking "${claude_passthrough_opts[@]}"; then
    passthrough_force_thinking=true
  fi
  return 0
}

_harness_launcher_export_codex_runtime_env() {
  local HARNESS_DIR="$1"
  local prepare="$_HARNESS_LAUNCHER_BIN/codex-home-prepare.sh"
  _harness_launcher_prepare_codex_global_mcp_allowlist || return $?
  _harness_launcher_prepare_codex_apps_allowlist || return $?
  if [[ -x "$prepare" ]]; then
    "$prepare" "$HARNESS_DIR" || return $?
  fi

  export CODEX_HOME="$HARNESS_DIR/.harness/codex"

  # MCP secrets from settings.local.json env so codex streamable_http
  # bearer_token_env_var resolves (native codex inherits no other harness env).
  harness_export_local_env "$HARNESS_DIR"
}

_harness_launcher_codex_synthetic_smoke() {
  local HARNESS_DIR="$1" obs_rc
  if harness_observability_load "$HARNESS_DIR"; then
    "$_HARNESS_LAUNCHER_BIN/codex-synthetic-smoke.py" \
      "$HARNESS_OBSERVABILITY_PROFILE" "$HARNESS_OTLP_HTTP_ENDPOINT"
    return $?
  else
    obs_rc=$?
  fi
  [[ "$obs_rc" -eq 1 ]] || return "$obs_rc"
  echo "harness-launcher: observability is not enabled for this profile" >&2
  return 2
}

_harness_launcher_kiro_bin() { harness_kiro_bin_resolve "$@"; }

_harness_launcher_export_kiro_runtime_env() {
  local HARNESS_DIR="$1"
  local prepare="$_HARNESS_LAUNCHER_BIN/kiro-home-prepare.sh"
  if [[ -x "$prepare" ]]; then
    "$prepare" "$HARNESS_DIR" || return $?
  fi
  export KIRO_HOME="$HARNESS_DIR/.harness/kiro"
  harness_export_local_env "$HARNESS_DIR"
}

_harness_launcher_codex_cd_arg() {
  local -a args=("$@")
  local i arg
  for (( i = 1; i <= ${#args[@]}; i++ )); do
    arg="${args[$i]}"
    case "$arg" in
      --cd|-C)
        (( i < ${#args[@]} )) && print -r -- "${args[$((i + 1))]}"
        return 0
        ;;
      --cd=*)
        print -r -- "${arg#--cd=}"
        return 0
        ;;
    esac
  done
  return 1
}

_harness_launcher_codex_harness_for_args() {
  local cd_arg cd_abs registered
  cd_arg="$(_harness_launcher_codex_cd_arg "$@")" || return 1
  [[ -n "$cd_arg" && -d "$cd_arg" ]] || return 1
  cd_abs="${cd_arg:A}"

  for registered in "${_HARNESS_LAUNCHER_REGISTERED_DIRS[@]}"; do
    [[ "$cd_abs" == "$registered" ]] && {
      print -r -- "$registered"
      return 0
    }
  done

  if [[ -f "$cd_abs/config/launcher.env" ]]; then
    print -r -- "$cd_abs"
    return 0
  fi

  return 1
}

_harness_launcher_auto_runtime() {
  local runtime="$1"; shift
  local harness_auto="$_HARNESS_LAUNCHER_BIN/harness-auto"
  [[ -x "$harness_auto" ]] || {
    echo "harness-launcher: missing executable: $harness_auto" >&2
    return 2
  }
  # Plain commands keep native argv: everything goes after --passthrough, so
  # `claude rich` is a prompt and `codex -a never` is a Codex option. Use
  # `<prefix> <keyword>` for launcher presets.
  if [[ "$runtime" == claude ]]; then
    if _harness_launcher_is_claude_management_command "${1:-}"; then
      "$harness_auto" claude-management "$@"
    else
      "$harness_auto" claude base --passthrough "$@"
    fi
  elif [[ "$runtime" == codex && "${1:-}" == (--version|-V|--help|-h) ]]; then
    local codex_bin
    codex_bin="$(_harness_launcher_codex_bin)" || {
      echo "❌ codex not found in PATH" >&2
      return 1
    }
    "$codex_bin" "$@"
  else
    "$harness_auto" "$runtime" --passthrough "$@"
  fi
}

_harness_launcher_is_claude_management_command() {
  harness_claude_is_management_command "$@"
}

_harness_launcher_auto_claude() {
  _harness_launcher_auto_runtime claude "$@"
}

codex() {
  if (( _HARNESS_LAUNCHER_SHELL_AUTO_ENABLED )); then
    _harness_launcher_auto_runtime codex "$@"
    return $?
  fi
  local codex_bin harness_dir broker_started=false
  local HARNESS_OBSERVABILITY_ACTIVE HARNESS_OBSERVABILITY_ENABLED HARNESS_OBSERVABILITY_PROFILE HARNESS_OTLP_HTTP_ENDPOINT
  local OTEL_RESOURCE_ATTRIBUTES obs_rc
  local inherited_codex_mcp_profile="${HARNESS_CODEX_MCP_PROFILE-}"
  local inherited_codex_mcp_profile_type="${(t)HARNESS_CODEX_MCP_PROFILE}"
  local HARNESS_CODEX_MCP_PROFILE="$inherited_codex_mcp_profile"
  [[ "$inherited_codex_mcp_profile_type" == *-export* ]] && export HARNESS_CODEX_MCP_PROFILE
  codex_bin="$(_harness_launcher_codex_bin)" || {
    echo "❌ codex not found in PATH" >&2
    return 1
  }

  if [[ "${HARNESS_LAUNCHER_DISABLE_CODEX_WRAPPER:-}" != "1" ]]; then
    if harness_dir="$(_harness_launcher_codex_harness_for_args "$@")"; then
      local HARNESS_NAME HARNESS_PREFIX HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST HARNESS_CODEX_APPS_ALLOWLIST HARNESS_MCP_SURFACE_POLICY="" mcp_surface_policy
      unset HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST HARNESS_CODEX_APPS_ALLOWLIST
      source "$harness_dir/config/launcher.env"
      mcp_surface_policy="$(harness_mcp_surface_policy_resolve "$HARNESS_MCP_SURFACE_POLICY")" || return $?
      export HARNESS_PREFIX
      # Per-harness GitHub identity: fail-open, never overrides with an empty token.
      local GH_TOKEN HARNESS_GH_USER
      harness_gh_token_load "$harness_dir" || true
      if harness_observability_load "$harness_dir"; then
        OTEL_RESOURCE_ATTRIBUTES="service.name=codex_exec,obs.runtime=codex,obs.profile=$HARNESS_OBSERVABILITY_PROFILE"
        export OTEL_RESOURCE_ATTRIBUTES
      else
        obs_rc=$?
        [[ "$obs_rc" -eq 1 ]] || return "$obs_rc"
      fi
      harness_mcp_surface_policy_is_single_full "$mcp_surface_policy" && unset HARNESS_CODEX_MCP_PROFILE
      _harness_launcher_export_codex_runtime_env "$harness_dir" || return $?
      harness_codex_cmux_broker_start "$_HARNESS_LAUNCHER_BIN/codex-cmux-title-sync.py"
      broker_started=true
    fi
  fi

  "$codex_bin" "$@"
  local rc=$?
  $broker_started && harness_codex_cmux_broker_stop
  return $rc
}

_HARNESS_LAUNCHER_CODEX_WRAPPER_BODY="$functions[codex]"

harness_shell_enable() {
  local harness_auto="$_HARNESS_LAUNCHER_BIN/harness-auto"
  [[ -x "$harness_auto" ]] || {
    echo "harness_shell_enable: missing executable: $harness_auto" >&2
    return 2
  }
  if alias claude >/dev/null 2>&1; then
    echo 'harness_shell_enable: claude alias already exists' >&2
    return 2
  fi
  if alias codex >/dev/null 2>&1; then
    echo 'harness_shell_enable: codex alias already exists' >&2
    return 2
  fi
  if [[ "$functions[codex]" != "$_HARNESS_LAUNCHER_CODEX_WRAPPER_BODY" ]]; then
    echo 'harness_shell_enable: codex function is not launcher-owned' >&2
    return 2
  fi
  if (( _HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED )); then
    if (( $+functions[claude] )) && \
        [[ "$functions[claude]" != "$functions[_harness_launcher_auto_claude]" ]]; then
      echo 'harness_shell_enable: launcher-owned claude function was replaced' >&2
      return 2
    fi
  elif (( $+functions[claude] )); then
    echo 'harness_shell_enable: claude function already exists' >&2
    return 2
  fi

  if (( ! $+functions[claude] )); then
    functions -c _harness_launcher_auto_claude claude || return 2
  fi
  typeset -g _HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED=1
  typeset -g +x _HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED
  typeset -g _HARNESS_LAUNCHER_SHELL_AUTO_ENABLED=1
  typeset -g +x _HARNESS_LAUNCHER_SHELL_AUTO_ENABLED
}

harness_shell_disable() {
  typeset -g _HARNESS_LAUNCHER_SHELL_AUTO_ENABLED=0
  typeset -g +x _HARNESS_LAUNCHER_SHELL_AUTO_ENABLED
  (( _HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED )) || return 0
  if (( $+functions[claude] )); then
    if [[ "$functions[claude]" == "$functions[_harness_launcher_auto_claude]" ]]; then
      unfunction claude
    else
      echo 'harness_shell_disable: claude function is no longer launcher-owned; preserved it' >&2
      return 2
    fi
  fi
  typeset -g _HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED=0
  typeset -g +x _HARNESS_LAUNCHER_SHELL_CLAUDE_OWNED
}

# harness_register <harness-dir>
#   Reads <dir>/config/launcher.env (HARNESS_NAME, HARNESS_PREFIX),
#   defines the prefix function, wires tab completion.
harness_register() {
  local dir="$1"
  [[ -z "$dir" || ! -d "$dir" ]] && { echo "harness_register: invalid dir: $dir" >&2; return 1; }
  dir="${dir:A}"
  local env_file="$dir/config/launcher.env"
  [[ ! -f "$env_file" ]] && { echo "harness_register: missing $env_file" >&2; return 1; }

  local HARNESS_NAME HARNESS_PREFIX HARNESS_MCP_SURFACE_POLICY="" mcp_surface_policy
  source "$env_file"
  mcp_surface_policy="$(harness_mcp_surface_policy_resolve "$HARNESS_MCP_SURFACE_POLICY")" || return $?
  [[ -z "$HARNESS_PREFIX" ]] && { echo "harness_register: HARNESS_PREFIX required in $env_file" >&2; return 1; }
  [[ "$HARNESS_PREFIX" =~ '^[A-Za-z_][A-Za-z0-9_-]*$' ]] || {
    echo "harness_register: invalid HARNESS_PREFIX in $env_file: $HARNESS_PREFIX" >&2
    return 1
  }
  [[ -z "$HARNESS_NAME" ]] && { echo "harness_register: HARNESS_NAME required in $env_file" >&2; return 1; }

  # Remove any pre-existing alias that shadows the configured prefix.
  unalias "$HARNESS_PREFIX" 2>/dev/null || true

  # Define <prefix>() as a thin wrapper around the same executable contract used
  # by external workspace managers. This keeps interactive shells, Orca, and
  # non-interactive automation on one cwd-resolution and policy path.
  local harness_exec="$_HARNESS_LAUNCHER_BIN/harness-exec"
  [[ -x "$harness_exec" ]] || {
    echo "harness_register: missing executable: $harness_exec" >&2
    return 1
  }
  local quoted_dir="${(q)dir}"
  local quoted_harness_exec="${(q)harness_exec}"
  eval "${HARNESS_PREFIX}() { ${quoted_harness_exec} ${quoted_dir} \"\$@\"; }" || return 1
  # Define _<prefix>_complete() — delegates to generic completion
  eval "_${HARNESS_PREFIX}_complete() { _harness_launcher_complete ${quoted_dir} \"\$@\"; }" || return 1
  if (( $+functions[compdef] )); then
    compdef "_${HARNESS_PREFIX}_complete" "$HARNESS_PREFIX"
  fi

  local registered exists=false
  for registered in "${_HARNESS_LAUNCHER_REGISTERED_DIRS[@]}"; do
    [[ "$registered" == "$dir" ]] && { exists=true; break; }
  done
  $exists || _HARNESS_LAUNCHER_REGISTERED_DIRS+=("$dir")
}

# _harness_launcher_run <harness-dir> [args...]
#   Shared implementation for every registered profile function.
_harness_launcher_run() {
  # Orca injects its own CODEX_HOME (and re-copies ORCA_CODEX_HOME into it in
  # interactive shells). Drop both when CODEX_HOME is exactly Orca's value so
  # launcher-owned Claude/Codex paths never inherit it; a differing user value
  # is left alone.
  if [[ -n "${ORCA_CODEX_HOME-}" && "${CODEX_HOME-}" == "$ORCA_CODEX_HOME" ]]; then
    unset CODEX_HOME ORCA_CODEX_HOME
  fi
  # Production entry points run without errexit; a caller's errexit would also
  # skip the `always` block that finishes an isolated session.
  setopt localoptions noerrexit
  local HARNESS_DIR="$1"; shift
  local HARNESS_NAME HARNESS_PREFIX HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST HARNESS_CODEX_APPS_ALLOWLIST HARNESS_MCP_SURFACE_POLICY="" mcp_surface_policy
  local HARNESS_SESSION_ISOLATION_DEFAULT="0"
  local HARNESS_SESSION_ID="" HARNESS_SOURCE_ROOT="" HARNESS_SESSION_ROOT=""
  local config_root="$HARNESS_DIR"
  unset HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST HARNESS_CODEX_APPS_ALLOWLIST
  source "$HARNESS_DIR/config/launcher.env"
  mcp_surface_policy="$(harness_mcp_surface_policy_resolve "$HARNESS_MCP_SURFACE_POLICY")" || return $?
  export HARNESS_PREFIX

  local HARNESS_RUN_DIR=""
  case "${1:-}" in
    --cwd)
      [[ $# -ge 2 ]] || { echo "harness-launcher: --cwd requires a directory" >&2; return 2; }
      HARNESS_RUN_DIR="$(harness_resolve_run_dir "$HARNESS_DIR" "$2")" || return $?
      shift 2
      ;;
  esac

  # SDK hosts run diagnostics such as `auth status` through the same argv
  # prefix (`base --passthrough auth status`); a management subcommand right
  # after the marker runs natively. Only for direct Claude: other runtimes and
  # gateway prefixes keep their own path.
  local mgmt_i=1
  case "${1:-}" in
    --isolated|--no-isolated) mgmt_i=2 ;;
    --isolated-session) mgmt_i=3 ;;
  esac
  if [[ "${@[mgmt_i]-}" != (codex|codex-smoke|checkup|kiro|kiro-cli|codex-gateway|claude-management) ]]; then
    for (( ; mgmt_i < $#; mgmt_i++ )); do
      [[ "${@[mgmt_i]}" == -- ]] && break
      if [[ "${@[mgmt_i]}" == --passthrough ]]; then
        if harness_claude_is_management_command "${@[mgmt_i+1]}"; then
          set -- claude-management "${@[mgmt_i+1,-1]}"
        fi
        break
      fi
    done
  fi

  if [[ "${1:-}" == claude-management ]]; then
    shift
    [[ $# -gt 0 ]] || {
      echo 'harness-launcher: claude-management requires a native Claude subcommand' >&2
      return 2
    }
    local claude_management_bin="${commands[claude]:-}"
    [[ -n "$claude_management_bin" && -x "$claude_management_bin" ]] || {
      echo 'harness-launcher: claude not found in PATH' >&2
      return 1
    }
    (
      [[ -z "$HARNESS_RUN_DIR" ]] || cd "$HARNESS_RUN_DIR" || exit $?
      harness_export_local_env "$HARNESS_DIR" || exit $?
      "$claude_management_bin" "$@"
    )
    return $?
  fi

  case "$HARNESS_SESSION_ISOLATION_DEFAULT" in 0|1) ;; *) echo 'harness-launcher: HARNESS_SESSION_ISOLATION_DEFAULT must be 0 or 1' >&2; return 2;; esac
  case "${HARNESS_SESSION_ISOLATION-}" in ''|0|1) ;; *) echo 'harness-launcher: HARNESS_SESSION_ISOLATION must be 0 or 1' >&2; return 2;; esac
  local isolated=false explicit_isolation_control=false created_isolated_session=false
  local requested_session_id="" isolation_route="" orca_resume=false orca_resume_id=""
  if [[ "${1:-}" == "--isolated" ]]; then
    isolated=true; explicit_isolation_control=true
    shift
  elif [[ "${1:-}" == "--isolated-session" ]]; then
    [[ $# -ge 2 ]] || { echo 'harness-launcher: --isolated-session requires a UUID' >&2; return 2; }
    isolated=true; explicit_isolation_control=true
    requested_session_id="$2"
    shift 2
  elif [[ "${1:-}" == "--no-isolated" ]]; then
    explicit_isolation_control=true
    shift
  elif [[ "${HARNESS_SESSION_ISOLATION-}" == 1 ]]; then
    isolated=true
  elif [[ "$HARNESS_SESSION_ISOLATION_DEFAULT" == 1 ]]; then
    local isolation_interactive=0
    harness_claude_stdio_is_tty && isolation_interactive=1
    isolation_route="$(harness_session_isolation_default_route "$isolation_interactive" "$@")" || return $?
    case "$isolation_route" in
      isolate) isolated=true ;;
      legacy) ;;
      reject)
        orca_resume_id="$(_harness_launcher_resolve_orca_resume "${HARNESS_DIR:A}" "$@")"
        case $? in
          0) isolated=true; requested_session_id="$orca_resume_id"; orca_resume=true ;;
          3) echo "harness-launcher: resume id is ambiguous (several isolated sessions own it); use '${HARNESS_PREFIX} --isolated-session <uuid> $*'" >&2
             return 2 ;;
          *) echo "harness-launcher: this profile isolates fresh sessions; use '${HARNESS_PREFIX} --isolated-session <uuid> $*' or '${HARNESS_PREFIX} --no-isolated $*'" >&2
             return 2 ;;
        esac
        ;;
      *) echo 'harness-launcher: invalid or conflicting isolation controls' >&2; return 2 ;;
    esac
  fi
  # checkup audits the harness root itself; reject before any clone exists.
  if $isolated && [[ "${1:-}" == checkup ]]; then
    echo "harness-launcher: checkup audits the harness root and cannot run in an isolated session; use '${HARNESS_PREFIX} --no-isolated checkup prompt-audit'" >&2
    return 2
  fi
  if $isolated; then
    isolation_route="$(harness_session_isolation_default_route 1 "$@")" || return $?
    [[ "$isolation_route" != invalid ]] || { echo 'harness-launcher: invalid or conflicting isolation controls' >&2; return 2; }
    if [[ -z "$requested_session_id" && "$isolation_route" == reject ]]; then
      orca_resume_id="$(_harness_launcher_resolve_orca_resume "${HARNESS_DIR:A}" "$@")"
      case $? in
        0) requested_session_id="$orca_resume_id"; orca_resume=true ;;
        3) echo "harness-launcher: resume id is ambiguous (several isolated sessions own it); use '${HARNESS_PREFIX} --isolated-session <uuid> $*'" >&2
           return 2 ;;
        *) echo "harness-launcher: continuation requires '${HARNESS_PREFIX} --isolated-session <uuid> $*' or intentional '${HARNESS_PREFIX} --no-isolated $*'" >&2
           return 2 ;;
      esac
    fi
  elif $explicit_isolation_control; then
    isolation_route="$(harness_session_isolation_default_route 1 "$@")" || return $?
    [[ "$isolation_route" != invalid ]] || { echo 'harness-launcher: invalid or conflicting isolation controls' >&2; return 2; }
  fi
  if $isolated; then
    local source_root="${HARNESS_DIR:A}"
    local HARNESS_SESSION_LEASE_FD=""
    "$_HARNESS_LAUNCHER_BIN/session-isolation.sh" gc >/dev/null 2>&1 || echo 'harness-launcher: warning: isolated-session GC failed; workspaces retained' >&2
    if [[ -n "$requested_session_id" ]]; then
      _harness_launcher_isolated_lease_acquire "$requested_session_id" || {
        local resume_rc=$?
        $orca_resume && echo "harness-launcher: could not restore isolated session $requested_session_id" >&2
        return "$resume_rc"
      }
      _harness_launcher_isolated_session_create "$source_root" "$requested_session_id" || {
        local resume_rc=$?
        zsystem flock -u "$HARNESS_SESSION_LEASE_FD" 2>/dev/null || true
        $orca_resume && echo "harness-launcher: could not restore isolated session $requested_session_id" >&2
        return "$resume_rc"
      }
    else
      _harness_launcher_isolated_session_create "$source_root" || return $?
      _harness_launcher_isolated_lease_acquire "$HARNESS_SESSION_ID" || return $?
      created_isolated_session=true
    fi
    HARNESS_DIR="$HARNESS_SESSION_ROOT"
    [[ -n "$HARNESS_RUN_DIR" ]] || HARNESS_RUN_DIR="$HARNESS_SESSION_ROOT"
    export HARNESS_RUN_DIR
    if $created_isolated_session; then
      if [[ "${1:-}" == codex ]]; then
        echo "harness-launcher: isolated session $HARNESS_SESSION_ID; continue: ${HARNESS_PREFIX} --isolated-session $HARNESS_SESSION_ID codex resume" >&2
      else
        echo "harness-launcher: isolated session $HARNESS_SESSION_ID; continue: ${HARNESS_PREFIX} --isolated-session $HARNESS_SESSION_ID resume" >&2
      fi
    fi
  fi
  local isolated_session_id="${HARNESS_SESSION_ID:-}" isolated_heartbeat_pid=""
  # Every exit after the isolated session is acquired, including error
  # returns, stops a started heartbeat and finishes the session once.
  {
    _harness_launcher_run_session "$@"
  } always {
    if [[ -n "$isolated_session_id" ]]; then
      _harness_launcher_isolated_finish "$isolated_session_id" "$isolated_heartbeat_pid" "${HARNESS_SESSION_LEASE_FD:-}"
    fi
  }
}

# _harness_launcher_run_session [args...]
#   Launch body of _harness_launcher_run after isolation is settled. Reads the
#   caller's locals (zsh dynamic scope) and sets its isolated_heartbeat_pid.
_harness_launcher_run_session() {
  local -a claude_args=() claude_passthrough_args=() claude_passthrough_opts=() claude_prompt_args=()
  local session_flag="" skip_tui=false env_effort="" provider_url="" gateway_api_key="" provider_name=""
  local mode_applied=false mcp_surface="full" passthrough=false passthrough_force_thinking=false

  # Optional provider prefix (must be first arg)
  case "${1:-}" in
    kiro)
      provider_name="kiro"
      local _env_file="$config_root/config/.local/kiro-gateway.env"
      if [[ -f "$_env_file" ]]; then
        source "$_env_file"
        [[ -n "${KIRO_GATEWAY_URL:-}" ]] && provider_url="$KIRO_GATEWAY_URL"
        [[ -n "${KIRO_GATEWAY_API_KEY:-}" ]] && gateway_api_key="$KIRO_GATEWAY_API_KEY"
      fi
      [[ -z "$provider_url" ]] && echo "❌ KIRO_GATEWAY_URL이 설정되지 않았습니다" && return 1
      _harness_launcher_probe_provider_health "$provider_url" \
        || { echo "❌ kiro-gateway에 연결할 수 없습니다 ($provider_url)"; return 1; }
      skip_tui=true; shift ;;
    codex)
      shift
      if [[ -n "$isolated_session_id" ]]; then _harness_launcher_isolated_heartbeat "$isolated_session_id" & isolated_heartbeat_pid=$!; fi
      _harness_launcher_run_codex_cli "$HARNESS_DIR" "$mcp_surface_policy" "$@"
      return $?
      ;;
    checkup)
      shift
      _harness_launcher_run_checkup "$HARNESS_DIR" "$@"
      return $?
      ;;
    codex-smoke)
      shift
      [[ $# -eq 0 ]] || { echo "harness-launcher: codex-smoke takes no arguments" >&2; return 2; }
      if [[ -n "$isolated_session_id" ]]; then _harness_launcher_isolated_heartbeat "$isolated_session_id" & isolated_heartbeat_pid=$!; fi
      _harness_launcher_codex_synthetic_smoke "$HARNESS_DIR"
      return $?
      ;;
    kiro-cli)
      shift
      if [[ -n "$isolated_session_id" ]]; then _harness_launcher_isolated_heartbeat "$isolated_session_id" & isolated_heartbeat_pid=$!; fi
      _harness_launcher_run_kiro_cli "$HARNESS_DIR" "$@"
      return $?
      ;;
    codex-gateway)
      provider_name="codex"
      local _env_file="$config_root/config/.local/codex-gateway.env"
      if [[ -f "$_env_file" ]]; then
        source "$_env_file"
        [[ -n "${CODEX_GATEWAY_URL:-}" ]] && provider_url="$CODEX_GATEWAY_URL"
        [[ -n "${CODEX_GATEWAY_API_KEY:-}" ]] && gateway_api_key="$CODEX_GATEWAY_API_KEY"
      fi
      [[ -z "$provider_url" ]] && echo "❌ CODEX_GATEWAY_URL이 설정되지 않았습니다" && return 1
      _harness_launcher_probe_provider_health "$provider_url" \
        || { echo "❌ codex-gateway에 연결할 수 없습니다 ($provider_url)"; return 1; }
      skip_tui=true; shift ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --passthrough)
        # SDK hosts (e.g. Paseo) append their own Claude argv after this
        # marker. Forward it verbatim: option values such as
        # `--permission-mode plan` or `--effort high` are not launcher keywords.
        shift
        claude_passthrough_args=("$@")
        passthrough=true; skip_tui=true
        break ;;
      --)
        # Everything after a launcher `--` is prompt text, forwarded last.
        claude_prompt_args=("$@")
        skip_tui=true
        break ;;
      fast|base|plan|opus|rich)
        harness_mode_resolve "$1" "${provider_name:-direct}"
        claude_args+=(--model "$HARNESS_MODE_MODEL")
        env_effort="$HARNESS_MODE_EFFORT"
        skip_tui=true; mode_applied=true; shift ;;
      fable)
        if ! harness_mode_resolve fable "${provider_name:-direct}"; then
          echo "❌ fable는 Anthropic direct 전용입니다 (codex/kiro 미지원)" >&2
          return 1
        fi
        claude_args+=(--model "$HARNESS_MODE_MODEL"); env_effort="$HARNESS_MODE_EFFORT"
        skip_tui=true; mode_applied=true; shift ;;
      ultracode)
        # ultracode = xhigh + dynamic workflow orchestration. The orchestration
        # half is a SESSION-ONLY Claude Code preset: the CLI rejects 'ultracode'
        # as an --effort / env / settings value (allowed: low|medium|high|xhigh|
        # max), so it cannot be set at launch. Launch as rich (opus[1m] + xhigh)
        # and remind the user to flip it on in-session via /effort.
        # Anthropic direct only — kiro/codex gateways don't support it at all.
        if ! harness_mode_resolve ultracode "${provider_name:-direct}"; then
          echo "❌ ultracode는 Anthropic direct 전용입니다 (codex/kiro 미지원)" >&2
          return 1
        fi
        claude_args+=(--model "$HARNESS_MODE_MODEL"); env_effort="$HARNESS_MODE_EFFORT"
        harness_ultracode_hint
        skip_tui=true; mode_applied=true; shift ;;
      low|medium|high|xhigh|max)
        env_effort="$1"
        if ! $mode_applied; then
          case "$provider_name" in
            kiro)  ;;
            codex) claude_args+=(--model "sonnet${CODEX_CONTEXT_SUFFIX:-}") ;;
            *)     claude_args+=(--model sonnet) ;;
          esac
        fi
        skip_tui=true; shift ;;
      light)
        if [[ "$provider_name" == kiro ]]; then
          mcp_surface="light"
        else
          case "$mcp_surface_policy" in
            legacy) mcp_surface="light" ;;
            single-full-compat)
              echo "⚠️  light MCP surface is deprecated for this project; using full" >&2
              mcp_surface="full"
              ;;
            single-full)
              echo "harness-launcher: light MCP surface is retired for this project" >&2
              return 2
              ;;
          esac
        fi
        skip_tui=true; shift ;;
      continue) session_flag="--continue"; skip_tui=true; shift ;;
      resume)   session_flag="--resume"; skip_tui=true; shift ;;
      bypass)       claude_args+=(--permission-mode bypassPermissions); skip_tui=true; shift ;;
      acceptEdits)  claude_args+=(--permission-mode acceptEdits); skip_tui=true; shift ;;
      dontAsk)      claude_args+=(--permission-mode dontAsk); skip_tui=true; shift ;;
      --chrome|--no-chrome)
                    claude_args+=("$1"); skip_tui=true; shift ;;
      *)            claude_args+=("$1"); shift ;;
    esac
  done

  if $passthrough; then
    # Caller options end at its own `--`; later tokens are prompt text and
    # are never scanned for options.
    local _pt_i=${claude_passthrough_args[(ie)--]}
    claude_passthrough_opts=("${(@)claude_passthrough_args[1,_pt_i-1]}")
    _harness_launcher_passthrough_reconcile || return $?
  fi

  if $skip_tui; then
    # Shortcut/gateway paths below launch Claude directly. Native Codex/Kiro
    # returned above; no-argument TUI selection is handled inside launcher.sh.
    local HARNESS_OBSERVABILITY_ACTIVE HARNESS_OBSERVABILITY_ENABLED HARNESS_OBSERVABILITY_PROFILE
    local HARNESS_OTLP_HTTP_ENDPOINT obs_rc
    # Per-harness GitHub identity: fail-open, never overrides with an empty token.
    local GH_TOKEN HARNESS_GH_USER
    harness_gh_token_load "$HARNESS_DIR" || true
    if harness_observability_load "$HARNESS_DIR"; then
      local CLAUDE_CODE_ENABLE_TELEMETRY=1
      local OTEL_METRICS_EXPORTER=otlp OTEL_LOGS_EXPORTER=otlp OTEL_TRACES_EXPORTER=none
      local OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
      local OTEL_EXPORTER_OTLP_ENDPOINT="$HARNESS_OTLP_HTTP_ENDPOINT"
      local OTEL_EXPORTER_OTLP_LOGS_ENDPOINT="$HARNESS_OTLP_HTTP_ENDPOINT/v1/logs"
      local OTEL_EXPORTER_OTLP_METRICS_ENDPOINT="$HARNESS_OTLP_HTTP_ENDPOINT/v1/metrics"
      local OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="$HARNESS_OTLP_HTTP_ENDPOINT/v1/traces"
      local OTEL_EXPORTER_OTLP_LOGS_PROTOCOL=http/protobuf
      local OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/protobuf
      local OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=http/protobuf
      local OTEL_EXPORTER_OTLP_HEADERS="" OTEL_EXPORTER_OTLP_LOGS_HEADERS=""
      local OTEL_EXPORTER_OTLP_METRICS_HEADERS="" OTEL_EXPORTER_OTLP_TRACES_HEADERS=""
      local OTEL_RESOURCE_ATTRIBUTES="service.name=harness-agent,obs.runtime=claude_code,obs.profile=$HARNESS_OBSERVABILITY_PROFILE"
      local OTEL_LOG_USER_PROMPTS=0 OTEL_LOG_ASSISTANT_RESPONSES=0
      local OTEL_LOG_TOOL_DETAILS=0 OTEL_LOG_TOOL_CONTENT=0 OTEL_LOG_RAW_API_BODIES=0
      export CLAUDE_CODE_ENABLE_TELEMETRY OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER OTEL_TRACES_EXPORTER
      export OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_ENDPOINT OTEL_RESOURCE_ATTRIBUTES
      export OTEL_EXPORTER_OTLP_LOGS_ENDPOINT OTEL_EXPORTER_OTLP_METRICS_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
      export OTEL_EXPORTER_OTLP_LOGS_PROTOCOL OTEL_EXPORTER_OTLP_METRICS_PROTOCOL OTEL_EXPORTER_OTLP_TRACES_PROTOCOL
      export OTEL_EXPORTER_OTLP_HEADERS OTEL_EXPORTER_OTLP_LOGS_HEADERS OTEL_EXPORTER_OTLP_METRICS_HEADERS OTEL_EXPORTER_OTLP_TRACES_HEADERS
      export OTEL_LOG_USER_PROMPTS OTEL_LOG_ASSISTANT_RESPONSES
      export OTEL_LOG_TOOL_DETAILS OTEL_LOG_TOOL_CONTENT OTEL_LOG_RAW_API_BODIES
    else
      obs_rc=$?
      [[ "$obs_rc" -eq 1 ]] || return "$obs_rc"
    fi

    [[ -n "$session_flag" ]] && claude_args=("$session_flag" "${claude_args[@]}")
    if [[ -n "$provider_url" ]]; then
      export ANTHROPIC_BASE_URL="$provider_url"
      if [[ -n "$gateway_api_key" ]]; then
        export ANTHROPIC_AUTH_TOKEN="$gateway_api_key"
        unset ANTHROPIC_API_KEY
      fi
      unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_CUSTOM_HEADERS
      if [[ "$provider_name" == "codex" ]]; then
        # DRIFT FIX: no dead fallbacks — only export what user configured
        [[ -n "${CODEX_OPUS_MODEL:-}" ]]   && export ANTHROPIC_DEFAULT_OPUS_MODEL="$CODEX_OPUS_MODEL"
        [[ -n "${CODEX_SONNET_MODEL:-}" ]] && export ANTHROPIC_DEFAULT_SONNET_MODEL="$CODEX_SONNET_MODEL"
        [[ -n "${CODEX_HAIKU_MODEL:-}" ]]  && export ANTHROPIC_DEFAULT_HAIKU_MODEL="$CODEX_HAIKU_MODEL"
      fi
    fi
    if [[ -n "$env_effort" ]]; then
      claude_args+=(--effort "$env_effort")
      # The API rejects xhigh/max while thinking is disabled ("effort 'xhigh' is
      # not supported when thinking is disabled on this model"). rich/ultracode
      # both resolve to xhigh, so a user with alwaysThinkingEnabled=false in
      # settings.json got a 400 at first prompt. Force it on for those efforts
      # instead of depending on per-machine settings; high and below are
      # unaffected and keep the user's own choice.
      [[ "$env_effort" == (xhigh|max) ]] \
        && claude_args+=(--settings '{"alwaysThinkingEnabled":true}')
    elif $passthrough_force_thinking; then
      claude_args+=(--settings '{"alwaysThinkingEnabled":true}')
    fi
    # Passthrough argv goes last, after the launcher-owned flags. The boolean
    # --exclude-dynamic-system-prompt-sections then closes the variadic
    # --mcp-config value list, so neither a caller prompt nor a caller `--`
    # can swallow or displace launcher flags.
    local -a claude_launch_tail=()
    if $passthrough; then
      claude_launch_tail=(--exclude-dynamic-system-prompt-sections "${claude_passthrough_args[@]}")
    else
      claude_args+=(--exclude-dynamic-system-prompt-sections)
    fi
    claude_launch_tail+=("${claude_prompt_args[@]}")
    local HARNESS_CLAUDE_TITLE_BOOTSTRAP_ID="" HARNESS_CLAUDE_TITLE_BOOTSTRAP_VALUE=""
    local _claude_interactive=0
    harness_claude_stdio_is_tty && _claude_interactive=1
    if harness_claude_bootstrap_eligible claude "${provider_name:-direct}" "$_claude_interactive" "${claude_args[@]}" "${claude_passthrough_opts[@]}"; then
      IFS=$'\t' read -r HARNESS_CLAUDE_TITLE_BOOTSTRAP_ID HARNESS_CLAUDE_TITLE_BOOTSTRAP_VALUE \
        < <(harness_claude_bootstrap_values) || true
      if [[ -n "$HARNESS_CLAUDE_TITLE_BOOTSTRAP_ID" ]]; then
        export HARNESS_CLAUDE_TITLE_BOOTSTRAP_ID HARNESS_CLAUDE_TITLE_BOOTSTRAP_VALUE
        claude_args+=(--name "$HARNESS_CLAUDE_TITLE_BOOTSTRAP_VALUE")
      fi
    fi
    # A fresh isolated Claude launch names its session after the isolated
    # session so an Orca restore (`--resume <id>`) can be mapped back to it.
    # Appended after the bootstrap decision: bootstrap eligibility rejects
    # --session-id, and this keeps --name.
    if $created_isolated_session && [[ "$isolation_route" == isolate ]]; then
      local _sid_arg _sid_ok=true
      for _sid_arg in "${claude_args[@]}" "${claude_passthrough_opts[@]}"; do
        case "$_sid_arg" in
          --session-id|--session-id=*|-c|--continue|-r|-r?*|--resume|--resume=*|--fork-session|--fork-session=*) _sid_ok=false ;;
        esac
      done
      $_sid_ok && claude_args+=(--session-id "${(L)HARNESS_SESSION_ID}")
    fi
    harness_autocompact_pct "${provider_name:-direct}" "${claude_args[@]}" "${claude_passthrough_opts[@]}"
    # Shared-table globals must not linger in the interactive shell.
    unset HARNESS_MODE_MODEL HARNESS_MODE_EFFORT
    # Plain invocation (not exec) so the user's interactive shell survives
    # the launched process — Ctrl+C returns to the prompt instead of closing
    # the terminal window.
    local claude_broker_started=false
    if [[ "$mcp_surface" == "light" ]]; then
      local _light_file
      _light_file="$(harness_claude_light_mcp_config "$HARNESS_DIR" "$_HARNESS_LAUNCHER_BIN")" || return $?
      if [[ -n "$isolated_session_id" ]]; then _harness_launcher_isolated_heartbeat "$isolated_session_id" & isolated_heartbeat_pid=$!; fi
      harness_claude_cmux_broker_start "$_HARNESS_LAUNCHER_BIN/codex-cmux-title-sync.py" "$HARNESS_DIR"
      claude_broker_started=true
      (
        [[ -z "$HARNESS_RUN_DIR" ]] || cd "$HARNESS_RUN_DIR" || exit $?
        harness_export_local_env "${HARNESS_SOURCE_ROOT:-$HARNESS_DIR}" || exit $?
        claude --strict-mcp-config --mcp-config "$_light_file" "${claude_args[@]}" "${claude_launch_tail[@]}"
      )
    else
      if [[ -n "$isolated_session_id" ]]; then _harness_launcher_isolated_heartbeat "$isolated_session_id" & isolated_heartbeat_pid=$!; fi
      harness_claude_cmux_broker_start "$_HARNESS_LAUNCHER_BIN/codex-cmux-title-sync.py" "$HARNESS_DIR"
      claude_broker_started=true
      (
        [[ -z "$HARNESS_RUN_DIR" ]] || cd "$HARNESS_RUN_DIR" || exit $?
        harness_export_local_env "${HARNESS_SOURCE_ROOT:-$HARNESS_DIR}" || exit $?
        _harness_launcher_claude_mcp_local_args "$HARNESS_DIR" || exit $?
        claude "${claude_args[@]}" "${reply[@]}" "${claude_launch_tail[@]}"
      )
    fi
    local rc=$?
    $claude_broker_started && harness_claude_cmux_broker_stop
    return $rc
  else
    if [[ -n "$isolated_session_id" ]]; then _harness_launcher_isolated_heartbeat "$isolated_session_id" & isolated_heartbeat_pid=$!; fi
    HARNESS_DIR="$HARNESS_DIR" HARNESS_NAME="$HARNESS_NAME" HARNESS_PREFIX="$HARNESS_PREFIX" \
      HARNESS_RUN_DIR="${HARNESS_RUN_DIR:-}" \
      "$_HARNESS_LAUNCHER_BIN/launcher.sh"
    return $?
  fi
}

# _harness_launcher_run_checkup <harness-dir> prompt-audit [preset] [--max-budget-usd N]
#   Runs Claude Code's `/checkup prompt-audit` headless at the harness root.
#   --restricted drops user/project/local settings (hooks, allow rules, default
#   modes) and MCP. Under dontAsk the allow list adds only two git commands that
#   neither write files, run commands, nor print file contents; other Bash
#   commands run only when Claude Code's read-only check accepts them. An allow
#   rule for git blame/log/show would also accept --contents/--output. Secrets
#   and earlier reports are denied even though Glob could list them. The session is not persisted, so `<prefix> continue` never
#   resumes the audit. The raw JSON, stderr, and report stay under
#   .harness/reports/checkup/; stdout gets one status line without report text,
#   so a caller running several profiles never sees another profile's content.
_harness_launcher_run_checkup() {
  local HARNESS_DIR="$1"; shift
  local usage="usage: ${HARNESS_PREFIX:-<prefix>} checkup prompt-audit [fast|base|opus|rich|fable] [--max-budget-usd N]"
  if [[ "${1:-}" != prompt-audit ]]; then
    echo "harness-launcher: $usage" >&2
    return 2
  fi
  shift
  # `plan` (opusplan) is left out: without plan mode it runs as Sonnet.
  local preset="opus" preset_set=false budget="${HARNESS_CHECKUP_MAX_BUDGET_USD:-20}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      fast|base|opus|rich|fable)
        $preset_set && { echo "harness-launcher: checkup accepts one preset; $usage" >&2; return 2; }
        preset="$1"; preset_set=true; shift ;;
      --max-budget-usd)
        [[ $# -ge 2 ]] || { echo "harness-launcher: --max-budget-usd requires a value" >&2; return 2; }
        budget="$2"; shift 2 ;;
      --max-budget-usd=*) budget="${1#*=}"; shift ;;
      *) echo "harness-launcher: checkup does not accept '$1'; $usage" >&2; return 2 ;;
    esac
  done
  if [[ ! "$budget" =~ '^[0-9]+(\.[0-9]+)?$' ]] || (( budget <= 0 )); then
    echo "harness-launcher: --max-budget-usd must be a positive number (got '$budget')" >&2
    return 2
  fi

  harness_mode_resolve "$preset" direct || return 2
  local model="$HARNESS_MODE_MODEL" effort="$HARNESS_MODE_EFFORT"
  unset HARNESS_MODE_MODEL HARNESS_MODE_EFFORT
  local py settings
  py="$(harness_python3_resolve)" || return 1
  settings="$("$py" - "$HARNESS_DIR" "$effort" <<'PY'
import json, sys
root, effort = sys.argv[1].rstrip("/"), sys.argv[2]
private = [".claude/settings*.json", ".mcp*.json", "mcp*.local.json",
           "config/.local/**", ".harness/**"]
settings = {"permissions": {
    "allow": ["Bash(git ls-files:*)", "Bash(git check-ignore:*)"],
    # `//` anchors a rule at the filesystem root; `**/` covers nested
    # worktrees and projects.
    "deny": ["Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch"]
            + [f"Read(/{root}/{prefix}{path})" for path in private for prefix in ("", "**/")],
}}
if effort in ("xhigh", "max"):
    settings["alwaysThinkingEnabled"] = True
print(json.dumps(settings))
PY
)" || return 1
  # User-level configuration the audit covers; the ~/.claude root (settings,
  # credentials) is deliberately not added.
  local -a add_dirs=()
  local sub
  for sub in skills commands agents output-styles rules plugins; do
    [[ -d "$HOME/.claude/$sub" ]] && add_dirs+=(--add-dir "$HOME/.claude/$sub")
  done

  local report_dir="$HARNESS_DIR/.harness/reports/checkup"
  local stem="$report_dir/prompt-audit-$(date -u +%Y%m%dT%H%M%SZ)-$$" n=0
  local base="$stem"
  while [[ -e "$base.json" ]]; do n=$(( n + 1 )); base="$stem-$n"; done
  ( umask 077; mkdir -p "$report_dir" && chmod 700 "$report_dir" ) || return 1

  # Best-effort signal, not a boundary: concurrent sessions on the same tree
  # also change it.
  local guard=false tree_before="" tree_after=""
  if git -C "$HARNESS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    guard=true
    tree_before="$(git -C "$HARNESS_DIR" status --porcelain=v1 --untracked-files=all -- . ':(exclude).harness/reports/checkup' 2>/dev/null)"
  fi

  echo "checkup prompt-audit: running at $HARNESS_DIR (model=$model effort=$effort budget=\$$budget); this can take several minutes" >&2
  # Claude's duration_ms leaves out time spent waiting on subagents; report the
  # launcher's own wall-clock time.
  local rc=0 started=$SECONDS
  (
    cd "$HARNESS_DIR" || exit $?
    # A caller launched through a gateway profile must not route this harness's
    # audit through its provider or hand it its GitHub token; the harness's own
    # local env below may set them again.
    unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS \
      ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
      GH_TOKEN
    harness_export_local_env "$HARNESS_DIR" || exit $?
    # A caller that is itself a Claude session must not link this run to its
    # session, messaging socket, terminal, or telemetry profile.
    unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT \
      CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_SESSION_ATTENDED \
      CLAUDE_CODE_EXECPATH CLAUDE_CODE_ENABLE_TELEMETRY \
      HARNESS_CLAUDE_TITLE_BOOTSTRAP_ID HARNESS_CLAUDE_TITLE_BOOTSTRAP_VALUE \
      HARNESS_SESSION_ID HARNESS_SESSION_ROOT HARNESS_SOURCE_ROOT HARNESS_RUN_DIR
    unset -m 'OTEL_*' 'CMUX_*' 'ORCA_*'
    # --restricted skips project settings env; keep Glob honoring .gitignore.
    export CLAUDE_CODE_GLOB_NO_IGNORE=false CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
    umask 077
    claude -p "/checkup prompt-audit" --restricted \
      --tools "Read,Grep,Glob,Bash,Agent" --permission-mode dontAsk \
      --settings "$settings" --strict-mcp-config "${add_dirs[@]}" \
      --model "$model" --effort "$effort" \
      --output-format json --max-budget-usd "$budget" --no-session-persistence \
      < /dev/null > "$base.json" 2> "$base.stderr"
  ) || rc=$?
  local duration=$(( SECONDS - started ))
  [[ -s "$base.stderr" ]] || rm -f "$base.stderr"

  local extra=""
  if $guard; then
    tree_after="$(git -C "$HARNESS_DIR" status --porcelain=v1 --untracked-files=all -- . ':(exclude).harness/reports/checkup' 2>/dev/null)"
    local -a before_lines=(${(f)tree_before}) after_lines=(${(f)tree_after})
    local -a gone=(${before_lines:|after_lines}) added=(${after_lines:|before_lines})
    local changed=$(( ${#gone} + ${#added} ))
    if (( changed )); then
      extra+=" tree_changed=$changed"
      echo "harness-launcher: working tree changed during checkup ($changed git status entries); if no other session was writing, review git status" >&2
    fi
  fi
  [[ -f "$base.stderr" ]] && extra=" stderr=$base.stderr$extra"

  local state subtype cost turns denials
  IFS=$'\t' read -r state subtype cost turns denials < <("$py" - "$base.json" "$base.md" <<'PY'
import json, os, sys
raw, md = sys.argv[1], sys.argv[2]
try:
    with open(raw, encoding="utf-8") as f:
        d = json.load(f)
    if not isinstance(d, dict):
        raise ValueError("not an object")
except Exception:
    print("nojson")
    sys.exit(0)
res = d.get("result")
wrote = isinstance(res, str) and bool(res.strip())
if wrote:
    fd = os.open(md, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(res if res.endswith("\n") else res + "\n")
subtype = str(d.get("subtype") or "unknown")
ok = d.get("is_error") is False and subtype == "success" and wrote
if not ok and subtype == "success":
    subtype = "error" if d.get("is_error") else "empty result"
num = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)
cost, turns = d.get("total_cost_usd"), d.get("num_turns")
print("\t".join([
    "ok" if ok else "fail", subtype,
    f"{cost:.2f}" if num(cost) else "-",
    str(turns) if num(turns) else "-",
    str(len(d.get("permission_denials") or [])),
]))
PY
)

  local exit_code=0
  case "$state" in
    ok)
      echo "checkup prompt-audit: ok report=$base.md cost_usd=$cost duration_s=$duration turns=$turns denials=$denials$extra"
      ;;
    fail)
      echo "checkup prompt-audit: failed ($subtype) raw=$base.json cost_usd=$cost denials=$denials$extra"
      exit_code=$(( rc ? rc : 1 ))
      ;;
    *)
      echo "checkup prompt-audit: failed (exit $rc) raw=$base.json$extra"
      exit_code=$(( rc ? rc : 1 ))
      ;;
  esac
  return $exit_code
}

# _harness_launcher_run_codex_cli <harness-dir> <resolved-policy> [args...]
#   Launches Codex CLI natively against a per-harness CODEX_HOME.
#   Modes:    fast | base | sol | plan | rich | astra | luna6 | sol6 → -p <profile>
#   Surface:  work → work MCP surface (combinable with any profile)
#   Apps:     --app <asdk_app_id> → add one app for this launch only
#   Wrapper:  happy → `happy codex ...`
#   Sessions: resume → `codex resume`,  continue → `codex resume --last`,
#             fork   → `codex fork`
#   SDK:      --passthrough → every later token is a native Codex argument;
#             a caller -p/--profile or -C/--cd replaces the launcher's.
#   Codex rejects -p for non-runtime subcommands, so the launcher omits it
#   there; plain `app-server` runs behind codex-app-server-guard.py.
_harness_launcher_run_codex_cli() {
  local HARNESS_DIR="$1" mcp_surface_policy="$2"; shift 2
  local run_dir="${HARNESS_RUN_DIR:-$HARNESS_DIR}"
  export HARNESS_PREFIX
  local HARNESS_OBSERVABILITY_ACTIVE HARNESS_OBSERVABILITY_ENABLED HARNESS_OBSERVABILITY_PROFILE HARNESS_OTLP_HTTP_ENDPOINT
  local OTEL_RESOURCE_ATTRIBUTES obs_rc
  # Per-harness GitHub identity: fail-open, never overrides with an empty token.
  local GH_TOKEN HARNESS_GH_USER
  harness_gh_token_load "$HARNESS_DIR" || true
  if harness_observability_load "$HARNESS_DIR"; then
    OTEL_RESOURCE_ATTRIBUTES="service.name=codex_exec,obs.runtime=codex,obs.profile=$HARNESS_OBSERVABILITY_PROFILE"
    export OTEL_RESOURCE_ATTRIBUTES
  else
    obs_rc=$?
    [[ "$obs_rc" -eq 1 ]] || return "$obs_rc"
  fi
  local profile=""
  local profile_explicit=false
  local mcp_profile=""
  local HARNESS_CODEX_APPS_ALLOWLIST="${HARNESS_CODEX_APPS_ALLOWLIST:-}"
  local HARNESS_CODEX_CONTEXT="272k"
  local subcmd=""
  local use_happy=false
  local freeform=false
  local passthrough=false
  local -a codex_args=() codex_passthrough_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --passthrough)
        shift; passthrough=true; codex_passthrough_args=("$@"); break ;;
      fast|base|sol|plan|rich)
        profile="$1"; profile_explicit=true; shift ;;
      astra|luna6|sol6)
        if $freeform; then
          codex_args+=("$1")
        else
          profile="$1"; profile_explicit=true
        fi
        shift ;;
      work)
        # Surface keyword, combinable with any model profile and any launcher
        # keyword in any order (same UX as the claude `light` keyword). Only a
        # genuinely free-form token before it (e.g. `exec work`) demotes it to
        # prompt text — launcher keywords like full-auto/continue must not.
        if $freeform; then
          codex_args+=("$1"); shift
        else
          case "$mcp_surface_policy" in
            legacy) mcp_profile="work" ;;
            single-full-compat)
              echo "⚠️  work MCP surface is deprecated for this project; using full" >&2
              ;;
            single-full)
              echo "harness-launcher: work MCP surface is retired for this project" >&2
              return 2
              ;;
          esac
          shift
        fi
        ;;
      --app)
        if $freeform; then
          codex_args+=("$1")
          shift
          [[ $# -gt 0 ]] && { codex_args+=("$1"); shift; }
        else
          [[ $# -ge 2 ]] || {
            echo "harness-launcher: --app requires an asdk_app_* id" >&2
            return 2
          }
          if [[ -n "$HARNESS_CODEX_APPS_ALLOWLIST" ]]; then
            HARNESS_CODEX_APPS_ALLOWLIST="$HARNESS_CODEX_APPS_ALLOWLIST,$2"
          else
            HARNESS_CODEX_APPS_ALLOWLIST="$2"
          fi
          shift 2
        fi
        ;;
      272k|1m)
        if $freeform; then
          codex_args+=("$1")
        else
          HARNESS_CODEX_CONTEXT="$1"
        fi
        shift ;;
      resume)              subcmd="resume"; shift ;;
      continue)            subcmd="resume"; codex_args+=(--last); shift ;;
      fork)                subcmd="fork"; codex_args+=(--last); shift ;;
      happy)               use_happy=true; shift ;;
      full-auto)           codex_args+=(--full-auto); shift ;;
      never)               codex_args+=(-a never); shift ;;
      bypass)              codex_args+=(--dangerously-bypass-approvals-and-sandbox); shift ;;
      *)                   freeform=true; codex_args+=("$1"); shift ;;
    esac
  done

  HARNESS_CODEX_APPS_ALLOWLIST="$(harness_codex_apps_allowlist_normalize "$HARNESS_CODEX_APPS_ALLOWLIST")" || return $?
  export HARNESS_CODEX_APPS_ALLOWLIST

  [[ -z "$profile" ]] && profile="base"
  export HARNESS_CODEX_CONTEXT

  # Caller wins after the marker. A caller -C/--cd must stay inside the
  # harness; a relative one resolves against the directory Codex starts in.
  local caller_profile=false caller_cd_set=false caller_cd="" caller_run_dir=""
  if $passthrough; then
    local i arg
    for (( i = 1; i <= ${#codex_passthrough_args}; i++ )); do
      arg="${codex_passthrough_args[i]}"
      case "$arg" in
        --) break ;;
        -p|--profile) caller_profile=true; (( i++ )) ;;
        -p?*|--profile=*) caller_profile=true ;;
        -C|--cd) caller_cd_set=true; caller_cd="${codex_passthrough_args[i+1]-}"; (( i++ )) ;;
        -C=*|--cd=*) caller_cd_set=true; caller_cd="${arg#*=}" ;;
        -C?*) caller_cd_set=true; caller_cd="${arg#-C}" ;;
        -*) if harness_codex_option_takes_value "$arg"; then (( i++ )); fi ;;
      esac
    done
  fi
  if $caller_cd_set; then
    caller_run_dir="$(cd "$run_dir" 2>/dev/null && harness_resolve_run_dir "$HARNESS_DIR" "$caller_cd" 2>/dev/null)" || {
      echo "harness-launcher: codex -C must name a directory inside the registered harness: $caller_cd" >&2
      return 2
    }
  fi

  local native_subcmd="" profile_arg=true guard_app_server=false
  if [[ -z "$subcmd" ]] && ! $use_happy; then
    native_subcmd="$(harness_codex_subcommand "${codex_args[@]}" "${codex_passthrough_args[@]}")"
    if harness_codex_subcommand_rejects_profile "$native_subcmd"; then
      if $profile_explicit; then
        echo "harness-launcher: codex profile '$profile' applies only to runtime commands; '${native_subcmd% }' rejects --profile" >&2
        return 2
      fi
      profile_arg=false
    fi
    case "$native_subcmd" in
      remote-control|exec-server|mcp-server)
        echo "harness-launcher: codex $native_subcmd serves clients outside the harness boundary guard; run 'command codex $native_subcmd' deliberately" >&2
        return 2
        ;;
    esac
    if [[ "$native_subcmd" == app-server ]]; then
      local app_server_route
      app_server_route="$(_harness_launcher_codex_app_server_route "${codex_args[@]}" "${codex_passthrough_args[@]}")"
      case "$app_server_route" in
        guard) guard_app_server=true ;;
        tool) ;;
        *)
          echo "harness-launcher: codex app-server '$app_server_route' is not supported; only the stdio app-server runs behind the harness boundary guard" >&2
          return 2
          ;;
      esac
    fi
  fi
  $caller_profile && profile_arg=false
  local guard_python=""
  if $guard_app_server; then
    guard_python="$(harness_python3_resolve)" || return 1
  fi

  # Validate incompatible combinations BEFORE preparing the runtime home, so a
  # rejected launch leaves no work-surface residue in the generated config.
  if $use_happy; then
    command -v happy >/dev/null 2>&1 || {
      echo "❌ happy not found in PATH" >&2
      return 1
    }
    if [[ -n "$subcmd" ]]; then
      echo "❌ Happy Codex cannot map Codex CLI resume/continue/fork. Use 'happy resume <happy-session-id>' or 'happy codex --resume <codex-thread-id>'." >&2
      return 1
    fi
    if $profile_explicit; then
      echo "❌ Happy Codex does not support launcher profiles. Use '${HARNESS_PREFIX:-harness} codex happy' for Happy mode, or '${HARNESS_PREFIX:-harness} codex $profile' for native Codex CLI." >&2
      return 1
    fi
    if [[ -n "$mcp_profile" ]]; then
      echo "❌ Happy Codex는 work MCP surface와 함께 사용할 수 없습니다." >&2
      return 1
    fi
  else
    local codex_bin
    codex_bin="$(_harness_launcher_codex_bin)" || {
      echo "❌ codex not found in PATH" >&2
      return 1
    }
  fi

  harness_mcp_surface_policy_is_single_full "$mcp_surface_policy" && unset HARNESS_CODEX_MCP_PROFILE
  if [[ -n "$mcp_profile" ]]; then
    local HARNESS_CODEX_MCP_PROFILE="$mcp_profile"
    export HARNESS_CODEX_MCP_PROFILE
    _harness_launcher_export_codex_runtime_env "$HARNESS_DIR" || return $?
  else
    _harness_launcher_export_codex_runtime_env "$HARNESS_DIR" || return $?
  fi

  # Plain invocation (not exec) so the user's interactive shell survives
  # codex exit — Ctrl+C returns to the prompt instead of closing the terminal.
  local -a launch_cmd=() codex_head=()
  if $use_happy; then
    launch_cmd=(happy codex)
  else
    launch_cmd=("$codex_bin")
  fi
  $caller_cd_set || codex_head+=(--cd "$run_dir")
  $profile_arg && codex_head+=(-p "$profile")
  if $guard_app_server; then
    local registry="${HARNESS_PROFILE_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/harness-launcher}/profiles"
    launch_cmd=("$guard_python" "$_HARNESS_LAUNCHER_BIN/codex-app-server-guard.py"
      --root "$HARNESS_DIR" --server-cwd "${caller_run_dir:-$run_dir}" --prefix "$HARNESS_PREFIX"
      --registry "$registry" -- "${launch_cmd[@]}")
  fi
  if [[ -n "$subcmd" ]]; then
    harness_codex_cmux_broker_start "$_HARNESS_LAUNCHER_BIN/codex-cmux-title-sync.py"
    (cd "$run_dir" && "${launch_cmd[@]}" "$subcmd" "${codex_head[@]}" "${codex_args[@]}" "${codex_passthrough_args[@]}")
  elif $use_happy; then
    harness_codex_cmux_broker_start "$_HARNESS_LAUNCHER_BIN/codex-cmux-title-sync.py"
    (cd "$run_dir" && "${launch_cmd[@]}" "${codex_args[@]}" "${codex_passthrough_args[@]}")
  else
    harness_codex_cmux_broker_start "$_HARNESS_LAUNCHER_BIN/codex-cmux-title-sync.py"
    (cd "$run_dir" && "${launch_cmd[@]}" "${codex_head[@]}" "${codex_args[@]}" "${codex_passthrough_args[@]}")
  fi
  local rc=$?
  harness_codex_cmux_broker_stop
  return $rc
}

# _harness_launcher_codex_app_server_route [codex args...]
#   Classifies the argv around `app-server`: `guard` for the stdio server,
#   `tool` for schema/binding generators and help, otherwise the shape that
#   would bypass the relay (a nested daemon/proxy or a non-stdio listener).
_harness_launcher_codex_app_server_route() {
  while (( $# )); do
    if [[ "$1" == app-server ]]; then
      shift
      break
    fi
    if [[ "$1" == -* ]] && harness_codex_option_takes_value "$1" && (( $# > 1 )); then
      shift
    fi
    shift
  done
  local arg
  while (( $# )); do
    arg="$1"; shift
    case "$arg" in
      --) break ;;
      --listen)
        [[ "${1-}" == stdio:// ]] || { print -r -- "--listen ${1-}"; return 0; }
        shift ;;
      --listen=*)
        [[ "${arg#--listen=}" == stdio:// ]] || { print -r -- "$arg"; return 0; } ;;
      -c|--config|--enable|--disable|--code-mode-host|--ws-auth|--ws-token-file|--ws-token-sha256|--ws-shared-secret-file|--ws-issuer|--ws-audience|--ws-max-clock-skew-seconds)
        if (( $# )); then shift; fi ;;
      -h|--help|generate-ts|generate-json-schema|help) print -r -- tool; return 0 ;;
      -*) ;;
      *) print -r -- "$arg"; return 0 ;;
    esac
  done
  print -r -- guard
}

# _harness_launcher_run_kiro_cli <harness-dir> [args...]
#   Launches Kiro CLI natively against a per-harness KIRO_HOME.
#   Modes:    fast | base | plan | rich → --model + --effort
#   Granular: model=<id> and/or effort=<low|medium|high|xhigh|max> override the
#             mode pair, so a one-off combination needs no new preset. A bare
#             model ID (claude-*, gpt-*, auto) is accepted as model=<id>.
#   Sessions: resume → --resume-picker, continue → -r
_harness_launcher_run_kiro_cli() {
  local HARNESS_DIR="$1"; shift
  local run_dir="${HARNESS_RUN_DIR:-$HARNESS_DIR}"
  local model="" effort="" agent="harness" mcp_surface="full"
  local model_set=0 effort_set=0
  local -a kiro_args=()
  local session_flag=""

  # Explicit model=/effort= win over a preset regardless of argument order:
  # `effort=medium plan` and `plan effort=medium` must behave identically.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      fast|base|plan|rich)
        harness_kiro_mode_resolve "$1"
        [[ $model_set -eq 1 ]] || model="$HARNESS_KIRO_MODEL"
        [[ $effort_set -eq 1 ]] || effort="$HARNESS_KIRO_EFFORT"
        shift ;;
      model=*)  model="${1#model=}"; model_set=1; shift ;;
      effort=*) effort="${1#effort=}"; effort_set=1; shift ;;
      claude-*|gpt-*|glm-*|qwen*|minimax-*|deepseek-*|auto)
        model="$1"; model_set=1; shift ;;
      resume)   session_flag="--resume-picker"; shift ;;
      continue) session_flag="-r"; shift ;;
      bypass)   kiro_args+=(-a); shift ;;
      light)    mcp_surface="light"; shift ;;
      *)        kiro_args+=("$1"); shift ;;
    esac
  done

  if [[ -z "$model" ]]; then
    harness_kiro_mode_resolve base
    model="$HARNESS_KIRO_MODEL"
    if [[ -z "$effort" ]]; then
      effort="$HARNESS_KIRO_EFFORT"
    fi
  fi
  if [[ -z "$effort" ]]; then
    effort="$(harness_kiro_effort_recommended "$model")"
  fi
  # The Kiro CLI validates --model (it errors with the live catalog) but NOT
  # --effort: an unknown level is silently swallowed, so guard it here.
  if ! harness_kiro_effort_is_valid "$effort"; then
    echo "❌ 잘못된 effort: '$effort' (가능한 값: $HARNESS_KIRO_EFFORT_LEVELS)" >&2
    return 1
  fi

  # Resolve the binary before exporting the surface profile: an early failure
  # return here must not leave HARNESS_KIRO_MCP_PROFILE in the user's shell.
  local kiro_bin
  kiro_bin="$(_harness_launcher_kiro_bin)" || {
    echo "❌ kiro-cli not found in PATH" >&2
    return 1
  }

  if [[ "$mcp_surface" == "light" ]]; then
    export HARNESS_KIRO_MCP_PROFILE="light"
  else
    unset HARNESS_KIRO_MCP_PROFILE
  fi
  _harness_launcher_export_kiro_runtime_env "$HARNESS_DIR" || {
    local rc=$?
    unset HARNESS_KIRO_MCP_PROFILE
    return $rc
  }

  local -a launch_cmd=("$kiro_bin" chat)
  [[ -n "$session_flag" ]] && launch_cmd+=("$session_flag")
  launch_cmd+=(--model "$model" --effort "$effort" --agent "$agent")
  [[ ${#kiro_args[@]} -gt 0 ]] && launch_cmd+=("${kiro_args[@]}")
  unset HARNESS_KIRO_MODEL HARNESS_KIRO_EFFORT

  (cd "$run_dir" && "${launch_cmd[@]}")
  local rc=$?
  unset HARNESS_KIRO_MCP_PROFILE
  return $rc
}

# _harness_launcher_complete <harness-dir>
_harness_launcher_complete() {
  local dir="$1"
  local -a shortcuts
  local m desc codex_surface_desc="" kiro_surface_desc=""
  local HARNESS_NAME HARNESS_PREFIX HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST
  local HARNESS_MCP_SURFACE_POLICY="" mcp_surface_policy
  if [[ -f "$dir/config/launcher.env" ]]; then
    source "$dir/config/launcher.env"
  fi
  mcp_surface_policy="$(harness_mcp_surface_policy_resolve "$HARNESS_MCP_SURFACE_POLICY")" || return $?
  # Mode descriptions come from the shared table so completion text cannot
  # drift from the launched model/effort. Resolution runs in subshells so the
  # HARNESS_MODE_* globals never touch the interactive shell.
  shortcuts=()
  for m in fast base plan opus rich fable; do
    desc="$( harness_mode_resolve "$m" direct; printf '%s · %s' "$HARNESS_MODE_MODEL" "$HARNESS_MODE_EFFORT" )"
    shortcuts+=("$m:$desc")
  done
  desc="$( harness_mode_resolve ultracode direct; printf '%s · %s' "$HARNESS_MODE_MODEL" "$HARNESS_MODE_EFFORT" )"
  if ! harness_mcp_surface_policy_is_single_full "$mcp_surface_policy"; then
    shortcuts+=('light:Light MCP surface — SSH-backed servers excluded (claude/kiro-cli)')
    codex_surface_desc=' · work surface'
  else
    kiro_surface_desc=' (optional light surface)'
  fi
  shortcuts+=(
    "ultracode:$desc now · /effort→ultracode for workflows (direct only)"
    'continue:Continue last session'
    'resume:Resume from list'
    'bypass:Skip all permission prompts'
    'acceptEdits:Auto-approve edits only'
    'dontAsk:Auto-approve most actions'
    '--chrome:Enable Claude in Chrome integration'
    '--no-chrome:Disable Claude in Chrome integration'
    "codex:Codex CLI native (272K default · 1m opt-in · profiles${codex_surface_desc}/fork/safety)"
    'codex-smoke:Send one bounded metadata-only Codex verification event'
    'checkup:Headless read-only /checkup prompt-audit at the harness root'
    "kiro-cli:Kiro CLI native${kiro_surface_desc}"
    'happy:Use Happy mobile wrapper for Codex CLI'
  )
  # Gateway env files are sourced in subshells so API keys never leak into
  # the interactive shell's variables.
  local _kiro_url _codex_url
  _kiro_url="${KIRO_GATEWAY_URL:-}"
  [[ -z "$_kiro_url" && -f "$dir/config/.local/kiro-gateway.env" ]] && \
    _kiro_url="$( source "$dir/config/.local/kiro-gateway.env" 2>/dev/null; printf '%s' "${KIRO_GATEWAY_URL:-}" )"
  _codex_url="${CODEX_GATEWAY_URL:-}"
  [[ -z "$_codex_url" && -f "$dir/config/.local/codex-gateway.env" ]] && \
    _codex_url="$( source "$dir/config/.local/codex-gateway.env" 2>/dev/null; printf '%s' "${CODEX_GATEWAY_URL:-}" )"
  [[ -n "$_kiro_url" ]]  && shortcuts+=('kiro:Kiro via gateway')
  [[ -n "$_codex_url" ]] && shortcuts+=('codex-gateway:Claude Code via Codex gateway (legacy)')
  _describe 'harness shortcuts' shortcuts
}
