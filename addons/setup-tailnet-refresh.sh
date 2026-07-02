#!/usr/bin/env bash
# setup-tailnet-refresh.sh — force every node in this stack to re-auth
# against the current TS_AUTHKEY.
#
# When to use this:
#   - Operator deleted devices from the tailnet admin panel and needs
#     the local nodes to re-register with fresh identities
#   - Tailscale auth key rotated; all nodes need to re-key
#   - Tailnet ACL / tag change; want to force re-registration to pick
#     up the new tag assignments
#   - Debugging weird tailnet state (works better than manual per-node
#     tailscale up commands because it's uniform and idempotent)
#
# What it does:
#   1. Reads TS_AUTHKEY from /root/td-tokens.txt
#   2. For the PVE host itself: `tailscale up --authkey --force-reauth`
#   3. For every running CT that has tailscale installed:
#      `pct exec $CT -- tailscale up --authkey --force-reauth`
#   4. Waits up to 30s per node for a fresh tailnet IP
#   5. Reports success/failure per node in a summary table
#
# Unlike bootstrap-pve.sh's per-CT tailscale step which SKIPS nodes that
# already have a 100.x IP, this script UNCONDITIONALLY force-reauths
# every node. That's the whole point: the caller is saying "I know the
# current state is broken/stale — regenerate identities everywhere."
#
# Flags:
#   --dry-run          Show what would run, don't actually reauth
#   --host-only        Only refresh the PVE host, skip CTs
#   --cts-only         Only refresh CTs, skip the PVE host
#   --only <CTID|host> Refresh a single target (repeatable)
#   --exclude <CTID>   Skip a specific CT (repeatable)
#
# Env:
#   TS_AUTHKEY         Override the value in /root/td-tokens.txt
#   TOKENS_FILE        Path to tokens file (default: /root/td-tokens.txt)

set -Eeuo pipefail

TOKENS_FILE="${TOKENS_FILE:-/root/td-tokens.txt}"
DRY_RUN=0
HOST_ONLY=0
CTS_ONLY=0
declare -a ONLY_TARGETS=()
declare -a EXCLUDE_CTS=()

# ----- helpers --------------------------------------------------------------
log()  { printf "\n\033[1;36m[tailnet-refresh]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[tailnet-refresh]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[tailnet-refresh]\033[0m %s\n" "$*" >&2; exit 1; }

# Source ct-helpers.sh for ts_ensure_joined + ct_find_by_hostname
LIB="$(dirname "${BASH_SOURCE[0]}")/lib/ct-helpers.sh"
if [[ -r "$LIB" ]]; then
  # shellcheck source=lib/ct-helpers.sh
  source "$LIB"
else
  die "Can't find ct-helpers.sh at $LIB (this script should live in sobol-foundation/addons/)"
fi

read_from_tokens() {
  local key="$1"
  [[ -f "$TOKENS_FILE" ]] || return 1
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); print; exit }' "$TOKENS_FILE"
}

# ----- args -----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=1;                 shift ;;
    --host-only)   HOST_ONLY=1;               shift ;;
    --cts-only)    CTS_ONLY=1;                shift ;;
    --only)        ONLY_TARGETS+=("$2");      shift 2 ;;
    --exclude)     EXCLUDE_CTS+=("$2");       shift 2 ;;
    -h|--help)
      sed -n '2,32p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) die "Unknown flag: $1 (see --help)" ;;
  esac
done

if (( HOST_ONLY && CTS_ONLY )); then
  die "--host-only and --cts-only are mutually exclusive"
fi

# ----- preflight ------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root."
command -v pct >/dev/null 2>&1 || die "pct not found — this needs to run on a PVE host."

TS_AUTHKEY="${TS_AUTHKEY:-$(read_from_tokens TS_AUTHKEY 2>/dev/null || true)}"
if [[ -z "$TS_AUTHKEY" ]]; then
  die "No TS_AUTHKEY in $TOKENS_FILE and none in env. Set one and retry:
    TS_AUTHKEY=tskey-auth-... $0"
fi

if [[ ! "$TS_AUTHKEY" =~ ^tskey-(auth|client)- ]]; then
  die "TS_AUTHKEY doesn't look like a Tailscale auth key (expected tskey-auth-...)"
fi

TS_HOSTNAME="$(read_from_tokens TS_HOSTNAME 2>/dev/null || hostname -s)"

log "TS_AUTHKEY loaded (${#TS_AUTHKEY} chars). PVE host tailnet name: $TS_HOSTNAME"

# ----- build the target list ------------------------------------------------
declare -a TARGETS=()

# The PVE host
if (( ! CTS_ONLY )); then
  if [[ ${#ONLY_TARGETS[@]} -eq 0 ]] || printf '%s\n' "${ONLY_TARGETS[@]}" | grep -qx "host"; then
    TARGETS+=("host")
  fi
fi

# Every running CT with tailscale installed
if (( ! HOST_ONLY )); then
  while IFS= read -r ctid; do
    # --only filter
    if [[ ${#ONLY_TARGETS[@]} -gt 0 ]] && ! printf '%s\n' "${ONLY_TARGETS[@]}" | grep -qx "$ctid"; then
      continue
    fi
    # --exclude filter
    if [[ ${#EXCLUDE_CTS[@]} -gt 0 ]] && printf '%s\n' "${EXCLUDE_CTS[@]}" | grep -qx "$ctid"; then
      log "  Skipping CT $ctid (--exclude)"
      continue
    fi
    # Must be running
    if ! pct status "$ctid" 2>/dev/null | grep -q "status: running"; then
      log "  Skipping CT $ctid (not running — start with 'pct start $ctid' first)"
      continue
    fi
    # Must have tailscale binary present + executable.
    # NB. `command -v` is a bash builtin, so `pct exec CT -- command -v X`
    # fails via execvp regardless of whether X is installed. Test by
    # invoking the binary itself (which pct exec resolves through PATH
    # the same way bootstrap-pve.sh's tailscale up call does).
    if ! pct exec "$ctid" -- tailscale --version >/dev/null 2>&1; then
      log "  Skipping CT $ctid (no tailscale binary — was bootstrap-pve.sh's Tailscale step ever run for it?)"
      continue
    fi
    TARGETS+=("$ctid")
  done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  die "No targets matched. Check pct list, --only, --exclude filters."
fi

log "Refresh plan (${#TARGETS[@]} targets):"
for t in "${TARGETS[@]}"; do
  if [[ "$t" == "host" ]]; then
    printf "    - PVE host (%s)\n" "$TS_HOSTNAME"
  else
    hn="$(pct config "$t" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    printf "    - CT %s (%s)\n" "$t" "${hn:-?}"
  fi
done

if (( DRY_RUN )); then
  log "Dry-run — not doing anything. Re-run without --dry-run to force reauth."
  exit 0
fi

# ----- refresh loop ---------------------------------------------------------
# ts_ensure_joined() in ct-helpers.sh checks "already on tailnet?" and
# skips if yes — but that's NOT what we want here. The whole point of
# this addon is to unconditionally force reauth. So we build the force-
# reauth command inline and don't call ts_ensure_joined.

declare -A RESULTS=()

for target in "${TARGETS[@]}"; do
  if [[ "$target" == "host" ]]; then
    exec_prefix=""
    label="PVE host ($TS_HOSTNAME)"
    hostname="$TS_HOSTNAME"
  else
    exec_prefix="pct exec $target --"
    hn="$(pct config "$target" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    label="CT $target (${hn:-?})"
    hostname="${hn:-ct$target}"
  fi

  log "==> $label — force-reauth"

  # Run up with --force-reauth. Don't die on non-zero; some tailscaled
  # versions return non-zero on successful reauth if the IP change
  # produces a warning. We judge success by "is there a 100.x IP after".
  $exec_prefix tailscale up \
    --authkey="$TS_AUTHKEY" \
    --hostname="$hostname" \
    --accept-routes \
    --reset \
    --force-reauth 2>&1 | sed 's/^/    /' || true

  # Wait for tailnet IP (up to 30s)
  new_ip=""
  for i in $(seq 1 30); do
    new_ip="$($exec_prefix tailscale ip -4 2>/dev/null | head -1 || true)"
    [[ -n "$new_ip" && "$new_ip" =~ ^100\. ]] && break
    sleep 1
  done

  if [[ -n "$new_ip" && "$new_ip" =~ ^100\. ]]; then
    log "  ✓ $label rejoined as $new_ip"
    RESULTS["$target"]="OK $new_ip"
  else
    warn "  ✗ $label did not come back on tailnet after 30s"
    warn "    $exec_prefix tailscale status"
    warn "    $exec_prefix journalctl -u tailscaled --no-pager -n 30"
    RESULTS["$target"]="FAIL"
  fi
done

# ----- summary --------------------------------------------------------------
log "================================================================"
log "Refresh summary"
log "================================================================"
ok=0
fail=0
for t in "${TARGETS[@]}"; do
  status="${RESULTS[$t]}"
  if [[ "$t" == "host" ]]; then
    printf "  %-10s  PVE host        %s\n" "host" "$status"
  else
    hn="$(pct config "$t" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    printf "  %-10s  %-15s %s\n" "CT $t" "${hn:-?}" "$status"
  fi
  [[ "$status" == FAIL ]] && fail=$((fail+1)) || ok=$((ok+1))
done
log "$ok succeeded, $fail failed."

if (( fail > 0 )); then
  warn "Some nodes did not come back on tailnet. See per-node debug output above."
  exit 1
fi
