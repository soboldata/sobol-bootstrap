#!/usr/bin/env bash
# setup-pi-mattermost-bridge.sh — Bidirectional pi ↔ Mattermost bridge.
#
# Wraps the @whonixnetworks/pi-mattermost npm package + local patches +
# systemd service so a pi session running on ollama-pi-agent can be DRIVEN
# from a Mattermost channel — user types in #bot, pi reads it and responds
# in the same channel.
#
# Prerequisites (script will verify):
#   - ollama-pi-agent CT exists, running, and has pi installed
#     (i.e., setup-ollama-pi.sh has finished against this host)
#   - mattermost CT exists with a pi-bot account + #bot channel
#     (i.e., setup-mattermost.sh has finished successfully)
#   - /root/td-tokens.txt has the MATTERMOST_BOT_TOKEN /
#     MATTERMOST_BOT_USER_ID / MATTERMOST_TEAM_ID / MATTERMOST_URL lines
#
# What it does (idempotent at each step):
#   1. Reads MM bot creds from /root/td-tokens.txt
#   2. Resolves pi's node binary path inside ollama-pi-agent
#      (/root/.local/share/pi-node/node-v*/bin/node — version-agnostic)
#   3. Installs @whonixnetworks/pi-mattermost via pi's npm
#      (lands at /root/.pi/agent/npm/node_modules/@whonixnetworks/pi-mattermost)
#   4. Applies our 3 local patches to that install — debug logging +
#      PI_MATTERMOST_AUTO_CONNECT env var support + projectPath="/" fallback
#      to /var/pi/bot
#   5. Writes ~/.config/pi-mattermost/config.toml populated from td-tokens.txt
#   6. Installs the systemd unit at /etc/systemd/system/pi-mattermost.service
#   7. Adds 'export PI_MATTERMOST_AUTO_CONNECT=1' to /root/.bashrc on the
#      pi host so any new pi session connects automatically
#   8. systemctl daemon-reload + enable --now pi-mattermost
#   9. Looks up the #bot channel id via Mattermost REST API and INSERTs a
#      channel_mappings row in the bridge's sessions.db so pi's default
#      auto-connect (projectPath=/var/pi/bot) resolves straight to #bot
#  10. Installs pi-bot.service — a tmux-hosted persistent pi session that
#      auto-starts at CT boot and registers with the bridge. Without this,
#      inbound posts to #bot drop on the floor when nobody has pi open.
#      Skip with --no-daemon if you only want manual interactive pi sessions.
#
# Usage:
#   ./setup-pi-mattermost-bridge.sh             # default: install end-to-end
#                                                # (including pi-bot daemon)
#   ./setup-pi-mattermost-bridge.sh --no-daemon  # skip pi-bot.service install
#   ./setup-pi-mattermost-bridge.sh --model NAME # override model (default:
#                                                # pi settings.json defaultModel)
#   ./setup-pi-mattermost-bridge.sh --dry-run    # preview
#   ./setup-pi-mattermost-bridge.sh --uninstall  # stop services + remove units
#                                                # (leaves npm package + patches
#                                                # in place; reinstall via re-run)

set -Eeuo pipefail

# ----- args --------------------------------------------------------------
DRY_RUN=0
UNINSTALL=0
WITH_DAEMON=1   # install pi-bot.service by default; --no-daemon opts out
PI_MODEL=""     # auto-detect from pi's settings.json; --model overrides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$SCRIPT_DIR/pi-mattermost-bridge"
TOKENS_FILE="/root/td-tokens.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --no-daemon)  WITH_DAEMON=0; shift ;;
    --with-daemon) WITH_DAEMON=1; shift ;;
    --model)      PI_MODEL="$2"; shift 2 ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-pi-mm-bridge]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-pi-mm-bridge]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-pi-mm-bridge]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct >/dev/null || die "pct not found — PVE host required."

find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

read_token() {
  local key="$1"
  [[ -f "$TOKENS_FILE" ]] || return 1
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); print; exit }' "$TOKENS_FILE"
}

# ----- pre-flight --------------------------------------------------------
PI_CTID="$(find_ct_by_hostname ollama-pi-agent 2>/dev/null || true)"
[[ -n "$PI_CTID" ]] || die "No CT with hostname 'ollama-pi-agent' found. Run bootstrap-pve.sh + setup-ollama-pi.sh first."

MM_CTID="$(find_ct_by_hostname mattermost 2>/dev/null || true)"
[[ -n "$MM_CTID" ]] || die "No CT with hostname 'mattermost' found. Run ./addons/setup-mattermost.sh first."

pct status "$PI_CTID" 2>/dev/null | grep -q "status: running" \
  || die "ollama-pi-agent CT ($PI_CTID) isn't running."
pct status "$MM_CTID" 2>/dev/null | grep -q "status: running" \
  || die "mattermost CT ($MM_CTID) isn't running."

# Read MM credentials. All four are required.
MM_BOT_TOKEN="$(read_token MATTERMOST_BOT_TOKEN || true)"
MM_BOT_USER_ID="$(read_token MATTERMOST_BOT_USER_ID || true)"
MM_TEAM_ID="$(read_token MATTERMOST_TEAM_ID || true)"
MM_URL="$(read_token MATTERMOST_URL || true)"
[[ -z "$MM_URL" ]] && MM_URL="http://mattermost:8065"

if [[ -z "$MM_BOT_TOKEN" || -z "$MM_BOT_USER_ID" || -z "$MM_TEAM_ID" ]]; then
  warn "Mattermost credentials missing from $TOKENS_FILE."
  warn "  Required: MATTERMOST_BOT_TOKEN, MATTERMOST_BOT_USER_ID, MATTERMOST_TEAM_ID"
  warn "  Got:"
  warn "    MATTERMOST_BOT_TOKEN=${MM_BOT_TOKEN:+(set)}"
  warn "    MATTERMOST_BOT_USER_ID=${MM_BOT_USER_ID:+(set)}"
  warn "    MATTERMOST_TEAM_ID=${MM_TEAM_ID:+(set)}"
  die "Re-run ./addons/setup-mattermost.sh to populate these in $TOKENS_FILE first."
fi

log "Pre-flight OK."
log "  ollama-pi-agent: CT $PI_CTID"
log "  mattermost:      CT $MM_CTID"
log "  Bridge URL:      $MM_URL"
log "  Bot user_id:     $MM_BOT_USER_ID"
log "  Team id:         $MM_TEAM_ID"

# ----- uninstall path ----------------------------------------------------
if (( UNINSTALL )); then
  log "Uninstalling pi-mattermost bridge service..."
  # Stop pi-bot first so it doesn't try to reconnect mid-uninstall
  run "pct exec $PI_CTID -- systemctl disable --now pi-bot 2>/dev/null || true"
  run "pct exec $PI_CTID -- bash -c 'tmux kill-session -t pi-bot 2>/dev/null || true'"
  run "pct exec $PI_CTID -- rm -f /etc/systemd/system/pi-bot.service"
  run "pct exec $PI_CTID -- systemctl disable --now pi-mattermost 2>/dev/null || true"
  run "pct exec $PI_CTID -- rm -f /etc/systemd/system/pi-mattermost.service"
  run "pct exec $PI_CTID -- systemctl daemon-reload"
  run "pct exec $PI_CTID -- sed -i '/PI_MATTERMOST_AUTO_CONNECT/d' /root/.bashrc"

  # Also unregister the package from pi's settings.json so it doesn't try
  # to load the (now-unconfigured) extension on next pi launch.
  if (( ! DRY_RUN )); then
    pct exec "$PI_CTID" -- bash -lc 'python3 -c "
import json, os
sp = \"/root/.pi/agent/settings.json\"
if os.path.exists(sp):
    with open(sp) as f:
        data = json.load(f)
    pkgs = data.get(\"packages\", [])
    # Remove both the canonical (npm:-prefixed) and any stale bare form
    removed = []
    for pkg in (\"npm:@whonixnetworks/pi-mattermost\", \"@whonixnetworks/pi-mattermost\"):
        if pkg in pkgs:
            pkgs.remove(pkg)
            removed.append(pkg)
    if removed:
        data[\"packages\"] = pkgs
        with open(sp, \"w\") as f:
            json.dump(data, f, indent=2)
        for pkg in removed:
            print(\"  Removed\", pkg, \"from pi settings.json.\")
" 2>/dev/null || true'
  fi

  log "Uninstalled. npm package + config + patches left in place — re-install via:"
  log "  $(basename "$0")"
  exit 0
fi

# ----- resolve pi-node path inside the CT --------------------------------
log "Resolving pi's Node binary inside ollama-pi-agent..."
NODE_BIN_DIR="$(pct exec "$PI_CTID" -- bash -lc 'ls -d /root/.local/share/pi-node/node-v*/bin 2>/dev/null | sort -V | tail -1' 2>/dev/null || true)"
if [[ -z "$NODE_BIN_DIR" ]]; then
  die "Couldn't find pi's Node install at /root/.local/share/pi-node/node-v*/bin.
  Was setup-ollama-pi.sh run successfully against ollama-pi-agent?"
fi
NODE_BIN="$NODE_BIN_DIR/node"
NPM_BIN="$NODE_BIN_DIR/npm"
log "  Node bin:  $NODE_BIN"

# Where pi's npm installs globals. Set by pi's npm config to this path.
PKG_DIR="/root/.pi/agent/npm/node_modules/@whonixnetworks/pi-mattermost"

# ----- 1. install (or update) the bridge via pi's npm --------------------
# npm's shebang is '#!/usr/bin/env node'. We wrap in 'bash -lc' so pi-node
# is on PATH (set up by setup-ollama-pi.sh's /etc/profile.d drop-in).
#
# Critical: we install LOCALLY (not -g) into /root/.pi/agent/npm. Reason:
# the bundled patches reference absolute paths under
# /root/.pi/agent/npm/node_modules/@whonixnetworks/pi-mattermost/, so the
# package has to land at that exact location for the patches to find their
# target files. `npm install -g` lands it at
# /root/.local/share/pi-node/node-vXX/lib/node_modules/ — wrong place, patches
# fail to apply.
#
# Doing `cd /root/.pi/agent/npm && npm install pkg` creates a 'local'
# install at node_modules/pkg there, matching the layout the patches expect.
log "Installing @whonixnetworks/pi-mattermost into /root/.pi/agent/npm..."
if (( ! DRY_RUN )); then
  if pct exec "$PI_CTID" -- test -d "$PKG_DIR"; then
    log "  Already installed at $PKG_DIR. Skipping npm install."
    log "  (To bump: pct exec $PI_CTID -- bash -lc 'cd /root/.pi/agent/npm && PATH=$NODE_BIN_DIR:\$PATH npm install @whonixnetworks/pi-mattermost@latest')"
  else
    run "pct exec $PI_CTID -- bash -lc 'mkdir -p /root/.pi/agent/npm && cd /root/.pi/agent/npm && PATH=\"$NODE_BIN_DIR:\$PATH\" npm install @whonixnetworks/pi-mattermost'"
  fi

  # Verify the install landed where the patches expect.
  if ! pct exec "$PI_CTID" -- test -d "$PKG_DIR"; then
    warn "Package didn't land at $PKG_DIR after install."
    warn "  npm root -g for the same invocation reports:"
    pct exec "$PI_CTID" -- bash -lc "PATH=\"$NODE_BIN_DIR:\$PATH\" npm root -g" 2>&1 | sed 's/^/    /' >&2 || true
    warn "  Wherever it landed, the bundled patches won't find their target"
    warn "  files. Investigate the actual install location and either move it,"
    warn "  or symlink it, before proceeding."
    die "Install location mismatch — refusing to proceed."
  fi
else
  printf '[dry-run] would run: pct exec %s -- bash -lc \"cd /root/.pi/agent/npm && npm install @whonixnetworks/pi-mattermost\"\n' "$PI_CTID"
fi

# ----- 2. push + apply our patches ---------------------------------------
# The community-scripts/openwebui-style debian-12 templates have an extremely
# minimal apt footprint — git and patch aren't preinstalled. Both are needed
# for the apply-chain below. Install them now (idempotent; apt no-ops on
# already-installed).
log "Ensuring 'git' and 'patch' are installed in the CT (needed for patch application)..."
run "pct exec $PI_CTID -- bash -lc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git patch >/dev/null'"

log "Pushing patches into the CT..."
run "pct exec $PI_CTID -- mkdir -p /tmp/pi-mm-patches"
for p in "$ASSETS_DIR/patches"/*.patch; do
  [[ -f "$p" ]] || continue
  run "pct push $PI_CTID '$p' /tmp/pi-mm-patches/$(basename "$p") --perms 0644"
done

log "Applying patches (skips any already applied)..."
# The patches in this repo have ABSOLUTE PATHS in their headers, e.g.:
#   --- /tmp/package/dist/extension.js
#   +++ /root/.pi/agent/npm/node_modules/@whonixnetworks/pi-mattermost/dist/extension.js
#
# Neither 'git apply -p1' nor 'patch -p1' can find their target files from
# those — -p1 strips ONE component leaving 'root/.pi/agent/.../dist/...' as
# a relative path, which doesn't exist relative to the package dir cwd.
# git apply DOES try heuristics, but they don't work for these particular
# absolute paths.
#
# Cleanest fix: rewrite each patch header to standard git-diff form
# ('--- a/<path>' / '+++ b/<path>') before applying. Then '-p1' works
# naturally. The original patch files in our repo stay unchanged — we
# transform copies inside the CT.
if (( ! DRY_RUN )); then
pct exec "$PI_CTID" -- bash -lc "
  # Rewrite patch headers in /tmp/pi-mm-patches/*.patch — only the path
  # prefixes change; timestamps + context lines stay verbatim.
  sed -i \
    -e 's|^--- /tmp/package/|--- a/|' \
    -e 's|^+++ /root/.pi/agent/npm/node_modules/@whonixnetworks/pi-mattermost/|+++ b/|' \
    /tmp/pi-mm-patches/*.patch

  cd '$PKG_DIR' || exit 1
  # Init a throwaway git repo so 'git apply' has something to operate on.
  if [ ! -d .git ]; then
    git init -q && git add -A && git -c user.email=patch@local -c user.name=patch commit -q -m 'pristine' >/dev/null
  fi
  for patch in /tmp/pi-mm-patches/*.patch; do
    name=\"\$(basename \"\$patch\")\"
    if git apply --check \"\$patch\" 2>/dev/null; then
      git apply \"\$patch\" && echo \"  ✓ \$name applied via git\"
    elif patch -p1 --dry-run < \"\$patch\" >/dev/null 2>&1; then
      patch -p1 < \"\$patch\" >/dev/null && echo \"  ✓ \$name applied via patch\"
    elif git apply --check --reverse \"\$patch\" 2>/dev/null; then
      echo \"  ⚠ \$name already applied — skipping\"
    else
      echo \"  ✗ \$name FAILED to apply (manual fix needed at $PKG_DIR)\" >&2
      echo \"     diagnostic — first lines of patch:\" >&2
      head -4 \"\$patch\" | sed 's/^/       /' >&2
      echo \"     diagnostic — git apply error:\" >&2
      git apply --check \"\$patch\" 2>&1 | sed 's/^/       /' >&2 || true
    fi
  done
"
fi

# ----- 2b. register the package in pi's settings.json --------------------
# Per pi.dev/docs/latest/packages: pi does NOT auto-scan node_modules. It
# only loads extensions from packages explicitly listed in
# ~/.pi/agent/settings.json's "packages" array. Without that registration,
# the [Extensions] header at pi startup doesn't show our package and the
# extension code never executes — even though it's on disk and patched.
#
# Equivalent CLI command: `pi install npm:@whonixnetworks/pi-mattermost`.
# We do the JSON edit directly so we don't (re)trigger pi install's own
# npm step (which could wipe our patches).
# Pi requires a SOURCE-TYPE PREFIX on package identifiers — "npm:" for npm,
# "git:" for git URLs, etc. Without the prefix, `pi list` shows the entry but
# can't resolve it to a path on disk, and pi silently fails to load the
# extension at startup. Earlier revisions of this script added a bare
# "@whonixnetworks/pi-mattermost" (no prefix). We now use the correct
# prefixed form AND strip any stale bare entry from prior runs.
log "Registering npm:@whonixnetworks/pi-mattermost in /root/.pi/agent/settings.json..."
if (( ! DRY_RUN )); then
pct exec "$PI_CTID" -- bash -lc 'python3 -c "
import json, os
sp = \"/root/.pi/agent/settings.json\"
data = {}
if os.path.exists(sp):
    try:
        with open(sp) as f:
            data = json.load(f)
    except json.JSONDecodeError:
        os.rename(sp, sp + \".bak\")
        data = {}
pkgs = data.setdefault(\"packages\", [])
canonical = \"npm:@whonixnetworks/pi-mattermost\"
legacy = \"@whonixnetworks/pi-mattermost\"
changed = False
if legacy in pkgs:
    pkgs.remove(legacy)
    changed = True
    print(\"  Removed stale bare entry (no npm: prefix).\")
if canonical not in pkgs:
    pkgs.append(canonical)
    changed = True
    print(\"  Added\", canonical, \"to packages list.\")
else:
    print(\"  Already registered correctly.\")
if changed:
    os.makedirs(os.path.dirname(sp), exist_ok=True)
    with open(sp, \"w\") as f:
        json.dump(data, f, indent=2)
"'
fi

# ----- 3. write config.toml ----------------------------------------------
log "Writing /root/.config/pi-mattermost/config.toml..."
run "pct exec $PI_CTID -- mkdir -p /root/.config/pi-mattermost /root/.local/share/pi-mattermost"
# Use 'tee' via stdin so we don't have to wrestle with heredoc-inside-pct-exec
# quoting (the TOML has [section] headers that bash double-quotes mangle).
CONFIG_BODY="$(cat <<EOF
# Generated by setup-pi-mattermost-bridge.sh — re-run the script to refresh.

[mattermost]
url = "$MM_URL"
bot_token = "$MM_BOT_TOKEN"
user_id = "$MM_BOT_USER_ID"
team_id = "$MM_TEAM_ID"
http_port = 4000

[pi]
# Default model the bridge will request from pi sessions. Override per-session
# inside pi itself if needed.
default_model = "gemma4:31b-cloud"

[resources]
max_sessions = 10
session_timeout = 7200

[database]
path = "/root/.local/share/pi-mattermost/sessions.db"

[logging]
# DEBUG surfaces all WebSocket events (with patch 01) — useful during
# initial setup. Drop to INFO once everything's working.
level = "DEBUG"
EOF
)"
if (( ! DRY_RUN )); then
  printf '%s\n' "$CONFIG_BODY" | pct exec "$PI_CTID" -- tee /root/.config/pi-mattermost/config.toml >/dev/null
  pct exec "$PI_CTID" -- chmod 600 /root/.config/pi-mattermost/config.toml
fi

# ----- 4. install the systemd unit ---------------------------------------
log "Installing /etc/systemd/system/pi-mattermost.service..."
# Render the template with our resolved paths
UNIT_BODY="$(sed \
  -e "s|%%NODE_BIN%%|$NODE_BIN|g" \
  -e "s|%%NODE_BIN_DIR%%|$NODE_BIN_DIR|g" \
  -e "s|%%PKG_DIR%%|$PKG_DIR|g" \
  "$ASSETS_DIR/pi-mattermost.service")"

if (( ! DRY_RUN )); then
  printf '%s\n' "$UNIT_BODY" | pct exec "$PI_CTID" -- tee /etc/systemd/system/pi-mattermost.service >/dev/null
fi

# ----- 5. export PI_MATTERMOST_AUTO_CONNECT in /root/.bashrc -------------
log "Ensuring PI_MATTERMOST_AUTO_CONNECT=1 is exported in /root/.bashrc..."
run "pct exec $PI_CTID -- bash -c '
  grep -q PI_MATTERMOST_AUTO_CONNECT /root/.bashrc || \
    echo \"export PI_MATTERMOST_AUTO_CONNECT=1\" >> /root/.bashrc
'"

# ----- 6. start + enable -------------------------------------------------
log "Enabling and starting the pi-mattermost service..."
run "pct exec $PI_CTID -- systemctl daemon-reload"
run "pct exec $PI_CTID -- systemctl enable pi-mattermost"
# restart (not just start) so re-runs pick up new config / unit / patches
run "pct exec $PI_CTID -- systemctl restart pi-mattermost"

# ----- 7. verify ---------------------------------------------------------
if (( ! DRY_RUN )); then
  log "Waiting for HTTP port 4000 inside the CT..."
  for i in {1..15}; do
    pct exec "$PI_CTID" -- bash -lc 'exec 3<>/dev/tcp/127.0.0.1/4000' 2>/dev/null && break
    sleep 1
  done
  if pct exec "$PI_CTID" -- bash -lc 'exec 3<>/dev/tcp/127.0.0.1/4000' 2>/dev/null; then
    log "  ✓ pi-mattermost listening on 127.0.0.1:4000"
  else
    warn "  ✗ pi-mattermost not responding on 4000 after 15s."
    warn "  Inspect: pct exec $PI_CTID -- journalctl -u pi-mattermost --no-pager -n 50"
  fi

  log "Last 10 lines of journal:"
  pct exec "$PI_CTID" -- journalctl -u pi-mattermost --no-pager -n 10 2>/dev/null | sed 's/^/    /' || true
fi

# ----- 9. pre-bind the /var/pi/bot project path to the #bot channel ------
# The auto-connect block in our patched extension falls back to projectPath
# "/var/pi/bot" when ctx.cwd is "/" (which is true under both `pct enter` and
# the systemd-spawned shell). basename("/var/pi/bot") = "bot", so we want
# pi's session to bind to the pre-existing #bot channel (display name
# "Bot Posts") that setup-mattermost.sh creates.
#
# To skip the bridge's name-based channel lookup (which would also work, but
# requires the bot token to still be valid), we pre-insert a row into the
# bridge's channel_mappings table directly. This makes inbound user posts in
# #bot route to pi immediately on first connect.
#
# Idempotent: INSERT OR REPLACE — re-running just refreshes the mapping if
# the channel id ever changes (e.g. after a Mattermost rebuild).
log "Pre-binding /var/pi/bot → #bot channel in bridge sessions.db..."
if (( ! DRY_RUN )); then
  # 9a. Make sure sqlite3 is available in the CT (debian-12 LXC templates omit it)
  pct exec "$PI_CTID" -- bash -lc 'command -v sqlite3 >/dev/null || \
    (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 >/dev/null)'

  # 9b. Look up the bot channel id from Mattermost.
  # We query from the PVE host (curl is reliably there). The MM CT is on the
  # same vmbr0 / Tailscale fabric as the PVE host, so $MM_URL resolves.
  BOT_CHANNEL_ID="$(curl -fsS \
    -H "Authorization: Bearer $MM_BOT_TOKEN" \
    "$MM_URL/api/v4/teams/$MM_TEAM_ID/channels/name/bot" 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("id",""))' \
    2>/dev/null || true)"

  if [[ -z "$BOT_CHANNEL_ID" ]]; then
    warn "  Could not look up #bot channel id from Mattermost."
    warn "  Verify: MM_URL=$MM_URL, team_id=$MM_TEAM_ID, MM_BOT_TOKEN is valid."
    warn "  Skipping channel pre-bind — pi auto-connect will fall back to the"
    warn "  bridge's name-based lookup at first session (also works, but slower"
    warn "  and depends on the bot token still being valid)."
  else
    log "  Bot channel id: $BOT_CHANNEL_ID"

    # 9c. INSERT into channel_mappings. Wait briefly for the bridge to have
    # created the DB on first start, then upsert.
    pct exec "$PI_CTID" -- bash -lc "
      for i in 1 2 3 4 5; do
        [[ -f /root/.local/share/pi-mattermost/sessions.db ]] && break
        sleep 1
      done
      if [[ -f /root/.local/share/pi-mattermost/sessions.db ]]; then
        sqlite3 /root/.local/share/pi-mattermost/sessions.db \\
          \"INSERT OR REPLACE INTO channel_mappings(project_path, channel_id, channel_name) VALUES ('/var/pi/bot', '$BOT_CHANNEL_ID', 'bot');\"
        echo '    ✓ channel_mappings row inserted'
        sqlite3 -header -column /root/.local/share/pi-mattermost/sessions.db \\
          \"SELECT * FROM channel_mappings WHERE project_path = '/var/pi/bot';\" | sed 's/^/    /'
      else
        echo '    ✗ sessions.db never created — bridge may have failed to start.' >&2
      fi
    "
  fi
fi

# ----- 10. install pi-bot.service (headless tmux-hosted pi) --------------
# Makes pi auto-start at CT boot inside a tmux session, so the Mattermost
# bridge has a session to route to even when no human has opened a pi
# terminal. Without this, the bridge sees inbound posts but has no
# registered session — messages silently drop.
#
# Why tmux? pi is a TUI and needs a pty. Raw systemd Type=simple ExecStart
# doesn't allocate one; the TUI either exits or behaves erratically.
# tmux new-session -d gives it a pty AND backgrounds itself, satisfying
# Type=forking.
#
# Skip with --no-daemon if you only want the bridge running and prefer
# manual `ollama launch pi` in `pct enter` for interactive use.
if (( WITH_DAEMON )); then
  log "Installing pi-bot.service (persistent headless pi for #bot channel)..."

  # 10a. tmux is required and not in the minimal debian-12 LXC template.
  run "pct exec $PI_CTID -- bash -lc 'command -v tmux >/dev/null || \
    (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux >/dev/null)'"

  # 10b. Resolve the model to launch pi with.
  # Order of precedence: --model CLI flag → pi's settings.json defaultModel
  # → hardcoded fallback. Without explicit --model on the launch line, pi
  # shows its interactive model picker on every daemon start — even with
  # models.json populated.
  if [[ -z "$PI_MODEL" ]]; then
    PI_MODEL="$(pct exec "$PI_CTID" -- bash -lc '
      python3 -c "
import json, sys
try:
    with open(\"/root/.pi/agent/settings.json\") as f:
        d = json.load(f)
    m = d.get(\"defaultModel\", \"\")
    print(m)
except Exception:
    pass
" 2>/dev/null
    ' 2>/dev/null || true)"
  fi
  if [[ -z "$PI_MODEL" ]]; then
    PI_MODEL="gemma4:31b-cloud"
    warn "  No defaultModel in /root/.pi/agent/settings.json — falling back to $PI_MODEL"
  fi
  log "  pi-bot will launch with model: $PI_MODEL"

  # 10c. Render the unit with our resolved Node bin dir + model.
  PI_BOT_UNIT="$(sed \
    -e "s|%%NODE_BIN_DIR%%|$NODE_BIN_DIR|g" \
    -e "s|%%PI_MODEL%%|$PI_MODEL|g" \
    "$ASSETS_DIR/pi-bot.service")"

  if (( ! DRY_RUN )); then
    printf '%s\n' "$PI_BOT_UNIT" | pct exec "$PI_CTID" -- tee /etc/systemd/system/pi-bot.service >/dev/null
    pct exec "$PI_CTID" -- systemctl daemon-reload
    pct exec "$PI_CTID" -- systemctl enable pi-bot.service 2>&1 | sed 's/^/    /' || true
    pct exec "$PI_CTID" -- systemctl restart pi-bot.service

    # Give pi a few seconds to launch + register with the bridge
    sleep 5

    # Verify the tmux session exists
    if pct exec "$PI_CTID" -- tmux has-session -t pi-bot 2>/dev/null; then
      log "  ✓ tmux session 'pi-bot' is running"
      log "    Attach with: pct exec $PI_CTID -- tmux attach -t pi-bot"
      log "    (Ctrl-b d to detach without killing the session.)"
    else
      warn "  ✗ tmux session 'pi-bot' not found after start."
      warn "    Inspect: pct exec $PI_CTID -- journalctl -u pi-bot --no-pager -n 30"
    fi

    # Confirm pi registered with the bridge
    if pct exec "$PI_CTID" -- sqlite3 /root/.local/share/pi-mattermost/sessions.db \
        "SELECT 1 FROM sessions WHERE project_path = '/var/pi/bot' LIMIT 1" 2>/dev/null | grep -q 1; then
      log "  ✓ pi session registered with bridge against /var/pi/bot"
    else
      warn "  ✗ No bridge session yet for /var/pi/bot — pi may still be starting."
      warn "    Re-check in ~30s with:"
      warn "      pct exec $PI_CTID -- sqlite3 -header -column \\"
      warn "        /root/.local/share/pi-mattermost/sessions.db \\"
      warn "        'SELECT session_id, project_path, channel_name FROM sessions'"
    fi
  fi
else
  log "Skipping pi-bot.service install (--no-daemon)."
  log "  Pi will only connect when YOU run \`ollama launch pi\` manually."
fi

# ----- done --------------------------------------------------------------
log "================================================================"
log "==> Done."
log " "
log "Bridge is now running. To use it:"
log " "
if (( WITH_DAEMON )); then
  log "  1. A persistent pi session is already running inside CT $PI_CTID"
  log "     under tmux session 'pi-bot', auto-connected to the #bot channel."
  log "     Just post in Mattermost — no need to launch pi manually."
  log " "
  log "  2. To watch / interact with the live pi session:"
  log "       pct exec $PI_CTID -- tmux attach -t pi-bot"
  log "       (Ctrl-b then d to detach — leaves pi running.)"
  log " "
  log "  3. To verify bidirectional chat:"
  log "     - Open Mattermost → Bot Posts channel"
  log "     - Post a message (e.g. '@pi-bot what files are in /root?')"
  log "     - Pi responds in the same channel"
else
  log "  1. Restart any open pi sessions so they pick up the newly-registered"
  log "     extension. (pi reads settings.json at startup only — already-running"
  log "     sessions won't see the new package until relaunched.)"
  log " "
  log "  2. Inside any pi session on ollama-pi-agent, the bridge will"
  log "     auto-connect on session start (PI_MATTERMOST_AUTO_CONNECT=1)."
  log "     Pi posts 'Auto-connecting to Mattermost (project: …)' as"
  log "     confirmation. The [Extensions] header on launch should list both:"
  log "       @ollama/pi-web-search"
  log "       @whonixnetworks/pi-mattermost"
  log " "
  log "  3. To verify end-to-end:"
  log "     - In Mattermost UI, open Bot Posts"
  log "     - Post a message there (e.g. '@pi-bot hello')"
  log "     - Pi receives it; its response posts back to the same channel"
fi
log " "
log "Channel routing:"
log "  - pi launched from / (default for the pi-bot daemon AND \`pct enter\`)"
log "    → binds to the #bot channel (display name 'Bot Posts'). Canonical."
log "  - pi launched from a project dir (cd /root/myproj && ollama launch pi)"
log "    → bridge creates a new channel named after the project basename"
log "    (e.g. 'myproj'). Useful for per-project chats."
log " "
log "Service management:"
log "  bridge:"
log "    status:   pct exec $PI_CTID -- systemctl status pi-mattermost"
log "    logs:     pct exec $PI_CTID -- journalctl -u pi-mattermost -f"
log "    restart:  pct exec $PI_CTID -- systemctl restart pi-mattermost"
if (( WITH_DAEMON )); then
log "  pi-bot daemon:"
log "    status:   pct exec $PI_CTID -- systemctl status pi-bot"
log "    attach:   pct exec $PI_CTID -- tmux attach -t pi-bot"
log "    restart:  pct exec $PI_CTID -- systemctl restart pi-bot"
fi
log "  uninstall: $(basename "$0") --uninstall"
log "================================================================"
