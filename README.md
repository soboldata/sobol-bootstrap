# sobol-bootstrap

The public entry point for installing a Sobol Data stack on a fresh
Proxmox VE host.

**Why this repo is public:** a brand-new customer install has no Gitea
yet — that's what we're about to install. So the install-time source
has to be reachable over the public internet. This repo is that
source. Sobol iterates in a private Gitea; changes get mirrored here.

## What's here

| Path | Purpose |
|---|---|
| `boot.sh` | The entry point — join tailnet, collect creds, clone this repo, run automation |
| `automation/` | `bootstrap-pve.sh` (creates CTs) + `setup-ollama-pi.sh` + `configure-apps.sh` |
| `addons/` | Library of `setup-<app>.sh` scripts + n8n workflow JSONs |
| `TROUBLESHOOTING_LOG.md` | Every issue we've hit + the fix (reference for operators) |

Everything here is what an operator needs to stand up a Sobol
Foundation stack. It doesn't contain secrets — those come from the
operator at install time (Tailscale auth key, SMTP token, CF token,
etc.) and get written to `/root/td-tokens.txt` mode 0600.

## Usage

**Fastest path — pre-populate the tokens file via `scp`:**

Best for testing and for install patterns where you don't want the
tokens leaving your workstation over the public internet.

```bash
# On your workstation
scp tokens.txt root@<pve-ip>:/root/td-tokens.txt

# SSH in and run boot.sh
ssh root@<pve-ip>
curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
```

`boot.sh` detects the pre-existing `/root/td-tokens.txt`, loads every
`KEY` from it into the env, and skips every prompt whose value is in
the file. No URL, no PAT, no network dependency between the PVE box
and your credential store.

**Alternative — fetch a pre-populated tokens file over HTTPS or LAN:**

Host a `tokens.txt` at a URL boot.sh can reach *before* Tailscale is
up. Options that work:

- **Local Gitea over LAN** — private repo, raw endpoint, PAT header.
  URL like `http://<your-gitea-lan-ip>:3000/td/td-tokens/raw/branch/main/td-tokens.txt`.
  Works when the PVE box is on the same LAN as your Gitea host.
  (Gitea doesn't have first-class Gists — a private repo with a
  raw endpoint gives the same effect.)
- **GitHub private repo raw** — for pilot customers.
- **GitHub secret gist** — unguessable URL, no auth. OK for quick
  testing; less durable than a repo since gists can leak in search.

```bash
curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
```

Paste the tokens URL at the first prompt. `boot.sh` fetches it, drops
it into `/root/td-tokens.txt`, exports the keys, and skips every
prompt whose value is in the file. Missing keys still get prompted.

Private repo (Gitea, GitHub, whatever)? Add a PAT — same header
format everywhere:

```bash
TOKENS_URL='http://<your-gitea-lan-ip>:3000/td/td-tokens/raw/branch/main/td-tokens.txt' \
TOKENS_URL_TOKEN=<gitea_or_github_PAT> \
curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
```

**Fully manual (env vars per credential):**

```bash
TS_AUTHKEY=tskey-auth-xxxx \
SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" \
CT_PASSWORD='strongpass-12chars-min' \
ADMIN_EMAIL='you@example.com' \
ADMIN_PASSWORD='stackadmin-12chars-min' \
curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
```

**Interactive (humans, one prompt per missing value):**

```bash
curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
```

Press Enter at the tokens-URL prompt to skip the fetch and type each
credential by hand. Every prompt reads from `/dev/tty` so it works
even under `curl | bash`.

### Tokens file format

Plain `KEY=value` per line. Blank lines and `# comment` lines are
ignored. Recognized keys (all optional — missing ones prompt):

```
TS_AUTHKEY=tskey-auth-...
TS_HOSTNAME=creator
SSH_PUBKEY=ssh-ed25519 AAAA... you@workstation
CT_PASSWORD=root-pw-for-CTs-12chars-min
ADMIN_EMAIL=you@example.com
ADMIN_USER=admin
ADMIN_PASSWORD=stack-admin-pw-12chars-min
```

Values may be optionally quoted with `"` or `'`; CRLF line endings
get stripped. Keep the file `chmod 600` on the host and treat the URL
as sensitive. For a testing gist, unlisted-with-hash is fine; for
anything customer-facing, use a private repo + PAT until the
encrypted-intake path lands.

## What boot.sh does

1. Swaps `enterprise.proxmox.com` apt repos → `no-subscription`
   (fresh PVE 8 / 9 defaults to enterprise which 401s without a
   paid subscription)
2. Installs base tools (`curl`, `ca-certificates`, `gnupg`)
3. Collects credentials from env vars or terminal prompts
4. Installs Tailscale via the official installer
5. Joins the customer's tailnet using the reusable auth key
6. Sanity-checks MagicDNS
7. Writes all credentials to `/root/td-tokens.txt` (mode 0600)
8. Installs git and clones THIS repo to `/root/sobol-foundation/`
9. Runs `automation/bootstrap-pve.sh` → creates the CTs
10. Runs `automation/setup-ollama-pi.sh` → Ollama + pi runtime
11. Runs `automation/configure-apps.sh` → admin accounts + Homepage
    tiles + wired credentials

After ~30-45 minutes the host is fully installed and Gitea (now on the
customer's tailnet) becomes the canonical source for future updates.

## Optional env vars

| Variable | Default | Purpose |
|---|---|---|
| `TS_HOSTNAME` | `hostname -s` | Hostname to register on the tailnet |
| `SOBOL_REPO_URL` | `https://github.com/soboldata/sobol-bootstrap.git` | Where to clone from |
| `SOBOL_REPO_DIR` | `/root/sobol-foundation` | Local checkout dir |
| `ADMIN_USER` | `admin` | Admin username for stack accounts |
| `STACK` | `sobol-foundation` | Stack to install; `none` = stop after clone |

## Testing without installing

To join the host to your tailnet, clone the repo, and stop before
running the automation:

```bash
STACK=none curl -fsSL https://raw.githubusercontent.com/soboldata/sobol-bootstrap/main/boot.sh | bash
```

The host will be tailnet-joined, tokens written, repo cloned — but
the install won't run. Useful for validating network connectivity
before a full install.

## Relationship to the private sobol-foundation repo

Sobol Data develops in a private Gitea at
`gitea:3000/td/sobol-foundation`. That's where changes land first,
where the framework tests run, where per-customer overlays sit.

This public repo (`soboldata/sobol-bootstrap`) is a **mirror** of the
install-time subset — `automation/` + `addons/` + `boot.sh` + logs.
Everything a customer needs to stand up a foundation stack. Nothing
they don't.

Content that stays private:
- `CLAUDE.md` files (internal agent context)
- Customer overlay repos (per-customer secrets + config)
- The full `stacks/` monorepo (commercial stack manifests)
- `sobol-business/` (strategy, GTM, runbooks)

## Requirements

**On the PVE host:**
- Proxmox VE 8.x or 9.x, fresh install
- Root SSH access
- ≥16 GB RAM, ≥100 GB disk, ≥4 CPU cores (see stack manifests for
  more precise capacity floors)
- Outbound HTTPS to `github.com`, `tailscale.com`, `download.proxmox.com`

**On the operator side:**
- Reusable Tailscale auth key with `tag:sobol-<customer>` or similar
- MagicDNS enabled in the Tailscale admin panel
- Customer domain on Cloudflare (if you're installing a customer-
  facing stack like creator-studio)

## License

MIT — reuse the pattern in your own installers.
