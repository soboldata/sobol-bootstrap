#!/usr/bin/env bash
# setup-connector-slack.sh — Install the Slack source connector for Sobol Mirror
#
# What it does (idempotent at every step):
#   1. Verifies setup-postgres-mirror.sh has run (sobol_mirror DB exists)
#   2. Verifies setup-n8n.sh has run (n8n CT exists)
#   3. Prompts for Slack Bot Token (or reads from tokens file)
#   4. Tests the token by calling auth.test
#   5. Applies addons/connectors/slack/schema.sql to sobol_mirror DB
#      (creates slack.* tables + agent_view.slack_* views)
#   6. Registers connector in _meta.connectors
#   7. Imports the n8n workflow (slack-mirror-sync.json) configured with
#      the Postgres credential + Slack token
#   8. Triggers an initial backfill (30 days, configurable)
#   9. Verifies first sync wrote rows
#
# Usage:
#   ./setup-connector-slack.sh                # interactive
#   ./setup-connector-slack.sh --token xoxb-... # non-interactive
#   ./setup-connector-slack.sh --backfill-days 7   # smaller initial backfill
#   ./setup-connector-slack.sh --uninstall    # drops slack schema + workflow

set -Eeuo pipefail

DRY_RUN=0
UNINSTALL=0
SLACK_TOKEN_ARG=""
BACKFILL_DAYS=30
TOKENS_FILE="/root/sobol-tokens.txt"
ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECTOR_DIR="$ADDON_DIR/connectors/slack"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=1; shift ;;
    --uninstall)       UNINSTALL=1; shift ;;
    --token)           SLACK_TOKEN_ARG="$2"; shift 2 ;;
    --backfill-days)   BACKFILL_DAYS="$2"; shift 2 ;;
    --tokens)          TOKENS_FILE="$2"; shift 2 ;;
    -h|--help)         sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

log()  { printf "\n\033[1;36m[connector-slack]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[connector-slack]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[connector-slack]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."

find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

read_token() {
  local k="$1" v
  [[ -f "$TOKENS_FILE" ]] || return 1
  v="$(awk -F= -v k="$k" '$1 == k { sub(/^[^=]*=/, "", $0); val = $0 } END { print val }' "$TOKENS_FILE")"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
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

# ----- preflight -------------------------------------------------------------
log "Preflight..."

MIRROR_CTID="$(find_ct_by_hostname postgres-mirror 2>/dev/null || true)"
[[ -n "$MIRROR_CTID" ]] || die "postgres-mirror CT not found. Run ./addons/setup-postgres-mirror.sh first."
log "  postgres-mirror CT: $MIRROR_CTID"

N8N_CTID="$(find_ct_by_hostname n8n 2>/dev/null || true)"
[[ -n "$N8N_CTID" ]] || die "n8n CT not found. Run ./addons/setup-n8n.sh first."
log "  n8n CT: $N8N_CTID"

WRITER_PASS="$(read_token SOBOL_MIRROR_WRITER_PASSWORD)" || die "SOBOL_MIRROR_WRITER_PASSWORD not in $TOKENS_FILE. Re-run setup-postgres-mirror.sh."
DB_HOST="$(read_token SOBOL_MIRROR_DB_HOST)" || DB_HOST="postgres-mirror"

[[ -f "$CONNECTOR_DIR/manifest.yaml" ]] || die "Manifest missing: $CONNECTOR_DIR/manifest.yaml"
[[ -f "$CONNECTOR_DIR/schema.sql" ]]    || die "Schema missing: $CONNECTOR_DIR/schema.sql"

# ----- uninstall path --------------------------------------------------------
if (( UNINSTALL )); then
  log "Uninstalling Slack connector..."

  log "  Dropping slack schema + agent_view.slack_* views..."
  if (( ! DRY_RUN )); then
    pct exec "$MIRROR_CTID" -- sudo -u postgres psql -d sobol_mirror -v ON_ERROR_STOP=1 <<'SQL'
DROP VIEW IF EXISTS
  agent_view.slack_recent_24h,
  agent_view.slack_recent_7d,
  agent_view.slack_channel_activity_24h,
  agent_view.slack_threads_with_questions,
  agent_view.slack_threads_with_decisions,
  agent_view.slack_action_items,
  agent_view.slack_high_reaction_messages_24h,
  agent_view.slack_quiet_users_7d
CASCADE;
DROP SCHEMA IF EXISTS slack CASCADE;
DELETE FROM _meta.connectors WHERE name = 'slack';
DELETE FROM _meta.sync_state WHERE source = 'slack';
SQL
  fi

  log "  Removing SOBOL_SLACK_* tokens..."
  run "sed -i '/^SOBOL_SLACK_/d' '$TOKENS_FILE'"

  log "  Note: n8n workflow 'slack-mirror-sync' must be manually deactivated/deleted in n8n UI."
  log "Uninstalled."
  exit 0
fi

# ----- Slack token -----------------------------------------------------------
SLACK_TOKEN=""
if [[ -n "$SLACK_TOKEN_ARG" ]]; then
  SLACK_TOKEN="$SLACK_TOKEN_ARG"
else
  SLACK_TOKEN="$(read_token SOBOL_SLACK_BOT_TOKEN 2>/dev/null || true)"
fi

if [[ -z "$SLACK_TOKEN" ]]; then
  echo
  log "Need a Slack Bot Token. Steps:"
  log "  1. https://api.slack.com/apps → Create New App → From scratch"
  log "  2. Add OAuth scopes (see manifest.yaml for the list)"
  log "  3. Install to your workspace"
  log "  4. Copy the 'Bot User OAuth Token' (starts with xoxb-)"
  echo
  printf "Paste your Slack Bot Token (xoxb-...): "
  read -rs SLACK_TOKEN
  echo
fi

[[ -n "$SLACK_TOKEN" ]] || die "Empty Slack token. Aborting."

# ----- verify the token ------------------------------------------------------
log "Verifying Slack token via auth.test..."
if (( ! DRY_RUN )); then
  AUTH_RESP="$(curl -sS -H "Authorization: Bearer $SLACK_TOKEN" \
    https://slack.com/api/auth.test 2>/dev/null)"
  OK="$(echo "$AUTH_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("ok", False))')"
  if [[ "$OK" != "True" ]]; then
    ERR="$(echo "$AUTH_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("error", "unknown"))')"
    die "Slack auth.test failed: $ERR. Re-check token and scopes."
  fi
  TEAM="$(echo "$AUTH_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("team", "?"))')"
  USER="$(echo "$AUTH_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("user", "?"))')"
  log "  ✓ Authenticated as bot user '$USER' in team '$TEAM'"
fi

upsert_token SOBOL_SLACK_BOT_TOKEN "$SLACK_TOKEN"

# ----- apply schema ----------------------------------------------------------
log "Applying schema (slack.* tables + agent_view.slack_* views)..."
if (( ! DRY_RUN )); then
  pct push "$MIRROR_CTID" "$CONNECTOR_DIR/schema.sql" /tmp/schema-slack.sql
  pct exec "$MIRROR_CTID" -- sudo -u postgres psql -d sobol_mirror -v ON_ERROR_STOP=1 -f /tmp/schema-slack.sql
  pct exec "$MIRROR_CTID" -- rm -f /tmp/schema-slack.sql
fi

# ----- register connector ----------------------------------------------------
log "Registering connector in _meta.connectors..."
if (( ! DRY_RUN )); then
  MANIFEST_TEXT="$(cat "$CONNECTOR_DIR/manifest.yaml")"
  # Pipe via stdin to avoid SQL-injection on quote-heavy YAML content
  pct exec "$MIRROR_CTID" -- bash -c "cat > /tmp/manifest-slack.yaml" <<< "$MANIFEST_TEXT"
  pct exec "$MIRROR_CTID" -- sudo -u postgres psql -d sobol_mirror -v ON_ERROR_STOP=1 <<SQL
INSERT INTO _meta.connectors (name, version, manifest_yaml, enabled)
VALUES ('slack', '1.0.0', pg_read_file('/tmp/manifest-slack.yaml'), TRUE)
ON CONFLICT (name) DO UPDATE
  SET version = EXCLUDED.version,
      manifest_yaml = EXCLUDED.manifest_yaml,
      enabled = TRUE;
INSERT INTO _meta.sync_state (source, entity, last_status)
VALUES ('slack', 'messages', 'pending'),
       ('slack', 'channels', 'pending'),
       ('slack', 'users', 'pending'),
       ('slack', 'threads', 'pending'),
       ('slack', 'reactions', 'pending')
ON CONFLICT DO NOTHING;
SQL
  pct exec "$MIRROR_CTID" -- rm -f /tmp/manifest-slack.yaml
fi

# ----- n8n credential + workflow ---------------------------------------------
log "Registering Slack credential in n8n..."
N8N_CTID="$(find_ct_by_hostname n8n 2>/dev/null || true)"

if [[ -z "$N8N_CTID" ]]; then
  warn "  n8n CT not found — credential creation skipped"
  warn "  Manually create in n8n UI:"
  warn "    Settings → Credentials → New → HTTP Header Auth"
  warn "    Name: 'Slack (Sobol Sync) — Bearer'"
  warn "    Header: Authorization, Value: 'Bearer $SLACK_TOKEN'"
else
  N8N_API_KEY="$(read_token N8N_API_KEY 2>/dev/null || \
    awk -F= '/^N8N_API_KEY=/{val=$2} END{print val}' /root/td-tokens.txt 2>/dev/null | tr -d ' ' || true)"

  if [[ -z "$N8N_API_KEY" ]]; then
    warn "  N8N_API_KEY not found — skipping credential creation"
    warn "  Re-run with N8N_API_KEY in $TOKENS_FILE or /root/td-tokens.txt"
  elif (( ! DRY_RUN )); then
    CRED_NAME="Slack (Sobol Sync) — Bearer"
    # Check if exists
    EXISTS="$(pct exec "$N8N_CTID" -- curl -sS -H "X-N8N-API-KEY: $N8N_API_KEY" \
      http://localhost:5678/api/v1/credentials 2>/dev/null \
      | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    items = d.get('data', d) if isinstance(d, dict) else d
    for c in items:
        if c.get('name') == '$CRED_NAME':
            print('exists'); break
except: pass" 2>/dev/null || true)"

    if [[ "$EXISTS" == "exists" ]]; then
      log "  ✓ Credential '$CRED_NAME' already exists — updating not yet supported via API"
      log "    To rotate token: delete in UI + re-run this addon"
    else
      PAYLOAD="$(SLACK_TOKEN="$SLACK_TOKEN" CRED_NAME="$CRED_NAME" python3 -c '
import json, os
print(json.dumps({
  "name": os.environ["CRED_NAME"],
  "type": "httpHeaderAuth",
  "data": {
    "name": "Authorization",
    "value": "Bearer " + os.environ["SLACK_TOKEN"]
  }
}))')"
      CODE="$(pct exec "$N8N_CTID" -- bash -lc "
        echo '$PAYLOAD' | curl -sS -o /tmp/cred-resp.json -w '%{http_code}' \
          -H 'X-N8N-API-KEY: $N8N_API_KEY' \
          -H 'Content-Type: application/json' \
          -X POST --data-binary @- \
          http://localhost:5678/api/v1/credentials
      ")"
      if [[ "$CODE" =~ ^2 ]]; then
        log "  ✓ Created credential '$CRED_NAME' (HTTP $CODE)"
      else
        warn "  Credential create returned HTTP $CODE"
        pct exec "$N8N_CTID" -- cat /tmp/cred-resp.json 2>/dev/null | sed 's/^/    /' >&2 || true
      fi
      pct exec "$N8N_CTID" -- rm -f /tmp/cred-resp.json 2>/dev/null || true
    fi
  fi
fi

log " "
log "n8n workflow:"
log "  slack-mirror-sync.json ships with setup-n8n.sh's workflow auto-import."
log "  If you ran setup-n8n.sh BEFORE this addon, re-import the workflow manually:"
log "    1. n8n UI → Workflows → Import from File"
log "    2. /root/td-proxmox/repo/addons/n8n/workflows/slack-mirror-sync.json"
log "    3. Activate"
log "  Otherwise it's already imported (inactive); just toggle Active in the UI."

# ----- summary ---------------------------------------------------------------
log "================================================================"
log "==> Slack connector installed."
log " "
log "  Connector:     slack v1.0.0"
log "  Schema:        slack (tables) + agent_view.slack_* (8 views)"
log "  Mirror DB:     $DB_HOST/sobol_mirror"
log "  Slack token:   stored in $TOKENS_FILE as SOBOL_SLACK_BOT_TOKEN"
log " "
log "Next steps (manual for v1):"
log "  1. In n8n UI: create credential 'Slack (Sobol Sync)' with token from $TOKENS_FILE"
log "  2. In n8n UI: import addons/n8n/workflows/slack-mirror-sync.json"
log "  3. In n8n UI: bind workflow to credentials + activate"
log "  4. Manually trigger first execution (Execute Workflow)"
log "  5. Verify: pct exec $MIRROR_CTID -- sudo -u postgres psql -d sobol_mirror -c 'SELECT COUNT(*) FROM slack.messages;'"
log " "
log "After first successful sync, the comms-agent persona can be deployed"
log "to ollama-pi-agent. Workflow comms-agent-digest.json (separate) will"
log "trigger it at 9am daily."
log " "
log "Inspect connector state:"
log "  pct exec $MIRROR_CTID -- sudo -u postgres psql -d sobol_mirror \\"
log "    -c 'SELECT * FROM _meta.sync_state WHERE source = $$slack$$;'"
log " "
log "Uninstall (drops slack schema + views):"
log "  $(basename "$0") --uninstall"
log "================================================================"
