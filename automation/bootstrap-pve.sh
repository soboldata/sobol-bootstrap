#!/usr/bin/env bash
# bootstrap-pve.sh — Take a fresh Proxmox VE 9.x install from "root login works"
# to "four LXC containers up and joined to your Tailscale tailnet."
#
# Usage (zero flags — script prompts for everything it needs):
#   ./bootstrap-pve.sh
#
# Or pass any subset as flags:
#   ./bootstrap-pve.sh \
#       --sshkey-file /root/workstation.pub \
#       --tsauthkey   tskey-auth-XXXXXXXXXXXXXXXX-YYYYYYYYYYYYYYY \
#       --ct-password 'strongpass'
#
# Secret inputs (each can come from a flag OR an interactive prompt):
#   --sshkey-file <path>   Path to a .pub file (already on the host).
#   --sshkey-text <key>    Or paste the whole 'ssh-... AAAA... user@host' string.
#   --tsauthkey   <key>    Tailscale auth key (tskey-auth-...).
#                          Generate at https://login.tailscale.com/admin/settings/keys.
#   --ct-password <pw>     Root password for ollama-pi-agent (TS auth-key login means
#                          you rarely need this, but pct create needs one).
#
# When --sshkey-file/--sshkey-text is missing the script prompts you to paste
# a public key (one line). When --tsauthkey or --ct-password is missing it
# prompts with hidden input (no echo).
#
# Optional flags:
#   --skip-update          Skip apt update/upgrade
#   --skip-repos           Don't touch repo files
#   --with-sandbox         Also install sandbox (Docker host) CT — opt-in
#   --with-openwebui       Also install openwebui (chat UI) CT — opt-in
#   --yes, -y              Non-interactive; accept defaults
#   --only ollama-pi-agent,gitea   Subset of CTs (comma-separated keys)
#   --dry-run              Print commands instead of running them
#
# CTs created (DHCP, IPv6 SLAAC, bridge vmbr0):
#   CORE (always — the sobol-foundation manifest core_apps set):
#     200  ollama-pi-agent  pct create — Debian 12 + manual Ollama/pi (Phase 4)
#     202  gitea            via community-scripts.org/ct/gitea.sh
#     110  homepage         via community-scripts.org/ct/homepage.sh (dashboard)
#   OPT-IN (only if --with-* passed — manifest optional_apps):
#     215  sandbox          via community-scripts.org/ct/docker.sh (Docker preinstalled)
#     100  openwebui        via community-scripts.org/ct/openwebui.sh
#
# NOTE 2026-07-01: sandbox + openwebui defaulted to install in earlier
# revisions of this script. They're now opt-in — the manifest lists them
# as optional_apps, and this script's default now matches. Future: replace
# these embedded community-scripts URLs with proper addons (setup-sandbox.sh
# + setup-openwebui.sh in sobol-foundation/addons/) so setup-stack.sh
# --include-optional handles them cleanly. Bootstrap-pve.sh will drop the
# --with-* flags entirely when those addons land.
#
# After each CT comes up, the Tailscale add-on is applied and `tailscale up`
# runs with --authkey for non-interactive auth.
#
# This script is idempotent — re-running skips work already done (existing CT,
# enabled repo, etc.). Failures abort cleanly.

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
# TEMPLATE_NAME is resolved at runtime via ensure_template() — we ask pveam for
# the latest available debian-12-standard build. Pinning a version string here
# would 404 the next time Proxmox bumps the point release (12.12-1 → 12.13-1).
TEMPLATE_NAME=""
TEMPLATE_REF=""
STORAGE_DISK="local-lvm"
BRIDGE="vmbr0"

# After install_pve_sshkey runs, all CT creation reads from this file. That way
# we pick up every key currently authorized on the PVE host — not just the one
# pasted at the prompt — and there is exactly one source of truth.
AUTHKEYS_FILE="/root/.ssh/authorized_keys"

DEFAULT_CORES=4
DEFAULT_MEMORY=4096
DEFAULT_SWAP=512
DEFAULT_DISK_GB=20

SSHKEY_FILE=""
SSHKEY_TEXT=""
TS_AUTHKEY=""
CT_PASSWORD=""
SKIP_UPDATE=0
SKIP_REPOS=0
ONLY=""
DRY_RUN=0
TMP_SSHKEY_FILE=""   # populated if we have to materialise a pasted key

# Optional CTs. The CORE homelab is ollama-pi-agent + gitea + homepage.
# sandbox (Docker host) + openwebui (Chat UI) are OPT-IN — the manifest
# lists them as optional_apps. Enable with --with-sandbox / --with-openwebui.
WANT_SANDBOX=0
WANT_OPENWEBUI=0

# CTID -> hostname / role
# Hostnames must be DNS-safe (alphanumeric + hyphens, no spaces) — that's a
# constraint of LXC/Linux, not of this script. The CT that runs Docker is
# named 'sandbox' rather than 'docker' to avoid the prompt-naming clash
# ("run a docker on docker"); the community helper script is still ct/docker.sh.
declare -A CT_HOSTNAME=(
  [200]="ollama-pi-agent"
  [215]="sandbox"
  [202]="gitea"
  [100]="openwebui"
  [110]="homepage"
)
# CTs we create with pct create directly. Only ollama-pi-agent needs this —
# the others all have well-maintained community-scripts helpers.
PCT_CREATE_CTS=(200)
# CTs we delegate to community-scripts helper scripts
HELPER_SCRIPTS=(
  "215|sandbox|https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh"
  "202|gitea|https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/gitea.sh"
  "100|openwebui|https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/openwebui.sh"
  "110|homepage|https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/homepage.sh"
)
# Tailscale add-on (run against an existing CT)
# NOTE: community add-tailscale-lxc.sh whiptail-prompts for CTID even when
# CTID env var is set, so we install Tailscale directly via pct exec instead
# (see install_tailscale_in_ct below). Variable kept here for documentation only.
# TS_ADDON_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/addon/add-tailscale-lxc.sh"

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sshkey-file)   SSHKEY_FILE="$2"; shift 2 ;;
    --sshkey-text)   SSHKEY_TEXT="$2"; shift 2 ;;
    --tsauthkey)     TS_AUTHKEY="$2"; shift 2 ;;
    --ct-password)   CT_PASSWORD="$2"; shift 2 ;;
    --skip-update)   SKIP_UPDATE=1; shift ;;
    --skip-repos)    SKIP_REPOS=1; shift ;;
    --with-sandbox)  WANT_SANDBOX=1; shift ;;
    --with-openwebui) WANT_OPENWEBUI=1; shift ;;
    # Back-compat: --skip-* used to opt out of on-by-default installs; now
    # sandbox + openwebui are off by default so these are no-ops. Accept
    # silently so old scripts / firstboot templates don't break.
    --skip-sandbox|--skip-openwebui) shift ;;
    --yes|-y)        shift ;;
    --only)          ONLY="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- preflight -------------------------------------------------------------
log()  { printf "\n\033[1;36m[bootstrap]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[bootstrap]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[bootstrap]\033[0m %s\n" "$*" >&2; exit 1; }

run() {
  if (( DRY_RUN )); then
    printf "[dry-run] %s\n" "$*"
  else
    eval "$@"
  fi
}

# ----- install profile (core-only by default) ------------------------------
# Core CTs (always installed): ollama-pi-agent, gitea, homepage.
# sandbox + openwebui are opt-in via --with-* (see manifest optional_apps).
# Sensible default = core only; power users add --with-* flags.
yn() { (( $1 )) && echo "YES" || echo "no"; }
log "Install profile:"
log "  Core (always):       ollama-pi-agent  gitea  homepage"
log "  sandbox (Docker):    $(yn $WANT_SANDBOX)   ${WANT_SANDBOX:+[--with-sandbox]}"
log "  openwebui (chat):    $(yn $WANT_OPENWEBUI)   ${WANT_OPENWEBUI:+[--with-openwebui]}"

# Filter HELPER_SCRIPTS down to the chosen profile. Iterating the existing
# array and rebuilding lets us preserve order (sandbox → gitea → openwebui
# → homepage) so dependencies (e.g., Gitea ready before homepage's tile
# config tries to reach it) hold.
declare -a FILTERED_HELPERS=()
for entry in "${HELPER_SCRIPTS[@]}"; do
  IFS='|' read -r _ehn _ehost _eurl <<< "$entry"
  case "$_ehost" in
    sandbox)   (( WANT_SANDBOX ))   && FILTERED_HELPERS+=("$entry") ;;
    openwebui) (( WANT_OPENWEBUI )) && FILTERED_HELPERS+=("$entry") ;;
    *)         FILTERED_HELPERS+=("$entry") ;;
  esac
done
HELPER_SCRIPTS=("${FILTERED_HELPERS[@]}")

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pveam >/dev/null || die "pveam not found — is this a PVE host?"
command -v pct   >/dev/null || die "pct not found — is this a PVE host?"

# Drop any tmp key file we materialised, even on failure.
cleanup_tmp_keyfile() {
  [[ -n "$TMP_SSHKEY_FILE" && -f "$TMP_SSHKEY_FILE" ]] && rm -f "$TMP_SSHKEY_FILE"
}
trap cleanup_tmp_keyfile EXIT

# ----- CT state helpers (used both by preflight and the main loop) ----------
ct_exists()    { pct status "$1" >/dev/null 2>&1; }
ct_running()   { pct status "$1" 2>/dev/null | grep -q "status: running"; }
ct_on_tailnet() {
  # True if the container exists, is running, and has a 100.x tailnet IP.
  ct_running "$1" || return 1
  pct exec "$1" -- bash -lc '
    command -v tailscale >/dev/null 2>&1 \
      && tailscale ip -4 2>/dev/null | grep -q "^100\."
  ' 2>/dev/null
}

# Snapshot of CTIDs that exist on the host. Used to detect what a helper
# created (since most community-scripts auto-assign CTID, ignoring env vars),
# AND to look up an existing CT by its hostname during preflight.
_list_ctids() { pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort; }

find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(_list_ctids); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# Iterate every CTID this run might touch.
all_ctids() {
  local c entry
  for c in "${PCT_CREATE_CTS[@]}"; do echo "$c"; done
  for entry in "${HELPER_SCRIPTS[@]}"; do
    IFS='|' read -r c _ _ <<< "$entry"
    echo "$c"
  done
}

# Filter CTs by --only=key1,key2 (hostnames, comma-separated)
selected_key() {
  local key="$1"
  if [[ -z "$ONLY" ]]; then return 0; fi
  IFS=',' read -ra wanted <<< "$ONLY"
  for w in "${wanted[@]}"; do [[ "$w" == "$key" ]] && return 0; done
  return 1
}

# ----- preflight: figure out what work actually needs doing -----------------
# Sets NEEDS_CT_PASSWORD and NEEDS_TS_AUTHKEY so the resolve_* functions can
# skip prompting for inputs they won't end up using.
preflight_state() {
  CTS_TO_CREATE=()
  CTS_NEED_TAILSCALE=()
  CTS_ALREADY_DONE=()

  if (( DRY_RUN )); then
    # Don't poke at the host's actual state in dry-run; assume all work needed.
    NEEDS_CT_PASSWORD=1
    NEEDS_TS_AUTHKEY=1
    log "Preflight: dry-run, assuming all work needs doing."
    return
  fi

  local c key actual
  for c in $(all_ctids); do
    key="${CT_HOSTNAME[$c]}"
    selected_key "$key" || continue

    # Look up by HOSTNAME first — the static CTID map drifts as helper scripts
    # auto-assign IDs. The previous version trusted the static CTID and could
    # confuse one CT's state for another's (e.g., 'is openwebui on tailnet?'
    # answered against CT 100 which is actually sandbox).
    actual="$(find_ct_by_hostname "$key" 2>/dev/null || true)"
    if [[ -z "$actual" ]] && ct_exists "$c"; then
      actual="$c"
    fi

    if [[ -z "$actual" ]]; then
      CTS_TO_CREATE+=("$c")
      CTS_NEED_TAILSCALE+=("$c")
    elif ! ct_on_tailnet "$actual"; then
      CTS_NEED_TAILSCALE+=("$actual")
    else
      CTS_ALREADY_DONE+=("$actual")
    fi
  done

  NEEDS_CT_PASSWORD=$(( ${#CTS_TO_CREATE[@]}     > 0 ))
  NEEDS_TS_AUTHKEY=$((  ${#CTS_NEED_TAILSCALE[@]} > 0 ))

  log "Preflight: ${#CTS_TO_CREATE[@]} CT(s) to create, ${#CTS_NEED_TAILSCALE[@]} need Tailscale join, ${#CTS_ALREADY_DONE[@]} already done."
}

# ----- resolve SSH public key -----------------------------------------------
# Priority: --sshkey-file > --sshkey-text > existing /root/.ssh/authorized_keys > prompt.
# Whichever path we take, end state: SSHKEY_FILE is a readable file on disk
# (pct create wants a path, not a string).
resolve_sshkey() {
  if [[ -n "$SSHKEY_FILE" ]]; then
    [[ -f "$SSHKEY_FILE" ]] || die "SSH key file not found: $SSHKEY_FILE"
    return
  fi

  if [[ -z "$SSHKEY_TEXT" ]]; then
    # PVE 9.x symlinks /root/.ssh/authorized_keys → /etc/pve/priv/authorized_keys
    # and pre-populates the target with an auto-generated 'root@<hostname>' key
    # for inter-node management. A plain '-s file' check sees that as "user has
    # added their key" and would skip the prompt — leaving the user's actual
    # workstation key uninstalled and unable to ssh in. So we only skip the
    # prompt if we find at least one key whose comment isn't 'root@<this-host>'.
    if [[ -s "$AUTHKEYS_FILE" ]]; then
      local self_host
      self_host="$(hostname -s 2>/dev/null || hostname)"
      if grep -E "^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-)" "$AUTHKEYS_FILE" 2>/dev/null \
         | awk -v def="root@$self_host" '$NF != def { found=1 } END { exit !found }'; then
        log "SSH key already present in $AUTHKEYS_FILE (non-PVE-default) — reusing (no prompt)."
        SSHKEY_FILE="$AUTHKEYS_FILE"
        return
      fi
      log "Only PVE auto-key (root@$self_host) found in $AUTHKEYS_FILE — will prompt for your workstation key."
    fi

    # Dry-run: skip the prompt with a placeholder.
    if (( DRY_RUN )); then
      TMP_SSHKEY_FILE="$(mktemp /tmp/bootstrap-sshkey.XXXXXX.pub)"
      chmod 600 "$TMP_SSHKEY_FILE"
      echo "ssh-ed25519 DRY_RUN_PLACEHOLDER dry@run" > "$TMP_SSHKEY_FILE"
      SSHKEY_FILE="$TMP_SSHKEY_FILE"
      log "Dry-run: using placeholder SSH key."
      return
    fi

    printf "\n\033[1;36m[bootstrap]\033[0m Paste your workstation's SSH PUBLIC key (one line, starts with ssh-...), then Enter:\n> " >&2
    IFS= read -r SSHKEY_TEXT
  fi

  # Sanity-check shape
  [[ "$SSHKEY_TEXT" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-) ]] \
    || die "That doesn't look like an SSH public key (must start with ssh-rsa / ssh-ed25519 / ecdsa-...)."

  TMP_SSHKEY_FILE="$(mktemp /tmp/bootstrap-sshkey.XXXXXX.pub)"
  chmod 600 "$TMP_SSHKEY_FILE"
  printf '%s\n' "$SSHKEY_TEXT" > "$TMP_SSHKEY_FILE"
  SSHKEY_FILE="$TMP_SSHKEY_FILE"
  log "SSH key staged at $SSHKEY_FILE (will be wiped on exit)."
}

# ----- locate tokens file ---------------------------------------------------
# Read TS_AUTHKEY and CT_PASSWORD from a tokens file before falling back to
# interactive prompts. Lets firstboot.sh / automation pass secrets via file
# instead of CLI flags (CLI flags are visible in 'ps aux' to anyone who can
# shell on the host — a real concern when we ship to paying customers).
_locate_tokens_file() {
  if [[ -n "${TOKENS_FILE:-}" && -f "$TOKENS_FILE" ]]; then
    printf '%s\n' "$TOKENS_FILE"; return
  fi
  for f in /root/td-tokens.txt /root/studio-tokens.txt /root/sobol-tokens.txt /root/founder-tokens.txt; do
    [[ -f "$f" ]] && { printf '%s\n' "$f"; return; }
  done
  return 1
}

_read_token() {
  local key="$1" tf v
  tf="$(_locate_tokens_file)" || return 1
  v="$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); val = $0 } END { print val }' "$tf")"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    "<"*">"|""|"REPLACE_ME"|"CHANGEME") return 1 ;;
  esac
  printf '%s\n' "$v"
}

# ----- resolve Tailscale auth key -------------------------------------------
resolve_tsauthkey() {
  if [[ -n "$TS_AUTHKEY" ]]; then return; fi

  # Nothing to join? Don't ask.
  if (( NEEDS_TS_AUTHKEY == 0 )); then
    log "All target CTs already on tailnet — no Tailscale auth key needed."
    TS_AUTHKEY="UNUSED_ALREADY_JOINED"
    return
  fi

  if (( DRY_RUN )); then
    TS_AUTHKEY="tskey-auth-DRY_RUN_PLACEHOLDER"
    log "Dry-run: using placeholder Tailscale auth key."
    return
  fi

  # Try tokens file first (unattended use case). Avoids putting the key
  # on the command line where 'ps aux' can see it.
  local fromfile
  if fromfile="$(_read_token TS_AUTHKEY 2>/dev/null)" && \
     [[ "$fromfile" =~ ^tskey-(auth|client)- ]]; then
    TS_AUTHKEY="$fromfile"
    log "Resolved TS_AUTHKEY from $(_locate_tokens_file)"
    return
  fi

  printf "\n\033[1;36m[bootstrap]\033[0m Tailscale auth key needed (tskey-auth-...). Input hidden.\n" >&2
  printf "\033[1;33m  IMPORTANT: the key MUST be reusable — bootstrap joins 5 CTs with this one key.\n" >&2
  printf "  A default (single-use) key will succeed on CT #1 and reject every CT after.\n" >&2
  printf "  Create one at https://login.tailscale.com/admin/settings/keys with Reusable=ON.\033[0m\n" >&2
  printf "\n\033[1;36m[bootstrap]\033[0m > " >&2
  IFS= read -rs TS_AUTHKEY
  echo >&2
  [[ "$TS_AUTHKEY" =~ ^tskey-(auth|client)- ]] \
    || die "That doesn't look like a Tailscale auth key (expected tskey-auth-... or tskey-client-...)."
}

# ----- resolve root password for new CTs ------------------------------------
resolve_ct_password() {
  if [[ -n "$CT_PASSWORD" ]]; then return; fi

  # Nothing to create? Don't ask.
  if (( NEEDS_CT_PASSWORD == 0 )); then
    log "All target CTs already exist — no root password needed for this run."
    CT_PASSWORD="UNUSED_NO_NEW_CTS"
    return
  fi

  if (( DRY_RUN )); then
    CT_PASSWORD="dry-run-placeholder-pw"
    log "Dry-run: using placeholder CT password."
    return
  fi

  # Try tokens file first (unattended use case). Avoids exposing in 'ps aux'.
  local fromfile
  if fromfile="$(_read_token CT_PASSWORD 2>/dev/null)" && [[ ${#fromfile} -ge 8 ]]; then
    CT_PASSWORD="$fromfile"
    log "Resolved CT_PASSWORD from $(_locate_tokens_file)"
    return
  fi

  local pw1 pw2
  printf "\n\033[1;36m[bootstrap]\033[0m Set a root password for the new containers. Input hidden:\n> " >&2
  IFS= read -rs pw1; echo >&2
  printf "Confirm: " >&2
  IFS= read -rs pw2; echo >&2
  [[ "$pw1" == "$pw2"   ]] || die "Passwords did not match."
  [[ ${#pw1} -ge 8      ]] || die "Password too short (need >= 8 chars)."
  CT_PASSWORD="$pw1"
}

preflight_state
resolve_sshkey
resolve_tsauthkey
resolve_ct_password

# ----- 1. repos: enable no-subscription, disable enterprise ------------------
# Reference: community-scripts.org tools/pve/post-pve-install.sh handles this
# cleanly across PVE 8 (.list) and PVE 9 (.sources / deb822). We follow the
# same approach: pick the format based on what's on disk, then operate.
#
# Key gotchas from PVE 9:
#   - Default state has NO `Enabled:` line in .sources files (implicit true),
#     so a simple sed s/yes/false/ does nothing. Need to APPEND `Enabled: false`
#     if no Enabled line exists, otherwise replace.
#   - The marker for "is this the enterprise repo" is `Components: pve-enterprise`
#     and similarly `Components: ... ceph-... enterprise` for Ceph, not the URI.
#   - Repo filenames vary (pve-enterprise.sources, proxmox.sources, etc.) so
#     we scan all .sources files rather than guessing the name.

# Helper: ensure a .sources file is disabled. Replaces existing Enabled: line,
# or appends one if none exists.
_disable_sources_file() {
  local file="$1"
  if grep -q "^Enabled:" "$file" 2>/dev/null; then
    run "sed -i 's|^Enabled:.*|Enabled: false|' '$file'"
  else
    run "printf 'Enabled: false\n' >> '$file'"
  fi
}

configure_repos() {
  (( SKIP_REPOS )) && { log "Skipping repo step (--skip-repos)"; return; }
  log "Configuring APT repos: enable pve-no-subscription, disable enterprise."

  # Detect format. PVE 9.1 default is deb822 .sources files; older PVE 8 uses .list.
  local has_sources=0
  if find /etc/apt/sources.list.d/ -maxdepth 1 -name '*.sources' 2>/dev/null | grep -q .; then
    has_sources=1
  fi

  if (( has_sources )); then
    # ----- PVE 9 / deb822 path ----------------------------------------------
    log "  Detected deb822 (.sources) format — using PVE 9 path."

    # Disable any .sources file that declares Components: pve-enterprise
    local file
    for file in /etc/apt/sources.list.d/*.sources; do
      [[ -f "$file" ]] || continue
      if grep -Eq "^[^#]*Components:[^#]*\bpve-enterprise\b" "$file"; then
        _disable_sources_file "$file"
        log "  Disabled pve-enterprise in $file"
      fi
    done

    # Disable Ceph enterprise (matches URI 'enterprise.proxmox.com' near 'ceph-')
    for file in /etc/apt/sources.list.d/*.sources; do
      [[ -f "$file" ]] || continue
      if grep -Eq "URIs:.*enterprise\.proxmox\.com.*ceph|URIs:.*ceph.*enterprise\.proxmox\.com" "$file" \
         || grep -Eq "^[^#]*Components:[^#]*\bceph.*enterprise\b" "$file"; then
        _disable_sources_file "$file"
        log "  Disabled ceph enterprise in $file"
      fi
    done

    # Add pve-no-subscription if no .sources file already declares it
    if ! grep -lEq "^[^#]*Components:[^#]*\bpve-no-subscription\b" /etc/apt/sources.list.d/*.sources 2>/dev/null; then
      local CODENAME
      CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-trixie}")"
      run "cat > /etc/apt/sources.list.d/proxmox.sources <<SRC
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $CODENAME
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SRC"
      log "  Added pve-no-subscription as deb822 (/etc/apt/sources.list.d/proxmox.sources)"
    else
      log "  pve-no-subscription already declared in a .sources file — leaving as is."
    fi
    return
  fi

  # ----- PVE 8 / .list path (kept for back-compat) --------------------------
  log "  Using legacy .list format (PVE 8 style)."
  local ENT="/etc/apt/sources.list.d/pve-enterprise.list"
  local CEPH_ENT="/etc/apt/sources.list.d/ceph.list"
  local NOSUB="/etc/apt/sources.list.d/pve-no-subscription.list"

  if [[ -f "$ENT" ]] && grep -Eq "^deb[[:space:]]" "$ENT"; then
    run "sed -i 's|^deb |# deb |' '$ENT'"
    log "  Disabled $ENT"
  fi
  if [[ -f "$CEPH_ENT" ]] && grep -Eq "^deb[[:space:]].*enterprise" "$CEPH_ENT"; then
    run "sed -i 's|^deb \\(.*enterprise.*\\)|# deb \\1|' '$CEPH_ENT'"
    log "  Disabled enterprise line in $CEPH_ENT"
  fi
  if [[ ! -f "$NOSUB" ]]; then
    local CODENAME
    CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"
    run "echo 'deb http://download.proxmox.com/debian/pve $CODENAME pve-no-subscription' > '$NOSUB'"
    log "  Added $NOSUB"
  fi
}

# ----- 2. apt update + upgrade ----------------------------------------------
apt_refresh() {
  (( SKIP_UPDATE )) && { log "Skipping apt update/upgrade (--skip-update)"; return; }
  log "apt update && apt upgrade -y"
  run "DEBIAN_FRONTEND=noninteractive apt-get update"
  run "DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"
}

# ----- 3. SSH key into root@PVE ---------------------------------------------
install_pve_sshkey() {
  log "Installing SSH key on PVE host."
  run "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
  local KEY
  KEY="$(<"$SSHKEY_FILE")"
  if ! grep -qF "$KEY" /root/.ssh/authorized_keys 2>/dev/null; then
    run "printf '%s\n' \"$KEY\" >> /root/.ssh/authorized_keys"
    run "chmod 600 /root/.ssh/authorized_keys"
  else
    log "  (key already present)"
  fi
}

# ----- 4. Debian template (pveam) -------------------------------------------
ensure_template() {
  # Resolve the latest debian-12-standard build at runtime — pinning a
  # version (e.g. 12.12-1) would break when Proxmox bumps point releases.
  if [[ -z "$TEMPLATE_NAME" ]]; then
    run "pveam update >/dev/null"
    if (( DRY_RUN )); then
      TEMPLATE_NAME="debian-12-standard_<latest>_amd64.tar.zst"
    else
      TEMPLATE_NAME="$(pveam available --section system 2>/dev/null \
        | awk '/debian-12-standard.*amd64\.tar\.zst/ {print $2}' \
        | sort -V | tail -1)"
    fi
    [[ -n "$TEMPLATE_NAME" ]] || die "Could not find a debian-12-standard template via pveam available."
    TEMPLATE_REF="local:vztmpl/${TEMPLATE_NAME}"
    log "Resolved latest Debian 12 template: $TEMPLATE_NAME"
  fi

  log "Ensuring template is downloaded: $TEMPLATE_NAME"
  if pveam list local 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
    log "  (template already present)"
    return
  fi
  run "pveam download local '$TEMPLATE_NAME'"
}

# ----- 5. CT creation via pct ------------------------------------------------
# (ct_exists, ct_running, ct_on_tailnet defined earlier near the preflight)

create_pct_ct() {
  local CTID="$1"
  local HOSTNAME="${CT_HOSTNAME[$CTID]}"

  if ct_exists "$CTID"; then
    log "  CT $CTID ($HOSTNAME) already exists — skipping create."
    return
  fi

  log "Creating CT $CTID ($HOSTNAME) — keys sourced from $AUTHKEYS_FILE"
  run "pct create $CTID '$TEMPLATE_REF' \
        --hostname '$HOSTNAME' \
        --password '$CT_PASSWORD' \
        --ssh-public-keys '$AUTHKEYS_FILE' \
        --cores $DEFAULT_CORES \
        --memory $DEFAULT_MEMORY \
        --swap $DEFAULT_SWAP \
        --rootfs '$STORAGE_DISK:$DEFAULT_DISK_GB' \
        --net0 'name=eth0,bridge=$BRIDGE,ip=dhcp,ip6=auto' \
        --features nesting=1 \
        --unprivileged 1 \
        --onboot 1 \
        --start 0"

  # Allow /dev/net/tun inside the unprivileged container (needed for Tailscale/Docker)
  local CONF="/etc/pve/lxc/${CTID}.conf"
  if ! grep -q "tun" "$CONF" 2>/dev/null; then
    run "cat >> '$CONF' <<'TUN_BLOCK'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
TUN_BLOCK"
  fi

  run "pct start $CTID"
  # Give it a moment to get DHCP + sshd up
  run "sleep 8"
}

# ----- 6. Helper-script CTs (Gitea, OpenWebUI) ------------------------------
# Run inside the PVE host shell, but driven non-interactively where possible by
# pre-exporting variables the community scripts respect.
# (_list_ctids + find_ct_by_hostname are defined earlier near the preflight.)

run_helper_script() {
  # Note the CTID arg is now the PREFERRED id — the community helpers don't
  # honor CT_ID env vars, so we just let them auto-assign and detect.
  local CTID_PREF="$1" KEY="$2" URL="$3"

  # If a CT with this hostname already exists, re-use it.
  local existing
  existing="$(find_ct_by_hostname "$KEY" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    log "  Found existing CT $existing with hostname '$KEY' — skipping helper, will use it."
    CREATED_CTID="$existing"
    return
  fi

  log "Installing $KEY via community-scripts.org (preferred CTID $CTID_PREF, may differ)..."
  log "  Note: the helper may show whiptail menus. Pick 'Default Install' unless"
  log "  you want to override the CTID via Advanced — either is fine, the script"
  log "  detects whichever CT actually gets created."

  # Snapshot before
  local before_ctids
  before_ctids="$(_list_ctids)"

  # Run the helper. We still pass env vars that ARE honored (var_cpu, var_ram,
  # var_disk, etc.) and SSH_AUTHORIZED_KEY which most helpers respect.
  # We do NOT try to dictate CT_ID — most helpers ignore it.
  #
  # var_gpu=no: openwebui.sh defaults to yes and triggers a multi-minute
  # CUDA/GPU support install that's wasted on the typical homelab box
  # (no discrete GPU). Harmless no-op for helpers that don't reference
  # var_gpu (docker.sh, gitea.sh, homepage.sh). If you do have a GPU and
  # want OpenWebUI to use it, remove this line or set var_gpu=yes.
  # Note: build.func's whitelist requires the var_* prefix. The real env-var
  # names are:
  #   var_ctid          → preferred CTID (helpers ignore CT_ID)
  #   var_hostname      → CT hostname
  #   var_pw            → root password
  #   var_gpu=no        → skip OpenWebUI GPU passthrough setup
  #   var_ssh=yes       → enable SSH inside the CT
  #   var_ssh_authorized_key → key content; install.func writes to
  #                            /root/.ssh/authorized_keys on first boot
  #
  # IMPORTANT: we do NOT pass var_cpu / var_ram / var_disk. Each helper has
  # its own well-tuned defaults for its actual install footprint:
  #   sandbox (docker.sh): 2 cpu / 2 GB RAM / 4 GB disk
  #   gitea:     1 cpu / 1 GB RAM / 8 GB disk
  #   openwebui: 4 cpu / 8 GB RAM / 50 GB disk  ← needs the headroom
  #   homepage:  1 cpu / 1 GB RAM / 4 GB disk
  # Overriding these globally is what caused OpenWebUI's install to fail
  # mid-Intel-oneAPI when we squeezed disk down to 20 GB. If you want
  # different sizes (e.g. small RAM box where 8 GB OpenWebUI is too much),
  # add per-helper overrides via the HELPER_SCRIPTS array entries.
  #
  # push_pve_keys_to_ct still runs as a safety net for cases where the user
  # picks 'Advanced Install' in the whiptail (which overrides our env).
  run "var_ctid=$CTID_PREF \
       var_hostname=$KEY \
       var_gpu=no \
       var_pw='$CT_PASSWORD' \
       var_ssh=yes \
       var_ssh_authorized_key=\"\$(cat '$AUTHKEYS_FILE')\" \
       bash -c \"\$(curl -fsSL '$URL')\""

  # Detect the new CTID by diffing pct list before vs after.
  local after_ctids new_ctid
  after_ctids="$(_list_ctids)"
  new_ctid="$(comm -13 <(echo "$before_ctids") <(echo "$after_ctids") | head -n1)"

  if [[ -z "$new_ctid" ]]; then
    warn "No new CT detected after $KEY helper. It may have been cancelled in the menu."
    CREATED_CTID=""
    return 1
  fi

  log "  Helper created CT $new_ctid for '$KEY'."

  # Force our preferred hostname (helper's default might be different)
  if [[ "$(pct config "$new_ctid" 2>/dev/null | awk '/^hostname:/ {print $2}')" != "$KEY" ]]; then
    run "pct set $new_ctid --hostname $KEY"
    log "  Renamed CT $new_ctid hostname to '$KEY'."
  fi

  CREATED_CTID="$new_ctid"
}

# Push the PVE host's authorized_keys into a CT.
#
# Why this exists: pct create --ssh-public-keys honors the file natively, so
# pct-created CTs (ollama-pi-agent) get the key automatically. But the
# community helper scripts (sandbox via docker.sh, gitea, openwebui, homepage)
# don't reliably honor the SSH_AUTHORIZED_KEY env var in Default Install mode —
# they were leaving CTs with no workstation key, so `ssh root@sandbox` from the laptop
# would prompt for a password.
#
# This function reads the PVE host's authorized_keys, filters to lines that
# look like real SSH public keys (drops blanks, comments, and stray markdown
# / YAML separators that have crept in during pastes), and appends any
# missing key into the target CT. Idempotent: re-runs skip already-present
# keys via grep -F.
push_pve_keys_to_ct() {
  local ctid="$1"
  if [[ ! -s "$AUTHKEYS_FILE" ]]; then
    warn "  $AUTHKEYS_FILE is empty — nothing to push."
    return
  fi

  # Make sure the target's .ssh dir + authorized_keys exist with correct perms.
  run "pct exec $ctid -- bash -lc 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'"

  local key added=0 skipped_non_key=0 skipped_present=0
  while IFS= read -r key; do
    # Skip blanks and comment lines
    [[ -z "$key" ]] && continue
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    # Skip anything that isn't a recognized OpenSSH public-key line. This
    # filters out the stray '---' / 'your-email@example.com' artifacts that
    # accumulated from earlier paste attempts.
    if [[ ! "$key" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-) ]]; then
      skipped_non_key=$((skipped_non_key + 1))
      continue
    fi

    # Idempotency: skip if already there.
    if (( ! DRY_RUN )) && pct exec "$ctid" -- grep -qF "$key" /root/.ssh/authorized_keys 2>/dev/null; then
      skipped_present=$((skipped_present + 1))
      continue
    fi

    if (( DRY_RUN )); then
      printf "[dry-run] would append key to CT %s: %s\n" "$ctid" "$(echo "$key" | awk '{print $NF}')"
    else
      printf '%s\n' "$key" | pct exec "$ctid" -- tee -a /root/.ssh/authorized_keys > /dev/null
    fi
    added=$((added + 1))
  done < "$AUTHKEYS_FILE"

  log "  [$ctid] PVE-host keys synced: $added added, $skipped_present already present, $skipped_non_key non-key lines filtered out."
}

# ----- 7. Direct Tailscale install inside CT (no addon script) --------------
# The community addon (tools/addon/add-tailscale-lxc.sh) explicitly whiptail-
# prompts for CTID even when we pass it via env, which is unsafe to script.
# We do the same work the addon does, but targeted at the CTID we know.
install_tailscale_in_ct() {
  local CTID="$1"

  # Lookup hostname from the CT itself rather than our static map, since the
  # helper may have created a CT we now know about by its detected ID.
  local HOSTNAME
  HOSTNAME="$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}')"
  HOSTNAME="${HOSTNAME:-ct$CTID}"

  # Skip if already on the tailnet — makes re-runs free.
  if (( ! DRY_RUN )) && ct_on_tailnet "$CTID"; then
    local IP
    IP="$(pct exec "$CTID" -- tailscale ip -4 2>/dev/null | head -n1 || echo '?')"
    log "  CT $CTID ($HOSTNAME) already on tailnet at $IP — skipping Tailscale step."
    return
  fi

  # Guard: never forward a placeholder auth key to tailscale up. If the
  # preflight wrongly skipped the prompt, fail clearly rather than letting
  # Tailscale reject the bogus key and leave the node half-configured.
  if [[ "$TS_AUTHKEY" =~ ^UNUSED_ ]] || [[ "$TS_AUTHKEY" =~ DRY_RUN_PLACEHOLDER ]]; then
    die "CT $CTID ($HOSTNAME) needs Tailscale join but no real auth key was provided.
  Re-run with: TS_AUTHKEY='' /root/bootstrap-pve.sh
or pass it via flag: /root/bootstrap-pve.sh --tsauthkey tskey-auth-..."
  fi

  log "Installing Tailscale in CT $CTID ($HOSTNAME) — direct install."

  # Step 1: Allow /dev/net/tun inside the unprivileged CT (this is the only
  # LXC config change the addon makes).
  local CONF="/etc/pve/lxc/${CTID}.conf"
  if [[ ! -f "$CONF" ]]; then
    warn "  Config file $CONF doesn't exist — was CT $CTID actually created?"
    return 1
  fi
  if ! grep -q "lxc.cgroup2.devices.allow: c 10:200 rwm" "$CONF" 2>/dev/null; then
    run "echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> '$CONF'"
  fi
  if ! grep -q "lxc.mount.entry: /dev/net/tun" "$CONF" 2>/dev/null; then
    run "echo 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >> '$CONF'"
  fi

  # Step 2: Restart CT so the new LXC config takes effect.
  log "  Restarting CT $CTID so /dev/net/tun is mapped..."
  run "pct stop $CTID >/dev/null 2>&1 || true"
  run "sleep 2"
  run "pct start $CTID"
  run "sleep 8"

  # Step 3: Install the tailscale package inside the CT.
  log "  Installing tailscale package..."
  run "pct exec $CTID -- bash -c '
    set -e
    if [ -f /etc/alpine-release ]; then
      ALPINE_VERSION=\$(cat /etc/alpine-release | cut -d. -f1,2)
      grep -q \"^[^#].*community\" /etc/apk/repositories 2>/dev/null \
        || echo \"https://dl-cdn.alpinelinux.org/alpine/v\${ALPINE_VERSION}/community\" >> /etc/apk/repositories
      apk update
      apk add --no-cache tailscale
      rc-update add tailscale default 2>/dev/null || true
      rc-service tailscale start 2>/dev/null || true
    else
      export DEBIAN_FRONTEND=noninteractive
      . /etc/os-release
      if ! command -v curl >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y curl
      fi
      mkdir -p /usr/share/keyrings
      curl -fsSL \"https://pkgs.tailscale.com/stable/\$ID/\$VERSION_CODENAME.noarmor.gpg\" \
        | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
      echo \"deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/\$ID \$VERSION_CODENAME main\" \
        > /etc/apt/sources.list.d/tailscale.list
      apt-get update -qq
      apt-get install -y tailscale
    fi
  '"

  # Step 4: tailscale up with the auth key (idempotent).
  #
  # Note: we intentionally do NOT pass --ssh. Tailscale SSH intercepts
  # connections between tailnet devices and requires per-connection 'check
  # mode' approval (or explicit ACL rules) before letting root in — which
  # breaks the standard-SSHD + authorized_keys trust mesh that
  # setup-ollama-pi.sh builds. By leaving Tailscale SSH off, regular sshd
  # inside each CT handles connections, and our key-based trust works as
  # designed. Trade-off: no Tailscale audit log for SSH; users who want that
  # can flip --ssh back on AND configure their tailnet ACLs to permit
  # 'autogroup:owner' SSH access to these tagged devices.
  log "  tailscale up --authkey ... --hostname $HOSTNAME"
  # --reset clears any prior partial config. Without it, a previous
  # `tailscale up` attempt that failed (e.g., one-time key rejected on the
  # 2nd CT, network blip mid-auth) leaves stale settings that cause the
  # retry to fail with "changing settings requires mentioning all
  # non-default flags". With --reset, every CT starts from a known clean
  # state on each attempt.
  run "pct exec $CTID -- tailscale up --reset --authkey=$TS_AUTHKEY --hostname=$HOSTNAME --accept-routes \
       || pct exec $CTID -- tailscale up --reset --authkey=$TS_AUTHKEY --hostname=$HOSTNAME"

  # Show the 100.x for our final summary.
  run "pct exec $CTID -- tailscale ip -4 || true"
}

# ----- driver ----------------------------------------------------------------
main() {
  log "==> Bootstrap PVE: 5-CT homelab (ollama-pi-agent, sandbox, gitea, openwebui, homepage)"

  configure_repos
  apt_refresh
  install_pve_sshkey
  ensure_template

  # Custom CTs first
  for CTID in "${PCT_CREATE_CTS[@]}"; do
    local KEY="${CT_HOSTNAME[$CTID]}"
    selected_key "$KEY" || { log "Skipping $KEY ($CTID) (not in --only)"; continue; }
    create_pct_ct "$CTID"
    # pct create's --ssh-public-keys flag already injected the host's keys,
    # but pushing again is idempotent and acts as a safety net for re-runs
    # where the user added keys to the PVE host after the CT was created.
    push_pve_keys_to_ct "$CTID"
    install_tailscale_in_ct "$CTID"
  done

  # Helper-script CTs. We treat the CTID in the array as PREFERRED — the
  # community helpers ignore env-var CT_ID overrides, so we let them auto-assign
  # and then pick up the actual CTID via run_helper_script (which sets the
  # global CREATED_CTID).
  for entry in "${HELPER_SCRIPTS[@]}"; do
    IFS='|' read -r CTID KEY URL <<< "$entry"
    selected_key "$KEY" || { log "Skipping $KEY ($CTID) (not in --only)"; continue; }
    CREATED_CTID=""
    run_helper_script "$CTID" "$KEY" "$URL" || { warn "Helper for $KEY failed — skipping."; continue; }
    if [[ -n "$CREATED_CTID" ]]; then
      # Helper CTs need this explicitly — community scripts in Default Install
      # mode skip the SSH_AUTHORIZED_KEY env var entirely.
      push_pve_keys_to_ct "$CREATED_CTID"
      install_tailscale_in_ct "$CREATED_CTID"
    fi
  done

  log "==> Done."
  log "Verify with:  tailscale status   (from any machine on the tailnet)"
  log "Or on PVE:    pct list   &&   for id in 100 200 202 215; do pct exec \$id tailscale ip -4 2>/dev/null; done"
}

main "$@"
