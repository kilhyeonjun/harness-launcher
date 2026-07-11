#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
ZSH_BIN="${ZSH_BIN:-$(command -v zsh)}"
passed=0
skipped=0
has_lockf=0
[[ -x /usr/bin/lockf ]] && has_lockf=1
[[ "${HARNESS_TEST_FORCE_NO_LOCKF:-0}" == "1" ]] && has_lockf=0

for test_file in "$ROOT"/test/test-*.sh; do
  test_name="$(basename "$test_file")"
  # This integration test verifies the macOS /usr/bin/lockf kernel-lock contract.
  # Hosted macOS images without that system binary cannot exercise it safely;
  # production preparation remains fail-closed when cache synchronization needs it.
  if [[ "$has_lockf" -eq 0 ]] && [[ "$test_name" == "test-codex-home-prepare.sh" \
    || "$test_name" == "test-codex-home-lock.sh" \
    || "$test_name" == "test-codex-config-preservation.sh" ]]; then
    printf '==> %s (SKIP: /usr/bin/lockf unavailable)\n' "$test_name"
    skipped=$((skipped + 1))
    continue
  fi
  IFS= read -r first_line < "$test_file" || true
  if [[ "$first_line" == *zsh* ]]; then
    interpreter="$ZSH_BIN"
  else
    interpreter="$BASH_BIN"
  fi

  printf '==> %s (%s)\n' "$test_name" "$interpreter"
  "$interpreter" "$test_file"
  passed=$((passed + 1))
done

printf '\n%d test scripts passed; %d skipped.\n' "$passed" "$skipped"
