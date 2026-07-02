#!/usr/bin/env bash
# setup-smb-share.sh — Install Samba on one or more pi agent CTs and expose
# /root as a network share so you can mount it from macOS / Windows / Linux
# directly (smb://hostname/home), rather than scp/sftp/rsync gymnastics.
#
# Typical use:
#   - macOS: Finder → Cmd-K → smb://ollama-pi-agent → connect as 'root'
#   - Windows: Run → \\ollama-pi-agent\home
#   - Linux: gio mount smb://ollama-pi-agent/home  OR  mount.cifs //ollama-pi-agent/home /mnt/foo -o username=root
#
# Auth: a Samba user named 'root' with a password (provided via --password
# or prompted). Files on disk stay owned by root regardless of what name
# the client logs in as — the SMB user maps to root at the filesystem layer.
#
# Bind scope: smbd listens on all interfaces inside the CT. Combined with
# Tailscale + LAN reachability, the share is mountable from any device on
# either network. Inside the tailnet you get hostname-based access
# (smb://ollama-pi-agent); on the LAN you'd use the CT's LAN IP.
#
# Usage:
#   ./setup-smb-share.sh                                # default: install on ollama-pi-agent
#   ./setup-smb-share.sh --target pi-agent-2            # different agent
#   ./setup-smb-share.sh --target ollama-pi-agent --target pi-agent-2   # multiple at once
#   ./setup-smb-share.sh --password 'devpass'           # skip the password prompt
#   ./setup-smb-share.sh --share-path /root/uploads --share-name uploads  # different share
#
# Optional flags:
#   --target NAME       Hostname to install on (repeatable, default: ollama-pi-agent)
#   --hostname NAME     Back-compat alias for --target
#   --ct-id N           Target a CT by ID instead (only valid with one --target)
#   --share-name NAME   SMB share name (default: home — mount with smb://host/home)
#   --share-path PATH   Filesystem path the share exposes (default: /root)
#   --password PW       SMB password for the 'root' user (default: prompted)
#   --workgroup NAME    SMB workgroup (default: WORKGROUP)
#   --dry-run           Preview commands without executing

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
declare -a TARGETS=()
TARGET_CTID=""
SHARE_NAME="home"
SHARE_PATH="/root"
SMB_PASSWORD=""
WORKGROUP="WORKGROUP"
DRY_RUN=0

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target|--hostname) TARGETS+=("$2"); shift 2 ;;
    --ct-id)             TARGET_CTID="$2"; shift 2 ;;
    --share-name)        SHARE_NAME="$2"; shift 2 ;;
    --share-path)        SHARE_PATH="$2"; shift 2 ;;
    --password)          SMB_PASSWORD="$2"; shift 2 ;;
    --workgroup)         WORKGROUP="$2"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Default target list = ollama-pi-agent (the original pi host from
# bootstrap-pve.sh). When called from setup-new-pi-agent.sh, --target is
# passed explicitly so this default isn't used.
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=("ollama-pi-agent")
fi

if [[ -n "$TARGET_CTID" && ${#TARGETS[@]} -gt 1 ]]; then
  echo "--ct-id can only be used with a single --target." >&2
  exit 2
fi

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-smb-share]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-smb-share]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-smb-share]\033[0m %s\n" "$*" >&2; exit 1; }
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

# ----- resolve SMB password (once, shared across all targets) ---------------
# We use one password for all targets in a single invocation. If you want
# distinct passwords per agent, run the script once per --target.
if [[ -z "$SMB_PASSWORD" ]]; then
  if (( DRY_RUN )); then
    SMB_PASSWORD="dryrun-placeholder-pw"
    log "Dry-run: using placeholder password."
  else
    printf "\n\033[1;36m[setup-smb-share]\033[0m SMB password for user 'root' (hidden; min 6 chars): " >&2
    IFS= read -rs pw1; echo >&2
    printf "Confirm: " >&2
    IFS= read -rs pw2; echo >&2
    [[ "$pw1" == "$pw2" ]] || die "Passwords didn't match."
    [[ ${#pw1} -ge 6    ]] || die "Password too short (need >= 6 chars)."
    SMB_PASSWORD="$pw1"
  fi
fi

# ----- resolve targets up front so we fail fast if any missing -------------
declare -a RESOLVED_HOSTNAMES=() RESOLVED_CTIDS=()
for hn in "${TARGETS[@]}"; do
  ctid="$TARGET_CTID"
  if [[ -z "$ctid" ]]; then
    ctid="$(find_ct_by_hostname "$hn" 2>/dev/null || true)"
  fi
  [[ -n "$ctid" ]] || die "Couldn't find a CT with hostname '$hn'. Pass --ct-id <n> if it's named differently."
  pct status "$ctid" 2>/dev/null | grep -q "status: running" \
    || die "CT $ctid ($hn) is not running."
  RESOLVED_HOSTNAMES+=("$hn")
  RESOLVED_CTIDS+=("$ctid")
done

log "Planned install on: ${RESOLVED_HOSTNAMES[*]}"
log "  Share name:    $SHARE_NAME"
log "  Share path:    $SHARE_PATH"
log "  Workgroup:     $WORKGROUP"

# ----- per-target install logic --------------------------------------------
install_on_target() {
  local target_hostname="$1"
  local target_ctid="$2"

  log "================================================================"
  log "Target: $target_hostname (CT $target_ctid)"
  log "================================================================"

  # 1. install samba (idempotent — apt-get is a no-op if installed)
  if pct exec "$target_ctid" -- bash -lc 'command -v smbd' >/dev/null 2>&1; then
    log "Samba already installed on $target_hostname."
  else
    log "Installing Samba on $target_hostname..."
    # DEBIAN_FRONTEND=noninteractive avoids the smb.conf 'do you want to
    # configure now' prompt that the Debian samba package fires.
    run "pct exec $target_ctid -- bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq samba'"
  fi

  # 2. ensure the share path exists
  log "Ensuring share path exists: $SHARE_PATH"
  run "pct exec $target_ctid -- mkdir -p '$SHARE_PATH'"

  # 3. write our managed block into /etc/samba/smb.conf
  # We use marker comments so re-runs replace our block surgically. If the
  # user has hand-edits elsewhere in smb.conf, they survive.
  local marker_start="# TD-SMB-SHARE: $SHARE_NAME START"
  local marker_end="# TD-SMB-SHARE: $SHARE_NAME END"

  log "Writing share definition to /etc/samba/smb.conf..."
  run "pct exec $target_ctid -- bash -lc '
    cd /etc/samba
    # Strip any prior block we wrote, surgically (awk between markers)
    if grep -qF \"$marker_start\" smb.conf; then
      awk -v s=\"$marker_start\" -v e=\"$marker_end\" \"
        \\\$0 ~ s { in_block=1; next }
        in_block && \\\$0 ~ e { in_block=0; next }
        !in_block { print }
      \" smb.conf > smb.conf.new && mv smb.conf.new smb.conf
    fi

    # Append our fresh block.
    cat >> smb.conf <<SHARE
$marker_start
[$SHARE_NAME]
   comment = pi agent home directory ($target_hostname:$SHARE_PATH)
   path = $SHARE_PATH
   browseable = yes
   read only = no
   guest ok = no
   valid users = root
   create mask = 0644
   directory mask = 0755
   force user = root
   force group = root
   # macOS Finder compatibility — hides ._ resource forks, handles .DS_Store
   # quietly, and surfaces extended attributes the way macOS expects.
   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:resource = file
   fruit:posix_rename = yes
$marker_end
SHARE
  '"

  # Also tweak [global] workgroup to whatever we want (idempotent — only
  # write if different from current).
  run "pct exec $target_ctid -- bash -lc '
    current=\$(awk -F= \"/^[[:space:]]*workgroup[[:space:]]*=/{print \\\$2}\" /etc/samba/smb.conf | head -1 | tr -d \" \")
    if [[ \"\$current\" != \"$WORKGROUP\" ]]; then
      sed -i \"s/^[[:space:]]*workgroup[[:space:]]*=.*/   workgroup = $WORKGROUP/\" /etc/samba/smb.conf
    fi
  '"

  # 4. validate smb.conf before restart (testparm catches typos)
  log "Validating smb.conf..."
  run "pct exec $target_ctid -- bash -lc 'testparm -s /etc/samba/smb.conf >/dev/null 2>&1' || true"

  # 5. set Samba password for the 'root' user.
  # smbpasswd manages an independent password database (tdbsam by default).
  # The Samba 'root' user maps to the system root UID for filesystem ops.
  # -a adds the user; -s reads from stdin; if the user already exists, -a
  # just resets the password (idempotent).
  log "Setting SMB password for 'root' user..."
  run "pct exec $target_ctid -- bash -lc 'printf \"%s\\n%s\\n\" \"$SMB_PASSWORD\" \"$SMB_PASSWORD\" | smbpasswd -a -s root >/dev/null'"

  # 6. enable + restart so config changes take effect.
  # We restart (not start) because the package install may have started
  # smbd with the default config; we need it to pick up our block.
  log "Enabling and restarting smbd/nmbd..."
  run "pct exec $target_ctid -- systemctl enable smbd nmbd 2>/dev/null || true"
  run "pct exec $target_ctid -- systemctl restart smbd"
  run "pct exec $target_ctid -- systemctl restart nmbd"

  # 7. verify the daemon is listening on 445.
  if (( ! DRY_RUN )); then
    sleep 1
    if pct exec "$target_ctid" -- bash -lc "exec 3<>/dev/tcp/127.0.0.1/445" 2>/dev/null; then
      log "smbd is listening on $target_hostname:445"
    else
      warn "smbd isn't responding on $target_hostname:445 — check 'pct exec $target_ctid -- journalctl -u smbd --no-pager | tail -20'"
    fi
  fi
}

# ----- install on each target ----------------------------------------------
for i in "${!RESOLVED_HOSTNAMES[@]}"; do
  install_on_target "${RESOLVED_HOSTNAMES[$i]}" "${RESOLVED_CTIDS[$i]}"
done

# ----- done ---------------------------------------------------------------
log "================================================================"
log "==> Done."
log " "
for i in "${!RESOLVED_HOSTNAMES[@]}"; do
  hn="${RESOLVED_HOSTNAMES[$i]}"
  log "  $hn:"
  log "    macOS Finder:  Cmd-K → smb://$hn/$SHARE_NAME → connect as 'root'"
  log "    Windows:       Run → \\\\$hn\\$SHARE_NAME"
  log "    Linux (gvfs):  gio mount smb://$hn/$SHARE_NAME"
  log "    Linux (cifs):  mount.cifs //$hn/$SHARE_NAME /mnt/foo -o username=root"
done
log " "
log "  Username:  root"
log "  Password:  (the one you just set)"
log "  Files on disk are owned by root regardless of which client mounts them."
