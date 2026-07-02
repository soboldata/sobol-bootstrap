#!/usr/bin/env bash
# setup-filebrowser.sh — Install filebrowser on one or more CTs so you can
# drag-and-drop files into a folder from a browser tab. By default we install
# on ollama-pi-agent (so pi can pick files up immediately without scp / rsync)
# AND on sandbox (so you can drop Dockerfiles / compose files / project source
# into the Docker host the same way).
#
# Runs on the PVE host. filebrowser is a single 20 MB Go binary with a built-in
# web UI (drag-drop upload, folder navigation, preview, edit text, auth).
# Project: https://github.com/filebrowser/filebrowser
#
# Usage (zero flags — script prompts for everything it needs):
#   ./setup-filebrowser.sh                          # both ollama-pi-agent + sandbox
#
# Restrict to a single CT:
#   ./setup-filebrowser.sh --target ollama-pi-agent
#   ./setup-filebrowser.sh --target sandbox
#
# Or pass any subset of options:
#   ./setup-filebrowser.sh \
#       --target ollama-pi-agent --target sandbox \
#       --admin-user td \
#       --admin-password 'strong-pw' \
#       --root /root/uploads \
#       --port 8080
#
# Optional flags:
#   --target NAME      Hostname of a CT to install on. Repeatable. Default if
#                      no --target given: ollama-pi-agent + sandbox.
#   --hostname NAME    Back-compat alias for --target.
#   --ct-id N          Target a specific CTID (only valid with one --target).
#   --root <path>      Filesystem root the UI exposes (default: /root/uploads)
#   --port <n>         Listen port inside each CT (default: 8080)
#   --admin-user NAME  Filebrowser admin username (shared across all targets)
#   --admin-password P Filebrowser admin password (shared across all targets)
#   --skip-homepage-tile  Don't register a Homepage tile (used by configure-apps.sh
#                         which manages services.yaml authoritatively)
#   --dry-run          Preview commands

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
declare -a TARGETS=()
TARGET_CTID=""
FB_ROOT="/root/uploads"
FB_PORT=8080
ADMIN_USER=""
ADMIN_PASSWORD=""
SKIP_HOMEPAGE_TILE=0
DRY_RUN=0

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target|--hostname) TARGETS+=("$2"); shift 2 ;;
    --ct-id)             TARGET_CTID="$2"; shift 2 ;;
    --root)              FB_ROOT="$2"; shift 2 ;;
    --port)              FB_PORT="$2"; shift 2 ;;
    --admin-user)        ADMIN_USER="$2"; shift 2 ;;
    --admin-password)    ADMIN_PASSWORD="$2"; shift 2 ;;
    --skip-homepage-tile) SKIP_HOMEPAGE_TILE=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Default target list = both pi host and sandbox.
# Why both? ollama-pi-agent is where pi reads files from; sandbox is the Docker
# host, where you'll often want to drop a Dockerfile, compose file, or project
# tarball and immediately reference it from `ssh root@sandbox`.
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=("ollama-pi-agent" "sandbox")
fi

# --ct-id only makes sense with one target — explicit CTID would otherwise
# be ambiguous about which target it overrides.
if [[ -n "$TARGET_CTID" && ${#TARGETS[@]} -gt 1 ]]; then
  echo "--ct-id can only be used with a single --target." >&2
  exit 2
fi

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-filebrowser]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-filebrowser]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-filebrowser]\033[0m %s\n" "$*" >&2; exit 1; }
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

# ----- resolve admin credentials (once, shared across all targets) ----------
resolve_admin_user() {
  if [[ -n "$ADMIN_USER" ]]; then return; fi
  if (( DRY_RUN )); then ADMIN_USER="dryrun"; log "Dry-run: using placeholder admin user."; return; fi
  printf "\n\033[1;36m[setup-filebrowser]\033[0m Admin username for filebrowser (e.g. td): " >&2
  IFS= read -r ADMIN_USER
  [[ -n "$ADMIN_USER" ]] || die "Admin user can't be empty."
}

resolve_admin_password() {
  # 12-char minimum matches filebrowser's hardcoded check (recent versions
  # bumped this from 8; the check is in the filebrowser binary and not
  # overridable via flag). Validate upfront whether the password came from
  # --admin-password or from the prompt so the failure mode is clear text
  # rather than the cryptic 'Error: password is too short, minimum length
  # is 12' from filebrowser deep inside the install.
  if [[ -n "$ADMIN_PASSWORD" ]]; then
    [[ ${#ADMIN_PASSWORD} -ge 12 ]] \
      || die "Admin password from --admin-password is too short (need >= 12 chars).
  Filebrowser recent versions hardcode a 12-char minimum. Either pass a
  longer --admin-password or omit the flag and the script will prompt."
    return
  fi
  if (( DRY_RUN )); then ADMIN_PASSWORD="dryrun-placeholder-pw-12"; log "Dry-run: using placeholder admin password."; return; fi
  local pw1 pw2
  printf "\n\033[1;36m[setup-filebrowser]\033[0m Admin password (hidden; min 12 chars — filebrowser's requirement): " >&2
  IFS= read -rs pw1; echo >&2
  printf "Confirm: " >&2
  IFS= read -rs pw2; echo >&2
  [[ "$pw1" == "$pw2"  ]] || die "Passwords didn't match."
  [[ ${#pw1} -ge 12    ]] || die "Password too short (need >= 12 chars to satisfy filebrowser)."
  ADMIN_PASSWORD="$pw1"
}

# ----- Homepage tile registration (used once per target) -------------------
# Auto-append a tile to the homepage CT's services.yaml. Idempotent via a
# TD-Addon marker comment unique to each target — re-runs detect the existing
# block, remove it, and re-append the fresh version.
add_homepage_tile() {
  local addon_name="$1"
  local tile_block="$2"
  local marker="# TD-Addon: $addon_name"

  local homepage_ctid
  homepage_ctid="$(find_ct_by_hostname homepage 2>/dev/null || true)"
  if [[ -z "$homepage_ctid" ]]; then
    log "  Homepage CT not found — paste the YAML manually if you want the tile."
    return
  fi

  local services_file
  services_file="$(pct exec "$homepage_ctid" -- bash -lc '
    for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage /var/lib/homepage/config; do
      if [[ -f "$d/services.yaml" ]]; then echo "$d/services.yaml"; exit 0; fi
    done
  ' 2>/dev/null | tail -n1)"

  if [[ -z "$services_file" ]]; then
    log "  Could not find services.yaml on the homepage CT — paste manually."
    return
  fi

  # If the marker exists, surgically remove the existing block first so
  # re-runs update content rather than no-op'ing. awk: skip from our marker
  # to next '# TD-Addon:' line (or EOF). Other addons' blocks untouched.
  if pct exec "$homepage_ctid" -- grep -qF "$marker" "$services_file" 2>/dev/null; then
    log "  Updating existing Homepage tile for $addon_name in $services_file..."
    run "pct exec $homepage_ctid -- bash -lc \"awk -v m='$marker' '
      \\\$0 ~ m { in_block=1; next }
      in_block && \\\$0 ~ /^# TD-Addon:/ { in_block=0 }
      !in_block { print }
    ' '$services_file' > /tmp/services.yaml.new && mv /tmp/services.yaml.new '$services_file'\""
  else
    log "  Appending Homepage tile for $addon_name to $services_file..."
  fi

  printf '\n%s\n%s\n' "$marker" "$tile_block" | pct exec "$homepage_ctid" -- tee -a "$services_file" > /dev/null

  pct exec "$homepage_ctid" -- bash -lc '
    systemctl restart homepage 2>/dev/null \
      || systemctl restart gethomepage 2>/dev/null \
      || true
  ' >/dev/null 2>&1 || true
}

# ----- per-target install logic --------------------------------------------
install_on_target() {
  local target_hostname="$1"
  local target_ctid="$2"

  log "================================================================"
  log "Target: $target_hostname (CT $target_ctid)"
  log "================================================================"

  # 1. install filebrowser inside the CT
  if pct exec "$target_ctid" -- bash -lc 'command -v filebrowser' >/dev/null 2>&1; then
    log "filebrowser already installed on $target_hostname."
  else
    log "Installing filebrowser via the official one-liner on $target_hostname..."
    # The official installer drops the binary at /usr/local/bin/filebrowser.
    run "pct exec $target_ctid -- bash -lc 'apt-get update -qq && apt-get install -y -qq curl && curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash'"
  fi

  # 2. ensure the file root exists
  log "Ensuring file root exists on $target_hostname: $FB_ROOT"
  run "pct exec $target_ctid -- mkdir -p '$FB_ROOT'"
  run "pct exec $target_ctid -- chmod 750 '$FB_ROOT'"

  # 3. initialize the filebrowser DB
  # Stop the service first so `filebrowser config set` can get a lock on
  # filebrowser.db. Without this, re-runs against an already-running filebrowser
  # time out: 'Error: timeout' (the bolt DB file is held by the live process).
  log "Stopping filebrowser on $target_hostname (if running) to update config..."
  run "pct exec $target_ctid -- systemctl stop filebrowser 2>/dev/null || true"

  log "Initializing filebrowser database on $target_hostname..."
  run "pct exec $target_ctid -- bash -lc '
    mkdir -p /etc/filebrowser
    cd /etc/filebrowser
    if [[ ! -f filebrowser.db ]]; then
      filebrowser config init -d /etc/filebrowser/filebrowser.db
    fi
    filebrowser config set \
      -a 0.0.0.0 \
      -p $FB_PORT \
      -r $FB_ROOT \
      --auth.method=json \
      --branding.name=\"TD Homelab Files — $target_hostname\" \
      --branding.disableExternal \
      -d /etc/filebrowser/filebrowser.db >/dev/null
  '"

  # 4. create or update admin user
  log "Creating/updating admin user '$ADMIN_USER' on $target_hostname..."
  run "pct exec $target_ctid -- bash -lc '
    if filebrowser users find $ADMIN_USER -d /etc/filebrowser/filebrowser.db >/dev/null 2>&1; then
      filebrowser users update $ADMIN_USER --password \"$ADMIN_PASSWORD\" -d /etc/filebrowser/filebrowser.db >/dev/null
    else
      filebrowser users add $ADMIN_USER \"$ADMIN_PASSWORD\" --perm.admin -d /etc/filebrowser/filebrowser.db >/dev/null
    fi
  '"

  # 5. systemd service so filebrowser auto-starts
  log "Installing systemd unit on $target_hostname..."
  run "pct exec $target_ctid -- bash -c 'cat > /etc/systemd/system/filebrowser.service <<UNIT
[Unit]
Description=filebrowser
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/filebrowser -d /etc/filebrowser/filebrowser.db
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT'"

  run "pct exec $target_ctid -- systemctl daemon-reload"
  run "pct exec $target_ctid -- systemctl enable filebrowser"
  # restart (not start) so re-runs pick up unit-file or config changes.
  # We stopped the service earlier to release the DB lock; this brings it back.
  run "pct exec $target_ctid -- systemctl restart filebrowser"

  # 6. verify
  local ct_ip=""
  if (( ! DRY_RUN )); then
    log "Verifying service is up on $target_hostname..."
    ct_ip="$(pct exec "$target_ctid" -- hostname -I 2>/dev/null | awk '{print $1}' || echo '?')"
    if pct exec "$target_ctid" -- bash -lc "exec 3<>/dev/tcp/127.0.0.1/$FB_PORT" 2>/dev/null; then
      log "filebrowser is listening on $target_hostname ($ct_ip):$FB_PORT"
    else
      warn "filebrowser isn't responding on $target_hostname:$FB_PORT — check 'pct exec $target_ctid -- journalctl -u filebrowser --no-pager | tail -20'"
    fi
  fi

  # 7. Homepage tile (per-target marker, per-target service name so they don't
  #    collide when more than one filebrowser is registered).
  local tile_description
  case "$target_hostname" in
    ollama-pi-agent) tile_description="Drop files for pi to use" ;;
    sandbox)         tile_description="Drop files for Docker workloads" ;;
    *)               tile_description="Drop files into $target_hostname" ;;
  esac

  local fb_tile="- Tools:
    - Files on $target_hostname:
        href: http://$target_hostname:$FB_PORT
        description: $tile_description
        icon: filebrowser.png"
  # configure-apps.sh's configure_filebrowser embeds the tile inline in
  # services.yaml authoritatively and passes --skip-homepage-tile so this
  # marker-based registration doesn't duplicate it. Standalone runs (no
  # flag) still register normally.
  if (( ! SKIP_HOMEPAGE_TILE )); then
    add_homepage_tile "filebrowser-$target_hostname" "$fb_tile"
  fi
}

# ----- resolve every target's CTID before doing any installs ----------------
# Fail fast if any target doesn't exist or isn't running.
declare -a RESOLVED_HOSTNAMES=() RESOLVED_CTIDS=()
for hn in "${TARGETS[@]}"; do
  ctid="$TARGET_CTID"
  if [[ -z "$ctid" ]]; then
    ctid="$(find_ct_by_hostname "$hn" 2>/dev/null || true)"
  fi
  [[ -n "$ctid" ]] || die "Couldn't find a CT with hostname '$hn'. Pass --ct-id <n> if it's named differently, or skip with --target <other>."
  pct status "$ctid" 2>/dev/null | grep -q "status: running" \
    || die "CT $ctid ($hn) is not running."
  RESOLVED_HOSTNAMES+=("$hn")
  RESOLVED_CTIDS+=("$ctid")
done

log "Planned install on: ${RESOLVED_HOSTNAMES[*]}"

# Collect credentials once (shared across all targets — same admin user/pw on
# each filebrowser instance).
resolve_admin_user
resolve_admin_password

# ----- install on each target ----------------------------------------------
for i in "${!RESOLVED_HOSTNAMES[@]}"; do
  install_on_target "${RESOLVED_HOSTNAMES[$i]}" "${RESOLVED_CTIDS[$i]}"
done

# ----- done ---------------------------------------------------------------
log "================================================================"
log "==> Done."
for i in "${!RESOLVED_HOSTNAMES[@]}"; do
  hn="${RESOLVED_HOSTNAMES[$i]}"
  ctid="${RESOLVED_CTIDS[$i]}"
  ct_ip="$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}' || echo '?')"
  log "  $hn:"
  log "    Open:   http://$hn:$FB_PORT  (over Tailscale MagicDNS)"
  log "    Or:     http://$ct_ip:$FB_PORT  (LAN)"
  log "    Files land at: $FB_ROOT/  (inside CT $ctid)"
done
log "  Login:  $ADMIN_USER / (your password)"
