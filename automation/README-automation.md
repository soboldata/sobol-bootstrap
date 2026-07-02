# TD-Proxmox — Automated Build Run Sheet

End state after a full run: a Proxmox VE 9.x host with up to five LXC containers, all joined to your Tailscale tailnet.

**Core CTs (always installed):**
- `ollama-pi-agent` — pi coding agent runtime
- `gitea` — self-hosted Git with admin account and access token
- `homepage` — dashboard with tiles for everything running

**Optional CTs (interactive Y/n prompt at bootstrap start, or `--skip-sandbox` / `--skip-openwebui` flags):**
- `sandbox` — Docker host for ad-hoc workloads (named `sandbox` rather than `docker` so prompts like "run a docker image on sandbox" stay unambiguous)
- `openwebui` — ChatGPT-style UI in front of Ollama + OpenRouter

A quick install (core only) takes ~25 minutes; the full install (everything) takes ~45 minutes. Either way roughly 10 minutes is hands-on-keyboard.

---

## Run order

| # | Phase | How | Roughly |
|---|---|---|---|
| 1 | Flash USB, boot, install Proxmox | Manual (Etcher + BIOS + graphical installer) | 15 min |
| 2 | First web UI login + grab the IP | Manual (browser) | 1 min |
| 3 | `bootstrap-pve.sh` | One script on the PVE host | 18 min |
| 4 | `setup-ollama-pi.sh` | One script — Ollama + pi + one browser click to pair | 5 min |
| 5 | `configure-apps.sh` | One script on the PVE host | 3 min |
| 6 | pi prompts (the actual point) | Interactive in `ollama launch pi` | open-ended |

Phases 1 and 2 are the only fully-manual stops. Phase 4 has one browser click for Ollama device pairing in the middle of an otherwise-automated script.

---

## Before you start

Have ready:

- A computer with at least **120 GB of free disk** after the Proxmox install — the LXCs allocate roughly: ollama-pi-agent 20 GB + sandbox 4 GB + gitea 8 GB + openwebui 50 GB + homepage 4 GB (≈ 86 GB), plus the template cache (~600 MB) and headroom for models / Docker images. 256 GB SSD is comfortable; 128 GB will work but get tight.
- A USB drive (8 GB+) with the Proxmox VE 9.1 ISO flashed via Balena Etcher.
- An SSH keypair on your workstation. `ssh-keygen -t ed25519` if you don't have one.
- An account at **tailscale.com** with an auth key minted in advance: admin console → Settings → Keys → Generate auth key → reusable, no expiry needed for first run.
- An account at **openrouter.ai** with at least one API key (`sk-or-...`).
- An account at **ollama.com** (no token needed yet — pairing is done in-flow).

Everything else is bootstrapped by the scripts.

---

## Phase 1–2 — Install Proxmox + first login

This part stays manual until you want to invest in a custom unattended-install ISO. Follow the `Proxmox VE Installation.pptx` deck through the install screens (target disk, country/timezone, hostname, management IP, root password). After reboot, browse to `https://<pve-ip>:8006`, log in as `root`, and note the IP.

---

## Phase 3 — `bootstrap-pve.sh`

Open the PVE web UI's `>_ Shell` on the node. The fastest way to get the script onto a fresh host is to fetch it directly from GitHub:

```bash
# Fetch + run interactively (process substitution keeps stdin free for prompts)
bash <(curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/automation/bootstrap-pve.sh) --dry-run
```

Or, equivalently, download then run — easier to debug, easier to re-run:

```bash
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/automation/bootstrap-pve.sh \
  -o /root/bootstrap-pve.sh
chmod +x /root/bootstrap-pve.sh
/root/bootstrap-pve.sh --dry-run
```

> **Don't use `curl … | bash`.** The script is interactive — `bash` would consume stdin from the pipe, leaving nothing for the SSH-key/Tailscale-key/password prompts to read. Use process substitution `bash <(curl …)` or download-then-run instead.

**Alternative paths** if you don't have GitHub access from the host (offline lab, restricted network, etc.):

- `scp ~/td-proxmox/automation/bootstrap-pve.sh root@<pve-ip>:/root/` from your workstation.
- Paste the script contents directly into `nano /root/bootstrap-pve.sh` in the web UI shell — it's ~6 KB, paste is instant.

The script doesn't need any flags up front. It will prompt you to paste, in order:

1. Your workstation's SSH **public** key (one line, starts with `ssh-...`).
2. A Tailscale auth key (`tskey-auth-...`) — input hidden.
3. A root password for the new CTs — input hidden, confirmed twice.

This solves the chicken-and-egg on a fresh install: you don't need to scp the public key over first or have anything else preloaded on the host. If you'd rather pass them non-interactively (e.g. from a CI driver or vault helper), the same values can come in as `--sshkey-file`, `--sshkey-text`, `--tsauthkey`, `--ct-password` flags.

Drop `--dry-run` once the printed command sequence looks right. The script:

1. Disables the enterprise repo, enables `pve-no-subscription` (handles both PVE 8 `.list` and PVE 9 `.sources` formats).
2. Runs `apt update && apt upgrade -y` and resolves the latest Debian 12 template via `pveam available`.
3. Appends your workstation pubkey to `/root/.ssh/authorized_keys` on the PVE host.
4. Creates `ollama-pi-agent` with `pct create` (CT 200 if free), plus the TUN passthrough config.
5. Runs the community helper scripts for `sandbox` (via `docker.sh`), `gitea`, `openwebui`, and `homepage`.
6. Pushes the PVE host's authorized_keys into each CT (workstation key + any other keys you've added).
7. Installs Tailscale directly inside each CT (no addon script, no whiptail) and runs `tailscale up --authkey=...` so each CT joins your tailnet.

> **Heads up about whiptail menus during step 5.** Each community helper presents a menu at the start with **Default Install** / **Advanced Install** / **App Defaults** / **Settings** options. **Pick "Default Install"** for each one — that's what the script's `var_*` env vars (CPU/RAM/disk/GPU/SSH key) are tuned for. Four menus, one click each.

> **About CTIDs.** Community helper scripts auto-assign the next available CTID rather than honoring our preferred IDs, so your `pct list` may show different numbers than the comments in the script (e.g., sandbox landing at CT 100 instead of 215). The scripts work entirely by hostname after creation, so this is cosmetic — `tailscale status` and `ssh root@sandbox` still work the same.

End state: five containers running, all reachable by MagicDNS hostname (`ollama-pi-agent`, `sandbox`, `gitea`, `openwebui`, `homepage`) from any device on your tailnet, and from each other via the SSH trust mesh that `setup-ollama-pi.sh` builds in the next phase.

Idempotent. Safe to re-run — existing CTs and steps already completed are detected by hostname and skipped.

---

## Phase 4 — `setup-ollama-pi.sh`

On the PVE host:

```bash
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/automation/setup-ollama-pi.sh \
  -o /root/setup-ollama-pi.sh
chmod +x /root/setup-ollama-pi.sh
/root/setup-ollama-pi.sh
```

The script walks both `ollama-pi-agent` and `openwebui` automatically (resolved by hostname — actual CTIDs depend on what the community helpers auto-assigned). For each:

1. Installs `curl`, `zstd`, and Ollama via the official `install.sh` (skip if already installed).
2. Drops `/etc/profile.d/usrlocal-path.sh` and appends to `/etc/bash.bashrc` so future `pct enter` sessions see `/usr/local/bin` (Ollama's install location) on PATH.
3. Runs `ollama signin` — Ollama prints a URL like `https://ollama.com/connect?name=<hostname>&key=...` to your terminal. **Visit it in a browser logged into ollama.com, click Connect, and the script resumes.** Two browser clicks per fresh host — once for each CT.
4. Pulls the default model (`gemma4:31b-cloud`, override with `--model …`).
5. On `ollama-pi-agent` only: binds Ollama to `0.0.0.0:11434` (so other tailnet devices can hit the API), installs pi from `pi.dev/install.sh`, appends Node.js bin to `PATH`, generates `/root/.ssh/id_ed25519` and pushes the pubkey into `sandbox`, `gitea`, `openwebui`, and `homepage`'s `authorized_keys` — so pi can `ssh root@sandbox` (etc.) without passwords or fingerprint prompts.

Idempotent at every step — re-runs detect what's already installed (Ollama binary, model pulled, pi installed, PATH already set) and skip cleanly. So if anything fails partway, just re-run.

**Flags for unusual cases:**

- `--ct-id N` — target only that CT instead of both
- `--skip-pi` — set up Ollama everywhere, skip pi install entirely
- `--skip-signin` — install Ollama but don't pair (you'll pair manually later)
- `--model gemma3:12b-cloud` — different default model

After this phase, `openwebui` chat dropdown lists local Ollama models alongside OpenRouter, and `ollama launch pi` works inside `ollama-pi-agent`.

---

## Phase 5 — `configure-apps.sh`

Back on the PVE host. By now Gitea is up, so you have two equally good sources for the script:

```bash
# From GitHub (canonical, always reachable)
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/automation/configure-apps.sh \
  -o /root/configure-apps.sh

# Or from your own Gitea (after you've pushed there too)
curl -fsSL http://gitea:3000/td/td-proxmox/raw/branch/main/automation/configure-apps.sh \
  -o /root/configure-apps.sh

chmod +x /root/configure-apps.sh
/root/configure-apps.sh --dry-run
```

The script prompts for the admin username, email, password (hidden + confirmed), and OpenRouter API key (hidden) at startup if they're not passed as flags — same interactive pattern as `bootstrap-pve.sh`. Pass them as `--admin-user td --admin-email ... --admin-password ... --openrouter-key ...` if you'd rather automate / drive from a vault helper.

Drop `--dry-run` to commit. The script:

1. Creates the Gitea admin user via `gitea admin user create`, mints an access token named `pi-agent`.
2. Creates the OpenWebUI admin user via `/api/v1/auths/signup`, logs in, and adds an OpenRouter connection (`https://openrouter.ai/api/v1`) under OpenAI-compatible providers.
3. On ollama-pi-agent, writes `/root/.netrc` with the Gitea creds and persists `OPENROUTER_API_KEY` in `/root/.bashrc`.
4. On homepage, writes a starter `services.yaml` (Gitea + widget, OpenWebUI, ollama-pi-agent, sandbox), `settings.yaml` (theme, title, layout), `bookmarks.yaml` (Proxmox + Tailscale + OpenRouter + Ollama admin links), and `widgets.yaml` (resources + search bar), then restarts the service.

5. On `ollama-pi-agent` and `sandbox`, installs [filebrowser](https://github.com/filebrowser/filebrowser) — a drag-and-drop web UI for `/root/uploads/` on each. Available at `http://ollama-pi-agent:8080` and `http://sandbox:8080`. Reuses the admin user/password you provided for Gitea + OpenWebUI; tile auto-registers on the Homepage dashboard.

A credentials summary is written to `/root/td-tokens.txt` (chmod 600) and echoed to stdout. Open `http://homepage:3000` from any tailnet device — every tile already points at the right place.

---

## Phase 6 — pi prompts

`pct enter 200`, then `ollama launch pi`, pick a model, and start prompting. The earlier scripts have already given pi the credentials it needs:

- Gitea: `.netrc` already on disk, push/pull "just works" on `http://gitea:3000/td/<repo>.git`.
- OpenRouter: `OPENROUTER_API_KEY` already in environment — ask pi to add it as a model provider on first launch.

Sample prompts that mirror the deck demo (Docker is already installed on the `sandbox` CT, so pi can go straight to using it):

> "ssh into the sandbox container and run `docker run hello-world`. Show me the output."
>
> "ssh into the sandbox container and tell me what's listening on which port."
>
> "write a small Python CLI that prints a random programming joke. Init a git repo, push to Gitea as `td/joke-cli`."
>
> "ssh into the sandbox container, clone td/joke-cli, build it as a container image, and run it."
>
> "ssh into the homepage container, open services.yaml, and add a tile for the joke-cli repo under Development. Restart the service. The other tiles are already there from configure-apps.sh — just slot the new one in."

---

## What's left to automate

In rough order of effort vs payoff:

- **pi provider config** — the one gap in `configure-apps.sh`. Pi's CLI for adding model providers isn't stable, so the current script just sets `OPENROUTER_API_KEY` and leaves the wiring to a first-launch prompt. If pi.dev stabilizes a `pi providers add` command, this becomes a one-liner.
- **Homepage tile config** — `services.yaml` and `widgets.yaml` for Homepage have a clean schema. A `configure-homepage.sh` that takes the four tailnet hostnames + Gitea token and emits these files would replace prompt 6 entirely.
- **Ollama device pairing** — eliminable only if you're willing to scrape the connect URL out of `ollama signin` output and open it in a headless browser with stored creds. Honestly not worth it for a one-time setup.
- **Proxmox unattended install** — `proxmox-auto-install-assistant` + an answer file can produce a no-keyboard installer ISO. Replaces phases 1–2 entirely. ~2 hours to set up, pays off the third time you reinstall.

---

## File layout

```
TD-Proxmox/
├── automation/
│   ├── bootstrap-pve.sh        # Phase 3
│   ├── setup-ollama-pi.sh      # Phase 4
│   ├── configure-apps.sh       # Phase 5
│   └── README-automation.md    # This file
├── follow-along-guide.md       # The manual walkthrough (source of truth for what each phase does)
├── concepts-deep-dive.md       # Background reading
└── Proxmox VE Installation.pptx   # Slide deck for live presentation
```

All three scripts support `--dry-run` and `--help`. The `--only` flag accepts different key sets depending on the script:

| Script | `--only` accepts | Example |
|---|---|---|
| `bootstrap-pve.sh` | hostnames | `--only ollama-pi-agent,gitea` |
| `setup-ollama-pi.sh` | (use `--ct-id` instead) | `--ct-id 200` |
| `configure-apps.sh` | subsystem names | `--only gitea,openwebui,pi,homepage` |

Read the header comment at the top of each script for the full flag list.
