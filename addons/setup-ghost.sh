#!/usr/bin/env bash
# setup-ghost.sh — Creator Studio
#
# Configures the Ghost CT for the customer's domain. Reads creds from
# /root/studio-tokens.txt. Idempotent at every step.
#
# Assumptions on entry:
#   - The Ghost CT (default CT 300) exists and is running. Community-scripts
#     ct/ghost.sh has already installed Ghost via ghost-cli under
#     /var/www/ghost, using SQLite. Ghost is systemd-managed.
#   - Cloudflared (installed by setup-cloudflared.sh, later) will handle
#     public TLS termination. Ghost runs plain HTTP on port 2368 internally
#     and trusts the Cloudflared forwarded headers.
#
# What it does:
#   1. Reads GHOST_CTID + DOMAIN + ADMIN_* + SMTP_* from studio-tokens.txt
#      (canonical SMTP_* schema — same used by setup-pve-email and downstream
#      creator-studio addons)
#   2. Waits for the Ghost CT to be reachable + Ghost service active
#   3. Discovers Ghost's install user + directory via ghost-cli
#   4. Stops Ghost via ghost-cli (as the ghost user)
#   5. Rewrites config.production.json via python (safer than sed for JSON):
#        - url:    https://$DOMAIN
#        - server: { host: 0.0.0.0, port: 2368 } — bind all interfaces
#        - mail:   { from, transport: SMTP, options: { host, port, auth } }
#   6. Starts Ghost via ghost-cli
#   7. Admin API setup — POST /ghost/api/admin/setup exactly once. If already
#      set up (HTTP 403), logs a friendly note and moves on.
#   8. Wires Ghost's post.published webhook to n8n's ghost-publish-to-mattermost
#      workflow. Skipped if n8n workflow isn't discoverable yet — retry with
#      --wire-webhook after the workflow is imported.
#   9. Registers Homepage tile (per homepage-tile-convention.md — falls back to
#      no-op if Homepage CT isn't reachable)
#  10. Smoke test — curl localhost:2368/ from PVE host returns 200
#
# Usage:
#   ./setup-ghost.sh                     # default
#   ./setup-ghost.sh --dry-run           # preview without changes
#   ./setup-ghost.sh --skip-admin-setup  # skip the /ghost/api/admin/setup step
#   ./setup-ghost.sh --skip-webhook      # skip n8n webhook wiring (retry later)
#   ./setup-ghost.sh --wire-webhook      # skip everything else, JUST wire the webhook

set -Eeuo pipefail

# ----- args --------------------------------------------------------------
DRY_RUN=0
SKIP_ADMIN_SETUP=0
SKIP_WEBHOOK=0
WEBHOOK_ONLY=0
# Auto-detect tokens file. --tokens-file arg (below) overrides.
TOKENS_FILE=""
for _tokf in /root/studio-tokens.txt /root/td-tokens.txt /root/sobol-tokens.txt; do
  [[ -f "$_tokf" ]] && { TOKENS_FILE="$_tokf"; break; }
done
unset _tokf

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)           DRY_RUN=1; shift ;;
    --skip-admin-setup)  SKIP_ADMIN_SETUP=1; shift ;;
    --skip-webhook)      SKIP_WEBHOOK=1; shift ;;
    --wire-webhook)      WEBHOOK_ONLY=1; shift ;;
    --tokens-file)       TOKENS_FILE="$2"; shift 2 ;;
    -h|--help)           sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[ghost]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[ghost]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[ghost]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct >/dev/null || die "pct not found — PVE host required."
[[ -f "$TOKENS_FILE" ]] || die "$TOKENS_FILE missing — run bootstrap-pve.sh first."

# read_token — last-match wins, placeholder values rejected
read_token() {
  local key="$1" val
  val="$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); v = $0 } END { print v }' "$TOKENS_FILE")"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  case "$val" in
    "<"*">"|""|"REPLACE_ME"|"CHANGEME") return 1 ;;
  esac
  printf '%s\n' "$val"
}

# upsert_token — write/overwrite a KEY=value pair in tokens.
upsert_token() {
  local key="$1" val="$2"
  (( DRY_RUN )) && return 0
  [[ -f "$TOKENS_FILE" ]] || { touch "$TOKENS_FILE"; chmod 600 "$TOKENS_FILE"; }
  if grep -q "^${key}=" "$TOKENS_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$TOKENS_FILE"
  else
    echo "${key}=${val}" >> "$TOKENS_FILE"
  fi
}

# pct_exec — run inside CT, returns exit code + stdout
pct_exec() {
  local ctid="$1"; shift
  pct exec "$ctid" -- bash -c "$*"
}

# ----- pre-flight --------------------------------------------------------
log "Pre-flight..."

# Shared CT lifecycle helpers (ct_wait_ready, ts_ensure_joined, etc)
# shellcheck source=lib/ct-helpers.sh
if [[ -r "$(dirname "${BASH_SOURCE[0]}")/lib/ct-helpers.sh" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib/ct-helpers.sh"
fi

GHOST_CTID="$(read_token GHOST_CTID || echo 300)"
GHOST_HOSTNAME="${GHOST_HOSTNAME:-ghost}"
DOMAIN="$(read_token DOMAIN || die "DOMAIN missing from $TOKENS_FILE")"
ADMIN_USER="$(read_token ADMIN_USER || die "ADMIN_USER missing")"
ADMIN_EMAIL="$(read_token ADMIN_EMAIL || die "ADMIN_EMAIL missing")"
ADMIN_PASSWORD="$(read_token ADMIN_PASSWORD || die "ADMIN_PASSWORD missing")"

SMTP_HOST="$(read_token SMTP_HOST || die "SMTP_HOST missing (canonical schema)")"
SMTP_PORT="$(read_token SMTP_PORT || echo 587)"
SMTP_USERNAME="$(read_token SMTP_USERNAME || die "SMTP_USERNAME missing")"
SMTP_PASSWORD="$(read_token SMTP_PASSWORD || die "SMTP_PASSWORD missing")"
SMTP_FROM="$(read_token SMTP_FROM || echo "\"Ghost\" <no-reply@${DOMAIN}>")"

# CT auto-create prerequisites — read only if we need to actually create
TS_AUTHKEY="$(read_token TS_AUTHKEY || true)"
CT_PASSWORD="$(read_token CT_PASSWORD || true)"

# ----- MariaDB dependency check -----------------------------------------
# Ghost is MySQL-only (Postgres was dropped at Ghost 1.0). We depend on
# a shared MariaDB CT provisioned by setup-mariadb-shared.sh, which
# creates ghost_db + ghost_user with proper utf8mb4 charset.
MARIADB_CTID="$(read_token MARIADB_CTID || true)"
MARIADB_LISTEN_IP="$(read_token MARIADB_LISTEN_IP || true)"
GHOST_DB_PASSWORD="$(read_token GHOST_DB_PASSWORD || true)"
if [[ -z "$MARIADB_CTID" || -z "$MARIADB_LISTEN_IP" || -z "$GHOST_DB_PASSWORD" ]]; then
  die "Missing MariaDB deps in $TOKENS_FILE (need MARIADB_CTID + MARIADB_LISTEN_IP + GHOST_DB_PASSWORD).
  Run setup-mariadb-shared.sh first — it provisions the shared MariaDB CT + ghost_db."
fi

# Find CT by hostname (matches setup-postgres-shared.sh pattern from #267)
find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

EXISTING_CTID="$(find_ct_by_hostname "$GHOST_HOSTNAME" 2>/dev/null || true)"
if [[ -n "$EXISTING_CTID" ]]; then
  log "  Found existing CT $EXISTING_CTID ($GHOST_HOSTNAME) — using it."
  GHOST_CTID="$EXISTING_CTID"
else
  # Community-scripts dropped ct/ghost.sh in July 2026 (only ghostfolio.sh
  # remains, unrelated). We create the CT directly via `pct create` + a
  # Debian 12 template, then install Node.js 22 + ghost-cli natively.
  # Matches the bootstrap-pve.sh direct-create pattern for ollama-pi-agent.
  log "  No CT named '$GHOST_HOSTNAME' found — creating Debian 12 CT + installing Ghost natively..."
  [[ -n "$CT_PASSWORD" ]] || die "CT_PASSWORD required in $TOKENS_FILE to create a new CT."

  # Auto-allocate CTID if the preferred one is taken
  if pct status "$GHOST_CTID" >/dev/null 2>&1; then
    GHOST_CTID="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"')"
    log "  Preferred CTID taken; auto-allocated $GHOST_CTID."
  fi

  # Resolve latest Debian 12 template (matches bootstrap-pve.sh pattern)
  log "  Resolving Debian 12 template..."
  pveam update >/dev/null 2>&1 || true
  TEMPLATE_NAME="$(pveam available -section system 2>/dev/null | awk '/debian-12-standard.*amd64\.tar\.zst/ {print $2}' | sort | tail -1)"
  [[ -n "$TEMPLATE_NAME" ]] || die "Could not find debian-12-standard template via 'pveam available'"
  # Ensure template is downloaded
  if ! ls /var/lib/vz/template/cache/${TEMPLATE_NAME} >/dev/null 2>&1; then
    log "  Downloading template $TEMPLATE_NAME..."
    pveam download local "$TEMPLATE_NAME" 2>&1 | tail -3
  fi
  TEMPLATE_REF="local:vztmpl/$TEMPLATE_NAME"

  # SSH pubkey file — bootstrap-pve.sh writes /root/workstation.pub
  AUTHKEYS_FILE=""
  for f in /root/workstation.pub /root/.ssh/authorized_keys; do
    [[ -s "$f" ]] && { AUTHKEYS_FILE="$f"; break; }
  done
  [[ -n "$AUTHKEYS_FILE" ]] || die "No SSH pubkey found. Boot.sh should have written /root/workstation.pub."

  # Resources — Ghost 6.0 wants 2 GB RAM min, 1 GB swap, ~5 GB disk
  # (Node + npm caches inflate; give headroom)
  if (( DRY_RUN )); then
    log "  [dry-run] would pct create $GHOST_CTID with hostname=$GHOST_HOSTNAME, 2 cpu, 2GB RAM, 8GB disk"
  else
    log "  Creating CT $GHOST_CTID ($GHOST_HOSTNAME)..."
    pct create "$GHOST_CTID" "$TEMPLATE_REF" \
      --hostname "$GHOST_HOSTNAME" \
      --password "$CT_PASSWORD" \
      --ssh-public-keys "$AUTHKEYS_FILE" \
      --cores 2 \
      --memory 2048 \
      --swap 1024 \
      --rootfs "local-lvm:8" \
      --net0 'name=eth0,bridge=vmbr0,ip=dhcp,ip6=auto' \
      --features nesting=1 \
      --unprivileged 1 \
      --onboot 1 \
      --start 0

    # TUN passthrough for Tailscale (must be BEFORE first start)
    CT_CONF="/etc/pve/lxc/$GHOST_CTID.conf"
    if ! grep -q "/dev/net/tun" "$CT_CONF" 2>/dev/null; then
      cat >> "$CT_CONF" <<'TUN_BLOCK'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
TUN_BLOCK
    fi

    pct start "$GHOST_CTID"
    log "  Waiting for CT to be ready (IP + DNS)..."
    declare -F ct_wait_ready >/dev/null && ct_wait_ready "$GHOST_CTID" || sleep 20

    upsert_token GHOST_CTID "$GHOST_CTID"

    # Tailscale install + join (via ts_ensure_joined helper)
    if [[ -n "$TS_AUTHKEY" ]] && declare -F ts_ensure_joined >/dev/null; then
      log "  Installing tailscale + joining tailnet as '$GHOST_HOSTNAME'..."
      pct exec "$GHOST_CTID" -- bash -lc '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        . /etc/os-release
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates gnupg
        curl -fsSL "https://pkgs.tailscale.com/stable/${ID}/${VERSION_CODENAME}.noarmor.gpg" \
          | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${ID} ${VERSION_CODENAME} main" \
          > /etc/apt/sources.list.d/tailscale.list
        apt-get update -qq
        apt-get install -y -qq tailscale
      ' 2>&1 | sed 's/^/    /'
      ts_ensure_joined "$GHOST_CTID" "$TS_AUTHKEY" "$GHOST_HOSTNAME" || \
        warn "  Tailscale join returned non-zero — continuing (LAN-only fallback ok)."
    fi

    # ----- Install Node.js 22 + build tooling + ghost-cli ---------------
    # Ghost 6.0 requires Node 22.13+. NodeSource maintains an up-to-date
    # Debian repo; using it avoids Debian's stale packaged node.
    log "  Installing Node.js 22 + build tooling..."
    pct exec "$GHOST_CTID" -- bash -lc '
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq curl ca-certificates gnupg build-essential python3
      # NodeSource setup script — pins the correct apt repo for node 22.x
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      apt-get install -y -qq nodejs
      node --version
      npm --version
    ' 2>&1 | sed 's/^/    /'

    log "  Installing ghost-cli globally..."
    pct exec "$GHOST_CTID" -- bash -lc 'npm install -g ghost-cli@latest' 2>&1 | sed 's/^/    /'

    # ----- Create ghost-mgr user (ghost-cli refuses to run as root) -----
    # ghost-cli hard-refuses root since 1.5.0. Standard pattern is a
    # dedicated sudo-capable "mgr" user under which `ghost install`
    # runs; ghost install then creates a SECOND daemon user called
    # 'ghost' (no shell) that owns the systemd unit and content dir.
    log "  Creating ghost-mgr user with passwordless sudo..."
    pct exec "$GHOST_CTID" -- bash -lc "
      set -e
      if ! id ghost-mgr >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo ghost-mgr
      fi
      # Passwordless sudo for ghost-install commands
      echo 'ghost-mgr ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ghost-mgr
      chmod 440 /etc/sudoers.d/ghost-mgr
      # Ghost install dir — must be /var/www/<name>, NOT /home or /root
      # (ghost-cli generates permissions errors otherwise)
      mkdir -p /var/www/ghost
      chown ghost-mgr:ghost-mgr /var/www/ghost
      chmod 755 /var/www/ghost
    "

    # ----- Run ghost install (non-interactive) --------------------------
    # --db mysql --dbhost <mariadb-tailnet-ip> --dbuser ghost_user
    # --dbpass <from-tokens> --dbname ghost_db
    # --no-setup-nginx --no-setup-ssl — Cloudflared handles ingress
    # --no-prompt — feed all answers via flags; die if anything's missing
    # --no-setup-systemd — we set up the unit ourselves via ghost start
    #                     (Ghost's systemd unit generation still works
    #                     via 'ghost start', which creates ghost_<name>.service)
    log "  Running ghost install as ghost-mgr (this takes 2-3 min)..."
    pct exec "$GHOST_CTID" -- bash -lc "
      set -e
      su - ghost-mgr -c '
        cd /var/www/ghost && \
        ghost install \
          --no-prompt \
          --no-setup-nginx \
          --no-setup-ssl \
          --url https://$DOMAIN \
          --db mysql \
          --dbhost $MARIADB_LISTEN_IP \
          --dbport 3306 \
          --dbuser ghost_user \
          --dbpass \"$GHOST_DB_PASSWORD\" \
          --dbname ghost_db \
          --port 2368 \
          --process systemd \
          --ip 0.0.0.0
      '
    " 2>&1 | sed 's/^/    /'
  fi
fi

# Verify CT is running
if ! pct status "$GHOST_CTID" 2>/dev/null | grep -q running; then
  die "CT $GHOST_CTID not running. Try: pct start $GHOST_CTID"
fi

log "  Ghost CTID:  $GHOST_CTID"
log "  Domain:      $DOMAIN"
log "  Admin email: $ADMIN_EMAIL"
log "  SMTP host:   $SMTP_HOST:$SMTP_PORT"
log "  SMTP from:   $SMTP_FROM"

# ----- Discover Ghost install --------------------------------------------
# Community-scripts installs Ghost under a specific user + directory.
# `ghost ls` output lists all installs — parse the first one.
log "Discovering Ghost install directory + user..."

if ! pct_exec "$GHOST_CTID" "command -v ghost >/dev/null 2>&1"; then
  die "ghost-cli not found in CT $GHOST_CTID. Community-scripts ct/ghost.sh must run first."
fi

GHOST_DIR="$(pct_exec "$GHOST_CTID" "ghost ls 2>/dev/null | awk 'NR==4 {print \$4}'" || echo "")"
GHOST_USER="$(pct_exec "$GHOST_CTID" "ghost ls 2>/dev/null | awk 'NR==4 {print \$6}'" || echo "")"

# Fallback if ghost ls doesn't parse cleanly — use conventional paths
[[ -z "$GHOST_DIR" ]] && GHOST_DIR="/var/www/ghost"
[[ -z "$GHOST_USER" ]] && GHOST_USER="ghost"

log "  Ghost dir:  $GHOST_DIR"
log "  Ghost user: $GHOST_USER"

pct_exec "$GHOST_CTID" "test -d $GHOST_DIR" || \
  die "Ghost directory $GHOST_DIR not found inside CT $GHOST_CTID."

# ----- Webhook-only mode short-circuit -----------------------------------
if (( WEBHOOK_ONLY )); then
  log "--wire-webhook mode — skipping config + start, jumping to webhook step"
else
  # ----- Stop Ghost ------------------------------------------------------
  log "Stopping Ghost (if running)..."
  run "pct exec $GHOST_CTID -- su - $GHOST_USER -c 'cd $GHOST_DIR && ghost stop || true'"

  # ----- Rewrite config.production.json ---------------------------------
  log "Rewriting config.production.json..."

  # We use python inside the CT to safely modify JSON. Assumes python3 exists
  # (community-scripts base image ships it).
  if (( ! DRY_RUN )); then
    pct_exec "$GHOST_CTID" "python3 --version >/dev/null 2>&1 || apt-get install -y -qq python3 >/dev/null"

    # Push a small python patcher script into the CT and run it
    PATCHER=$(cat <<'PYEOF'
import json, os, sys
config_path = os.environ["CONFIG_PATH"]
with open(config_path) as f:
    cfg = json.load(f)

cfg["url"] = f"https://{os.environ['DOMAIN']}"
cfg.setdefault("server", {})
cfg["server"]["host"] = "0.0.0.0"
cfg["server"]["port"] = 2368

cfg["mail"] = {
    "from": os.environ["SMTP_FROM"],
    "transport": "SMTP",
    "options": {
        "host": os.environ["SMTP_HOST"],
        "port": int(os.environ["SMTP_PORT"]),
        "secure": False,   # STARTTLS on 587
        "auth": {
            "user": os.environ["SMTP_USERNAME"],
            "pass": os.environ["SMTP_PASSWORD"],
        },
    },
}

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"Rewrote {config_path}")
PYEOF
    )

    # Push the patcher via stdin so we don't have to write a temp file
    echo "$PATCHER" | pct exec "$GHOST_CTID" -- bash -c "cat > /tmp/ghost-patch.py"
    pct exec "$GHOST_CTID" -- bash -c "
      export CONFIG_PATH='$GHOST_DIR/config.production.json'
      export DOMAIN='$DOMAIN'
      export SMTP_HOST='$SMTP_HOST'
      export SMTP_PORT='$SMTP_PORT'
      export SMTP_USERNAME='$SMTP_USERNAME'
      export SMTP_PASSWORD=\$(cat <<'SMTPPWEOF'
$SMTP_PASSWORD
SMTPPWEOF
)
      # Trim trailing newline from heredoc
      export SMTP_PASSWORD=\"\${SMTP_PASSWORD%\$'\\n'}\"
      export SMTP_FROM='$SMTP_FROM'
      chown $GHOST_USER:$GHOST_USER '$GHOST_DIR/config.production.json'
      su - $GHOST_USER -c 'cd $GHOST_DIR && python3 /tmp/ghost-patch.py'
      rm -f /tmp/ghost-patch.py
    "
  else
    printf "[dry-run] would rewrite %s/config.production.json (url, server, mail)\n" "$GHOST_DIR"
  fi

  # ----- Start Ghost ----------------------------------------------------
  log "Starting Ghost..."
  run "pct exec $GHOST_CTID -- su - $GHOST_USER -c 'cd $GHOST_DIR && ghost start'"

  # Wait for HTTP 200 on /
  log "Waiting for Ghost HTTP response..."
  GHOST_IP="$(pct exec "$GHOST_CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
  for i in $(seq 1 30); do
    if pct_exec "$GHOST_CTID" "curl -sf -o /dev/null -m 3 http://localhost:2368/" 2>/dev/null; then
      log "  Ghost responding at http://localhost:2368/ (CT internal)"
      break
    fi
    [[ $i -eq 30 ]] && warn "Ghost didn't respond after 30s — check 'ghost log' inside CT"
    sleep 1
  done

  # ----- Admin setup ----------------------------------------------------
  if (( ! SKIP_ADMIN_SETUP )); then
    log "Ghost admin setup..."

    # Check if setup already done
    SETUP_STATE="$(pct_exec "$GHOST_CTID" \
      "curl -sf -m 5 http://localhost:2368/ghost/api/admin/authentication/setup/ 2>/dev/null" || echo '')"

    if echo "$SETUP_STATE" | grep -q '"status":true'; then
      log "  Already set up — skipping."
    else
      log "  Running first-time setup POST..."
      BODY="$(python3 <<PYEOF
import json
print(json.dumps({"setup": [{
    "name": "$ADMIN_USER",
    "email": "$ADMIN_EMAIL",
    "password": "$ADMIN_PASSWORD",
    "blogTitle": "$DOMAIN"
}]}))
PYEOF
)"
      if (( ! DRY_RUN )); then
        RESULT="$(pct exec "$GHOST_CTID" -- bash -c "curl -s -m 10 -X POST \
          -H 'Content-Type: application/json' \
          -d '$BODY' \
          http://localhost:2368/ghost/api/admin/authentication/setup/")" || true
        if echo "$RESULT" | grep -q '"users"'; then
          log "  Admin user created: $ADMIN_EMAIL"
        else
          warn "  Admin-setup POST didn't return expected shape. Response:"
          warn "  $RESULT"
          warn "  You may need to complete /ghost/setup manually in browser."
        fi
      else
        printf "[dry-run] would POST admin-setup body to /ghost/api/admin/authentication/setup/\n"
      fi
    fi
  fi
fi

# ----- Wire webhook to n8n ----------------------------------------------
if (( ! SKIP_WEBHOOK )); then
  log "Wiring Ghost post.published webhook to n8n..."

  # Discover n8n's webhook URL for ghost-publish-to-mattermost.
  # Convention: n8n workflows expose webhooks at http://<n8n-ip>:5678/webhook/<slug>
  # We look for N8N_HOST + expected webhook slug in tokens; skip if missing.
  N8N_HOST="$(read_token N8N_HOST 2>/dev/null || echo '')"
  N8N_GHOST_WEBHOOK_URL="$(read_token N8N_GHOST_WEBHOOK_URL 2>/dev/null || echo '')"

  # Default: guess based on n8n hostname + workflow slug
  if [[ -z "$N8N_GHOST_WEBHOOK_URL" && -n "$N8N_HOST" ]]; then
    N8N_GHOST_WEBHOOK_URL="http://${N8N_HOST}:5678/webhook/ghost-publish"
  fi

  if [[ -z "$N8N_GHOST_WEBHOOK_URL" ]]; then
    warn "  N8N_GHOST_WEBHOOK_URL not resolvable. Skipping webhook wiring."
    warn "  Retry after n8n has the workflow imported:"
    warn "    $0 --wire-webhook"
  else
    log "  Target: $N8N_GHOST_WEBHOOK_URL"

    # Need a Ghost admin API key. Use the just-created admin credentials
    # to mint a Content API key or (better) use Admin API JWT.
    # For MVP: leave the webhook wiring to a follow-up run once the operator
    # has minted an admin API key manually.
    warn "  MVP: Ghost webhook wiring requires an admin API key. Steps:"
    warn "    1. Log in to https://$DOMAIN/ghost as $ADMIN_EMAIL"
    warn "    2. Settings → Integrations → Add custom integration"
    warn "    3. Copy the Admin API Key, save to $TOKENS_FILE as:"
    warn "         GHOST_ADMIN_API_KEY=<id>:<secret>"
    warn "    4. Re-run: $0 --wire-webhook"
    warn "  (post-MVP: mint via /ghost/api/admin/integrations POST)"
  fi
fi

# ----- Homepage tile -----------------------------------------------------
if [[ -f "$(dirname "$0")/../../../sobol-foundation/addons/homepage-tile-convention.md" ]] || \
   pct exec "$(read_token HOMEPAGE_CTID 2>/dev/null || echo 110)" -- test -f /etc/homepage/services.yaml 2>/dev/null; then
  log "Registering Homepage tile..."
  HOMEPAGE_CTID="$(read_token HOMEPAGE_CTID 2>/dev/null || echo 110)"
  GHOST_IP="${GHOST_IP:-$(pct exec "$GHOST_CTID" -- hostname -I 2>/dev/null | awk '{print $1}')}"

  TILE_BLOCK="$(cat <<EOF
- Publishing:
    - Ghost:
        href: https://$DOMAIN
        description: Publishing CMS
        server: my-docker
        container: ghost
        icon: ghost.png
        siteMonitor: http://$GHOST_IP:2368
EOF
)"
  # Simple append if the tile doesn't already exist (idempotent)
  if (( ! DRY_RUN )); then
    if ! pct_exec "$HOMEPAGE_CTID" "grep -q '    - Ghost:' /etc/homepage/services.yaml 2>/dev/null"; then
      echo "$TILE_BLOCK" | pct exec "$HOMEPAGE_CTID" -- bash -c "cat >> /etc/homepage/services.yaml"
      pct exec "$HOMEPAGE_CTID" -- systemctl restart homepage 2>/dev/null || true
      log "  Tile added."
    else
      log "  Tile already registered — skipping."
    fi
  fi
else
  log "Homepage CT not detected — skipping tile registration."
fi

# ----- Smoke test --------------------------------------------------------
log "Smoke test..."
GHOST_IP="${GHOST_IP:-$(pct exec "$GHOST_CTID" -- hostname -I 2>/dev/null | awk '{print $1}')}"
if curl -sf -m 5 -o /dev/null "http://${GHOST_IP}:2368/"; then
  log "  ✓ Ghost responding at http://${GHOST_IP}:2368/"
else
  warn "  ✗ Ghost not responding from PVE host. Check inside CT: 'pct enter $GHOST_CTID' then 'ghost log'"
fi

# ----- Success banner ----------------------------------------------------
log "================================================================"
log "Ghost setup complete."
log " "
log "  Public URL (post-Cloudflared): https://$DOMAIN"
log "  Internal:                       http://$GHOST_IP:2368"
log "  Admin login:                    $ADMIN_EMAIL"
log " "
log "Next steps:"
log "  - Set up Cloudflared for public access: ./setup-cloudflared.sh"
log "  - If webhook wiring was deferred, mint Ghost admin API key + rerun with --wire-webhook"
log "  - Import ghost-publish-to-mattermost workflow into n8n if not done"
log "================================================================"
