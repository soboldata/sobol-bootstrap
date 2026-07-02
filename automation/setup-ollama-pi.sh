#!/usr/bin/env bash
# setup-ollama-pi.sh — Sign Ollama in on every relevant LXC, install pi on
# ollama-pi-agent. Runs on the PVE host.
#
# Default behavior (no flags): walks the built-in target list, currently
#   ollama-pi-agent   → install/verify Ollama, signin, pull model, install pi,
#                       generate /root/.ssh/id_ed25519, push pubkey into
#                       sandbox (or docker)/gitea/openwebui/homepage so pi can ssh into
#                       any of them passwordless
#   openwebui         → install/verify Ollama, signin, pull model (no pi)
# Idempotent at every step — re-runs only do work that isn't already done.
#
# The one place you leave the terminal is the `ollama signin` step. Ollama
# prints a pairing URL to stdout, blocks while you visit it in a browser
# (logged into ollama.com) and click Connect, then exits naturally. We run
# signin once per target CT, so plan to do two browser clicks on a fresh host.
#
# Usage:
#   ./setup-ollama-pi.sh                          # default: walk all targets
#   ./setup-ollama-pi.sh --model gemma3:12b-cloud # different default model
#   ./setup-ollama-pi.sh --ct-id 200              # single CT (still installs pi if hostname matches a "with-pi" target)
#   ./setup-ollama-pi.sh --ct-id 103 --skip-pi    # explicit single-CT, no pi
#   ./setup-ollama-pi.sh --ct-id 103 --with-pi    # force pi install on a non-default hostname
#   ./setup-ollama-pi.sh --skip-signin            # install Ollama, pair manually later
#   ./setup-ollama-pi.sh --skip-pi                # never install pi (Ollama on all targets)
#   ./setup-ollama-pi.sh --dry-run                # preview commands

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
DEFAULT_MODEL="gemma4:31b-cloud"
MODEL=""
PI_CTID=""
SKIP_SIGNIN=0
SKIP_PI=0
WITH_PI=0
DRY_RUN=0

# Built-in targets. Format: "hostname:mode" where mode is with-pi or no-pi.
# To add a new CT for community-extensions, append a row here.
DEFAULT_TARGETS=(
  "ollama-pi-agent:with-pi"
  "openwebui:no-pi"
)

# CTs that pi (running on the with-pi host) should be able to SSH into without
# password. The script generates a keypair on the pi host, drops the pubkey
# into each target's /root/.ssh/authorized_keys, and pre-trusts each target's
# host key so the first connection doesn't prompt.
#
# 'sandbox' and 'docker' are both listed because the Docker host CT was
# renamed from 'docker' to 'sandbox' to avoid the prompt-clash issue ('run
# a docker on docker'). On a freshly bootstrapped homelab only 'sandbox'
# exists; on a transitional homelab where the rename hasn't been done yet,
# only 'docker' exists. Including both means trust gets seeded to whichever
# is actually there — missing CTs are skipped silently below.
SSH_TRUST_TARGETS=(sandbox docker gitea openwebui homepage)

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ct-id)       PI_CTID="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    --skip-signin) SKIP_SIGNIN=1; shift ;;
    --skip-pi)     SKIP_PI=1; shift ;;
    --with-pi)     WITH_PI=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${MODEL:=$DEFAULT_MODEL}"

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-ollama-pi]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-ollama-pi]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-ollama-pi]\033[0m %s\n" "$*" >&2; exit 1; }
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

get_hostname_for_ctid() {
  pct config "$1" 2>/dev/null | awk '/^hostname:/ {print $2}'
}

# ----- per-CT operations -----------------------------------------------------

install_ollama_in_ct() {
  local ctid="$1"
  if pct exec "$ctid" -- bash -lc 'command -v ollama' >/dev/null 2>&1; then
    log "  [$ctid] Ollama already installed."
    return
  fi
  log "  [$ctid] Installing curl + zstd + Ollama..."
  run "pct exec $ctid -- bash -lc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y curl zstd && curl -fsSL https://ollama.com/install.sh | sh'"
}

# Make `ollama` (and anything else under /usr/local/bin) reachable from
# future `pct enter` shells.
#
# Ollama installs to /usr/local/bin/ollama, which is normally on PATH — but
# `pct enter` uses a sanitized PATH that drops /usr/local/bin and
# /usr/local/sbin. Without this fix, future shells say `bash: ollama:
# command not found` even though the binary is right there.
#
# We write to TWO places to cover both shell-startup paths PVE might use:
#   /etc/profile.d/usrlocal-path.sh  →  for login shells (sourced via /etc/profile)
#   /etc/bash.bashrc                  →  for interactive non-login shells
# `pct enter` on modern PVE typically spawns interactive non-login bash, so
# /etc/bash.bashrc is the one that actually fires. The profile.d drop-in is
# kept for forward compatibility (in case pct enter switches to login shells)
# and as a safety net.
#
# Not Ollama-specific — anything installed under /usr/local/bin/* would have
# the same problem (pi, kubectl, etc.), so this fix is worth doing once per
# CT regardless of what's installed.
ensure_usrlocal_path_in_ct() {
  local ctid="$1"

  # 1. /etc/profile.d/ — login shells
  if pct exec "$ctid" -- test -f /etc/profile.d/usrlocal-path.sh 2>/dev/null; then
    log "  [$ctid] /etc/profile.d/usrlocal-path.sh already present."
  else
    log "  [$ctid] Adding /etc/profile.d/usrlocal-path.sh (login shells)..."
    run "echo 'export PATH=\"/usr/local/sbin:/usr/local/bin:\$PATH\"' | pct exec $ctid -- tee /etc/profile.d/usrlocal-path.sh > /dev/null"
    run "pct exec $ctid -- chmod 644 /etc/profile.d/usrlocal-path.sh"
  fi

  # 2. /etc/bash.bashrc — interactive non-login shells (this is what pct enter
  # actually triggers on most PVE versions). Append idempotently via a marker.
  local marker="# TD-Proxmox: /usr/local in PATH for pct enter"
  if pct exec "$ctid" -- grep -qF "$marker" /etc/bash.bashrc 2>/dev/null; then
    log "  [$ctid] /etc/bash.bashrc already has the PATH override."
  else
    log "  [$ctid] Appending PATH override to /etc/bash.bashrc (interactive shells)..."
    run "printf '\\n%s\\n%s\\n' '$marker' 'export PATH=\"/usr/local/sbin:/usr/local/bin:\$PATH\"' | pct exec $ctid -- tee -a /etc/bash.bashrc > /dev/null"
  fi
}

# Drop a systemd override so the Ollama daemon binds 0.0.0.0:11434 instead of
# the default 127.0.0.1:11434. This lets other tailnet devices and other LXCs
# (e.g. OpenWebUI) hit http://<hostname>:11434/ as an API endpoint. The CLI
# inside the same CT still resolves to localhost:11434 (which 0.0.0.0 includes),
# so 'ollama list', 'ollama run', etc. keep working unchanged inside pct enter.
#
# Idempotent — the file content is the same on every run; checking presence
# would race with content drift, so we just overwrite + reload + restart.
configure_ollama_network_in_ct() {
  local ctid="$1"
  log "  [$ctid] Binding Ollama to 0.0.0.0:11434 (systemd override)..."
  run "pct exec $ctid -- bash -lc '
    mkdir -p /etc/systemd/system/ollama.service.d
    cat > /etc/systemd/system/ollama.service.d/network.conf <<DROPIN
[Service]
Environment=\"OLLAMA_HOST=0.0.0.0:11434\"
DROPIN
    systemctl daemon-reload
    systemctl restart ollama
  '"
  # Brief settle so subsequent ollama signin / pull don't race the restart.
  run "sleep 2"
}

ollama_signin_in_ct() {
  local ctid="$1" hostname="$2"
  if (( SKIP_SIGNIN )); then
    log "  [$ctid] Skipping ollama signin (--skip-signin set)."
    return
  fi
  if pct exec "$ctid" -- bash -lc 'ollama list 2>/dev/null | tail -n +2 | grep -q .' 2>/dev/null; then
    log "  [$ctid] Ollama appears already paired (models present). Skipping signin."
    return
  fi

  echo
  log "===================================================="
  log " [$hostname] Starting 'ollama signin'."
  log " Ollama will print a URL like:"
  log "   https://ollama.com/connect?name=$hostname&key=..."
  log " Open it in a browser logged into ollama.com, click"
  log " Connect, and this script will resume automatically."
  log "===================================================="
  echo

  if (( DRY_RUN )); then
    printf "[dry-run] pct exec %s -- bash -lc 'ollama signin'\n" "$ctid"
  else
    pct exec "$ctid" -- bash -lc 'ollama signin' \
      || die "  [$ctid] ollama signin failed or cancelled."
  fi
  log "  [$ctid] Pairing complete."
}

pull_model_in_ct() {
  local ctid="$1"
  if (( SKIP_SIGNIN )); then
    log "  [$ctid] Skipping model pull (Ollama not paired yet)."
    return
  fi
  if pct exec "$ctid" -- bash -lc "ollama list 2>/dev/null | awk '\$1==\"$MODEL\"' | grep -q ." 2>/dev/null; then
    log "  [$ctid] Model $MODEL already pulled."
    return
  fi
  log "  [$ctid] Pulling $MODEL (this can take a while)..."
  run "pct exec $ctid -- bash -lc 'ollama pull \"$MODEL\"'"
}

# Set up SSH trust from the pi host into the other service CTs, so pi can
# `ssh root@sandbox` etc. without password or fingerprint prompts.
#
# Three things happen for each target:
#   1. Generate /root/.ssh/id_ed25519 on the pi host (idempotent — keep
#      existing key if present).
#   2. Append the pi host's pubkey to the target CT's authorized_keys
#      (skip if already there to avoid duplicates).
#   3. Pre-populate the pi host's known_hosts with the target's ssh-keyscan
#      output, dedup, so the first connection doesn't prompt.
#
# Targets come from the SSH_TRUST_TARGETS array at the top of the file.
# Any target that doesn't exist as a CT is skipped silently with a log line.
configure_ssh_trust_from_pi_host() {
  local pi_ctid="$1"

  log "  [$pi_ctid] Ensuring pi-host SSH key (/root/.ssh/id_ed25519)..."
  run "pct exec $pi_ctid -- bash -lc 'mkdir -p /root/.ssh && chmod 700 /root/.ssh; [[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N \"\" -f /root/.ssh/id_ed25519 -C \"root@\$(hostname)\"'"

  # Read the public key. In dry-run we don't need the real value, but the rest
  # of the function still walks targets so the user sees what would happen.
  local pi_pubkey=""
  if (( DRY_RUN )); then
    pi_pubkey="ssh-ed25519 DRYRUN_PLACEHOLDER root@ollama-pi-agent"
  else
    pi_pubkey="$(pct exec "$pi_ctid" -- cat /root/.ssh/id_ed25519.pub 2>/dev/null || true)"
    if [[ -z "$pi_pubkey" ]]; then
      warn "  Could not read pi host's public key — skipping trust setup."
      return
    fi
  fi

  log "  Authorizing pi key on the other service CTs..."
  local target_hostname target_ctid
  for target_hostname in "${SSH_TRUST_TARGETS[@]}"; do
    target_ctid="$(find_ct_by_hostname "$target_hostname" 2>/dev/null || true)"
    if [[ -z "$target_ctid" ]]; then
      log "    [$target_hostname] no such CT — skipping."
      continue
    fi

    # Skip if pi's pubkey is already in the target's authorized_keys.
    if (( ! DRY_RUN )) \
       && pct exec "$target_ctid" -- grep -qF "$pi_pubkey" /root/.ssh/authorized_keys 2>/dev/null; then
      log "    [$target_hostname] pi key already authorized."
    else
      log "    [$target_hostname] adding pi pubkey to /root/.ssh/authorized_keys"
      run "pct exec $target_ctid -- bash -lc 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'"
      run "echo '$pi_pubkey' | pct exec $target_ctid -- tee -a /root/.ssh/authorized_keys > /dev/null"
    fi

    # Pre-trust the target's host key so first ssh from pi doesn't prompt.
    # sort -u dedupes if we've already keyscanned it on a previous run.
    run "pct exec $pi_ctid -- bash -lc 'ssh-keyscan -H $target_hostname 2>/dev/null >> /root/.ssh/known_hosts || true; if [[ -s /root/.ssh/known_hosts ]]; then sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts; chmod 644 /root/.ssh/known_hosts; fi'"
  done
}

install_pi_in_ct() {
  local ctid="$1"
  if pct exec "$ctid" -- bash -lc 'command -v pi >/dev/null 2>&1 || ls /root/.local/share/pi-node/node-v*/bin/pi >/dev/null 2>&1'; then
    log "  [$ctid] pi already installed."
  else
    log "  [$ctid] Installing pi (auto-answering Y to install Node.js + pi prompts)..."
    run "pct exec $ctid -- bash -lc 'yes | bash -c \"\$(curl -fsSL https://pi.dev/install.sh)\" 2>&1 | tail -40'"
  fi

  log "  [$ctid] Ensuring pi PATH in /root/.bashrc..."
  run "pct exec $ctid -- bash -lc '
    PI_BIN=\$(ls -d /root/.local/share/pi-node/node-v*/bin 2>/dev/null | head -1)
    if [[ -n \"\$PI_BIN\" ]]; then
      if ! grep -qF \"\$PI_BIN\" /root/.bashrc 2>/dev/null; then
        echo \"export PATH=\\\"\$PI_BIN:\\\$PATH\\\"\" >> /root/.bashrc
        echo \"    Added \$PI_BIN to /root/.bashrc\"
      else
        echo \"    PATH export already present in /root/.bashrc\"
      fi
    else
      echo \"    Could not find /root/.local/share/pi-node/node-v*/bin — verify pi installed correctly\"
    fi
  '"
}

# ----- choose targets --------------------------------------------------------
# If --ct-id was passed, build a single-element target list from that CT's
# hostname so the "with-pi" / "no-pi" decision still respects the built-in
# defaults (or --skip-pi when set).
declare -a TARGETS
if [[ -n "$PI_CTID" ]]; then
  pct status "$PI_CTID" 2>/dev/null | grep -q "status: running" \
    || die "CT $PI_CTID is not running."
  hn="$(get_hostname_for_ctid "$PI_CTID")"
  mode="no-pi"
  # Decide with-pi vs no-pi in this order:
  #   1. --with-pi flag explicitly forces it (overrides everything below)
  #   2. Hostname matches a built-in "with-pi" target (ollama-pi-agent)
  #   3. Hostname looks like a pi agent (any *pi-agent* — covers pi-agent-2,
  #      pi-agent-3, ... created by setup-new-pi-agent.sh, and any custom
  #      name with 'pi-agent' in it)
  #   4. Otherwise: no-pi (just Ollama, like the openwebui CT)
  if (( WITH_PI )); then
    mode="with-pi"
  else
    for entry in "${DEFAULT_TARGETS[@]}"; do
      IFS=':' read -r dh dmode <<< "$entry"
      if [[ "$dh" == "$hn" ]]; then mode="$dmode"; break; fi
    done
    # Auto-detect pi-style hostnames if not already matched. Pattern is
    # intentionally loose: anything with 'pi-agent' in the name gets pi.
    if [[ "$mode" == "no-pi" && "$hn" == *pi-agent* ]]; then
      mode="with-pi"
    fi
  fi
  TARGETS=("$hn:$mode")
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

# ----- main loop -------------------------------------------------------------
log "==> Targets:"
for entry in "${TARGETS[@]}"; do
  IFS=':' read -r hostname mode <<< "$entry"
  log "     $hostname ($mode)"
done

for entry in "${TARGETS[@]}"; do
  IFS=':' read -r hostname mode <<< "$entry"
  ctid="$(find_ct_by_hostname "$hostname" 2>/dev/null || true)"
  if [[ -z "$ctid" ]]; then
    warn "No CT with hostname '$hostname' — skipping. Run bootstrap-pve.sh first if this is unexpected."
    continue
  fi
  if ! pct status "$ctid" 2>/dev/null | grep -q "status: running"; then
    warn "CT $ctid ($hostname) is not running — skipping."
    continue
  fi

  echo
  log "============================================================"
  log "  Setting up Ollama on $hostname (CT $ctid)"
  log "============================================================"

  install_ollama_in_ct "$ctid"

  # Make /usr/local/bin reachable from future pct enter shells. Applies to
  # every CT (not just with-pi) since both have Ollama installed there.
  ensure_usrlocal_path_in_ct "$ctid"

  # On the "primary" Ollama host (with-pi), expose the daemon on 0.0.0.0:11434
  # so it's reachable from OpenWebUI, pi running on the host, or any other
  # tailnet client. "no-pi" CTs keep Ollama localhost-bound (internal use only).
  if [[ "$mode" == "with-pi" ]]; then
    configure_ollama_network_in_ct "$ctid"
  fi

  ollama_signin_in_ct  "$ctid" "$hostname"
  pull_model_in_ct     "$ctid"

  if [[ "$mode" == "with-pi" ]] && (( ! SKIP_PI )); then
    install_pi_in_ct "$ctid"
    configure_ssh_trust_from_pi_host "$ctid"
  fi
done

# ----- final verification ---------------------------------------------------
if (( ! DRY_RUN )); then
  log "==> Verification:"
  for entry in "${TARGETS[@]}"; do
    IFS=':' read -r hostname _mode <<< "$entry"
    ctid="$(find_ct_by_hostname "$hostname" 2>/dev/null || true)"
    [[ -z "$ctid" ]] && continue
    log "  [$hostname / CT $ctid]"
    pct exec "$ctid" -- bash -lc 'echo "    ollama: $(command -v ollama || echo not-found)"; ollama list 2>/dev/null | tail -n +2 | head -3 | sed "s/^/    /"; command -v pi >/dev/null && echo "    pi: $(command -v pi)" || true' 2>/dev/null
  done
fi

# ----- done ------------------------------------------------------------------
log "==> All done."
log "    ollama-pi-agent — start pi with:  pct enter <ctid>  &&  ollama launch pi"
log "    openwebui — chat dropdown now lists local Ollama models alongside OpenRouter."
