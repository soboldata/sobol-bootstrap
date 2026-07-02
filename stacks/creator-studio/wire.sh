#!/usr/bin/env bash
# wire.sh — Creator Studio composition wiring.
#
# Post-install glue that only makes sense because THIS specific set of
# apps (Ghost + Plausible + Cal.com + Cloudflared + Mattermost + n8n)
# is composed together on this host. Runs AFTER all library addons
# have installed AND the operator has completed manual admin signups
# and minted API keys.
#
# This is the first real wire.sh in the framework — treat it as the
# reference example. See:
#   ../../proxmox-stack-foundations/conventions.md §2.1
#     — addon-library-vs-stack-wiring rule (why this exists)
#   ../../proxmox-stack-foundations/conventions.md §2.2
#     — additive composition (why every phase is idempotent + skippable)
#
# The overall design principle: wire.sh does five independent phases.
# Each phase checks its prerequisites and either RUNS (if ready) or
# SKIPS with a clear "come back after X" message. Operator can safely
# re-run wire.sh multiple times as they complete prerequisites; already-
# done phases are no-ops.
#
# Phases:
#   1. Ghost Code Injection — inject the Plausible tracking snippet
#      into Ghost's Settings → Code Injection → Site Header via the
#      Ghost Admin API (JWT-signed with GHOST_ADMIN_API_KEY).
#   2. Cal.com event types — create `audit-consult` (30 min) and
#      `compliance-discovery` (60 min) via the Cal.com API; persist
#      URLs to studio-tokens as CALCOM_AUDIT_URL + CALCOM_COMPLIANCE_URL
#      for the intake-website form.js to consume.
#   3. Ghost webhook — register Ghost's post.published event to fire at
#      n8n's /webhook/ghost-publish endpoint.
#   4. Cal.com webhook — register Cal.com's BOOKING_CREATED event to
#      fire at n8n's /webhook/calcom-booking endpoint.
#   5. Reachability check — curl all 5 public hostnames, report which
#      return 200 through the Cloudflared tunnel.
#
# Prerequisites the operator must have set up:
#   - All library addons installed (postgres-shared, ghost, plausible,
#     calcom, cloudflared, mattermost, n8n)
#   - Cloudflared public hostnames configured in the CF Zero Trust
#     dashboard (soboldata.com, audit., cal., analytics., tracking.)
#   - Ghost admin created at /ghost/setup, admin API key minted →
#     GHOST_ADMIN_API_KEY=<id>:<secret> in studio-tokens.txt
#   - Plausible admin created at /register, tracking domain set to
#     $DOMAIN (site added under Sites)
#   - Cal.com admin created at /auth/setup, API key minted →
#     CALCOM_API_KEY=<key> in studio-tokens.txt
#   - n8n workflows imported and activated: ghost-publish-to-mattermost
#     and calcom-booking-to-mattermost
#
# Usage:
#   ./wire.sh                 # run all phases; skip those missing prereqs
#   ./wire.sh --dry-run       # preview without changes
#   ./wire.sh --phase <N>     # run only phase N (1-5)
#   ./wire.sh --skip-check    # skip phase 5 (reachability) — useful in
#                               dev when tunnel isn't fully live yet

set -Eeuo pipefail

# ----- args --------------------------------------------------------------
DRY_RUN=0
PHASE_FILTER=""
SKIP_CHECK=0
TOKENS_FILE="/root/studio-tokens.txt"
TD_TOKENS_FILE="/root/td-tokens.txt"   # for N8N_HOST + N8N tokens

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --phase)        PHASE_FILTER="$2"; shift 2 ;;
    --skip-check)   SKIP_CHECK=1; shift ;;
    --tokens-file)  TOKENS_FILE="$2"; shift 2 ;;
    -h|--help)      sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[wire]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[wire]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[wire]\033[0m %s\n" "$*" >&2; exit 1; }
skip() { printf "\n\033[1;35m[wire SKIP]\033[0m %s\n" "$*"; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -f "$TOKENS_FILE" ]] || die "$TOKENS_FILE missing — run bootstrap first."

# read_token from either studio-tokens.txt (default) or a specific file
read_token() {
  local key="$1" file="${2:-$TOKENS_FILE}" val
  [[ -f "$file" ]] || return 1
  val="$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); v = $0 } END { print v }' "$file")"
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

# should_run <phase-number> — respects --phase filter
should_run() {
  [[ -z "$PHASE_FILTER" || "$PHASE_FILTER" == "$1" ]]
}

# Load the common tokens all phases share
DOMAIN="$(read_token DOMAIN || die "DOMAIN missing from $TOKENS_FILE")"

# ----- state tracking (for summary at the end) --------------------------
declare -A PHASE_STATUS
mark() { PHASE_STATUS[$1]="$2"; }

# ============================================================================
# Phase 1 — Ghost Code Injection: inject Plausible tracking snippet
# ============================================================================
phase_1_ghost_plausible() {
  should_run 1 || return 0
  log "─── Phase 1: Ghost Code Injection ← Plausible tracking snippet ───"

  local api_key ghost_ctid ghost_ip
  api_key="$(read_token GHOST_ADMIN_API_KEY || echo '')"

  if [[ -z "$api_key" ]]; then
    skip "GHOST_ADMIN_API_KEY missing. Mint at https://$DOMAIN/ghost → Settings → Integrations → Add custom integration, save as GHOST_ADMIN_API_KEY=<id>:<secret> to $TOKENS_FILE, then re-run --phase 1."
    mark 1 "SKIP (no api key)"; return 0
  fi

  if ! [[ "$api_key" =~ ^[a-f0-9]{24}:[a-f0-9]{64}$ ]]; then
    skip "GHOST_ADMIN_API_KEY doesn't match Ghost's <24-hex>:<64-hex> shape. Value looks malformed — re-mint + re-save."
    mark 1 "SKIP (malformed api key)"; return 0
  fi

  ghost_ctid="$(read_token GHOST_CTID || echo 300)"
  ghost_ip="$(pct exec "$ghost_ctid" -- hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ghost_ip" ]] || { skip "Ghost CT $ghost_ctid not reachable"; mark 1 "SKIP (ghost down)"; return 0; }

  local tracking_snippet="<script defer data-domain=\"$DOMAIN\" src=\"https://tracking.$DOMAIN/js/script.js\"></script>"
  log "  Snippet to inject:"
  log "    $tracking_snippet"

  # Ghost Admin API needs a JWT signed with the key secret. Use python
  # inline — bash HMAC is doable but fiddly. Reads GHOST_ADMIN_API_KEY
  # from env so it never appears on the command line (redacted in ps aux).
  local jwt
  if (( DRY_RUN )); then
    printf "[dry-run] would mint JWT + PUT /ghost/api/admin/settings/\n"
    mark 1 "DRY-RUN"; return 0
  fi

  jwt="$(GHOST_ADMIN_API_KEY="$api_key" python3 <<'PYEOF'
import base64, hashlib, hmac, json, os, time
kid, secret_hex = os.environ["GHOST_ADMIN_API_KEY"].split(":", 1)
secret = bytes.fromhex(secret_hex)

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")

header  = b64url(json.dumps({"alg":"HS256","typ":"JWT","kid":kid}).encode())
payload = b64url(json.dumps({"iat":int(time.time()),"exp":int(time.time())+300,"aud":"/admin/"}).encode())
msg = header + b"." + payload
sig = b64url(hmac.new(secret, msg, hashlib.sha256).digest())
print((msg + b"." + sig).decode())
PYEOF
)"

  # First GET the current settings so we can preserve any existing head
  # injection the operator might have set through the UI.
  local current_head
  current_head="$(curl -sf -H "Authorization: Ghost $jwt" \
    "http://${ghost_ip}:2368/ghost/api/admin/settings/" 2>/dev/null | \
    python3 -c "import json,sys;d=json.load(sys.stdin);s={x['key']:x.get('value','') for x in d.get('settings',[])};print(s.get('codeinjection_head','') or '')" 2>/dev/null || echo "")"

  # Idempotence — if the snippet is already there, skip.
  if [[ "$current_head" == *"data-domain=\"$DOMAIN\""* ]] && [[ "$current_head" == *"tracking.$DOMAIN"* ]]; then
    log "  Plausible tracking snippet already present in Ghost head — SKIP (idempotent)"
    mark 1 "IDEMPOTENT SKIP"; return 0
  fi

  # Append (rather than replace) — preserve anything the operator put in
  local new_head
  new_head="$(printf '%s\n%s' "${current_head}" "$tracking_snippet" | sed 's/^$//')"

  # PUT the updated setting
  local body
  body="$(NEW_HEAD="$new_head" python3 -c "import json,os;print(json.dumps({'settings':[{'key':'codeinjection_head','value':os.environ['NEW_HEAD']}]}))")"

  local result
  result="$(curl -sf -X PUT \
    -H "Authorization: Ghost $jwt" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "http://${ghost_ip}:2368/ghost/api/admin/settings/" 2>&1)" || {
    warn "  PUT /ghost/api/admin/settings/ failed:"
    warn "  $result"
    mark 1 "FAIL"
    return 0
  }

  log "  ✓ Plausible tracking snippet injected into Ghost Code Injection → Site Header"
  mark 1 "SUCCESS"
}

# ============================================================================
# Phase 2 — Cal.com event types: audit-consult + compliance-discovery
# ============================================================================
phase_2_calcom_event_types() {
  should_run 2 || return 0
  log "─── Phase 2: Cal.com event types (audit-consult + compliance-discovery) ───"

  local api_key calcom_ctid calcom_ip
  api_key="$(read_token CALCOM_API_KEY || echo '')"

  if [[ -z "$api_key" ]]; then
    skip "CALCOM_API_KEY missing. Mint at https://cal.$DOMAIN → Settings → Developer → API keys → Add. Save as CALCOM_API_KEY to $TOKENS_FILE, then re-run --phase 2."
    mark 2 "SKIP (no api key)"; return 0
  fi

  calcom_ctid="$(read_token CALCOM_CTID || echo 302)"
  calcom_ip="$(pct exec "$calcom_ctid" -- hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$calcom_ip" ]] || { skip "Cal.com CT $calcom_ctid not reachable"; mark 2 "SKIP (calcom down)"; return 0; }

  # Cal.com event type spec:
  #   audit-consult      — 30 min, business audit conversation
  #   compliance-discovery — 60 min, Lane B compliance path per
  #                          intake-website/workshop-decisions.md
  local -a event_types=(
    "audit-consult:30:Audit consult:Business audit discovery conversation"
    "compliance-discovery:60:Compliance discovery:Compliance-lane discovery call (Lane B per intake-website)"
  )

  # Create idempotently — GET existing first, only POST what's missing
  local existing
  existing="$(curl -sf -H "Authorization: Bearer $api_key" \
    "http://${calcom_ip}:3000/api/v2/event-types" 2>/dev/null || echo '{"data":[]}')"

  for et in "${event_types[@]}"; do
    IFS=':' read -r slug length title description <<<"$et"

    # Idempotence check by slug
    local exists
    exists="$(echo "$existing" | SLUG="$slug" python3 -c "import json,sys,os;d=json.load(sys.stdin);slugs=[e.get('slug','') for e in d.get('data',[])];print('yes' if os.environ['SLUG'] in slugs else 'no')" 2>/dev/null || echo "no")"

    if [[ "$exists" == "yes" ]]; then
      log "  '$slug' already exists — SKIP (idempotent)"
      # Still persist the URL to tokens in case wire.sh is re-run on a
      # fresh tokens file
      local url="https://cal.$DOMAIN/admin/$slug"
      case "$slug" in
        audit-consult)         upsert_token CALCOM_AUDIT_URL "$url" ;;
        compliance-discovery)  upsert_token CALCOM_COMPLIANCE_URL "$url" ;;
      esac
      continue
    fi

    if (( DRY_RUN )); then
      printf "[dry-run] would POST /api/v2/event-types (%s, %d min)\n" "$slug" "$length"
      continue
    fi

    local body
    body="$(python3 <<PYEOF
import json
print(json.dumps({
    "lengthInMinutes": $length,
    "title": "$title",
    "slug": "$slug",
    "description": "$description"
}))
PYEOF
)"

    local result
    result="$(curl -sf -X POST \
      -H "Authorization: Bearer $api_key" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "http://${calcom_ip}:3000/api/v2/event-types" 2>&1)" || {
      warn "  POST /api/v2/event-types for '$slug' failed:"
      warn "  $result"
      continue
    }

    log "  ✓ Created event type: $slug ($length min)"

    # Persist the public URL to tokens
    local url="https://cal.$DOMAIN/admin/$slug"
    case "$slug" in
      audit-consult)         upsert_token CALCOM_AUDIT_URL "$url" ;;
      compliance-discovery)  upsert_token CALCOM_COMPLIANCE_URL "$url" ;;
    esac
    log "  ↳ URL persisted to $TOKENS_FILE"
  done

  mark 2 "SUCCESS"
}

# ============================================================================
# Phase 3 — Ghost webhook wiring → n8n
# ============================================================================
phase_3_ghost_webhook() {
  should_run 3 || return 0
  log "─── Phase 3: Ghost post.published webhook → n8n ───"

  local api_key ghost_ctid ghost_ip n8n_host
  api_key="$(read_token GHOST_ADMIN_API_KEY || echo '')"
  n8n_host="$(read_token N8N_HOST "$TD_TOKENS_FILE" || read_token N8N_HOST || echo '')"

  [[ -n "$api_key" ]] || { skip "GHOST_ADMIN_API_KEY missing (see phase 1)"; mark 3 "SKIP"; return 0; }
  [[ -n "$n8n_host" ]] || { skip "N8N_HOST unknown — expected in td-tokens.txt or studio-tokens.txt"; mark 3 "SKIP"; return 0; }

  ghost_ctid="$(read_token GHOST_CTID || echo 300)"
  ghost_ip="$(pct exec "$ghost_ctid" -- hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ghost_ip" ]] || { skip "Ghost CT $ghost_ctid not reachable"; mark 3 "SKIP"; return 0; }

  local webhook_url="http://${n8n_host}:5678/webhook/ghost-publish"
  log "  Target: $webhook_url"

  if (( DRY_RUN )); then
    printf "[dry-run] would POST /ghost/api/admin/webhooks/\n"
    mark 3 "DRY-RUN"; return 0
  fi

  # Mint JWT (same pattern as phase 1)
  local jwt
  jwt="$(GHOST_ADMIN_API_KEY="$api_key" python3 <<'PYEOF'
import base64, hashlib, hmac, json, os, time
kid, secret_hex = os.environ["GHOST_ADMIN_API_KEY"].split(":", 1)
secret = bytes.fromhex(secret_hex)
def b64url(d): return base64.urlsafe_b64encode(d).rstrip(b"=")
header  = b64url(json.dumps({"alg":"HS256","typ":"JWT","kid":kid}).encode())
payload = b64url(json.dumps({"iat":int(time.time()),"exp":int(time.time())+300,"aud":"/admin/"}).encode())
msg = header + b"." + payload
sig = b64url(hmac.new(secret, msg, hashlib.sha256).digest())
print((msg + b"." + sig).decode())
PYEOF
)"

  # Idempotence — GET existing webhooks, skip if one already targets our URL
  local existing_targets
  existing_targets="$(curl -sf -H "Authorization: Ghost $jwt" \
    "http://${ghost_ip}:2368/ghost/api/admin/webhooks/" 2>/dev/null | \
    python3 -c "import json,sys;d=json.load(sys.stdin);print('\n'.join(w.get('target_url','') for w in d.get('webhooks',[])))" 2>/dev/null || echo "")"

  if echo "$existing_targets" | grep -qF "$webhook_url"; then
    log "  Ghost webhook already registered for this URL — SKIP (idempotent)"
    mark 3 "IDEMPOTENT SKIP"; return 0
  fi

  local body
  body="$(python3 <<PYEOF
import json
print(json.dumps({"webhooks":[{
    "event":"post.published",
    "target_url":"$webhook_url",
    "name":"creator-studio: publish → mattermost"
}]}))
PYEOF
)"

  local result
  result="$(curl -sf -X POST \
    -H "Authorization: Ghost $jwt" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "http://${ghost_ip}:2368/ghost/api/admin/webhooks/" 2>&1)" || {
    warn "  POST /ghost/api/admin/webhooks/ failed:"
    warn "  $result"
    mark 3 "FAIL"
    return 0
  }

  log "  ✓ Ghost webhook registered: post.published → $webhook_url"
  mark 3 "SUCCESS"
}

# ============================================================================
# Phase 4 — Cal.com webhook wiring → n8n
# ============================================================================
phase_4_calcom_webhook() {
  should_run 4 || return 0
  log "─── Phase 4: Cal.com BOOKING_CREATED webhook → n8n ───"

  local api_key calcom_ctid calcom_ip n8n_host
  api_key="$(read_token CALCOM_API_KEY || echo '')"
  n8n_host="$(read_token N8N_HOST "$TD_TOKENS_FILE" || read_token N8N_HOST || echo '')"

  [[ -n "$api_key" ]] || { skip "CALCOM_API_KEY missing (see phase 2)"; mark 4 "SKIP"; return 0; }
  [[ -n "$n8n_host" ]] || { skip "N8N_HOST unknown"; mark 4 "SKIP"; return 0; }

  calcom_ctid="$(read_token CALCOM_CTID || echo 302)"
  calcom_ip="$(pct exec "$calcom_ctid" -- hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$calcom_ip" ]] || { skip "Cal.com CT $calcom_ctid not reachable"; mark 4 "SKIP"; return 0; }

  local webhook_url="http://${n8n_host}:5678/webhook/calcom-booking"
  log "  Target: $webhook_url"

  if (( DRY_RUN )); then
    printf "[dry-run] would POST /api/v2/webhooks\n"
    mark 4 "DRY-RUN"; return 0
  fi

  # Idempotence — GET existing webhooks first
  local existing_targets
  existing_targets="$(curl -sf -H "Authorization: Bearer $api_key" \
    "http://${calcom_ip}:3000/api/v2/webhooks" 2>/dev/null | \
    python3 -c "import json,sys;d=json.load(sys.stdin);print('\n'.join(w.get('subscriberUrl','') for w in d.get('data',[])))" 2>/dev/null || echo "")"

  if echo "$existing_targets" | grep -qF "$webhook_url"; then
    log "  Cal.com webhook already registered for this URL — SKIP (idempotent)"
    mark 4 "IDEMPOTENT SKIP"; return 0
  fi

  # Cal.com v2 webhook body — kept minimal (unknown fields sometimes 400)
  local body
  body="$(python3 <<PYEOF
import json
print(json.dumps({
    "subscriberUrl":"$webhook_url",
    "triggers":["BOOKING_CREATED","BOOKING_RESCHEDULED","BOOKING_CANCELLED"],
    "active":True
}))
PYEOF
)"

  local result
  result="$(curl -sf -X POST \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "http://${calcom_ip}:3000/api/v2/webhooks" 2>&1)" || {
    warn "  POST /api/v2/webhooks failed:"
    warn "  $result"
    mark 4 "FAIL"
    return 0
  }

  log "  ✓ Cal.com webhook registered for BOOKING_* → $webhook_url"
  mark 4 "SUCCESS"
}

# ============================================================================
# Phase 5 — Public reachability check
# ============================================================================
phase_5_reachability() {
  should_run 5 || return 0
  (( SKIP_CHECK )) && { skip "Phase 5 explicitly skipped via --skip-check"; mark 5 "SKIP (--skip-check)"; return 0; }

  log "─── Phase 5: Public reachability check ───"

  local -a urls=(
    "https://$DOMAIN/"
    "https://audit.$DOMAIN/"
    "https://cal.$DOMAIN/"
    "https://analytics.$DOMAIN/"
    "https://tracking.$DOMAIN/js/script.js"
  )

  local up=0 down=0
  for url in "${urls[@]}"; do
    if curl -sf -m 10 -o /dev/null "$url" 2>/dev/null; then
      log "  ✓ $url"
      ((up++))
    else
      warn "  ✗ $url — no 200 response"
      ((down++))
    fi
  done

  if (( down == 0 )); then
    log "  All 5 public hostnames reachable."
    mark 5 "SUCCESS ($up/5)"
  else
    warn "  $up/5 reachable, $down not yet."
    warn "  Common causes: (a) public hostnames not yet configured in the CF"
    warn "    Zero Trust dashboard, (b) upstream service isn't running,"
    warn "    (c) DNS still propagating."
    mark 5 "PARTIAL ($up/5)"
  fi
}

# ============================================================================
# Main
# ============================================================================
log "================================================================"
log "creator-studio wire.sh — composition glue"
log "  Domain:        $DOMAIN"
log "  Tokens file:   $TOKENS_FILE"
log "  Phase filter:  ${PHASE_FILTER:-all}"
(( DRY_RUN )) && log "  Mode:          DRY-RUN"
log "================================================================"

phase_1_ghost_plausible || true
phase_2_calcom_event_types || true
phase_3_ghost_webhook || true
phase_4_calcom_webhook || true
phase_5_reachability || true

# ----- summary -----------------------------------------------------------
log "================================================================"
log "Summary"
log "================================================================"
for p in 1 2 3 4 5; do
  status="${PHASE_STATUS[$p]:-not run}"
  printf "  Phase %d: %s\n" "$p" "$status"
done
log " "
log "Re-run with --phase <N> to retry a single phase after fixing prereqs."
log "================================================================"
