#!/usr/bin/env bash
# setup-gitea-email.sh — Wire Gitea's [mailer] section to send mail
#
# After this, Gitea sends:
#   - account verification emails
#   - password resets
#   - issue / PR notifications to watchers
#   - daily/weekly digest emails for subscribed users
#   - admin notifications
#
# Reads SMTP_* from /root/td-tokens.txt. Edits app.ini's [mailer] section
# with a markered block so re-runs don't accumulate dupes. Restarts Gitea.
#
# Usage:
#   ./setup-gitea-email.sh
#   ./setup-gitea-email.sh --dry-run
#   ./setup-gitea-email.sh --uninstall  # strip the markered block, restart

set -Eeuo pipefail

DRY_RUN=0
UNINSTALL=0
TOKENS_FILE="/root/td-tokens.txt"
MARKER_BEGIN="# TD-Mailer: BEGIN (managed by setup-gitea-email.sh)"
MARKER_END="# TD-Mailer: END"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --tokens)     TOKENS_FILE="$2"; shift 2 ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

log()  { printf "\n\033[1;36m[gitea-email]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[gitea-email]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[gitea-email]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."

find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

read_token() {
  local k="$1" v
  [[ -f "$TOKENS_FILE" ]] || return 1
  v="$(awk -F= -v k="$k" '$1 == k { sub(/^[^=]*=/, "", $0); val = $0 } END { print val }' "$TOKENS_FILE")"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  [[ -n "$v" ]] && printf '%s\n' "$v"
}

# ----- preflight ---------------------------------------------------------
GITEA_CTID="$(find_ct_by_hostname gitea 2>/dev/null || true)"
[[ -n "$GITEA_CTID" ]] || die "Gitea CT not found. Hostname must be 'gitea'."

CONFIG="$(pct exec "$GITEA_CTID" -- bash -lc 'for p in /etc/gitea/app.ini /var/lib/gitea/custom/conf/app.ini /opt/gitea/custom/conf/app.ini; do [[ -f "$p" ]] && echo "$p" && exit 0; done')"
[[ -n "$CONFIG" ]] || die "Couldn't find app.ini inside CT $GITEA_CTID."
log "Gitea CT $GITEA_CTID — app.ini at $CONFIG"

# ----- uninstall path ----------------------------------------------------
if (( UNINSTALL )); then
  log "Stripping mailer block from $CONFIG..."
  if (( ! DRY_RUN )); then
    pct exec "$GITEA_CTID" -- bash -lc "
      cp '$CONFIG' '${CONFIG}.bak.\$(date +%s)'
      sed -i '/$MARKER_BEGIN/,/$MARKER_END/d' '$CONFIG'
      systemctl restart gitea
    "
  fi
  log "Uninstalled. Gitea email features now disabled."
  exit 0
fi

# ----- read SMTP creds --------------------------------------------------
SMTP_HOST="$(read_token SMTP_HOST || true)"
SMTP_PORT="$(read_token SMTP_PORT || echo 587)"
SMTP_USERNAME="$(read_token SMTP_USERNAME || true)"
SMTP_PASSWORD="$(read_token SMTP_PASSWORD || true)"
SMTP_FROM="$(read_token SMTP_FROM || true)"
SMTP_FROM_NAME="$(read_token SMTP_FROM_NAME || echo 'Gitea')"

[[ -n "$SMTP_HOST" ]]      || die "SMTP_HOST missing in $TOKENS_FILE. Run setup-pve-email.sh first."
[[ -n "$SMTP_USERNAME" ]]  || die "SMTP_USERNAME missing in $TOKENS_FILE."
[[ -n "$SMTP_PASSWORD" ]]  || die "SMTP_PASSWORD missing in $TOKENS_FILE."
[[ -n "$SMTP_FROM" ]]      || die "SMTP_FROM missing in $TOKENS_FILE (must be verified at provider)."

log "  SMTP host:    $SMTP_HOST:$SMTP_PORT"
log "  SMTP from:    $SMTP_FROM_NAME <$SMTP_FROM>"

# ----- write the markered block ----------------------------------------
# Build the mailer block. Gitea's [mailer] section has been stable since 1.18.
# - ENABLED = true   so the [mailer] is wired
# - PROTOCOL = smtp+starttls (matches port 587) or smtps (465)
# - SMTP_ADDR + SMTP_PORT
# - USER + PASSWD
# - FROM = "<name>" <email>
case "$SMTP_PORT" in
  465) PROTO="smtps" ;;
  *)   PROTO="smtp+starttls" ;;
esac

MAILER_BLOCK="$MARKER_BEGIN
[mailer]
ENABLED          = true
PROTOCOL         = $PROTO
SMTP_ADDR        = $SMTP_HOST
SMTP_PORT        = $SMTP_PORT
USER             = $SMTP_USERNAME
PASSWD           = $SMTP_PASSWORD
FROM             = \"$SMTP_FROM_NAME\" <$SMTP_FROM>
SEND_AS_PLAIN_TEXT = false

[service]
REGISTER_EMAIL_CONFIRM   = true
ENABLE_NOTIFY_MAIL       = true
$MARKER_END"

# ----- patch app.ini ----------------------------------------------------
log "Patching $CONFIG..."

if (( DRY_RUN )); then
  echo "$MAILER_BLOCK" | sed 's/^/[dry-run]   /'
else
  # Write the new block to a temp file inside the CT, then sed-replace any
  # existing markered block + append the new one.
  echo "$MAILER_BLOCK" | pct exec "$GITEA_CTID" -- tee /tmp/gitea-mailer.txt >/dev/null

  pct exec "$GITEA_CTID" -- bash -lc "
    cp '$CONFIG' '${CONFIG}.bak.\$(date +%s)'

    # Strip any existing markered block (re-run safety)
    sed -i '/$MARKER_BEGIN/,/$MARKER_END/d' '$CONFIG'

    # Strip any prior unmarked [mailer] / [service] blocks Gitea may have
    # auto-written — we want OUR markered block to be the single source.
    # Only strip those exact section names + their immediate values, not
    # other [service.*] subsections.
    # (Be conservative — if app.ini has a [service] block with other keys,
    # leave it; Gitea merges multiple [section] blocks if they exist.)

    # Append our block
    echo '' >> '$CONFIG'
    cat /tmp/gitea-mailer.txt >> '$CONFIG'
    rm -f /tmp/gitea-mailer.txt
  "
fi

# ----- restart gitea ---------------------------------------------------
log "Restarting Gitea..."
run "pct exec $GITEA_CTID -- systemctl restart gitea"
sleep 3

if (( ! DRY_RUN )); then
  if pct exec "$GITEA_CTID" -- systemctl is-active --quiet gitea; then
    log "  ✓ gitea is active"
  else
    die "  gitea failed to restart — check 'pct exec $GITEA_CTID -- journalctl -u gitea -n 30'"
  fi
fi

# ----- send a test via Gitea's own admin endpoint ---------------------
log "Sending Gitea test email..."

if (( ! DRY_RUN )); then
  ADMIN_USER="$(read_token ADMIN_USER || echo admin)"
  GITEA_TOKEN="$(read_token GITEA_TOKEN || true)"

  if [[ -n "$GITEA_TOKEN" ]]; then
    # Use the admin API to send a test mail to ADMIN_NOTIFY_EMAIL
    ADMIN_NOTIFY_EMAIL="$(read_token ADMIN_NOTIFY_EMAIL || read_token ADMIN_EMAIL)"
    TEST_RESP="$(pct exec "$GITEA_CTID" -- bash -lc "
      curl -sS -o /dev/null -w '%{http_code}' \
        -H 'Authorization: token $GITEA_TOKEN' \
        -X POST 'http://localhost:3000/api/v1/admin/email/test' \
        -H 'Content-Type: application/json' \
        -d '{\"email\":\"$ADMIN_NOTIFY_EMAIL\"}' 2>/dev/null
    ")"
    log "  Test send HTTP: $TEST_RESP"
    if [[ "$TEST_RESP" =~ ^2 ]]; then
      log "  ✓ Test email sent. Check $ADMIN_NOTIFY_EMAIL inbox."
    else
      warn "  Test endpoint returned $TEST_RESP. Try sending from Site Administration → Configuration → Mailer Config → Send Testing Email."
    fi
  else
    log "  No GITEA_TOKEN in tokens — skipping API test. Test manually:"
    log "    Site Administration → Configuration → Mailer Config → 'Send Testing Email'"
  fi
fi

# ----- summary ---------------------------------------------------------
log "================================================================"
log "==> Gitea mailer configured."
log " "
log "  Protocol:    $PROTO"
log "  Host:        $SMTP_HOST:$SMTP_PORT"
log "  From:        \"$SMTP_FROM_NAME\" <$SMTP_FROM>"
log "  Config:      $CONFIG (markered block, safe to re-run)"
log " "
log "What now sends email:"
log "  - Account verification (REGISTER_EMAIL_CONFIRM = true)"
log "  - Password resets"
log "  - Issue / PR notifications to watchers (ENABLE_NOTIFY_MAIL = true)"
log "  - Mention emails"
log "  - Admin invitations"
log " "
log "Per-user opt-in to watch a repo:"
log "  Repo settings → Notifications → Watch → 'Watching'"
log " "
log "Manage:"
log "  Re-run:    $(basename "$0")"
log "  Uninstall: $(basename "$0") --uninstall"
log "  Inspect:   pct exec $GITEA_CTID -- grep -A20 'mailer' $CONFIG"
log "================================================================"
