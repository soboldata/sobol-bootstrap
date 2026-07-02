# pi-mattermost-bridge auxiliary files

Used by `addons/setup-pi-mattermost-bridge.sh`. Self-contained — no
external dependencies on a separate repo.

## Files

- **`pi-mattermost.service`** — systemd unit (system service). Adapted from
  the user-service template upstream `@whonixnetworks/pi-mattermost` ships.
  We use a system service because pi already runs as root in this homelab
  (avoids the user-service lingering complexity).
- **`patches/01-message-router-debug-logging.patch`** — adds
  `logger.debug("WS event received", ...)` so all incoming Mattermost
  WebSocket events show up in the bridge log. Useful for troubleshooting.
- **`patches/02-extension-auto-connect.patch`** — JS source of the
  `PI_MATTERMOST_AUTO_CONNECT` feature. When that env var is `1` or `true`,
  pi sessions auto-register with the bridge on `session_start`. No need to
  manually run `/connect`.
- **`patches/03-extension-ts-auto-connect.patch`** — same feature, applied
  to the TypeScript source so the patch survives a future `tsc` rebuild.

## Patch attribution

Originally developed in the user's `pi-mattermost-setup` Gitea repo. The
patches are unmodified copies; they apply against `@whonixnetworks/pi-mattermost`
v1.5.0. If the upstream package bumps, the patches may need refreshing.

## How the setup script uses these

1. Resolves pi's node-vXX bin via `ls -d /root/.local/share/pi-node/node-v*/bin`
2. Writes `pi-mattermost.service` into `/etc/systemd/system/` with
   `%%NODE_BIN%%`, `%%NODE_BIN_DIR%%`, and `%%PKG_DIR%%` substituted in
3. `npm install -g @whonixnetworks/pi-mattermost` via pi's npm (which has
   its `prefix` set to `/root/.pi/agent/npm`)
4. `pct push`es the three patches into the CT and applies them with the
   same fallback chain the user's `apply-patches.sh` used (git apply → patch)
5. Writes `~/.config/pi-mattermost/config.toml` from values in
   `/root/td-tokens.txt` (`MATTERMOST_*` keys)
6. Adds `PI_MATTERMOST_AUTO_CONNECT=1` to `/root/.bashrc` so any new pi
   session opens connected to its Mattermost mirror channel
7. `systemctl enable --now pi-mattermost`
