#!/usr/bin/env bash
# setup-new-pi-agent.sh — Spin up an additional ollama-pi-agent-style CT.
#
# The original ollama-pi-agent CT is created by bootstrap-pve.sh as part of
# the first-time homelab build. This addon stands up MORE of them later —
# same shape, same capabilities, joined to the same tailnet, meshed into the
# same SSH trust graph.
#
# What gets created (default — flags can turn most of this off):
#
#   1. A new Debian 12 LXC (unprivileged, nesting=1) — same shape as the
#      original ollama-pi-agent (4 CPU / 4 GB RAM / 20 GB disk).
#   2. Tailscale, joined under the new hostname so it's reachable at
#      http://<hostname> from anywhere on your tailnet.
#   3. Ollama installed and signed in to ollama.com (one browser click — same
#      flow setup-ollama-pi.sh uses).
#   4. The default Ollama model pulled (gemma4:31b-cloud unless --model given).
#   5. pi installed from pi.dev/install.sh.
#   6. Bidirectional SSH trust mesh: this agent gets passwordless ssh into
#      every other existing CT (and into other pi agents); other pi agents
#      get passwordless ssh into this one.
#   7. Three browser UIs (cards 9090, pi terminal 9091, plain shell 9092)
#      via setup-pi-web-uis.sh.
#   8. Homepage tiles for the three UIs (per-target marker so multiple agents
#      coexist on the dashboard).
#   9. SMB share of /root (port 445) so you can mount the agent's home
#      directory from macOS Finder / Windows Explorer / Linux. SMB auth uses
#      the CT root password ('root' SMB user maps to root on disk).
#
# Usage:
#   ./setup-new-pi-agent.sh                                  # auto-hostname (pi-agent-N), all defaults
#   ./setup-new-pi-agent.sh --hostname pi-agent-research     # explicit name
#   ./setup-new-pi-agent.sh --hostname pi-agent-fast --cpu 8 --ram 8192 --model gemma3:12b-cloud
#   ./setup-new-pi-agent.sh --skip-filebrowser               # install everything EXCEPT filebrowser
#   ./setup-new-pi-agent.sh --skip-web-uis --skip-homepage-tile  # bare Ollama+pi only
#
# Optional flags:
#   --hostname NAME       Explicit hostname (default: auto — next pi-agent-N)
#   --ctid N              Explicit CTID (default: auto-allocate via pvesh)
#   --cpu N               CPU cores (default: 4)
#   --ram MB              Memory in MB (default: 4096)
#   --disk GB             Root disk size in GB (default: 20)
#   --model NAME          Ollama model to pull (passed to setup-ollama-pi.sh)
#   --ts-authkey KEY      Tailscale auth key (else prompted)
#   --ct-password PW      CT root password (else prompted)
#   --skip-web-uis        Skip the cards/term/shell install + their Homepage tiles
#   --skip-filebrowser    Don't install filebrowser on the new agent
#                         (filebrowser is now default-on; --with-filebrowser
#                         is accepted as a no-op for back-compat)
#   --skip-trust-mesh     Don't wire SSH trust to/from existing CTs (manual setup later)
#   --skip-homepage-tile  Don't register the agent's "machine" tile on Homepage
#                         (the web-UIs tile is still registered if --skip-web-uis isn't set)
#   --skip-smb-share      Don't install Samba / expose /root via SMB
#   --dry-run             Preview every command without executing
#
# Prereqs: a TD-Proxmox homelab built by bootstrap-pve.sh — at minimum, the
# original ollama-pi-agent CT must exist (or you wouldn't be running this
# addon). pct/pveam/pvesh available (you're on the PVE host).

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
HOSTNAME=""
CTID=""
CPU=4
RAM=4096
DISK=20
MODEL=""
TS_AUTHKEY=""
CT_PASSWORD=""
SKIP_WEB_UIS=0
SKIP_FILEBROWSER=0
SKIP_TRUST_MESH=0
SKIP_HOMEPAGE_TILE=0
SKIP_SMB_SHARE=0
DRY_RUN=0

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)           HOSTNAME="$2"; shift 2 ;;
    --ctid)               CTID="$2"; shift 2 ;;
    --cpu)                CPU="$2"; shift 2 ;;
    --ram)                RAM="$2"; shift 2 ;;
    --disk)               DISK="$2"; shift 2 ;;
    --model)              MODEL="$2"; shift 2 ;;
    --ts-authkey)         TS_AUTHKEY="$2"; shift 2 ;;
    --ct-password)        CT_PASSWORD="$2"; shift 2 ;;
    --skip-web-uis)       SKIP_WEB_UIS=1; shift ;;
    --skip-filebrowser)   SKIP_FILEBROWSER=1; shift ;;
    --with-filebrowser)   shift ;;  # back-compat no-op: filebrowser is now default-on
    --skip-trust-mesh)    SKIP_TRUST_MESH=1; shift ;;
    --skip-smb-share)     SKIP_SMB_SHARE=1; shift ;;
    --skip-homepage-tile) SKIP_HOMEPAGE_TILE=1; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    -h|--help)            sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-new-pi-agent]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-new-pi-agent]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-new-pi-agent]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct  >/dev/null || die "pct not found — PVE host required."
command -v pveam >/dev/null || die "pveam not found — PVE host required."

find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# ----- find sibling addon + automation scripts -----------------------------
# We delegate to setup-ollama-pi.sh and setup-pi-web-uis.sh for everything
# they already do well — this script's unique work is CT creation, Tailscale
# init, and the trust-mesh wiring around the delegated pieces.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_OLLAMA="$SCRIPT_DIR/../automation/setup-ollama-pi.sh"
SETUP_WEB_UIS="$SCRIPT_DIR/setup-pi-web-uis.sh"
SETUP_FB="$SCRIPT_DIR/setup-filebrowser.sh"
SETUP_SMB="$SCRIPT_DIR/setup-smb-share.sh"

[[ -x "$SETUP_OLLAMA" ]] || die "setup-ollama-pi.sh not found at $SETUP_OLLAMA. Run this from a clone of the td-proxmox repo."
[[ -x "$SETUP_WEB_UIS" ]] || warn "setup-pi-web-uis.sh not found — --skip-web-uis will be forced."
(( ! SKIP_WEB_UIS )) && [[ ! -x "$SETUP_WEB_UIS" ]] && SKIP_WEB_UIS=1
[[ -x "$SETUP_SMB" ]] || warn "setup-smb-share.sh not found — --skip-smb-share will be forced."
(( ! SKIP_SMB_SHARE )) && [[ ! -x "$SETUP_SMB" ]] && SKIP_SMB_SHARE=1

# ----- determine hostname (auto-number if not given) ------------------------
if [[ -z "$HOSTNAME" ]]; then
  # Scan for existing pi-agent-N and pick next N. Treat the original
  # ollama-pi-agent as N=1, so the first new one is pi-agent-2.
  n=2
  while find_ct_by_hostname "pi-agent-$n" >/dev/null 2>&1; do
    n=$((n + 1))
  done
  HOSTNAME="pi-agent-$n"
  log "Auto-picked hostname: $HOSTNAME"
fi

# Validate: DNS-safe, doesn't already exist
if ! [[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
  die "Hostname '$HOSTNAME' has invalid characters (DNS-safe only: alphanumeric + hyphens)."
fi
if find_ct_by_hostname "$HOSTNAME" >/dev/null 2>&1; then
  die "A CT with hostname '$HOSTNAME' already exists. Choose a different --hostname or remove the existing one first."
fi

# ----- determine CTID -------------------------------------------------------
if [[ -z "$CTID" ]]; then
  CTID="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"')"
  [[ -n "$CTID" ]] || die "Couldn't auto-allocate CTID via 'pvesh get /cluster/nextid'."
  log "Auto-allocated CTID: $CTID"
fi

if pct status "$CTID" >/dev/null 2>&1; then
  die "CTID $CTID is already in use. Choose a different --ctid."
fi

# ----- resolve workstation SSH key ------------------------------------------
# Same pattern bootstrap-pve.sh uses: the PVE host's /root/.ssh/authorized_keys
# is the source of truth. Skip the PVE-self key (root@<pve-hostname>) if it's
# the only thing there.
SSH_KEYS_FILE=/root/.ssh/authorized_keys
[[ -f "$SSH_KEYS_FILE" && -s "$SSH_KEYS_FILE" ]] \
  || die "$SSH_KEYS_FILE is missing or empty. Add your workstation pubkey first (cat ~/.ssh/id_*.pub | ssh root@pve 'cat >> ~/.ssh/authorized_keys')."

PVE_HOST=$(hostname -s)
SSH_KEY="$(awk -v skip="root@$PVE_HOST" '
  /^ssh-/ && $NF != skip { print; found=1; exit }
  END { exit !found }
' "$SSH_KEYS_FILE")"

if [[ -z "$SSH_KEY" ]]; then
  warn "Only the PVE auto-key (root@$PVE_HOST) is in $SSH_KEYS_FILE."
  warn "The new CT will get THAT key, which means your workstation can't ssh in until you add your own key."
  printf "Continue anyway? [y/N]: "
  if (( ! DRY_RUN )); then read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted."; fi
  SSH_KEY="$(awk '/^ssh-/ { print; exit }' "$SSH_KEYS_FILE")"
fi

# ----- resolve Tailscale auth key ------------------------------------------
if [[ -z "$TS_AUTHKEY" ]]; then
  if (( DRY_RUN )); then
    TS_AUTHKEY="tskey-DRYRUN-PLACEHOLDER"
  else
    printf "\n\033[1;36m[setup-new-pi-agent]\033[0m Tailscale auth key from https://login.tailscale.com/admin/settings/keys (hidden):\n  " >&2
    printf "\033[1;33m  Single-use is fine for this script (only joins one CT). If you reuse a key across attempts, make it reusable.\033[0m\n  > " >&2
    IFS= read -rs TS_AUTHKEY; echo >&2
    [[ -n "$TS_AUTHKEY" ]] || die "Tailscale auth key required."
    [[ "$TS_AUTHKEY" == tskey-* ]] || warn "That doesn't look like a tskey-... auth key; proceeding anyway."
  fi
fi

# ----- resolve CT root password --------------------------------------------
if [[ -z "$CT_PASSWORD" ]]; then
  if (( DRY_RUN )); then
    CT_PASSWORD="dryrun-placeholder-pw"
  else
    printf "\n\033[1;36m[setup-new-pi-agent]\033[0m CT root password (hidden; for console fallback if ssh breaks): " >&2
    IFS= read -rs CT_PASSWORD; echo >&2
    [[ -n "$CT_PASSWORD" ]] || die "CT password required."
  fi
fi

# ----- find Debian 12 template ----------------------------------------------
log "Locating Debian 12 LXC template..."
TEMPLATE_FILE=""
TEMPLATE_FILE="$(ls /var/lib/vz/template/cache/debian-12-standard_*.tar.zst 2>/dev/null | sort -V | tail -1)"
if [[ -z "$TEMPLATE_FILE" ]]; then
  log "  Not cached — downloading the latest debian-12-standard template..."
  run "pveam update"
  # Get the exact filename from pveam available
  TEMPLATE_NAME="$(pveam available 2>/dev/null | awk '/debian-12-standard.*amd64/ {print $2}' | sort -V | tail -1)"
  [[ -n "$TEMPLATE_NAME" ]] || die "No debian-12-standard amd64 template found in pveam catalog."
  run "pveam download local '$TEMPLATE_NAME'"
  TEMPLATE_FILE="/var/lib/vz/template/cache/$TEMPLATE_NAME"
fi
TEMPLATE_REF="local:vztmpl/$(basename "$TEMPLATE_FILE")"
log "  Using: $TEMPLATE_REF"

# ----- summary before commit ------------------------------------------------
log "================================================================"
log "About to create a new pi agent:"
log "  Hostname:        $HOSTNAME"
log "  CTID:            $CTID"
log "  Resources:       $CPU cpu / $RAM MB RAM / $DISK GB disk"
log "  Workstation key: ${SSH_KEY:0:50}..."
[[ -n "$MODEL" ]] && log "  Ollama model:    $MODEL" || log "  Ollama model:    (setup-ollama-pi default — currently gemma4:31b-cloud)"
log "  Trust mesh:      $((( SKIP_TRUST_MESH )) && echo skipped || echo bidirectional with existing CTs)"
log "  Web UIs:         $((( SKIP_WEB_UIS )) && echo skipped || echo cards/term/shell on 9090/9091/9092)"
log "  Filebrowser:     $((( SKIP_FILEBROWSER )) && echo skipped || echo /root/uploads on smb://$HOSTNAME:8080)"
log "  SMB share:       $((( SKIP_SMB_SHARE )) && echo skipped || echo /root over smb://$HOSTNAME/home)"
log "  Homepage tile:   $((( SKIP_HOMEPAGE_TILE )) && echo skipped || echo registered)"
log "================================================================"

# ----- create CT ------------------------------------------------------------
log "Creating CT $CTID ($HOSTNAME)..."
SSH_KEYS_TMP=$(mktemp)
printf '%s\n' "$SSH_KEY" > "$SSH_KEYS_TMP"

# `pct create` doesn't take args via env vars; build the command string and
# eval through run() so --dry-run can preview it.
run "pct create $CTID '$TEMPLATE_REF' \
  --hostname '$HOSTNAME' \
  --cores $CPU --memory $RAM --swap 512 \
  --rootfs local-lvm:$DISK \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 \
  --features nesting=1 \
  --ssh-public-keys '$SSH_KEYS_TMP' \
  --password '$CT_PASSWORD' \
  --tags 'homelab;ollama-pi' \
  --onboot 1 \
  --start 0"
rm -f "$SSH_KEYS_TMP"

# ----- TUN device passthrough (unprivileged LXC needs this for Tailscale) ---
# An unprivileged LXC with --features nesting=1 still doesn't get /dev/net/tun
# by default. Without that device, tailscaled fails to start (the daemon needs
# TUN to create its tailscale0 interface). bootstrap-pve.sh adds the same two
# lines to the original ollama-pi-agent's config; we do the same here.
log "Adding /dev/net/tun passthrough to CT $CTID config..."
CT_CONF="/etc/pve/lxc/$CTID.conf"
if (( ! DRY_RUN )) && ! grep -q "/dev/net/tun" "$CT_CONF" 2>/dev/null; then
  cat >> "$CT_CONF" <<'TUN_BLOCK'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
TUN_BLOCK
fi
if (( DRY_RUN )); then
  printf "[dry-run] would append to %s:\n  lxc.cgroup2.devices.allow: c 10:200 rwm\n  lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file\n" "$CT_CONF"
fi

run "pct start $CTID"

log "Waiting for CT network to come up..."
if (( ! DRY_RUN )); then
  for i in {1..30}; do
    pct exec "$CTID" -- ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && break
    sleep 2
  done
  pct exec "$CTID" -- ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 \
    || warn "CT didn't get network within 60s. Check 'pct exec $CTID -- ip a' and proceed cautiously."
fi

# ----- install Tailscale + join the tailnet ---------------------------------
log "Installing Tailscale inside CT $CTID..."
run "pct exec $CTID -- bash -c 'apt-get update -qq && apt-get install -y -qq curl ca-certificates'"
run "pct exec $CTID -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'"

log "Bringing Tailscale up under hostname '$HOSTNAME'..."
run "pct exec $CTID -- tailscale up --reset --authkey '$TS_AUTHKEY' --hostname '$HOSTNAME' --accept-routes --accept-dns"

log "Waiting for Tailscale to reach Running..."
if (( ! DRY_RUN )); then
  for i in {1..20}; do
    pct exec "$CTID" -- tailscale status >/dev/null 2>&1 && break
    sleep 2
  done
fi

# ----- push PVE host authorized_keys (workstation access) -------------------
# bootstrap-pve.sh does the same thing for the initial CTs: the community
# helpers (and pct create's --ssh-public-keys flag in some versions) don't
# always preserve the full set of keys, so we push them explicitly.
log "Ensuring workstation SSH keys are present inside the CT..."
run "pct push $CTID /root/.ssh/authorized_keys /root/.ssh/authorized_keys --perms 0600"
run "pct exec $CTID -- chown root:root /root/.ssh/authorized_keys"

# ----- delegate to setup-ollama-pi.sh (Ollama install + signin + pi) -------
log "================================================================"
log "Delegating to setup-ollama-pi.sh for Ollama + pi install..."
log "  You'll see a 'ollama signin' URL — open it in a browser, click Connect."
log "================================================================"

OLLAMA_ARGS=(--ct-id "$CTID" --with-pi)
[[ -n "$MODEL" ]] && OLLAMA_ARGS+=(--model "$MODEL")
run "'$SETUP_OLLAMA' ${OLLAMA_ARGS[*]}"

# setup-ollama-pi.sh handles:
#   - Ollama install + signin (browser-pair flow)
#   - Model pull
#   - pi install on the with-pi target (which we're hitting via --ct-id)
#   - OUTBOUND trust: this agent's pubkey → sandbox/gitea/openwebui/homepage's
#     authorized_keys

# Sanity check: verify pi+Node actually landed before downstream addons try
# to use them. The interactive ollama.com signin can be skipped or fail
# (browser tab closed, network blip), in which case pi never installs and
# setup-pi-web-uis.sh would crash much later with 'npm: command not found'.
# Catch the gap here with a clear remediation message.
if (( ! DRY_RUN )) && (( ! SKIP_WEB_UIS )); then
  if ! pct exec "$CTID" -- bash -lc 'ls -d /root/.local/share/pi-node/node-v*/bin >/dev/null 2>&1'; then
    warn "================================================================"
    warn "setup-ollama-pi.sh finished but pi's Node ISN'T at"
    warn "  /root/.local/share/pi-node/  inside CT $CTID ($HOSTNAME)."
    warn "Most likely cause: the ollama.com signin step didn't complete, so"
    warn "the model pull + pi install steps were skipped."
    warn ""
    warn "Re-run setup-ollama-pi.sh by hand to finish that pairing flow:"
    warn "  $SETUP_OLLAMA --ct-id $CTID${MODEL:+ --model $MODEL}"
    warn ""
    warn "Then re-invoke this script (it'll skip the parts already done) or"
    warn "just run the remaining addons:"
    warn "  $SETUP_WEB_UIS --hostname $HOSTNAME"
    if (( ! SKIP_FILEBROWSER )); then
      warn "  $SETUP_FB --target $HOSTNAME"
    fi
    warn "================================================================"
    die "Aborting before downstream addons run — they need pi's Node."
  fi
fi

# ----- bidirectional trust mesh with other pi agents -----------------------
# setup-ollama-pi.sh seeds OUTBOUND trust to the standard "service" CTs
# (sandbox/gitea/openwebui/homepage). It doesn't know about peer pi agents.
# We close that gap here: scan for other pi-style CTs and wire trust both
# directions so any pi can ssh into any other pi without prompting.
if (( ! SKIP_TRUST_MESH )); then
  log "================================================================"
  log "Wiring SSH trust mesh with existing pi-style CTs..."

  # Discover pi-style CTs already on this host. We look at the conventional
  # names (ollama-pi-agent, pi-agent-N) — extend the list if you've renamed.
  declare -a PEER_HOSTS=()
  for candidate in ollama-pi-agent pi-agent-2 pi-agent-3 pi-agent-4 pi-agent-5 pi-agent-6 pi-agent-7 pi-agent-8 pi-agent-9; do
    [[ "$candidate" == "$HOSTNAME" ]] && continue
    if find_ct_by_hostname "$candidate" >/dev/null 2>&1; then
      PEER_HOSTS+=("$candidate")
    fi
  done

  if [[ ${#PEER_HOSTS[@]} -eq 0 ]]; then
    log "  No existing pi-style CTs found. Skipping mesh wiring."
  else
    log "  Found pi peers: ${PEER_HOSTS[*]}"

    # Get the new agent's pubkey (setup-ollama-pi.sh just generated it)
    NEW_PUBKEY="$(pct exec "$CTID" -- cat /root/.ssh/id_ed25519.pub 2>/dev/null || true)"
    [[ -n "$NEW_PUBKEY" ]] || warn "Couldn't read new agent's pubkey — trust mesh may be incomplete."

    for peer in "${PEER_HOSTS[@]}"; do
      peer_ctid="$(find_ct_by_hostname "$peer")"
      log "  [$peer (CT $peer_ctid)] wiring trust..."

      # 1. new pubkey → peer's authorized_keys (so new pi can ssh into peer)
      if [[ -n "$NEW_PUBKEY" ]]; then
        run "pct exec $peer_ctid -- bash -lc '
          mkdir -p /root/.ssh && chmod 700 /root/.ssh
          touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
          grep -qF \"$NEW_PUBKEY\" /root/.ssh/authorized_keys || echo \"$NEW_PUBKEY\" >> /root/.ssh/authorized_keys
        '"
      fi

      # 2. peer's pubkey → new agent's authorized_keys (so peer can ssh in)
      peer_pubkey="$(pct exec "$peer_ctid" -- cat /root/.ssh/id_ed25519.pub 2>/dev/null || true)"
      if [[ -n "$peer_pubkey" ]]; then
        run "pct exec $CTID -- bash -lc '
          mkdir -p /root/.ssh && chmod 700 /root/.ssh
          touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
          grep -qF \"$peer_pubkey\" /root/.ssh/authorized_keys || echo \"$peer_pubkey\" >> /root/.ssh/authorized_keys
        '"
      else
        warn "    Peer $peer has no /root/.ssh/id_ed25519.pub — peer→new trust will need to be set up after peer runs setup-ollama-pi.sh."
      fi

      # 3. pre-seed both directions' known_hosts so first ssh doesn't prompt
      run "pct exec $CTID -- bash -lc 'ssh-keyscan -H $peer >> /root/.ssh/known_hosts 2>/dev/null; sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts'"
      run "pct exec $peer_ctid -- bash -lc 'ssh-keyscan -H $HOSTNAME >> /root/.ssh/known_hosts 2>/dev/null; sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts'"
    done
  fi
  log "================================================================"
fi

# ----- pi web UIs (cards / terminal / shell) -------------------------------
if (( ! SKIP_WEB_UIS )); then
  log "================================================================"
  log "Delegating to setup-pi-web-uis.sh for cards/term/shell..."
  log "================================================================"
  run "'$SETUP_WEB_UIS' --hostname '$HOSTNAME'"
fi

# ----- filebrowser (default-on; --skip-filebrowser to opt out) ------------
if (( ! SKIP_FILEBROWSER )) && [[ -x "$SETUP_FB" ]]; then
  log "================================================================"
  log "Delegating to setup-filebrowser.sh..."
  log "================================================================"
  # setup-filebrowser.sh will prompt for admin user + password since this
  # script doesn't manage homelab admin creds — that lives with the main
  # configure-apps.sh flow. Tip: reuse the same admin creds you use for
  # Gitea/OpenWebUI to keep one password to remember.
  run "'$SETUP_FB' --target '$HOSTNAME'"
fi

# ----- SMB share on /root -------------------------------------------------
# Default ON for new pi agents so you can mount the agent's home directory
# from your laptop's Finder / Explorer without scp / sftp. SMB auth uses
# the CT root password the user already provided above, mapped to the
# Samba 'root' user. --skip-smb-share opts out.
if (( ! SKIP_SMB_SHARE )); then
  log "================================================================"
  log "Delegating to setup-smb-share.sh for SMB share on /root..."
  log "================================================================"
  run "'$SETUP_SMB' --target '$HOSTNAME' --password '$CT_PASSWORD'"
fi

# ----- Homepage tile for the agent itself (the "machine" tile) -------------
# This is separate from the per-UI tiles that setup-pi-web-uis.sh registers.
# This tile names the agent and links to its SSH endpoint; useful when you
# want one canonical place to land on the dashboard for each agent.
if (( ! SKIP_HOMEPAGE_TILE )); then
  log "Registering Homepage 'machine' tile for $HOSTNAME..."

  homepage_ctid="$(find_ct_by_hostname homepage 2>/dev/null || true)"
  if [[ -z "$homepage_ctid" ]]; then
    log "  Homepage CT not found — skipping tile (re-run after the homepage CT is up)."
  else
    services_file="$(pct exec "$homepage_ctid" -- bash -lc '
      for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage /var/lib/homepage/config; do
        if [[ -f "$d/services.yaml" ]]; then echo "$d/services.yaml"; exit 0; fi
      done
    ' 2>/dev/null | tail -n1)"

    if [[ -z "$services_file" ]]; then
      log "  Could not locate services.yaml on homepage — skipping tile."
    else
      marker="# TD-Addon: pi-agent-machine-$HOSTNAME"
      tile_block="- AI:
    - $HOSTNAME:
        description: pi coding agent runtime (ssh root@$HOSTNAME)
        icon: ollama.png"

      # awk surgical block-replace if our marker already exists
      if (( ! DRY_RUN )) && pct exec "$homepage_ctid" -- grep -qF "$marker" "$services_file" 2>/dev/null; then
        log "  Updating existing tile..."
        run "pct exec $homepage_ctid -- bash -lc \"awk -v m='$marker' '
          \\\$0 ~ m { in_block=1; next }
          in_block && \\\$0 ~ /^# TD-Addon:/ { in_block=0 }
          !in_block { print }
        ' '$services_file' > /tmp/services.yaml.new && mv /tmp/services.yaml.new '$services_file'\""
      fi

      run "printf '\\n%s\\n%s\\n' '$marker' '$tile_block' | pct exec $homepage_ctid -- tee -a '$services_file' >/dev/null"
      run "pct exec $homepage_ctid -- bash -lc 'systemctl restart homepage 2>/dev/null || systemctl restart gethomepage 2>/dev/null || true'"
    fi
  fi
fi

# ----- done ----------------------------------------------------------------
log "================================================================"
log "==> Done. New pi agent ready."
log " "
log "  Hostname:    $HOSTNAME"
log "  CTID:        $CTID"
log "  SSH:         ssh root@$HOSTNAME"
log "  pi (CLI):    pct enter $CTID  →  ollama launch pi"
if (( ! SKIP_WEB_UIS )); then
log "  Cards UI:    http://$HOSTNAME:9090"
log "  pi terminal: http://$HOSTNAME:9091"
log "  Plain shell: http://$HOSTNAME:9092"
fi
if (( ! SKIP_FILEBROWSER )); then
log "  Files:       http://$HOSTNAME:8080"
fi
if (( ! SKIP_SMB_SHARE )); then
log "  SMB share:   smb://$HOSTNAME/home  (user: root, password: the CT root password you provided)"
fi
if (( ! SKIP_HOMEPAGE_TILE )); then
log "  Homepage:    http://homepage (look for the '$HOSTNAME' tile in the AI group)"
fi
log "================================================================"
