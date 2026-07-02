# Homepage tile convention — for pi (and humans)

Quick reference for adding a service tile to the Homepage dashboard in this
homelab. Designed to be pasted into a pi prompt or included verbatim in an
install script.

The dashboard CT is **`homepage`** (MagicDNS reachable from the tailnet at
`http://homepage:3000` or `http://homepage` if `setup-port80-redirect.sh`
is installed). It reads three YAML files from a config directory inside
the CT — for this build the path is one of:

```
/opt/homepage/config/services.yaml      ← service tiles (this doc is about this file)
/opt/homepage/config/settings.yaml      ← title, theme, group layout
/opt/homepage/config/bookmarks.yaml     ← side bookmarks
```

A few older / non-standard installs put them at `/etc/homepage/`,
`/var/lib/homepage/config/`, or `/homepage/config/`. The function below
probes all five locations and uses whichever exists, so install scripts
don't need to hardcode.

---

## The convention

Every tile that's added programmatically is wrapped in a `# TD-Addon: <slug>`
**marker comment**. The marker is what makes the registration idempotent —
re-running an install script removes the existing block with that marker
first, then appends the fresh version. Without the marker, re-runs would
either duplicate the tile or silently skip the update.

```yaml
# TD-Addon: docker-vaultwarden
- Sandbox:
    - Vaultwarden:
        href: http://sandbox:8222
        description: Self-hosted password manager
        icon: vaultwarden.png
```

The marker line is structural — keep it on its own line, immediately above
the `- <Group>:` line of the block it owns. The next `# TD-Addon:` line
(or EOF) ends the block. Don't put marker lines inside a block; the awk
surgery used by the registration function assumes one-marker-per-block.

---

## File shape

Homepage's `services.yaml` is a list of group objects. Each group's value
is a list of service tiles. Groups with the same name **merge** across the
file — so two `- Sandbox:` blocks both contribute tiles to the same on-screen
"Sandbox" section. You don't have to consolidate groups across markers.

Minimum tile fields:

```yaml
- <GroupName>:
    - <Tile Display Name>:
        href: <URL>
        description: <short caption>
        icon: <iconname>.png
```

Optional fields Homepage supports: `ping:` (display a status dot from a
TCP probe), `siteMonitor:` (HTTP healthcheck URL), `widget:` (per-service
integration — Gitea, Sonarr, etc. have native widgets).

---

## Where icons come from

Homepage bundles the [selfh.st icon set](https://selfh.st/icons/) plus
[homarr-labs/dashboard-icons](https://github.com/homarr-labs/dashboard-icons).
For most popular self-hosted apps the icon name is just the app's lowercase
name — Homepage's renderer searches both sets:

| Icon string | Source / outcome |
|---|---|
| `vaultwarden.png` | bundled — works for most well-known apps |
| `uptime-kuma.png` | bundled |
| `mdi-docker.png` | Material Design Icons (prefix `mdi-`) |
| `selfh-st-<name>.png` | force selfh.st set explicitly |
| `<URL to a PNG>` | external — used when the app's not in either set |

If pi guesses wrong and the icon doesn't render, Homepage shows a tile with
a placeholder. Easy to fix — try the alternate name or paste a URL.

---

## When tiles appear

Homepage watches its config directory and **auto-reloads** on file change,
so a `systemctl restart homepage` is *usually* unnecessary. But the build
in this homelab runs Homepage under systemd (`homepage.service` from the
community-scripts/ProxmoxVE installer), and in practice the watcher
occasionally misses appends to `services.yaml` — most reliably on the very
first run after CT boot. The registration function below issues a defensive
`systemctl restart homepage || systemctl restart gethomepage` after writing,
which is a no-op on a healthy file-watcher and a fix when the watcher
missed the change.

If pi is doing many tile updates in a tight loop, batch them (write all the
YAML first, restart once at the end) rather than restarting per tile.

---

## Reserved markers (don't collide)

Markers already used by the TD-Proxmox addons. Pi should not reuse these
slugs — pick a new one for each app:

| Marker slug | Who owns it | What it tiles |
|---|---|---|
| `pi-web-uis` | `setup-pi-web-uis.sh` | Cards UI (9090), pi terminal (9091), plain shell (9092) on ollama-pi-agent |
| `filebrowser-ollama-pi-agent` | `setup-filebrowser.sh` | filebrowser on the pi host |
| `filebrowser-sandbox` | `setup-filebrowser.sh` | filebrowser on the sandbox / Docker host |

Suggested naming for Docker apps pi installs on sandbox:
**`docker-<app>`** (e.g. `docker-vaultwarden`, `docker-uptime-kuma`,
`docker-dozzle`). Lowercase, hyphens, no spaces, no version numbers.

---

## Suggested groups

The initial `services.yaml` written by `configure-apps.sh` defines three
groups: `Development`, `AI`, `Sandbox`. For Docker apps installed on the
sandbox CT, extend the existing `Sandbox` group rather than creating a
new one — keeps everything that lives on the sandbox host visually together.

If a Docker app is conceptually a development tool (e.g. a code-review UI),
adding it to `Development` is fine too. For a brand-new category (media
server, monitoring), create a new group — Homepage handles the layout
automatically, and `settings.yaml`'s `layout:` block can tune columns
later if needed.

---

## The function — copy this into pi's install scripts

`register_homepage_tile` runs from ollama-pi-agent (where pi lives) and
SSHes into the `homepage` CT to do the file surgery. SSH trust is already
seeded by `setup-ollama-pi.sh` — pi has a key in homepage's
`authorized_keys`, so this just works without prompting.

```bash
# ----- register_homepage_tile -----------------------------------------------
# Add (or update) a service tile on the Homepage dashboard.
#
# Arguments (positional):
#   $1 slug      Unique marker slug — avoid collisions, use 'docker-<app>'
#   $2 group     Group name as it should appear (e.g. 'Sandbox')
#   $3 name      Tile display name (e.g. 'Vaultwarden')
#   $4 href      URL the tile links to (e.g. 'http://sandbox:8222')
#   $5 desc      Short description (one line, no YAML special chars)
#   $6 icon      Icon string (e.g. 'vaultwarden.png' or a full URL)
#
# Idempotent: re-running with the same slug REPLACES the existing block.
# Use a different slug for a second tile of the same app on a different port.
register_homepage_tile() {
  local slug="$1" group="$2" name="$3" href="$4" desc="$5" icon="$6"

  if [[ -z "$slug" || -z "$group" || -z "$name" || -z "$href" ]]; then
    echo "register_homepage_tile: need slug, group, name, href (icon/desc optional)" >&2
    return 2
  fi

  local marker="# TD-Addon: $slug"

  # Build the YAML block locally so variable expansion happens in the caller's
  # shell (not on the remote homepage CT).
  local yaml_block
  yaml_block=$(cat <<YAML
$marker
- $group:
    - $name:
        href: $href
        description: $desc
        icon: $icon
YAML
)

  # Pipe a bash script over ssh to homepage. The outer EOF is unquoted so
  # $marker / $yaml_block expand locally; \$VARS inside survive to the
  # remote bash.
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@homepage bash <<EOF
set -Eeuo pipefail

# Locate services.yaml — Homepage installs put it in different places.
SVCS=""
for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage /var/lib/homepage/config; do
  if [[ -f "\$d/services.yaml" ]]; then SVCS="\$d/services.yaml"; break; fi
done
[[ -n "\$SVCS" ]] || { echo "register_homepage_tile: services.yaml not found on homepage CT" >&2; exit 1; }

# If a block with our marker already exists, surgically remove it. awk: skip
# the marker line and every subsequent line until the next '# TD-Addon:'
# header (or EOF). Other addons' blocks are untouched.
if grep -qF '$marker' "\$SVCS"; then
  awk -v m='$marker' '
    \$0 ~ m { in_block=1; next }
    in_block && \$0 ~ /^# TD-Addon:/ { in_block=0 }
    !in_block { print }
  ' "\$SVCS" > /tmp/services.yaml.new && mv /tmp/services.yaml.new "\$SVCS"
fi

# Append the fresh block (with a leading blank line for visual separation).
{
  printf '\n'
  cat <<'BLOCK'
$yaml_block
BLOCK
} >> "\$SVCS"

# Defensive restart — Homepage's file watcher usually picks up changes
# automatically, but the systemd-managed install occasionally misses them.
# Service name varies by upstream version.
systemctl restart homepage 2>/dev/null || systemctl restart gethomepage 2>/dev/null || true
EOF
}
```

---

## Worked example — registering a Docker app pi just installed

```bash
# At the end of an install script for, say, Vaultwarden:
docker run -d \
  --name vaultwarden \
  --restart unless-stopped \
  -p 8222:80 \
  -v /root/uploads/vaultwarden-data:/data \
  vaultwarden/server:latest

# Register the tile on Homepage
register_homepage_tile \
  "docker-vaultwarden" \
  "Sandbox" \
  "Vaultwarden" \
  "http://sandbox:8222" \
  "Self-hosted password manager" \
  "vaultwarden.png"
```

A few more examples to cover different shapes:

```bash
# Uptime Kuma — standard tile
register_homepage_tile \
  "docker-uptime-kuma" \
  "Sandbox" \
  "Uptime Kuma" \
  "http://sandbox:3001" \
  "Status & uptime monitoring" \
  "uptime-kuma.png"

# Dozzle — logs viewer (icon falls back to a URL since dozzle.png may not
# be bundled depending on Homepage version)
register_homepage_tile \
  "docker-dozzle" \
  "Sandbox" \
  "Dozzle" \
  "http://sandbox:8888" \
  "Live container logs" \
  "https://raw.githubusercontent.com/amir20/dozzle/master/assets/logo.png"

# Code-server — register it in Development instead of Sandbox
register_homepage_tile \
  "docker-code-server" \
  "Development" \
  "code-server" \
  "http://sandbox:8443" \
  "VS Code in the browser" \
  "vscode.png"
```

---

## Validation — confirm the tile registered

After running `register_homepage_tile`, pi can verify in one shot:

```bash
# 1. The marker should be in services.yaml exactly once
ssh root@homepage 'grep -c "^# TD-Addon: docker-vaultwarden$" /opt/homepage/config/services.yaml'
# Expected output: 1

# 2. The Homepage HTTP endpoint should reload without YAML errors
ssh root@homepage 'curl -sf -o /dev/null -w "%{http_code}\n" http://localhost:3000'
# Expected output: 200
# (Anything 5xx means Homepage couldn't parse the new YAML — usually
# a stray colon in the description or an icon path with a # in it.)

# 3. Optional: visit http://homepage in a browser; the tile should appear
# in the Sandbox group.
```

If the HTTP probe is non-200, the most common cause is a description string
that contains a YAML special char (`:`, `#`, `&`, `*`, `!`, `|`, `>`, `[`,
`]`). Quote the value or escape it.

---

## When to break this convention

The function above is good for 95% of tiles. Use raw YAML editing only when:

- You need a `widget:` integration (Gitea token, Sonarr API key, etc.) —
  these need extra fields the simple function doesn't take. Hand-write the
  block and use the same `# TD-Addon: <slug>` marker convention so it's
  still updateable by re-running the script.
- You're restructuring groups (changing layout columns, theme) — that lives
  in `settings.yaml`, not `services.yaml`. Use a different marker prefix
  like `# TD-Addon-settings:` and write a separate registration function.

For the standard "Docker app on sandbox, port N, link from Homepage" pattern,
`register_homepage_tile` is the path of least surprise.
