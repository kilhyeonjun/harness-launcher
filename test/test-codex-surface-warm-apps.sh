#!/usr/bin/env bash
# test-codex-surface-warm-apps.sh — the warm fingerprint must carry the ChatGPT
# Apps allowlist.
#
# Generated config.toml depends on HARNESS_CODEX_APPS_ALLOWLIST. If the warm
# fingerprint ignores it, an already-converged home keeps its stale [apps.*]
# shape and the variable silently does nothing.
#
# A synthetic warm hit is not reproducible here: the probe additionally requires
# twelve generated files, recorded output signatures, a managed config
# projection hash, and a matching skill catalog. So this asserts the source
# contract on both sides of the fingerprint, the same way
# test-codex-observability-profile.sh pins the profile environment. End-to-end
# behavior is verified against a real prepared harness home before release.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SURFACE="$ROOT/bin/codex-surface.py"
WARM="$ROOT/bin/codex-surface-warm.py"

for file in "$SURFACE" "$WARM"; do
  [[ -f "$file" ]] || { echo "FAIL: $file missing"; exit 1; }
done

grep -q '"apps_allowlist": apps_allowlist(),' "$SURFACE" || {
  echo "FAIL: fingerprint payload must record the app allowlist"; exit 1;
}
echo "PASS: fingerprint payload records the app allowlist"

# write_stamp rejects unknown fields, so the key has to be declared there too or
# every prepare run fails once the payload carries it.
grep -q '^        "apps_allowlist",$' "$SURFACE" || {
  echo "FAIL: write_stamp must accept the app allowlist field"; exit 1;
}
echo "PASS: write_stamp accepts the app allowlist field"

grep -q '^        "apps_allowlist",$' "$WARM" || {
  echo "FAIL: warm probe must compare the recorded app allowlist against the stamp"; exit 1;
}
grep -q 'if fingerprint.get("apps_allowlist") != apps_allowlist():' "$WARM" || {
  echo "FAIL: warm probe must compare the recorded app allowlist against the environment"; exit 1;
}
echo "PASS: warm probe compares the app allowlist"

# Both sides must read the same variable, or a harness would converge warm on a
# fingerprint the generator never produced.
for file in "$SURFACE" "$WARM"; do
  grep -q 'os.environ.get("HARNESS_CODEX_APPS_ALLOWLIST", "")' "$file" || {
    echo "FAIL: $(basename "$file") must read HARNESS_CODEX_APPS_ALLOWLIST"; exit 1;
  }
done
echo "PASS: generator and warm probe read the same allowlist variable"

echo "✓ All codex surface warm apps tests passed"
