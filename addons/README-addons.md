# Addons

Optional scripts that layer on top of the core homelab built by [`automation/`](../automation/). Each addon is self-contained and assumes the base stack already exists — the CTs (`ollama-pi-agent`, `sandbox`, `gitea`, `openwebui`, `homepage`) are running and joined to Tailscale.

If you haven't run the automation scripts yet, start there: [automation/README-automation.md](../automation/README-automation.md).

For pi (or you, writing scripts that pi runs) registering tiles on the Homepage dashboard, see [homepage-tile-convention.md](homepage-tile-convention.md) — convention reference + a `register_homepage_tile` bash function you can paste into install scripts. Used when standing up Docker apps on `sandbox` and wanting them to appear on the dashboard.

---

## Available addons

| Script | What it does | Target | Time |
|---|---|---|---|
| [`setup-filebrowser.sh`](setup-filebrowser.sh) **(auto-installed)** | Drag-and-drop web UI for getting files into `ollama-pi-agent` (pi reads them) and `sandbox` (Dockerfiles, compose files, project source). Auto-installed by the main `configure-apps.sh` flow; this addon is for re-runs, extra targets, or opt-out via `--skip-filebrowser` | `ollama-pi-agent`, `sandbox` | ~3 min |
| [`setup-pi-web-uis.sh`](setup-pi-web-uis.sh) | Three browser UIs on `ollama-pi-agent`: cards (9090), pi terminal (9091), plain bash shell (9092) | `ollama-pi-agent` | ~5 min |
| [`setup-port80-redirect.sh`](setup-port80-redirect.sh) | Kernel-level NAT redirect so `http://gitea`, `http://openwebui`, `http://homepage` work without typing `:3000` / `:8080` | `gitea`, `openwebui`, `homepage` | ~1 min |
| [`setup-pve-etc-backup.sh`](setup-pve-etc-backup.sh) | Daily systemd timer that snapshots `/etc/pve` + host network/SSH/apt config to your backup drive (vzdump doesn't cover these) | PVE host | <1 min |
| [`setup-usb-backup.sh`](setup-usb-backup.sh) | Wipe + format + mount a USB drive as a PVE backup target. Partitions GPT + ext4, adds persistent /etc/fstab line, registers as PVE storage 'usb-backup' with 7-day daily retention. Idempotent uninstall path | PVE host | ~5 min + format time |
| [`setup-vzdump-schedule.sh`](setup-vzdump-schedule.sh) | Idempotent vzdump job in `/etc/pve/jobs.cfg` — nightly CT backups to your backup drive with sensible retention | PVE host | <1 min |
| [`setup-new-pi-agent.sh`](setup-new-pi-agent.sh) | Stand up an additional `ollama-pi-agent`-style CT from scratch — pct create + Tailscale + Ollama + pi + bidirectional SSH trust mesh + web UIs + SMB share + Homepage tile | new CT (auto-named `pi-agent-N`) | ~10 min |
| [`setup-smb-share.sh`](setup-smb-share.sh) | Expose `/root` on a pi agent over SMB so you can mount the agent's home directory from macOS Finder / Windows Explorer / Linux | `ollama-pi-agent` (default), any pi-agent | ~2 min |
| [`setup-mattermost.sh`](setup-mattermost.sh) | Stand up a Mattermost CT (self-hosted team chat) + full auto-config: admin user, enable PATs, create default team, register Homepage tile with widget. Now wires `EmailSettings` to SMTP_* from tokens so mention emails / password resets / admin invites actually deliver | new CT | ~10 min |
| [`setup-pve-email.sh`](setup-pve-email.sh) | Configure PVE host's postfix to relay through SMTP (Postmark/etc) so vzdump alerts, root cron output, subscription nag all route to `ADMIN_NOTIFY_EMAIL`. Reads SMTP_* from tokens; supports `--test-only` and `--uninstall`. Promoted from `proxmox-stack-foundations` so every stack inherits it | PVE host | ~2 min |
| [`setup-email-relay.sh`](setup-email-relay.sh) | Per-CT version of `setup-pve-email.sh`. Configures any target CT's postfix to relay through the same SMTP. Use when a CT needs to send mail directly (Gitea webhook fallbacks, in-CT cron) | any CT | ~2 min/CT |
| [`setup-pi-mattermost-bridge.sh`](setup-pi-mattermost-bridge.sh) | Wire bidirectional chat between pi (on `ollama-pi-agent`) and Mattermost. User types in a channel, pi reads + responds. Wraps `@whonixnetworks/pi-mattermost` v1.5.0 + local patches + systemd unit | `ollama-pi-agent` | ~3 min |
| [`setup-homepage-pi-widgets.sh`](setup-homepage-pi-widgets.sh) | Add two `customapi` tiles to Homepage: (1) live bridge channel-count (orphans / persisted / active), (2) most recent message in #bot. Exposes the bridge on the tailnet and installs a tiny Python proxy on the Mattermost CT to reshape MM's posts response | `ollama-pi-agent`, `mattermost`, `homepage` | ~2 min |
| [`setup-health-watchdog.sh`](setup-health-watchdog.sh) | Hourly cron checks PVE host health: disk free %, LVM thin pool fullness, RAM availability, CTs running, vzdump freshness, in-stack services active, Tailscale auth key expiry. Emails on threshold breach via the Postmark relay. Dedupe state file so a long-running alert doesn't spam every hour | PVE host | ~5 min |
| [`setup-gitea-email.sh`](setup-gitea-email.sh) | Wire Gitea's `[mailer]` section to send account verification, password resets, issue/PR watcher notifications, daily/weekly digests. Reads SMTP_* from tokens, markered block in app.ini | `gitea` | ~3 min |
| [`setup-n8n.sh`](setup-n8n.sh) | Stand up an n8n CT and **auto-wire credentials** for everything in the stack: Ollama (shared), Mattermost (pi-bot), Gitea (admin), OpenWebUI (OpenAI-compat). Imports four starter workflows (`hello-mattermost`, `mm-ollama-chat`, `gitea-daily-digest`, `gitea-events-to-mattermost`) so you can start composing instead of plumbing | new CT | ~10 min |
| [`setup-ghost.sh`](setup-ghost.sh) | Configure a Ghost CT for a customer's domain — reads `config.production.json` via python, wires SMTP + URL + external bind, restarts, idempotently runs `POST /ghost/api/admin/authentication/setup/`, registers a Homepage tile. `--wire-webhook` mode (post-MVP) wires Ghost's `post.published` webhook to n8n's `ghost-publish-to-mattermost` flow. Currently declared by the creator-studio stack; any downstream stack that composes `ghost` can inherit it | `ghost` CT | ~5 min |
| [`setup-plausible.sh`](setup-plausible.sh) | Run Plausible Community Edition via docker-compose in a Docker CT. Points DATABASE_URL at the shared Postgres CT (setup-postgres-shared.sh provisions `plausible_db`), keeps ClickHouse co-located in the same CT, hard-pins image versions, generates + persists `SECRET_KEY_BASE`. Idempotent — detects INSTALL vs RECONFIGURE mode. Post-install: browser signup → add site → mint API key → paste tracking snippet into Ghost Code Injection. Currently declared by creator-studio | `plausible` CT (Docker) | ~7 min first install |
| [`setup-calcom.sh`](setup-calcom.sh) | Run Cal.com self-hosted via docker-compose in a Docker CT. Uses shared Postgres CT (`calcom_db`), pins the calcom image + calcom/docker repo to a specific ref, generates + persists `NEXTAUTH_SECRET` + `CALENDSO_ENCRYPTION_KEY`. Runs `prisma migrate deploy` after start as belt-and-suspenders. Idempotent — detects INSTALL vs RECONFIGURE mode. Refuses to rotate the encryption key without an explicit `--redo-secrets` interactive confirm (would make encrypted DB rows unreadable). Currently declared by creator-studio | `calcom` CT (Docker) | ~10 min first install (Prisma migrations are slow) |
| [`setup-cloudflared.sh`](setup-cloudflared.sh) | THE "GO PUBLIC" MOMENT. Installs cloudflared on a small dedicated CT via the official .deb (pinned version), registers as a systemd-managed connector using `CF_TUNNEL_TOKEN`, and lets the operator manage ingress rules in the Cloudflare Zero Trust dashboard. Dashboard-first model (no local `config.yml` — see script header for rationale). Idempotent via a token-hash file: same token → SKIP; rotated token → re-register. Waits for tunnel connections at CF edge before returning success; external reachability check is a warning-not-fail (operator may still be adding public hostnames). CF API automation (auto-create tunnel + DNS records) is deferred to future | `cloudflared` CT (small — 1 CPU/512MB works) | ~3 min |
| [`setup-postgres-shared.sh`](setup-postgres-shared.sh) | Configure a shared Postgres CT with per-app databases + isolated users. **Current state:** hardcoded for creator-studio — creates `calcom_db` + `plausible_db` with random per-user passwords + writes `CALCOM_DATABASE_URL` / `PLAUSIBLE_DATABASE_URL` to tokens for the app-specific setup scripts to consume. Binds postgres to the tailnet IP only, adds a markered pg_hba block scoped per-DB per-user per-network-range, installs a daily pg_dump cron with 14-day retention. Fully idempotent. **Future:** generalize the DB list via `POSTGRES_SHARED_DBS` env var when a third stack needs a different pair | `postgres` CT | ~4 min |

---

## `setup-filebrowser.sh`

Installs [filebrowser](https://github.com/filebrowser/filebrowser) on **both `ollama-pi-agent` and `sandbox`** by default and exposes `/root/uploads/` as a drag-and-drop web UI on each (`http://ollama-pi-agent:8080`, `http://sandbox:8080`). Drop a PDF or markdown file into the pi host's UI, immediately reference it in a pi prompt like `"summarize the PDF in /root/uploads/"` — no scp, no rsync, no sftp client. Drop a Dockerfile or compose file into the sandbox UI, then `ssh root@sandbox` and `cd uploads` to use it.

**What you get:**

- Single 20 MB Go binary running as a systemd service inside each target CT
- Web UI: drag-drop upload, folder navigation, in-browser text edit, file preview
- JSON-file auth with one admin user (same credentials across both instances), JWT sessions
- Files land at `/root/uploads/` on each target — pi reads from the `ollama-pi-agent` instance; Docker / `ssh root@sandbox` workflows use the `sandbox` instance
- Auto-registers a Homepage tile per instance (separately updateable via per-target `# TD-Addon:` marker)

**Prereqs:**

- `ollama-pi-agent` and `sandbox` CTs exist and are running (from `bootstrap-pve.sh`)
- Tailscale is up on each CT (so `http://ollama-pi-agent:8080` and `http://sandbox:8080` resolve via MagicDNS)
- You have admin creds you want to use for the filebrowser login (shared across both instances)

**Install:**

```bash
# On the PVE host — installs on both ollama-pi-agent and sandbox
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/addons/setup-filebrowser.sh \
  -o /root/setup-filebrowser.sh
chmod +x /root/setup-filebrowser.sh
/root/setup-filebrowser.sh
```

To install on only one of them:

```bash
/root/setup-filebrowser.sh --target ollama-pi-agent      # pi host only
/root/setup-filebrowser.sh --target sandbox              # docker host only
```

The script prompts once for:
1. Admin username (e.g. `td`)
2. Admin password (hidden, confirmed twice, min 8 chars)

…then iterates over each target, installs the binary, initializes `/etc/filebrowser/filebrowser.db`, creates the admin user, drops a systemd unit, and starts the service.

**Or from your own Gitea (after first push):**

```bash
curl -fsSL http://gitea:3000/<your-gitea-user>/td-proxmox/raw/branch/main/addons/setup-filebrowser.sh \
  -o /root/setup-filebrowser.sh
```

**Flags for unusual cases:**

| Flag | Default | What it does |
|---|---|---|
| `--target NAME` | `ollama-pi-agent` + `sandbox` | Hostname to install on (repeatable; replaces the default list) |
| `--hostname NAME` | — | Back-compat alias for `--target` |
| `--ct-id N` | (hostname lookup) | Target a CT by ID (only valid with one `--target`) |
| `--root <path>` | `/root/uploads` | Filesystem path the UI exposes (applies to every target) |
| `--port <n>` | `8080` | Port filebrowser listens on inside each CT |
| `--admin-user <name>` | (prompt) | Skip the prompt |
| `--admin-password <pw>` | (prompt) | Skip the prompt |
| `--dry-run` | — | Preview commands without running them |

**After install:**

Open `http://ollama-pi-agent:8080` or `http://sandbox:8080` from any device on your tailnet, log in, drag files into the browser. They appear at `/root/uploads/` inside the corresponding CT.

The Homepage `services.yaml` gets one tile per filebrowser instance, each guarded by its own `# TD-Addon: filebrowser-<hostname>` marker, so re-running the addon updates only the relevant tile and leaves the other untouched.

**Idempotent.** Re-running detects each existing install and updates the admin user's password rather than failing. Safe to invoke again whenever you want to rotate credentials or add a new target.

---

---

## `setup-pi-web-uis.sh`

Installs **three** browser UIs side-by-side on `ollama-pi-agent`:

- **Port 9090 — cards UI** ([VVander/pi-remote-web-ui](https://github.com/VVander/pi-remote-web-ui)). Purpose-built for pi: tool outputs render as expandable cards, thinking blocks are surfaced separately, multiple browser tabs share one session via WebSocket. Uses pi's `AgentSession` SDK in-process (the upstream-recommended pattern, no subprocess spawning).
- **Port 9091 — pi terminal** ([ttyd](https://github.com/tsl0922/ttyd) wrapping `ollama launch pi`). xterm.js in a browser tab. Same experience as `pct enter 200 && ollama launch pi`. HTTP basic auth.
- **Port 9092 — plain shell** (ttyd wrapping `bash` at `/root`). Same `pct enter 200` experience without auto-launching pi — useful for `git`/`curl`/file inspection/log tail-ing or just kicking the CT around. HTTP basic auth.

Why all three: the cards UI is nicer for day-to-day pi prompting (tool calls don't blow past your scrollback, thinking is collapsed), the pi terminal is a bulletproof fallback when the cards UI doesn't render some new feature, and the plain shell is for everything that isn't agent-driven (debugging, inspection, manual commands).

**Prereqs:**

- `ollama-pi-agent` CT exists, is running, and has pi installed (from `setup-ollama-pi.sh` — the cards UI reuses pi's bundled Node.js install)
- Tailscale is up on the CT (so `http://ollama-pi-agent:9090` and `:9091` resolve via MagicDNS)

**Install:**

```bash
# On the PVE host
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/addons/setup-pi-web-uis.sh \
  -o /root/setup-pi-web-uis.sh
chmod +x /root/setup-pi-web-uis.sh
/root/setup-pi-web-uis.sh
```

The script prompts for an admin username + password (used for the ttyd basic auth on the terminal UI; the cards UI has no built-in auth and relies on your tailnet boundary).

**What it does, step by step:**

1. `apt install` git, ttyd, build-essential inside the CT.
2. Clones `pi-remote-web-ui` to `/opt/pi-remote-web-ui`, runs `npm install && npm run build && npm run build:server` using pi's standalone Node (`/root/.local/share/pi-node/node-v*/bin/node` — no second Node install).
3. Patches the upstream's `127.0.0.1:8080` bind to `0.0.0.0:9090` so the cards UI is reachable across the tailnet. (VVander's default was designed for SSH-tunneled access on a VPS; tailnet is our security boundary instead.)
4. Drops `pi-cards.service` (cards UI) and `pi-term.service` (ttyd) as systemd units, enables both.
5. Verifies both services are running.
6. Prints Homepage tile YAML for both ports.

**Flags for unusual cases:**

| Flag | Default | What it does |
|---|---|---|
| `--ct-id N` | (hostname lookup) | Target a CT by ID instead of looking up `ollama-pi-agent` |
| `--hostname X` | `ollama-pi-agent` | Look up a CT by a different hostname |
| `--cards-port N` | `9090` | Port for the cards UI |
| `--term-port N` | `9091` | Port for the pi terminal UI |
| `--shell-port N` | `9092` | Port for the plain shell UI |
| `--admin-user <name>` | (prompt) | Skip the prompt |
| `--admin-password <pw>` | (prompt) | Skip the prompt |
| `--only cards` | — | Install only the cards UI |
| `--only terminal` | — | Install only the pi terminal UI |
| `--only shell` | — | Install only the plain shell UI |
| `--only cards,shell` | — | Combine subsets |
| `--dry-run` | — | Preview commands |

**Security note.** The cards UI has no built-in authentication — it inherits trust from whoever can reach port 9090 on the tailnet. For a personal homelab with a closed tailnet that's fine. If you have multiple tailnet users and want to restrict the cards UI further, the easiest fix is a Tailscale ACL rule limiting port 9090 to your own user. ttyd on 9091 has HTTP basic auth as a second layer.

**Idempotent.** Re-running detects an existing clone and `git pull`s the latest. Systemd units are recreated and restarted.

---

---

## `setup-port80-redirect.sh`

Lets you type `http://gitea` instead of `http://gitea:3000`. Same for `http://openwebui` and `http://homepage`. The apps stay on their high ports; the kernel quietly rewrites incoming `:80` traffic to the real port before it reaches the app.

**Why these defaults exist in the first place.** Ports below 1024 (the "privileged" range) require root or `CAP_NET_BIND_SERVICE` on Linux. Modern web apps run as a dedicated unprivileged user for security, so they default to higher ports (3000, 8080) that don't need elevated permissions. In a Docker / multi-tenant world this is normal — you put a reverse proxy on 80 and route to the apps' high ports. Our "one CT per app + Tailscale MagicDNS" homelab is the unusual case where typing the port is friction without payoff.

**How it works.** A single `iptables` NAT rule per CT:

```
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3000
```

That tells the kernel: rewrite the destination port of any incoming TCP packet bound for :80 to :3000 before the app sees it. The app itself is unchanged — it keeps listening on 3000 and never knows. Both URLs work: `http://gitea` and `http://gitea:3000`. A small systemd oneshot re-applies the rule on every boot so it survives reboots without needing `iptables-persistent`.

**Targets:**

| Hostname | Redirect |
|---|---|
| `gitea` | 80 → 3000 |
| `openwebui` | 80 → 8080 |
| `homepage` | 80 → 3000 |

`sandbox` and `ollama-pi-agent` aren't included because they don't have a single obvious "primary" web service — `ollama-pi-agent` runs filebrowser on 8080 alongside pi UIs on 9090–9092, and `sandbox` runs filebrowser on 8080 plus whatever Docker workloads you spin up. Pinning one to port 80 would mask the rest.

**Install:**

```bash
# On the PVE host
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/addons/setup-port80-redirect.sh \
  -o /root/setup-port80-redirect.sh
chmod +x /root/setup-port80-redirect.sh
/root/setup-port80-redirect.sh
```

No prompts. Loops over each `hostname:port` pair in the script's `REDIRECTS=(...)` array, finds the CT, applies the rule, drops a systemd unit. Idempotent — re-running checks for the rule with `iptables -C` before adding, so no duplicate rules pile up.

**Test from your workstation:**

```bash
curl -sI http://gitea  | head -1   # Should be 200 / 302 / 303 (Gitea login redirect)
curl -sI http://homepage | head -1
```

**Uninstall:**

```bash
/root/setup-port80-redirect.sh --uninstall
```

Removes the systemd unit and deletes the iptables rule from each CT. The apps continue to work on their original ports.

**Flags:**

| Flag | What it does |
|---|---|
| `--uninstall` | Reverse the changes (remove rules + units, leave apps untouched) |
| `--dry-run` | Print commands without executing |

**Extending.** To add another CT, edit the `REDIRECTS=(...)` array at the top of the script. Each entry is `hostname:port`. To add SSL termination later, the natural upgrade is to drop a small reverse proxy (Caddy is a one-binary fit) on each CT and let it handle 80 → 443 + auto-HTTPS via Tailscale's MagicDNS certificates.

---

## `setup-pve-etc-backup.sh`

Installs a daily systemd timer on the **PVE host itself** (not a CT) that snapshots PVE's host-level configuration to a compressed tarball on your backup drive. Closes a gap in `vzdump`: vzdump backs up CT *data* but not PVE's own state, so a fresh PVE install from a CT-only backup can't even mount the backup drive without redoing every storage definition by hand.

**What's in each tarball:**

- `/etc/pve` — cluster, storage, ACL, user db (PVE's FUSE config)
- `/var/lib/pve-cluster/config.db` — the sqlite DB behind `/etc/pve`
- `/etc/network/interfaces` + `interfaces.d/` — `vmbr0`, bonds, VLANs
- `/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf`
- `/etc/ssh/ssh_host_*_key*` — host keys (preserve fingerprints across rebuilds)
- `/etc/ssh/sshd_config` — sshd policy
- `/root/.ssh/` — admin authorized_keys + any private keys you keep there
- `/etc/apt/sources.list` + `/etc/apt/sources.list.d/` — deb822 `.sources` files written by `bootstrap-pve.sh`

Format: zstd-compressed tar, named `pve-etc-<hostname>-<YYYYMMDD-HHMMSS>.tar.zst` (matches vzdump's default compression). Typical size: a few MB.

**Prereqs:**

- USB / external backup drive mounted somewhere persistent (see [the USB backup walkthrough](#setting-up-a-usb-drive-as-a-backup-target) below if you haven't done this yet)
- Default backup path is `/mnt/pve-backup/etc-snapshots/` — pass `--backup-dir` if yours is elsewhere

**Install:**

```bash
# On the PVE host
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/addons/setup-pve-etc-backup.sh \
  -o /root/setup-pve-etc-backup.sh
chmod +x /root/setup-pve-etc-backup.sh
/root/setup-pve-etc-backup.sh --run-now
```

`--run-now` triggers one immediate run after installing the timer, so you see a tarball land before you walk away. End state: a daily 01:30 timer, last 14 tarballs retained per host, on-target backup directory.

**Flags:**

| Flag | Default | What it does |
|---|---|---|
| `--backup-dir PATH` | `/mnt/pve-backup/etc-snapshots` | Where tarballs land |
| `--keep N` | `14` | How many tarballs to retain per host (oldest pruned) |
| `--time HH:MM` | `01:30` | Daily run time (set 30 min before your vzdump window) |
| `--run-now` | — | Trigger one immediate run after install |
| `--dry-run` | — | Preview commands without executing |

**Safety: mount check before write.** The backup script `mountpoint -q`s the backup directory's parent before writing anything. If the USB drive is unplugged or unmounted, the run exits 0 with a "skipped" log line — it will never silently dump a tarball into the host's root filesystem and fill `/`.

**Verify:**

```bash
systemctl list-timers pve-etc-backup.timer
journalctl -u pve-etc-backup.service -n 30 --no-pager
ls -lh /mnt/pve-backup/etc-snapshots/
```

**Restore (after a host rebuild):**

```bash
# After installing PVE on a fresh disk, mount your backup drive, then:
cd /mnt/pve-backup/etc-snapshots
ls -lt pve-etc-*.tar.zst | head -1                    # find the latest
# Inspect first:
tar --zstd -tf pve-etc-<host>-<stamp>.tar.zst | less
# Selectively restore /etc/pve (PVE must be stopped):
systemctl stop pve-cluster
tar --zstd -xf pve-etc-<host>-<stamp>.tar.zst -C / etc/pve
systemctl start pve-cluster
```

For most fields (`/etc/network/interfaces`, `/root/.ssh/`, apt sources) you can extract straight into `/` while PVE is running.

---

## `setup-vzdump-schedule.sh`

Installs a nightly `vzdump` job into `/etc/pve/jobs.cfg` so PVE backs up every CT to your backup drive automatically. Complements `setup-pve-etc-backup.sh`: that script captures the *host* config (the PVE identity), this one captures the *CT data* (root filesystems, running state). Together they make a fresh PVE install + USB drive a complete restore source.

PVE picks up changes to `jobs.cfg` automatically — no daemon restart, no GUI fiddling.

**Defaults** (matched to the rest of this stack):

| Setting | Default | Why |
|---|---|---|
| Schedule | `02:00` daily | 30 min after `setup-pve-etc-backup`'s 01:30 default — config snapshot lands first |
| Storage | `pve-backup` | The USB drive registered by the storage walkthrough below |
| Mode | `snapshot` | Live backup on LVM-thin; CT stays running with near-zero pause |
| Compression | `zstd` | Same format as the host-config tarball; fast + small |
| Retention | `keep-daily=7, keep-weekly=4, keep-monthly=2` | ~13 backups, predictable disk usage |
| Includes | `all` | Every CT (and any VMs you add later) |
| Job ID | `td-nightly` | Lets the script find + replace its own block on re-run |

**Install:**

```bash
# On the PVE host
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/addons/setup-vzdump-schedule.sh \
  -o /root/setup-vzdump-schedule.sh
chmod +x /root/setup-vzdump-schedule.sh
/root/setup-vzdump-schedule.sh
```

End state: a `vzdump: td-nightly` stanza in `/etc/pve/jobs.cfg`, scheduled for tomorrow 02:00. To verify in the GUI: Datacenter → Backup, you should see one row labeled `td-nightly`.

To run a backup immediately (foreground, takes a while depending on your CT sizes):

```bash
/root/setup-vzdump-schedule.sh --run-now
```

**Flags:**

| Flag | Default | What it does |
|---|---|---|
| `--job-id ID` | `td-nightly` | Stanza identifier used for idempotent updates |
| `--storage NAME` | `pve-backup` | Backup storage target (must include `backup` in its content types) |
| `--schedule HH:MM` | `02:00` | Daily run time |
| `--mode KIND` | `snapshot` | `snapshot` (live) / `suspend` (brief pause) / `stop` (clean) |
| `--compress KIND` | `zstd` | `zstd` / `gzip` / `lzo` / `none` |
| `--retention SPEC` | `keep-daily=7,keep-weekly=4,keep-monthly=2` | PVE retention spec |
| `--include SPEC` | `all` | `all` / `pool:<name>` / comma-separated CT IDs (e.g. `100,102,200`) |
| `--mailto EMAIL` | — | Send notifications to an address |
| `--notify-mode MODE` | `failure` | `failure` or `always` — paired with `--mailto` |
| `--run-now` | — | Trigger one immediate backup after writing the job |
| `--uninstall` | — | Remove the job stanza from `jobs.cfg` |
| `--dry-run` | — | Preview without writing |

**Pre-flight checks:** the script verifies the storage target exists and has `backup` listed in its content types before touching `jobs.cfg`. A common gotcha is registering a directory storage with only `iso,vztmpl` content and then trying to use it for backups — the script catches that and tells you how to fix it (`pvesm set <name> --content backup,iso,vztmpl`).

**Idempotent:** re-running with different flags updates the existing stanza rather than appending a duplicate. The job-id is the key — if you want a second vzdump job (say, weekly backups of a specific pool), invoke with a different `--job-id`.

**Uninstall:**

```bash
/root/setup-vzdump-schedule.sh --uninstall
```

Removes the stanza; existing backup files on the drive are untouched.

**Restore drill — worth doing once:**

```bash
# Pick a small CT (sandbox is ~300 MB)
CTID=$(pct list | awk '/sandbox/ {print $1}')
LATEST=$(ls -t /mnt/pve-backup/dump/vzdump-lxc-$CTID-*.tar.zst | head -1)

# Restore into a throwaway CTID
pct restore 999 "$LATEST" --storage local-lvm --hostname sandbox-restore-test
pct start 999
pct exec 999 -- hostname && pct exec 999 -- docker ps
pct destroy 999 --purge
```

Untested backups are wishes, not backups.

---

## `setup-new-pi-agent.sh`

Stand up an additional `ollama-pi-agent`-style CT from scratch. The first one was created by `bootstrap-pve.sh` as part of the homelab build; this addon lets you spin up more later (a research agent, a sandbox agent, a per-project agent) without re-running the whole bootstrap.

End state per invocation: a new Debian 12 LXC named `pi-agent-N` (auto-numbered) joined to Tailscale, with Ollama + pi installed, browser UIs on 9090/9091/9092, bidirectional SSH trust with every other existing CT, and a Homepage tile under the AI group.

**Default behavior** (no flags):

1. Auto-pick the next available `pi-agent-N` hostname (`pi-agent-2`, `pi-agent-3`, ...)
2. Auto-allocate the next CTID via `pvesh get /cluster/nextid`
3. Create a CT with the same resources as the original `ollama-pi-agent`: 4 CPU / 4 GB RAM / 20 GB disk, unprivileged, `nesting=1`
4. Install Tailscale and join the tailnet under the new hostname
5. Push the PVE host's workstation `authorized_keys` so you can `ssh root@<new-hostname>` from your laptop immediately
6. Delegate to `setup-ollama-pi.sh --ct-id <new>` for Ollama install, ollama.com signin (one browser click), model pull, and pi install
7. Wire the bidirectional SSH trust mesh — new agent's pubkey lands in every other pi agent's `authorized_keys`, and every other pi agent's pubkey lands in the new one's, plus `ssh-keyscan` pre-seeds `known_hosts` both directions so first SSHes don't prompt
8. Delegate to `setup-pi-web-uis.sh --hostname <new>` for the cards/term/shell UIs (per-target Homepage markers added so multiple agents coexist on the dashboard)
9. Register a "machine" tile on Homepage in the AI group, linking to the agent

**Prereqs:**

- TD-Proxmox homelab already built (`bootstrap-pve.sh` finished — at minimum the original `ollama-pi-agent` exists, since this is the trust-mesh anchor)
- A workstation SSH key in PVE's `/root/.ssh/authorized_keys` (same source bootstrap-pve.sh uses)
- A Tailscale auth key from <https://login.tailscale.com/admin/settings/keys> (prompted if `--ts-authkey` not given)
- The td-proxmox repo cloned on the PVE host (the script delegates to sibling scripts at `../automation/setup-ollama-pi.sh` and `./setup-pi-web-uis.sh`)

**Install:**

```bash
# On the PVE host, inside your td-proxmox clone
./addons/setup-new-pi-agent.sh                              # auto everything
./addons/setup-new-pi-agent.sh --hostname pi-agent-research # explicit name
./addons/setup-new-pi-agent.sh --hostname pi-agent-fast \
    --cpu 8 --ram 8192 --disk 40 \
    --model gemma3:12b-cloud                                # bigger box, lighter model
./addons/setup-new-pi-agent.sh --with-filebrowser           # plus filebrowser on 8080
./addons/setup-new-pi-agent.sh --skip-web-uis --skip-homepage-tile  # bare Ollama+pi only
```

**Flags:**

| Flag | Default | What it does |
|---|---|---|
| `--hostname NAME` | `pi-agent-N` (auto) | Explicit hostname |
| `--ctid N` | auto via `pvesh` | Explicit CTID |
| `--cpu N` | `4` | CPU cores |
| `--ram MB` | `4096` | Memory (MB) |
| `--disk GB` | `20` | Root disk (GB) |
| `--model NAME` | setup-ollama-pi default | Ollama model to pull |
| `--ts-authkey KEY` | (prompt) | Skip the Tailscale auth-key prompt |
| `--ct-password PW` | (prompt) | Skip the CT root password prompt |
| `--skip-web-uis` | — | Don't install cards/term/shell (and don't register their Homepage tiles) |
| `--with-filebrowser` | — | Also install filebrowser at port 8080 |
| `--skip-trust-mesh` | — | Don't wire SSH trust to/from existing CTs |
| `--skip-homepage-tile` | — | Don't register the agent's machine tile (UI tiles still register unless `--skip-web-uis`) |
| `--dry-run` | — | Print every command without executing |

**SSH trust mesh details:** the script scans for existing pi-style CTs (`ollama-pi-agent`, `pi-agent-2`, `pi-agent-3`, ... up to `pi-agent-9`) and for each one it finds:

1. Appends the new agent's `id_ed25519.pub` to the peer's `/root/.ssh/authorized_keys`
2. Appends the peer's `id_ed25519.pub` to the new agent's `/root/.ssh/authorized_keys`
3. Runs `ssh-keyscan` in both directions to pre-trust host keys

End state: any pi can `ssh root@<other-pi>` without password or fingerprint prompts. This is on top of the "outbound only" trust mesh `setup-ollama-pi.sh` already seeds to the service CTs (`sandbox`/`gitea`/`openwebui`/`homepage`).

**Homepage layout with multiple agents:** each pi agent's three browser UIs land in their own group, e.g. `Pi (ollama-pi-agent)` with Cards/Terminal/Shell inside, and `Pi (pi-agent-2)` with its own Cards/Terminal/Shell. The marker is `pi-web-uis-<hostname>` per agent so re-runs only touch the relevant block. Plus one "machine" tile per agent in the AI group (marker `pi-agent-machine-<hostname>`).

**Idempotent at the addon-script level**, not at the CT level. If you re-run with the same `--hostname`, the script aborts because that CT already exists. To update an existing agent's config, run the relevant sub-addon directly: `setup-ollama-pi.sh --ct-id <N>` for re-install, `setup-pi-web-uis.sh --hostname <h>` for UI changes. The Homepage tile registration *is* marker-idempotent — re-registering replaces the existing block rather than appending a duplicate.

---

## `setup-smb-share.sh`

Exposes a pi agent's `/root` over SMB so you can mount the agent's home directory from your laptop's Finder (macOS), File Explorer (Windows), or `gio mount` / `mount.cifs` (Linux). Eliminates the scp / sftp / rsync friction when you want to edit pi's configs, drop files in, or browse what pi has produced.

Auto-installed by `setup-new-pi-agent.sh` for every new agent (opt out with `--skip-smb-share`). For the original `ollama-pi-agent` from `bootstrap-pve.sh`, run this addon once manually as a post-bootstrap step.

**Config:**

- Single share named `home` exposing `/root` (everything — including `.ssh/`, `.local/share/pi-node/`, `.ollama/`, `uploads/`, anything else)
- Auth: Samba user `root` with a password. Files on disk remain owned by `root` at the filesystem layer regardless of which client mounts the share.
- Bind: `smbd` listens on all interfaces, so the share is reachable from both Tailscale (`smb://ollama-pi-agent/home`) and your local LAN (`smb://<lan-ip>/home`).
- macOS Finder compatibility: `vfs objects = catia fruit streams_xattr` plus `fruit:metadata = stream` etc., so `.DS_Store` and resource forks don't pollute the filesystem and extended attributes round-trip correctly.

**Mount instructions per platform:**

| Platform | How |
|---|---|
| macOS | Finder → `Cmd-K` → `smb://ollama-pi-agent/home` → connect as `root` |
| Windows | Run → `\\ollama-pi-agent\home` → username `root` |
| Linux (gvfs) | `gio mount smb://ollama-pi-agent/home` |
| Linux (cifs) | `mount.cifs //ollama-pi-agent/home /mnt/foo -o username=root` |

**Install (for the original `ollama-pi-agent`, post-bootstrap):**

```bash
# On the PVE host
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/addons/setup-smb-share.sh \
  -o /root/setup-smb-share.sh
chmod +x /root/setup-smb-share.sh
/root/setup-smb-share.sh
```

Prompts for an SMB password (twice for confirmation; minimum 6 chars). For convenience, use the same password as your CT root password so you only have one credential to remember. Files land on disk with their root ownership preserved.

**Flags:**

| Flag | Default | What it does |
|---|---|---|
| `--target NAME` | `ollama-pi-agent` | Hostname to install on (repeatable) |
| `--hostname NAME` | — | Back-compat alias for `--target` |
| `--ct-id N` | (hostname lookup) | Target a CT by ID (only valid with one `--target`) |
| `--share-name NAME` | `home` | SMB share name (mount path: `smb://host/<name>`) |
| `--share-path PATH` | `/root` | Filesystem path the share exposes |
| `--password PW` | (prompt) | Skip the password prompt |
| `--workgroup NAME` | `WORKGROUP` | SMB workgroup |
| `--dry-run` | — | Preview without executing |

**Auto-installed by `setup-new-pi-agent.sh`:** when you spin up a new agent, the script reuses the CT root password you already entered as the SMB password (so the new agent's `smb://pi-agent-2/home` mount works with the same password the script just set). Pass `--skip-smb-share` to opt out.

**Idempotent.** Re-running detects the existing config (managed via `# TD-SMB-SHARE: <name> START/END` markers in `/etc/samba/smb.conf`), strips the old block, and writes a fresh one. Resets the SMB password too. Safe to invoke whenever you want to rotate credentials or change the share path.

**Verify after install:**

```bash
# From PVE host
pct exec $(pct list | awk '/ollama-pi-agent/ {print $1}') -- smbstatus --shares
# Should list 'home' as available

# From a tailnet device — macOS smoke test
smbutil view -g //root@ollama-pi-agent
# Prompts for password, then lists [home]
```

**Security notes:**

- Anyone on your tailnet (or LAN) can attempt to mount with the SMB password — Tailscale ACLs don't filter port 445 traffic. If you have untrusted devices on your tailnet, consider running `setup-port80-redirect.sh`-style iptables rules to gate `tcp/445` to specific tailnet IPs.
- The SMB user is named `root` but the password is independent of the Linux root password. Changing one doesn't change the other.
- For higher security, switch to a dedicated `pi` SMB user — but you'll need to align Samba's `valid users` and `force user` directives. Edit the script's heredoc directly if you want this shape.

---

## `setup-mattermost.sh`

Stand up a Mattermost CT (self-hosted team chat) with full auto-config so the dashboard tile, admin account, default team, and bot identity are all wired in before you ever open the web UI. Communication side of the homelab — gives you a place for build-status pings, job-completion notifications from pi, and human chat all in one app.

End state per invocation: a new CT named `mattermost`, joined to the tailnet, Mattermost running, admin user created (system admin via the first-signup convention), personal access tokens enabled, a `TD Homelab` team created with the admin and a dedicated `pi-bot` account in it, a `#bot` channel populated, and a Homepage tile (with the native `mattermost` widget) registered.

**What gets created:**

| Entity | Where | Purpose |
|---|---|---|
| New CT `mattermost` | via community-scripts/ct/mattermost.sh | Hosts the Mattermost server (port 8065) |
| Admin user `td` (or whatever your homelab admin user is) | inside Mattermost | Logs into the UI, owns the Homepage widget PAT |
| Team `TD Homelab` | inside Mattermost | Default team — URL slug `td-homelab` |
| Bot account `pi-bot` ("pi (bot)") | inside Mattermost, added to team | Identity pi uses for automated posts |
| Channel `#bot` (public) | inside the team, pi-bot added | Default place for automated posts |
| Admin PAT | written to `/root/td-tokens.txt` as `MATTERMOST_TOKEN` | Used by Homepage widget |
| Bot PAT | written to `/root/td-tokens.txt` as `MATTERMOST_BOT_TOKEN` | Used by pi automation |
| Homepage tile | services.yaml Communication group | Dashboard entry with live widget |

**Prereqs:**

- A working homelab (bootstrap finished, Tailscale up, Homepage CT alive)
- A reusable Tailscale auth key (the new CT joins the tailnet) — script reads from `/etc/td-proxmox/.vars` if present, else prompts
- `/root/td-tokens.txt` should exist (written by `configure-apps.sh`) — the script reads admin user/email/password from it so Mattermost reuses the same credentials as Gitea + OpenWebUI. Falls back to interactive prompt if the file isn't there.

**Install:**

```bash
# On the PVE host, inside your td-proxmox clone
./addons/setup-mattermost.sh
```

The community-scripts helper's whiptail menu will appear — pick **Default Install** and hit Enter. The script handles everything after that automatically. About 10 minutes total.

**Flags:**

| Flag | Default | What it does |
|---|---|---|
| `--hostname NAME` | `mattermost` | CT hostname |
| `--ctid N` | auto via `pvesh` | Explicit CTID |
| `--cpu N` | `2` | CPU cores |
| `--ram MB` | `4096` | Memory (MB) |
| `--disk GB` | `16` | Root disk (GB) |
| `--admin-user NAME` | from td-tokens.txt or prompt | Mattermost admin username |
| `--admin-email EMAIL` | from td-tokens.txt or prompt | Admin email |
| `--admin-password PW` | from td-tokens.txt or prompt | Admin password (min 8 chars) |
| `--team-name NAME` | `TD Homelab` | Default team display name (URL slug derived) |
| `--ts-authkey KEY` | from .vars or prompt | Tailscale auth key |
| `--ct-password PW` | (prompt) | CT root password |
| `--skip-homepage-tile` | — | Don't register the Homepage tile |
| `--skip-tailscale` | — | Don't join the new CT to the tailnet (LAN-only access) |
| `--dry-run` | — | Preview everything without executing |

**Mattermost-specific quirks handled by the script:**

1. **Personal access tokens are disabled by default.** The script enables them via `PUT /api/v4/config` (sets `ServiceSettings.EnableUserAccessTokens=true`) and restarts Mattermost before minting any tokens.
2. **Email verification is disabled** in the same config PUT (`EmailSettings.RequireEmailVerification=false`) so the admin can log in immediately after signup without an email-loop.
3. **First-user-becomes-admin** — Mattermost's convention is that the first signup on a fresh install gets system-admin privileges. The script signs up the admin user before anything else; if signup returns "username exists" it falls through to login (handles re-runs gracefully).
4. **The bot is added to the team AND the channel separately.** Mattermost requires explicit `team/members` and `channels/members` membership for a bot to post anywhere — adding to one doesn't grant the other.
5. **`SiteURL` defaults to the CT IP and breaks multi-hostname access.** Mattermost auto-populates `ServiceSettings.SiteURL` with the URL the installer was reached at (typically `http://<ct-ip>:8065`). With a non-empty SiteURL, Mattermost's WebSocket handler does a Host/Origin check on every WS upgrade — accessing via any other name (MagicDNS `mattermost:8065`, Tailscale FQDN, a reverse proxy hostname) causes the client to retry-loop with `disconnect_err_code=1006` and lose typing indicators + real-time updates. The script clears `SiteURL=""`, `WebsocketURL=""`, and sets `AllowCorsFrom="*"` in the same config PUT, so Mattermost trusts the request host and plugin AJAX calls don't trip CORS. Safe inside a tailnet because access is already auth-gated; if you ever expose Mattermost externally, set `AllowCorsFrom` to a specific origin list.
6. **Built-in plugins (mattermost-ai, playbooks, calls) cache SiteURL at startup.** If you change SiteURL on a live install, disable + re-enable the plugins in **System Console → Plugin Management** so they pick up the new value. Otherwise plugin AJAX requests keep hitting the old hardcoded URL and you'll see CORS errors in the console.

**After install — log into Mattermost:**

Open `http://mattermost:8065` in a browser:

- Sign in with your homelab admin user + password
- You land directly in the **TD Homelab** team, inside Town Square
- Sidebar shows a `#bot` channel (created automatically) — that's where pi's automated posts go by default

**After install — let pi know about it:**

```bash
# Re-run configure-apps.sh's pi step so AGENTS.md gets the Mattermost section
./automation/configure-apps.sh --only pi
```

This regenerates `/root/.pi/agent/AGENTS.md` with a new "Posting to Mattermost programmatically" section AND exports `MATTERMOST_BOT_TOKEN` + `MATTERMOST_BOT_CHANNEL_ID` in `/root/.bashrc` on ollama-pi-agent. After this, pi can post status updates with a single curl using just env vars:

```bash
curl -sS -X POST 'http://mattermost:8065/api/v4/posts' \
  -H "Authorization: Bearer $MATTERMOST_BOT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"channel_id\":\"$MATTERMOST_BOT_CHANNEL_ID\",\"message\":\"build complete\"}"
```

**Re-run safety:**

The addon is idempotent at the API level:

- Bot already exists → looks it up by `GET /api/v4/users/username/pi-bot` and reuses the user_id
- Channel already exists → looks it up by `GET /api/v4/teams/{tid}/channels/name/bot` and reuses the channel_id
- Token already exists → mint will fail; the script surfaces the error in `warn()` and continues (you can rotate by deleting the old token in Mattermost UI first, then re-running)
- Team already exists → returns HTTP 400; script proceeds without recreating

It is **not** idempotent at the CT level — re-running with the same `--hostname` aborts because the CT already exists. To rebuild from scratch, destroy the CT first: `pct stop <ctid> && pct destroy <ctid>`.

**Two identities, distinct rotation lifecycle:**

| Identity | Token in td-tokens.txt | Used by | Rotation |
|---|---|---|---|
| `td` (admin) | `MATTERMOST_TOKEN` | Homepage widget (post/unread counts) | Rotate in Mattermost UI → Settings → Security |
| `pi-bot` (bot account) | `MATTERMOST_BOT_TOKEN` | Pi for automation | Rotate via API: `POST /api/v4/users/<bot_id>/tokens` (admin auth) |

This separation means a token leak from one doesn't compromise the other. Pi automation can't impersonate the admin; admin token rotation doesn't break pi.

---

## `setup-pi-mattermost-bridge.sh`

Wire **bidirectional** chat between pi (on `ollama-pi-agent`) and the Mattermost CT you stood up with `setup-mattermost.sh`. After this addon runs, opening a pi session auto-connects pi to the `#bot` channel, and posts in that channel get routed straight into pi's input — type "what's running on the sandbox CT?" in Mattermost, pi reads it and responds in the same channel.

Without this addon you only have outbound chat (pi can `curl POST /api/v4/posts` to drop status messages in `#bot`). With it, you have a **conversational interface** to pi from any device that can reach Mattermost — phone, laptop, browser, anywhere.

**What it does, end to end:**

1. Verifies prerequisites: `ollama-pi-agent` and `mattermost` CTs exist + are running, `/root/td-tokens.txt` has the four `MATTERMOST_*` lines `setup-mattermost.sh` wrote.
2. Installs `@whonixnetworks/pi-mattermost@1.5.0` locally into `/root/.pi/agent/npm/node_modules/` via pi's bundled `npm` (not `npm -g` — see "quirks" below).
3. Applies three local patches (in `pi-mattermost-bridge/patches/`):
   - `01-message-router-debug-logging.patch` — bridge-side WS event logging
   - `02-extension-auto-connect.patch` — adds the `PI_MATTERMOST_AUTO_CONNECT` env-var-driven auto-connect block to `dist/extension.js`, **plus** a fallback that swaps `projectPath` to `/var/pi/bot` when `ctx.cwd === "/"`
   - `03-extension-ts-auto-connect.patch` — same block in `src/extension.ts` (pi loads `.ts` directly via its bundled TS runtime)
4. Registers `npm:@whonixnetworks/pi-mattermost` in `~/.pi/agent/settings.json` (pi doesn't auto-scan `node_modules` — explicit registration is required, including the `npm:` source prefix).
5. Writes `~/.config/pi-mattermost/config.toml` from the `/root/td-tokens.txt` values.
6. Installs `pi-mattermost.service` as a system-level systemd unit (port 4000, bound to `127.0.0.1`).
7. Adds `export PI_MATTERMOST_AUTO_CONNECT=1` to `/root/.bashrc` so any pi session triggers auto-connect on startup.
8. Looks up the `#bot` channel id from Mattermost (`GET /api/v4/teams/{team_id}/channels/name/bot`) and **pre-binds** `/var/pi/bot → channel_id` in the bridge's `channel_mappings` SQLite table — so pi's auto-connect resolves immediately to the right channel without an extra round-trip.
9. Installs `pi-bot.service` — a `tmux`-hosted persistent pi session that auto-starts at CT boot and registers with the bridge. Without this, the bridge sees inbound posts but has no registered session to deliver them to (they drop on the floor). Skippable with `--no-daemon` if you only want manual interactive pi sessions.

**Prereqs:**

- `setup-mattermost.sh` finished successfully on this PVE host
- `/root/td-tokens.txt` has `MATTERMOST_BOT_TOKEN`, `MATTERMOST_BOT_USER_ID`, `MATTERMOST_TEAM_ID`, `MATTERMOST_URL`
- pi installed on `ollama-pi-agent` (i.e., `setup-ollama-pi.sh` was run)

**Install:**

```bash
./addons/setup-pi-mattermost-bridge.sh
```

About 3 minutes. The end-of-run banner explains how to use it.

**Flags:**

| Flag | What it does |
|---|---|
| `--no-daemon` | Skip installing `pi-bot.service`. Use if you only want the bridge available for on-demand sessions and don't want pi running headless 24/7. |
| `--with-daemon` | Explicitly opt in to the `pi-bot.service` install (default behavior — included for symmetry). |
| `--model NAME` | Model name passed to `ollama launch pi --model`. Default: auto-detected from `/root/.pi/agent/settings.json`'s `defaultModel`, falling back to `gemma4:31b-cloud`. Without an explicit `--model` on the launch line, pi shows its interactive picker on every daemon start (the `models.json` state isn't honored for non-interactive launches). |
| `--dry-run` | Print every action without executing — useful for previewing on a fresh CT |
| `--uninstall` | Stop both `pi-mattermost` and `pi-bot` services, remove the units, kill the `pi-bot` tmux session, strip `PI_MATTERMOST_AUTO_CONNECT` from `/root/.bashrc`, unregister the package from pi's `settings.json`. Leaves the npm install + DB in place for fast reinstall via re-running. |

**The pi-bot daemon (`pi-bot.service`):**

This is what makes pi "live" 24/7 inside Mattermost. Architecture:

```
┌─────────────────────────────────────────────────────────────┐
│  pi-bot.service  (systemd, Type=forking, RemainAfterExit)   │
│                                                             │
│     ExecStart:  tmux new-session -d -s pi-bot               │
│                 "cd / && ollama launch pi                   │
│                          --model gemma4:31b-cloud --yes"    │
│                                                             │
│     ┌──────────────────────────────────────────────────┐    │
│     │  tmux session 'pi-bot'                           │    │
│     │                                                  │    │
│     │  ┌────────────────────────────────────────┐      │    │
│     │  │   ollama launch pi                     │      │    │
│     │  │   - cwd: /                             │      │    │
│     │  │   - env: PI_MATTERMOST_AUTO_CONNECT=1  │      │    │
│     │  │   - default model: gemma4:31b-cloud    │      │    │
│     │  │   - loads pi-mattermost extension      │      │    │
│     │  │   - auto-registers session against     │      │    │
│     │  │     bridge (channel = 'bot')           │      │    │
│     │  └────────────────────────────────────────┘      │    │
│     └──────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

**Why tmux?** Pi is a TUI. It needs a pseudo-terminal (`pty`). Raw systemd `Type=simple` with `ExecStart=ollama launch pi` doesn't allocate one — pi either exits with "not a tty" or behaves erratically. `tmux new-session -d` allocates a pty AND immediately detaches, which satisfies systemd's `Type=forking` while leaving pi running inside.

**Default model:** the unit's `ExecStart` runs `ollama launch pi --model <NAME> --yes`. `<NAME>` is rendered into the unit by the install script from (in order of precedence): the `--model` CLI flag, then `/root/.pi/agent/settings.json`'s `defaultModel`, then a hardcoded `gemma4:31b-cloud`. `--yes` auto-confirms the "Update Available" banner pi shows on launch.

Why explicit `--model`? Even with `models.json` populated and `settings.json` showing the right `defaultModel`, pi's interactive launcher shows its model picker on every restart. The `--model` flag bypasses that picker entirely — the TUI proceeds straight to extension load and auto-connect.

To switch models later: re-run the addon with `--model NEW_NAME` (it'll re-render the unit). Or hand-edit `/etc/systemd/system/pi-bot.service` + `systemctl daemon-reload && systemctl restart pi-bot`.

**Attaching to the live session:**

```bash
PI_CTID=$(pct list | awk '$3=="ollama-pi-agent" {print $1}')
pct exec $PI_CTID -- tmux attach -t pi-bot
# Ctrl-b then d to detach (leaves pi running)
# Or just close the terminal — pi stays alive
```

You can attach to see what pi is doing, type commands directly into pi's REPL, etc. Multiple `tmux attach` sessions can connect simultaneously — useful for sharing a session between humans.

**Survives CT reboots:** `systemctl enable pi-bot.service` is wired during install. After a `pct reboot $PI_CTID`, the unit auto-starts (after `pi-mattermost.service` and `network-online.target`), pi registers with the bridge, and inbound `#bot` posts route immediately. No human intervention needed.

**Restarting cleanly:**

```bash
pct exec $PI_CTID -- systemctl restart pi-bot
# (this kills the old tmux session and starts a fresh one)
```

**Coexists with interactive sessions:** Running `pct enter $PI_CTID && ollama launch pi` opens a *second* pi session that registers separately. The daemon's session stays bound to `#bot`; your interactive one binds to whatever directory you launched from (e.g., `#root` if you launch from `/root`). You can have both running at once.

**Channel routing — how pi picks where to chat:**

The bridge supports two modes, picked by where pi was launched from:

- **Default mode** — pi launched from `/` (the default for `pct enter` and any systemd-spawned shell). The auto-connect block detects `ctx.cwd === "/"` and falls back to `projectPath = "/var/pi/bot"`. The bridge looks up this project path in `channel_mappings` (pre-bound by step 8 above), finds the `#bot` channel id, and binds the session to it. **This is what 99% of users want** — one canonical conversation channel.
- **Per-project mode** — pi launched from a real directory: `cd /root/myproject && ollama launch pi`. `ctx.cwd === "/root/myproject"`, basename is `myproject`, the bridge creates (or finds) a `#myproject` channel and binds the session there. Useful if you want per-project chats that don't all pile into `#bot`.

**Bridge architecture, in one diagram:**

```
                          ┌─────────────────┐
                          │   Mattermost    │
                          │   (CT 207)      │
                          └────┬────────────┘
                               │ WebSocket (posts/typing/status events)
                               │ REST API (post messages, get/create channels)
                               │
                          ┌────▼────────────┐    Unix-domain :4000
                          │ pi-mattermost   │◄──────────────────┐
                          │   bridge        │                   │
                          │  (systemd)      │                   │
                          └────┬────────────┘                   │
                               │                                │
                               │ session.messages              poll
                               │ (in-memory queue,             every
                               │  per registered sessionId)    1s
                               │                                │
                          ┌────▼────────────┐                   │
                          │ SQLite          │              ┌────┴────┐
                          │ sessions.db     │              │   pi    │
                          │  - sessions     │              │ session │
                          │  - channel_     │              └─────────┘
                          │    mappings     │
                          └─────────────────┘
```

When a user posts in `#bot`, the WS event arrives at the bridge → `message-router.js` filters out the bot's own posts and non-public channels → `queueIncomingMessage(channelId, ...)` finds the matching session and appends to its in-memory message list → pi's next poll drains the queue → pi handles the message.

When pi posts back, the extension calls `bridgeFetch("/api/stream-output", ...)` → bridge calls Mattermost's REST `POST /api/v4/posts` against the bound channel.

**Quirks the script handles for you:**

1. **`pi` doesn't auto-scan `node_modules`.** Packages must be explicitly listed in `~/.pi/agent/settings.json` under `"packages"`, and the identifier must include a source prefix (`npm:` for npm packages). The script adds the prefixed form AND removes any stale bare entry from prior runs.
2. **`npm -g` lands in the wrong place.** Pi's `npm` uses its own prefix at `/root/.local/share/pi-node/node-v*/lib/node_modules/` for globals, but our bundled patches reference absolute paths under `/root/.pi/agent/npm/`. So the script does `cd /root/.pi/agent/npm && npm install <pkg>` (no `-g`), which lands the package at the path the patches expect.
3. **Patch headers use absolute paths.** Neither `git apply -p1` nor `patch -p1` can find target files from `--- /tmp/package/dist/extension.js`. The script `sed`-rewrites headers to standard git-diff form (`a/dist/extension.js` / `b/dist/extension.js`) before applying.
4. **Bridge sessions are in-memory only.** Restarting `pi-mattermost.service` clears the `externalSessions` map. The SQLite `sessions` table persists rows, but `getOrCreateChannel` doesn't auto-load them on bridge startup — they're only re-created when pi calls `/api/register-session` again. This means relaunching pi after a bridge restart re-registers the session cleanly; no manual sync needed.
5. **The bridge's `display_name` rule is invisible.** Mattermost's `createChannel` API rejects empty `display_name`, and the bridge derives `display_name = basename(projectPath)` internally — ignoring any `display_name` field in the request body. If pi launches from `/`, `basename("/")` is empty and the API returns `"Invalid or missing display_name in request body."` — surfacing as a `status 500` to pi. Our patched auto-connect block dodges this with the `/var/pi/bot` fallback for `cwd === "/"`.
6. **First pi launch after `--uninstall` needs a relaunch.** Pi caches the loaded extension list at startup; uninstalling the package mid-session won't unload it. Exit and relaunch pi to drop the matter extension.

**Service management:**

```bash
PI_CTID=$(pct list | awk '$3=="ollama-pi-agent" {print $1}')
pct exec $PI_CTID -- systemctl status pi-mattermost
pct exec $PI_CTID -- journalctl -u pi-mattermost -f
pct exec $PI_CTID -- systemctl restart pi-mattermost
```

**Verifying end-to-end:**

1. On any pi-equipped CT: `ollama launch pi`. Watch for `Auto-connecting to Mattermost (project: /var/pi/bot)...` then `Connected to Mattermost channel: bot`.
2. In Mattermost UI: open Bot Posts (display name for the `#bot` channel). Post `hello pi`. Pi sees it and responds in the same channel.

**Re-run safety:**

The whole script is idempotent. Re-running:

- Detects existing npm install at `/root/.pi/agent/npm/node_modules/@whonixnetworks/pi-mattermost` and skips reinstall (force-bump via the printed command).
- Patches: each tried with `git apply --check` first, then `patch --dry-run`, then `git apply --check --reverse` to detect already-applied state.
- `settings.json` entry: only adds if missing; removes stale bare entry.
- `channel_mappings` row: `INSERT OR REPLACE` — refreshes if the bot channel id ever changes.
- systemd unit: written every run (template-rendered with current node binary path).
- `/root/.bashrc` export: `grep -q` before append.

---

## `setup-homepage-pi-widgets.sh`

Adds two Homepage `customapi` tiles for at-a-glance visibility into the pi-Mattermost bridge:

- **Pi Bridge** — live channel-count from the bridge daemon (`/api/channel-count` on port 4000): how many channels are live, how many session rows are persisted, how many are orphaned. Useful for spotting bridge restarts or stale state.
- **Latest in #bot** — most recent message in the `#bot` channel with relative timestamp. At-a-glance "what did pi just say" without opening Mattermost.

**What it does, end to end:**

1. Drops a systemd drop-in at `/etc/systemd/system/pi-mattermost.service.d/bind-all.conf` inside `ollama-pi-agent` that exports `PI_MATTERMOST_BIND=0.0.0.0`. Without this the bridge listens on `127.0.0.1:4000` only — the Homepage CT can't reach it. Bridge is still auth-gated (Bearer token required), so exposing it on the tailnet is safe.
2. Reads `/root/.local/share/pi-mattermost/.api_token` from the bridge CT and writes `PI_BRIDGE_TOKEN=…` into `/root/td-tokens.txt` on the PVE host. The Homepage tile uses this token in its `Authorization: Bearer` header.
3. Looks up the `#bot` channel id via `GET /api/v4/teams/{team_id}/channels/name/bot`.
4. Installs `/opt/mm-helpers/latest-bot-post.py` + `mm-latest-bot-post.service` inside the Mattermost CT. The Python proxy fetches `/api/v4/channels/<bot>/posts?per_page=1` with the admin token, then re-serializes the response into a flat `{message, user_id, create_at_ms}` shape because Homepage's `customapi` mappings can't index dynamic JSON keys (Mattermost wraps posts in a UUID-keyed dict).
5. Edits `services.yaml` on the Homepage CT — markered TD-Addon blocks for `pi-bridge` and `mm-latest-post`. Surgical block-replace on re-run.
6. Restarts the Homepage service so tiles appear immediately.

**Prereqs:** `setup-mattermost.sh` + `setup-pi-mattermost-bridge.sh` both finished. `/root/td-tokens.txt` must have `MATTERMOST_TOKEN` and `MATTERMOST_TEAM_ID`.

**Install:**

```bash
./addons/setup-homepage-pi-widgets.sh
```

**Flags:**

| Flag | What it does |
|---|---|
| `--no-bridge-tile` | Skip the Pi Bridge tile install (don't expose the bridge, don't write the tile) |
| `--no-latest-tile` | Skip the Latest in #bot tile install (don't install the MM-side helper) |
| `--dry-run` | Preview every action without executing |
| `--uninstall` | Remove the bridge override drop-in, the MM-side helper service, both tiles. Leaves `PI_BRIDGE_TOKEN` in td-tokens.txt for fast re-install. |

**Why a Python proxy on the Mattermost CT?**

Mattermost's `GET /api/v4/channels/{id}/posts?per_page=1` returns:

```json
{ "order": ["abc123uuid"], "posts": { "abc123uuid": { "message": "hello pi", ... } } }
```

Homepage's `customapi.mappings.field` does dot-notation extraction (e.g. `field: posts.count`) but can't dereference `posts[order[0]].message` — the inner key is a dynamic UUID. The 30-line proxy reshapes this to:

```json
{ "message": "hello pi", "user_id": "...", "create_at_ms": 1782175392000 }
```

…which Homepage maps trivially.

**Re-run safety:**

- Drop-in conf is idempotent — written from scratch every run, no append risk.
- Bridge token: `PI_BRIDGE_TOKEN` line uses sed-replace if present, append if not.
- Bot channel id: looked up fresh each run.
- Homepage tiles: markered block-replace.
- mm-latest-bot-post.service is `systemctl restart`'d on every run so changes to MM_TOKEN propagate.

---

## `setup-n8n.sh`

Stands up [n8n](https://n8n.io) — a self-hosted workflow automation platform — on its own CT, then **pre-wires credentials** for every other service in your TD-Proxmox stack so you can start building actual workflows instead of copy-pasting tokens out of `/root/td-tokens.txt`.

**Why bother:** n8n is the visual glue between Mattermost, Ollama, Gitea, OpenWebUI, and the outside world. By the time the script finishes, you can drag in a "Mattermost" node → it already knows your bot account. Drag in an "Ollama" node → it already points at `ollama-pi-agent`. The four-step "wire up the credentials" friction that kills most homelab n8n installs is done.

**What you get:**

- n8n on its own CT (community-scripts helper, defaults are fine)
- Joined to your Tailscale tailnet with `/dev/net/tun` passthrough
- Owner account created via REST (`POST /rest/owner/setup`) using the same `ADMIN_EMAIL` / `ADMIN_PASSWORD` you used everywhere else
- An n8n API key minted and saved back as `N8N_API_KEY` in `/root/td-tokens.txt`
- **Five pre-configured credentials** created via the API:
  - `Ollama (shared)` → `http://ollama-pi-agent:11434`
  - `Mattermost (pi-bot)` → reads `MATTERMOST_BOT_TOKEN` from `td-tokens.txt`
  - `Gitea (admin)` → reads `GITEA_TOKEN` from `td-tokens.txt`
  - `Gitea (admin) — Bearer` → same token, header-auth flavor for arbitrary REST calls
  - `OpenWebUI (OpenAI-compat)` → reads `OPENWEBUI_TOKEN` from `td-tokens.txt`
  - `TD shared webhook secret` → random `X-TD-Secret` header for trusted-caller webhook patterns
- **Four starter workflows** imported as INACTIVE (review then activate):
  - **`hello-mattermost`** — `POST /webhook/hello` → bot posts in `#town-square`. Smoke test that the Mattermost credential works.
  - **`mm-ollama-chat`** — receives Mattermost's outgoing webhook → routes the message body through Ollama → posts the response back. Wire up Mattermost: *your avatar → Integrations → Outgoing Webhooks → Add*, callback `http://n8n:5678/webhook/mm-chat`, pick a channel like `#ai-chat`. Includes a bot-loop guard (skips if `user_name == pi-bot`).
  - **`gitea-daily-digest`** — daily 9am cron → lists Gitea repos updated in last 24h → fetches their commits → posts a digest in `#town-square`.
  - **`gitea-events-to-mattermost`** — receives Gitea system webhooks at `POST /webhook/gitea-events` and posts a formatted message per event (push, PR opened/merged/closed, PR review, issue opened/closed, issue comment, release published, branch/tag created, repo created/deleted, fork). Wire up Gitea: *Site Administration → Webhooks → Add Webhook → Gitea*. URL: `http://n8n:5678/webhook/gitea-events`. Method: POST. Content Type: application/json. Trigger On: "Send Everything" (or pick specific events). Active: yes. The workflow returns `{ok: true, posted: bool, event: <type>}` so the Gitea webhook delivery log shows whether each event was actionable.
- Homepage tile under `Automation → n8n`
- All marker-strip + backup safety we use elsewhere — re-run any time

**Usage:**

```bash
# Stack-wide install (default)
./addons/setup-n8n.sh

# Preview without changes
./addons/setup-n8n.sh --dry-run

# Skip the starter workflows (just install + wire credentials)
./addons/setup-n8n.sh --skip-workflows

# Just stand up the CT, no credentials, no workflows
./addons/setup-n8n.sh --skip-credentials --skip-workflows

# Don't pollute the Homepage dashboard
./addons/setup-n8n.sh --skip-homepage-tile

# Tear it down
./addons/setup-n8n.sh --uninstall
```

**After it runs:**

1. Open `http://n8n:5678` and sign in as `ADMIN_EMAIL`.
2. Open *Workflows* — all three starters are there, marked inactive.
3. Open each workflow once and confirm the credential selector in every node resolves to the pre-created credential (if n8n shows "select credential", pick the named one from the dropdown — n8n matches by name on first save).
4. Toggle a workflow **Active** when you're ready.

**Pre-flight tokens it needs in `/root/td-tokens.txt`:**

| Required | Used for |
|---|---|
| `ADMIN_USER` | First-run owner setup (first name) |
| `ADMIN_EMAIL` *or* `N8N_OWNER_EMAIL` | Owner account email |
| `ADMIN_PASSWORD` *or* `N8N_OWNER_PASSWORD` | Owner account password |
| `MATTERMOST_BOT_TOKEN`, `MATTERMOST_URL` | Mattermost credential (skipped if missing) |
| `GITEA_TOKEN` | Gitea credential (skipped if missing) |
| `OPENWEBUI_TOKEN` | OpenWebUI credential (skipped if missing) |
| `TS_AUTHKEY`, `CT_PASSWORD` | CT creation + Tailscale join |
| `N8N_API_KEY` | (Optional, auto-minted) Use this on retry runs to skip login |

Anything missing → that credential just isn't created, and the script tells you. Re-run after the missing service is set up and the credential gets added.

**n8n's owner account has stricter requirements than the rest of the stack:**

- **Email must be real and reachable.** n8n 2.x sends an activation code to the email address before allowing the owner account to be fully active. Use a working inbox (Tutanota, mailbox.org, Fastmail, Gmail, etc.) — NOT `admin@localhost` or anything synthetic.
- **Password must contain at least 1 number** in addition to the usual 8+ char / mixed-case requirements.

If your stack-wide `ADMIN_EMAIL` / `ADMIN_PASSWORD` don't satisfy those (because the email isn't real or the password is letters-only), set per-app overrides in `/root/td-tokens.txt`:

```
N8N_OWNER_EMAIL=you@some-real-email.com
N8N_OWNER_PASSWORD=Xnrs9gRWeHLGM7p
```

The script prefers these when set, falls back to `ADMIN_*` when not. The startup pre-flight prints a warning if the password it's about to use has no number.

**If you've already set up n8n manually via the UI** (because the script crashed or you wanted to use different creds), put the API key in tokens to skip login entirely:

```bash
# 1. Log into the UI → Settings → n8n API → "Create an API key" → copy
# 2. On PVE:
echo 'N8N_API_KEY=n8n_api_v1_...' >> /root/td-tokens.txt
# 3. Re-run
./addons/setup-n8n.sh --credentials-only
```

The script will validate the key against `/api/v1/credentials`, see it's good, and proceed straight to credentials + workflows.

**Why the workflows are imported as inactive:** webhooks become live URLs the moment they're activated. Reviewing them first is the responsible default — confirm the credential bindings, confirm the channel ids match your install, then flip the toggle.

**Channel IDs in the starter workflows:** they reference `town-square` by slug. If your Mattermost has different channel names, edit the `channelId` on the Mattermost node — n8n accepts either a slug or a 26-char channel UUID.

**Idempotency:**

- CT creation: skipped if `hostname=n8n` already exists.
- Owner setup: if owner already exists, the script logs in instead.
- Credentials: each credential checked by name via `GET /credentials` before creating — re-runs skip existing ones, won't duplicate.
- Workflows: importing a workflow with the same name creates a new one (n8n doesn't enforce name uniqueness on workflows). If you re-run and want to dedupe, delete the old copies in the n8n UI first.
- API key: minted only on first run (idempotent because we check for the key in `td-tokens.txt` before calling `/rest/me/api-keys` again — n8n versions before 1.49 allowed only one key per user).
- Homepage tile: marker-based block-strip + re-append.

**Adding more credentials later:** anything else you wire (Slack, Telegram, AWS, OpenAI, etc.) you add manually in the n8n UI — only the in-stack services are auto-wired by this script. Keep the convention: name the credential after what it's for so the starter workflows' name-match resolution keeps working.

**License note:** n8n is **Fair-Code** under their Sustainable Use License. Self-hosting for your own use (or your client's use, as a TD-Proxmox install) is fine. You **cannot** repackage n8n into your own SaaS product and resell it. The intake-website business model treats n8n as part of the customer's install, not a hosted product we sell access to — so this is well inside the license.

---

## Setting up a USB drive as a backup target

`setup-pve-etc-backup.sh` (and `vzdump`) need somewhere to write. If you haven't already prepped a USB drive on the PVE host, the short version:

```bash
# 1. Identify the drive
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,MOUNTPOINT       # look for TRAN=usb

# 2. Wipe + format (replace sdb with your device — and double-check you've got the right one)
wipefs -a /dev/sdb
parted -s /dev/sdb mklabel gpt mkpart primary ext4 0% 100%
mkfs.ext4 -L pve-backup /dev/sdb1

# 3. Mount persistently using UUID + nofail
blkid /dev/sdb1                                       # copy the UUID
mkdir -p /mnt/pve-backup
echo 'UUID=<your-uuid> /mnt/pve-backup ext4 defaults,nofail,x-systemd.device-timeout=10s 0 2' >> /etc/fstab
systemctl daemon-reload
mount /mnt/pve-backup

# 4. Register with PVE as a backup storage target
pvesm add dir pve-backup --path /mnt/pve-backup --content backup,iso,vztmpl --is_mountpoint 1
```

`nofail` keeps PVE booting if the drive is unplugged. `--is_mountpoint 1` keeps PVE from writing into the placeholder directory if the drive isn't actually mounted.

Then schedule a daily vzdump via Datacenter → Backup, and stack `setup-pve-etc-backup.sh` on top to cover the host's own config.

---

## Adding your own addon

Drop a new `setup-<thing>.sh` into this folder. The patterns from `setup-filebrowser.sh` are worth borrowing:

- Auto-detect the target CT by hostname (`find_ct_by_hostname`) with a `--ct-id` override.
- Interactive prompts for required inputs, with `--flag value` overrides for automation.
- `--dry-run` that skips state-changing operations but still prints what would happen.
- Idempotent re-runs (check whether the work is already done before doing it).
- Final log lines that print the access URL and any next-step config.

Then add a row to the table at the top of this file describing it. If it's useful enough to surface, also link it from the top-level [`README.md`](../README.md).
