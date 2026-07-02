#!/usr/bin/env bash
# setup-mariadb-shared.sh — Shared MariaDB CT for MySQL-family apps.
#
# Ghost is MySQL-only (Postgres was dropped at Ghost 1.0, no roadmap
# to return). Easy!Appointments is also MySQL-family. Rather than run
# a MariaDB inside each app CT, we run one shared MariaDB CT with
# per-app databases + per-app users (each app isolated, no cross-DB
# access). Parallel to setup-postgres-shared.sh — same pattern, same
# security posture (bind tailnet + localhost only, daily backups).
#
# CURRENT STATE (opinionated for creator-studio v1.0):
#   Creates `ghost_db` (owner: ghost_user) + `ea_db` (owner: ea_user)
#   — the two DBs creator-studio needs. Character set is utf8mb4
#   (Ghost requires this since 4.0; utf8 has been rejected since 5.0).
#
# FUTURE (when a third stack needs shared mariadb with different DBs):
#   Generalize via a MARIADB_SHARED_DBS tokens field or --db name:user
#   repeatable arg. For now the hardcoded pair matches the only in-tree
#   consumer, and the convention (§2.1) is willing to accept a
#   first-mover cost in return for shipping.
#
# What it does (idempotent at every step):
#   1. Auto-detects MARIADB CTID; creates via community-scripts
#      mariadb.sh helper if absent (matches setup-postgres-shared.sh
#      pattern from task #267)
#   2. TUN passthrough + tailscale install/join
#   3. Reads or generates random passwords for ghost_user + ea_user
#      (re-runs use existing passwords; first run generates + persists)
#   4. Creates DBs with CREATE DATABASE IF NOT EXISTS + utf8mb4
#   5. Creates users with CREATE OR REPLACE USER (idempotent MariaDB
#      10.1+) — one entry per allowed host CIDR (Tailscale + RFC1918)
#   6. GRANT ALL PRIVILEGES ON app_db.* TO 'app_user'@<each-host>
#      (scoped — no *.* superuser grants)
#   7. Edits /etc/mysql/mariadb.conf.d/50-server.cnf bind-address to
#      localhost,tailnet-ip (MariaDB 10.3+ supports comma-separated)
#   8. Restarts mariadb service
#   9. Writes GHOST_DATABASE_URL + EA_DATABASE_URL to tokens
#      (consumed by setup-ghost.sh + setup-easyappointments.sh)
#  10. Smoke-tests each connection from inside the CT
#  11. Installs daily mysqldump cron to /var/backups/mariadb-daily/
#      with 14-day retention
#
# Usage:
#   ./setup-mariadb-shared.sh                     # default
#   ./setup-mariadb-shared.sh --dry-run           # preview
#   ./setup-mariadb-shared.sh --redo-passwords    # regenerate user passwords
#   ./setup-mariadb-shared.sh --tokens-file PATH  # override tokens location

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
log()  { printf "\n\033[1;36m[mariadb-shared]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[mariadb-shared]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[mariadb-shared]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct >/dev/null || die "pct not found — PVE host required."

# Resolve tokens file. --tokens-file wins; else auto-detect (matches
# setup-postgres-shared.sh + setup-stack.sh resolution).
if [[ -z "$TOKENS_FILE" ]]; then
  for f in /root/studio-tokens.txt /root/td-tokens.txt /root/sobol-tokens.txt; do
    if [[ -f "$f" ]]; then TOKENS_FILE="$f"; break; fi
  done
fi
[[ -n "$TOKENS_FILE" && -f "$TOKENS_FILE" ]] \
  || die "No tokens file found. Tried studio-tokens.txt, td-tokens.txt, sobol-tokens.txt.
  Pass --tokens-file <path> or run bootstrap-pve.sh first."
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

# upsert_token — idempotent write to tokens file (replace or append)
upsert_token() {
  local key="$1" val="$2"
  if grep -q "^$key=" "$TOKENS_FILE"; then
    sed -i "s|^$key=.*|$key=$val|" "$TOKENS_FILE"
  else
    echo "$key=$val" >> "$TOKENS_FILE"
  fi
}

# ----- pre-flight --------------------------------------------------------
log "Pre-flight..."

# Shared CT lifecycle helpers (ct_wait_ready, ts_ensure_joined, etc)
if [[ -r "$(dirname "${BASH_SOURCE[0]}")/lib/ct-helpers.sh" ]]; then
  # shellcheck source=lib/ct-helpers.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib/ct-helpers.sh"
fi

MARIADB_CTID="$(read_token MARIADB_CTID || echo 305)"
MARIADB_HOSTNAME="${MARIADB_HOSTNAME:-mariadb}"

# CT-create prerequisites — used only when creating a new CT
TS_AUTHKEY="$(read_token TS_AUTHKEY || true)"
CT_PASSWORD="$(read_token CT_PASSWORD || true)"

# ----- CT-detection or auto-create --------------------------------------
MARIADB_HELPER_URL="${MARIADB_HELPER_URL:-https://github.com/community-scripts/ProxmoxVE/raw/main/ct/mariadb.sh}"

find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

EXISTING_CTID="$(find_ct_by_hostname "$MARIADB_HOSTNAME" 2>/dev/null || true)"
if [[ -n "$EXISTING_CTID" ]]; then
  log "  Found existing CT $EXISTING_CTID ($MARIADB_HOSTNAME) — using it."
  MARIADB_CTID="$EXISTING_CTID"
else
  log "  No CT named '$MARIADB_HOSTNAME' found — creating via community-scripts mariadb.sh..."
  [[ -n "$CT_PASSWORD" ]] || die "CT_PASSWORD required in $TOKENS_FILE to create a new CT."

  # Auto-allocate CTID if the preferred one is taken
  if pct status "$MARIADB_CTID" >/dev/null 2>&1; then
    MARIADB_CTID="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"')"
    log "  Preferred CTID taken; auto-allocated $MARIADB_CTID."
  fi

  # SSH pubkey from authorized_keys (skip PVE auto-generated)
  PVE_HOST="$(hostname -s)"
  SSH_KEY=""
  [[ -f /root/.ssh/authorized_keys ]] && \
    SSH_KEY="$(awk -v skip="root@$PVE_HOST" '/^ssh-/ && $NF != skip { print; exit }' /root/.ssh/authorized_keys)"

  if (( DRY_RUN )); then
    log "  [dry-run] would run community-scripts mariadb.sh (CTID=$MARIADB_CTID, hostname=$MARIADB_HOSTNAME)"
  else
    # Fetch helper to tempfile first (task #271 fail-loud pattern)
    HELPER_TMP="$(mktemp /tmp/mariadb-helper.XXXXXX.sh)"
    if ! curl -fsSL "$MARIADB_HELPER_URL" -o "$HELPER_TMP" || [[ ! -s "$HELPER_TMP" ]]; then
      rm -f "$HELPER_TMP"
      die "MariaDB helper fetch failed or returned empty. URL: $MARIADB_HELPER_URL
  Check community-scripts current layout: https://community-scripts.github.io/ProxmoxVE/scripts
  Override with: MARIADB_HELPER_URL=<url> $0"
    fi

    var_ctid="$MARIADB_CTID" \
    var_hostname="$MARIADB_HOSTNAME" \
    var_ssh=yes \
    var_ssh_authorized_key="$SSH_KEY" \
    var_gpu=no \
    bash "$HELPER_TMP"
    rm -f "$HELPER_TMP"

    # Detect actual CTID (helper may have chosen a different one)
    ACTUAL_CTID="$(find_ct_by_hostname "$MARIADB_HOSTNAME" 2>/dev/null || true)"
    if [[ -n "$ACTUAL_CTID" && "$ACTUAL_CTID" != "$MARIADB_CTID" ]]; then
      log "  Helper assigned CTID $ACTUAL_CTID — switching."
      MARIADB_CTID="$ACTUAL_CTID"
    fi
    [[ -n "$MARIADB_CTID" ]] || die "MariaDB CT didn't come up — see community-scripts output above."
    upsert_token MARIADB_CTID "$MARIADB_CTID"

    # TUN passthrough so Tailscale can run
    CT_CONF="/etc/pve/lxc/$MARIADB_CTID.conf"
    if ! grep -q "/dev/net/tun" "$CT_CONF" 2>/dev/null; then
      log "  Adding /dev/net/tun passthrough..."
      cat >> "$CT_CONF" <<'TUN_BLOCK'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
TUN_BLOCK
      pct reboot "$MARIADB_CTID"
      log "  Waiting for CT to come back after reboot..."
      declare -F ct_wait_ready >/dev/null && ct_wait_ready "$MARIADB_CTID" || sleep 15
    fi

    # Tailscale install + join
    if [[ -n "$TS_AUTHKEY" ]] && declare -F ts_ensure_joined >/dev/null; then
      log "  Installing tailscale + joining tailnet as '$MARIADB_HOSTNAME'..."
      if ! pct exec "$MARIADB_CTID" -- tailscale --version >/dev/null 2>&1; then
        pct exec "$MARIADB_CTID" -- bash -lc '
          set -e
          export DEBIAN_FRONTEND=noninteractive
          . /etc/os-release
          apt-get update -qq
          apt-get install -y -qq curl ca-certificates
          curl -fsSL "https://pkgs.tailscale.com/stable/${ID}/${VERSION_CODENAME}.noarmor.gpg" \
            | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
          echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${ID} ${VERSION_CODENAME} main" \
            > /etc/apt/sources.list.d/tailscale.list
          apt-get update -qq
          apt-get install -y -qq tailscale
        ' 2>&1 | sed 's/^/    /'
      fi
      ts_ensure_joined "$MARIADB_CTID" "$TS_AUTHKEY" "$MARIADB_HOSTNAME" || \
        warn "  Tailscale join returned non-zero — continuing (LAN-only fallback ok)."
    fi
  fi
fi

# Verify CT is running
if ! pct status "$MARIADB_CTID" 2>/dev/null | grep -q running; then
  die "CT $MARIADB_CTID not running. Try: pct start $MARIADB_CTID"
fi

# ----- resolve IPs -------------------------------------------------------
log "Resolving mariadb tailnet IP..."
DB_TS_IP="$(pct exec "$MARIADB_CTID" -- tailscale ip -4 2>/dev/null | head -1)"
DB_LAN_IP="$(pct exec "$MARIADB_CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
log "  Tailnet IP: ${DB_TS_IP:-<none>}"
log "  LAN IP:     ${DB_LAN_IP:-<none>}"

# Prefer tailnet IP, fall back to LAN if tailscale isn't up
DB_LISTEN_IP="${DB_TS_IP:-$DB_LAN_IP}"
[[ -n "$DB_LISTEN_IP" ]] || die "MariaDB CT has no usable IP. Check 'pct exec $MARIADB_CTID -- ip a'"

# ----- wait for mariadb service ------------------------------------------
log "Waiting for mariadb service..."
if (( ! DRY_RUN )); then
  # Package name is 'mariadb' on modern Debian; older systems use 'mysql'
  MARIADB_UNIT=""
  for unit in mariadb mysql mysqld; do
    if pct exec "$MARIADB_CTID" -- systemctl list-unit-files "${unit}.service" 2>/dev/null | grep -q "${unit}.service"; then
      MARIADB_UNIT="$unit"; break
    fi
  done
  [[ -n "$MARIADB_UNIT" ]] || die "No mariadb/mysql systemd unit found on CT $MARIADB_CTID"

  for i in {1..30}; do
    if pct exec "$MARIADB_CTID" -- systemctl is-active "$MARIADB_UNIT" 2>/dev/null | grep -q active; then
      log "  ✓ $MARIADB_UNIT is active"
      break
    fi
    sleep 2
  done
fi

# ----- detect MariaDB version --------------------------------------------
# Ghost 6.0 requires MariaDB 10.11+ (or MySQL 8.0+). Log the version so
# operators know at-a-glance whether they can run Ghost 6+.
MARIADB_VERSION="$(pct exec "$MARIADB_CTID" -- bash -lc 'mariadb --version 2>/dev/null || mysql --version 2>/dev/null' 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[[ -n "$MARIADB_VERSION" ]] || warn "Couldn't detect MariaDB version — is mariadb-server installed?"
log "  MariaDB version: ${MARIADB_VERSION:-unknown}"

# Config file path — Debian pattern for MariaDB 10.x+
DB_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
if ! pct exec "$MARIADB_CTID" -- test -f "$DB_CONF" 2>/dev/null; then
  # Fallback locations
  for candidate in /etc/mysql/mariadb.cnf /etc/mysql/my.cnf; do
    if pct exec "$MARIADB_CTID" -- test -f "$candidate" 2>/dev/null; then
      DB_CONF="$candidate"; break
    fi
  done
fi
log "  Config file: $DB_CONF"

# ----- 1. generate or re-use per-app passwords --------------------------
log "Generating per-app database passwords..."

GHOST_DB_PASSWORD="$(read_token GHOST_DB_PASSWORD || true)"
EA_DB_PASSWORD="$(read_token EA_DB_PASSWORD || true)"

if [[ -z "$GHOST_DB_PASSWORD" || $REDO_PASSWORDS -eq 1 ]]; then
  GHOST_DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)"
  log "  Generated GHOST_DB_PASSWORD (${#GHOST_DB_PASSWORD} chars)"
fi
if [[ -z "$EA_DB_PASSWORD" || $REDO_PASSWORDS -eq 1 ]]; then
  EA_DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)"
  log "  Generated EA_DB_PASSWORD (${#EA_DB_PASSWORD} chars)"
fi

if (( ! DRY_RUN )); then
  upsert_token GHOST_DB_PASSWORD "$GHOST_DB_PASSWORD"
  upsert_token EA_DB_PASSWORD "$EA_DB_PASSWORD"
fi

# ----- 2. create dbs + users --------------------------------------------
log "Creating databases + users..."

# MariaDB doesn't have pg_hba — access control is per-user, and
# 'user'@'host' rows scope allowed sources. We create each user with
# multiple @host entries covering Tailscale CGNAT + RFC1918. Slightly
# verbose but transparent and revocable per-CIDR.
#
# Ghost specifically requires utf8mb4 (not utf8) — has done since v4.
# Setting utf8mb4_unicode_ci for proper Unicode collation.
#
# CREATE OR REPLACE USER (MariaDB 10.1+) is idempotent: creates on
# first run, replaces (updating password) on re-runs. This lets
# --redo-passwords work cleanly.
SQL="$(cat <<EOF
-- Ghost blog
CREATE DATABASE IF NOT EXISTS ghost_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE OR REPLACE USER 'ghost_user'@'localhost'      IDENTIFIED BY '$GHOST_DB_PASSWORD';
CREATE OR REPLACE USER 'ghost_user'@'100.%'          IDENTIFIED BY '$GHOST_DB_PASSWORD';
CREATE OR REPLACE USER 'ghost_user'@'10.%'           IDENTIFIED BY '$GHOST_DB_PASSWORD';
CREATE OR REPLACE USER 'ghost_user'@'172.16.%'       IDENTIFIED BY '$GHOST_DB_PASSWORD';
CREATE OR REPLACE USER 'ghost_user'@'192.168.%'      IDENTIFIED BY '$GHOST_DB_PASSWORD';
GRANT ALL PRIVILEGES ON ghost_db.* TO 'ghost_user'@'localhost';
GRANT ALL PRIVILEGES ON ghost_db.* TO 'ghost_user'@'100.%';
GRANT ALL PRIVILEGES ON ghost_db.* TO 'ghost_user'@'10.%';
GRANT ALL PRIVILEGES ON ghost_db.* TO 'ghost_user'@'172.16.%';
GRANT ALL PRIVILEGES ON ghost_db.* TO 'ghost_user'@'192.168.%';

-- Easy!Appointments
CREATE DATABASE IF NOT EXISTS ea_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE OR REPLACE USER 'ea_user'@'localhost'         IDENTIFIED BY '$EA_DB_PASSWORD';
CREATE OR REPLACE USER 'ea_user'@'100.%'             IDENTIFIED BY '$EA_DB_PASSWORD';
CREATE OR REPLACE USER 'ea_user'@'10.%'              IDENTIFIED BY '$EA_DB_PASSWORD';
CREATE OR REPLACE USER 'ea_user'@'172.16.%'          IDENTIFIED BY '$EA_DB_PASSWORD';
CREATE OR REPLACE USER 'ea_user'@'192.168.%'         IDENTIFIED BY '$EA_DB_PASSWORD';
GRANT ALL PRIVILEGES ON ea_db.* TO 'ea_user'@'localhost';
GRANT ALL PRIVILEGES ON ea_db.* TO 'ea_user'@'100.%';
GRANT ALL PRIVILEGES ON ea_db.* TO 'ea_user'@'10.%';
GRANT ALL PRIVILEGES ON ea_db.* TO 'ea_user'@'172.16.%';
GRANT ALL PRIVILEGES ON ea_db.* TO 'ea_user'@'192.168.%';

FLUSH PRIVILEGES;
EOF
)"

if (( ! DRY_RUN )); then
  # Write SQL to a file inside the CT, then run as root via socket auth.
  # (Debian MariaDB installs give root@localhost socket auth by default —
  # no password needed for root from inside the CT.)
  echo "$SQL" | pct exec "$MARIADB_CTID" -- tee /tmp/studio-mariadb-setup.sql >/dev/null
  pct exec "$MARIADB_CTID" -- bash -lc 'mariadb < /tmp/studio-mariadb-setup.sql' 2>&1 | tail -10
  pct exec "$MARIADB_CTID" -- rm -f /tmp/studio-mariadb-setup.sql
fi

# ----- 3. configure bind-address ----------------------------------------
log "Editing $DB_CONF to bind to localhost + tailnet IP..."

# MariaDB 10.3+ supports comma-separated bind-address. Default install
# binds 127.0.0.1 only, which locks out network connections entirely.
# We bind localhost + the tailnet IP so intra-tailnet apps can connect
# but the LAN can't. Marker comment lets re-runs stay canonical.
LISTEN_ADDRS="127.0.0.1,$DB_LISTEN_IP"

if (( ! DRY_RUN )); then
  pct exec "$MARIADB_CTID" -- bash -lc "
    set -e
    cp '$DB_CONF' '${DB_CONF}.bak.\$(date +%s)' 2>/dev/null || true
    # Strip any existing bind-address line in the [mysqld] section
    if grep -qE '^[[:space:]]*bind-address' '$DB_CONF'; then
      sed -i 's|^[[:space:]]*bind-address.*|bind-address = $LISTEN_ADDRS|' '$DB_CONF'
    elif grep -q '^\[mysqld\]' '$DB_CONF'; then
      # Insert after [mysqld] section header
      sed -i '/^\[mysqld\]/a bind-address = $LISTEN_ADDRS' '$DB_CONF'
    else
      # No [mysqld] section at all — append full block
      cat >> '$DB_CONF' <<CFG

[mysqld]
bind-address = $LISTEN_ADDRS
CFG
    fi
  "
  log "  ✓ bind-address = $LISTEN_ADDRS"
fi

# ----- 4. restart mariadb -----------------------------------------------
log "Restarting $MARIADB_UNIT..."
run "pct exec $MARIADB_CTID -- systemctl restart $MARIADB_UNIT"
sleep 3

if (( ! DRY_RUN )); then
  if pct exec "$MARIADB_CTID" -- systemctl is-active "$MARIADB_UNIT" 2>/dev/null | grep -q active; then
    log "  ✓ $MARIADB_UNIT is active"
  else
    die "  $MARIADB_UNIT failed to restart — check 'pct exec $MARIADB_CTID -- journalctl -u $MARIADB_UNIT -n 30'"
  fi
fi

# ----- 5. smoke-test connections ----------------------------------------
log "Smoke-testing connections..."

if (( ! DRY_RUN )); then
  for pair in "ghost_db:ghost_user:$GHOST_DB_PASSWORD" "ea_db:ea_user:$EA_DB_PASSWORD"; do
    db="${pair%%:*}"
    rest="${pair#*:}"
    user="${rest%%:*}"
    pw="${rest#*:}"
    # Connect over TCP to the tailnet IP (not socket) so we're testing
    # the same path the app CT will use.
    result="$(pct exec "$MARIADB_CTID" -- bash -lc "mariadb -h '$DB_LISTEN_IP' -u '$user' -p'$pw' -N -e 'SELECT DATABASE(), CURRENT_USER()' '$db'" 2>&1)"
    if echo "$result" | grep -q "$db"; then
      log "  ✓ $db connection works ($result)"
    else
      warn "  ✗ $db connection failed: $result"
    fi
  done
fi

# ----- 6. persist connection URLs to tokens -----------------------------
log "Persisting connection URLs to $TOKENS_FILE..."

# Ghost uses individual env vars (host/user/pw/db), not a URL. We write
# both — DATABASE_URL for consistency with setup-postgres-shared.sh's
# convention, and per-field values for Ghost's config.
GHOST_DATABASE_URL="mysql://ghost_user:$GHOST_DB_PASSWORD@$DB_LISTEN_IP:3306/ghost_db"
EA_DATABASE_URL="mysql://ea_user:$EA_DB_PASSWORD@$DB_LISTEN_IP:3306/ea_db"

if (( ! DRY_RUN )); then
  upsert_token GHOST_DATABASE_URL   "$GHOST_DATABASE_URL"
  upsert_token EA_DATABASE_URL      "$EA_DATABASE_URL"
  upsert_token MARIADB_LISTEN_IP    "$DB_LISTEN_IP"
  upsert_token MARIADB_VERSION      "$MARIADB_VERSION"
fi

# ----- 7. daily mysqldump backup cron -----------------------------------
log "Installing daily mysqldump cron..."

if (( ! DRY_RUN )); then
  pct exec "$MARIADB_CTID" -- bash -lc "
    mkdir -p /var/backups/mariadb-daily
    cat > /etc/cron.daily/studio-mariadb-backup <<'EOF'
#!/bin/sh
# Daily creator-studio mariadb backup (installed by setup-mariadb-shared.sh)
# One dump per DB — restore with: mysql <db> < backup.sql
# 14-day retention.
set -e
BACKUP_DIR=/var/backups/mariadb-daily
DATE=\$(date +%Y%m%d)
for DB in ghost_db ea_db; do
  mariadb-dump --single-transaction --routines --triggers \"\$DB\" 2>/dev/null \
    | gzip > \"\$BACKUP_DIR/\${DB}-\${DATE}.sql.gz\"
done
# Prune anything older than 14 days
find \"\$BACKUP_DIR\" -name '*.sql.gz' -mtime +14 -delete 2>/dev/null || true
EOF
    chmod 755 /etc/cron.daily/studio-mariadb-backup
  "
  log "  ✓ /etc/cron.daily/studio-mariadb-backup installed (14-day retention)"
fi

# ----- summary ----------------------------------------------------------
log "================================================================"
log "==> mariadb-shared configured."
log " "
log "  CT:        $MARIADB_CTID ($MARIADB_HOSTNAME)"
log "  Version:   $MARIADB_VERSION"
log "  Listen IP: $DB_LISTEN_IP (binds to localhost + this IP only)"
log " "
log "Databases (each app has its own user, no cross-access):"
log "  ghost_db  (user: ghost_user)  — for Ghost blog"
log "  ea_db     (user: ea_user)     — for Easy!Appointments"
log " "
log "Connection URLs (persisted to $TOKENS_FILE):"
log "  GHOST_DATABASE_URL=mysql://ghost_user:****@$DB_LISTEN_IP:3306/ghost_db"
log "  EA_DATABASE_URL=mysql://ea_user:****@$DB_LISTEN_IP:3306/ea_db"
log " "
log "Backups:"
log "  /var/backups/mariadb-daily/ on CT $MARIADB_CTID"
log "  Daily via /etc/cron.daily/studio-mariadb-backup, 14-day retention"
log " "
log "Manage:"
log "  enter:   pct enter $MARIADB_CTID"
log "  status:  pct exec $MARIADB_CTID -- systemctl status $MARIADB_UNIT"
log "  logs:    pct exec $MARIADB_CTID -- journalctl -u $MARIADB_UNIT -f"
log "  mariadb: pct exec $MARIADB_CTID -- mariadb"
log "================================================================"
