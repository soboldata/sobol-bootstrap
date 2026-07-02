#!/usr/bin/env bash
# setup-email-relay.sh — Configure a CT's postfix to relay through SMTP
#
# Per-CT version of setup-pve-email.sh. Wires postfix INSIDE a target CT so
# that any service in that CT calling `sendmail` or `mail` routes through
# the same SMTP provider as the PVE host.
#
# Most useful when:
#   - A specific CT needs to send mail directly (Mattermost mention emails,
#     Gitea webhook fallbacks, cron jobs inside the CT)
#   - You want a unified "everything sends mail through Postmark" model
#     instead of letting each CT figure out its own MTA
#
# Reads creds from /root/<stack>-tokens.txt on the PVE host (not inside CT)
# and copies the necessary config files into the CT. Idempotent.
#
# Usage:
#   ./setup-email-relay.sh --ct <CTID>           # configure one CT
#   ./setup-email-relay.sh --ct 101 --ct 102     # configure multiple
#   ./setup-email-relay.sh --tokens /root/td-tokens.txt --ct 101
#   ./setup-email-relay.sh --ct 101 --dry-run    # preview
#   ./setup-email-relay.sh --ct 101 --uninstall  # restore .bak

set -Eeuo pipefail

DRY_RUN=0
UNINSTALL=0
TOKENS_FILE=""
declare -a CTIDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --tokens)     TOKENS_FILE="$2"; shift 2 ;;
    --ct)         CTIDS+=("$2"); shift 2 ;;
    -h|--help)    sed -n '2,26p' "$0"; exit 0 ;;
    *)            echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ ${#CTIDS[@]} -gt 0 ]] || { echo "Specify at least --ct <CTID>" >&2; exit 2; }

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[email-relay]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[email-relay]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[email-relay]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."

if [[ -z "$TOKENS_FILE" ]]; then
  for f in /root/td-tokens.txt /root/studio-tokens.txt /root/founder-tokens.txt; do
    [[ -f "$f" ]] && { TOKENS_FILE="$f"; break; }
  done
fi
[[ -f "$TOKENS_FILE" ]] || die "No tokens file found. Specify --tokens"

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

SMTP_HOST="$(read_token SMTP_HOST || true)"
SMTP_PORT="$(read_token SMTP_PORT || echo 587)"
SMTP_USERNAME="$(read_token SMTP_USERNAME || true)"
SMTP_PASSWORD="$(read_token SMTP_PASSWORD || true)"
SMTP_FROM="$(read_token SMTP_FROM || true)"
ADMIN_NOTIFY_EMAIL="$(read_token ADMIN_NOTIFY_EMAIL || read_token ADMIN_EMAIL || true)"

[[ -n "$SMTP_HOST"     ]] || die "SMTP_HOST missing in $TOKENS_FILE"
[[ -n "$SMTP_USERNAME" ]] || die "SMTP_USERNAME missing"
[[ -n "$SMTP_PASSWORD" ]] || die "SMTP_PASSWORD missing"
[[ -n "$SMTP_FROM"     ]] || die "SMTP_FROM missing (must be verified sender)"

configure_one_ct() {
  local ctid="$1"

  if ! pct status "$ctid" 2>/dev/null | grep -q running; then
    warn "  CT $ctid not running — skipping"
    return 0
  fi

  local hostname
  hostname="$(pct config "$ctid" 2>/dev/null | awk '/^hostname:/ {print $2}')"
  log "Configuring email relay in CT $ctid ($hostname)..."

  # Install postfix + sasl modules inside the CT (idempotent — apt skip if installed)
  if (( ! DRY_RUN )); then
    pct exec "$ctid" -- bash -lc "
      set -e
      if ! command -v postfix >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y postfix libsasl2-modules bsd-mailx >/dev/null 2>&1
      fi
    "
  fi

  if (( UNINSTALL )); then
    log "  Restoring postfix config in CT $ctid from .bak..."
    if (( ! DRY_RUN )); then
      pct exec "$ctid" -- bash -lc '
        for f in /etc/postfix/main.cf /etc/postfix/sasl_passwd /etc/aliases; do
          bak=$(ls -t ${f}.bak.* 2>/dev/null | head -1)
          [[ -n "$bak" ]] && cp "$bak" "$f"
        done
        systemctl restart postfix 2>/dev/null || true
        newaliases 2>/dev/null || true
      '
    fi
    return 0
  fi

  # Push the sasl_passwd file in
  local TS=$(date +%s)
  if (( ! DRY_RUN )); then
    # Backup first
    pct exec "$ctid" -- bash -lc "
      for f in /etc/postfix/main.cf /etc/postfix/sasl_passwd /etc/aliases; do
        [[ -f \"\$f\" ]] && cp \"\$f\" \"\${f}.bak.$TS\"
      done
    "

    # Write SASL creds
    echo "[$SMTP_HOST]:$SMTP_PORT $SMTP_USERNAME:$SMTP_PASSWORD" | pct exec "$ctid" -- tee /etc/postfix/sasl_passwd >/dev/null
    pct exec "$ctid" -- bash -lc "
      chmod 600 /etc/postfix/sasl_passwd
      postmap /etc/postfix/sasl_passwd
      chmod 600 /etc/postfix/sasl_passwd.db
    "

    # Patch main.cf
    pct exec "$ctid" -- bash -lc "
      postconf -e 'relayhost = [$SMTP_HOST]:$SMTP_PORT'
      postconf -e 'smtp_use_tls = yes'
      postconf -e 'smtp_sasl_auth_enable = yes'
      postconf -e 'smtp_sasl_security_options = noanonymous'
      postconf -e 'smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd'
      postconf -e 'smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt'
      postconf -e 'smtp_generic_maps = hash:/etc/postfix/generic'
    "

    # Generic map (rewrites From: header to verified sender)
    pct exec "$ctid" -- bash -lc "
      cat > /etc/postfix/generic <<EOF
root@$hostname        $SMTP_FROM
@$hostname            $SMTP_FROM
EOF
      postmap /etc/postfix/generic
    "

    # Root forwarding
    pct exec "$ctid" -- bash -lc "
      if grep -q '^root:' /etc/aliases; then
        sed -i 's|^root:.*|root: $ADMIN_NOTIFY_EMAIL|' /etc/aliases
      else
        echo 'root: $ADMIN_NOTIFY_EMAIL' >> /etc/aliases
      fi
      newaliases
    "

    # Restart
    pct exec "$ctid" -- systemctl restart postfix
    sleep 2
    if pct exec "$ctid" -- systemctl is-active --quiet postfix; then
      log "  ✓ postfix active in CT $ctid"
    else
      warn "  ✗ postfix failed to restart in CT $ctid"
      return 1
    fi
  fi

  log "  ✓ CT $ctid ($hostname) relays through $SMTP_HOST"
}

for ctid in "${CTIDS[@]}"; do
  configure_one_ct "$ctid"
done

log "================================================================"
log "==> Email relay configured in $(echo "${CTIDS[*]}" | wc -w) CT(s)."
log "    All routing through: $SMTP_HOST:$SMTP_PORT"
log " "
log "Test from inside a CT:"
log "  pct exec <CTID> -- bash -lc 'echo \"test\" | mail -s \"hello\" $ADMIN_NOTIFY_EMAIL'"
log "  pct exec <CTID> -- mailq"
log "  pct exec <CTID> -- journalctl -u postfix -n 30"
log "================================================================"
