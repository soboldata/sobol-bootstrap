#!/usr/bin/env bash
# diagnose-n8n.sh — Read-only check: what does the n8n CT actually have?
# Tells you whether owner setup worked, whether the API key is valid, and
# whether any credentials / workflows are in there.
#
# Run on the PVE host:
#   bash addons/n8n/diagnose-n8n.sh
set -Eeuo pipefail

find_ct_by_hostname() {
  local want="$1"
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

CTID="$(find_ct_by_hostname n8n 2>/dev/null || true)"
[[ -n "$CTID" ]] || { echo "no n8n CT found"; exit 1; }

# Read LAST occurrence (so later 'echo K=v >>' wins over earlier ones).
API_KEY="$(awk -F= '/^N8N_API_KEY=/ {sub(/^[^=]*=/,"",$0); v=$0} END {print v}' /root/td-tokens.txt 2>/dev/null || true)"
# Strip whitespace
API_KEY="${API_KEY#"${API_KEY%%[![:space:]]*}"}"
API_KEY="${API_KEY%"${API_KEY##*[![:space:]]}"}"
# Reject obvious placeholders
case "$API_KEY" in "<"*">"|"REPLACE_ME"|"CHANGEME") API_KEY="" ;; esac

# Warn if tokens file has duplicates
DUPES="$(grep -c '^N8N_API_KEY=' /root/td-tokens.txt 2>/dev/null || echo 0)"
if (( DUPES > 1 )); then
  echo "!!! /root/td-tokens.txt has $DUPES lines starting with N8N_API_KEY="
  echo "!!! Only the LAST one is used. Fix with:"
  echo "!!!   sed -i '/^N8N_API_KEY=<paste/d' /root/td-tokens.txt"
  echo
fi

echo "=== n8n CT: $CTID ==="
echo
echo "--- service status ---"
pct exec "$CTID" -- systemctl is-active n8n 2>/dev/null || echo "n8n service not active"
echo
echo "--- health ---"
pct exec "$CTID" -- curl -sS http://localhost:5678/healthz | head -3
echo
echo "--- owner exists? (POST to /rest/owner/setup w/ junk; 400 = already set up) ---"
pct exec "$CTID" -- bash -lc 'curl -sS -o /dev/null -w "HTTP %{http_code}\n" -X POST http://localhost:5678/rest/owner/setup -H "Content-Type: application/json" -d "{}"'
echo
echo "--- API key in td-tokens.txt? ---"
if [[ -n "$API_KEY" ]]; then echo "yes (len ${#API_KEY})"; else echo "NO — owner setup or key mint failed"; fi
echo
echo "--- Credentials in n8n (via API key) ---"
if [[ -n "$API_KEY" ]]; then
  pct exec "$CTID" -- bash -lc "curl -sS -H 'X-N8N-API-KEY: $API_KEY' http://localhost:5678/api/v1/credentials" \
    | python3 -m json.tool 2>/dev/null | head -40 || echo "(could not parse)"
else
  echo "(no api key — skipping)"
fi
echo
echo "--- Workflows in n8n (via API key) ---"
if [[ -n "$API_KEY" ]]; then
  pct exec "$CTID" -- bash -lc "curl -sS -H 'X-N8N-API-KEY: $API_KEY' http://localhost:5678/api/v1/workflows" \
    | python3 -m json.tool 2>/dev/null | head -40 || echo "(could not parse)"
fi
echo
echo "--- n8n version ---"
pct exec "$CTID" -- bash -lc 'n8n --version 2>/dev/null || npm ls -g --depth=0 2>/dev/null | grep n8n'
