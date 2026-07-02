#!/usr/bin/env bash
# setup-pve-etc-backup.sh — Install a daily systemd timer that captures the
# PVE host's configuration to a compressed tarball on your backup drive.
#
# vzdump backs up your CTs but it does NOT back up /etc/pve (PVE's own config —
# storage definitions, cluster.conf, user db, ACLs), your network config, your
# SSH host keys, or your root authorized_keys. If the host drive dies and you
# only have vzdump backups, you have CT data but a freshly-installed PVE that
# can't even mount the backup drive without redoing the storage definitions.
# This addon closes that gap.
#
# What it backs up (one tarball per run, named pve-etc-YYYYMMDD-HHMMSS.tar.zst):
#
#   /etc/pve                          (cluster + storage + user db — FUSE)
#   /var/lib/pve-cluster/config.db    (the sqlite DB behind /etc/pve)
#   /etc/network/interfaces           (vmbr0, bonds, VLANs)
#   /etc/network/interfaces.d/        (any drop-ins)
#   /etc/hosts, /etc/hostname, /etc/resolv.conf
#   /etc/ssh/ssh_host_*_key           (host keys — preserve fingerprints on rebuild)
#   /etc/ssh/sshd_config              (allowed users, ports, etc.)
#   /root/.ssh/                       (authorized_keys + any keys you put there)
#   /etc/apt/sources.list             (legacy)
#   /etc/apt/sources.list.d/          (deb822 .sources we wrote in bootstrap)
#
# Safety: the script `mountpoint -q`s the backup directory before doing
# anything. If the USB drive is unplugged the run exits 0 with a log line —
# we never write a tarball into the host's root filesystem by accident.
#
# Usage:
#   ./setup-pve-etc-backup.sh                         # default: /mnt/pve-backup/etc-snapshots, keep 14, 01:30 daily
#   ./setup-pve-etc-backup.sh --backup-dir /mnt/other-backup/etc-snapshots
#   ./setup-pve-etc-backup.sh --keep 30 --time 03:00
#
# Optional flags:
#   --backup-dir PATH  Where tarballs land (default: /mnt/pve-backup/etc-snapshots)
#   --keep N           How many tarballs to retain (default: 14)
#   --time HH:MM       Daily run time (default: 01:30 — half an hour before
#                                       a typical 02:00 vzdump schedule, so
#                                       config snapshot precedes CT backup)
#   --run-now          Trigger one immediate run after installing the timer
#   --dry-run          Preview commands

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
BACKUP_DIR="/mnt/pve-backup/etc-snapshots"
KEEP=14
RUN_TIME="01:30"
RUN_NOW=0
DRY_RUN=0

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    --keep)       KEEP="$2"; shift 2 ;;
    --time)       RUN_TIME="$2"; shift 2 ;;
    --run-now)    RUN_NOW=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

log()  { printf "\n\033[1;36m[setup-pve-etc-backup]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-pve-etc-backup]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-pve-etc-backup]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pveversion >/dev/null || warn "pveversion not found — are you sure this is a PVE host?"

# Validate time format (HH:MM, 24h)
if ! [[ "$RUN_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  die "--time must be HH:MM in 24h format (got: '$RUN_TIME')."
fi

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || (( KEEP < 1 )); then
  die "--keep must be a positive integer (got: '$KEEP')."
fi

log "Backup directory: $BACKUP_DIR"
log "Retention:        $KEEP snapshots"
log "Daily run time:   $RUN_TIME"

# ----- install the backup script itself -------------------------------------
# We write a standalone script the systemd unit invokes, rather than putting
# all logic in ExecStart=. Easier to test by hand (`pve-etc-backup`) and easier
# to read in journalctl.
log "Writing /usr/local/sbin/pve-etc-backup..."
run "cat > /usr/local/sbin/pve-etc-backup <<'BACKUP_SCRIPT'
#!/usr/bin/env bash
# pve-etc-backup — capture PVE host config to a compressed tarball.
# Managed by setup-pve-etc-backup.sh — re-running that script overwrites this.
set -Eeuo pipefail

BACKUP_DIR=\"\${BACKUP_DIR:-$BACKUP_DIR}\"
KEEP=\"\${KEEP:-$KEEP}\"

log() { printf '[pve-etc-backup] %s\n' \"\$*\"; }

# Bail out cleanly if the backup volume isn't mounted — never write into the
# root filesystem by accident. The systemd unit treats exit 0 as 'fine,
# nothing to do', so an unmounted USB drive shows as a clean skip in
# journalctl rather than a failure that pages you.
if ! mountpoint -q \"\$(dirname \"\$BACKUP_DIR\")\" 2>/dev/null && \\
   ! mountpoint -q \"\$BACKUP_DIR\" 2>/dev/null; then
  log \"Backup volume not mounted at parent of \$BACKUP_DIR — skipping.\"
  exit 0
fi

mkdir -p \"\$BACKUP_DIR\"

stamp=\"\$(date +%Y%m%d-%H%M%S)\"
host=\"\$(hostname -s)\"
tarball=\"\$BACKUP_DIR/pve-etc-\$host-\$stamp.tar.zst\"

# Paths to capture. Some may not exist on every host (e.g. no
# /etc/network/interfaces.d) — tar -P with --ignore-failed-read tolerates that.
PATHS=(
  /etc/pve
  /var/lib/pve-cluster/config.db
  /etc/network/interfaces
  /etc/network/interfaces.d
  /etc/hosts
  /etc/hostname
  /etc/resolv.conf
  /etc/ssh/sshd_config
  /etc/apt/sources.list
  /etc/apt/sources.list.d
  /root/.ssh
)
# Host SSH keys — globbing because filenames vary by algo.
for k in /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub; do
  [[ -e \"\$k\" ]] && PATHS+=(\"\$k\")
done

# Filter to existing paths (tar warns about missing ones; we'd rather skip).
EXISTING=()
for p in \"\${PATHS[@]}\"; do
  [[ -e \"\$p\" ]] && EXISTING+=(\"\$p\")
done

if [[ \${#EXISTING[@]} -eq 0 ]]; then
  log \"No paths to back up — exiting.\"
  exit 0
fi

log \"Writing tarball: \$tarball\"
# zstd is what vzdump uses by default — same trade-off (fast + small).
# --ignore-failed-read so a transient permission glitch on one file doesn't
# kill the whole snapshot.
tar --zstd \\
    --ignore-failed-read \\
    --warning=no-file-changed \\
    -cf \"\$tarball\" \\
    \"\${EXISTING[@]}\" 2>&1 | grep -v '^tar:' || true

if [[ ! -s \"\$tarball\" ]]; then
  log \"Tarball is empty or missing — something went wrong.\"
  rm -f \"\$tarball\"
  exit 1
fi

size=\"\$(du -h \"\$tarball\" | awk '{print \$1}')\"
log \"Wrote \$size to \$tarball\"

# Retention — delete oldest tarballs beyond \$KEEP for THIS host. We scope by
# hostname so a multi-host cluster doesn't have nodes deleting each other's
# snapshots if they share a backup directory.
log \"Pruning to last \$KEEP snapshots for \$host...\"
mapfile -t old < <(
  ls -1t \"\$BACKUP_DIR\"/pve-etc-\"\$host\"-*.tar.zst 2>/dev/null | tail -n +\$((KEEP + 1))
)
for f in \"\${old[@]}\"; do
  log \"  removing \$(basename \"\$f\")\"
  rm -f \"\$f\"
done

log \"Done.\"
BACKUP_SCRIPT"
run "chmod 0750 /usr/local/sbin/pve-etc-backup"

# ----- systemd service + timer ---------------------------------------------
log "Writing /etc/systemd/system/pve-etc-backup.service..."
run "cat > /etc/systemd/system/pve-etc-backup.service <<'UNIT'
[Unit]
Description=Snapshot /etc/pve and host config to backup volume
# We don't have a hard dependency on the mount unit because the script
# checks mountpoint itself and exits cleanly if the drive isn't there —
# that way a missing drive shows as 'skipped' in the log rather than a
# unit-level failure.

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-etc-backup
# Lock down a little — this only needs to read host config and write to
# the backup directory.
ProtectHome=true
NoNewPrivileges=true
UNIT"

log "Writing /etc/systemd/system/pve-etc-backup.timer..."
run "cat > /etc/systemd/system/pve-etc-backup.timer <<UNIT
[Unit]
Description=Daily PVE host config snapshot

[Timer]
# OnCalendar uses HH:MM:SS, but we accept HH:MM and append :00 here.
OnCalendar=*-*-* $RUN_TIME:00
# If the system was off at the scheduled time, run as soon as it comes back.
Persistent=true
# Small randomized delay so a fleet of hosts doesn't all hit the backup
# drive at the same second.
RandomizedDelaySec=120
Unit=pve-etc-backup.service

[Install]
WantedBy=timers.target
UNIT"

run "systemctl daemon-reload"
run "systemctl enable pve-etc-backup.timer"
run "systemctl restart pve-etc-backup.timer"

# ----- optional immediate run -----------------------------------------------
if (( RUN_NOW )); then
  log "Triggering a one-off run now (--run-now)..."
  run "systemctl start pve-etc-backup.service"
  # Tail the unit's output briefly so the user sees it succeeded or skipped.
  sleep 2
  run "journalctl -u pve-etc-backup.service -n 20 --no-pager"
fi

# ----- verify ---------------------------------------------------------------
if (( ! DRY_RUN )); then
  log "Timer status:"
  systemctl list-timers pve-etc-backup.timer --no-pager || true
fi

log "==> Done."
log " "
log "  Next backup:   $RUN_TIME daily"
log "  Tarballs in:   $BACKUP_DIR/  (named pve-etc-<host>-<stamp>.tar.zst)"
log "  Retention:     last $KEEP snapshots per host"
log "  Run manually:  systemctl start pve-etc-backup.service"
log "                 (or just: pve-etc-backup)"
log "  Logs:          journalctl -u pve-etc-backup.service"
