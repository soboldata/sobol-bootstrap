#!/usr/bin/env bash
# diff-mm-configs.sh — Pull Mattermost config.json from N CTs and show which
# settings differ across them. Secrets (passwords/tokens/keys) get redacted
# uniformly so they never show up as "differences".
#
# Usage:
#   bash diff-mm-configs.sh 112 115 121
#
# Run on the PVE host that hosts these CTs. If a CT isn't on this host, the
# script will say so and skip it. Re-run on the other PVE host with the
# CTs that live there.

set -Eeuo pipefail

CTIDS=("$@")
if (( ${#CTIDS[@]} < 2 )); then
  echo "Usage: $0 <ctid1> <ctid2> [ctid3] ..." >&2
  echo "Example: $0 112 115 121" >&2
  exit 2
fi

# Verify each CT exists on this PVE host before doing real work
for ct in "${CTIDS[@]}"; do
  if ! pct config "$ct" >/dev/null 2>&1; then
    echo "[warn] CT $ct not found on this PVE host — skip or run on the other host." >&2
  fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Pulling Mattermost config from each CT into $WORK ..."

for ct in "${CTIDS[@]}"; do
  pct config "$ct" >/dev/null 2>&1 || { echo "[skip] $ct"; continue; }

  # Confirm Mattermost is actually here
  if ! pct exec "$ct" -- test -f /opt/mattermost/config/config.json 2>/dev/null; then
    echo "[skip] CT $ct — no /opt/mattermost/config/config.json"
    continue
  fi

  pct exec "$ct" -- python3 -c '
import json, re
with open("/opt/mattermost/config/config.json") as f:
    c = json.load(f)
SENSITIVE = re.compile(r"(password|secret|token|key|salt|datasource|connectionstring|smtp(user|password))", re.I)
def scrub(o):
    if isinstance(o, dict):
        return {k: ("<REDACTED>" if SENSITIVE.search(k) and o.get(k) else scrub(v)) for k, v in o.items()}
    if isinstance(o, list):
        return [scrub(x) for x in o]
    return o
print(json.dumps(scrub(c)))
' > "$WORK/ct-$ct.json" 2>/dev/null

  if [[ ! -s "$WORK/ct-$ct.json" ]]; then
    echo "[warn] CT $ct produced empty config — Mattermost may not be installed."
    rm -f "$WORK/ct-$ct.json"
    continue
  fi

  echo "  ✓ CT $ct  ($(wc -c < "$WORK/ct-$ct.json") bytes)"
done

# Build the diff
echo
echo "================================================================"
echo "Settings that DIFFER across the CTs"
echo "================================================================"
echo

WORK="$WORK" CTIDS="${CTIDS[*]}" python3 - <<'PYEOF'
import json, os, re, sys, glob

work = os.environ["WORK"]
ctids = os.environ["CTIDS"].split()

# Load all configs that survived the pull
configs = {}
for ct in ctids:
    p = os.path.join(work, f"ct-{ct}.json")
    if os.path.exists(p):
        with open(p) as f:
            configs[ct] = json.load(f)

if len(configs) < 2:
    print("Need at least 2 configs to compare; have", len(configs))
    sys.exit(0)

# Flatten dict to {dotted.path: value}
def flatten(o, prefix=""):
    out = {}
    if isinstance(o, dict):
        for k, v in o.items():
            key = f"{prefix}.{k}" if prefix else k
            out.update(flatten(v, key))
    elif isinstance(o, list):
        # Represent lists by their JSON repr so we can string-compare cleanly
        out[prefix] = json.dumps(o, sort_keys=True)
    else:
        out[prefix] = json.dumps(o)
    return out

flats = {ct: flatten(c) for ct, c in configs.items()}

# Union of all keys
all_keys = set()
for f in flats.values():
    all_keys.update(f.keys())

# Find diverging keys
diffs = []
for k in sorted(all_keys):
    values = {ct: flats[ct].get(k, "<absent>") for ct in flats}
    if len(set(values.values())) > 1:
        diffs.append((k, values))

# Categorize: webhook-relevant first, then everything else
WEBHOOK_HINTS = re.compile(r"webhook|cors|trust|allowed|connection|siteurl|insecure|integration|command|incoming|outgoing|allowinsecure", re.I)
webhook_diffs = [(k, v) for k, v in diffs if WEBHOOK_HINTS.search(k)]
other_diffs  = [(k, v) for k, v in diffs if not WEBHOOK_HINTS.search(k)]

def render(group_name, items):
    if not items:
        return
    print(f"\n--- {group_name} ({len(items)}) ---\n")
    for k, values in items:
        print(f"  {k}")
        for ct, v in values.items():
            # Truncate long values for readability
            sv = v if len(v) <= 100 else v[:97] + "..."
            print(f"    CT {ct}: {sv}")
        print()

render("WEBHOOK-RELEVANT differences (look here first!)", webhook_diffs)
render("Other differences", other_diffs)

# Summary footer
print(f"\n{'='*64}")
print(f"Compared CTs: {', '.join(sorted(flats.keys()))}")
print(f"Total settings: {len(all_keys)}")
print(f"Differences: {len(diffs)}  (webhook-relevant: {len(webhook_diffs)})")
PYEOF
