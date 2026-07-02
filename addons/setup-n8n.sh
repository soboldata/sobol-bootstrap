#!/usr/bin/env bash
# setup-n8n.sh — Stand up n8n on its own CT and auto-wire credentials for
# every TD-Proxmox service so the founder can start building workflows
# without copy-pasting tokens out of /root/td-tokens.txt.
#
# What it does (idempotent at each step):
#   1. Reads tokens from /root/td-tokens.txt
#   2. Creates an n8n CT via community-scripts helper (skips if exists)
#   3. Joins it to Tailscale + pushes SSH keys + PATH helper
#   4. Waits for n8n on port 5678
#   5. Does first-run owner signup via POST /rest/owner/setup using
#      ADMIN_USER/EMAIL/PASSWORD already in tokens file (same admin as
#      everything else in the stack — same password tier they're used to)
#   6. Mints an n8n API key and saves it back as N8N_API_KEY in tokens
#   7. Creates pre-configured credentials in n8n:
#        - Ollama (shared)         → http://ollama-pi-agent:11434
#        - Mattermost (pi-bot)     → MATTERMOST_BOT_TOKEN
#        - Gitea (admin)           → GITEA_TOKEN
#        - OpenWebUI (OpenAI-compat) → OPENWEBUI_TOKEN (if set)
#   8. Imports 3 starter workflows from addons/n8n/workflows/:
#        - hello-mattermost.json — webhook → post in #general
#        - mm-ollama-chat.json  — listen on a channel → Ollama → reply
#        - gitea-daily-digest.json — cron → recent commits → MM post
#      (Each workflow is INACTIVE on import; user activates after review.)
#   9. Registers a Homepage tile
#
# Usage:
#   ./setup-n8n.sh                      # default install
#   ./setup-n8n.sh --dry-run            # preview
#   ./setup-n8n.sh --uninstall          # stop + destroy CT
#   ./setup-n8n.sh --skip-workflows     # don't import the 3 examples
#   ./setup-n8n.sh --skip-credentials   # just install CT, no wiring
#   ./setup-n8n.sh --skip-homepage-tile
#
# Prereqs:
#   - TD-Proxmox foundation built (bootstrap-pve.sh + configure-apps.sh
#     finished). /root/td-tokens.txt must have ADMIN_USER/EMAIL/PASSWORD.
#   - For credentials to actually wire: mattermost + gitea (at minimum)
#     must already be configured. Missing tokens = warning, not failure.

set -Eeuo pipefail

# ----- args --------------------------------------------------------------
DRY_RUN=0
UNINSTALL=0
SKIP_WORKFLOWS=0
SKIP_CREDENTIALS=0
SKIP_HOMEPAGE_TILE=0
CREDENTIALS_ONLY=0
VERBOSE=0
N8N_HOSTNAME="n8n"
TOKENS_FILE="/root/td-tokens.txt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="$SCRIPT_DIR/n8n/workflows"
HELPER_URL="https://github.com/community-scripts/ProxmoxVE/raw/main/ct/n8n.sh"

# Pre-declare these so set -u doesn't trip when login fails before they're set
N8N_API_KEY=""
CTID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)            DRY_RUN=1; shift ;;
    --uninstall)          UNINSTALL=1; shift ;;
    --skip-workflows)     SKIP_WORKFLOWS=1; shift ;;
    --skip-credentials)   SKIP_CREDENTIALS=1; shift ;;
    --skip-homepage-tile) SKIP_HOMEPAGE_TILE=1; shift ;;
    --credentials-only)   CREDENTIALS_ONLY=1; shift ;;
    --verbose|-v)         VERBOSE=1; shift ;;
    --hostname)           N8N_HOSTNAME="$2"; shift 2 ;;
    -h|--help)            sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-n8n]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-n8n]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-n8n]\033[0m %s\n" "$*" >&2; exit 1; }
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
  # Returns the LAST occurrence of key= in the tokens file (so a later
  # 'echo K=v >>' overrides any earlier line). Also strips obvious
  # placeholder values like "<paste here>" or "REPLACE_ME".
  local key="$1" val
  [[ -f "$TOKENS_FILE" ]] || return 1
  val="$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); v = $0 } END { print v }' "$TOKENS_FILE")"
  # Strip surrounding whitespace
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  # Drop placeholder values
  case "$val" in
    "<"*">"|""|"REPLACE_ME"|"CHANGEME"|"changeme") return 1 ;;
  esac
  printf '%s\n' "$val"
}

upsert_token() {
  local key="$1" val="$2"
  touch "$TOKENS_FILE"
  chmod 600 "$TOKENS_FILE"
  if grep -q "^$key=" "$TOKENS_FILE"; then
    sed -i "s|^$key=.*|$key=$val|" "$TOKENS_FILE"
  else
    echo "$key=$val" >> "$TOKENS_FILE"
  fi
}

add_tun_to_ct() {
  local ctid="$1"
  local conf="/etc/pve/lxc/${ctid}.conf"
  grep -q "tun rwm" "$conf" 2>/dev/null && return 0
  cat >> "$conf" <<EOF
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
}

# ----- pre-flight --------------------------------------------------------
log "Pre-flight..."

ADMIN_USER="$(read_token ADMIN_USER || true)"
ADMIN_EMAIL="$(read_token ADMIN_EMAIL || true)"
ADMIN_PASSWORD="$(read_token ADMIN_PASSWORD || true)"

# n8n has its own owner-account requirements that differ from the rest of the
# stack:
#   - email must be REAL and reachable — n8n 2.x sends an activation code
#     to verify it (use a tutanota / mailbox.org / gmail address, not
#     admin@localhost)
#   - password must contain at least 1 number (8+ chars, mixed)
# If your stack-wide ADMIN_PASSWORD doesn't satisfy those (e.g. all letters,
# or the email isn't real), set these overrides in /root/td-tokens.txt and
# this script will use them for owner setup / login instead:
#   N8N_OWNER_EMAIL=...
#   N8N_OWNER_PASSWORD=...
N8N_OWNER_EMAIL="$(read_token N8N_OWNER_EMAIL || true)"
N8N_OWNER_PASSWORD="$(read_token N8N_OWNER_PASSWORD || true)"
[[ -z "$N8N_OWNER_EMAIL"    ]] && N8N_OWNER_EMAIL="$ADMIN_EMAIL"
[[ -z "$N8N_OWNER_PASSWORD" ]] && N8N_OWNER_PASSWORD="$ADMIN_PASSWORD"

if [[ -z "$ADMIN_USER" || -z "$N8N_OWNER_EMAIL" || -z "$N8N_OWNER_PASSWORD" ]]; then
  die "Need ADMIN_USER + (N8N_OWNER_EMAIL or ADMIN_EMAIL) + (N8N_OWNER_PASSWORD or ADMIN_PASSWORD) in $TOKENS_FILE.
  Re-run automation/configure-apps.sh first so the ADMIN_* land there."
fi

# Sanity-check the password n8n will receive: at least 1 digit, length >= 8
if ! [[ "$N8N_OWNER_PASSWORD" =~ [0-9] ]]; then
  warn "  n8n requires at least 1 number in the password — yours has none."
  warn "  Owner setup may fail. Set N8N_OWNER_PASSWORD in $TOKENS_FILE to override."
fi
if (( ${#N8N_OWNER_PASSWORD} < 8 )); then
  warn "  n8n requires password length >= 8 — yours is ${#N8N_OWNER_PASSWORD}."
fi

TS_AUTHKEY="$(read_token TS_AUTHKEY || true)"
CT_PASSWORD="$(read_token CT_PASSWORD || true)"

# Tokens needed for wiring (warn if missing — we proceed without those creds)
MM_BOT_TOKEN="$(read_token MATTERMOST_BOT_TOKEN || true)"
MM_TOWNSQUARE_CHANNEL_ID="$(read_token MATTERMOST_TOWNSQUARE_CHANNEL_ID || true)"
MM_AICHAT_CHANNEL_ID="$(read_token MATTERMOST_AICHAT_CHANNEL_ID || true)"
MM_BOT_CHANNEL_ID="$(read_token MATTERMOST_BOT_CHANNEL_ID || true)"
MM_TEAM_ID="$(read_token MATTERMOST_TEAM_ID || true)"
MM_URL="$(read_token MATTERMOST_URL || true)"
[[ -z "$MM_URL" ]] && MM_URL="http://mattermost:8065"
GITEA_TOKEN="$(read_token GITEA_TOKEN || true)"
OPENWEBUI_TOKEN="$(read_token OPENWEBUI_TOKEN || true)"

# Check service CTs that we'll wire to (warnings only)
OLLAMA_CTID="$(find_ct_by_hostname ollama-pi-agent 2>/dev/null || true)"
MM_CTID="$(find_ct_by_hostname mattermost 2>/dev/null || true)"
GITEA_CTID="$(find_ct_by_hostname gitea 2>/dev/null || true)"
OW_CTID="$(find_ct_by_hostname openwebui 2>/dev/null || true)"

[[ -z "$OLLAMA_CTID" ]] && warn "  ollama-pi-agent CT not found — Ollama credential will still be created (URL only) but may not resolve."
[[ -z "$MM_CTID" || -z "$MM_BOT_TOKEN" ]] && warn "  Mattermost CT/token missing — MM credential will be skipped."
[[ -z "$GITEA_CTID" || -z "$GITEA_TOKEN" ]] && warn "  Gitea CT/token missing — Gitea credential will be skipped."
[[ -z "$OW_CTID" ]] && warn "  openwebui CT not found — OpenWebUI credential will be skipped."

# Fallback: if the channel IDs aren't in tokens (older setup-mattermost.sh
# install), look them up live via the Mattermost API. We need real UUIDs to
# patch into the starter workflow JSONs — slugs like "town-square" don't
# resolve in n8n 2.x's Mattermost node.
MM_TEAM_ID="$(read_token MATTERMOST_TEAM_ID || true)"
if [[ -n "$MM_CTID" && -n "$MM_BOT_TOKEN" && -n "$MM_TEAM_ID" ]]; then
  # Helper to extract a real channel UUID from a /api/v4/...channels/name/<n>
  # response. MM's error responses ALSO have an "id" field (containing the
  # error code string), so we need to also check that status_code is absent
  # or 200. A real MM channel id is a 26-char alphanumeric string.
  _mm_pick_channel_id() {
    pct exec "$MM_CTID" -- bash -lc "
      curl -sS -H 'Authorization: Bearer $MM_BOT_TOKEN' '$1' \
      | python3 -c 'import sys,json
try:
  d = json.load(sys.stdin)
  sc = d.get(\"status_code\", 200)
  cid = d.get(\"id\", \"\")
  # Real MM ids are 26 chars [a-z0-9]; error ids contain dots
  if sc == 200 and len(cid) == 26 and \".\" not in cid:
    print(cid)
except: pass'
    " 2>/dev/null || true
  }

  if [[ -z "$MM_TOWNSQUARE_CHANNEL_ID" ]]; then
    log "  Resolving #town-square channel ID via MM API..."
    MM_TOWNSQUARE_CHANNEL_ID="$(_mm_pick_channel_id "http://localhost:8065/api/v4/teams/$MM_TEAM_ID/channels/name/town-square")"
    [[ -n "$MM_TOWNSQUARE_CHANNEL_ID" ]] && log "    town-square = $MM_TOWNSQUARE_CHANNEL_ID"
  fi
  if [[ -z "$MM_AICHAT_CHANNEL_ID" ]]; then
    log "  Resolving #ai-chat channel ID via MM API..."
    MM_AICHAT_CHANNEL_ID="$(_mm_pick_channel_id "http://localhost:8065/api/v4/teams/$MM_TEAM_ID/channels/name/ai-chat")"
    if [[ -n "$MM_AICHAT_CHANNEL_ID" ]]; then
      log "    ai-chat = $MM_AICHAT_CHANNEL_ID"
    else
      log "    ai-chat not found — workflows will use town-square instead"
      MM_AICHAT_CHANNEL_ID="$MM_TOWNSQUARE_CHANNEL_ID"
    fi
  fi
  if [[ -z "$MM_BOT_CHANNEL_ID" ]]; then
    log "  Resolving #bot channel ID via MM API..."
    MM_BOT_CHANNEL_ID="$(_mm_pick_channel_id "http://localhost:8065/api/v4/teams/$MM_TEAM_ID/channels/name/bot")"
    if [[ -n "$MM_BOT_CHANNEL_ID" ]]; then
      log "    bot = $MM_BOT_CHANNEL_ID"
    else
      log "    bot not found — workflows targeting #bot will fall back to town-square"
      MM_BOT_CHANNEL_ID="$MM_TOWNSQUARE_CHANNEL_ID"
    fi
  fi
fi

# ----- uninstall path ----------------------------------------------------
if (( UNINSTALL )); then
  CTID="$(find_ct_by_hostname "$N8N_HOSTNAME" 2>/dev/null || true)"
  if [[ -z "$CTID" ]]; then
    log "No $N8N_HOSTNAME CT found — nothing to uninstall."
    exit 0
  fi
  log "Uninstalling n8n CT $CTID..."
  run "pct stop $CTID 2>/dev/null || true"
  run "pct destroy $CTID --purge"
  run "sed -i '/^N8N_API_KEY=/d' '$TOKENS_FILE'"
  # Strip Homepage tile (markered block)
  HP_CTID="$(find_ct_by_hostname homepage 2>/dev/null || true)"
  if [[ -n "$HP_CTID" ]] && (( ! DRY_RUN )); then
    pct exec "$HP_CTID" -- bash -lc '
      for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage; do
        [[ -f "$d/services.yaml" ]] || continue
        SVC="$d/services.yaml"
        cp "$SVC" "${SVC}.bak.$(date +%s)"
        awk "
          /^# TD-Addon: n8n/ { in_block=1; next }
          in_block && /^# TD-Addon:/ { in_block=0; print; next }
          !in_block { print }
        " "$SVC" > /tmp/services.yaml.new && mv /tmp/services.yaml.new "$SVC"
      done
      systemctl restart homepage 2>/dev/null || true
    '
  fi
  log "Uninstalled."
  exit 0
fi

# ----- 1. Create n8n CT --------------------------------------------------
CTID="$(find_ct_by_hostname "$N8N_HOSTNAME" 2>/dev/null || true)"
if (( CREDENTIALS_ONLY )); then
  [[ -n "$CTID" ]] || die "--credentials-only requires existing $N8N_HOSTNAME CT."
  log "Credentials-only mode — using existing CT $CTID, skipping create + Tailscale."
elif [[ -n "$CTID" ]]; then
  log "n8n CT already exists (CT $CTID) — skipping creation."
else
  log "Creating n8n CT via community-scripts helper..."
  if (( DRY_RUN )); then
    printf "[dry-run] bash <(curl -fsSL %s)\n" "$HELPER_URL"
  else
    # The helper is interactive (whiptail). User clicks "Default Install".
    CT_PASSWORD="$CT_PASSWORD" var_hostname="$N8N_HOSTNAME" \
      bash <(curl -fsSL "$HELPER_URL") || die "n8n helper failed."
  fi

  CTID="$(find_ct_by_hostname "$N8N_HOSTNAME" 2>/dev/null || true)"
  [[ -n "$CTID" ]] || die "n8n CT didn't show up after helper ran."

  # /dev/net/tun for Tailscale + restart
  pct stop "$CTID"
  add_tun_to_ct "$CTID"
  pct start "$CTID"
  sleep 5

  # Push PVE host's authorized_keys
  pct exec "$CTID" -- mkdir -p /root/.ssh
  pct push "$CTID" /root/.ssh/authorized_keys /root/.ssh/authorized_keys --perms 0600

  # Join Tailscale (idempotent --reset).
  # Note: previous version swallowed install errors with >/dev/null 2>&1
  # and ended up with CTs that never joined the tailnet but reported
  # "success" — caught 2026-06-28 when n8n CT had no tailscale binary
  # at all. Now we surface install errors and verify the binary exists
  # before attempting 'up'.
  if [[ -n "$TS_AUTHKEY" ]]; then
    log "Installing Tailscale + joining tailnet..."
    pct exec "$CTID" -- bash -lc "
      set -e
      if ! command -v tailscale >/dev/null 2>&1; then
        echo '  installing tailscale...'
        curl -fsSL https://tailscale.com/install.sh | sh 2>&1 | tail -5
      fi
      command -v tailscale >/dev/null 2>&1 || { echo '  TAILSCALE INSTALL FAILED — n8n will be LAN-only'; exit 1; }
      echo '  tailscale up --hostname=$N8N_HOSTNAME...'
      tailscale up --authkey='$TS_AUTHKEY' --hostname='$N8N_HOSTNAME' --reset --accept-routes 2>&1 | tail -3
      echo '  tailscale ip:' \$(tailscale ip -4 2>/dev/null || echo none)
    " || warn "  Tailscale step failed — n8n will only be reachable via LAN IP $(pct exec "$CTID" -- hostname -I | awk '{print $1}'). Outgoing calls will need /etc/hosts entries or LAN DNS to reach 'mattermost' / 'gitea' / etc."
  fi
fi

# ----- 1b. Harden the systemd unit ---------------------------------------
# Two changes that make n8n survive longer overnight:
#   - NODE_OPTIONS=--max-old-space-size=2048
#     Node's default V8 heap limit is ~1.4GB on 64-bit. Under sustained
#     load (e.g. Gitea webhook retries, MM credential 403 retries, big
#     execution backlog) n8n OOMs and SIGABRTs itself with
#     "FATAL ERROR: Ineffective mark-compacts near heap limit".
#     Caught by user 2026-06-28 after the install died overnight at
#     ~3h uptime, peak 1.3G memory. Bumping to 2GB gives V8 headroom
#     and the CT (default 2GB RAM) can support it; bump CT RAM to 4GB
#     if you want even more buffer.
#   - Restart=on-failure + RestartSec=10
#     If V8 OOMs again (or n8n panics for any reason) systemd brings
#     it back up in 10 seconds instead of leaving it dead until you
#     check on it the next morning.
log "Hardening n8n systemd unit (NODE_OPTIONS + Restart=on-failure)..."
if (( ! DRY_RUN )); then
  pct exec "$CTID" -- bash -lc '
    SVC=/etc/systemd/system/n8n.service
    [[ -f "$SVC" ]] || SVC=/lib/systemd/system/n8n.service
    [[ -f "$SVC" ]] || { echo "  n8n service unit not found — skipping hardening"; exit 0; }

    # Backup once per change so re-runs are reversible
    if ! grep -q "Environment=NODE_OPTIONS" "$SVC" || ! grep -q "^Restart=" "$SVC"; then
      cp "$SVC" "${SVC}.bak.$(date +%s)"
    fi

    if ! grep -q "Environment=NODE_OPTIONS" "$SVC"; then
      sed -i "/^\[Service\]/a Environment=NODE_OPTIONS=--max-old-space-size=2048" "$SVC"
      echo "  ✓ Added NODE_OPTIONS=--max-old-space-size=2048"
    else
      echo "  - NODE_OPTIONS already set, skipping"
    fi

    if ! grep -q "^Restart=" "$SVC"; then
      sed -i "/^\[Service\]/a Restart=on-failure\nRestartSec=10" "$SVC"
      echo "  ✓ Added Restart=on-failure (10s)"
    else
      echo "  - Restart= already set, skipping"
    fi
  '
  pct exec "$CTID" -- systemctl daemon-reload
  pct exec "$CTID" -- systemctl restart n8n 2>/dev/null || true
fi

# ----- 2. Wait for n8n on port 5678 --------------------------------------
log "Waiting for n8n on :5678..."
if (( ! DRY_RUN )); then
  for i in {1..60}; do
    if pct exec "$CTID" -- bash -lc 'curl -fsS --max-time 3 http://localhost:5678/healthz >/dev/null 2>&1' 2>/dev/null; then
      log "  ✓ n8n is up"
      break
    fi
    sleep 3
  done
  pct exec "$CTID" -- bash -lc 'curl -fsS --max-time 3 http://localhost:5678/healthz >/dev/null 2>&1' \
    || die "n8n didn't come up. Check: pct exec $CTID -- journalctl -u n8n -n 50"
fi

# ----- helpers for posting JSON SAFELY -----------------------------------
# Pattern: write payload to a temp file on the CT, then `curl -d @file`.
# This avoids quoting collisions when JSON contains " characters and we'd
# otherwise be embedding it through `pct exec ... bash -lc "curl -d '...'"`.
#
# Use: post_json_file <local_payload_file> <method> <url> [extra_curl_args...]
# Returns body on stdout, HTTP status on stderr. Always reads the body so
# callers can grep it; we don't swallow errors.
load_token_from_file_on_ct() {
  local ctid="$1" local_file="$2" remote_file="$3"
  pct push "$ctid" "$local_file" "$remote_file" --perms 0600
}

# Hit n8n's REST or API endpoint. Args:
#   $1 = http method
#   $2 = path (starting with '/' — caller picks /rest/... or /api/v1/...)
#   $3 = body (optional, JSON string)
# Extra args after $3 are appended to curl. Always prints body. Always
# prints "HTTP <code>" to stderr.
n8n_curl() {
  local method="$1" path="$2" body="${3:-}"
  shift 3 || true
  local remote_body="/tmp/n8n-body.$$.json"
  # Write the body locally then push (or empty out the remote file)
  if [[ -n "$body" ]]; then
    local tmp; tmp="$(mktemp)"
    printf '%s' "$body" > "$tmp"
    pct push "$CTID" "$tmp" "$remote_body" --perms 0600 >/dev/null
    rm -f "$tmp"
  else
    pct exec "$CTID" -- bash -lc "rm -f $remote_body; touch $remote_body"
  fi

  local auth_header=""
  if [[ "$path" == /api/v1/* && -n "${N8N_API_KEY:-}" ]]; then
    auth_header="-H 'X-N8N-API-KEY: ${N8N_API_KEY}'"
  fi
  local data_arg=""
  [[ -n "$body" ]] && data_arg="--data-binary @${remote_body}"

  # Run curl on the CT. Print body to stdout, status to stderr.
  # Note: the auth_header / data_arg are intentionally unquoted inside the
  # double-quoted heredoc so the shell on the CT expands them as separate
  # tokens. The header value itself is wrapped in single quotes so the API
  # key is safe.
  pct exec "$CTID" -- bash -lc "
    code=\$(curl -sS -o /tmp/n8n-resp.body -w '%{http_code}' \
      -b /tmp/n8n-cookies.txt -c /tmp/n8n-cookies.txt \
      -X $method 'http://localhost:5678${path}' \
      -H 'Content-Type: application/json' \
      ${auth_header} \
      ${data_arg})
    cat /tmp/n8n-resp.body
    echo HTTP \$code >&2
    rm -f /tmp/n8n-resp.body
  "
}

# ----- 3. Owner setup via REST -------------------------------------------
log "Setting up n8n owner account..."

if (( ! DRY_RUN )); then
  # POST /rest/owner/setup — accepts {email, firstName, lastName, password}
  # If already done, returns 400; we treat that as "already done" and move on.
  # Env vars MUST be prefixed before python3 — they're env to the command,
  # not argv. (Bash's KEY=VAL prefix only applies as env when at the start.)
  OWNER_BODY="$(N8N_OWNER_EMAIL="$N8N_OWNER_EMAIL" ADMIN_USER="$ADMIN_USER" N8N_OWNER_PASSWORD="$N8N_OWNER_PASSWORD" python3 -c '
import json, os
print(json.dumps({
  "email":     os.environ["N8N_OWNER_EMAIL"],
  "firstName": os.environ["ADMIN_USER"],
  "lastName":  "Admin",
  "password":  os.environ["N8N_OWNER_PASSWORD"],
}))')"

  OWNER_RESP="$(n8n_curl POST /rest/owner/setup "$OWNER_BODY" 2> /tmp/n8n-owner.code)"
  OWNER_CODE="$(awk '{print $2}' /tmp/n8n-owner.code 2>/dev/null)"

  case "$OWNER_CODE" in
    200|201)
      log "  ✓ Owner account created (HTTP $OWNER_CODE)"
      ;;
    400|409)
      log "  Owner already exists (HTTP $OWNER_CODE) — logging in"
      LOGIN_BODY="$(N8N_OWNER_EMAIL="$N8N_OWNER_EMAIL" N8N_OWNER_PASSWORD="$N8N_OWNER_PASSWORD" python3 -c '
import json, os
print(json.dumps({
  "emailOrLdapLoginId": os.environ["N8N_OWNER_EMAIL"],
  "email":              os.environ["N8N_OWNER_EMAIL"],
  "password":           os.environ["N8N_OWNER_PASSWORD"],
}))')"
      # n8n 1.x uses /rest/login; n8n 2.x may use /rest/auth/login. Try both.
      LOGGED_IN=0
      for ep in /rest/login /rest/auth/login; do
        LOGIN_RESP="$(n8n_curl POST "$ep" "$LOGIN_BODY" 2> /tmp/n8n-login.code)"
        LOGIN_CODE="$(awk '{print $2}' /tmp/n8n-login.code 2>/dev/null)"
        log "  Trying $ep — HTTP $LOGIN_CODE"
        if [[ "$LOGIN_CODE" =~ ^2 ]]; then
          log "  ✓ Logged in via $ep"
          LOGGED_IN=1
          break
        fi
      done
      if (( ! LOGGED_IN )); then
        warn "  Login failed on all known endpoints. Last response:"
        echo "$LOGIN_RESP" | head -3 | sed 's/^/    /' >&2
      fi
      ;;
    *)
      warn "  Owner setup HTTP $OWNER_CODE — body:"
      echo "$OWNER_RESP" | head -3 | sed 's/^/    /' >&2
      warn "  Continuing anyway — manual sign-in may be required."
      ;;
  esac

  # Mint an API key. n8n versions differ on the endpoint and response shape:
  #   1.0–1.48: POST /rest/me/api-keys                  → {data:{apiKey:"..."}}
  #   1.49+:    POST /rest/api-keys                     → {data:{rawApiKey:"...", apiKey:"..."}}
  # We try both. We also re-use an existing key if one is already in tokens
  # (n8n versions before 1.49 only allow one personal API key).
  EXISTING_KEY="$(read_token N8N_API_KEY || true)"
  if [[ -n "$EXISTING_KEY" ]]; then
    log "  N8N_API_KEY already in $TOKENS_FILE — re-using it"
    N8N_API_KEY="$EXISTING_KEY"
    # Validate it before continuing
    HEAD_CODE="$(pct exec "$CTID" -- bash -lc "curl -sS -o /dev/null -w '%{http_code}' -H 'X-N8N-API-KEY: $N8N_API_KEY' http://localhost:5678/api/v1/credentials")"
    if [[ ! "$HEAD_CODE" =~ ^2 ]]; then
      warn "  Existing key is invalid (HTTP $HEAD_CODE). Re-minting."
      N8N_API_KEY=""
    fi
  fi

  if [[ -z "$N8N_API_KEY" ]]; then
    # Body shapes across n8n versions:
    #   1.0-1.48:  {"label":"..."}                          (simple)
    #   1.49-1.59: {"label":"...", "expiresAt": null}       (expiresAt required)
    #   1.60+:     {"label":"...", "expiresAt": null,
    #              "scopes": ["*:*", ...]}                   (scopes may be req)
    # We try progressively richer bodies. Any 2xx wins.
    KEY_BODIES=(
      '{"label":"td-proxmox automation"}'
      '{"label":"td-proxmox automation","expiresAt":null}'
      '{"label":"td-proxmox automation","expiresAt":null,"scopes":["*"]}'
    )
    KEY_FAILURES=""
    for endpoint in /rest/api-keys /rest/me/api-keys; do
      for KEY_BODY in "${KEY_BODIES[@]}"; do
        KEY_RESP="$(n8n_curl POST "$endpoint" "$KEY_BODY" 2> /tmp/n8n-key.code)"
        KEY_CODE="$(awk '{print $2}' /tmp/n8n-key.code 2>/dev/null)"
        # Show the shape being tried so operators can see the progression
        SHAPE="$(echo "$KEY_BODY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("+".join(sorted(d.keys())))')"
        log "  Trying $endpoint [$SHAPE] — HTTP $KEY_CODE"
        if [[ "$KEY_CODE" =~ ^2 ]]; then
          N8N_API_KEY="$(echo "$KEY_RESP" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    data = d.get("data", d) if isinstance(d, dict) else d
    print(data.get("rawApiKey") or data.get("apiKey") or "")
except Exception:
    pass' 2>/dev/null)"
          if [[ -n "$N8N_API_KEY" ]]; then
            upsert_token N8N_API_KEY "$N8N_API_KEY"
            log "  ✓ N8N_API_KEY minted via $endpoint (shape=$SHAPE) and saved to $TOKENS_FILE"
            break 2
          else
            warn "  $endpoint returned 2xx but no key in response body:"
            echo "$KEY_RESP" | head -3 | sed 's/^/    /' >&2
          fi
        elif [[ "$KEY_CODE" == "400" ]]; then
          # 400 body carries the validation error — capture the first one we
          # see for the diagnostic block below. Newer n8n typically says
          # "expiresAt is required" or "scopes must be an array".
          if [[ -z "$KEY_FAILURES" ]]; then
            KEY_FAILURES="$endpoint [$SHAPE] → 400: $(echo "$KEY_RESP" | head -c 300)"
          fi
        fi
      done
    done
  fi

  if [[ -z "$N8N_API_KEY" ]]; then
    log "================================================================"
    warn "  No API key available — auto-mint failed and none in tokens file."
    warn ""
    if [[ -n "$KEY_FAILURES" ]]; then
      warn "  First 400 body captured (helps identify the schema n8n now wants):"
      printf '    %s\n' "$KEY_FAILURES" >&2
      warn ""
    fi
    warn "  This usually means login failed (HTTP 401), which means either:"
    warn "    1. The password in $TOKENS_FILE doesn't match what the owner"
    warn "       account in n8n was actually created with, OR"
    warn "    2. n8n 2.x's login API expects a shape we're not sending."
    warn ""
    warn "  Manual recovery (60 seconds):"
    warn "    1. Open http://$N8N_HOSTNAME:5678"
    warn "    2. Log in. If you can't log in: pct exec $CTID -- n8n"
    warn "       user-management:reset  (deletes owner, lets you re-signup)"
    warn "    3. Settings → n8n API → 'Create an API key' → copy value"
    warn "    4. echo 'N8N_API_KEY=<paste>' >> $TOKENS_FILE"
    warn "    5. ./addons/setup-n8n.sh --credentials-only"
    warn ""
    warn "  The next run will validate the key and proceed straight to"
    warn "  credentials + workflows, no login needed."
    log "================================================================"
    exit 1
  fi
fi

# Helper for hitting n8n's API after this point (preserves /api/v1 vs /rest)
n8n_api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "${N8N_API_KEY:-}" ]]; then
    n8n_curl "$method" "/api/v1$path" "$body"
  else
    n8n_curl "$method" "/rest$path" "$body"
  fi
}

# ----- 4. Create credentials ---------------------------------------------
if (( SKIP_CREDENTIALS )); then
  log "Skipping credential wiring (--skip-credentials)"
else
  log "Wiring credentials..."

  # Helper: only create if a credential with this name doesn't already exist
  cred_exists() {
    local name="$1"
    local resp
    resp="$(n8n_api GET "/credentials" "" 2>/dev/null)"
    NAME="$name" python3 -c '
import sys, json, os
want = os.environ.get("NAME", "")
try:
    d = json.loads(sys.stdin.read() or "{}")
    items = d.get("data", d) if isinstance(d, dict) else d
    if isinstance(items, list):
        for c in items:
            if isinstance(c, dict) and c.get("name") == want:
                print("exists"); sys.exit(0)
except Exception:
    pass
' <<< "$resp" | grep -q exists
  }

  create_credential() {
    local name="$1" type="$2" data_json="$3"
    if (( DRY_RUN )); then
      printf "[dry-run] create credential: name=%s type=%s\n" "$name" "$type"
      return 0
    fi
    if cred_exists "$name"; then
      log "  - $name already exists, skipping"
      return 0
    fi
    # Build the payload as proper JSON via Python — env vars carry the raw
    # values so quotes/escapes inside tokens don't matter.
    local payload
    payload="$(NAME="$name" TYPE="$type" DATA="$data_json" python3 -c '
import json, os
print(json.dumps({
  "name": os.environ["NAME"],
  "type": os.environ["TYPE"],
  "data": json.loads(os.environ["DATA"]),
}))')"
    local resp code
    resp="$(n8n_api POST "/credentials" "$payload" 2> /tmp/n8n-cred.code)"
    code="$(awk "{print \$2}" /tmp/n8n-cred.code 2>/dev/null)"
    if [[ "$code" =~ ^2 ]]; then
      log "  ✓ $name (HTTP $code)"
    else
      warn "  ✗ $name HTTP $code — body:"
      echo "$resp" | head -2 | sed 's/^/      /' >&2
    fi
  }

  # 4a. Ollama — skipped on purpose.
  #
  # The native n8n Ollama node (@n8n/n8n-nodes-langchain.lmChatOllama) lives
  # in the LangChain package and depends on credential type 'ollamaApi'.
  # That credential type is ALSO rejected by n8n 2.x's public /api/v1
  # whitelist ("not a known type"). And the matching node may not even be
  # installed depending on the n8n image.
  #
  # The starter workflows now use a plain HTTP Request node hitting
  # http://ollama-pi-agent:11434/api/chat directly. Ollama is unauthenticated
  # on the tailnet so no credential is needed. Users building manual
  # workflows that want the native Ollama node can add the credential via
  # the n8n UI in 10 seconds.

  # 4b. Mattermost — only if creds present
  if [[ -n "$MM_BOT_TOKEN" ]]; then
    create_credential "Mattermost (pi-bot)" "mattermostApi" \
      "$(MM_BOT_TOKEN="$MM_BOT_TOKEN" MM_URL="$MM_URL" python3 -c '
import json, os
print(json.dumps({"accessToken": os.environ["MM_BOT_TOKEN"], "baseUrl": os.environ["MM_URL"]}))')"
  fi

  # 4c. Gitea — header-auth only (n8n 2.x doesn't accept giteaApi via public API)
  if [[ -n "$GITEA_TOKEN" ]]; then
    # n8n 2.x's public /api/v1/credentials rejects giteaApi as "not a known
    # type" (the type still exists in the UI's whitelist but not the REST
    # whitelist). The header-auth credential is functionally equivalent for
    # every Gitea REST call, so we skip the native one and just create the
    # bearer flavor. Users who want to use the native Gitea node directly
    # in a UI-built workflow can add the credential through the UI.
    create_credential "Gitea (admin) — Bearer" "httpHeaderAuth" \
      "$(GITEA_TOKEN="$GITEA_TOKEN" python3 -c '
import json, os
print(json.dumps({"name": "Authorization", "value": "token " + os.environ["GITEA_TOKEN"]}))')"
  fi

  # 4d. OpenWebUI as OpenAI-compatible
  if [[ -n "$OPENWEBUI_TOKEN" ]]; then
    create_credential "OpenWebUI (OpenAI-compat)" "openAiApi" \
      "$(OPENWEBUI_TOKEN="$OPENWEBUI_TOKEN" python3 -c '
import json, os
print(json.dumps({"apiKey": os.environ["OPENWEBUI_TOKEN"], "url": "http://openwebui:8080/api/v1"}))')"
  fi

  # 4e. A random header-auth credential for any "trusted webhook" pattern
  # callers can use to authenticate themselves to n8n webhooks.
  if (( ! DRY_RUN )); then
    EXISTING_SECRET="$(read_token N8N_WEBHOOK_SECRET || true)"
    SHARED_SECRET="${EXISTING_SECRET:-$(openssl rand -hex 16)}"
    create_credential "TD shared webhook secret" "httpHeaderAuth" \
      "$(SHARED_SECRET="$SHARED_SECRET" python3 -c '
import json, os
print(json.dumps({"name": "X-TD-Secret", "value": os.environ["SHARED_SECRET"]}))')"
    upsert_token N8N_WEBHOOK_SECRET "$SHARED_SECRET"
  fi
fi

# ----- 5. Import starter workflows ---------------------------------------
if (( SKIP_WORKFLOWS )); then
  log "Skipping starter workflows (--skip-workflows)"
elif [[ ! -d "$WORKFLOWS_DIR" ]]; then
  warn "Starter workflows dir $WORKFLOWS_DIR missing — skipping."
else
  log "Importing starter workflows..."

  # Build the set of "apps present on this host" to filter workflows against.
  # Sources: pct list hostnames (installed CTs) + special "features" derived
  # from tokens.txt (email_relay if SMTP_HOST set, etc).
  #
  # Rationale: sobol-foundation/addons/n8n/workflows/ is a shared LIBRARY
  # containing every workflow across every stack (foundation, creator-studio,
  # sobol-mirror, founder-ai-os). Prior versions imported ALL of them
  # unconditionally, which meant a foundation-only install got ghost /
  # plausible / calcom / cloudflared / slack-mirror workflows referencing
  # services that don't exist — their credentials were dead, activation
  # would fail. Filter by meta.stack_dependencies.required_apps before
  # importing so each install only gets workflows relevant to its footprint.
  RUNNING_APPS_LIST="$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r _cid; do
    pct config "$_cid" 2>/dev/null | awk '/^hostname:/ {print $2}'
  done | sort -u | tr '\n' ',' | sed 's/,$//')"
  log "  Present apps (from pct list): $RUNNING_APPS_LIST"

  # Feature set: derived from tokens.txt. Extend as we add feature flags.
  RUNNING_FEATURES=""
  if [[ -n "$(read_token SMTP_HOST 2>/dev/null || true)" ]]; then
    RUNNING_FEATURES="email_relay"
  fi
  [[ -n "$RUNNING_FEATURES" ]] && log "  Present features (from tokens.txt): $RUNNING_FEATURES"

  if (( ! DRY_RUN )); then
    for wf in "$WORKFLOWS_DIR"/*.json; do
      [[ -f "$wf" ]] || continue
      WF_NAME="$(basename "$wf" .json)"

      # Read meta.stack_dependencies and decide: import or skip?
      # Returns "OK" or "SKIP: reason".
      DEP_CHECK="$(APPS_PRESENT="$RUNNING_APPS_LIST" FEATURES_PRESENT="$RUNNING_FEATURES" python3 -c "
import json, os, sys
try:
    with open('$wf') as f:
        w = json.load(f)
except Exception as e:
    print('SKIP: unparseable JSON (' + str(e) + ')')
    sys.exit(0)

deps = (w.get('meta') or {}).get('stack_dependencies') or {}
required_apps = deps.get('required_apps') or []
required_features = deps.get('required_features') or []

present_apps = set(a for a in os.environ.get('APPS_PRESENT', '').split(',') if a)
present_features = set(f for f in os.environ.get('FEATURES_PRESENT', '').split(',') if f)

missing_apps = [a for a in required_apps if a not in present_apps]
missing_features = [f for f in required_features if f not in present_features]

if missing_apps or missing_features:
    parts = []
    if missing_apps:     parts.append('missing apps: ' + ','.join(missing_apps))
    if missing_features: parts.append('missing features: ' + ','.join(missing_features))
    print('SKIP: ' + '; '.join(parts))
else:
    print('OK')
")"

      if [[ "$DEP_CHECK" != "OK" ]]; then
        log "  ⊘ Skipping: $WF_NAME ($DEP_CHECK)"
        continue
      fi

      # Read + clean the JSON locally; also patch real Mattermost channel
      # UUIDs into any Mattermost node (n8n 2.x's MM node doesn't resolve
      # channel slugs like "town-square" — it needs the 26-char UUID).
      WF_BODY="$(WF_PATH="$wf" \
        TOWNSQUARE_ID="${MM_TOWNSQUARE_CHANNEL_ID:-}" \
        AICHAT_ID="${MM_AICHAT_CHANNEL_ID:-}" \
        BOT_ID="${MM_BOT_CHANNEL_ID:-}" \
        python3 -c '
import json, os, re
with open(os.environ["WF_PATH"]) as f:
    w = json.load(f)

# Patch channel IDs in any Mattermost node. Two cases:
#   1. Static: p["channelId"] is the slug or "=slug" (n8n-expression-prefixed)
#   2. Dynamic: p["channelId"] is "={{$json.channel}}" — set by a Code node
#      upstream. In that case, also patch the Code node where the slug is
#      assigned, so the dynamic value becomes the real UUID at runtime.
ts = os.environ.get("TOWNSQUARE_ID", "")
ai = os.environ.get("AICHAT_ID", "")
bot = os.environ.get("BOT_ID", "")
mapping = {"town-square": ts, "ai-chat": ai, "bot": bot}

for node in w.get("nodes", []):
    if node.get("type") == "n8n-nodes-base.mattermost":
        p = node.setdefault("parameters", {})
        ch = p.get("channelId", "")
        # Strip leading "=" used by n8n for expressions when comparing slug
        ch_bare = ch[1:] if ch.startswith("=") and not ch.startswith("={{") else ch
        if ch_bare in mapping and mapping[ch_bare]:
            p["channelId"] = mapping[ch_bare]

    # For Code nodes that set channel = "slug" dynamically, replace the
    # slug literal with the UUID literal. Match patterns like:
    #   let channel = "bot";   ->   let channel = "uuid...";
    # We do this conservatively: only replace inside lines that look like
    # channel = "<slug>" so we do not clobber unrelated string literals.
    if node.get("type") == "n8n-nodes-base.code":
        p = node.setdefault("parameters", {})
        code = p.get("jsCode", "")
        if code:
            for slug, uuid in mapping.items():
                if not uuid:
                    continue
                code = re.sub(
                    r"(channel\s*=\s*)([\x27\x22])" + re.escape(slug) + r"\2",
                    lambda m, u=uuid: m.group(1) + m.group(2) + u + m.group(2),
                    code,
                )
            p["jsCode"] = code

# Strip metadata the public API rejects
for k in ("id", "createdAt", "updatedAt", "versionId", "shared", "meta", "tags"):
    w.pop(k, None)
w["active"] = False
allowed = {"name", "nodes", "connections", "settings", "staticData"}
w = {k: v for k, v in w.items() if k in allowed}
w.setdefault("settings", {"executionOrder": "v1"})
print(json.dumps(w))')"

      log "  Importing: $WF_NAME"
      RESP="$(n8n_api POST "/workflows" "$WF_BODY" 2> /tmp/n8n-wf.code)"
      CODE="$(awk '{print $2}' /tmp/n8n-wf.code 2>/dev/null)"
      if [[ "$CODE" =~ ^2 ]]; then
        log "    ✓ imported (inactive — activate via n8n UI after review)"
      else
        warn "    ✗ HTTP $CODE — body:"
        echo "$RESP" | head -3 | sed 's/^/        /' >&2
      fi
    done
  fi
fi

# ----- 6. Register Homepage tile -----------------------------------------
if (( ! SKIP_HOMEPAGE_TILE )); then
  log "Registering Homepage tile..."
  HP_CTID="$(find_ct_by_hostname homepage 2>/dev/null || true)"
  if [[ -n "$HP_CTID" ]] && (( ! DRY_RUN )); then
    SVC="$(pct exec "$HP_CTID" -- bash -lc '
      for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage; do
        [[ -f "$d/services.yaml" ]] && { echo "$d/services.yaml"; exit 0; }
      done' 2>/dev/null | tail -n1)"

    if [[ -n "$SVC" ]]; then
      pct exec "$HP_CTID" -- cp "$SVC" "${SVC}.bak.$(date +%s)"
      pct exec "$HP_CTID" -- bash -lc "awk '
        /^# TD-Addon: n8n/ { in_block=1; next }
        in_block && /^# TD-Addon:/ { in_block=0; print; next }
        !in_block { print }
      ' '$SVC' > /tmp/services.yaml.new && mv /tmp/services.yaml.new '$SVC'"

      TILE_BLOCK="- Automation:
    - n8n:
        href: http://${N8N_HOSTNAME}:5678
        description: Workflow automation
        icon: n8n.png"

      printf '\n# TD-Addon: n8n\n%s\n' "$TILE_BLOCK" | pct exec "$HP_CTID" -- tee -a "$SVC" >/dev/null
      pct exec "$HP_CTID" -- bash -lc 'systemctl restart homepage 2>/dev/null || true'
      log "  ✓ Homepage tile registered"
    fi
  fi
fi

# ----- 7. End-of-run banner ----------------------------------------------
log "================================================================"
log "==> n8n installed and wired."
log " "
log "  Hostname:  $N8N_HOSTNAME (CT $CTID)"
log "  URL:       http://$N8N_HOSTNAME:5678"
log "  Login:     $N8N_OWNER_EMAIL / (n8n owner password from $TOKENS_FILE)"
if [[ -n "${N8N_API_KEY:-}" ]]; then
  log "  API key:   N8N_API_KEY in $TOKENS_FILE"
fi
log " "
log "Credentials wired:"
[[ -n "$MM_BOT_TOKEN" ]] && log "  ✓ Mattermost (pi-bot) — Mattermost node uses bot account"
[[ -n "$GITEA_TOKEN"  ]] && log "  ✓ Gitea (admin) — Bearer — HTTP Request can hit any Gitea endpoint"
[[ -n "$OPENWEBUI_TOKEN" ]] && log "  ✓ OpenWebUI (OpenAI-compat) — OpenAI node points at OpenWebUI"
log "  ✓ TD shared webhook secret — header-auth credential for trusted-caller patterns"
log " "
log "  (Ollama needs no credential — starter workflow hits http://ollama-pi-agent:11434/api/chat directly)"
log " "
log "Starter workflows imported (INACTIVE — review then activate):"
log "  - hello-mattermost: POST /webhook/hello → posts 'hello world' in #town-square"
log "  - mm-ollama-chat: messages in #ai-chat get an Ollama-generated reply"
log "  - gitea-daily-digest: daily 9am cron → last 24h commits → posts in #town-square"
log " "
log "Next steps:"
log "  1. Open http://$N8N_HOSTNAME:5678 and sign in"
log "  2. Open the Workflows panel — three workflows waiting for you"
log "  3. Review the credentials each one references (Settings → Credentials)"
log "  4. Toggle a workflow ACTIVE when you're ready to use it"
log " "
log "Manage:"
log "  status:    pct exec $CTID -- systemctl status n8n"
log "  logs:      pct exec $CTID -- journalctl -u n8n -f"
log "  restart:   pct exec $CTID -- systemctl restart n8n"
log "  uninstall: $(basename "$0") --uninstall"
log "================================================================"
