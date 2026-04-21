#!/usr/bin/env bash
# harness-launcher — TUI for picking provider/mode/effort.
# Invoked by bin/aliases.zsh when user runs `<prefix>` with no shortcut args.
# Required env: HARNESS_DIR, HARNESS_NAME

HARNESS_DIR="${HARNESS_DIR:?HARNESS_DIR required}"
HARNESS_NAME="${HARNESS_NAME:?HARNESS_NAME required}"
cd "$HARNESS_DIR"

MENU_RESULT=""
menu() {
  local header="$1"; shift
  local options=("$@")
  MENU_RESULT=""

  if command -v gum >/dev/null 2>&1 && : </dev/tty 2>/dev/null; then
    local result rc
    result=$(gum choose \
      --header "$header" \
      --cursor "❯ " \
      --select-if-one \
      --height "${#options[@]}" \
      "${options[@]}")
    rc=$?
    [ $rc -eq 130 ] && exit 0
    [ $rc -ne 0 ] && return 1
    MENU_RESULT="$result"
    return 0
  fi

  echo ""
  echo "$header"
  for i in "${!options[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${options[$i]}"
  done
  read -rp "> " choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
    MENU_RESULT="${options[$((choice - 1))]}"
    return 0
  fi
  return 1
}

probe_provider_health() {
  local provider_url="$1"
  [[ -z "$provider_url" ]] && return 1
  PROBE_PROVIDER_URL="$provider_url" \
    node -e 'const baseUrl = process.env.PROBE_PROVIDER_URL; const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 2000); fetch(`${baseUrl}/health`, { signal: controller.signal }).then(() => { clearTimeout(timer); process.exit(0); }).catch(() => { clearTimeout(timer); process.exit(1); });' >/dev/null 2>&1
}

detect_active_providers() {
  [[ -f "$HARNESS_DIR/config/.local/kiro-gateway.env" ]]  && source "$HARNESS_DIR/config/.local/kiro-gateway.env"
  [[ -f "$HARNESS_DIR/config/.local/codex-gateway.env" ]] && source "$HARNESS_DIR/config/.local/codex-gateway.env"
  local -a providers=("1. ☁️  Anthropic (direct)")
  if probe_provider_health "${KIRO_GATEWAY_URL:-}"; then
    providers+=("2. 🔀 Kiro (via gateway)")
  fi
  if probe_provider_health "${CODEX_GATEWAY_URL:-}"; then
    providers+=("3. ⚡ Codex (via gateway)")
  fi
  printf '%s\n' "${providers[@]}"
}

SESSION_FLAG=""
CLAUDE_ARGS=""
IS_CUSTOM=false
STEP=1
PROVIDER_URL=""
GATEWAY_API_KEY=""
PROVIDER_NAME=""
LAUNCH_EXECUTABLE="claude"
HAPPY_RETURN_STEP=5
HAS_HAPPY=false
command -v happy >/dev/null 2>&1 && HAS_HAPPY=true

active_providers=()
while IFS= read -r line; do
  active_providers+=("$line")
done < <(detect_active_providers)
if [[ ${#active_providers[@]} -ge 2 ]]; then
  STEP=0
fi

while true; do
  case $STEP in

  0)
    menu "Select provider" "${active_providers[@]}" || exit 0
    case "$MENU_RESULT" in
      2*)
        _KIRO_ENV="$HARNESS_DIR/config/.local/kiro-gateway.env"
        [[ -f "$_KIRO_ENV" ]] && source "$_KIRO_ENV"
        PROVIDER_URL="${KIRO_GATEWAY_URL}"
        GATEWAY_API_KEY="${KIRO_GATEWAY_API_KEY:-}"
        PROVIDER_NAME="kiro" ;;
      3*)
        _CODEX_ENV="$HARNESS_DIR/config/.local/codex-gateway.env"
        [[ -f "$_CODEX_ENV" ]] && source "$_CODEX_ENV"
        PROVIDER_URL="${CODEX_GATEWAY_URL}"
        GATEWAY_API_KEY="${CODEX_GATEWAY_API_KEY:-}"
        PROVIDER_NAME="codex" ;;
      *)
        PROVIDER_URL=""; GATEWAY_API_KEY=""; PROVIDER_NAME="" ;;
    esac
    STEP=1
    ;;

  1)
    menu "=== $HARNESS_NAME ===" \
      "1. New session" \
      "2. Continue last session" \
      "3. Resume (pick from list)" || exit 0
    SESSION_FLAG=""
    case "$MENU_RESULT" in
      *Continue*) SESSION_FLAG="--continue" ;;
      *Resume*)   SESSION_FLAG="--resume" ;;
    esac
    STEP=2
    ;;

  2)
    case "$PROVIDER_NAME" in
      kiro)  RICH_LABEL="4. 🧠 Rich — Opus 4.6, max effort (200K via gateway)" ;;
      codex) RICH_LABEL="4. 🧠 Rich — Opus 4.6, max effort (1M via gateway)" ;;
      *)     RICH_LABEL="4. 🧠 Rich — Opus 1M, max effort" ;;
    esac
    menu "Select mode" \
      "1. ⚡ Fast — Sonnet, low effort" \
      "2. ⚖️  Base — Sonnet, high effort" \
      "3. 🗺️  Plan — Opusplan, high effort" \
      "$RICH_LABEL" \
      "5. 🔧 Custom" || { STEP=1; continue; }

    CLAUDE_ARGS=""; EFFORT_ENV=""; IS_CUSTOM=false
    case "$MENU_RESULT" in
      *Fast*)
        CLAUDE_ARGS="--model haiku"
        EFFORT_ENV="low"; STEP=5 ;;
      *Base*)
        case "$PROVIDER_NAME" in
          kiro)  ;;
          codex) CLAUDE_ARGS="--model sonnet[1m]" ;;   # DRIFT FIX: added codex branch
          *)     CLAUDE_ARGS="--model sonnet" ;;
        esac
        EFFORT_ENV="high"; STEP=5 ;;
      *Plan*)
        case "$PROVIDER_NAME" in
          kiro)  CLAUDE_ARGS="--model opusplan"; EFFORT_ENV="high" ;;
          codex) CLAUDE_ARGS="--model opusplan[1m]"; EFFORT_ENV="xhigh" ;;
          *)     CLAUDE_ARGS="--model opusplan"; EFFORT_ENV="high" ;;
        esac
        STEP=5 ;;
      *Rich*)
        case "$PROVIDER_NAME" in
          kiro)  CLAUDE_ARGS="--model claude-opus-4-6" ;;
          codex) CLAUDE_ARGS="--model opus[1m]" ;;     # DRIFT FIX: opus → opus[1m]
          *)     CLAUDE_ARGS="--model opus[1m]" ;;
        esac
        EFFORT_ENV="max"; STEP=5 ;;
      *Custom*) IS_CUSTOM=true; STEP=3 ;;
    esac
    ;;

  3)
    if [[ "$PROVIDER_NAME" == "kiro" ]]; then
      menu "Model" "1. sonnet" "2. opus" "3. opusplan" "4. haiku" || { STEP=2; continue; }
    else
      menu "Model" "1. sonnet" "2. opus" "3. opus-1m" "4. opusplan" "5. haiku" || { STEP=2; continue; }
    fi
    C_MODEL=$(echo "$MENU_RESULT" | sed 's/^[0-9]*\. //')
    STEP=4
    ;;

  4)
    case "$C_MODEL" in
      haiku)    menu "Effort ($C_MODEL)" "1. low ← Recommended" "2. medium" || { STEP=3; continue; } ;;
      sonnet)   menu "Effort ($C_MODEL)" "1. low" "2. medium ← Recommended" "3. high" || { STEP=3; continue; } ;;
      opus-1m)  menu "Effort ($C_MODEL)" "1. medium" "2. high" "3. max ← Recommended" || { STEP=3; continue; } ;;
      opus)     menu "Effort ($C_MODEL)" "1. medium" "2. high ← Recommended" "3. max" || { STEP=3; continue; } ;;
      opusplan) menu "Effort ($C_MODEL)" "1. medium" "2. high ← Recommended" || { STEP=3; continue; } ;;
    esac
    C_EFFORT=$(echo "$MENU_RESULT" | sed 's/^[0-9]*\. //' | awk '{print $1}')
    C_MODEL_ID="$C_MODEL"
    if [[ "$C_MODEL" == "opus-1m" ]]; then
      case "$PROVIDER_NAME" in
        kiro)  C_MODEL_ID="claude-opus-4-6" ;;
        codex) C_MODEL_ID="opus[1m]" ;;       # DRIFT FIX: opus → opus[1m]
        *)     C_MODEL_ID="claude-opus-4-6[1m]" ;;
      esac
    fi
    CLAUDE_ARGS="--model ${C_MODEL_ID:-sonnet}"
    EFFORT_ENV="${C_EFFORT:-medium}"
    STEP=5
    ;;

  5)
    menu "Advanced options?" "1. Yes" "2. No (start now)" || {
      if [ "$IS_CUSTOM" = true ]; then STEP=4; else STEP=2; fi
      continue
    }
    case "$MENU_RESULT" in
      *Yes*) STEP=6 ;;
      *)
        if $HAS_HAPPY; then
          HAPPY_RETURN_STEP=5
          STEP=7
        else
          break
        fi
        ;;
    esac
    ;;

  6)
    menu "Permission mode" \
      "1. default — Ask each tool / 매번 확인" \
      "2. acceptEdits — Auto-approve edits / 편집만 자동 승인" \
      "3. dontAsk — Auto-approve most / 대부분 자동 승인" \
      "4. bypassPermissions — Skip all / 모든 확인 건너뛰기" || { STEP=5; continue; }
    CLAUDE_ARGS="${CLAUDE_ARGS%% --permission-mode *}"
    PERM=$(echo "$MENU_RESULT" | sed 's/^[0-9]*\. //' | awk '{print $1}')
    [ "$PERM" != "default" ] && CLAUDE_ARGS="$CLAUDE_ARGS --permission-mode $PERM"
    if $HAS_HAPPY; then
      HAPPY_RETURN_STEP=6
      STEP=7
    else
      break
    fi
    ;;

  7)
    menu "Use Happy mobile wrapper?" \
      "1. No ← Recommended" \
      "2. Yes" || { STEP=$HAPPY_RETURN_STEP; continue; }
    case "$MENU_RESULT" in
      2*) LAUNCH_EXECUTABLE="happy" ;;
      *)  LAUNCH_EXECUTABLE="claude" ;;
    esac
    break
    ;;

  esac
done

CLAUDE_ARGS="$SESSION_FLAG $CLAUDE_ARGS"
CLAUDE_ARGS=$(echo "$CLAUDE_ARGS" | xargs)
read -ra CLAUDE_ARGS_ARR <<< "$CLAUDE_ARGS"

stty sane 2>/dev/null

echo ""
PROVIDER_LABEL=""
[[ -n "$PROVIDER_URL" ]] && PROVIDER_LABEL="via $PROVIDER_URL · "
echo "Starting: ${PROVIDER_LABEL}$LAUNCH_EXECUTABLE $CLAUDE_ARGS"
echo ""
command -v "$LAUNCH_EXECUTABLE" >/dev/null 2>&1 || {
  echo "Error: $LAUNCH_EXECUTABLE not found in PATH"
  exit 1
}

if [[ -n "$PROVIDER_URL" ]]; then
  export ANTHROPIC_BASE_URL="$PROVIDER_URL"
  if [[ -n "$GATEWAY_API_KEY" ]]; then
    export ANTHROPIC_AUTH_TOKEN="$GATEWAY_API_KEY"
    unset ANTHROPIC_API_KEY
  fi
  unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_CUSTOM_HEADERS
  if [[ "$PROVIDER_NAME" == "codex" ]]; then
    # DRIFT FIX: no dead fallbacks
    [[ -n "${CODEX_OPUS_MODEL:-}" ]]   && export ANTHROPIC_DEFAULT_OPUS_MODEL="$CODEX_OPUS_MODEL"
    [[ -n "${CODEX_SONNET_MODEL:-}" ]] && export ANTHROPIC_DEFAULT_SONNET_MODEL="$CODEX_SONNET_MODEL"
    [[ -n "${CODEX_HAIKU_MODEL:-}" ]]  && export ANTHROPIC_DEFAULT_HAIKU_MODEL="$CODEX_HAIKU_MODEL"
  fi
fi
[[ -n "$EFFORT_ENV" ]] && CLAUDE_ARGS_ARR+=(--effort "$EFFORT_ENV")
exec "$LAUNCH_EXECUTABLE" "${CLAUDE_ARGS_ARR[@]}"
