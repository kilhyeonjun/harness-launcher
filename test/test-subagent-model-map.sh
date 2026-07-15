#!/usr/bin/env bash
# test-subagent-model-map.sh — the tsv is the SSOT, but both prepare scripts
# carry a literal fallback map used when the tsv is missing at runtime (e.g. an
# install path that didn't ship the file). Those fallbacks MUST stay byte-equal
# to the tsv rows, or a missing-file install silently drifts from the SSOT.
# This test parses all three and asserts they agree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TSV="$ROOT/bin/subagent-model-map.tsv"
CODEX="$ROOT/bin/codex-home-prepare.sh"
KIRO="$ROOT/bin/kiro-home-prepare.sh"

for f in "$TSV" "$CODEX" "$KIRO"; do
  [[ -f "$f" ]] || { echo "FAIL: missing $f" >&2; exit 1; }
done

python3 - "$TSV" "$CODEX" "$KIRO" <<'PY'
import re, sys

tsv_path, codex_path, kiro_path = sys.argv[1:4]

# ── tsv: tier -> (codex_model, codex_effort, kiro_model) ──
tsv = {}
with open(tsv_path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) >= 4 and cols[0]:
            tsv[cols[0].strip().lower()] = (cols[1].strip(), cols[2].strip(), cols[3].strip())

fail = 0
codex_fb, kiro_fb = {}, {}

# ── codex fallback dict: _MODEL_MAP = { "tier": ("model","effort"), ... } ──
codex_src = open(codex_path, encoding="utf-8").read()
m = re.search(r"_MODEL_MAP\s*=\s*\{(.*?)\}", codex_src, re.S)
if not m:
    print("FAIL: could not locate _MODEL_MAP literal in codex-home-prepare.sh"); fail = 1
else:
    codex_fb = {t: (mdl, eff) for t, mdl, eff in
                re.findall(r'"(\w+)"\s*:\s*\("([^"]+)",\s*"([^"]+)"\)', m.group(1))}
    for tier, (cmodel, ceffort, _k) in tsv.items():
        if codex_fb.get(tier) != (cmodel, ceffort):
            print(f"FAIL: codex fallback[{tier}]={codex_fb.get(tier)} != tsv ({cmodel},{ceffort})"); fail = 1

# ── kiro fallback dict: model_map = { "tier": "model-id", ... } ──
kiro_src = open(kiro_path, encoding="utf-8").read()
m = re.search(r"model_map\s*=\s*\{(.*?)\}", kiro_src, re.S)
if not m:
    print("FAIL: could not locate model_map literal in kiro-home-prepare.sh"); fail = 1
else:
    kiro_fb = dict(re.findall(r'"(\w+)"\s*:\s*"([^"]+)"', m.group(1)))
    for tier, (_cm, _ce, kmodel) in tsv.items():
        if kiro_fb.get(tier) != kmodel:
            print(f"FAIL: kiro fallback[{tier}]={kiro_fb.get(tier)} != tsv {kmodel}"); fail = 1

# every tsv tier must be represented in both fallbacks (no silently-dropped tier)
for tier in tsv:
    if tier not in codex_fb:
        print(f"FAIL: tier '{tier}' in tsv but absent from codex fallback"); fail = 1
    if tier not in kiro_fb:
        print(f"FAIL: tier '{tier}' in tsv but absent from kiro fallback"); fail = 1

if fail:
    sys.exit(1)
print(f"PASS: tsv ({len(tsv)} tiers) == codex + kiro fallback maps")
PY
