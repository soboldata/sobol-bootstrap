#!/usr/bin/env bash
# setup-usb-backup.sh — Prep a USB drive as a PVE backup target
#
# Does the full one-time USB setup so vzdump has somewhere off-host to write:
#   1. Enumerates USB drives currently plugged in
#   2. Asks you to confirm WHICH drive to wipe (multi-confirmation)
#   3. Partitions GPT + creates a single ext4 partition labeled "pve-backup"
#   4. Adds a persistent /etc/fstab mount at /mnt/pve-backup
#   5. Registers the mount as a PVE storage named "usb-backup" (content: backup)
#   6. Tests by writing + reading a file
#   7. Suggests the next command (setup-vzdump-schedule.sh --storage usb-backup)
#
# SAFETY:
#   - Never targets the PVE boot disk (/dev/sda or whichever has the PVE root LVM)
#   - Requires TRAN=usb at the kernel layer (won't see internal SATA drives)
#   - Requires you to confirm the device name + size + serial before formatting
#   - Honors --dry-run (no destructive ops)
#
# Usage:
#   ./setup-usb-backup.sh                  # interactive
#   ./setup-usb-backup.sh --dry-run        # preview
#   ./setup-usb-backup.sh --device /dev/sdX  # skip enumeration, target this one
#   ./setup-usb-backup.sh --uninstall      # unmount + remove pvesm storage + fstab line
#   ./setup-usb-backup.sh --label NAME     # filesystem label (default: pve-backup)
#   ./setup-usb-backup.sh --mount /mnt/X   # mount path (default: /mnt/pve-backup)
#   ./setup-usb-backup.sh --storage NAME   # PVE storage name (default: usb-backup)

set -Eeuo pipefail

DRY_RUN=0
UNINSTALL=0
DEVICE=""
FS_LABEL="pve-backup"
MOUNT_PATH="/mnt/pve-backup"
PVE_STORAGE_NAME="usb-backup"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --device)     DEVICE="$2"; shift 2 ;;
    --label)      FS_LABEL="$2"; shift 2 ;;
    --mount)      MOUNT_PATH="$2"; shift 2 ;;
    --storage)    PVE_STORAGE_NAME="$2"; shift 2 ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

log()  { printf "\n\033[1;36m[usb-backup]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[usb-backup]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[usb-backup]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v lsblk >/dev/null || die "lsblk required."
command -v pvesm >/dev/null || die "pvesm required (PVE host)."

# PVE ships without parted by default; e2fsprogs is usually present but check
# anyway. Both are tiny — auto-install idempotently. Same pattern setup-pve-email.sh
# uses for libsasl2-modules.
NEED_APT=()
command -v parted    >/dev/null || NEED_APT+=(parted)
command -v mkfs.ext4 >/dev/null || NEED_APT+=(e2fsprogs)
if (( ${#NEED_APT[@]} > 0 )); then
  log "Installing missing tools: ${NEED_APT[*]}"
  if (( ! DRY_RUN )); then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${NEED_APT[@]}" >/dev/null 2>&1 \
      || die "Failed to install: ${NEED_APT[*]}. Run 'apt update && apt install ${NEED_APT[*]}' manually."
  fi
fi

# ----- uninstall path ---------------------------------------------------
if (( UNINSTALL )); then
  log "Uninstalling: removing PVE storage + fstab line + unmounting..."

  if pvesm status | grep -q "^${PVE_STORAGE_NAME}"; then
    run "pvesm remove '${PVE_STORAGE_NAME}'"
  fi

  if mountpoint -q "$MOUNT_PATH"; then
    run "umount '$MOUNT_PATH'"
  fi

  if grep -q " $MOUNT_PATH " /etc/fstab; then
    run "sed -i '\\| $MOUNT_PATH |d' /etc/fstab"
  fi

  log "Uninstalled. USB device + filesystem still present — manually wipe if you want to repurpose:"
  log "  wipefs --all $DEVICE  (only if you remember which device)"
  exit 0
fi

# ----- 1. enumerate USB drives -----------------------------------------
log "Enumerating USB drives..."

if [[ -z "$DEVICE" ]]; then
  # List all USB block devices, exclude partitions
  USB_DEVS=$(lsblk -dpno NAME,SIZE,MODEL,TRAN | awk '$NF=="usb" {print $1, $2, $3, $4, $5, $6, $7}')
  if [[ -z "$USB_DEVS" ]]; then
    die "No USB drives detected. Plug one in and re-run, or specify --device /dev/sdX."
  fi

  echo
  echo "  Detected USB drives:"
  echo "  ----------------------------------------"
  echo "$USB_DEVS" | nl -ba | sed 's/^/   /'
  echo

  # If only one, use it
  USB_COUNT=$(echo "$USB_DEVS" | wc -l)
  if (( USB_COUNT == 1 )); then
    DEVICE=$(echo "$USB_DEVS" | awk '{print $1}')
    log "Only one USB drive found — auto-selecting $DEVICE"
  else
    printf "  Select drive [1-%d]: " "$USB_COUNT" >&2
    IFS= read -r choice
    DEVICE=$(echo "$USB_DEVS" | sed -n "${choice}p" | awk '{print $1}')
    [[ -n "$DEVICE" ]] || die "Invalid selection."
  fi
fi

# ----- 2. safety checks -------------------------------------------------
[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device."

# Refuse to wipe the PVE boot disk
PVE_BOOT_DEV=$(findmnt -no SOURCE / 2>/dev/null | sed 's/[0-9]*$//')
if [[ "$DEVICE" == "$PVE_BOOT_DEV" ]] || lsblk -no PKNAME "$PVE_BOOT_DEV" 2>/dev/null | grep -q "^$(basename $DEVICE)$"; then
  die "$DEVICE looks like the PVE boot disk. Refusing to wipe. Specify --device explicitly if you're sure."
fi

# Refuse if the device's TRAN isn't usb (in case --device override)
TRAN=$(lsblk -dno TRAN "$DEVICE" 2>/dev/null)
if [[ "$TRAN" != "usb" ]]; then
  warn "$DEVICE has TRAN=$TRAN, not 'usb'. Are you sure this is the right drive?"
  printf "  Type the device path again to confirm: " >&2
  IFS= read -r confirm
  [[ "$confirm" == "$DEVICE" ]] || die "Mismatch. Aborting."
fi

# Show what's on the drive now
log "Pre-wipe inventory of $DEVICE:"
lsblk -fp "$DEVICE" | sed 's/^/  /'
SIZE=$(lsblk -dno SIZE "$DEVICE")
MODEL=$(lsblk -dno MODEL "$DEVICE")
SERIAL=$(lsblk -dno SERIAL "$DEVICE" 2>/dev/null || echo "?")
log "  Size: $SIZE"
log "  Model: $MODEL"
log "  Serial: $SERIAL"

# Final confirmation
echo
echo "  ⚠ THIS WILL DESTROY ALL DATA ON $DEVICE."
printf "  Type 'WIPE' (uppercase) to proceed: " >&2
IFS= read -r confirm
[[ "$confirm" == "WIPE" ]] || die "Confirmation not received. Aborting."

# ----- 3. unmount anything currently mounted from this device ----------
log "Unmounting any current partitions on $DEVICE..."
for part in $(lsblk -lnpo NAME "$DEVICE" | tail -n +2); do
  if mountpoint -q "$(findmnt -no TARGET "$part" 2>/dev/null)" 2>/dev/null; then
    run "umount '$part'"
  fi
  # Remove existing fstab entries
  if grep -q "^[^#].*${part}" /etc/fstab 2>/dev/null; then
    run "sed -i \"\\|${part}|d\" /etc/fstab"
  fi
done

# ----- 4. partition + format -------------------------------------------
log "Wiping + repartitioning $DEVICE..."
run "wipefs --all '$DEVICE'"
run "parted '$DEVICE' mklabel gpt --script"
run "parted '$DEVICE' mkpart primary ext4 0% 100% --script"
sleep 1
run "partprobe '$DEVICE' 2>/dev/null || true"
sleep 1

# Figure out the partition name (sda → sda1, nvme0n1 → nvme0n1p1)
if [[ "$DEVICE" =~ nvme ]]; then
  PARTITION="${DEVICE}p1"
else
  PARTITION="${DEVICE}1"
fi

log "Formatting $PARTITION as ext4 with label '$FS_LABEL'..."
run "mkfs.ext4 -L '$FS_LABEL' -F '$PARTITION'"
sleep 1

# ----- 5. mount persistently -------------------------------------------
log "Mounting at $MOUNT_PATH and adding to /etc/fstab..."
run "mkdir -p '$MOUNT_PATH'"

UUID=$(blkid -s UUID -o value "$PARTITION")
[[ -n "$UUID" ]] || die "Couldn't get UUID for $PARTITION."

# Strip any prior fstab entry for this mount path
if grep -q " $MOUNT_PATH " /etc/fstab; then
  run "sed -i '\\| $MOUNT_PATH |d' /etc/fstab"
fi

if (( ! DRY_RUN )); then
  echo "UUID=$UUID  $MOUNT_PATH  ext4  defaults,nofail,x-systemd.device-timeout=10s  0  2" >> /etc/fstab
  systemctl daemon-reload  # so it notices fstab change
fi
run "mount '$MOUNT_PATH'"

mountpoint -q "$MOUNT_PATH" 2>/dev/null || die "Mount failed. Check 'dmesg | tail' and 'cat /etc/fstab'."

log "  ✓ Mounted: $(df -h $MOUNT_PATH | tail -1)"

# ----- 6. register as PVE storage -------------------------------------
log "Registering as PVE storage '$PVE_STORAGE_NAME'..."

# Remove existing definition if present
if pvesm status 2>/dev/null | grep -q "^${PVE_STORAGE_NAME}"; then
  warn "  PVE storage '$PVE_STORAGE_NAME' already exists — removing + re-adding"
  run "pvesm remove '$PVE_STORAGE_NAME'"
fi

run "pvesm add dir '$PVE_STORAGE_NAME' --path '$MOUNT_PATH' --content backup,iso,snippets --prune-backups 'keep-daily=7,keep-weekly=2'"

# ----- 7. smoke test --------------------------------------------------
log "Smoke test: writing + reading a sentinel file..."

if (( ! DRY_RUN )); then
  echo "td-proxmox usb-backup ready $(date)" > "$MOUNT_PATH/.usb-backup-ready"
  if [[ ! -f "$MOUNT_PATH/.usb-backup-ready" ]]; then
    die "Couldn't write to $MOUNT_PATH — check permissions / mount."
  fi
  log "  ✓ Wrote $MOUNT_PATH/.usb-backup-ready"
fi

# ----- summary --------------------------------------------------------
log "================================================================"
log "==> USB backup target ready."
log " "
log "  Device:        $DEVICE"
log "  Partition:     $PARTITION"
log "  Filesystem:    ext4 (label: $FS_LABEL)"
log "  Mount path:    $MOUNT_PATH"
log "  PVE storage:   $PVE_STORAGE_NAME (content: backup, iso, snippets)"
log "  Retention:     keep-daily=7, keep-weekly=2 (pvesm prune policy)"
log " "
log "Next: schedule the actual vzdump job"
log " "
log "  ./addons/setup-vzdump-schedule.sh --storage $PVE_STORAGE_NAME"
log " "
log "Or run a manual full-stack backup now to test (5-15 min depending on CT count + size):"
log " "
log "  vzdump --all --mode snapshot --compress zstd --storage $PVE_STORAGE_NAME"
log " "
log "Verify:"
log "  pvesm status                           # see new storage + free space"
log "  ls -la $MOUNT_PATH/dump/                # backup files land here"
log "  mountpoint $MOUNT_PATH                 # confirm mounted"
log "  cat /etc/fstab | grep $MOUNT_PATH      # persistent across reboots"
log " "
log "If the USB ever gets unplugged:"
log "  nofail option means PVE boot doesn't hang, but backups will fail"
log "  silently. The watchdog will catch this within an hour (VZDUMP_STALE)."
log " "
log "Uninstall (removes mount + PVE storage; doesn't wipe data):"
log "  $(basename "$0") --uninstall"
log "================================================================"
