#!/usr/bin/env bash
# setup-postgres-mirror.sh — Provision the Postgres "mirror" CT for Sobol Mirror.
#
# This is the dedicated read-only mirror database that connector workflows
# write to (slack, quickbooks, google, etc.) and that agent personas read
# from (via agent_view.* views, never raw tables).
#
# It is INTENTIONALLY separate from any other Postgres in the stack:
#   - studio-stack's setup-postgres-shared.sh is for APP databases (Cal.com,
#     Plausible, Ghost) that need shared host but distinct DBs
#   - This one is for SaaS mirror data. Isolation = simpler reasoning about
#     what's in it, what can break, and what migrations look like.
#
# What it does (idempotent at every step):
#   1. Creates Postgres CT via community-scripts (or detects existing)
#   2. Creates database `sobol_mirror` if missing
#   3. Creates roles:
#        sobol_writer       — used by connector n8n workflows (DDL + DML)
#        sobol_agent_readonly — used by agents (SELECT on agent_view.* only)
#   4. Creates initial schemas: `_meta`, `agent_view`
#   5. Creates `_meta.sync_state` table for cursor tracking
#   6. Stores connection info in /root/sobol-tokens.txt
#   7. Registers Postgres credentials in n8n (if n8n CT exists)
#   8. Optionally registers Homepage tile
#
# Usage:
#   ./setup-postgres-mirror.sh                   # default: hostname postgres-mirror
#   ./setup-postgres-mirror.sh --ctid 310        # request specific CTID
#   ./setup-postgres-mirror.sh --tokens FILE     # default /root/sobol-tokens.txt
#   ./setup-postgres-mirror.sh --uninstall       # remove CT and tokens entries
#   ./setup-postgres-mirror.sh --dry-run

set -Eeuo pipefail

DRY_RUN=0
UNINSTALL=0
CT_HOSTNAME="postgres-mirror"
TARGET_CTID=""
TOKENS_FILE="/root/sobol-tokens.txt"
SKIP_N8N_REGISTER=0
SKIP_HOMEPAGE_TILE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)            DRY_RUN=1; shift ;;
    --uninstall)          UNINSTALL=1; shift ;;
    --ctid)               TARGET_CTID="$2"; shift 2 ;;
    --hostname)           CT_HOSTNAME="$2"; shift 2 ;;
    --tokens)             TOKENS_FILE="$2"; shift 2 ;;
    --skip-n8n)           SKIP_N8N_REGISTER=1; shift ;;
    --skip-homepage-tile) SKIP_HOMEPAGE_TILE=1; shift ;;
    -h|--help)            sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

log()  { printf "\n\033[1;36m[postgres-mirror]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[postgres-mirror]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[postgres-mirror]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."

# ----- helpers ---------------------------------------------------------------
find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

upsert_token() {
  local k="$1" v="$2"
  touch "$TOKENS_FILE"
  if grep -q "^${k}=" "$TOKENS_FILE"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$TOKENS_FILE"
  else
    echo "${k}=${v}" >> "$TOKENS_FILE"
  fi
  chmod 600 "$TOKENS_FILE"
}

random_password() {
  # 24-char password, urlsafe (no shell metachars to break OAuth/conn strings)
  python3 -c 'import secrets; print(secrets.token_urlsafe(18))'
}

# ----- uninstall path --------------------------------------------------------
if (( UNINSTALL )); then
  log "Uninstalling postgres-mirror..."
  CTID="$(find_ct_by_hostname "$CT_HOSTNAME" 2>/dev/null || true)"
  if [[ -n "$CTID" ]]; then
    log "  Stopping + destroying CT $CTID..."
    run "pct stop $CTID 2>/dev/null || true"
    run "pct destroy $CTID"
  else
    log "  No CT named $CT_HOSTNAME found — skipping CT destroy"
  fi

  if [[ -f "$TOKENS_FILE" ]]; then
    log "  Removing SOBOL_MIRROR_* entries from $TOKENS_FILE"
    run "sed -i '/^SOBOL_MIRROR_/d' '$TOKENS_FILE'"
  fi

  log "Uninstalled. Connector data is gone — no recovery."
  exit 0
fi

# ----- 1. CT provisioning ----------------------------------------------------
log "Provisioning Postgres CT (hostname: $CT_HOSTNAME)..."

CTID="$(find_ct_by_hostname "$CT_HOSTNAME" 2>/dev/null || true)"
if [[ -n "$CTID" ]]; then
  log "  Found existing CT $CTID — skipping create, will configure"
else
  if [[ -z "$TARGET_CTID" ]]; then
    # Find next available CTID >= 310 (Sobol Mirror lane starts at 310)
    for c in $(seq 310 399); do
      if ! pct status "$c" >/dev/null 2>&1; then TARGET_CTID="$c"; break; fi
    done
    [[ -n "$TARGET_CTID" ]] || die "No available CTID in 310-399 range"
  fi
  log "  Creating CT $TARGET_CTID via community-scripts helper..."

  if (( DRY_RUN )); then
    log "[dry-run] would run community-scripts postgresql.sh with var_hostname=$CT_HOSTNAME var_ctid=$TARGET_CTID"
  else
    # Community-scripts helper for postgresql
    CT_ID="$TARGET_CTID" var_hostname="$CT_HOSTNAME" var_disk=8 var_cpu=2 var_ram=2048 \
      bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/postgresql.sh)" \
      <<< "" || die "community-scripts postgresql install failed"
  fi
  CTID="$TARGET_CTID"
fi

# Wait for CT to be ready
log "  Waiting for CT $CTID to be reachable..."
for _ in $(seq 1 30); do
  pct exec "$CTID" -- true 2>/dev/null && break
  sleep 2
done
pct exec "$CTID" -- true 2>/dev/null || die "CT $CTID not responding"

# ----- 2. Bind Postgres to tailnet only --------------------------------------
log "Configuring Postgres to listen on tailnet IP only..."
# (Same hardening pattern as setup-postgres-shared.sh)

CT_TS_IP=""
if (( ! DRY_RUN )); then
  CT_TS_IP="$(pct exec "$CTID" -- bash -lc 'tailscale ip -4 2>/dev/null | head -1' || true)"
  if [[ -z "$CT_TS_IP" ]]; then
    warn "  CT $CTID has no Tailscale IP yet — Postgres will bind to all interfaces"
    warn "  Re-run after Tailscale is up to harden the bind"
    CT_TS_IP="*"
  fi

  PG_VERSION=$(pct exec "$CTID" -- bash -lc 'ls /etc/postgresql/ 2>/dev/null | head -1')
  if [[ -z "$PG_VERSION" ]]; then
    die "Could not find Postgres config dir in CT $CTID"
  fi
  PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"

  pct exec "$CTID" -- bash -lc "
    cp $PG_CONF ${PG_CONF}.bak.\$(date +%s)
    if grep -q '^listen_addresses' $PG_CONF; then
      sed -i \"s|^listen_addresses.*|listen_addresses = 'localhost,$CT_TS_IP'|\" $PG_CONF
    else
      echo \"listen_addresses = 'localhost,$CT_TS_IP'\" >> $PG_CONF
    fi
  "
fi

# ----- 3. Create database + roles --------------------------------------------
log "Creating database 'sobol_mirror' and roles..."

# Read existing passwords from tokens, or mint new ones
SOBOL_WRITER_PASS="$(grep -E '^SOBOL_MIRROR_WRITER_PASSWORD=' "$TOKENS_FILE" 2>/dev/null | sed 's/^[^=]*=//' || true)"
SOBOL_READER_PASS="$(grep -E '^SOBOL_MIRROR_READONLY_PASSWORD=' "$TOKENS_FILE" 2>/dev/null | sed 's/^[^=]*=//' || true)"
[[ -z "$SOBOL_WRITER_PASS" ]] && SOBOL_WRITER_PASS="$(random_password)"
[[ -z "$SOBOL_READER_PASS" ]] && SOBOL_READER_PASS="$(random_password)"

if (( ! DRY_RUN )); then
  pct exec "$CTID" -- sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
-- Idempotent: create DB if it doesn't exist
SELECT 'CREATE DATABASE sobol_mirror'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'sobol_mirror')\gexec

-- Roles
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'sobol_writer') THEN
    CREATE ROLE sobol_writer WITH LOGIN PASSWORD '$SOBOL_WRITER_PASS';
  ELSE
    ALTER ROLE sobol_writer WITH PASSWORD '$SOBOL_WRITER_PASS';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'sobol_agent_readonly') THEN
    CREATE ROLE sobol_agent_readonly WITH LOGIN PASSWORD '$SOBOL_READER_PASS';
  ELSE
    ALTER ROLE sobol_agent_readonly WITH PASSWORD '$SOBOL_READER_PASS';
  END IF;
END
\$\$;

GRANT CONNECT ON DATABASE sobol_mirror TO sobol_writer, sobol_agent_readonly;
SQL

  # Schemas + base table (run inside the DB itself)
  pct exec "$CTID" -- sudo -u postgres psql -v ON_ERROR_STOP=1 -d sobol_mirror <<SQL
CREATE SCHEMA IF NOT EXISTS _meta AUTHORIZATION sobol_writer;
CREATE SCHEMA IF NOT EXISTS agent_view AUTHORIZATION sobol_writer;

-- Sync state — connectors update this after each successful run
CREATE TABLE IF NOT EXISTS _meta.sync_state (
  source         TEXT NOT NULL,           -- 'slack', 'quickbooks', 'gmail', etc.
  entity         TEXT NOT NULL,           -- 'messages', 'channels', etc.
  cursor         TEXT,                    -- opaque pagination cursor / last ID / last ts
  last_sync_ts   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_status    TEXT NOT NULL DEFAULT 'ok',  -- 'ok', 'rate_limited', 'auth_failed', 'error'
  last_error     TEXT,
  rows_total     BIGINT DEFAULT 0,
  PRIMARY KEY (source, entity)
);

-- Connector registry — installed connectors and their manifests
CREATE TABLE IF NOT EXISTS _meta.connectors (
  name          TEXT PRIMARY KEY,         -- 'slack'
  version       TEXT NOT NULL,            -- '1.0.0'
  installed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  manifest_yaml TEXT NOT NULL,            -- the parsed manifest
  enabled       BOOLEAN NOT NULL DEFAULT TRUE
);

-- Audit log — every read query an agent makes lands here
CREATE TABLE IF NOT EXISTS _meta.agent_actions (
  id           BIGSERIAL PRIMARY KEY,
  ts           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  agent        TEXT NOT NULL,            -- 'comms-agent', 'cfo-agent'
  action       TEXT NOT NULL,            -- 'digest_morning', 'on_demand_query', etc.
  view_queried TEXT,                     -- which agent_view.* it hit
  rows_returned INTEGER,
  prompt_hash  TEXT,                     -- sha256 of prompt sent to LLM
  output_hash  TEXT,                     -- sha256 of LLM output
  notes        TEXT
);

GRANT USAGE ON SCHEMA agent_view TO sobol_agent_readonly;
GRANT USAGE ON SCHEMA _meta TO sobol_agent_readonly;
-- Read-only role can see what it can see, nothing more
GRANT SELECT ON ALL TABLES IN SCHEMA agent_view TO sobol_agent_readonly;
GRANT SELECT ON _meta.sync_state TO sobol_agent_readonly;
GRANT INSERT ON _meta.agent_actions TO sobol_agent_readonly;
GRANT USAGE, SELECT ON SEQUENCE _meta.agent_actions_id_seq TO sobol_agent_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA agent_view GRANT SELECT ON TABLES TO sobol_agent_readonly;

-- Writer role owns all the data
GRANT ALL ON SCHEMA _meta, agent_view TO sobol_writer;
GRANT ALL ON ALL TABLES IN SCHEMA _meta TO sobol_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA _meta, agent_view GRANT ALL ON TABLES TO sobol_writer;
SQL
fi

# ----- 4. Update pg_hba.conf for tailnet access ------------------------------
log "Configuring pg_hba.conf for tailnet access..."
if (( ! DRY_RUN )); then
  PG_HBA="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
  pct exec "$CTID" -- bash -lc "
    if ! grep -q 'Sobol Mirror' $PG_HBA; then
      cat >> $PG_HBA <<EOF

# Sobol Mirror — tailnet access for connectors and agents
host    sobol_mirror    sobol_writer            100.0.0.0/8     scram-sha-256
host    sobol_mirror    sobol_agent_readonly    100.0.0.0/8     scram-sha-256
EOF
      systemctl restart postgresql
    fi
  "
fi

# ----- 5. Persist credentials in tokens file ---------------------------------
log "Persisting connection info to $TOKENS_FILE..."
upsert_token SOBOL_MIRROR_DB_HOST "$CT_HOSTNAME"
upsert_token SOBOL_MIRROR_DB_PORT "5432"
upsert_token SOBOL_MIRROR_DB_NAME "sobol_mirror"
upsert_token SOBOL_MIRROR_WRITER_USER "sobol_writer"
upsert_token SOBOL_MIRROR_WRITER_PASSWORD "$SOBOL_WRITER_PASS"
upsert_token SOBOL_MIRROR_READONLY_USER "sobol_agent_readonly"
upsert_token SOBOL_MIRROR_READONLY_PASSWORD "$SOBOL_READER_PASS"
upsert_token SOBOL_MIRROR_CTID "$CTID"

# ----- 6. Register n8n credentials -------------------------------------------
if (( ! SKIP_N8N_REGISTER )); then
  N8N_CTID="$(find_ct_by_hostname n8n 2>/dev/null || true)"
  if [[ -z "$N8N_CTID" ]]; then
    log "  n8n CT not found — skipping credential registration"
    log "  Run this addon again after setup-n8n.sh, or manually create:"
    log "    'Sobol Mirror (writer)' — type: postgres"
    log "    'Sobol Mirror (read-only)' — type: postgres"
  else
    N8N_API_KEY="$(read_token N8N_API_KEY 2>/dev/null || true)"
    if [[ -z "$N8N_API_KEY" ]]; then
      # Try the td-tokens file as fallback (n8n stores its key there during setup-n8n)
      N8N_API_KEY="$(awk -F= '/^N8N_API_KEY=/{val=$2} END{print val}' /root/td-tokens.txt 2>/dev/null | tr -d ' ' || true)"
    fi

    if [[ -z "$N8N_API_KEY" ]]; then
      warn "  N8N_API_KEY not found in $TOKENS_FILE or /root/td-tokens.txt"
      warn "  Skipping credential registration. To create later:"
      warn "    Re-run with --tokens pointing at the file containing N8N_API_KEY"
      warn "    OR create credentials manually in n8n UI (Settings → Credentials)"
    else
      log "Registering Postgres credentials in n8n CT $N8N_CTID..."

      # Helper: create credential if not present (n8n public API)
      create_pg_credential() {
        local cred_name="$1" pg_user="$2" pg_pass="$3"
        # Check if exists
        local exists
        exists="$(pct exec "$N8N_CTID" -- curl -sS -H "X-N8N-API-KEY: $N8N_API_KEY" \
          http://localhost:5678/api/v1/credentials 2>/dev/null \
          | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    items = d.get('data', d) if isinstance(d, dict) else d
    for c in items:
        if c.get('name') == '$cred_name':
            print('exists'); break
except: pass" 2>/dev/null)"

        if [[ "$exists" == "exists" ]]; then
          log "  ✓ Credential '$cred_name' already exists — skipping"
          return 0
        fi

        local payload
        payload="$(PG_HOST="$CT_HOSTNAME" PG_USER="$pg_user" PG_PASS="$pg_pass" CRED_NAME="$cred_name" python3 -c '
import json, os
print(json.dumps({
  "name": os.environ["CRED_NAME"],
  "type": "postgres",
  "data": {
    "host": os.environ["PG_HOST"],
    "port": 5432,
    "database": "sobol_mirror",
    "user": os.environ["PG_USER"],
    "password": os.environ["PG_PASS"],
    "ssl": "disable"
  }
}))')"

        # POST to /api/v1/credentials
        local code
        code="$(pct exec "$N8N_CTID" -- bash -lc "
          echo '$payload' | curl -sS -o /tmp/cred-resp.json -w '%{http_code}' \
            -H 'X-N8N-API-KEY: $N8N_API_KEY' \
            -H 'Content-Type: application/json' \
            -X POST --data-binary @- \
            http://localhost:5678/api/v1/credentials
        ")"
        if [[ "$code" =~ ^2 ]]; then
          log "  ✓ Created '$cred_name' (HTTP $code)"
        else
          warn "  Credential create returned HTTP $code for '$cred_name'"
          pct exec "$N8N_CTID" -- cat /tmp/cred-resp.json 2>/dev/null | sed 's/^/    /' >&2 || true
        fi
        pct exec "$N8N_CTID" -- rm -f /tmp/cred-resp.json 2>/dev/null || true
      }

      if (( ! DRY_RUN )); then
        create_pg_credential "Sobol Mirror (writer)"     "sobol_writer"         "$SOBOL_WRITER_PASS"
        create_pg_credential "Sobol Mirror (read-only)"  "sobol_agent_readonly" "$SOBOL_READER_PASS"
      else
        log "[dry-run] would create credentials: 'Sobol Mirror (writer)' + 'Sobol Mirror (read-only)'"
      fi
    fi
  fi
fi

# ----- 7. Smoke test ---------------------------------------------------------
log "Smoke test: connecting + listing schemas..."
if (( ! DRY_RUN )); then
  pct exec "$CTID" -- sudo -u postgres psql -d sobol_mirror -c '\dn' 2>&1 | sed 's/^/  /'
fi

# ----- summary ---------------------------------------------------------------
log "================================================================"
log "==> Postgres mirror ready."
log " "
log "  CT:            $CTID ($CT_HOSTNAME)"
log "  Database:      sobol_mirror"
log "  Schemas:       _meta, agent_view"
log "  Writer role:   sobol_writer  (used by connector workflows)"
log "  Reader role:   sobol_agent_readonly  (used by agent personas)"
log " "
log "Connection string for connectors (n8n):"
log "  postgres://sobol_writer:<see-tokens-file>@$CT_HOSTNAME:5432/sobol_mirror"
log " "
log "Connection string for agents:"
log "  postgres://sobol_agent_readonly:<see-tokens-file>@$CT_HOSTNAME:5432/sobol_mirror"
log " "
log "What's NOT in this addon (by design):"
log "  - No source-specific schemas (slack.*, quickbooks.*, etc.) — those"
log "    come from setup-connector-<source>.sh addons"
log "  - No agent_view.* views — same"
log "  - No data — connectors run hourly and populate over time"
log " "
log "Next steps:"
log "  ./addons/setup-connector-slack.sh      # add Slack as a source"
log "  cat $TOKENS_FILE | grep SOBOL_MIRROR  # see what was provisioned"
log " "
log "Inspect:"
log "  pct exec $CTID -- sudo -u postgres psql -d sobol_mirror -c '\\\\dn'"
log "  pct exec $CTID -- sudo -u postgres psql -d sobol_mirror -c 'SELECT * FROM _meta.sync_state;'"
log " "
log "Uninstall (destroys CT and DATA):"
log "  $(basename "$0") --uninstall"
log "================================================================"
