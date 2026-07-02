#!/usr/bin/env bash
# setup-vzdump-schedule.sh — Install (or update, or remove) a nightly vzdump
# job that backs up every CT to your backup storage.
#
# Companion to setup-pve-etc-backup.sh: that addon snapshots PVE's own host
# config (/etc/pve, network, SSH keys, apt); this addon schedules CT data
# backups via vzdump. Together they cover the full restore picture.
#
# This writes a stanza into /etc/pve/jobs.cfg (PVE's cluster-managed job
# config). PVE picks up changes automatically — no daemon restart needed.
#
# Idempotent: a TD-managed job-id (`td-nightly` by default) means re-running
# this script replaces the existing block rather than appending a duplicate.
# Use --uninstall to remove it entirely.
#
# Usage:
#   ./setup-vzdump-schedule.sh                  # 02:00 nightly, snapshot, zstd
#   ./setup-vzdump-schedule.sh --run-now        # also fire one immediate backup
#   ./setup-vzdump-schedule.sh --mailto you@example.com
#   ./setup-vzdump-schedule.sh --uninstall      # remove the scheduled job
#
# Optional flags:
#   --job-id ID         Unique job identifier (default: td-nightly)
#   --storage NAME      Backup storage (default: pve-backup)
#   --schedule HH:MM    Daily run time (default: 02:00 — 30 min after the
#                                       config-backup timer's 01:30 default)
#   --compress KIND     zstd|gzip|lzo|none (default: zstd)
#   --mode KIND         snapshot|suspend|stop (default: snapshot)
#   --retention SPEC    PVE retention spec (default:
#                       'keep-daily=7,keep-weekly=4,keep-monthly=2')
#   --include SPEC      'all' | 'pool:<name>' | comma-separated CT IDs
#                       (default: 'all')
#   --mailto EMAIL      Where to send notifications (default: none)
#   --notify-mode MODE  always|failure (default: failure)
#   --run-now           Trigger one immediate backup after installing the job
#   --uninstall         Remove the job stanza from jobs.cfg
#   --dry-run           Preview commands

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
JOB_ID="td-nightly"
STORAGE="pve-backup"
SCHEDULE="02:00"
COMPRESS="zstd"
MODE="snapshot"
RETENTION="keep-daily=7,keep-weekly=4,keep-monthly=2"
INCLUDE="all"
MAILTO=""
NOTIFY_MODE="failure"
RUN_NOW=0
UNINSTALL=0
DRY_RUN=0

JOBS_FILE="/etc/pve/jobs.cfg"

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-id)      JOB_ID="$2"; shift 2 ;;
    --storage)     STORAGE="$2"; shift 2 ;;
    --schedule)    SCHEDULE="$2"; shift 2 ;;
    --compress)    COMPRESS="$2"; shift 2 ;;
    --mode)        MODE="$2"; shift 2 ;;
    --retention)   RETENTION="$2"; shift 2 ;;
    --include)     INCLUDE="$2"; shift 2 ;;
    --mailto)      MAILTO="$2"; shift 2 ;;
    --notify-mode) NOTIFY_MODE="$2"; shift 2 ;;
    --run-now)     RUN_NOW=1; shift ;;
    --uninstall)   UNINSTALL=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-vzdump-schedule]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-vzdump-schedule]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-vzdump-schedule]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v vzdump >/dev/null || die "vzdump not found — is this a PVE host?"

# Validate schedule format (HH:MM, 24h)
if ! [[ "$SCHEDULE" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  die "--schedule must be HH:MM in 24h format (got: '$SCHEDULE')."
fi

# Validate compress / mode
case "$COMPRESS" in zstd|gzip|lzo|none) ;; *) die "--compress must be zstd|gzip|lzo|none (got: '$COMPRESS').";; esac
case "$MODE" in snapshot|suspend|stop) ;; *) die "--mode must be snapshot|suspend|stop (got: '$MODE').";; esac

# ----- uninstall path -------------------------------------------------------
remove_job_block() {
  if [[ ! -f "$JOBS_FILE" ]]; then
    log "$JOBS_FILE doesn't exist — nothing to remove."
    return
  fi
  if ! grep -qE "^vzdump: ${JOB_ID}[[:space:]]*$" "$JOBS_FILE"; then
    log "No vzdump job '${JOB_ID}' in $JOBS_FILE — nothing to remove."
    return
  fi
  log "Removing existing vzdump:${JOB_ID} stanza from $JOBS_FILE..."
  # awk: skip the header line and all subsequent indented lines (the stanza
  # body). Resume printing on the next non-indented line (next stanza or EOF).
  run "awk -v jid='${JOB_ID}' '
    BEGIN { in_block = 0 }
    \$0 ~ \"^vzdump: \" jid \"[[:space:]]*\$\" { in_block = 1; next }
    in_block && /^[^[:space:]]/ { in_block = 0 }
    !in_block { print }
  ' '$JOBS_FILE' > '${JOBS_FILE}.new' && mv '${JOBS_FILE}.new' '$JOBS_FILE'"
}

if (( UNINSTALL )); then
  remove_job_block
  log "==> Removed. PVE will pick up the change immediately."
  exit 0
fi

# ----- pre-flight: storage exists, has 'backup' content -------------------
# NOTE: there is no `pvesm config <name>` subcommand on PVE 8/9 — the
# supported way to ask "does this storage support content type X?" is
# `pvesm status --content backup`, which only lists storages that include
# 'backup' in their content types. Fall back to reading /etc/pve/storage.cfg
# directly if pvesm status doesn't accept --content for any reason.
if (( ! DRY_RUN )); then
  if ! pvesm status 2>/dev/null | awk -v s="$STORAGE" 'NR>1 && $1==s {found=1} END {exit !found}'; then
    warn "Storage '$STORAGE' isn't registered yet. Run setup-usb-backup.sh"
    warn "first (or setup-pve-etc-backup.sh's USB walkthrough), or pass"
    warn "--storage <existing-name>."
    die "Aborting before writing job config."
  fi

  # Primary check: pvesm status --content backup lists only storages that
  # advertise backup. If our storage shows up there, we're good.
  if pvesm status --content backup 2>/dev/null \
       | awk -v s="$STORAGE" 'NR>1 && $1==s {found=1} END {exit !found}'; then
    : # storage supports backup — proceed
  else
    # Fallback: read /etc/pve/storage.cfg directly — handles the case where
    # pvesm status --content isn't behaving as expected.
    content_line=$(awk -v s="$STORAGE" '
      $0 ~ "^dir: " s "$" || $0 ~ "^[a-z]+: " s "$" { in_block = 1; next }
      in_block && /^[a-z]+:/ { in_block = 0 }
      in_block && /^[[:space:]]*content[[:space:]]/ { print; exit }
    ' /etc/pve/storage.cfg 2>/dev/null)

    if echo "$content_line" | grep -q backup; then
      : # found in storage.cfg
    else
      warn "Storage '$STORAGE' exists but doesn't include 'backup' in its content types."
      warn "Current content:  ${content_line:-<not found>}"
      warn "Fix:  pvesm set $STORAGE --content backup,iso,snippets"
      die "Aborting before writing job config."
    fi
  fi
fi

# ----- build the stanza ----------------------------------------------------
# Each line below the header must be indented (PVE convention) — tab or spaces
# both work; we use tabs to match what the GUI generates.
build_stanza() {
  printf 'vzdump: %s\n' "$JOB_ID"
  printf '\tschedule %s\n' "$SCHEDULE"
  printf '\tstorage %s\n' "$STORAGE"
  printf '\tmode %s\n' "$MODE"
  printf '\tcompress %s\n' "$COMPRESS"
  printf '\tprune-backups %s\n' "$RETENTION"
  printf '\tenabled 1\n'
  printf '\tnotification-mode auto\n'
  # Include selection — keyword on the same line as its value.
  case "$INCLUDE" in
    all)
      printf '\tall 1\n' ;;
    pool:*)
      printf '\tpool %s\n' "${INCLUDE#pool:}" ;;
    *)
      printf '\tvmid %s\n' "$INCLUDE" ;;
  esac
  if [[ -n "$MAILTO" ]]; then
    printf '\tmailto %s\n' "$MAILTO"
    printf '\tmailnotification %s\n' "$NOTIFY_MODE"
  fi
}

NEW_STANZA="$(build_stanza)"

# ----- write to jobs.cfg ---------------------------------------------------
log "Installing vzdump job:"
echo
echo "$NEW_STANZA" | sed 's/^/  /'
echo

# Make sure jobs.cfg exists (PVE creates it on first GUI-added job, but if
# the user has never made one, we have to start it).
if [[ ! -f "$JOBS_FILE" ]]; then
  log "Creating $JOBS_FILE (first job on this host)..."
  run "touch '$JOBS_FILE'"
fi

# Idempotent: remove our existing block first, then append the fresh one.
remove_job_block

if (( ! DRY_RUN )); then
  # Trailing newline before the stanza so blocks stay visually separated.
  {
    printf '\n'
    printf '%s\n' "$NEW_STANZA"
  } >> "$JOBS_FILE"
else
  printf '[dry-run] would append stanza to %s\n' "$JOBS_FILE"
fi

log "Job written to $JOBS_FILE — PVE picks it up automatically."

# ----- optional immediate run ----------------------------------------------
if (( RUN_NOW )); then
  log "Triggering one immediate vzdump run (foreground — this can take a while)..."
  log "Tail progress in another shell with:"
  log "  journalctl -u pvescheduler --since '5 min ago' -f"
  log ""

  # Build the equivalent CLI invocation.
  VZARGS=(--storage "$STORAGE" --mode "$MODE" --compress "$COMPRESS")
  case "$INCLUDE" in
    all)     VZARGS+=(--all 1) ;;
    pool:*)  VZARGS+=(--pool "${INCLUDE#pool:}") ;;
    *)       # comma-separated list of CTIDs
             IFS=',' read -ra IDS <<< "$INCLUDE"
             for id in "${IDS[@]}"; do VZARGS+=("$id"); done ;;
  esac

  run "vzdump ${VZARGS[*]}"
fi

# ----- summary -------------------------------------------------------------
log "==> Done."
log " "
log "  Job ID:       $JOB_ID"
log "  Schedule:     $SCHEDULE daily"
log "  Storage:      $STORAGE"
log "  Mode:         $MODE"
log "  Compression:  $COMPRESS"
log "  Retention:    $RETENTION"
log "  Includes:     $INCLUDE"
if [[ -n "$MAILTO" ]]; then
  log "  Notify:       $MAILTO (on $NOTIFY_MODE)"
else
  log "  Notify:       (none — pass --mailto EMAIL to enable)"
fi
log " "
log "  Manual trigger:   vzdump --all --storage $STORAGE --mode $MODE --compress $COMPRESS"
log "  Edit / inspect:   $JOBS_FILE  (or Datacenter → Backup in the GUI)"
log "  Remove:           $0 --uninstall"
