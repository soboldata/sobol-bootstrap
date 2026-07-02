#!/usr/bin/env bash
# boot.sh — Sobol Data public bootstrap shim.
#
# Fresh PVE host → joined to your tailnet → private stack install
# happens automatically once MagicDNS resolves.
#
# This script is PUBLIC. It knows nothing about any private
# infrastructure. It exists to:
#   1. Fix the enterprise-repo 401 that fresh PVE installs default to
#   2. Install Tailscale on the host
#   3. Join the tailnet using the operator's auth key
#   4. Write ALL prereqs to /root/td-tokens.txt so downstream scripts
#      run unattended
#   5. Delegate to the private Sobol Foundation bootstrap via
#      http://gitea:3000 (resolved through MagicDNS after tailnet-join)
#
# Everything private (Gitea URL, addon library, stack manifests)
# stays private. The only public knowledge is: "run this shim on a
# fresh PVE host and give it your creds."
#
# ------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------
#
# Fastest path (pre-populated tokens file — no network fetch):
#
#   # From your workstation:
#   scp tokens.txt root@<pve-ip>:/root/td-tokens.txt
#   ssh root@<pve-ip>
#   curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
#
# boot.sh detects the file, loads every KEY from it, and skips every
# prompt whose value is already in the file.
#
# Fastest network path (fetch tokens from HTTPS or LAN URL):
#
#   curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
#     → paste a URL at the prompt (e.g. Gitea raw, secret gist, private repo)
#
# Or non-interactively with the URL in env:
#
#   TOKENS_URL='http://<your-gitea-lan-ip>:3000/td/td-tokens/raw/branch/main/td-tokens.txt' \
#   TOKENS_URL_TOKEN=<gitea_or_github_pat> \
#   curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
#
# Private-repo raw URL adds one more env var:
#
#   TOKENS_URL='https://raw.githubusercontent.com/you/private-repo/main/tokens.txt' \
#   TOKENS_URL_TOKEN=ghp_yourPAT... \
#   curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
#
# Fully manual (one prompt per credential):
#
#   TS_AUTHKEY=tskey-auth-... \
#   SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" \
#   CT_PASSWORD='strongpass' \
#   ADMIN_EMAIL='you@example.com' \
#   ADMIN_PASSWORD='stackadminpw' \
#   curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
#
# Interactive (humans, one prompt per missing value):
#
#   curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
#
# Expected keys in a tokens file (any subset works — missing keys prompt):
#   TS_AUTHKEY, TS_HOSTNAME, SSH_PUBKEY, CT_PASSWORD,
#   ADMIN_EMAIL, ADMIN_USER, ADMIN_PASSWORD
#
# Optional env vars:
#   TOKENS_URL       Pre-populated tokens file to fetch (public HTTPS)
#   TOKENS_URL_TOKEN Optional PAT/bearer for private repos (auto-prompted on 401/404)
#   TS_HOSTNAME      Hostname to register on the tailnet (defaults to `hostname -s`)
#   SOBOL_REPO_URL   Public repo URL (default: https://github.com/soboldata/sobol-bootstrap.git)
#   SOBOL_REPO_DIR   Local checkout dir (default: /root/sobol-foundation)
#   STACK            Stack to install (default: sobol-foundation)
#                    Set to 'none' to stop after tailnet-join + repo clone
#
# ------------------------------------------------------------------

# NB. The entire body is wrapped in _main() so bash finishes parsing
# the whole script off the curl|bash pipe BEFORE we redirect any file
# descriptors. See boot.sh's trailing lines for the pattern.
_main() {
set -Eeuo pipefail

# ----- helpers ------------------------------------------------------
log()  { printf "\n\033[1;36m[sobol-boot]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[sobol-boot]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[sobol-boot]\033[0m %s\n" "$*" >&2; exit 1; }

# tty_prompt <var-name> <prompt-text> [-s for silent (no echo)]
# Reads from /dev/tty explicitly so it works even under `curl | bash`.
# If the var is already set in env, use that (non-interactive path).
tty_prompt() {
  local var="$1" msg="$2" silent="${3:-}" val=""
  local current
  current="$(printenv "$var" 2>/dev/null || true)"
  if [[ -n "$current" ]]; then
    printf '%s\n' "$current"
    return 0
  fi
  if [[ ! -r /dev/tty ]]; then
    die "$var not set and /dev/tty not readable — run with $var=... in the env"
  fi
  if [[ "$silent" == "-s" ]]; then
    read -rsp "$msg" val </dev/tty
    echo >/dev/tty
  else
    read -rp "$msg" val </dev/tty
  fi
  printf '%s\n' "$val"
}

# upsert_token <key> <value> — write to /root/td-tokens.txt idempotently
upsert_token() {
  local key="$1" val="$2" f="/root/td-tokens.txt"
  touch "$f"; chmod 600 "$f"
  if grep -q "^$key=" "$f"; then
    sed -i "s|^$key=.*|$key=$val|" "$f"
  else
    printf '%s=%s\n' "$key" "$val" >> "$f"
  fi
}

# ----- preflight ----------------------------------------------------
log "Sobol Data bootstrap shim starting."

[[ $EUID -eq 0 ]] || die "Run as root."
command -v pveversion >/dev/null 2>&1 || die "This isn't a PVE host (no pveversion command)."

PVE_VERSION="$(pveversion 2>/dev/null | head -1 | awk -F/ '{print $2}' | awk -F- '{print $1}')"
log "  PVE version: $PVE_VERSION"

# ----- 1. Repo swap: enterprise → no-subscription -------------------
# Same logic as private bootstrap-fresh-pve.sh — done first so all
# subsequent apt operations succeed. Handles PVE 8 (.list) and PVE 9
# (.sources) formats. Codename detected dynamically.
log "Swapping enterprise → no-subscription apt repos..."

DEB_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
[[ -n "$DEB_CODENAME" ]] || DEB_CODENAME="bookworm"
log "  Debian codename: $DEB_CODENAME"

# .list format (PVE 8)
for f in /etc/apt/sources.list.d/pve-enterprise.list \
         /etc/apt/sources.list.d/ceph.list; do
  [[ -f "$f" ]] || continue
  sed -i 's/^deb /# deb /g' "$f"
  log "  Disabled $f"
done
# .sources format (PVE 9) — rename to .disabled (apt only reads *.sources)
for f in /etc/apt/sources.list.d/pve-enterprise.sources \
         /etc/apt/sources.list.d/ceph.sources \
         /etc/apt/sources.list.d/ceph-squid.sources \
         /etc/apt/sources.list.d/ceph-enterprise.sources; do
  [[ -f "$f" ]] || continue
  mv "$f" "${f}.disabled"
  log "  Disabled $f (renamed → .disabled)"
done
# Add no-subscription
if [[ ! -f /etc/apt/sources.list.d/pve-no-subscription.list ]]; then
  echo "deb http://download.proxmox.com/debian/pve $DEB_CODENAME pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-no-subscription.list
  log "  Added pve-no-subscription.list ($DEB_CODENAME)"
fi

log "Refreshing apt index..."
apt-get update -qq 2>&1 | grep -vE '^(Reading|Get|Hit|Ign|Fetched)' | head -5 || true

# ----- 2. Base tools ------------------------------------------------
log "Installing curl + ca-certificates + gnupg..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  curl ca-certificates gnupg >/dev/null

# ----- 3. Populate /root/td-tokens.txt (three paths, all optional) --
# Fast paths for testing and future customer installs:
#
#   A. Pre-existing /root/td-tokens.txt on the host
#      (operator scp'd it before running boot.sh — no network needed)
#   B. Fetch from public HTTPS URL (TOKENS_URL)
#      Recommended hosts:
#        - GitHub secret gist       (unguessable URL, no auth) — testing
#        - GitHub private repo raw  (requires PAT)             — pilot
#        - Gitea private repo raw   (requires PAT, LAN-reachable)
#        - (future) encrypted blob + decryption key            — intake
#   C. Interactive prompts (blank URL, no pre-existing file)
#
# Any KEY loaded from A or B skips its prompt below. Missing keys still
# prompt interactively, so partial tokens files work — put TS_AUTHKEY
# + ADMIN_* in the file, type SSH_PUBKEY at the terminal, etc.
#
# Path A takes precedence: if /root/td-tokens.txt already exists, we
# don't even prompt for the URL (unless TOKENS_URL is set in env, in
# which case we fetch and MERGE by re-installing the fetched file).

# --- Path A detection ---
if [[ -f /root/td-tokens.txt && -s /root/td-tokens.txt ]] && [[ -z "${TOKENS_URL+x}" ]]; then
  log "Found pre-existing /root/td-tokens.txt — loading values from it."
  log "  (To fetch a URL instead, set TOKENS_URL=... in env or delete the file.)"
  awk -F= '/^[A-Z_][A-Z0-9_]*=/ {
    n = length(substr($0, index($0,"=")+1))
    printf "    %s = <%d chars>\n", $1, n
  }' /root/td-tokens.txt >&2
  # Mark the URL prompt as "already decided" so the next block skips it.
  TOKENS_URL=""
fi

# --- Path B: URL fetch (skipped if TOKENS_URL is set to empty) ---
# Only prompt for the URL if it wasn't set explicitly in env AND we
# didn't already load from a pre-existing file.
if [[ -z "${TOKENS_URL+x}" ]] && [[ -r /dev/tty ]]; then
  printf "\n\033[1;36m[sobol-boot]\033[0m Pre-populated tokens URL (blank for interactive): " >/dev/tty
  read -r TOKENS_URL </dev/tty || TOKENS_URL=""
fi

if [[ -n "${TOKENS_URL:-}" ]]; then
  log "Fetching tokens from $TOKENS_URL..."

  # Optional bearer/PAT for private-repo case. GitHub raw honors both
  # 'token X' and 'Bearer X' — we send 'Bearer' since it's the more
  # widely-portable header form.
  auth_args=()
  if [[ -n "${TOKENS_URL_TOKEN:-}" ]]; then
    auth_args=(-H "Authorization: Bearer $TOKENS_URL_TOKEN")
  fi

  http_code="$(curl -sSL -o /tmp/tokens.fetched -w '%{http_code}' "${auth_args[@]}" "$TOKENS_URL" || echo 000)"

  # Auth challenge → prompt for token, retry once. GitHub returns 404
  # (not 401) for private-repo raw URLs without auth, so catch both.
  if [[ ( "$http_code" == "401" || "$http_code" == "404" ) && -z "${TOKENS_URL_TOKEN:-}" ]]; then
    warn "  Fetch returned HTTP $http_code — may need auth for a private repo."
    TOKENS_URL_TOKEN="$(tty_prompt TOKENS_URL_TOKEN "PAT / bearer token for tokens URL (input hidden): " -s)"
    http_code="$(curl -sSL -o /tmp/tokens.fetched -w '%{http_code}' \
      -H "Authorization: Bearer $TOKENS_URL_TOKEN" "$TOKENS_URL" || echo 000)"
  fi

  [[ "$http_code" == "200" ]] || die "Failed to fetch $TOKENS_URL (HTTP $http_code)."

  # Sanity: at least one KEY=value line, or this is garbage / an HTML
  # error page returned with a 200 (happens with misconfigured gists).
  grep -qE '^[A-Z_][A-Z0-9_]*=' /tmp/tokens.fetched \
    || die "Fetched file doesn't look like a tokens file (no KEY=value lines). First 3 lines:
$(head -3 /tmp/tokens.fetched | sed 's/^/    /')"

  install -m 0600 /tmp/tokens.fetched /root/td-tokens.txt
  rm -f /tmp/tokens.fetched

  # Show what came through, redacted — value length only, never contents
  log "Tokens installed to /root/td-tokens.txt. Keys present:"
  awk -F= '/^[A-Z_][A-Z0-9_]*=/ {
    n = length(substr($0, index($0,"=")+1))
    printf "    %s = <%d chars>\n", $1, n
  }' /root/td-tokens.txt >&2
fi

# --- Common: export every KEY from tokens file into env so tty_prompt ---
# below sees them and skips prompting. This block runs for both Path A
# (pre-existing file) and Path B (URL fetch), which both end with a
# valid /root/td-tokens.txt in place. Safer than `. /root/td-tokens.txt`
# (which would break on values containing # or unquoted whitespace).
if [[ -f /root/td-tokens.txt && -s /root/td-tokens.txt ]]; then
  while IFS='=' read -r _key _val; do
    [[ "$_key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    # Strip CR (Windows line endings) and optional surrounding quotes
    _val="${_val%$'\r'}"
    _val="${_val%\"}"; _val="${_val#\"}"
    _val="${_val%\'}"; _val="${_val#\'}"
    export "$_key"="$_val"
  done < /root/td-tokens.txt
  unset _key _val
fi

# ----- 4. Collect credentials (prompts skip anything already in env) -
# All prompts read from /dev/tty so this works under `curl | bash`.
# If the operator set env vars OR fetched a tokens file above, we use
# those values and skip the prompt.
log "Collecting credentials (fetched/env values are used when set; otherwise prompts)..."

TS_AUTHKEY="$(tty_prompt TS_AUTHKEY "Tailscale REUSABLE auth key (tskey-auth-...): " -s)"
[[ "$TS_AUTHKEY" =~ ^tskey-(auth|client)- ]] || \
  die "TS_AUTHKEY doesn't look like a Tailscale auth key (expected tskey-auth-... or tskey-client-...)"

# SSH pubkey — one-line paste
if [[ -z "${SSH_PUBKEY:-}" ]]; then
  log "Paste your workstation SSH public key (one line, starts with ssh-...):"
fi
SSH_PUBKEY="$(tty_prompt SSH_PUBKEY "> ")"
[[ "$SSH_PUBKEY" =~ ^ssh-(rsa|ed25519|ecdsa) ]] || \
  die "SSH_PUBKEY doesn't look like an SSH public key (must start with ssh-rsa / ssh-ed25519 / ecdsa-)"

CT_PASSWORD="$(tty_prompt CT_PASSWORD "Root password for CTs (12+ chars): " -s)"
[[ "${#CT_PASSWORD}" -ge 12 ]] || die "CT_PASSWORD must be at least 12 chars."

ADMIN_EMAIL="$(tty_prompt ADMIN_EMAIL "Admin email (for stack admin accounts + alerts): ")"
[[ "$ADMIN_EMAIL" == *"@"* ]] || die "ADMIN_EMAIL doesn't look like an email."

# ADMIN_PASSWORD is the password for admin accounts INSIDE the stack apps
# (Mattermost, Gitea, n8n, etc.). Separate from CT_PASSWORD (which is the
# root password for the LXCs themselves). Downstream addons that create
# these admin accounts read this from tokens; without it in the file,
# they'd prompt during install AND fail to persist the value, leaving
# re-runs unable to authenticate. So we collect it here upfront.
ADMIN_PASSWORD="$(tty_prompt ADMIN_PASSWORD "Password for STACK admin accounts (Mattermost, Gitea, n8n; 12+ chars): " -s)"
[[ "${#ADMIN_PASSWORD}" -ge 12 ]] || die "ADMIN_PASSWORD must be at least 12 chars (Mattermost enforces this)."

# ----- 5. Install Tailscale -----------------------------------------
if command -v tailscale >/dev/null 2>&1; then
  log "Tailscale already installed — will re-authenticate with the provided key."
else
  log "Installing Tailscale via https://tailscale.com/install.sh ..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# ----- 6. Join the tailnet ------------------------------------------
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname -s)}"
log "Joining tailnet as '$TS_HOSTNAME'..."
tailscale up \
  --authkey="$TS_AUTHKEY" \
  --hostname="$TS_HOSTNAME" \
  --accept-routes \
  --reset

# Wait for a Tailnet IPv4 (means we're connected + assigned)
TS_IP=""
for i in $(seq 1 30); do
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  [[ -n "$TS_IP" ]] && break
  sleep 1
done
[[ -n "$TS_IP" ]] || die "Tailscale up succeeded but no tailnet IP after 30s"
log "  Tailnet IP: $TS_IP"

# ----- 7. MagicDNS health check (informational only) ----------------
# On a brand-new customer tailnet, there's no gitea yet — that's what
# we're about to install. So this check is just a sanity signal that
# MagicDNS is working; not a prerequisite for the install to proceed.
GITEA_RESOLVED=0
if getent hosts gitea >/dev/null 2>&1; then
  log "  MagicDNS: 'gitea' already resolves (existing tailnet with a Gitea)"
  GITEA_RESOLVED=1
else
  log "  MagicDNS: 'gitea' doesn't resolve yet — expected on a new tailnet"
  log "           (we're about to install it via the automation below)"
fi

# ----- 8. Persist /root/td-tokens.txt -------------------------------
# (If a tokens URL was fetched above, most keys are already in place —
# this block upserts anything the operator supplied interactively OR
# refreshes values that changed since the fetch. Upsert is idempotent.)
log "Writing /root/td-tokens.txt (mode 0600)..."
upsert_token TS_AUTHKEY     "$TS_AUTHKEY"
upsert_token TS_HOSTNAME    "$TS_HOSTNAME"
upsert_token CT_PASSWORD    "$CT_PASSWORD"
upsert_token ADMIN_EMAIL    "$ADMIN_EMAIL"
upsert_token ADMIN_USER     "${ADMIN_USER:-admin}"
upsert_token ADMIN_PASSWORD "$ADMIN_PASSWORD"

# Persist SSH pubkey to a real .pub file so bootstrap-pve.sh can consume it
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "$SSH_PUBKEY" > /root/workstation.pub
chmod 600 /root/workstation.pub
# Also append to authorized_keys so the operator can `ssh root@<pve>` immediately
if ! grep -qFx "$SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
  echo "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  log "  Added SSH pubkey to /root/.ssh/authorized_keys"
fi
upsert_token SSHKEY_FILE    "/root/workstation.pub"

# ----- 9. Fetch the install-time source ------------------------------
# Chicken-and-egg: fresh customer install has no local Gitea (Gitea is
# what we're ABOUT to install), so all install-time code has to come
# from public GitHub. Clone the sobol-bootstrap repo which mirrors the
# install-time subset of the private sobol-foundation repo (automation/
# + addons/ — everything needed to stand up a foundation stack).
STACK="${STACK:-sobol-foundation}"
SOBOL_REPO_URL="${SOBOL_REPO_URL:-https://github.com/soboldata/sobol-bootstrap.git}"
SOBOL_REPO_DIR="${SOBOL_REPO_DIR:-/root/sobol-foundation}"

log "Installing git..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  git >/dev/null

log "Cloning $SOBOL_REPO_URL → $SOBOL_REPO_DIR..."
if [[ -d "$SOBOL_REPO_DIR/.git" ]]; then
  log "  Repo already present — pulling latest..."
  (cd "$SOBOL_REPO_DIR" && git pull --ff-only 2>&1 | sed 's/^/    /')
else
  git clone "$SOBOL_REPO_URL" "$SOBOL_REPO_DIR" 2>&1 | sed 's/^/    /'
fi

if [[ "$STACK" == "none" ]]; then
  log "================================================================"
  log "Shim complete — STACK=none, stopping here."
  log " "
  log "  Host is on tailnet as '$TS_HOSTNAME' ($TS_IP)"
  log "  MagicDNS resolves 'gitea': $(( GITEA_RESOLVED )) && echo yes || echo no"
  log "  Tokens written to /root/td-tokens.txt"
  log "  Repo cloned to $SOBOL_REPO_DIR"
  log " "
  log "Run the automation manually when ready:"
  log "  cd $SOBOL_REPO_DIR"
  log "  bash automation/bootstrap-pve.sh"
  log "  bash automation/setup-ollama-pi.sh"
  log "  bash automation/configure-apps.sh"
  log "================================================================"
  exit 0
fi

# ----- 10. Run the three-phase installation --------------------------
cd "$SOBOL_REPO_DIR"

for s in bootstrap-pve.sh setup-ollama-pi.sh configure-apps.sh; do
  [[ -f "automation/$s" ]] || die "Expected automation/$s in the repo — check the public mirror is complete."
done

log "================================================================"
log "Phase 1 — bootstrap-pve.sh (creates CTs, joins them to tailnet)"
log "================================================================"
bash automation/bootstrap-pve.sh

log "================================================================"
log "Phase 2 — setup-ollama-pi.sh (Ollama + pi install)"
log "================================================================"
bash automation/setup-ollama-pi.sh

log "================================================================"
log "Phase 3 — configure-apps.sh (admins, tokens, dashboard)"
log "================================================================"
bash automation/configure-apps.sh

log "================================================================"
log "==> Sobol Foundation install complete."
log " "
log "  Host:         $(hostname -s) ($TS_IP on tailnet)"
log "  Repo:         $SOBOL_REPO_DIR"
log "  Tokens:       /root/td-tokens.txt (mode 0600)"
log " "
log "Where to go next:"
log "  - Dashboard:  http://homepage (should resolve via MagicDNS)"
log "  - Docs:       cat $SOBOL_REPO_DIR/README.md"
log "  - Addons:     ls $SOBOL_REPO_DIR/addons/"
log "================================================================"
}
# ----- end of _main() ------------------------------------------------

# Redirect stdin from /dev/tty AFTER the whole _main body has been read
# off the curl|bash pipe. This lets any leftover `read` prompts work.
if [ ! -t 0 ] && [ -r /dev/tty ]; then
  exec < /dev/tty
fi

_main "$@"
