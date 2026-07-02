#!/usr/bin/env bash
# ct-helpers.sh — CT lifecycle helpers, sourced by setup-*.sh addons.
#
# Central place for "how do you know a CT is actually usable" — which
# turns out to be more subtle than `pct status ... running`. Especially
# on Ubuntu 24 CTs after LXC config edits + reboot, where systemd-resolved
# races with the addon's next `pct exec` call.
#
# Usage in an addon:
#
#   # Source this from wherever the addon lives. addons/setup-<name>.sh
#   # is one level up from addons/lib/, so `${BASH_SOURCE[0]%/*}/lib/…`
#   # works. Setup-stack.sh dispatch uses the same paths.
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/ct-helpers.sh"
#
#   # After a reboot or CT creation:
#   ct_wait_ready "$CTID" || die "CT $CTID never came fully up"
#
# ---------------------------------------------------------------------
# Assumes the sourcing script defines log() and warn(). Falls back to
# printf if not (so this file is testable standalone).
# ---------------------------------------------------------------------

# Fallback logging helpers if the sourcing script didn't define them.
if ! declare -F log >/dev/null 2>&1; then
  log()  { printf "\n\033[1;36m[ct-helper]\033[0m %s\n" "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf "\n\033[1;33m[ct-helper]\033[0m %s\n" "$*" >&2; }
fi

# ct_status <CTID>
# Prints the raw `pct status` output — one of 'running', 'stopped', or
# an error message. Empty if pct fails.
ct_status() {
  local ctid="$1"
  pct status "$ctid" 2>/dev/null | awk '{print $2}'
}

# ct_running <CTID>
# Returns 0 if the CT exists AND is in 'running' state, 1 otherwise.
ct_running() {
  [[ "$(ct_status "$1")" == "running" ]]
}

# ct_wait_running <CTID> [timeout_seconds=60]
# Wait for the CT to be in 'running' state after a pct create / reboot.
# Returns 0 on success, non-zero on timeout.
ct_wait_running() {
  local ctid="$1" timeout="${2:-60}" i=0
  while (( i < timeout )); do
    ct_running "$ctid" && return 0
    sleep 1
    ((i++))
  done
  return 1
}

# ct_wait_ip_ready <CTID> [timeout=60]
# Wait for IP-level connectivity from inside the CT. Uses ping to 1.1.1.1
# which is the standard test — bypasses DNS entirely.
ct_wait_ip_ready() {
  local ctid="$1" timeout="${2:-60}" i=0
  while (( i < timeout )); do
    pct exec "$ctid" -- ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
    sleep 2
    ((i+=2))
  done
  return 1
}

# ct_wait_dns_ready <CTID> [host=github.com] [timeout=60]
# Wait for DNS resolution to actually work from inside the CT. This is
# what fails after a reboot on Ubuntu 24 CTs — systemd-resolved takes
# a moment to come back up, and if we run apt-get/curl before it does,
# every hostname fails to resolve.
#
# We test against github.com by default because:
#   - it's what our addons actually need to reach (Tailscale install,
#     apt package repos, etc.)
#   - it's a public host that MUST resolve for a normal internet-connected
#     CT to function
#
# Callers can override the target for offline / restricted environments.
ct_wait_dns_ready() {
  local ctid="$1" host="${2:-github.com}" timeout="${3:-60}" i=0
  while (( i < timeout )); do
    pct exec "$ctid" -- getent hosts "$host" >/dev/null 2>&1 && return 0
    sleep 2
    ((i+=2))
  done
  return 1
}

# ct_stage_public_dns <CTID>
# Force /etc/resolv.conf inside the CT to use public DNS (1.1.1.1 +
# 8.8.8.8) so pre-Tailscale bootstrap work (apt-get update, curl) can
# resolve hostnames. Idempotent.
#
# Once Tailscale is installed and `tailscale up --accept-dns` runs
# inside the CT, Tailscale takes over /etc/resolv.conf and this staged
# config is replaced with Tailscale MagicDNS. So this is a scaffold,
# not the final state.
ct_stage_public_dns() {
  local ctid="$1"
  log "  Staging public DNS (1.1.1.1) in CT $ctid for pre-Tailscale bootstrap..."
  pct exec "$ctid" -- bash -c "cat > /etc/resolv.conf <<'RESOLV_EOF'
# Temporary — staged by ct-helpers.sh (ct_stage_public_dns).
# Tailscale will overwrite this after 'tailscale up --accept-dns' runs
# and the CT joins the tailnet.
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLV_EOF"
}

# ct_fix_dns <CTID>
# Recovery: try to bring DNS back up. Two known failure modes:
#
#   A. CT's resolv.conf points at Tailscale MagicDNS (100.100.100.100)
#      but CT isn't on the tailnet yet. Happens when the PVE host was
#      joined to the tailnet BEFORE the CT was created — pct create
#      copies the host's resolv.conf, which now points at MagicDNS.
#      The CT can't reach 100.100.100.100 until it's on tailnet too.
#      → Fix: stage public DNS. Tailscale will reclaim resolv.conf
#              once 'tailscale up --accept-dns' runs inside the CT.
#
#   B. systemd-resolved is racing at boot (common on Ubuntu 24 CTs
#      after config edits + reboot). resolv.conf is a stub that will
#      populate once resolved is fully up.
#      → Fix: restart systemd-resolved.
#
# Idempotent — safe to call even if DNS is already fine.
ct_fix_dns() {
  local ctid="$1"
  local resolv
  resolv="$(pct exec "$ctid" -- cat /etc/resolv.conf 2>/dev/null || true)"

  # Case A: pointing at Tailscale MagicDNS from an unjoined CT
  if echo "$resolv" | grep -q '100\.100\.100\.100'; then
    warn "  CT $ctid resolv.conf points at Tailscale MagicDNS (100.100.100.100),"
    warn "  but the CT hasn't joined the tailnet yet. Staging public DNS so"
    warn "  bootstrap can proceed; Tailscale will take resolv.conf back after"
    warn "  'tailscale up --accept-dns' runs."
    ct_stage_public_dns "$ctid"
    return 0
  fi

  # Case B: systemd-resolved race
  if pct exec "$ctid" -- systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    warn "  DNS not resolving inside CT $ctid — restarting systemd-resolved as recovery..."
    pct exec "$ctid" -- systemctl restart systemd-resolved 2>&1 | sed 's/^/    /' || true
    sleep 5
  else
    warn "  DNS not resolving inside CT $ctid — no systemd-resolved to restart, ensure /etc/resolv.conf is set"
  fi
}

# ct_wait_ready <CTID> [dns_target=github.com]
# THE MAIN ENTRY POINT — call this after any pct create / pct reboot
# to make sure the CT is actually usable for downstream commands.
#
# Sequence:
#   1. Wait for CT to be in 'running' state (up to 60s)
#   2. Wait for IP-level connectivity (up to 60s)
#   3. Wait for DNS to resolve (up to 60s)
#   4. If DNS times out, try ct_fix_dns and re-test (up to 30s more)
#   5. If still broken, die with a clear diagnostic
#
# Returns 0 on success; die's on failure (calling script exits).
ct_wait_ready() {
  local ctid="$1" dns_target="${2:-github.com}"

  log "  Waiting for CT $ctid to be running..."
  ct_wait_running "$ctid" 60 || {
    warn "  CT $ctid didn't reach 'running' after 60s. Status: $(ct_status "$ctid")"
    return 1
  }

  # Small grace period for systemd inside the CT to start core services
  sleep 3

  log "  Waiting for IP-level connectivity (ping 1.1.1.1)..."
  ct_wait_ip_ready "$ctid" 60 || {
    warn "  CT $ctid has no IP connectivity after 60s. Check: pct exec $ctid -- ip a; pct exec $ctid -- ip route"
    return 1
  }

  log "  Waiting for DNS to resolve '$dns_target'..."
  if ct_wait_dns_ready "$ctid" "$dns_target" 60; then
    log "  ✓ CT $ctid fully ready (IP + DNS)"
    return 0
  fi

  # DNS didn't come up in the normal window — try to unblock it
  ct_fix_dns "$ctid"

  if ct_wait_dns_ready "$ctid" "$dns_target" 30; then
    log "  ✓ CT $ctid fully ready after systemd-resolved restart"
    return 0
  fi

  # Still broken — give the operator a specific next step
  warn "  DNS still broken in CT $ctid after recovery attempt. Diagnostics:"
  warn "    pct exec $ctid -- cat /etc/resolv.conf"
  warn "    pct exec $ctid -- ls -la /etc/resolv.conf"
  warn "    pct exec $ctid -- systemctl status systemd-resolved --no-pager"
  return 1
}

# ct_find_by_hostname <hostname>
# Return CTID for a CT with the given hostname, or empty string.
# Community-scripts helpers auto-assign CTIDs and ignore env vars, so
# static CTID maps drift. Hostname is the reliable lookup key.
ct_find_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# ct_ip <CTID>
# Return the CT's primary LAN IPv4 (from hostname -I). Empty if the CT
# isn't running or has no IP yet.
ct_ip() {
  pct exec "$1" -- hostname -I 2>/dev/null | awk '{print $1}'
}

# ct_tailnet_ip <CTID>
# Return the CT's Tailscale IPv4, or empty if Tailscale isn't up.
ct_tailnet_ip() {
  pct exec "$1" -- tailscale ip -4 2>/dev/null | head -1
}

# ts_ensure_joined <ctid|"host"> <ts_authkey> [ts_hostname] [ts_extra_flags]
# Idempotently ensure the target (a CT by ID, or the string "host" for the
# PVE host itself) is currently on the tailnet AND has a working identity.
#
# Handles four states:
#   1. Working: tailscale up, has an IP → no-op, returns 0
#   2. Never joined: no IP, no session → runs `tailscale up --authkey`
#   3. Stale nodekey (device deleted admin-side): `tailscale up` alone can
#      succeed but no IP appears because the nodekey is dead → retries with
#      --force-reauth
#   4. Fully broken: even --force-reauth fails → returns 1 with diagnostics
#
# Why this exists: after an operator deletes a Tailscale device admin-side
# (accidentally or intentionally), re-running the installer sees "tailscale
# is installed" and doesn't force reauth. The local tailscaled still has
# the cached (now-dead) nodekey. Standard `tailscale up --authkey` is often
# ignored in that state — the control server has no record of this node.
# Only `--force-reauth` reliably recovers.
#
# Called from: bootstrap-pve.sh (per CT after preflight), boot.sh (for the
# PVE host itself — inlined there since it runs before this file is
# clone-able), setup-tailnet-refresh.sh (force-reauth every node in the
# stack), individual addons after they detect EXISTING_CT=1.
#
# Returns 0 on success (target is on tailnet with a valid IP).
# Returns 1 if authkey isn't provided or all recovery attempts fail.
ts_ensure_joined() {
  local target="$1" authkey="${2:-}" hostname="${3:-}" extra_flags="${4:-}"
  local exec_prefix label

  if [[ "$target" == "host" ]]; then
    exec_prefix=""
    label="PVE host"
  else
    exec_prefix="pct exec $target --"
    label="CT $target"
  fi

  # Step 1: is tailscale even installed on the target?
  # (For CTs: bootstrap-pve.sh installs it via the tailscale add-on. For
  # the host: boot.sh installs it via https://tailscale.com/install.sh.
  # This helper only VERIFIES; it doesn't install.)
  if ! $exec_prefix command -v tailscale >/dev/null 2>&1; then
    warn "  $label: tailscale binary not installed — helper won't install, that's the caller's job"
    return 1
  fi

  # Step 2: happy path — already on tailnet with a working IP
  local ip
  ip="$($exec_prefix tailscale ip -4 2>/dev/null | head -1 || true)"
  if [[ -n "$ip" && "$ip" =~ ^100\. ]]; then
    log "  $label already on tailnet as $ip — no rejoin needed"
    return 0
  fi

  # Step 3: not on tailnet. Need an authkey to fix that.
  if [[ -z "$authkey" ]]; then
    warn "  $label not on tailnet, but no TS_AUTHKEY provided — can't rejoin"
    return 1
  fi

  # Assemble the up command. --reset drops any old prefs (advertised routes,
  # exit-node settings, etc.) so a re-join is clean. --accept-routes lets
  # the node reach subnet-router-advertised destinations.
  local up_cmd="tailscale up --authkey=$authkey --accept-routes --reset"
  [[ -n "$hostname" ]] && up_cmd="$up_cmd --hostname=$hostname"
  [[ -n "$extra_flags" ]] && up_cmd="$up_cmd $extra_flags"

  log "  $label not on tailnet — attempting standard tailscale up..."
  if $exec_prefix $up_cmd 2>&1 | sed 's/^/    /'; then
    sleep 2
    ip="$($exec_prefix tailscale ip -4 2>/dev/null | head -1 || true)"
    if [[ -n "$ip" && "$ip" =~ ^100\. ]]; then
      log "  ✓ $label joined tailnet as $ip"
      return 0
    fi
  fi

  # Step 4: standard up didn't yield an IP. Almost always means the local
  # nodekey is stale (device was deleted admin-side, or authkey rotated).
  # --force-reauth generates a fresh nodekey and re-registers with the
  # control server.
  warn "  $label: tailscale up didn't produce a tailnet IP."
  warn "    Most common cause: this device was deleted from the tailnet admin"
  warn "    panel, leaving a stale nodekey cached locally. Retrying with"
  warn "    --force-reauth to generate a fresh identity..."

  if $exec_prefix $up_cmd --force-reauth 2>&1 | sed 's/^/    /'; then
    sleep 3
    ip="$($exec_prefix tailscale ip -4 2>/dev/null | head -1 || true)"
    if [[ -n "$ip" && "$ip" =~ ^100\. ]]; then
      log "  ✓ $label force-rejoined tailnet as $ip"
      return 0
    fi
  fi

  # Truly broken. Give the operator specific commands to debug manually.
  warn "  $label: --force-reauth also failed to yield a tailnet IP. Diagnose with:"
  warn "    $exec_prefix tailscale status"
  warn "    $exec_prefix tailscale netcheck"
  warn "    $exec_prefix journalctl -u tailscaled --no-pager -n 50"
  warn "  Manual recovery:"
  warn "    $exec_prefix tailscale logout"
  warn "    $exec_prefix tailscale up --authkey=<KEY> --hostname=$hostname --force-reauth"
  return 1
}
