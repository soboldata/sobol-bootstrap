#!/usr/bin/env bash
# setup-homepage-pi-widgets.sh — Add Pi/Mattermost-specific tiles to Homepage.
#
# Two tiles, both customapi-based:
#
#   1. Pi Bridge  — number of channels the pi-mattermost bridge knows about
#                   (live + persisted + orphans). Pulled from the bridge's
#                   own /api/channel-count endpoint at port 4000.
#
#   2. Latest in #bot — most recent message in the Mattermost #bot channel.
#                   Mattermost's /api/v4/channels/{id}/posts response has a
#                   dynamic post-UUID key that Homepage's customapi can't
#                   reach directly, so we install a tiny Python proxy on the
#                   Mattermost CT (mm-latest-bot-post.service, port 4501)
#                   that re-shapes the response into flat fields.
#
# Side effects (all idempotent):
#   * Adds /etc/systemd/system/pi-mattermost.service.d/bind-all.conf inside
#     the ollama-pi-agent CT (overrides PI_MATTERMOST_BIND=0.0.0.0 so the
#     bridge is reachable from the Homepage CT across the tailnet/vmbr).
#   * Adds PI_BRIDGE_TOKEN to /root/td-tokens.txt on the PVE host.
#   * Installs /opt/mm-helpers/latest-bot-post.py + mm-latest-bot-post.service
#     in the mattermost CT.
#   * Replaces or appends two TD-Addon blocks in homepage's services.yaml.
#   * Restarts: pi-mattermost (after override), mm-latest-bot-post (after
#     install), homepage (after services.yaml edit).
#
# Prerequisites (script verifies):
#   * setup-mattermost.sh has finished (homepage tile exists, td-tokens.txt
#     has MATTERMOST_TOKEN, MATTERMOST_TEAM_ID, MATTERMOST_URL).
#   * setup-pi-mattermost-bridge.sh has finished (pi-mattermost.service is
#     running, .api_token exists at /root/.local/share/pi-mattermost/).
#
# Usage:
#   ./setup-homepage-pi-widgets.sh             # default: install both tiles
#   ./setup-homepage-pi-widgets.sh --no-bridge-tile
#   ./setup-homepage-pi-widgets.sh --no-latest-tile
#   ./setup-homepage-pi-widgets.sh --dry-run   # preview
#   ./setup-homepage-pi-widgets.sh --uninstall # remove tiles + services
#                                              # (leaves td-tokens.txt PI_BRIDGE_TOKEN
#                                              # entry for re-install)

set -Eeuo pipefail

# ----- args --------------------------------------------------------------
DRY_RUN=0
UNINSTALL=0
WITH_BRIDGE_TILE=1
WITH_LATEST_TILE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKENS_FILE="/root/td-tokens.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=1; shift ;;
    --uninstall)       UNINSTALL=1; shift ;;
    --no-bridge-tile)  WITH_BRIDGE_TILE=0; shift ;;
    --no-latest-tile)  WITH_LATEST_TILE=0; shift ;;
    -h|--help)         sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[hp-pi-widgets]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[hp-pi-widgets]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[hp-pi-widgets]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct >/dev/null || die "pct not found — PVE host required."

find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

read_token() {
  local key="$1"
  [[ -f "$TOKENS_FILE" ]] || return 1
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); print; exit }' "$TOKENS_FILE"
}

upsert_token() {
  # Idempotently set key=value in TOKENS_FILE
  local key="$1" val="$2"
  if [[ -f "$TOKENS_FILE" ]] && grep -q "^$key=" "$TOKENS_FILE"; then
    sed -i "s|^$key=.*|$key=$val|" "$TOKENS_FILE"
  else
    echo "$key=$val" >> "$TOKENS_FILE"
  fi
}

# ----- preflight ---------------------------------------------------------
PI_CTID="$(find_ct_by_hostname ollama-pi-agent 2>/dev/null || true)"
[[ -n "$PI_CTID" ]] || die "No CT with hostname 'ollama-pi-agent' found."

MM_CTID="$(find_ct_by_hostname mattermost 2>/dev/null || true)"
[[ -n "$MM_CTID" ]] || die "No CT with hostname 'mattermost' found."

HP_CTID="$(find_ct_by_hostname homepage 2>/dev/null || true)"
[[ -n "$HP_CTID" ]] || die "No CT with hostname 'homepage' found."

# Required tokens
MM_TOKEN="$(read_token MATTERMOST_TOKEN || true)"
MM_BOT_TOKEN="$(read_token MATTERMOST_BOT_TOKEN || true)"
MM_TEAM_ID="$(read_token MATTERMOST_TEAM_ID || true)"
MM_URL="$(read_token MATTERMOST_URL || true)"
[[ -z "$MM_URL" ]] && MM_URL="http://mattermost:8065"

if [[ -z "$MM_TOKEN" || -z "$MM_TEAM_ID" ]]; then
  die "Missing MATTERMOST_TOKEN or MATTERMOST_TEAM_ID in $TOKENS_FILE.
  Run ./addons/setup-mattermost.sh first."
fi

# Confirm bridge is installed
if ! pct exec "$PI_CTID" -- test -f /etc/systemd/system/pi-mattermost.service; then
  die "pi-mattermost.service not found in CT $PI_CTID — run ./addons/setup-pi-mattermost-bridge.sh first."
fi

log "Pre-flight OK."
log "  ollama-pi-agent : CT $PI_CTID"
log "  mattermost      : CT $MM_CTID"
log "  homepage        : CT $HP_CTID"

# ----- uninstall ---------------------------------------------------------
if (( UNINSTALL )); then
  log "Uninstalling Homepage pi widgets..."

  # Pi-bot bridge override
  run "pct exec $PI_CTID -- rm -f /etc/systemd/system/pi-mattermost.service.d/bind-all.conf"
  run "pct exec $PI_CTID -- bash -lc 'rmdir /etc/systemd/system/pi-mattermost.service.d 2>/dev/null || true'"
  run "pct exec $PI_CTID -- systemctl daemon-reload"
  run "pct exec $PI_CTID -- systemctl restart pi-mattermost"

  # mm-latest-bot-post helper
  run "pct exec $MM_CTID -- systemctl disable --now mm-latest-bot-post 2>/dev/null || true"
  run "pct exec $MM_CTID -- rm -f /etc/systemd/system/mm-latest-bot-post.service"
  run "pct exec $MM_CTID -- rm -rf /opt/mm-helpers"
  run "pct exec $MM_CTID -- systemctl daemon-reload"

  # Strip Homepage tiles
  services_file="$(pct exec "$HP_CTID" -- bash -lc '
    for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage /var/lib/homepage/config; do
      [[ -f "$d/services.yaml" ]] && { echo "$d/services.yaml"; exit 0; }
    done
  ' 2>/dev/null | tail -n1)"

  if [[ -n "$services_file" ]] && (( ! DRY_RUN )); then
    # Backup before touching — same precaution as install path.
    pct exec "$HP_CTID" -- cp "$services_file" "${services_file}.bak.$(date +%s)"
    # Single-pass strip — see write_combined_tile() for rationale.
    pct exec "$HP_CTID" -- bash -lc "awk '
      /^# TD-Addon:/ {
        if (\$0 ~ /pi-bridge|mm-latest-post|pi-widgets/) {
          in_block = 1
        } else {
          in_block = 0
          print
        }
        next
      }
      !in_block { print }
    ' '$services_file' > /tmp/services.yaml.new && mv /tmp/services.yaml.new '$services_file'"
    pct exec "$HP_CTID" -- bash -lc 'systemctl restart homepage 2>/dev/null || systemctl restart gethomepage 2>/dev/null || true'
  fi

  log "Uninstalled. PI_BRIDGE_TOKEN left in $TOKENS_FILE for fast re-install."
  exit 0
fi

# ----- 1. expose bridge on all interfaces (idempotent) -------------------
if (( WITH_BRIDGE_TILE )); then
  log "Overriding pi-mattermost.service to bind 0.0.0.0..."
  OVERRIDE_DIR=/etc/systemd/system/pi-mattermost.service.d
  OVERRIDE_FILE="$OVERRIDE_DIR/bind-all.conf"

  if (( ! DRY_RUN )); then
    pct exec "$PI_CTID" -- mkdir -p "$OVERRIDE_DIR"
    pct exec "$PI_CTID" -- bash -c "cat > $OVERRIDE_FILE <<'CONF'
[Service]
Environment=PI_MATTERMOST_BIND=0.0.0.0
CONF"
    pct exec "$PI_CTID" -- systemctl daemon-reload
    pct exec "$PI_CTID" -- systemctl restart pi-mattermost
    sleep 2
    if pct exec "$PI_CTID" -- bash -lc 'ss -tlnp | grep -q ":4000.*node"'; then
      log "  ✓ bridge listening on :4000"
    else
      warn "  ✗ bridge not listening after restart — inspect with:"
      warn "    pct exec $PI_CTID -- journalctl -u pi-mattermost -n 30"
    fi
  fi

  # Capture the API token + share with Homepage
  log "Reading bridge API token..."
  if (( ! DRY_RUN )); then
    BRIDGE_TOKEN="$(pct exec "$PI_CTID" -- cat /root/.local/share/pi-mattermost/.api_token 2>/dev/null || true)"
    if [[ -z "$BRIDGE_TOKEN" ]]; then
      warn "  Could not read .api_token — skipping bridge tile token write."
    else
      upsert_token "PI_BRIDGE_TOKEN" "$BRIDGE_TOKEN"
      log "  PI_BRIDGE_TOKEN written to $TOKENS_FILE"
    fi
  fi
fi

# ----- 2. install mm-latest-bot-post.service -----------------------------
BOT_CHANNEL_ID=""
if (( WITH_LATEST_TILE )); then
  log "Looking up #bot channel id via Mattermost API..."
  if (( ! DRY_RUN )); then
    BOT_CHANNEL_ID="$(curl -fsS \
      -H "Authorization: Bearer $MM_TOKEN" \
      "$MM_URL/api/v4/teams/$MM_TEAM_ID/channels/name/bot" 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' \
      2>/dev/null || true)"
    if [[ -z "$BOT_CHANNEL_ID" ]]; then
      warn "  Could not resolve #bot channel id — skipping latest-tile install."
      WITH_LATEST_TILE=0
    else
      log "  #bot channel id: $BOT_CHANNEL_ID"
    fi
  fi
fi

if (( WITH_LATEST_TILE )); then
  log "Installing mm-latest-bot-post.service into mattermost CT..."

  HELPER_SCRIPT=$(cat <<'PYEOF'
#!/usr/bin/env python3
"""
Tiny HTTP proxy that fetches Mattermost's most-recent post in a channel and
re-shapes the response into flat fields Homepage customapi can read.
"""
import json, os, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

MM_URL     = os.environ.get("MM_URL", "http://localhost:8065")
MM_TOKEN   = os.environ["MM_TOKEN"]
CHANNEL_ID = os.environ["BOT_CHANNEL_ID"]
PORT       = int(os.environ.get("PORT", "4501"))

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            req = urllib.request.Request(
                f"{MM_URL}/api/v4/channels/{CHANNEL_ID}/posts?per_page=1",
                headers={"Authorization": f"Bearer {MM_TOKEN}"},
            )
            with urllib.request.urlopen(req, timeout=5) as r:
                data = json.load(r)
            pid = data["order"][0] if data.get("order") else None
            post = data["posts"][pid] if pid else {}
            out = {
                "message": (post.get("message", "") or "")[:140] or "(empty)",
                "user_id": post.get("user_id", ""),
                "create_at_ms": post.get("create_at", 0),
            }
            body = json.dumps(out).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:
            err = json.dumps({"error": str(e)}).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(err)))
            self.end_headers()
            self.wfile.write(err)

    def log_message(self, *a):  # quiet logs
        pass

if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYEOF
)

  UNIT_BODY=$(cat <<UNIT
[Unit]
Description=Mattermost latest-bot-post reshaping proxy (Homepage customapi feed)
After=mattermost.service network-online.target
Wants=mattermost.service

[Service]
Type=simple
Environment=MM_URL=http://localhost:8065
Environment=MM_TOKEN=$MM_TOKEN
Environment=BOT_CHANNEL_ID=$BOT_CHANNEL_ID
Environment=PORT=4501
ExecStart=/usr/bin/python3 /opt/mm-helpers/latest-bot-post.py
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
)

  if (( ! DRY_RUN )); then
    pct exec "$MM_CTID" -- mkdir -p /opt/mm-helpers
    printf '%s\n' "$HELPER_SCRIPT" | pct exec "$MM_CTID" -- tee /opt/mm-helpers/latest-bot-post.py >/dev/null
    pct exec "$MM_CTID" -- chmod +x /opt/mm-helpers/latest-bot-post.py

    printf '%s\n' "$UNIT_BODY" | pct exec "$MM_CTID" -- tee /etc/systemd/system/mm-latest-bot-post.service >/dev/null

    pct exec "$MM_CTID" -- systemctl daemon-reload
    pct exec "$MM_CTID" -- systemctl enable mm-latest-bot-post.service 2>&1 | sed 's/^/    /' || true
    pct exec "$MM_CTID" -- systemctl restart mm-latest-bot-post.service
    sleep 2

    # Smoke test
    if pct exec "$MM_CTID" -- bash -lc 'curl -fsS http://localhost:4501/ >/dev/null'; then
      log "  ✓ mm-latest-bot-post listening on :4501"
      pct exec "$MM_CTID" -- bash -lc 'curl -sS http://localhost:4501/' | sed 's/^/    /'
    else
      warn "  ✗ mm-latest-bot-post not responding — inspect with:"
      warn "    pct exec $MM_CTID -- journalctl -u mm-latest-bot-post -n 20"
    fi
  fi
fi

# ----- 3. register Homepage tiles ----------------------------------------
log "Registering Homepage tiles..."

services_file="$(pct exec "$HP_CTID" -- bash -lc '
  for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage /var/lib/homepage/config; do
    [[ -f "$d/services.yaml" ]] && { echo "$d/services.yaml"; exit 0; }
  done
' 2>/dev/null | tail -n1)"

[[ -n "$services_file" ]] || die "Could not find services.yaml in homepage CT $HP_CTID."
log "  services.yaml: $services_file"

# Read PI_BRIDGE_TOKEN from td-tokens.txt (just wrote it above)
BRIDGE_TOKEN_FOR_TILE="$(read_token PI_BRIDGE_TOKEN || true)"

# Build a SINGLE combined "AI Agents" block containing both tiles. Emitting
# two separate `- AI Agents:` top-level sequence items breaks js-yaml
# (Homepage's parser) with 'bad indentation of a sequence entry' even though
# YAML allows duplicate keys in a sequence. Consolidating both tiles under
# one group avoids the ambiguity entirely AND looks better in the UI.
COMBINED_MARKER="# TD-Addon: pi-widgets"
COMBINED_TILE_BLOCK=""

# Render each tile's INNER body (without the group wrapper) only if enabled
# and prerequisites are met.
INCLUDED_TILES=""

if (( WITH_BRIDGE_TILE )) && [[ -n "$BRIDGE_TOKEN_FOR_TILE" ]]; then
  INCLUDED_TILES="$INCLUDED_TILES bridge"
  BRIDGE_TILE_INNER="    - Pi Bridge:
        href: http://ollama-pi-agent:9092
        description: pi ↔ Mattermost bridge daemon
        icon: ollama.png
        widget:
          type: customapi
          url: http://ollama-pi-agent:4000/api/channel-count
          method: GET
          headers:
            Authorization: Bearer $BRIDGE_TOKEN_FOR_TILE
          display: list
          mappings:
            - field: count
              label: Channels
            - field: dbCount
              label: Persisted
            - field: orphanCount
              label: Orphans"
fi

if (( WITH_LATEST_TILE )); then
  INCLUDED_TILES="$INCLUDED_TILES latest"
  # NOTE: service name MUST be quoted — '#' preceded by whitespace starts a
  # YAML comment, so an unquoted "Latest in #bot:" parses as
  # "Latest in" + comment "bot:" which leaves the sequence item malformed
  # and js-yaml reports "bad indentation of a sequence entry" at the
  # following line. (Caught by user 2026-06-23.)
  LATEST_TILE_INNER="    - \"Latest in #bot\":
        href: http://mattermost:8065/td-homelab/channels/bot
        description: Most recent Bot Posts message
        icon: mattermost.png
        widget:
          type: customapi
          url: http://mattermost:4501/
          method: GET
          display: list
          mappings:
            - field: message
              label: Last message
            - field: create_at_ms
              label: When
              format: relativeDate"
fi

if [[ -n "$INCLUDED_TILES" ]]; then
  COMBINED_TILE_BLOCK="- AI Agents:"
  [[ -n "${BRIDGE_TILE_INNER:-}" ]] && COMBINED_TILE_BLOCK="$COMBINED_TILE_BLOCK
$BRIDGE_TILE_INNER"
  [[ -n "${LATEST_TILE_INNER:-}" ]] && COMBINED_TILE_BLOCK="$COMBINED_TILE_BLOCK
$LATEST_TILE_INNER"
fi

# Helper: replace existing TD-Addon blocks, or append if absent.
# Strips ALL legacy markers (pi-bridge, mm-latest-post) AND the current
# combined marker (pi-widgets), then re-appends the combined block.
write_combined_tile() {
  local marker="$1" block="$2"
  [[ -z "$block" ]] && {
    log "  No tiles enabled — skipping write."
    return 0
  }

  (( DRY_RUN )) && {
    log "  [dry-run] would write $marker"
    printf '%s\n%s\n' "$marker" "$block" | sed 's/^/    /'
    return 0
  }

  # Always make a timestamped backup BEFORE touching the file. Lets you
  # 'cp services.yaml.bak.<ts> services.yaml' if anything goes sideways.
  pct exec "$HP_CTID" -- cp "$services_file" "${services_file}.bak.$(date +%s)"

  # Single-pass strip of ALL our markers at once. Every '# TD-Addon:' line
  # resets in_block based on whether it matches one of our markers — so we
  # can never accidentally strip past the end of our own block. Other
  # TD-Addon markers (like 'mattermost') terminate our block AND get
  # printed, which is what we want.
  #
  # The previous per-marker loop had a fatal compounding bug: if any
  # iteration's awk failed mid-way or the file lost a terminating marker,
  # subsequent iterations could strip past content they shouldn't have
  # touched. (Cost a user their entire services.yaml on 2026-06-23 — only
  # the pi-widgets block survived.) Hence the always-on backup above.
  log "  Removing any existing pi-widgets / pi-bridge / mm-latest-post blocks..."
  pct exec "$HP_CTID" -- bash -lc "awk '
    /^# TD-Addon:/ {
      if (\$0 ~ /pi-bridge|mm-latest-post|pi-widgets/) {
        in_block = 1
      } else {
        in_block = 0
        print
      }
      next
    }
    !in_block { print }
  ' '$services_file' > /tmp/services.yaml.new && mv /tmp/services.yaml.new '$services_file'"

  log "  Appending $marker block..."
  printf '\n%s\n%s\n' "$marker" "$block" | pct exec "$HP_CTID" -- tee -a "$services_file" >/dev/null
}

write_combined_tile "$COMBINED_MARKER" "$COMBINED_TILE_BLOCK"

# Reload Homepage to pick up new tiles
if (( ! DRY_RUN )); then
  log "Reloading Homepage..."
  pct exec "$HP_CTID" -- bash -lc '
    systemctl restart homepage 2>/dev/null \
      || systemctl restart gethomepage 2>/dev/null \
      || (cd /opt/homepage && npm run start >/dev/null 2>&1 & disown) \
      || echo "  (no homepage service unit found — restart manually if tiles don'\''t appear)"
  '
fi

# ----- done --------------------------------------------------------------
log "================================================================"
log "==> Done."
log " "
if (( WITH_BRIDGE_TILE )); then
  log "  ✓ Pi Bridge tile registered"
  log "    Polls http://ollama-pi-agent:4000/api/channel-count"
  log "    Shows: live channels / persisted DB rows / orphaned mappings"
fi
if (( WITH_LATEST_TILE )); then
  log "  ✓ Latest-in-bot tile registered"
  log "    Polls http://mattermost:4501/"
  log "    Shows: most recent message text + relative timestamp"
fi
log " "
log "Open Homepage in your browser — both tiles should populate within"
log "Homepage's poll interval (~5s default)."
log " "
log "Service management:"
log "  bridge override:  pct exec $PI_CTID -- systemctl cat pi-mattermost"
log "  latest-bot-post:  pct exec $MM_CTID -- systemctl status mm-latest-bot-post"
log "  homepage reload:  pct exec $HP_CTID -- systemctl restart homepage"
log "  uninstall:        $(basename "$0") --uninstall"
log "================================================================"
