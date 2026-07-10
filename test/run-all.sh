#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
ZSH_BIN="${ZSH_BIN:-$(command -v zsh)}"
passed=0

for test_file in "$ROOT"/test/test-*.sh; do
  test_name="$(basename "$test_file")"
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

printf '\nAll %d test scripts passed.\n' "$passed"
