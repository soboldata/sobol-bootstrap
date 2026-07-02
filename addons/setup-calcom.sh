#!/usr/bin/env bash
# setup-calcom.sh — Configure a Cal.com self-hosted CT.
#
# Runs Cal.com in a Docker CT via docker-compose, pointing DATABASE_URL at
# the shared Postgres CT (setup-postgres-shared.sh provisions calcom_db +
# calcom_user). Prisma migrations run inside the container after first
# start.
#
# Follows the additive-composition rules (conventions.md §2.2):
#   - Detects existing install and reconfigures cleanly
#   - Docker + compose are idempotent by design
#   - NEXTAUTH_SECRET + CALENDSO_ENCRYPTION_KEY are generated ONCE and
#     persisted to tokens; regenerating would invalidate all existing
#     sessions AND make encrypted DB rows unreadable — hard fail if a
#     user tries to rotate without --redo-secrets
#
# Cal.com's self-hosting story is finicky. This addon uses the community
# calcom/docker repo pinned to a known-working commit; adjust if that
# repo moves further. See "Known caveats" below.
#
# Assumptions on entry:
#   - The Cal.com CT exists and Docker is installed inside it
#     (community-scripts ct/docker.sh, or the studio-stack bootstrap)
#   - The Postgres CT is reachable + has calcom_db + calcom_user
#     (setup-postgres-shared.sh writes CALCOM_DATABASE_URL to tokens)
#   - Cloudflared will later expose Cal.com publicly at cal.<DOMAIN>;
#     Cal.com runs plain HTTP on port 3000 internally
#
# What it does (idempotent at every step):
#   1. Reads CALCOM_CTID + DOMAIN + CALCOM_DATABASE_URL + SMTP_* +
#      NEXTAUTH_SECRET + CALENDSO_ENCRYPTION_KEY from studio-tokens.txt
#      (generates the secrets + persists on first run)
#   2. Pre-flight — CT exists + Docker is present inside CT
#   3. Ensures /opt/calcom exists with the calcom/docker compose files
#      (clones on first run at pinned commit; git fetch + checkout on
#      re-runs so the pin holds)
#   4. Writes /opt/calcom/.env fresh each run (tokens are source of truth)
#   5. Writes docker-compose.override.yml to (a) drop the bundled
#      postgres service and (b) pin the calcom image version
#   6. `docker compose up -d calcom` — starts Cal.com only
#   7. Waits for HTTP 200 on port 3000 (initial Prisma migrations are
#      slow on first run — up to 3 minutes)
#   8. Explicit `prisma migrate deploy` in the container as a belt-and-
#      suspenders step (Cal.com auto-migrates on start, but the migration
#      timing has been flaky across versions)
#   9. Registers a Homepage tile
#  10. Smoke test from PVE host
#  11. Success banner with next steps (browser signup at /auth/setup →
#      wire.sh in creator-studio creates the audit-consult +
#      compliance-discovery event types via API)
#
# Known caveats:
#   - Cal.com does NOT publish official prebuilt images anymore. The
#     official self-host path is "build from source." That's an
#     option-of-last-resort for us; instead we use the community image
#     from calcom/docker at a pinned tag. If that image goes stale, we
#     have to either bump the pin or switch to building-from-source.
#   - First-run Prisma migrations can take 90–180s. The smoke test
#     tolerates up to 3 min before warning.
#   - Cal.com's admin setup at /auth/setup is UI-only — no API path to
#     create the first admin (as of Cal.com v4.x). Documented as a
#     manual step in the success banner.
#
# Usage:
#   ./setup-calcom.sh                     # default
#   ./setup-calcom.sh --dry-run           # preview
#   ./setup-calcom.sh --redo-secrets      # REGENERATE secrets (destructive!
#                                            invalidates encrypted DB rows;
#                                            you'll need to reset user creds)
#   ./setup-calcom.sh --uninstall         # docker compose down + rm /opt/calcom
#   ./setup-calcom.sh --tokens-file PATH

set -Eeuo pipefail

# ----- args --------------------------------------------------------------
DRY_RUN=0
REDO_SECRETS=0
UNINSTALL=0
TOKENS_FILE="/root/studio-tokens.txt"

# Pinned versions — override with env vars to bump
CALCOM_IMAGE="${CALCOM_IMAGE:-calcom/cal.com:v4.5.4}"
CALCOM_REPO_URL="${CALCOM_REPO_URL:-https://github.com/calcom/docker.git}"
CALCOM_REPO_PIN="${CALCOM_REPO_PIN:-main}"   # bump to specific commit for stability

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --redo-secrets) REDO_SECRETS=1; shift ;;
    --uninstall)    UNINSTALL=1; shift ;;
    --tokens-file)  TOKENS_FILE="$2"; shift 2 ;;
    -h|--help)      sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[calcom]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[calcom]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[calcom]\033[0m %s\n" "$*" >&2; exit 1; }
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

CALCOM_CTID="$(read_token CALCOM_CTID || echo 302)"
DOMAIN="$(read_token DOMAIN || die "DOMAIN missing from $TOKENS_FILE")"

if (( ! UNINSTALL )); then
  CALCOM_DATABASE_URL="$(read_token CALCOM_DATABASE_URL || \
    die "CALCOM_DATABASE_URL missing — run setup-postgres-shared.sh first")"
  SMTP_HOST="$(read_token SMTP_HOST || die "SMTP_HOST missing (canonical schema)")"
  SMTP_PORT="$(read_token SMTP_PORT || echo 587)"
  SMTP_USERNAME="$(read_token SMTP_USERNAME || die "SMTP_USERNAME missing")"
  SMTP_PASSWORD="$(read_token SMTP_PASSWORD || die "SMTP_PASSWORD missing")"
  SMTP_FROM="$(read_token SMTP_FROM || echo "\"Cal.com\" <no-reply@${DOMAIN}>")"
fi

# CT check
pct status "$CALCOM_CTID" >/dev/null 2>&1 || \
  die "CT $CALCOM_CTID not found. Create it first (community-scripts ct/docker.sh)."
[[ "$(pct status "$CALCOM_CTID")" == *running* ]] || \
  { log "Starting CT $CALCOM_CTID..."; run "pct start $CALCOM_CTID"; sleep 3; }

log "  Cal.com CTID: $CALCOM_CTID"
log "  Domain:       cal.$DOMAIN"

# ----- uninstall path ----------------------------------------------------
if (( UNINSTALL )); then
  log "Uninstall mode — stopping stack, removing /opt/calcom..."
  run "pct exec $CALCOM_CTID -- bash -c 'cd /opt/calcom 2>/dev/null && docker compose down -v || true'"
  run "pct exec $CALCOM_CTID -- rm -rf /opt/calcom"
  log "Uninstall complete. Postgres DB (calcom_db) NOT touched — drop via"
  log "setup-postgres-shared.sh if you want to reclaim that space too."
  exit 0
fi

# ----- Verify Docker -----------------------------------------------------
log "Verifying Docker inside CT..."
if ! pct_exec "$CALCOM_CTID" "command -v docker >/dev/null && docker compose version >/dev/null 2>&1"; then
  die "Docker + compose not found in CT $CALCOM_CTID. \
Create the CT with community-scripts ct/docker.sh (or install manually) first."
fi

# ----- Detect install mode -----------------------------------------------
if pct_exec "$CALCOM_CTID" "test -d /opt/calcom/.git"; then
  MODE="RECONFIGURE"
  log "Existing /opt/calcom detected — RECONFIGURE mode."
else
  MODE="INSTALL"
  log "Fresh install — INSTALL mode."
fi

# ----- Clone or update the calcom/docker repo ----------------------------
if [[ "$MODE" == "INSTALL" ]]; then
  log "Cloning $CALCOM_REPO_URL → /opt/calcom (pin: $CALCOM_REPO_PIN)..."
  run "pct exec $CALCOM_CTID -- git clone $CALCOM_REPO_URL /opt/calcom"
  run "pct exec $CALCOM_CTID -- bash -c 'cd /opt/calcom && git checkout $CALCOM_REPO_PIN'"
else
  log "Updating /opt/calcom to pin $CALCOM_REPO_PIN..."
  run "pct exec $CALCOM_CTID -- bash -c 'cd /opt/calcom && git fetch --depth 50 origin && git checkout $CALCOM_REPO_PIN'"
fi

# ----- Secrets (NEXTAUTH_SECRET + CALENDSO_ENCRYPTION_KEY) --------------
# These MUST stay stable across restarts. Rotating CALENDSO_ENCRYPTION_KEY
# makes existing calendar-integration credentials unreadable (they're
# encrypted in the DB with this key). Only regenerate on explicit request.
NEXTAUTH_SECRET="$(read_token NEXTAUTH_SECRET || true)"
CALENDSO_ENCRYPTION_KEY="$(read_token CALENDSO_ENCRYPTION_KEY || true)"

if [[ -z "$NEXTAUTH_SECRET" ]] || (( REDO_SECRETS )); then
  (( REDO_SECRETS )) && warn "  --redo-secrets: rotating NEXTAUTH_SECRET (invalidates all sessions)"
  NEXTAUTH_SECRET="$(openssl rand -base64 32)"
  upsert_token NEXTAUTH_SECRET "$NEXTAUTH_SECRET"
  log "  Generated NEXTAUTH_SECRET"
else
  log "  Reusing NEXTAUTH_SECRET from tokens"
fi

if [[ -z "$CALENDSO_ENCRYPTION_KEY" ]]; then
  CALENDSO_ENCRYPTION_KEY="$(openssl rand -base64 24 | head -c 32)"
  upsert_token CALENDSO_ENCRYPTION_KEY "$CALENDSO_ENCRYPTION_KEY"
  log "  Generated CALENDSO_ENCRYPTION_KEY"
elif (( REDO_SECRETS )); then
  # Only rotate CALENDSO_ENCRYPTION_KEY if user is explicit. It's destructive.
  warn "  DESTRUCTIVE: --redo-secrets is rotating CALENDSO_ENCRYPTION_KEY."
  warn "  Existing calendar-integration credentials in the DB will be UNREADABLE."
  warn "  Users will need to re-connect Google/Outlook/etc. after this."
  read -rp "  Type 'ROTATE' to confirm: " confirm
  if [[ "$confirm" == "ROTATE" ]]; then
    CALENDSO_ENCRYPTION_KEY="$(openssl rand -base64 24 | head -c 32)"
    upsert_token CALENDSO_ENCRYPTION_KEY "$CALENDSO_ENCRYPTION_KEY"
    log "  Rotated CALENDSO_ENCRYPTION_KEY"
  else
    log "  Skipped rotation — keeping existing key."
  fi
else
  log "  Reusing CALENDSO_ENCRYPTION_KEY from tokens"
fi

# ----- Write .env --------------------------------------------------------
log "Writing /opt/calcom/.env..."

ENV_CONTENT="$(cat <<EOF
# GENERATED BY setup-calcom.sh — DO NOT EDIT BY HAND.
# Source of truth is $TOKENS_FILE; re-run the addon to regenerate.

# --- URLs ----------------------------------------------------------------
NEXTAUTH_URL=https://cal.$DOMAIN
NEXT_PUBLIC_WEBAPP_URL=https://cal.$DOMAIN
CALCOM_TELEMETRY_DISABLED=1

# --- Databases -----------------------------------------------------------
DATABASE_URL=$CALCOM_DATABASE_URL
DATABASE_DIRECT_URL=$CALCOM_DATABASE_URL

# --- Secrets -------------------------------------------------------------
NEXTAUTH_SECRET=$NEXTAUTH_SECRET
CALENDSO_ENCRYPTION_KEY=$CALENDSO_ENCRYPTION_KEY

# --- Mail (canonical SMTP_* schema) --------------------------------------
EMAIL_SERVER_HOST=$SMTP_HOST
EMAIL_SERVER_PORT=$SMTP_PORT
EMAIL_SERVER_USER=$SMTP_USERNAME
EMAIL_SERVER_PASSWORD=$SMTP_PASSWORD
EMAIL_FROM=$SMTP_FROM

# --- Ops -----------------------------------------------------------------
NODE_ENV=production
NEXT_PUBLIC_LICENSE_CONSENT=agree
EOF
)"

if (( ! DRY_RUN )); then
  echo "$ENV_CONTENT" | pct exec "$CALCOM_CTID" -- bash -c "cat > /opt/calcom/.env && chmod 600 /opt/calcom/.env"
else
  printf "[dry-run] would write /opt/calcom/.env (%d lines)\n" "$(echo "$ENV_CONTENT" | wc -l)"
fi

# ----- Write docker-compose.override.yml ---------------------------------
log "Writing docker-compose.override.yml (image pin + drop bundled postgres)..."

OVERRIDE_CONTENT="$(cat <<EOF
# GENERATED BY setup-calcom.sh — DO NOT EDIT BY HAND.
# Pins the calcom image + disables the bundled postgres service since
# we use the shared postgres CT via DATABASE_URL (.env).

services:
  calcom:
    image: $CALCOM_IMAGE
    # Original compose has depends_on: database (postgres) — drop it.
    depends_on: []
    ports:
      - "0.0.0.0:3000:3000"

  database:
    # Bundled postgres — we use shared postgres CT instead.
    profiles: ["donotuse"]
EOF
)"

if (( ! DRY_RUN )); then
  echo "$OVERRIDE_CONTENT" | pct exec "$CALCOM_CTID" -- bash -c "cat > /opt/calcom/docker-compose.override.yml"
else
  printf "[dry-run] would write /opt/calcom/docker-compose.override.yml\n"
fi

# ----- Start the stack ---------------------------------------------------
log "docker compose up -d calcom..."
run "pct exec $CALCOM_CTID -- bash -c 'cd /opt/calcom && docker compose up -d calcom --remove-orphans'"

# ----- Wait for HTTP (long — Prisma migrations on first run) -------------
log "Waiting for Cal.com HTTP response (initial Prisma migrations take 90-180s)..."
CALCOM_READY=0
for i in $(seq 1 180); do
  if pct_exec "$CALCOM_CTID" "curl -sf -o /dev/null -m 3 http://localhost:3000/" 2>/dev/null; then
    log "  Cal.com responding at http://localhost:3000/ (CT internal, ${i}s)"
    CALCOM_READY=1
    break
  fi
  # Print progress every 30s so operator sees this isn't stuck
  if (( i % 30 == 0 )); then
    log "  ...still waiting (${i}s / 180s max)"
  fi
  sleep 1
done
(( CALCOM_READY )) || warn "Cal.com didn't respond after 180s — check 'docker compose logs calcom' inside CT"

# ----- Belt-and-suspenders Prisma migrate --------------------------------
# Cal.com's entrypoint runs migrations on start, but the timing is
# flaky across versions. Run explicitly as a safety net.
log "Running prisma migrate deploy (belt-and-suspenders)..."
if (( ! DRY_RUN )); then
  pct exec "$CALCOM_CTID" -- bash -c \
    "cd /opt/calcom && docker compose exec -T calcom npx prisma migrate deploy --schema=/calcom/packages/prisma/schema.prisma" 2>&1 \
    | sed 's/^/    /' || warn "Prisma migrate returned non-zero — usually harmless if migrations already ran. Check logs if signup fails."
fi

# ----- Homepage tile -----------------------------------------------------
HOMEPAGE_CTID="$(read_token HOMEPAGE_CTID 2>/dev/null || echo 110)"
if pct status "$HOMEPAGE_CTID" >/dev/null 2>&1; then
  log "Registering Homepage tile..."
  CALCOM_IP="$(pct exec "$CALCOM_CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
  TILE_BLOCK="$(cat <<EOF

# TD-Addon: calcom
- Scheduling:
    - Cal.com:
        href: https://cal.$DOMAIN
        description: Self-hosted scheduling
        icon: cal-com.png
        siteMonitor: http://$CALCOM_IP:3000
EOF
)"
  if (( ! DRY_RUN )); then
    if ! pct_exec "$HOMEPAGE_CTID" "grep -q '# TD-Addon: calcom' /etc/homepage/services.yaml 2>/dev/null"; then
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
CALCOM_IP="${CALCOM_IP:-$(pct exec "$CALCOM_CTID" -- hostname -I 2>/dev/null | awk '{print $1}')}"
if curl -sf -m 5 -o /dev/null "http://${CALCOM_IP}:3000/"; then
  log "Smoke test: ✓ Cal.com responding at http://${CALCOM_IP}:3000/"
else
  warn "Smoke test: ✗ Cal.com not responding from PVE host. Inside CT: 'pct enter $CALCOM_CTID' → 'cd /opt/calcom && docker compose logs calcom'"
fi

# ----- Success banner ----------------------------------------------------
log "================================================================"
log "Cal.com setup complete ($MODE)."
log " "
log "  Public URL (post-Cloudflared): https://cal.$DOMAIN"
log "  Internal:                       http://$CALCOM_IP:3000"
log " "
log "Next steps (post-Cloudflared):"
log "  1. Complete first-run admin setup at https://cal.$DOMAIN/auth/setup"
log "     (UI only — no API path for the initial admin)"
log "  2. Configure Google Calendar / Outlook / Zoom integrations as needed"
log "     (Settings → Apps → Install)"
log "  3. Stack-specific event-type creation (audit-consult,"
log "     compliance-discovery) belongs in stacks/creator-studio/wire.sh"
log "     — that's the wiring layer, not the addon."
log "  4. Import calcom-booking-to-mattermost.json into n8n if not done."
log "     Register Cal.com webhook → n8n:"
log "       Cal.com: Settings → Developer → Webhooks → New"
log "         URL: http://<n8n-ip>:5678/webhook/calcom-booking"
log "         Trigger: BOOKING_CREATED"
log "================================================================"
