#!/usr/bin/env bash
# setup-pve-email.sh — Configure PVE host postfix to relay through SMTP
#
# After this runs, EVERY email the PVE host tries to send (vzdump completion
# alerts, subscription nag mail, root cron output, anything calling `mail`)
# routes through your SMTP provider (Postmark/Mailgun/SES/your-MX) and lands
# in your real inbox at ADMIN_NOTIFY_EMAIL.
#
# Reads creds from /root/<stack>-tokens.txt (auto-detected, or pass --tokens):
#   SMTP_HOST
#   SMTP_PORT             default 587 (STARTTLS)
#   SMTP_USERNAME
#   SMTP_PASSWORD
#   SMTP_FROM             must be a verified sender at your provider
#   SMTP_FROM_NAME        optional friendly name, default "PVE"
#   ADMIN_NOTIFY_EMAIL    where root's mail forwards to
#
# What it does (idempotent at every step):
#   1. Validates SMTP creds are present in tokens file
#   2. Writes /etc/postfix/sasl_passwd with SMTP creds
#   3. Runs postmap to compile the SASL password DB
#   4. Edits /etc/postfix/main.cf to relay through SMTP_HOST:SMTP_PORT
#   5. Sets root → ADMIN_NOTIFY_EMAIL alias in /etc/aliases
#   6. Sets PVE's datacenter.cfg mail-from to SMTP_FROM
#   7. Restarts postfix
#   8. Sends a test email so you know it works
#   9. Backs up every modified config first (timestamped .bak)
#
# Usage:
#   ./setup-pve-email.sh                    # uses /root/td-tokens.txt or studio-tokens.txt (auto-detect)
#   ./setup-pve-email.sh --tokens /root/X-tokens.txt
#   ./setup-pve-email.sh --dry-run          # preview without changes
#   ./setup-pve-email.sh --test-only        # skip config, just send a test
#   ./setup-pve-email.sh --uninstall        # revert to no-relay (use original .bak)

set -Eeuo pipefail

DRY_RUN=0
TEST_ONLY=0
UNINSTALL=0
TOKENS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --test-only)  TEST_ONLY=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --tokens)     TOKENS_FILE="$2"; shift 2 ;;
    -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
    *)            echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[pve-email]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[pve-email]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[pve-email]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v postfix >/dev/null || die "postfix not installed — apt install postfix libsasl2-modules"

# Postfix ships without SASL client mechanisms by default on Debian/PVE.
# Without libsasl2-modules, SMTP AUTH fails with:
#   "no mechanism available" / "No worthy mechs found"
# Install it explicitly — idempotent (apt skips if already installed).
if ! dpkg -l libsasl2-modules 2>/dev/null | grep -q '^ii'; then
  log "Installing libsasl2-modules (required for SMTP AUTH to relay)..."
  if (( ! DRY_RUN )); then
    DEBIAN_FRONTEND=noninteractive apt-get install -y libsasl2-modules >/dev/null 2>&1 \
      || die "Failed to install libsasl2-modules. Run 'apt update && apt install libsasl2-modules' manually."
  fi
fi

# Auto-detect tokens file if not specified
if [[ -z "$TOKENS_FILE" ]]; then
  for f in /root/td-tokens.txt /root/studio-tokens.txt /root/founder-tokens.txt; do
    [[ -f "$f" ]] && { TOKENS_FILE="$f"; break; }
  done
fi
[[ -f "$TOKENS_FILE" ]] || die "No tokens file found. Specify --tokens /path/to/tokens.txt"
log "Using tokens file: $TOKENS_FILE"

# read_token — same pattern as TD-Proxmox addons
read_token() {
  local key="$1" val
  val="$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); v = $0 } END { print v }' "$TOKENS_FILE")"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  case "$val" in
    "<"*">"|""|"REPLACE_ME"|"CHANGEME") return 1 ;;
  esac
  printf '%s\n' "$val"
}

# ----- uninstall path ---------------------------------------------------
if (( UNINSTALL )); then
  log "Restoring original postfix config from .bak..."
  for f in /etc/postfix/main.cf /etc/postfix/sasl_passwd /etc/aliases /etc/pve/datacenter.cfg; do
    bak="$(ls -t ${f}.bak.* 2>/dev/null | head -1)"
    if [[ -n "$bak" ]]; then
      log "  $f → restored from $bak"
      run "cp '$bak' '$f'"
    else
      log "  $f → no .bak found, skipping"
    fi
  done
  run "systemctl restart postfix"
  run "newaliases"
  log "Uninstalled. SMTP relay reverted."
  exit 0
fi

# ----- read creds from tokens -------------------------------------------
SMTP_HOST="$(read_token SMTP_HOST || true)"
SMTP_PORT="$(read_token SMTP_PORT || echo 587)"
SMTP_USERNAME="$(read_token SMTP_USERNAME || true)"
SMTP_PASSWORD="$(read_token SMTP_PASSWORD || true)"
SMTP_FROM="$(read_token SMTP_FROM || true)"
SMTP_FROM_NAME="$(read_token SMTP_FROM_NAME || echo 'PVE')"
ADMIN_NOTIFY_EMAIL="$(read_token ADMIN_NOTIFY_EMAIL || read_token ADMIN_EMAIL || true)"

[[ -n "$SMTP_HOST" ]]          || die "SMTP_HOST missing in $TOKENS_FILE"
[[ -n "$SMTP_USERNAME" ]]      || die "SMTP_USERNAME missing in $TOKENS_FILE"
[[ -n "$SMTP_PASSWORD" ]]      || die "SMTP_PASSWORD missing in $TOKENS_FILE"
[[ -n "$SMTP_FROM" ]]          || die "SMTP_FROM missing in $TOKENS_FILE (must be a verified sender at your SMTP provider)"
[[ -n "$ADMIN_NOTIFY_EMAIL" ]] || die "ADMIN_NOTIFY_EMAIL (or ADMIN_EMAIL) missing — where should root's mail go?"

log "  SMTP_HOST:          $SMTP_HOST:$SMTP_PORT"
log "  SMTP_FROM:          $SMTP_FROM_NAME <$SMTP_FROM>"
log "  ADMIN_NOTIFY_EMAIL: $ADMIN_NOTIFY_EMAIL"

# ----- test-only path ---------------------------------------------------
if (( TEST_ONLY )); then
  log "Sending test email to $ADMIN_NOTIFY_EMAIL (skipping config)..."
  if (( ! DRY_RUN )); then
    printf "Subject: Test from PVE $(hostname)\nFrom: %s <%s>\n\nThis is a test email from PVE $(hostname) at $(date).\n\nIf you got this, postfix relay is working.\n" "$SMTP_FROM_NAME" "$SMTP_FROM" | sendmail -t "$ADMIN_NOTIFY_EMAIL"
  fi
  log "Test email sent. Check $ADMIN_NOTIFY_EMAIL inbox + Postfix queue (mailq) + journal (journalctl -u postfix -n 30)"
  exit 0
fi

# ----- 1. backup ---------------------------------------------------------
TS=$(date +%s)
log "Backing up current config..."
for f in /etc/postfix/main.cf /etc/postfix/sasl_passwd /etc/aliases; do
  if [[ -f "$f" ]]; then
    run "cp '$f' '${f}.bak.$TS'"
    log "  ✓ ${f}.bak.$TS"
  fi
done
# datacenter.cfg may not exist on fresh installs
[[ -f /etc/pve/datacenter.cfg ]] && run "cp /etc/pve/datacenter.cfg /etc/pve/datacenter.cfg.bak.$TS"

# ----- 2. write sasl_passwd ----------------------------------------------
log "Writing /etc/postfix/sasl_passwd..."
if (( ! DRY_RUN )); then
  cat > /etc/postfix/sasl_passwd <<EOF
[$SMTP_HOST]:$SMTP_PORT $SMTP_USERNAME:$SMTP_PASSWORD
EOF
  chmod 600 /etc/postfix/sasl_passwd
  postmap /etc/postfix/sasl_passwd
  chmod 600 /etc/postfix/sasl_passwd.db
fi

# ----- 3. patch main.cf --------------------------------------------------
log "Patching /etc/postfix/main.cf for relay through $SMTP_HOST..."

# Use postconf to make changes idempotent — it handles existing keys safely
if (( ! DRY_RUN )); then
  postconf -e "relayhost = [$SMTP_HOST]:$SMTP_PORT"
  # smtp_tls_security_level = encrypt enforces STARTTLS on port 587.
  # Older 'smtp_use_tls = yes' was deprecated in postfix 3.x; new param is
  # less ambiguous: 'may' = opportunistic, 'encrypt' = required, 'verify' =
  # required + cert validation. Postmark requires TLS so 'encrypt' is right.
  postconf -e "smtp_tls_security_level = encrypt"
  # Strip the deprecated param if a prior version of this script left it
  # in main.cf — postconf -X errors if missing, so check first.
  postconf smtp_use_tls 2>/dev/null | grep -q '^smtp_use_tls' && postconf -X smtp_use_tls 2>/dev/null || true
  postconf -e "smtp_sasl_auth_enable = yes"
  postconf -e "smtp_sasl_security_options = noanonymous"
  postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
  postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
  # Override the From address on outbound mail so it matches the SMTP sender
  postconf -e "smtp_generic_maps = hash:/etc/postfix/generic"

  # Build the generic map: any local user → SMTP_FROM
  cat > /etc/postfix/generic <<EOF
root@$(hostname)        $SMTP_FROM
root@$(hostname -f)     $SMTP_FROM
@$(hostname)            $SMTP_FROM
EOF
  postmap /etc/postfix/generic
fi

# ----- 4. set root forwarding alias --------------------------------------
log "Forwarding root mail to $ADMIN_NOTIFY_EMAIL..."
if (( ! DRY_RUN )); then
  if grep -q "^root:" /etc/aliases; then
    sed -i "s|^root:.*|root: $ADMIN_NOTIFY_EMAIL|" /etc/aliases
  else
    echo "root: $ADMIN_NOTIFY_EMAIL" >> /etc/aliases
  fi
  newaliases
fi

# ----- 5. PVE datacenter.cfg mail-from ----------------------------------
if [[ -f /etc/pve/datacenter.cfg ]]; then
  log "Setting PVE datacenter mail-from to $SMTP_FROM..."
  if (( ! DRY_RUN )); then
    if grep -q "^mail-from:" /etc/pve/datacenter.cfg; then
      sed -i "s|^mail-from:.*|mail-from: $SMTP_FROM|" /etc/pve/datacenter.cfg
    else
      echo "mail-from: $SMTP_FROM" >> /etc/pve/datacenter.cfg
    fi
  fi
fi

# ----- 6. restart postfix ------------------------------------------------
log "Restarting postfix..."
run "systemctl restart postfix"
sleep 2

if (( ! DRY_RUN )); then
  if systemctl is-active --quiet postfix; then
    log "  ✓ postfix is active"
  else
    die "  postfix failed to restart — check journalctl -u postfix -n 30"
  fi
fi

# ----- 7. send test email ------------------------------------------------
log "Sending test email to $ADMIN_NOTIFY_EMAIL..."
if (( ! DRY_RUN )); then
  printf "Subject: Test from PVE $(hostname)\nFrom: %s <%s>\n\nThis is a test email from PVE %s at %s.\n\nIf you got this, postfix relay is working. Future PVE alerts (vzdump completion, subscription nag, root cron output) will route through %s and land here.\n" \
    "$SMTP_FROM_NAME" "$SMTP_FROM" "$(hostname)" "$(date)" "$SMTP_HOST" | sendmail -t "$ADMIN_NOTIFY_EMAIL"
  sleep 3
  # Check mail queue — if test got stuck, surface it.
  # NB. `grep -v "^Mail queue is empty"` used to be the check, but under
  # set -Eeuo pipefail it BREAKS in the HAPPY PATH: when the queue is
  # empty (mailq prints only that literal line), grep -v filters it out,
  # exits 1 (no matches), pipefail propagates, command substitution
  # returns non-zero, and set -e kills the script. Replaced with a
  # simple string check that always exits 0 and lets pipefail be quiet.
  mailq_out=$(mailq 2>&1 || true)
  if ! grep -q "Mail queue is empty" <<<"$mailq_out"; then
    warn "  Mail queue not empty after send. Check 'mailq' and 'journalctl -u postfix -n 30'"
  fi
fi

# ----- summary -----------------------------------------------------------
log "================================================================"
log "==> PVE email relay configured."
log " "
log "  Relay host:   $SMTP_HOST:$SMTP_PORT"
# Postmark (and some other providers) use the same Server API Token for
# both SMTP username AND password. So SMTP_USERNAME is the actual secret —
# redact in output to avoid leaking it when users paste run output.
log "  Auth user:    ${SMTP_USERNAME:0:8}... (redacted; full value in $TOKENS_FILE)"
log "  From address: $SMTP_FROM ($SMTP_FROM_NAME)"
log "  root → :      $ADMIN_NOTIFY_EMAIL"
log " "
log "What now routes through SMTP:"
log "  - vzdump completion notifications"
log "  - PVE cluster alerts"
log "  - root's cron output"
log "  - any 'echo ... | mail' invocations"
log " "
log "Verify:"
log "  Send manual test: ./setup-pve-email.sh --test-only"
log "  Watch queue:      mailq"
log "  Watch postfix:    journalctl -u postfix -f"
log "  Inspect config:   postconf -n | grep -E 'relayhost|sasl|tls'"
log " "
log "Uninstall (revert):"
log "  $(basename "$0") --uninstall"
log "================================================================"
