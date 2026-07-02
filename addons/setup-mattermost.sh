#!/usr/bin/env bash
# setup-mattermost.sh — Stand up a Mattermost CT and auto-configure it.
#
# Creates a new LXC running Mattermost (via community-scripts/mattermost.sh),
# joins it to the tailnet, and runs the same kind of post-install API
# auto-config we do for Gitea + OpenWebUI in configure-apps.sh:
#
#   - Create the homelab admin user (first signup = system admin in MM)
#   - Enable personal access tokens (off by default in MM)
#   - Restart MM so the config change takes effect
#   - Mint a personal access token (used by the Homepage widget)
#   - Create a default 'TD Homelab' team and add the admin to it
#   - Register a Homepage tile with the mattermost widget
#
# End state: open http://mattermost:8065 in your browser, log in as the
# homelab admin, land directly inside the TD Homelab team's Town Square.
# The Homepage dashboard shows a Mattermost tile with live post / unread
# counts via the widget.
#
# Usage (zero flags — reads homelab admin creds from /root/td-tokens.txt
# if present, else prompts):
#   ./setup-mattermost.sh
#
# Or pass any subset:
#   ./setup-mattermost.sh \
#     --admin-user td \
#     --admin-password 'longer-than-12-chars' \
#     --team-name 'TD Homelab' \
#     --ts-authkey tskey-auth-... \
#     --ct-password 'devpass'
#
# Flags:
#   --hostname NAME       CT hostname (default: mattermost)
#   --ctid N              Explicit CTID (default: auto-allocate via pvesh)
#   --cpu N               CPU cores (default: 2)
#   --ram MB              Memory in MB (default: 4096)
#   --disk GB             Root disk in GB (default: 16)
#   --admin-user NAME     Mattermost admin username (default: read from
#                          /root/td-tokens.txt or prompt)
#   --admin-email EMAIL   Admin email (default: read or prompt)
#   --admin-password PW   Admin password (default: read or prompt, min 8 chars)
#   --team-name NAME      Default team display name (default: 'TD Homelab')
#   --ts-authkey KEY      Tailscale auth key (else read /etc/td-proxmox/.vars or prompt)
#   --ct-password PW      CT root password (else read or prompt)
#   --skip-homepage-tile  Don't register a Homepage tile
#   --skip-tailscale      Don't join the new CT to the tailnet
#                         (you'd reach it via LAN IP only)
#   --dry-run             Preview every command without executing

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
HOSTNAME="mattermost"
CTID=""
CPU=2
RAM=4096
DISK=16
ADMIN_USER=""
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
TEAM_NAME="TD Homelab"
TS_AUTHKEY=""
CT_PASSWORD=""
SKIP_HOMEPAGE_TILE=0
SKIP_TAILSCALE=0
DRY_RUN=0

TOKENS_FILE="/root/td-tokens.txt"
MM_HELPER_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/mattermost.sh"

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)           HOSTNAME="$2"; shift 2 ;;
    --ctid)               CTID="$2"; shift 2 ;;
    --cpu)                CPU="$2"; shift 2 ;;
    --ram)                RAM="$2"; shift 2 ;;
    --disk)               DISK="$2"; shift 2 ;;
    --admin-user)         ADMIN_USER="$2"; shift 2 ;;
    --admin-email)        ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password)     ADMIN_PASSWORD="$2"; shift 2 ;;
    --team-name)          TEAM_NAME="$2"; shift 2 ;;
    --ts-authkey)         TS_AUTHKEY="$2"; shift 2 ;;
    --ct-password)        CT_PASSWORD="$2"; shift 2 ;;
    --skip-homepage-tile) SKIP_HOMEPAGE_TILE=1; shift ;;
    --skip-tailscale)     SKIP_TAILSCALE=1; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    -h|--help)            sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-mattermost]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-mattermost]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-mattermost]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

# Shared CT lifecycle helpers (ct_wait_ready + friends). Defined AFTER
# log/warn so the library sees our project-specific formatters.
# shellcheck source=lib/ct-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/ct-helpers.sh"

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct  >/dev/null || die "pct not found — PVE host required."
command -v curl >/dev/null || die "curl not found — install with: apt-get install -y curl"

find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# Read a key=value pair from /root/td-tokens.txt if it exists. configure-apps.sh
# writes that file at the end of its run with ADMIN_USER, ADMIN_EMAIL, and
# ADMIN_PASSWORD. We reuse them so the homelab has one credential set across
# Gitea / OpenWebUI / filebrowser / Mattermost.
read_from_tokens() {
  local key="$1"
  [[ -f "$TOKENS_FILE" ]] || return 1
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); print; exit }' "$TOKENS_FILE"
}

# ----- pre-flight: detect existing CT (skip create) or allocate new --------
# The script is idempotent at the API-config level. If the CT already exists
# we re-run just the auto-config phase against it (admin/team/bot/token/
# Homepage tile/td-tokens.txt). That handles all the partial-success cases
# where the CT got created but the post-config didn't complete.
EXISTING_CT=0
EXISTING_CTID="$(find_ct_by_hostname "$HOSTNAME" 2>/dev/null || true)"
if [[ -n "$EXISTING_CTID" ]]; then
  EXISTING_CT=1
  CTID="$EXISTING_CTID"
  log "================================================================"
  log "Existing CT detected: $CTID ($HOSTNAME)"
  log "Skipping community-scripts install + Tailscale + key push."
  log "Re-running API auto-config phase (admin/team/bot/token/tile)."
  log "If you want a fresh install instead, destroy first:"
  log "  pct stop $CTID && pct destroy $CTID --purge"
  log "================================================================"
  # Verify it's actually running before we depend on it
  pct status "$CTID" 2>/dev/null | grep -q "status: running" \
    || die "CT $CTID ($HOSTNAME) exists but isn't running. Start it: pct start $CTID"
else
  # Fresh install path — allocate CTID if not provided
  if [[ -z "$CTID" ]]; then
    CTID="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"')"
    [[ -n "$CTID" ]] || die "Couldn't auto-allocate CTID via 'pvesh get /cluster/nextid'."
    log "Auto-allocated CTID: $CTID"
  fi
  if pct status "$CTID" >/dev/null 2>&1; then
    die "CTID $CTID is already in use by a different CT. Choose a different --ctid."
  fi
fi

# ----- resolve credentials --------------------------------------------------
# Prefer values from /root/td-tokens.txt (written by configure-apps.sh).
# Fall back to interactive prompt. Reuses the same admin user across the
# homelab so the user doesn't have a separate Mattermost password to manage.

if [[ -z "$ADMIN_USER" ]]; then
  ADMIN_USER="$(read_from_tokens ADMIN_USER 2>/dev/null || true)"
fi
if [[ -z "$ADMIN_USER" ]]; then
  if (( DRY_RUN )); then ADMIN_USER="dryrun"; else
    printf "\n\033[1;36m[setup-mattermost]\033[0m Admin username (e.g. td): " >&2
    IFS= read -r ADMIN_USER
    [[ -n "$ADMIN_USER" ]] || die "Admin user can't be empty."
  fi
else
  log "Reusing admin user '$ADMIN_USER' from $TOKENS_FILE."
fi

if [[ -z "$ADMIN_EMAIL" ]]; then
  ADMIN_EMAIL="$(read_from_tokens ADMIN_EMAIL 2>/dev/null || true)"
fi
if [[ -z "$ADMIN_EMAIL" ]]; then
  if (( DRY_RUN )); then ADMIN_EMAIL="dry@run.local"; else
    printf "\n\033[1;36m[setup-mattermost]\033[0m Admin email: " >&2
    IFS= read -r ADMIN_EMAIL
    [[ -n "$ADMIN_EMAIL" ]] || die "Admin email can't be empty."
  fi
fi

if [[ -z "$ADMIN_PASSWORD" ]]; then
  ADMIN_PASSWORD="$(read_from_tokens ADMIN_PASSWORD 2>/dev/null || true)"
fi
if [[ -z "$ADMIN_PASSWORD" ]]; then
  if (( DRY_RUN )); then ADMIN_PASSWORD="dryrun-placeholder-pw"; else
    printf "\n\033[1;36m[setup-mattermost]\033[0m Admin password (hidden; min 8 chars): " >&2
    IFS= read -rs ADMIN_PASSWORD; echo >&2
    [[ ${#ADMIN_PASSWORD} -ge 8 ]] || die "Password too short (need >= 8 chars)."
  fi
fi

# SMTP credentials (optional). If present in td-tokens.txt, the config PUT
# below wires Mattermost's EmailSettings to relay through the provider so
# @mentions, password resets, admin invitations actually arrive. If absent,
# we leave MM's defaults in place (its SMTP fields stay empty, no mail sent).
SMTP_HOST="$(read_from_tokens SMTP_HOST 2>/dev/null || true)"
SMTP_PORT="$(read_from_tokens SMTP_PORT 2>/dev/null || echo 587)"
SMTP_USERNAME="$(read_from_tokens SMTP_USERNAME 2>/dev/null || true)"
SMTP_PASSWORD="$(read_from_tokens SMTP_PASSWORD 2>/dev/null || true)"
SMTP_FROM="$(read_from_tokens SMTP_FROM 2>/dev/null || true)"
SMTP_FROM_NAME="$(read_from_tokens SMTP_FROM_NAME 2>/dev/null || echo 'Mattermost')"
if [[ -n "$SMTP_HOST" ]]; then
  log "Will wire Mattermost EmailSettings to $SMTP_HOST:$SMTP_PORT (FROM: $SMTP_FROM)"
else
  log "No SMTP_HOST in $TOKENS_FILE — Mattermost email will be disabled. Add SMTP_* and re-run to enable."
fi

# TS_AUTHKEY and CT_PASSWORD are ONLY needed when creating a fresh CT.
# When EXISTING_CT=1 we're re-running just the API auto-config phase against
# an already-up CT — skip these prompts entirely. Saves a re-prompt every
# time the user iterates on the auto-config side of things.
if (( ! EXISTING_CT )); then

  if [[ -z "$TS_AUTHKEY" ]] && (( ! SKIP_TAILSCALE )); then
    # Resolution order, most-specific first:
    #   1. /root/td-tokens.txt   (cached from a prior addon run — preferred)
    #   2. /etc/td-proxmox/.vars (bootstrap-pve.sh writes it on initial build)
    #   3. interactive prompt
    TS_AUTHKEY="$(read_from_tokens TS_AUTHKEY 2>/dev/null || true)"
    if [[ -n "$TS_AUTHKEY" ]]; then
      log "Reusing TS_AUTHKEY from $TOKENS_FILE."
    elif [[ -f /etc/td-proxmox/.vars ]]; then
      TS_AUTHKEY="$(awk -F= '/^TS_AUTHKEY=/{sub(/^[^=]*=/,"",$0); print; exit}' /etc/td-proxmox/.vars 2>/dev/null | tr -d '"' || true)"
      [[ -n "$TS_AUTHKEY" ]] && log "Reusing TS_AUTHKEY from /etc/td-proxmox/.vars."
    fi
    if [[ -z "$TS_AUTHKEY" ]] && (( ! DRY_RUN )); then
      printf "\n\033[1;36m[setup-mattermost]\033[0m Tailscale auth key (https://login.tailscale.com/admin/settings/keys; must be REUSABLE): " >&2
      IFS= read -rs TS_AUTHKEY; echo >&2
      [[ -n "$TS_AUTHKEY" ]] || die "Tailscale auth key required (or pass --skip-tailscale)."
    fi
    (( DRY_RUN )) && [[ -z "$TS_AUTHKEY" ]] && TS_AUTHKEY="tskey-DRYRUN"

    # Cache the key in td-tokens.txt for future addon runs (other addons
    # that create CTs — setup-new-pi-agent.sh, hypothetical future ones —
    # can read from the same place). Skip the cache write on dry-run or
    # if td-tokens.txt doesn't exist yet (first-ever bootstrap path).
    if (( ! DRY_RUN )) && [[ -f "$TOKENS_FILE" && "$TS_AUTHKEY" != "tskey-DRYRUN" ]]; then
      # Strip any prior TS_AUTHKEY line first so re-runs stay canonical
      if grep -q "^TS_AUTHKEY=" "$TOKENS_FILE"; then
        sed -i '/^TS_AUTHKEY=/d' "$TOKENS_FILE"
      fi
      echo "TS_AUTHKEY=$TS_AUTHKEY" >> "$TOKENS_FILE"
      log "Cached TS_AUTHKEY in $TOKENS_FILE for future addon runs."
    fi
  fi

  if [[ -z "$CT_PASSWORD" ]]; then
    if (( DRY_RUN )); then CT_PASSWORD="dryrun-ct-pw"; else
      printf "\n\033[1;36m[setup-mattermost]\033[0m CT root password (for console fallback): " >&2
      IFS= read -rs CT_PASSWORD; echo >&2
      [[ -n "$CT_PASSWORD" ]] || die "CT password required."
    fi
  fi

fi  # ! EXISTING_CT

# ----- resolve workstation SSH key for the new CT --------------------------
SSH_KEY=""
if [[ -f /root/.ssh/authorized_keys && -s /root/.ssh/authorized_keys ]]; then
  # Pick the first non-PVE-auto-key (skip 'root@<pve-hostname>')
  PVE_HOST="$(hostname -s)"
  SSH_KEY="$(awk -v skip="root@$PVE_HOST" '/^ssh-/ && $NF != skip { print; exit }' /root/.ssh/authorized_keys)"
  [[ -z "$SSH_KEY" ]] && SSH_KEY="$(awk '/^ssh-/ { print; exit }' /root/.ssh/authorized_keys)"
fi

# ----- planned-install summary ----------------------------------------------
log "================================================================"
log "Mattermost install plan:"
log "  Hostname:       $HOSTNAME"
log "  CTID:           $CTID"
log "  Resources:      $CPU cpu / $RAM MB RAM / $DISK GB disk"
log "  Admin user:     $ADMIN_USER ($ADMIN_EMAIL)"
log "  Team name:      $TEAM_NAME"
log "  Tailscale:      $((( SKIP_TAILSCALE )) && echo skipped || echo yes (joining tailnet))"
log "  Homepage tile:  $((( SKIP_HOMEPAGE_TILE )) && echo skipped || echo registered)"
log "================================================================"

# ----- CT-creation phase (skipped when EXISTING_CT=1) ----------------------
# Everything in this section is one-shot CT setup. If the CT already exists,
# we assume it's working (port test below catches the case where Mattermost
# is broken) and jump straight to the auto-config phase.
if (( ! EXISTING_CT )); then
  log "Running community-scripts mattermost.sh helper (creates CT, installs Mattermost)..."
  log "  Pick 'Default Install' in the whiptail menu when it appears."

  # Same env-var pattern bootstrap-pve.sh uses. var_hostname pins the CT name,
  # var_ssh + var_ssh_authorized_key seed our workstation key during CT creation,
  # var_gpu=no skips any GPU prompts.
  run "var_ctid=$CTID \
       var_hostname=$HOSTNAME \
       var_cpu=$CPU \
       var_ram=$RAM \
       var_disk=$DISK \
       var_ssh=yes \
       var_ssh_authorized_key='$SSH_KEY' \
       var_gpu=no \
       bash -c \"\$(curl -fsSL '$MM_HELPER_URL')\""

  # The community helper may have used a different CTID if ours was taken.
  # Detect the actual one by hostname before continuing.
  if (( ! DRY_RUN )); then
    ACTUAL_CTID="$(find_ct_by_hostname "$HOSTNAME" 2>/dev/null || true)"
    if [[ -n "$ACTUAL_CTID" && "$ACTUAL_CTID" != "$CTID" ]]; then
      log "  Helper assigned CTID $ACTUAL_CTID (not our preferred $CTID) — switching."
      CTID="$ACTUAL_CTID"
    fi
  fi

  [[ -n "$CTID" ]] || die "Mattermost CT didn't come up — check the community helper output above."

  # ----- TUN passthrough (only matters if Tailscale will be joined) ----------
  if (( ! SKIP_TAILSCALE )); then
    log "Adding /dev/net/tun passthrough so Tailscale can run..."
    CT_CONF="/etc/pve/lxc/$CTID.conf"
    if (( ! DRY_RUN )) && ! grep -q "/dev/net/tun" "$CT_CONF" 2>/dev/null; then
      cat >> "$CT_CONF" <<'TUN_BLOCK'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
TUN_BLOCK
      # Reboot so the mount takes effect.
      run "pct reboot $CTID"
      log "Waiting for CT to come back fully after reboot (IP + DNS)..."
      # Was: sleep 8 + ping-only loop. Ping tests IP-connectivity but
      # returns green before systemd-resolved is ready, so downstream
      # apt/curl calls that hit hostnames would fail with 'Temporary
      # failure resolving' on fresh Ubuntu 24 CTs. ct_wait_ready waits
      # for both IP and DNS + restarts systemd-resolved as recovery if
      # DNS doesn't come up. See TROUBLESHOOTING_LOG 2026-07-02.
      if (( ! DRY_RUN )); then
        ct_wait_ready "$CTID" || die "CT $CTID not fully ready after reboot — see diagnostics above"
      fi
    fi
  fi

  # ----- Tailscale join ----------------------------------------------------
  if (( ! SKIP_TAILSCALE )); then
    log "Installing Tailscale + joining tailnet as '$HOSTNAME'..."
    # Dropped -qq on apt so operators see actual progress. Wrapped Tailscale
    # install in timeout so it can't hang forever on a slow install.sh.
    run "pct exec $CTID -- bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends curl ca-certificates 2>&1 | tail -3'"
    run "pct exec $CTID -- bash -lc 'curl -fsSL --max-time 90 https://tailscale.com/install.sh | sh'"
    run "pct exec $CTID -- tailscale up --reset --authkey '$TS_AUTHKEY' --hostname '$HOSTNAME' --accept-routes --accept-dns"

    log "Waiting for Tailscale to reach Running..."
    if (( ! DRY_RUN )); then
      for i in {1..20}; do
        pct exec "$CTID" -- tailscale status >/dev/null 2>&1 && break
        sleep 2
      done
    fi
  fi

  # ----- ensure workstation SSH keys are in /root/.ssh/authorized_keys -----
  log "Pushing PVE host's authorized_keys to the new CT..."
  run "pct push $CTID /root/.ssh/authorized_keys /root/.ssh/authorized_keys --perms 0600"
  run "pct exec $CTID -- chown root:root /root/.ssh/authorized_keys"
else
  log "Skipping CT creation steps (existing CT mode)."
fi

# ----- wait for Mattermost to be reachable ---------------------------------
log "Waiting for Mattermost to come up on port 8065..."
if (( ! DRY_RUN )); then
  i=0
  while ! pct exec "$CTID" -- bash -lc "exec 3<>/dev/tcp/127.0.0.1/8065" 2>/dev/null; do
    (( ++i > 60 )) && die "Mattermost (CT $CTID port 8065) not responding after 2 min. Check: pct exec $CTID -- journalctl -u mattermost --no-pager | tail -30"
    sleep 2
  done
  # Plus a /api/v4/system/ping check so we know the API itself is happy
  for i in {1..30}; do
    pct exec "$CTID" -- bash -lc "curl -sf http://127.0.0.1:8065/api/v4/system/ping >/dev/null 2>&1" && break
    sleep 2
  done
fi

MM_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "<mm-ip>")"
log "Mattermost reachable at http://$MM_IP:8065 (or http://$HOSTNAME:8065 on the tailnet)"

# ----- auto-config: admin user + token + team ------------------------------
# Same pattern as configure_openwebui in configure-apps.sh: hit the API
# from inside the CT (127.0.0.1) so we don't depend on Tailscale or LAN
# routing for the bootstrap step.
#
# Mattermost-specific quirks:
#   - First user signed up on a fresh install becomes a system admin.
#   - Personal access tokens are disabled by default; we have to PUT the
#     config to enable them, then restart Mattermost, then mint the token.
#   - Email verification might be required by config; we patch config to
#     disable it before the signup so 'login' returns a session immediately.

log "================================================================"
log "Auto-configuring Mattermost via REST API..."
log "================================================================"

MM_TOKEN=""
MM_USER_ID=""
MM_TEAM_ID=""

if (( ! DRY_RUN )); then
  # Small helper: POST JSON to a Mattermost endpoint from inside the CT.
  _mm_post() {
    local path="$1" body="$2" auth_header="${3:-}"
    local cmd="curl -sS -w '\nHTTP_STATUS:%{http_code}' -X POST 'http://127.0.0.1:8065${path}' -H 'Content-Type: application/json' -d '$body'"
    [[ -n "$auth_header" ]] && cmd="${cmd/-H \'Content-Type:/$auth_header -H \'Content-Type:}"
    pct exec "$CTID" -- bash -lc "$cmd" 2>/dev/null || echo "HTTP_STATUS:000"
  }
  _mm_get() {
    local path="$1" auth_header="${2:-}"
    pct exec "$CTID" -- bash -lc "curl -sS -w '\nHTTP_STATUS:%{http_code}' $auth_header 'http://127.0.0.1:8065${path}'" 2>/dev/null || echo "HTTP_STATUS:000"
  }
  _mm_status() { echo "$1" | grep -oE 'HTTP_STATUS:[0-9]+' | tail -1 | cut -d: -f2; }
  _mm_body()   { echo "$1" | sed '/^HTTP_STATUS:/d'; }

  # 1. Signup as the first user → system admin
  log "Creating admin user ($ADMIN_USER) via /api/v4/users..."
  SIGNUP_BODY=$(printf '{"email":"%s","username":"%s","password":"%s"}' "$ADMIN_EMAIL" "$ADMIN_USER" "$ADMIN_PASSWORD")
  SIGNUP_RESP=$(_mm_post "/api/v4/users" "$SIGNUP_BODY")
  SIGNUP_STATUS=$(_mm_status "$SIGNUP_RESP")
  SIGNUP_BODYR=$(_mm_body "$SIGNUP_RESP")

  if [[ "$SIGNUP_STATUS" == "200" || "$SIGNUP_STATUS" == "201" ]]; then
    MM_USER_ID=$(echo "$SIGNUP_BODYR" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
    log "  Admin user created. id=$MM_USER_ID"
  elif [[ "$SIGNUP_STATUS" == "400" ]] && echo "$SIGNUP_BODYR" | grep -q 'app.user.save.username_exists'; then
    log "  User already exists — fetching id via login..."
  else
    warn "  Signup returned HTTP $SIGNUP_STATUS. Body: $SIGNUP_BODYR"
    warn "  Continuing — login attempt below may still recover."
  fi

  # 2. Login → session token is returned in the Token header
  log "Logging in as $ADMIN_USER..."
  LOGIN_BODY=$(printf '{"login_id":"%s","password":"%s"}' "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
  LOGIN_RESP=$(pct exec "$CTID" -- bash -lc "curl -sS -D - -X POST 'http://127.0.0.1:8065/api/v4/users/login' -H 'Content-Type: application/json' -d '$LOGIN_BODY'" 2>/dev/null || true)
  SESSION_TOKEN=$(echo "$LOGIN_RESP" | awk '/^[Tt]oken:/ {print $2}' | tr -d '\r')

  if [[ -z "$SESSION_TOKEN" ]]; then
    warn "  Login didn't return a session token. Mattermost may require email verification."
    warn "  Fix: open http://$MM_IP:8065 in a browser, sign in once with your password, then re-run this addon with --skip-tailscale (or whatever stage failed)."
    warn "  Skipping token mint + team creation."
  else
    log "  Session token obtained. (Length: ${#SESSION_TOKEN})"

    AUTH_HEADER="-H 'Authorization: Bearer $SESSION_TOKEN'"

    # 3. Enable personal access tokens — required for the Homepage widget
    log "Enabling personal access tokens in config..."
    CFG_RESP=$(pct exec "$CTID" -- bash -lc "curl -sS $AUTH_HEADER 'http://127.0.0.1:8065/api/v4/config'" 2>/dev/null || true)
    if [[ -n "$CFG_RESP" ]]; then
      # Set ServiceSettings.EnableUserAccessTokens=true and PUT back
      NEW_CFG=$(echo "$CFG_RESP" | python3 -c "
import sys, json
c = json.load(sys.stdin)
# Nine settings to flip:
#  1. EnableUserAccessTokens — required to mint admin PAT for Homepage
#     widget AND the bot's PAT.
#  2. EnableBotAccountCreation — defaults to FALSE in Mattermost. Without
#     it, POST /api/v4/bots returns 403 'api.bot.create_disabled' even
#     for system admins. (Caught by user 2026-06-22 — bot was being
#     blocked here, leaving the entire automation chain broken.)
#  3. RequireEmailVerification — turn off so future signups don't loop
#     on email-confirm.
#  4. SiteURL — clear to empty. Mattermost defaults this to the IP the
#     installer used (http://<ct-ip>:8065). With a non-empty value, MM's
#     WebSocket handler does Host/Origin validation against it, so any
#     access via a different name (MagicDNS like 'mattermost:8065',
#     Tailscale FQDN, reverse proxy) gets ws disconnects with err 1006
#     and real-time updates stop. Empty SiteURL = trust the request.
#     Safe inside a tailnet because access is already auth-gated.
#     (Caught by user 2026-06-23 — magicdns access lost typing+live
#     updates; CORS errors from mattermost-ai plugin against the IP.)
#  5. AllowCorsFrom — '*' so plugin AJAX calls (mattermost-ai etc.)
#     don't trip CORS when accessed via a hostname different from
#     SiteURL's recorded value.
#  6. WebsocketURL — clear so client derives from the request URL.
#     A hardcoded value here would override the page's WS URL and
#     re-introduce the Host mismatch.
#  7. AllowedUntrustedInternalConnections — THE undocumented webhook
#     gate. Mattermost's anti-SSRF protection blocks all outgoing
#     connections (outgoing webhooks, mattermost-ai plugin, etc.) to
#     RFC1918 / loopback / link-local addresses unless their host or
#     CIDR is in this whitelist. With it empty (default), 'outgoing
#     webhook → http://n8n:5678/...' silently fails. We whitelist
#     every private range + Tailscale CGNAT + loopback + service
#     hostnames so every in-stack target works. (Found by user
#     2026-06-28 via config diff across CT 112/115/121.)
#  8. EnablePostUsernameOverride / EnablePostIconOverride — let
#     incoming webhooks and bot accounts post AS custom identities.
#     Without these, webhook posts appear as the owning account name.
ss = c.setdefault('ServiceSettings', {})
ss['EnableUserAccessTokens']     = True
ss['EnableBotAccountCreation']   = True
ss['SiteURL']                    = ''
ss['AllowCorsFrom']              = '*'
ss['WebsocketURL']               = ''
ss['AllowedUntrustedInternalConnections'] = 'localhost 127.0.0.1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 n8n ollama-pi-agent gitea openwebui homepage sandbox mattermost'
ss['EnablePostUsernameOverride'] = True
ss['EnablePostIconOverride']     = True
# 9. EnableDynamicClientRegistration — user's recollection (2026-06-28) is
#    that THIS flag, not AllowedUntrustedInternalConnections, was the actual
#    setting that unblocked outgoing webhooks on a previous install. The
#    config-diff showed CT 115 (the working one) had this flag = true while
#    112 + 121 had it = false. There's no documented connection between this
#    OAuth-server feature and webhook handling, so it may be an unintended
#    side-effect / bug. Setting both flags here is belt-and-suspenders: if
#    the SSRF whitelist is the real fix, this is harmless. If this flag is
#    the real fix (a bug somewhere in MM's request pipeline), we're covered.
ss['EnableDynamicClientRegistration'] = True

# 10. EmailSettings — wire SMTP so MM sends mention emails, password resets,
#     admin invitations, etc. Reads SMTP_* from environment (passed in by
#     bash heredoc below). Skip if SMTP_HOST is empty — leave MM's defaults
#     in place so it doesn't try to send mail and queue/fail silently.
es = c.setdefault('EmailSettings', {})
es['RequireEmailVerification'] = False  # never gate access on email working
smtp_host = '''$SMTP_HOST'''
if smtp_host:
    es['EnableSignUpWithEmail']       = True
    es['EnableSignInWithEmail']       = True
    es['EnableSignInWithUsername']    = True
    es['SendEmailNotifications']      = True
    es['EnableSMTPAuth']              = True
    es['SMTPServer']                  = smtp_host
    es['SMTPPort']                    = '''${SMTP_PORT:-587}'''
    es['SMTPUsername']                = '''$SMTP_USERNAME'''
    es['SMTPPassword']                = '''$SMTP_PASSWORD'''
    # 587 = STARTTLS, 465 = TLS, 25 = none. Pick TLS variant based on port.
    smtp_port_str = '''${SMTP_PORT:-587}'''
    if smtp_port_str == '465':
        es['ConnectionSecurity'] = 'TLS'
    elif smtp_port_str == '25':
        es['ConnectionSecurity'] = ''
    else:
        es['ConnectionSecurity'] = 'STARTTLS'
    es['FeedbackEmail']               = '''$SMTP_FROM'''
    es['FeedbackName']                = '''${SMTP_FROM_NAME:-Mattermost}'''
    es['FeedbackOrganization']        = '''${SMTP_FROM_NAME:-Mattermost}'''
    es['ReplyToAddress']              = '''$SMTP_FROM'''
    es['SkipServerCertificateVerification'] = False
    es['SendPushNotifications']       = False  # only set this true if you've configured a push service

print(json.dumps(c))
" 2>/dev/null || true)
      if [[ -n "$NEW_CFG" ]]; then
        # Write the config payload to a temp file inside the CT so we don't
        # have to worry about shell-escaping a multi-MB JSON blob.
        echo "$NEW_CFG" | pct exec "$CTID" -- tee /tmp/mm-config.json >/dev/null
        PUT_STATUS=$(pct exec "$CTID" -- bash -lc "curl -sS -o /dev/null -w '%{http_code}' -X PUT $AUTH_HEADER -H 'Content-Type: application/json' --data-binary @/tmp/mm-config.json 'http://127.0.0.1:8065/api/v4/config'" 2>/dev/null || echo "000")
        if [[ "$PUT_STATUS" == "200" ]]; then
          log "  Config updated. Restarting Mattermost to apply..."
          run "pct exec $CTID -- systemctl restart mattermost"
          log "  Waiting for Mattermost to come back..."
          sleep 5
          for i in {1..30}; do
            pct exec "$CTID" -- bash -lc "curl -sf http://127.0.0.1:8065/api/v4/system/ping >/dev/null 2>&1" && break
            sleep 2
          done
          # Re-login because the restart invalidates our session
          LOGIN_RESP=$(pct exec "$CTID" -- bash -lc "curl -sS -D - -X POST 'http://127.0.0.1:8065/api/v4/users/login' -H 'Content-Type: application/json' -d '$LOGIN_BODY'" 2>/dev/null || true)
          SESSION_TOKEN=$(echo "$LOGIN_RESP" | awk '/^[Tt]oken:/ {print $2}' | tr -d '\r')
          AUTH_HEADER="-H 'Authorization: Bearer $SESSION_TOKEN'"
        else
          warn "  Config update returned HTTP $PUT_STATUS — personal access tokens may not be enabled. Homepage widget will fall back to placeholder."
        fi
      fi
    fi

    # 4. Mint a personal access token for the admin
    log "Minting personal access token for $ADMIN_USER..."
    if [[ -z "$MM_USER_ID" ]]; then
      # Fetch user id from /api/v4/users/me
      ME_RESP=$(pct exec "$CTID" -- bash -lc "curl -sS $AUTH_HEADER 'http://127.0.0.1:8065/api/v4/users/me'" 2>/dev/null || true)
      MM_USER_ID=$(echo "$ME_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
    fi
    if [[ -n "$MM_USER_ID" ]]; then
      TOKEN_BODY='{"description":"Homepage widget"}'
      TOKEN_RESP=$(_mm_post "/api/v4/users/$MM_USER_ID/tokens" "$TOKEN_BODY" "$AUTH_HEADER")
      TOKEN_STATUS=$(_mm_status "$TOKEN_RESP")
      TOKEN_BODYR=$(_mm_body "$TOKEN_RESP")
      if [[ "$TOKEN_STATUS" == "200" || "$TOKEN_STATUS" == "201" ]]; then
        MM_TOKEN=$(echo "$TOKEN_BODYR" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)
        log "  Personal access token minted (length: ${#MM_TOKEN})"
      else
        warn "  Token mint returned HTTP $TOKEN_STATUS. Body: $TOKEN_BODYR"
        warn "  Homepage widget will use a placeholder — fix manually in Mattermost: Account Settings → Security → Personal Access Tokens."
      fi
    fi

    # 5. Create default team and add admin to it
    log "Creating default team '$TEAM_NAME'..."
    # Derive a URL-safe team 'name' from the display name (lowercase, hyphens)
    TEAM_SLUG=$(echo "$TEAM_NAME" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
    TEAM_BODY=$(printf '{"name":"%s","display_name":"%s","type":"O","email":"%s"}' "$TEAM_SLUG" "$TEAM_NAME" "$ADMIN_EMAIL")
    TEAM_RESP=$(_mm_post "/api/v4/teams" "$TEAM_BODY" "$AUTH_HEADER")
    TEAM_STATUS=$(_mm_status "$TEAM_RESP")
    TEAM_BODYR=$(_mm_body "$TEAM_RESP")
    if [[ "$TEAM_STATUS" == "200" || "$TEAM_STATUS" == "201" ]]; then
      MM_TEAM_ID=$(echo "$TEAM_BODYR" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
      log "  Team created: id=$MM_TEAM_ID name=$TEAM_SLUG"
    elif [[ "$TEAM_STATUS" == "400" ]] && echo "$TEAM_BODYR" | grep -q 'existing.app_error'; then
      # Re-run path: team URL already exists — look it up by slug. Without
      # this fallback, MM_TEAM_ID stays empty, and every downstream operation
      # that needs a team_id (bot-to-team add, channel create, channel
      # member add) silently no-ops. The user gets a half-configured
      # install with no error trail.
      log "  Team already exists — looking it up by slug '$TEAM_SLUG'..."
      LOOKUP=$(_mm_get "/api/v4/teams/name/$TEAM_SLUG" "$AUTH_HEADER")
      LOOKUP_STATUS=$(_mm_status "$LOOKUP")
      if [[ "$LOOKUP_STATUS" == "200" ]]; then
        MM_TEAM_ID=$(_mm_body "$LOOKUP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
        log "    Reused id=$MM_TEAM_ID"
      else
        warn "    Lookup also failed (HTTP $LOOKUP_STATUS). Bot+channel steps will be skipped."
      fi
    else
      warn "  Team create returned HTTP $TEAM_STATUS. Body: $TEAM_BODYR"
    fi

    # Add admin to team — works whether team was newly created or looked-up
    if [[ -n "$MM_USER_ID" && -n "$MM_TEAM_ID" ]]; then
      MEMBER_BODY=$(printf '{"team_id":"%s","user_id":"%s"}' "$MM_TEAM_ID" "$MM_USER_ID")
      _mm_post "/api/v4/teams/$MM_TEAM_ID/members" "$MEMBER_BODY" "$AUTH_HEADER" >/dev/null
    fi

    # 6. Create a dedicated bot account for pi automation
    #
    # Bot accounts are first-class in Mattermost (POST /api/v4/bots) and are
    # the right shape for "agent posts status updates" workloads:
    #   - Distinct identity in the UI (posts show as 'pi (bot)' not as the admin)
    #   - Own access token (admin PAT leak doesn't compromise bot, and vice versa)
    #   - Can be confined to one channel rather than every channel the admin sees
    #
    # We also create a public #bot channel and put the bot in it so pi has a
    # default landing place for automation messages. The bot id + token + channel
    # id all get exported from /root/td-tokens.txt for pi to consume.
    log "Creating pi-bot account + #bot channel..."

    MM_BOT_USER_ID=""
    MM_BOT_TOKEN=""
    MM_BOT_CHANNEL_ID=""

    BOT_BODY='{"username":"pi-bot","display_name":"pi (bot)","description":"Pi coding agent automation"}'
    BOT_RESP=$(_mm_post "/api/v4/bots" "$BOT_BODY" "$AUTH_HEADER")
    BOT_STATUS=$(_mm_status "$BOT_RESP")
    BOT_BODYR=$(_mm_body "$BOT_RESP")

    if [[ "$BOT_STATUS" == "200" || "$BOT_STATUS" == "201" ]]; then
      MM_BOT_USER_ID=$(echo "$BOT_BODYR" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("user_id",""))' 2>/dev/null || true)
      log "  Bot 'pi-bot' created. user_id=$MM_BOT_USER_ID"
    elif [[ "$BOT_STATUS" == "400" ]]; then
      # Already exists — fetch user_id by username so re-runs reuse it
      log "  Bot 'pi-bot' already exists — fetching user_id..."
      LOOKUP=$(_mm_get "/api/v4/users/username/pi-bot" "$AUTH_HEADER")
      LOOKUP_STATUS=$(_mm_status "$LOOKUP")
      if [[ "$LOOKUP_STATUS" == "200" ]]; then
        MM_BOT_USER_ID=$(_mm_body "$LOOKUP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
      fi
    else
      warn "  Bot create returned HTTP $BOT_STATUS. Body: $BOT_BODYR"
    fi

    if [[ -n "$MM_BOT_USER_ID" ]]; then
      # Add bot to the default team. Required before it can join any channels there.
      if [[ -n "$MM_TEAM_ID" ]]; then
        BOT_TEAM_BODY=$(printf '{"team_id":"%s","user_id":"%s"}' "$MM_TEAM_ID" "$MM_BOT_USER_ID")
        _mm_post "/api/v4/teams/$MM_TEAM_ID/members" "$BOT_TEAM_BODY" "$AUTH_HEADER" >/dev/null
        log "  Added pi-bot to team."
      fi

      # Mint a personal access token for the bot. Same endpoint as user tokens.
      BOT_TOKEN_BODY='{"description":"pi-agent automation token"}'
      BTRESP=$(_mm_post "/api/v4/users/$MM_BOT_USER_ID/tokens" "$BOT_TOKEN_BODY" "$AUTH_HEADER")
      BTSTATUS=$(_mm_status "$BTRESP")
      BTBODY=$(_mm_body "$BTRESP")
      if [[ "$BTSTATUS" == "200" || "$BTSTATUS" == "201" ]]; then
        MM_BOT_TOKEN=$(echo "$BTBODY" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)
        log "  Bot token minted (length: ${#MM_BOT_TOKEN})"
      else
        warn "  Bot token mint returned HTTP $BTSTATUS. Body: $BTBODY"
      fi

      # Create #bot channel in the team. type=O is public/open.
      if [[ -n "$MM_TEAM_ID" ]]; then
        CHAN_BODY=$(printf '{"team_id":"%s","name":"bot","display_name":"Bot Posts","type":"O","purpose":"Automated posts from pi and other homelab bots"}' "$MM_TEAM_ID")
        CHRESP=$(_mm_post "/api/v4/channels" "$CHAN_BODY" "$AUTH_HEADER")
        CHSTATUS=$(_mm_status "$CHRESP")
        CHBODY=$(_mm_body "$CHRESP")
        if [[ "$CHSTATUS" == "200" || "$CHSTATUS" == "201" ]]; then
          MM_BOT_CHANNEL_ID=$(echo "$CHBODY" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
          log "  #bot channel created: id=$MM_BOT_CHANNEL_ID"
        elif [[ "$CHSTATUS" == "400" ]]; then
          # Channel name collision — fetch the existing one
          log "  #bot channel already exists — fetching id..."
          LOOKUP=$(_mm_get "/api/v4/teams/$MM_TEAM_ID/channels/name/bot" "$AUTH_HEADER")
          LOOKUP_STATUS=$(_mm_status "$LOOKUP")
          if [[ "$LOOKUP_STATUS" == "200" ]]; then
            MM_BOT_CHANNEL_ID=$(_mm_body "$LOOKUP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
          fi
        else
          warn "  Channel create returned HTTP $CHSTATUS. Body: $CHBODY"
        fi

        # Add bot to channel so it can post
        if [[ -n "$MM_BOT_CHANNEL_ID" ]]; then
          CHM_BODY=$(printf '{"user_id":"%s"}' "$MM_BOT_USER_ID")
          _mm_post "/api/v4/channels/$MM_BOT_CHANNEL_ID/members" "$CHM_BODY" "$AUTH_HEADER" >/dev/null
          log "  Added pi-bot to #bot channel."
        fi

        # ----- ensure pi-bot is a member of standard channels too -----
        # Workflows from setup-n8n.sh (and any other automation) tend to post
        # to town-square by default. Without bot membership Mattermost returns
        # 403 on POST. Also create #ai-chat for the Ollama-chat workflow.
        _mm_add_bot_to_channel() {
          local channel_name="$1" channel_id="$2"
          [[ -z "$channel_id" ]] && return 0
          local body status
          body=$(printf '{"user_id":"%s"}' "$MM_BOT_USER_ID")
          local resp
          resp=$(_mm_post "/api/v4/channels/$channel_id/members" "$body" "$AUTH_HEADER")
          status=$(_mm_status "$resp")
          case "$status" in
            200|201) log "  Added pi-bot to #$channel_name." ;;
            400)     log "  pi-bot already a member of #$channel_name." ;;
            *)       warn "  Adding pi-bot to #$channel_name returned HTTP $status." ;;
          esac
        }

        # town-square — already exists in every team
        log "  Looking up #town-square..."
        TS_LOOKUP=$(_mm_get "/api/v4/teams/$MM_TEAM_ID/channels/name/town-square" "$AUTH_HEADER")
        TS_STATUS=$(_mm_status "$TS_LOOKUP")
        if [[ "$TS_STATUS" == "200" ]]; then
          MM_TOWNSQUARE_CHANNEL_ID=$(_mm_body "$TS_LOOKUP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
          log "  #town-square id: $MM_TOWNSQUARE_CHANNEL_ID"
          _mm_add_bot_to_channel "town-square" "$MM_TOWNSQUARE_CHANNEL_ID"
        else
          warn "  Could not look up #town-square (HTTP $TS_STATUS)."
        fi

        # ai-chat — create if missing, add bot
        log "  Ensuring #ai-chat exists..."
        AI_CHAT_BODY=$(printf '{"team_id":"%s","name":"ai-chat","display_name":"AI Chat","type":"O","purpose":"Talk to the homelab Ollama agents via the n8n bridge"}' "$MM_TEAM_ID")
        AICRESP=$(_mm_post "/api/v4/channels" "$AI_CHAT_BODY" "$AUTH_HEADER")
        AICSTATUS=$(_mm_status "$AICRESP")
        AICBODY=$(_mm_body "$AICRESP")
        if [[ "$AICSTATUS" == "200" || "$AICSTATUS" == "201" ]]; then
          MM_AICHAT_CHANNEL_ID=$(echo "$AICBODY" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
          log "  #ai-chat channel created: id=$MM_AICHAT_CHANNEL_ID"
        elif [[ "$AICSTATUS" == "400" ]]; then
          log "  #ai-chat already exists — fetching id..."
          AILOOKUP=$(_mm_get "/api/v4/teams/$MM_TEAM_ID/channels/name/ai-chat" "$AUTH_HEADER")
          AILSTATUS=$(_mm_status "$AILOOKUP")
          if [[ "$AILSTATUS" == "200" ]]; then
            MM_AICHAT_CHANNEL_ID=$(_mm_body "$AILOOKUP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
          fi
        else
          warn "  #ai-chat create returned HTTP $AICSTATUS. Body: $AICBODY"
        fi
        _mm_add_bot_to_channel "ai-chat" "${MM_AICHAT_CHANNEL_ID:-}"
      fi
    fi
  fi
fi

# ----- register Homepage tile (with widget) --------------------------------
if (( ! SKIP_HOMEPAGE_TILE )); then
  log "Registering Homepage tile (with Mattermost widget)..."

  homepage_ctid="$(find_ct_by_hostname homepage 2>/dev/null || true)"
  if [[ -z "$homepage_ctid" ]]; then
    log "  Homepage CT not found — skipping. (Run the addon again after the homepage CT is up.)"
  else
    services_file="$(pct exec "$homepage_ctid" -- bash -lc '
      for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage /var/lib/homepage/config; do
        if [[ -f "$d/services.yaml" ]]; then echo "$d/services.yaml"; exit 0; fi
      done
    ' 2>/dev/null | tail -n1)"

    if [[ -z "$services_file" ]]; then
      log "  Could not find services.yaml — skipping tile."
    else
      marker="# TD-Addon: mattermost"
      # Widget needs the personal-access-token AND the team id. If either is
      # missing, render the tile without the widget so the link still works.
      if [[ -n "$MM_TOKEN" && -n "$MM_TEAM_ID" ]]; then
        widget_block="        widget:
          type: mattermost
          url: http://$HOSTNAME:8065
          key: $MM_TOKEN
          teamId: $MM_TEAM_ID"
      else
        widget_block="        # widget skipped: personal access token or team id missing"
      fi

      tile_block="- Communication:
    - Mattermost:
        href: http://$HOSTNAME:8065
        description: Self-hosted team chat
        icon: mattermost.png
$widget_block"

      # Surgical block-replace if marker already exists, otherwise append
      if (( ! DRY_RUN )) && pct exec "$homepage_ctid" -- grep -qF "$marker" "$services_file" 2>/dev/null; then
        log "  Updating existing Mattermost tile..."
        run "pct exec $homepage_ctid -- bash -lc \"awk -v m='$marker' '
          \\\$0 ~ m { in_block=1; next }
          in_block && \\\$0 ~ /^# TD-Addon:/ { in_block=0 }
          !in_block { print }
        ' '$services_file' > /tmp/services.yaml.new && mv /tmp/services.yaml.new '$services_file'\""
      fi

      run "printf '\\n%s\\n%s\\n' '$marker' '$tile_block' | pct exec $homepage_ctid -- tee -a '$services_file' >/dev/null"
      run "pct exec $homepage_ctid -- bash -lc 'systemctl restart homepage 2>/dev/null || systemctl restart gethomepage 2>/dev/null || true'"
    fi
  fi
fi

# ----- save MM token + bot creds to /root/td-tokens.txt for the user -------
# Both admin PAT (for Homepage widget) and bot creds (for pi automation) land
# here. configure_pi_host reads MATTERMOST_BOT_TOKEN to export it as an env
# var in ollama-pi-agent's /root/.bashrc, so pi sees it as $MATTERMOST_BOT_TOKEN.
#
# Note: write whatever we have, even if some fields are empty. Earlier
# revisions gated the entire append on MM_TOKEN (admin PAT) being set,
# which meant a partial run (bot created OK but admin PAT mint failed)
# wrote NOTHING — bot creds were lost. Now each field stands on its own;
# configure_pi_host's exporter handles empty values gracefully (just
# skips that line in bashrc).
if [[ -f "$TOKENS_FILE" ]] && (( ! DRY_RUN )); then
  # If td-tokens.txt already has MATTERMOST_* lines from a prior run,
  # strip them first so the file stays canonical (no stale duplicates).
  if grep -q "^MATTERMOST_" "$TOKENS_FILE"; then
    log "Stripping prior MATTERMOST_* entries from $TOKENS_FILE..."
    sed -i '/^MATTERMOST_/d' "$TOKENS_FILE"
    # Also collapse any resulting double-blank lines
    sed -i '/^$/N;/^\n$/D' "$TOKENS_FILE"
  fi

  log "Appending Mattermost details to $TOKENS_FILE..."
  cat >> "$TOKENS_FILE" <<EOF

MATTERMOST_URL=http://$MM_IP:8065
MATTERMOST_TOKEN=${MM_TOKEN:-}
MATTERMOST_TEAM_ID=${MM_TEAM_ID:-}
MATTERMOST_BOT_USER_ID=${MM_BOT_USER_ID:-}
MATTERMOST_BOT_TOKEN=${MM_BOT_TOKEN:-}
MATTERMOST_BOT_CHANNEL_ID=${MM_BOT_CHANNEL_ID:-}
MATTERMOST_TOWNSQUARE_CHANNEL_ID=${MM_TOWNSQUARE_CHANNEL_ID:-}
MATTERMOST_AICHAT_CHANNEL_ID=${MM_AICHAT_CHANNEL_ID:-}
EOF

  # Surface which values are populated so the user sees the partial-success
  # state without having to cat the file.
  log "  Wrote — populated fields:"
  for var in MM_TOKEN MM_TEAM_ID MM_BOT_USER_ID MM_BOT_TOKEN MM_BOT_CHANNEL_ID MM_TOWNSQUARE_CHANNEL_ID MM_AICHAT_CHANNEL_ID; do
    if [[ -n "${!var:-}" ]]; then
      log "    ${var/MM_/MATTERMOST_} ✓"
    else
      warn "    ${var/MM_/MATTERMOST_} (empty)"
    fi
  done
elif [[ ! -f "$TOKENS_FILE" ]]; then
  warn "$TOKENS_FILE doesn't exist — skipping MM creds save."
  warn "  (Was configure-apps.sh ever run? It creates td-tokens.txt at the end of its run.)"
  warn "  You can still recover the creds manually — they're inside the Mattermost UI."
fi

# ----- done ---------------------------------------------------------------
log "================================================================"
log "==> Done."
log " "
log "  Hostname:      $HOSTNAME"
log "  CTID:          $CTID"
log "  URL:           http://$HOSTNAME:8065  (or http://$MM_IP:8065 on LAN)"
log "  Admin login:   $ADMIN_USER / (your password)"
log "  Default team:  $TEAM_NAME"
if [[ -n "$MM_TOKEN" ]]; then
  log "  PAT length:    ${#MM_TOKEN}  (saved to $TOKENS_FILE if it existed)"
fi
log "================================================================"
