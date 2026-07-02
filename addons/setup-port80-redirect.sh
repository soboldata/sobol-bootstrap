#!/usr/bin/env bash
# setup-port80-redirect.sh — Make each service CT respond on port 80 in
# addition to its real app port, so http://gitea, http://openwebui, and
# http://homepage work without typing :3000 / :8080.
#
# How it works:
#   - The app itself is untouched — it keeps listening on its high port.
#   - A small iptables NAT rule is added INSIDE each service CT:
#       iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port <port>
#     That tells the kernel to silently rewrite incoming :80 traffic to the
#     real app port BEFORE it reaches the app. The app never knows.
#   - A small systemd oneshot (port80-redirect.service) re-applies the rule
#     on every boot so it survives reboots without iptables-persistent.
#
# What gets redirected (edit REDIRECTS below to extend / change):
#   gitea     :80 → :3000
#   openwebui :80 → :8080
#   homepage  :80 → :3000
#
# Not redirected:
#   sandbox        (no single web service on this CT)
#   ollama-pi-agent (multi-service: filebrowser:8080, pi-web-uis:9090-9092
#                    — each needs its own port; binding 80 to one would
#                    mask the rest)
#
# Usage:
#   ./setup-port80-redirect.sh             # apply / refresh redirects
#   ./setup-port80-redirect.sh --uninstall # remove redirects + unit
#   ./setup-port80-redirect.sh --dry-run

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
DRY_RUN=0
UNINSTALL=0

# hostname:port pairs. Edit to add / remove CTs from the redirect.
REDIRECTS=(
  "gitea:3000"
  "openwebui:8080"
  "homepage:3000"
)

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall)  UNINSTALL=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-port80-redirect]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-port80-redirect]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-port80-redirect]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct >/dev/null || die "pct not found — run this on the PVE host."

find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# ----- install: drop the rule + systemd oneshot in one CT -------------------
apply_redirect() {
  local hostname="$1"
  local port="$2"

  local ctid
  ctid="$(find_ct_by_hostname "$hostname" 2>/dev/null || true)"
  if [[ -z "$ctid" ]]; then
    log "  [$hostname] no such CT — skipping."
    return
  fi
  if ! pct status "$ctid" 2>/dev/null | grep -q "status: running"; then
    log "  [$hostname] CT $ctid not running — skipping."
    return
  fi

  log "  [$hostname] (CT $ctid) installing port 80 -> $port redirect..."

  # Ensure iptables is available. Most community-scripts CTs have it; this is
  # defensive for the ones that don't (e.g., minimal Debian).
  run "pct exec $ctid -- bash -lc 'command -v iptables >/dev/null || (DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables)'"

  # Apply the rule right now (idempotent via -C check).
  run "pct exec $ctid -- bash -lc 'iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port $port 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port $port'"

  # Drop a small re-apply script for the systemd unit to call on every boot.
  # No iptables-persistent dependency this way — one script, one unit, one
  # rule. Re-applies are idempotent (the -C / -A pattern again).
  run "pct exec $ctid -- bash -c 'cat > /usr/local/bin/port80-redirect.sh <<SCRIPT
#!/bin/bash
# Re-applied on every boot by port80-redirect.service.
iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port $port 2>/dev/null \\
  || iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port $port
SCRIPT
chmod 755 /usr/local/bin/port80-redirect.sh'"

  run "pct exec $ctid -- bash -c 'cat > /etc/systemd/system/port80-redirect.service <<UNIT
[Unit]
Description=Redirect port 80 to $port for $hostname
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/port80-redirect.sh

[Install]
WantedBy=multi-user.target
UNIT'"

  run "pct exec $ctid -- systemctl daemon-reload"
  run "pct exec $ctid -- systemctl enable port80-redirect.service"
  # restart re-runs the script (which is idempotent — the -C check skips
  # work if the rule is already there). Safe and quiet.
  run "pct exec $ctid -- systemctl restart port80-redirect.service"

  log "  [$hostname] done. http://$hostname now reaches the app on :$port."
}

# ----- uninstall: remove the rule + systemd oneshot from one CT --------------
remove_redirect() {
  local hostname="$1"
  local port="$2"

  local ctid
  ctid="$(find_ct_by_hostname "$hostname" 2>/dev/null || true)"
  if [[ -z "$ctid" ]]; then
    log "  [$hostname] no such CT — skipping."
    return
  fi

  log "  [$hostname] (CT $ctid) removing port 80 -> $port redirect..."

  # Stop + disable the service first.
  run "pct exec $ctid -- systemctl disable port80-redirect.service 2>/dev/null || true"
  run "pct exec $ctid -- systemctl stop port80-redirect.service 2>/dev/null || true"
  run "pct exec $ctid -- rm -f /etc/systemd/system/port80-redirect.service /usr/local/bin/port80-redirect.sh"
  run "pct exec $ctid -- systemctl daemon-reload"

  # Delete the live iptables rule. Loop in case it was applied multiple times.
  run "pct exec $ctid -- bash -lc 'while iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port $port 2>/dev/null; do iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port $port; done'"

  log "  [$hostname] removed. http://$hostname:$port still works as before."
}

# ----- driver ---------------------------------------------------------------
if (( UNINSTALL )); then
  log "==> Uninstalling port 80 redirects across all configured CTs..."
else
  log "==> Installing port 80 redirects across all configured CTs..."
fi

for entry in "${REDIRECTS[@]}"; do
  hostname="${entry%%:*}"
  port="${entry##*:}"
  if (( UNINSTALL )); then
    remove_redirect "$hostname" "$port"
  else
    apply_redirect "$hostname" "$port"
  fi
done

log "==> Done."
if (( ! UNINSTALL )) && (( ! DRY_RUN )); then
  log " "
  log "Try these from your workstation now (Tailscale MagicDNS):"
  log "  http://gitea"
  log "  http://openwebui"
  log "  http://homepage"
  log " "
  log "The high-port URLs still work too (http://gitea:3000, etc.) — the"
  log "redirect just adds 80 as an additional path in. Apps unchanged."
fi
