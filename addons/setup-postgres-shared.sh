#!/usr/bin/env bash
# setup-postgres-shared.sh — Shared PostgreSQL CT for multiple apps.
#
# Configures a Postgres CT with per-app databases + per-app users
# (each app isolated in its own DB), binds postgres to the tailnet IP
# only (never the public LAN — security), and installs daily pg_dump
# backups with 14-day retention.
#
# CURRENT STATE (opinionated for creator-studio):
#   Creates `calcom_db` (owner: calcom_user) + `plausible_db` (owner:
#   plausible_user) — the two DBs creator-studio needs. Any stack that
#   composes Cal.com + Plausible reuses this as-is.
#
# FUTURE (when a third stack needs shared postgres with different DBs):
#   Generalize the DB list via a `POSTGRES_SHARED_DBS` tokens field or
#   `--db name:user` repeatable arg. For now the hardcoded pair matches
#   the only in-tree consumer, and the convention (§2.1) is willing to
#   accept a first-mover cost in return for shipping.
#
# What it does (idempotent at every step):
#   1. Reads POSTGRES_CTID + ADMIN_USER + ADMIN_PASSWORD from tokens
#   2. Waits for postgres CT up + service active
#   3. Reads or generates random passwords for calcom_user + plausible_user
#      (re-runs use existing passwords; first run generates + persists)
#   4. createdb calcom_db; createuser calcom_user; grant
#   5. createdb plausible_db; createuser plausible_user; grant
#   6. Edits postgresql.conf to bind only to tailnet IP (security)
#   7. Edits pg_hba.conf to allow tailnet-only connections with md5 auth
#      (markered block, idempotent — no dupe accumulation on re-runs)
#   8. Restarts postgres service
#   9. Writes CALCOM_DATABASE_URL + PLAUSIBLE_DATABASE_URL to tokens
#      (consumed by setup-calcom.sh + setup-plausible.sh)
#  10. Smoke-tests connections from inside the CT
#  11. Installs daily pg_dump cron to /var/backups/postgres-daily/ with
#      14-day retention (backup freshness reportable via the
#      td-health-watchdog eventually — planned extension)
#
# Usage:
#   ./setup-postgres-shared.sh                     # default
#   ./setup-postgres-shared.sh --dry-run           # preview
#   ./setup-postgres-shared.sh --redo-passwords    # regenerate user passwords

set -Eeuo pipefail

# ----- args --------------------------------------------------------------
DRY_RUN=0
REDO_PASSWORDS=0
TOKENS_FILE=""    # resolved below — accepts --tokens-file or auto-detects

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=1; shift ;;
    --redo-passwords)  REDO_PASSWORDS=1; shift ;;
    --tokens-file)     TOKENS_FILE="$2"; shift 2 ;;
    -h|--help)         sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[postgres-shared]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[postgres-shared]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[postgres-shared]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct >/dev/null || die "pct not found — PVE host required."

# Resolve tokens file. --tokens-file wins; else auto-detect in order:
#   /root/studio-tokens.txt   (legacy, when creator-studio was studio-stack)
#   /root/td-tokens.txt       (foundation — most common)
#   /root/sobol-tokens.txt    (Sobol Mirror overlay)
# Matches setup-stack.sh's tokens-file resolution order.
if [[ -z "$TOKENS_FILE" ]]; then
  for f in /root/studio-tokens.txt /root/td-tokens.txt /root/sobol-tokens.txt; do
    if [[ -f "$f" ]]; then TOKENS_FILE="$f"; break; fi
  done
fi
[[ -n "$TOKENS_FILE" && -f "$TOKENS_FILE" ]] \
  || die "No tokens file found. Tried /root/studio-tokens.txt, /root/td-tokens.txt, /root/sobol-tokens.txt.
  Pass --tokens-file <path> explicitly, or run bootstrap-pve.sh first."
log "Using tokens file: $TOKENS_FILE"

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

# ----- pre-flight --------------------------------------------------------
log "Pre-flight..."

POSTGRES_CTID="$(read_token POSTGRES_CTID || echo 303)"
ADMIN_USER="$(read_token ADMIN_USER || true)"
ADMIN_PASSWORD="$(read_token ADMIN_PASSWORD || true)"
DOMAIN="$(read_token DOMAIN || true)"

[[ -n "$ADMIN_USER" && -n "$ADMIN_PASSWORD" ]] || die "Need ADMIN_USER + ADMIN_PASSWORD in $TOKENS_FILE."

# Verify CT exists + running
if ! pct status "$POSTGRES_CTID" 2>/dev/null | grep -q running; then
  die "CT $POSTGRES_CTID not running. Run bootstrap-pve.sh first or 'pct start $POSTGRES_CTID'."
fi

# Get the postgres CT's tailnet IP for connection URLs
log "Resolving postgres tailnet IP..."
PG_TS_IP="$(pct exec "$POSTGRES_CTID" -- tailscale ip -4 2>/dev/null | head -1)"
PG_LAN_IP="$(pct exec "$POSTGRES_CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
log "  Tailnet IP: ${PG_TS_IP:-<none>}"
log "  LAN IP:     ${PG_LAN_IP:-<none>}"

# Prefer the tailnet IP, fall back to LAN if no tailscale
PG_LISTEN_IP="${PG_TS_IP:-$PG_LAN_IP}"
[[ -n "$PG_LISTEN_IP" ]] || die "Postgres CT has no usable IP. Check 'pct exec $POSTGRES_CTID -- ip a'"

# Wait for the postgres service to be up
log "Waiting for postgres service..."
if (( ! DRY_RUN )); then
  for i in {1..30}; do
    if pct exec "$POSTGRES_CTID" -- systemctl is-active postgresql 2>/dev/null | grep -q active; then
      log "  ✓ postgresql is active"
      break
    fi
    sleep 2
  done
fi

# Detect Postgres version (community-scripts default is currently PG 16)
PG_VERSION="$(pct exec "$POSTGRES_CTID" -- bash -lc 'ls /etc/postgresql/ 2>/dev/null | sort -n | tail -1' 2>/dev/null)"
[[ -n "$PG_VERSION" ]] || die "Couldn't detect PG version on CT $POSTGRES_CTID — is postgresql installed?"
log "  Postgres version: $PG_VERSION"
PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
HBA_CONF="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"

# ----- 1. generate or re-use per-app passwords --------------------------
log "Generating per-app database passwords..."

CALCOM_DB_PASSWORD="$(read_token CALCOM_DB_PASSWORD || true)"
PLAUSIBLE_DB_PASSWORD="$(read_token PLAUSIBLE_DB_PASSWORD || true)"

if [[ -z "$CALCOM_DB_PASSWORD" || $REDO_PASSWORDS -eq 1 ]]; then
  CALCOM_DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)"
  log "  Generated CALCOM_DB_PASSWORD (${#CALCOM_DB_PASSWORD} chars)"
fi
if [[ -z "$PLAUSIBLE_DB_PASSWORD" || $REDO_PASSWORDS -eq 1 ]]; then
  PLAUSIBLE_DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)"
  log "  Generated PLAUSIBLE_DB_PASSWORD (${#PLAUSIBLE_DB_PASSWORD} chars)"
fi

if (( ! DRY_RUN )); then
  upsert_token CALCOM_DB_PASSWORD "$CALCOM_DB_PASSWORD"
  upsert_token PLAUSIBLE_DB_PASSWORD "$PLAUSIBLE_DB_PASSWORD"
fi

# ----- 2. create dbs + users -------------------------------------------
log "Creating databases + users..."

# Build the SQL — uses DO blocks so it's idempotent (no errors on re-run)
SQL="$(cat <<EOF
-- Cal.com
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'calcom_user') THEN
    CREATE ROLE calcom_user WITH LOGIN PASSWORD '$CALCOM_DB_PASSWORD';
  ELSE
    ALTER ROLE calcom_user WITH PASSWORD '$CALCOM_DB_PASSWORD';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE calcom_db OWNER calcom_user ENCODING UTF8'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'calcom_db')\gexec

GRANT ALL PRIVILEGES ON DATABASE calcom_db TO calcom_user;

-- Plausible
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'plausible_user') THEN
    CREATE ROLE plausible_user WITH LOGIN PASSWORD '$PLAUSIBLE_DB_PASSWORD';
  ELSE
    ALTER ROLE plausible_user WITH PASSWORD '$PLAUSIBLE_DB_PASSWORD';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE plausible_db OWNER plausible_user ENCODING UTF8'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'plausible_db')\gexec

GRANT ALL PRIVILEGES ON DATABASE plausible_db TO plausible_user;

-- Useful in PG 15+: also grant on schema public for new DBs to work cleanly
\c calcom_db
GRANT ALL ON SCHEMA public TO calcom_user;

\c plausible_db
GRANT ALL ON SCHEMA public TO plausible_user;
EOF
)"

if (( ! DRY_RUN )); then
  # Write SQL to a file inside the CT, then run as postgres user (avoids
  # the pct exec quoting trap we hit on TD-Proxmox).
  echo "$SQL" | pct exec "$POSTGRES_CTID" -- tee /tmp/studio-pg-setup.sql >/dev/null
  pct exec "$POSTGRES_CTID" -- bash -lc 'sudo -u postgres psql -f /tmp/studio-pg-setup.sql' 2>&1 | tail -10
  pct exec "$POSTGRES_CTID" -- rm -f /tmp/studio-pg-setup.sql
fi

# ----- 3. configure postgresql.conf (bind to tailnet IP) ---------------
log "Editing $PG_CONF to bind to tailnet IP..."

# Build the listen_addresses value. We listen on localhost + the chosen IP.
LISTEN_ADDRS="localhost,$PG_LISTEN_IP"

if (( ! DRY_RUN )); then
  pct exec "$POSTGRES_CTID" -- bash -lc "
    set -e
    cp '$PG_CONF' '${PG_CONF}.bak.\$(date +%s)' 2>/dev/null || true
    if grep -q '^listen_addresses' '$PG_CONF'; then
      sed -i \"s|^listen_addresses.*|listen_addresses = '$LISTEN_ADDRS'|\" '$PG_CONF'
    elif grep -q '^#listen_addresses' '$PG_CONF'; then
      sed -i \"s|^#listen_addresses.*|listen_addresses = '$LISTEN_ADDRS'|\" '$PG_CONF'
    else
      echo \"listen_addresses = '$LISTEN_ADDRS'\" >> '$PG_CONF'
    fi
  "
  log "  ✓ listen_addresses = '$LISTEN_ADDRS'"
fi

# ----- 4. configure pg_hba.conf (allow tailnet, deny LAN-internet) ----
log "Editing $HBA_CONF for tailnet-only auth..."

# Tailscale CGNAT range is 100.64.0.0/10. RFC1918 ranges allowed because
# the PVE host's vmbr0 needs to reach postgres too (Plausible/Cal.com hit
# via service hostnames that resolve to LAN IPs on the bridge).

HBA_RULES="$(cat <<EOF

# studio-stack: per-app access scoped to specific DBs only
# (added by setup-postgres-shared.sh — comment out to revoke)
host    calcom_db       calcom_user       100.64.0.0/10     md5
host    calcom_db       calcom_user       10.0.0.0/8        md5
host    calcom_db       calcom_user       172.16.0.0/12     md5
host    calcom_db       calcom_user       192.168.0.0/16    md5
host    plausible_db    plausible_user    100.64.0.0/10     md5
host    plausible_db    plausible_user    10.0.0.0/8        md5
host    plausible_db    plausible_user    172.16.0.0/12     md5
host    plausible_db    plausible_user    192.168.0.0/16    md5
EOF
)"

if (( ! DRY_RUN )); then
  pct exec "$POSTGRES_CTID" -- bash -lc "
    set -e
    cp '$HBA_CONF' '${HBA_CONF}.bak.\$(date +%s)' 2>/dev/null || true
    # Strip any prior studio-stack block (markered by the comment) so we don't accumulate dupes
    sed -i '/# studio-stack: per-app access scoped to specific DBs only/,/^\$/d' '$HBA_CONF'
  "
  echo "$HBA_RULES" | pct exec "$POSTGRES_CTID" -- tee -a "$HBA_CONF" >/dev/null
  log "  ✓ pg_hba.conf updated (markered block, idempotent)"
fi

# ----- 5. restart postgres ---------------------------------------------
log "Restarting postgresql..."
run "pct exec $POSTGRES_CTID -- systemctl restart postgresql"
sleep 3

if (( ! DRY_RUN )); then
  if pct exec "$POSTGRES_CTID" -- systemctl is-active postgresql | grep -q active; then
    log "  ✓ postgresql is active"
  else
    die "  postgresql failed to restart — check 'pct exec $POSTGRES_CTID -- journalctl -u postgresql -n 30'"
  fi
fi

# ----- 6. smoke-test connections from inside the CT --------------------
log "Smoke-testing connections..."

if (( ! DRY_RUN )); then
  for db in calcom_db plausible_db; do
    user="${db%_db}_user"
    pw_var="$(echo "${user}_password" | tr 'a-z' 'A-Z' | sed 's/_USER_PASSWORD$/_DB_PASSWORD/')"
    pw="${!pw_var}"
    result="$(pct exec "$POSTGRES_CTID" -- bash -lc "PGPASSWORD='$pw' psql -h '$PG_LISTEN_IP' -U '$user' -d '$db' -tAc 'SELECT current_database(), current_user'" 2>&1)"
    if echo "$result" | grep -q "$db|$user"; then
      log "  ✓ $db connection works ($result)"
    else
      warn "  ✗ $db connection failed: $result"
    fi
  done
fi

# ----- 7. write connection URLs to studio-tokens.txt -------------------
log "Persisting connection URLs to $TOKENS_FILE..."

CALCOM_DATABASE_URL="postgresql://calcom_user:$CALCOM_DB_PASSWORD@$PG_LISTEN_IP:5432/calcom_db"
PLAUSIBLE_DATABASE_URL="postgresql://plausible_user:$PLAUSIBLE_DB_PASSWORD@$PG_LISTEN_IP:5432/plausible_db"

if (( ! DRY_RUN )); then
  upsert_token CALCOM_DATABASE_URL "$CALCOM_DATABASE_URL"
  upsert_token PLAUSIBLE_DATABASE_URL "$PLAUSIBLE_DATABASE_URL"
  upsert_token POSTGRES_LISTEN_IP "$PG_LISTEN_IP"
  upsert_token POSTGRES_VERSION "$PG_VERSION"
fi

# ----- 8. daily pg_dump backup cron ------------------------------------
log "Installing daily pg_dump cron..."

if (( ! DRY_RUN )); then
  pct exec "$POSTGRES_CTID" -- bash -lc "
    mkdir -p /var/backups/postgres-daily
    cat > /etc/cron.daily/studio-pg-backup <<'EOF'
#!/bin/sh
# Daily Studio Stack postgres backup (installed by setup-postgres-shared.sh)
set -e
DEST=/var/backups/postgres-daily
mkdir -p \$DEST
TS=\$(date +%Y-%m-%d_%H%M%S)
sudo -u postgres pg_dump --clean --if-exists --quote-all-identifiers calcom_db    | gzip > \$DEST/calcom_\${TS}.sql.gz
sudo -u postgres pg_dump --clean --if-exists --quote-all-identifiers plausible_db | gzip > \$DEST/plausible_\${TS}.sql.gz
# Keep 14 days
find \$DEST -name '*.sql.gz' -mtime +14 -delete
EOF
    chmod +x /etc/cron.daily/studio-pg-backup
  "
  log "  ✓ /etc/cron.daily/studio-pg-backup installed (14-day retention)"
fi

# ----- summary ---------------------------------------------------------
log "================================================================"
log "==> postgres-shared configured."
log " "
log "  CT:        $POSTGRES_CTID (postgres)"
log "  Version:   $PG_VERSION"
log "  Listen IP: $PG_LISTEN_IP (binds to localhost + this IP only)"
log " "
log "Databases (each app has its own user, no cross-access):"
log "  calcom_db    (user: calcom_user)"
log "  plausible_db (user: plausible_user)"
log " "
log "Connection URLs (persisted to $TOKENS_FILE):"
log "  CALCOM_DATABASE_URL=postgresql://calcom_user:****@$PG_LISTEN_IP:5432/calcom_db"
log "  PLAUSIBLE_DATABASE_URL=postgresql://plausible_user:****@$PG_LISTEN_IP:5432/plausible_db"
log " "
log "Backups:"
log "  /var/backups/postgres-daily/ on CT $POSTGRES_CTID"
log "  Daily via /etc/cron.daily/studio-pg-backup, 14-day retention"
log " "
log "Manage:"
log "  enter:   pct enter $POSTGRES_CTID"
log "  status:  pct exec $POSTGRES_CTID -- systemctl status postgresql"
log "  logs:    pct exec $POSTGRES_CTID -- journalctl -u postgresql -f"
log "  psql:    pct exec $POSTGRES_CTID -- sudo -u postgres psql"
log "================================================================"
