#!/usr/bin/env bash
# setup-cloudflared.sh — The "go public" moment.
#
# Installs cloudflared as a systemd-managed connector on the cloudflared
# CT, registers with Cloudflare using CF_TUNNEL_TOKEN, and lets the
# operator manage ingress rules in the Cloudflare Zero Trust dashboard.
#
# We deliberately use the DASHBOARD-FIRST model rather than the legacy
# local-config.yml model:
#   - Simpler: one token, no cert/credential JSON to shuttle around
#   - Ingress hostname edits go through the CF UI (auditable, non-root)
#   - DNS CNAME records are auto-created when hostnames are added
#   - Rotating a compromised token is one dashboard click, not a
#     multi-file replay
#
# The trade-off: ingress rules aren't in-repo. That's acceptable because
# the hostnames + upstream URLs are customer-facing config that should
# live in the CF org anyway (that's who gets paged when soboldata.com is
# down, not the addon library).
#
# CF API automation (create tunnel + configure ingress + create DNS
# records all programmatically) is DEFERRED to a future version — it
# needs CF_API_TOKEN with broad scopes and adds significant complexity
# for marginal benefit at MVP. Documented in the success banner.
#
# Follows the additive-composition rules (conventions.md §2.2):
#   - Detects existing install, only re-registers if token changed
#   - Systemd unit management is idempotent
#   - Uninstall path removes service + binary cleanly
#
# Assumptions on entry:
#   - The Cloudflared CT exists and is running (community-scripts ct
#     debian.sh or equivalent — this is a lightweight CT, 1 CPU / 512MB
#     is plenty)
#   - Operator has already created a Tunnel in the Cloudflare Zero Trust
#     dashboard (Networks → Tunnels → Create tunnel) and saved the
#     TUNNEL_TOKEN to studio-tokens.txt as CF_TUNNEL_TOKEN
#   - Operator has added public hostnames in the dashboard pointing at
#     the internal CT tailnet IPs (soboldata.com → http://ghost:2368,
#     cal.soboldata.com → http://calcom:3000, etc.)
#
# What it does (idempotent at every step):
#   1. Reads CLOUDFLARED_CTID + DOMAIN + CF_TUNNEL_TOKEN from tokens
#   2. Pre-flight — CT exists and is running
#   3. Downloads cloudflared .deb (pinned version) and installs
#   4. Checks whether cloudflared.service already exists AND is using
#      the current token (compares against a hash file we write). If
#      yes → SKIP with "already configured for this token". If no →
#      registers as service using `cloudflared service install`.
#   5. Enables + starts the service
#   6. Waits for tunnel connections to establish (queries metrics
#      endpoint on port 2000; up to 60s)
#   7. Optional external verification — if DOMAIN is set, curl the root
#      URL from the PVE host and check for a 200. If not 200, WARN but
#      don't fail (the operator may still be adding hostnames in CF UI).
#   8. Registers a Homepage tile (dashboard link)
#   9. Success banner with the CF dashboard next-steps + the ingress
#      mapping the operator should have set up
#
# Usage:
#   ./setup-cloudflared.sh                     # default
#   ./setup-cloudflared.sh --dry-run           # preview
#   ./setup-cloudflared.sh --reinstall         # force re-registration
#                                                (needed if token was rotated)
#   ./setup-cloudflared.sh --uninstall         # stop service + remove binary
#   ./setup-cloudflared.sh --tokens-file PATH

set -Eeuo pipefail

# ----- args --------------------------------------------------------------
DRY_RUN=0
REINSTALL=0
UNINSTALL=0
# Auto-detect tokens file. --tokens-file arg overrides.
TOKENS_FILE=""
for _tokf in /root/studio-tokens.txt /root/td-tokens.txt /root/sobol-tokens.txt; do
  [[ -f "$_tokf" ]] && { TOKENS_FILE="$_tokf"; break; }
done
unset _tokf

# Pinned version — override with env var to bump
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-2025.5.0}"
CLOUDFLARED_ARCH="${CLOUDFLARED_ARCH:-amd64}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --reinstall)    REINSTALL=1; shift ;;
    --uninstall)    UNINSTALL=1; shift ;;
    --tokens-file)  TOKENS_FILE="$2"; shift 2 ;;
    -h|--help)      sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[cloudflared]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[cloudflared]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[cloudflared]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

# Redact a token for logging — first 8 chars + ellipsis
redact() { local s="$1"; printf '%s...' "${s:0:8}"; }

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

pct_exec() {
  local ctid="$1"; shift
  pct exec "$ctid" -- bash -c "$*"
}

# ----- pre-flight --------------------------------------------------------
log "Pre-flight..."

CLOUDFLARED_CTID="$(read_token CLOUDFLARED_CTID || echo 304)"

# Soft-fail on missing prerequisites so setup-stack.sh's addon loop
# doesn't die and abort the whole install. Prints the "come back after"
# note and exits 0. Operator finishes CF setup, adds tokens, re-runs.
# Same pattern as setup-pve-email.sh's SMTP_HOST-missing skip.
if (( ! UNINSTALL )); then
  DOMAIN="$(read_token DOMAIN 2>/dev/null || true)"
  CF_TUNNEL_TOKEN="$(read_token CF_TUNNEL_TOKEN 2>/dev/null || true)"

  MISSING=()
  [[ -z "$DOMAIN" ]] && MISSING+=("DOMAIN")
  [[ -z "$CF_TUNNEL_TOKEN" ]] && MISSING+=("CF_TUNNEL_TOKEN")

  if (( ${#MISSING[@]} > 0 )); then
    warn "Cloudflared install skipped — missing from $TOKENS_FILE: ${MISSING[*]}"
    warn ""
    warn "  To enable:"
    warn "    1. Create a tunnel in Cloudflare Zero Trust dashboard:"
    warn "       Networks → Tunnels → Create tunnel"
    warn "    2. Copy the TUNNEL_TOKEN (a long eyJh... string)"
    warn "    3. Add to $TOKENS_FILE:"
    warn "         DOMAIN=your-domain.com"
    warn "         CF_TUNNEL_TOKEN=eyJh..."
    warn "    4. Re-run this addon (or setup-stack.sh <stack> --continue)"
    warn ""
    warn "  Skipping cloudflared install. Other addons proceed normally."
    exit 0
  fi
fi

# CT detection or auto-create — mirrors setup-postgres-shared.sh #267 pattern.
CLOUDFLARED_HOSTNAME="${CLOUDFLARED_HOSTNAME:-cloudflared}"
CLOUDFLARED_HELPER_URL="${CLOUDFLARED_HELPER_URL:-https://github.com/community-scripts/ProxmoxVE/raw/main/ct/cloudflared.sh}"
TS_AUTHKEY_LOCAL="$(read_token TS_AUTHKEY || true)"
CT_PASSWORD_LOCAL="$(read_token CT_PASSWORD || true)"

# Source ct-helpers if available (ct_wait_ready, ts_ensure_joined)
if [[ -r "$(dirname "${BASH_SOURCE[0]}")/lib/ct-helpers.sh" ]]; then
  # shellcheck source=lib/ct-helpers.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib/ct-helpers.sh"
fi

find_ct_by_hostname_local() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

EXISTING_CTID="$(find_ct_by_hostname_local "$CLOUDFLARED_HOSTNAME" 2>/dev/null || true)"
if [[ -n "$EXISTING_CTID" ]]; then
  log "  Found existing CT $EXISTING_CTID ($CLOUDFLARED_HOSTNAME) — using it."
  CLOUDFLARED_CTID="$EXISTING_CTID"
elif (( ! UNINSTALL )); then
  log "  No CT named '$CLOUDFLARED_HOSTNAME' found — creating via community-scripts cloudflared.sh..."
  [[ -n "$CT_PASSWORD_LOCAL" ]] || die "CT_PASSWORD required in $TOKENS_FILE to create a new CT."

  # Auto-allocate CTID if the preferred one is taken
  if pct status "$CLOUDFLARED_CTID" >/dev/null 2>&1; then
    CLOUDFLARED_CTID="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"')"
    log "  Preferred CTID taken; auto-allocated $CLOUDFLARED_CTID."
  fi

  # SSH pubkey pick from authorized_keys (skip PVE auto-generated)
  PVE_HOST="$(hostname -s)"
  SSH_KEY=""
  [[ -f /root/.ssh/authorized_keys ]] && \
    SSH_KEY="$(awk -v skip="root@$PVE_HOST" '/^ssh-/ && $NF != skip { print; exit }' /root/.ssh/authorized_keys)"

  # Fetch helper to tempfile (fail-loud if 404)
  HELPER_TMP="$(mktemp /tmp/cf-helper.XXXXXX.sh)"
  if ! curl -fsSL "$CLOUDFLARED_HELPER_URL" -o "$HELPER_TMP" || [[ ! -s "$HELPER_TMP" ]]; then
    rm -f "$HELPER_TMP"
    die "Cloudflared helper fetch failed or returned empty. URL: $CLOUDFLARED_HELPER_URL
  Check community-scripts current layout: https://community-scripts.github.io/ProxmoxVE/scripts
  Override with: CLOUDFLARED_HELPER_URL=<url> $0"
  fi

  var_ctid="$CLOUDFLARED_CTID" \
  var_hostname="$CLOUDFLARED_HOSTNAME" \
  var_ssh=yes \
  var_ssh_authorized_key="$SSH_KEY" \
  var_gpu=no \
  bash "$HELPER_TMP"
  rm -f "$HELPER_TMP"

  # Detect actual CTID
  ACTUAL_CTID="$(find_ct_by_hostname_local "$CLOUDFLARED_HOSTNAME" 2>/dev/null || true)"
  if [[ -n "$ACTUAL_CTID" && "$ACTUAL_CTID" != "$CLOUDFLARED_CTID" ]]; then
    log "  Helper assigned CTID $ACTUAL_CTID — switching."
    CLOUDFLARED_CTID="$ACTUAL_CTID"
  fi
  [[ -n "$CLOUDFLARED_CTID" ]] || die "Cloudflared CT didn't come up — see community-scripts output above."
  # Persist for future runs
  if grep -q "^CLOUDFLARED_CTID=" "$TOKENS_FILE" 2>/dev/null; then
    sed -i "s|^CLOUDFLARED_CTID=.*|CLOUDFLARED_CTID=$CLOUDFLARED_CTID|" "$TOKENS_FILE"
  else
    echo "CLOUDFLARED_CTID=$CLOUDFLARED_CTID" >> "$TOKENS_FILE"
  fi

  # TUN passthrough + reboot
  CT_CONF="/etc/pve/lxc/$CLOUDFLARED_CTID.conf"
  if ! grep -q "/dev/net/tun" "$CT_CONF" 2>/dev/null; then
    log "  Adding /dev/net/tun passthrough..."
    cat >> "$CT_CONF" <<'TUN_BLOCK'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
TUN_BLOCK
    pct reboot "$CLOUDFLARED_CTID"
    log "  Waiting for CT to come back after reboot..."
    declare -F ct_wait_ready >/dev/null && ct_wait_ready "$CLOUDFLARED_CTID" || sleep 15
  fi

  # Tailscale install + join
  if [[ -n "$TS_AUTHKEY_LOCAL" ]] && declare -F ts_ensure_joined >/dev/null; then
    log "  Installing tailscale + joining tailnet as '$CLOUDFLARED_HOSTNAME'..."
    if ! pct exec "$CLOUDFLARED_CTID" -- tailscale --version >/dev/null 2>&1; then
      pct exec "$CLOUDFLARED_CTID" -- bash -lc '
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
    ts_ensure_joined "$CLOUDFLARED_CTID" "$TS_AUTHKEY_LOCAL" "$CLOUDFLARED_HOSTNAME" || \
      warn "  Tailscale join returned non-zero — continuing."
  fi
fi

# Final running check
[[ "$(pct status "$CLOUDFLARED_CTID")" == *running* ]] || \
  { log "Starting CT $CLOUDFLARED_CTID..."; run "pct start $CLOUDFLARED_CTID"; sleep 3; }

log "  Cloudflared CTID: $CLOUDFLARED_CTID"
log "  Domain:           $DOMAIN"
(( UNINSTALL )) || log "  CF Tunnel Token:  $(redact "$CF_TUNNEL_TOKEN")"

# ----- uninstall path ----------------------------------------------------
if (( UNINSTALL )); then
  log "Uninstall mode — stopping service, removing cloudflared..."
  run "pct exec $CLOUDFLARED_CTID -- bash -c 'systemctl disable --now cloudflared 2>/dev/null || true'"
  run "pct exec $CLOUDFLARED_CTID -- bash -c 'cloudflared service uninstall 2>/dev/null || true'"
  run "pct exec $CLOUDFLARED_CTID -- bash -c 'apt-get remove -y cloudflared 2>/dev/null || true'"
  run "pct exec $CLOUDFLARED_CTID -- rm -f /etc/cloudflared/.token-hash"
  log "Uninstall complete. CF tunnel + DNS records in the Cloudflare"
  log "dashboard are NOT touched — delete those manually if you want to"
  log "fully retire the tunnel."
  exit 0
fi

# ----- Install cloudflared -----------------------------------------------
INSTALLED_VERSION="$(pct_exec "$CLOUDFLARED_CTID" "cloudflared --version 2>/dev/null | head -1 | awk '{print \$3}'" || echo "")"

if [[ "$INSTALLED_VERSION" == "$CLOUDFLARED_VERSION" ]]; then
  log "cloudflared $CLOUDFLARED_VERSION already installed."
else
  if [[ -n "$INSTALLED_VERSION" ]]; then
    log "Upgrading cloudflared: $INSTALLED_VERSION → $CLOUDFLARED_VERSION..."
  else
    log "Installing cloudflared $CLOUDFLARED_VERSION..."
  fi
  DEB_URL="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${CLOUDFLARED_ARCH}.deb"
  run "pct exec $CLOUDFLARED_CTID -- bash -c \"apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null\""
  run "pct exec $CLOUDFLARED_CTID -- bash -c \"curl -fsSL -o /tmp/cloudflared.deb '$DEB_URL' && dpkg -i /tmp/cloudflared.deb 2>&1 | tail -3 && rm -f /tmp/cloudflared.deb\""
fi

# ----- Register service --------------------------------------------------
# We track the currently-registered token via a hash file so re-runs can
# tell 'same token, skip' from 'token rotated, re-register'. We NEVER
# write the token itself to disk in cleartext beyond what cloudflared's
# own service install does.
TOKEN_HASH="$(printf '%s' "$CF_TUNNEL_TOKEN" | sha256sum | awk '{print $1}')"
STORED_HASH="$(pct_exec "$CLOUDFLARED_CTID" "cat /etc/cloudflared/.token-hash 2>/dev/null" || echo "")"

if [[ "$TOKEN_HASH" == "$STORED_HASH" ]] && (( ! REINSTALL )); then
  log "Service already registered with this token — SKIP registration."
else
  if (( REINSTALL )); then
    log "REINSTALL flag set — re-registering cloudflared service..."
  elif [[ -n "$STORED_HASH" ]]; then
    log "Token has changed since last install — re-registering service..."
  else
    log "First-time service registration..."
  fi

  # Uninstall previous service (if any) so cloudflared service install
  # gets a clean slate — otherwise it errors 'service already installed'.
  run "pct exec $CLOUDFLARED_CTID -- bash -c 'cloudflared service uninstall 2>/dev/null || true'"

  # Register — this creates the systemd unit + starts the service.
  # Token is passed as arg (into the CT), then written into a config
  # inside the CT by cloudflared itself. Redact for logging.
  if (( ! DRY_RUN )); then
    pct exec "$CLOUDFLARED_CTID" -- bash -c "cloudflared service install '$CF_TUNNEL_TOKEN'" 2>&1 | \
      sed "s|$CF_TUNNEL_TOKEN|$(redact "$CF_TUNNEL_TOKEN")|g" | sed 's/^/    /'
  else
    printf "[dry-run] cloudflared service install <TOKEN>\n"
  fi

  # Persist the token hash so future re-runs know 'same token'
  run "pct exec $CLOUDFLARED_CTID -- bash -c 'mkdir -p /etc/cloudflared && printf %s $TOKEN_HASH > /etc/cloudflared/.token-hash && chmod 600 /etc/cloudflared/.token-hash'"
fi

# ----- Ensure service is enabled + running -------------------------------
log "Ensuring cloudflared service is enabled + running..."
run "pct exec $CLOUDFLARED_CTID -- systemctl enable --now cloudflared"

# ----- Wait for tunnel connections ---------------------------------------
# cloudflared exposes metrics on port 2000 by default. Poll for
# tunnel_ha_connections > 0 (or the service just being active if that
# port isn't reachable — some cloudflared versions gate the port).
log "Waiting for tunnel to connect to Cloudflare edge..."
CONNECTED=0
for i in $(seq 1 60); do
  # Prefer the metrics endpoint if we can hit it
  if pct_exec "$CLOUDFLARED_CTID" "curl -sf -m 2 http://localhost:2000/metrics 2>/dev/null | grep -q 'cloudflared_tunnel_ha_connections [1-9]'"; then
    log "  Tunnel HA connections active (${i}s)"
    CONNECTED=1
    break
  fi
  # Fall back to systemd-active check
  if pct_exec "$CLOUDFLARED_CTID" "systemctl is-active --quiet cloudflared && journalctl -u cloudflared --since '30 sec ago' | grep -q 'Registered tunnel connection'"; then
    log "  Service active + tunnel registered per journalctl (${i}s)"
    CONNECTED=1
    break
  fi
  sleep 1
done
(( CONNECTED )) || warn "  Tunnel didn't confirm connection in 60s. Check inside CT: 'journalctl -u cloudflared -n 50'"

# ----- Optional external reachability check ------------------------------
# If the operator has already added public hostnames in the CF dashboard,
# curling the root URL should work through the tunnel. If not, this warns
# but doesn't fail — the operator may be mid-setup.
log "External reachability check (root URL)..."
if curl -sf -m 8 -o /dev/null "https://$DOMAIN/"; then
  log "  ✓ https://$DOMAIN/ reachable through the tunnel"
else
  warn "  ✗ https://$DOMAIN/ not returning 200 yet."
  warn "  Likely: (a) public hostnames not yet added in CF dashboard, or"
  warn "  (b) upstream service (Ghost) isn't responding, or (c) DNS not yet"
  warn "  propagated. Check the CF dashboard: Networks → Tunnels → <yours>"
  warn "  → Public Hostname tab. Expected mapping documented in the banner."
fi

# ----- Homepage tile -----------------------------------------------------
HOMEPAGE_CTID="$(read_token HOMEPAGE_CTID 2>/dev/null || echo 110)"
if pct status "$HOMEPAGE_CTID" >/dev/null 2>&1; then
  log "Registering Homepage tile..."
  TILE_BLOCK="$(cat <<EOF

# TD-Addon: cloudflared
- Infrastructure:
    - Cloudflare Tunnel:
        href: https://one.dash.cloudflare.com
        description: Tunnel connector (mgmt in CF dashboard)
        icon: cloudflare.png
EOF
)"
  if (( ! DRY_RUN )); then
    if ! pct_exec "$HOMEPAGE_CTID" "grep -q '# TD-Addon: cloudflared' /etc/homepage/services.yaml 2>/dev/null"; then
      echo "$TILE_BLOCK" | pct exec "$HOMEPAGE_CTID" -- bash -c "cat >> /etc/homepage/services.yaml"
      pct exec "$HOMEPAGE_CTID" -- systemctl restart homepage 2>/dev/null || true
      log "  Tile added."
    else
      log "  Tile already registered — skipping (idempotent)."
    fi
  fi
fi

# ----- Success banner ----------------------------------------------------
log "================================================================"
log "Cloudflared setup complete."
log " "
log "  Connector CT:    CT $CLOUDFLARED_CTID"
log "  Tunnel token:    $(redact "$CF_TUNNEL_TOKEN") (in $TOKENS_FILE)"
log "  Root domain:     https://$DOMAIN"
log " "
log "Ingress mapping expected in CF Zero Trust dashboard:"
log "  Networks → Tunnels → <your tunnel> → Public Hostname"
log " "
log "  Add these (adjust internal hostnames as needed):"
log "    soboldata.com               → http://ghost:2368"
log "    audit.soboldata.com         → http://ghost:2368"
log "    cal.soboldata.com           → http://calcom:3000"
log "    analytics.soboldata.com     → http://plausible:8000"
log "    tracking.soboldata.com      → http://plausible:8000"
log " "
log "The DNS CNAME records are auto-created when hostnames are added."
log " "
log "Post-launch checklist (for stack-specific wire.sh — see"
log "stacks/creator-studio/wire.sh once written):"
log "  - Verify all 5 URLs return 200"
log "  - Tighten n8n workflow CORS from '*' to the specific hostnames"
log "  - Confirm Ghost + Cal.com webhooks are firing to n8n"
log "================================================================"
