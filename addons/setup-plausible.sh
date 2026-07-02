#!/usr/bin/env bash
# setup-plausible.sh — Configure a Plausible Community Edition CT.
#
# Runs Plausible + ClickHouse via docker-compose inside the Plausible CT,
# pointing DATABASE_URL at the shared Postgres CT (which setup-postgres-shared.sh
# has already provisioned `plausible_db` + `plausible_user` on).
#
# Follows the additive-composition rules (conventions.md §2.2):
#   - Detects existing install and reconfigures cleanly, doesn't clobber
#   - Docker + compose are idempotent by design
#   - SECRET_KEY_BASE is generated once and persisted to tokens; re-runs use it
#
# Assumptions on entry:
#   - The Plausible CT exists and Docker is installed inside it
#     (community-scripts ct/docker.sh, or the studio-stack bootstrap)
#   - The Postgres CT is reachable on the tailnet and has plausible_db +
#     plausible_user (setup-postgres-shared.sh writes PLAUSIBLE_DATABASE_URL
#     to the tokens file — this addon reads it)
#   - Cloudflared will later expose Plausible publicly at
#     analytics.<DOMAIN> and tracking.<DOMAIN>; Plausible runs plain HTTP
#     on port 8000 internally
#
# What it does (idempotent at every step):
#   1. Reads PLAUSIBLE_CTID + DOMAIN + PLAUSIBLE_DATABASE_URL + SMTP_* +
#      PLAUSIBLE_SECRET_KEY_BASE from studio-tokens.txt (generates the
#      secret + persists on first run)
#   2. Pre-flight — CT exists + Docker is present inside CT
#   3. Ensures /opt/plausible exists with the community-edition compose
#      files (clones on first run, `git pull` on re-run)
#   4. Writes /opt/plausible/.env fresh each run — the tokens file is
#      the source of truth, .env is a projection of it
#   5. Writes docker-compose.override.yml that: (a) drops the built-in
#      postgres service (we use the shared external DB) and (b) hard-pins
#      the plausible + clickhouse image versions so the customer's
#      install can't drift silently on a container restart
#   6. `docker compose up -d` — starts plausible + clickhouse only
#   7. Waits for HTTP 200 on port 8000 (up to 60s — Plausible's initial
#      DB migration is slow on first run)
#   8. Registers a Homepage tile (idempotent per convention)
#   9. Smoke test from PVE host
#  10. Success banner with next steps (browser signup → add site → mint
#      API key → paste tracking snippet into Ghost Code Injection)
#
# Usage:
#   ./setup-plausible.sh                     # default
#   ./setup-plausible.sh --dry-run           # preview without changes
#   ./setup-plausible.sh --redo-secret       # regenerate SECRET_KEY_BASE
#                                              (invalidates existing sessions)
#   ./setup-plausible.sh --uninstall         # docker compose down + rm /opt/plausible
#   ./setup-plausible.sh --tokens-file PATH  # override tokens file location

set -Eeuo pipefail

# ----- args --------------------------------------------------------------
DRY_RUN=0
REDO_SECRET=0
UNINSTALL=0
TOKENS_FILE="/root/studio-tokens.txt"

# Pinned versions — override with env vars if you need to bump
PLAUSIBLE_IMAGE="${PLAUSIBLE_IMAGE:-ghcr.io/plausible/community-edition:v2.1.4}"
CLICKHOUSE_IMAGE="${CLICKHOUSE_IMAGE:-clickhouse/clickhouse-server:24.3.6.48-alpine}"
PLAUSIBLE_REPO_URL="${PLAUSIBLE_REPO_URL:-https://github.com/plausible/community-edition.git}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --redo-secret)  REDO_SECRET=1; shift ;;
    --uninstall)    UNINSTALL=1; shift ;;
    --tokens-file)  TOKENS_FILE="$2"; shift 2 ;;
    -h|--help)      sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[plausible]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[plausible]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[plausible]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct >/dev/null || die "pct not found — PVE host required."
[[ -f "$TOKENS_FILE" ]] || die "$TOKENS_FILE missing — run bootstrap first."

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

upsert_token() {
  local key="$1" val="$2"
  touch "$TOKENS_FILE"; chmod 600 "$TOKENS_FILE"
  if grep -q "^$key=" "$TOKENS_FILE"; then
    sed -i "s|^$key=.*|$key=$val|" "$TOKENS_FILE"
  else
    echo "$key=$val" >> "$TOKENS_FILE"
  fi
}

pct_exec() {
  local ctid="$1"; shift
  pct exec "$ctid" -- bash -c "$*"
}

# ----- pre-flight --------------------------------------------------------
log "Pre-flight..."

PLAUSIBLE_CTID="$(read_token PLAUSIBLE_CTID || echo 301)"
DOMAIN="$(read_token DOMAIN || die "DOMAIN missing from $TOKENS_FILE")"

if (( ! UNINSTALL )); then
  PLAUSIBLE_DATABASE_URL="$(read_token PLAUSIBLE_DATABASE_URL || \
    die "PLAUSIBLE_DATABASE_URL missing — run setup-postgres-shared.sh first")"
  SMTP_HOST="$(read_token SMTP_HOST || die "SMTP_HOST missing (canonical schema)")"
  SMTP_PORT="$(read_token SMTP_PORT || echo 587)"
  SMTP_USERNAME="$(read_token SMTP_USERNAME || die "SMTP_USERNAME missing")"
  SMTP_PASSWORD="$(read_token SMTP_PASSWORD || die "SMTP_PASSWORD missing")"
  SMTP_FROM="$(read_token SMTP_FROM || echo "\"Plausible\" <no-reply@${DOMAIN}>")"
fi

# CT check
pct status "$PLAUSIBLE_CTID" >/dev/null 2>&1 || \
  die "CT $PLAUSIBLE_CTID not found. Create it first (community-scripts ct/docker.sh)."
[[ "$(pct status "$PLAUSIBLE_CTID")" == *running* ]] || \
  { log "Starting CT $PLAUSIBLE_CTID..."; run "pct start $PLAUSIBLE_CTID"; sleep 3; }

log "  Plausible CTID: $PLAUSIBLE_CTID"
log "  Domain:         analytics.$DOMAIN + tracking.$DOMAIN"

# ----- uninstall path ----------------------------------------------------
if (( UNINSTALL )); then
  log "Uninstall mode — stopping stack, removing /opt/plausible..."
  run "pct exec $PLAUSIBLE_CTID -- bash -c 'cd /opt/plausible 2>/dev/null && docker compose down -v || true'"
  run "pct exec $PLAUSIBLE_CTID -- rm -rf /opt/plausible"
  log "Uninstall complete. Postgres DB (plausible_db) NOT touched — drop it"
  log "via setup-postgres-shared.sh if you want to reclaim that space too."
  exit 0
fi

# ----- Verify Docker is present ------------------------------------------
log "Verifying Docker inside CT..."
if ! pct_exec "$PLAUSIBLE_CTID" "command -v docker >/dev/null && docker compose version >/dev/null 2>&1"; then
  die "Docker + compose not found in CT $PLAUSIBLE_CTID. \
Create the CT with community-scripts ct/docker.sh (or install manually) before running this."
fi

# ----- Detect install mode -----------------------------------------------
if pct_exec "$PLAUSIBLE_CTID" "test -d /opt/plausible/.git"; then
  MODE="RECONFIGURE"
  log "Existing /opt/plausible detected — RECONFIGURE mode."
else
  MODE="INSTALL"
  log "Fresh install — INSTALL mode."
fi

# ----- Clone or pull the community-edition repo --------------------------
if [[ "$MODE" == "INSTALL" ]]; then
  log "Cloning $PLAUSIBLE_REPO_URL → /opt/plausible..."
  run "pct exec $PLAUSIBLE_CTID -- git clone --depth 1 $PLAUSIBLE_REPO_URL /opt/plausible"
else
  log "Pulling latest of /opt/plausible..."
  run "pct exec $PLAUSIBLE_CTID -- bash -c 'cd /opt/plausible && git pull --ff-only'"
fi

# ----- SECRET_KEY_BASE ---------------------------------------------------
PLAUSIBLE_SECRET_KEY_BASE="$(read_token PLAUSIBLE_SECRET_KEY_BASE || true)"
if [[ -z "$PLAUSIBLE_SECRET_KEY_BASE" ]] || (( REDO_SECRET )); then
  if (( REDO_SECRET )); then
    warn "  --redo-secret set — rotating SECRET_KEY_BASE (invalidates active sessions)"
  fi
  PLAUSIBLE_SECRET_KEY_BASE="$(openssl rand -hex 32)"
  upsert_token PLAUSIBLE_SECRET_KEY_BASE "$PLAUSIBLE_SECRET_KEY_BASE"
  log "  Generated new SECRET_KEY_BASE"
else
  log "  Reusing existing SECRET_KEY_BASE from tokens"
fi

# ----- Write .env --------------------------------------------------------
log "Writing /opt/plausible/.env..."

# Build the .env content locally then push into CT — avoids interpolation
# hell with shell/docker/plausible substitution rules.
ENV_CONTENT="$(cat <<EOF
# GENERATED BY setup-plausible.sh — DO NOT EDIT BY HAND.
# Source of truth is $TOKENS_FILE; re-run the addon to regenerate.

BASE_URL=https://analytics.$DOMAIN
SECRET_KEY_BASE=$PLAUSIBLE_SECRET_KEY_BASE

# --- Databases -----------------------------------------------------------
# Postgres lives in the shared postgres CT (setup-postgres-shared.sh)
DATABASE_URL=$PLAUSIBLE_DATABASE_URL
# ClickHouse runs in this CT via docker-compose (below)
CLICKHOUSE_DATABASE_URL=http://plausible_events_db:8123/plausible_events_db

# --- Mail (canonical SMTP_* schema) --------------------------------------
MAILER_ADAPTER=Bamboo.Mua.Adapter
SMTP_HOST_ADDR=$SMTP_HOST
SMTP_HOST_PORT=$SMTP_PORT
SMTP_USER_NAME=$SMTP_USERNAME
SMTP_USER_PWD=$SMTP_PASSWORD
SMTP_HOST_SSL_ENABLED=false
MAILER_EMAIL=$SMTP_FROM

# --- Ops -----------------------------------------------------------------
DISABLE_REGISTRATION=invite_only   # first admin signup allowed; then locked
LOG_LEVEL=info
EOF
)"

if (( ! DRY_RUN )); then
  echo "$ENV_CONTENT" | pct exec "$PLAUSIBLE_CTID" -- bash -c "cat > /opt/plausible/.env && chmod 600 /opt/plausible/.env"
else
  printf "[dry-run] would write /opt/plausible/.env (%d lines)\n" "$(echo "$ENV_CONTENT" | wc -l)"
fi

# ----- Write docker-compose.override.yml ---------------------------------
# Two jobs: (1) hard-pin image versions so container recreation doesn't
# silently upgrade, (2) exclude the built-in postgres service since we
# use the shared one.
log "Writing docker-compose.override.yml (image pins + drop bundled postgres)..."

OVERRIDE_CONTENT="$(cat <<EOF
# GENERATED BY setup-plausible.sh — DO NOT EDIT BY HAND.
# Image pins live here so 'docker compose pull' can't silently upgrade.
# The bundled postgres service is disabled via profile so plausible uses
# the shared postgres CT via DATABASE_URL (.env).

services:
  plausible:
    image: $PLAUSIBLE_IMAGE
    # Original compose file has depends_on: plausible_db (postgres).
    # Override the whole list to drop it — we use external postgres.
    depends_on:
      plausible_events_db:
        condition: service_healthy
    ports:
      - "0.0.0.0:8000:8000"

  plausible_events_db:
    image: $CLICKHOUSE_IMAGE

  plausible_db:
    # Bundled postgres — we use shared postgres CT instead.
    # profile == 'donotuse' means it's skipped by default \`docker compose up\`.
    profiles: ["donotuse"]
EOF
)"

if (( ! DRY_RUN )); then
  echo "$OVERRIDE_CONTENT" | pct exec "$PLAUSIBLE_CTID" -- bash -c "cat > /opt/plausible/docker-compose.override.yml"
else
  printf "[dry-run] would write /opt/plausible/docker-compose.override.yml\n"
fi

# ----- Start the stack ---------------------------------------------------
log "docker compose up -d..."
run "pct exec $PLAUSIBLE_CTID -- bash -c 'cd /opt/plausible && docker compose up -d --remove-orphans'"

# ----- Wait for HTTP -----------------------------------------------------
log "Waiting for Plausible HTTP response (initial migration is slow on first install)..."
for i in $(seq 1 60); do
  if pct_exec "$PLAUSIBLE_CTID" "curl -sf -o /dev/null -m 3 http://localhost:8000/" 2>/dev/null; then
    log "  Plausible responding at http://localhost:8000/ (CT internal, ${i}s)"
    break
  fi
  [[ $i -eq 60 ]] && warn "Plausible didn't respond after 60s — check 'docker compose logs plausible' inside CT"
  sleep 1
done

# ----- Homepage tile -----------------------------------------------------
HOMEPAGE_CTID="$(read_token HOMEPAGE_CTID 2>/dev/null || echo 110)"
if pct status "$HOMEPAGE_CTID" >/dev/null 2>&1; then
  log "Registering Homepage tile..."
  PLAUSIBLE_IP="$(pct exec "$PLAUSIBLE_CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
  TILE_BLOCK="$(cat <<EOF

# TD-Addon: plausible
- Analytics:
    - Plausible:
        href: https://analytics.$DOMAIN
        description: Privacy-first analytics
        icon: plausible-analytics.png
        siteMonitor: http://$PLAUSIBLE_IP:8000
EOF
)"
  if (( ! DRY_RUN )); then
    if ! pct_exec "$HOMEPAGE_CTID" "grep -q '# TD-Addon: plausible' /etc/homepage/services.yaml 2>/dev/null"; then
      echo "$TILE_BLOCK" | pct exec "$HOMEPAGE_CTID" -- bash -c "cat >> /etc/homepage/services.yaml"
      pct exec "$HOMEPAGE_CTID" -- systemctl restart homepage 2>/dev/null || true
      log "  Tile added."
    else
      log "  Tile already registered — skipping (idempotent)."
    fi
  fi
else
  log "Homepage CT not detected — skipping tile registration."
fi

# ----- Smoke test --------------------------------------------------------
PLAUSIBLE_IP="${PLAUSIBLE_IP:-$(pct exec "$PLAUSIBLE_CTID" -- hostname -I 2>/dev/null | awk '{print $1}')}"
if curl -sf -m 5 -o /dev/null "http://${PLAUSIBLE_IP}:8000/"; then
  log "Smoke test: ✓ Plausible responding at http://${PLAUSIBLE_IP}:8000/"
else
  warn "Smoke test: ✗ Plausible not responding from PVE host. Check inside CT: 'pct enter $PLAUSIBLE_CTID' then 'cd /opt/plausible && docker compose logs plausible'"
fi

# ----- Success banner ----------------------------------------------------
log "================================================================"
log "Plausible setup complete ($MODE)."
log " "
log "  Public URLs (post-Cloudflared):"
log "    https://analytics.$DOMAIN   ← dashboard + admin"
log "    https://tracking.$DOMAIN    ← the JS pixel host"
log "  Internal: http://$PLAUSIBLE_IP:8000"
log " "
log "Next steps (post-Cloudflared):"
log "  1. Register the first admin at https://analytics.$DOMAIN/register"
log "  2. Add '$DOMAIN' as a Site (Settings → Sites → Add Website)"
log "  3. Mint an API key (User settings → API Keys → New key)"
log "     Save to $TOKENS_FILE as: PLAUSIBLE_API_KEY=<key>"
log "  4. Paste the JS snippet into Ghost Code Injection → Site Header:"
log "       <script defer data-domain=\"$DOMAIN\" \\"
log "               src=\"https://tracking.$DOMAIN/js/script.js\"></script>"
log "  5. Import plausible-weekly-digest-to-mattermost.json into n8n"
log "================================================================"
