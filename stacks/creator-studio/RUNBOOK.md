# Creator Studio — Runbook

The end-to-end install procedure for a creator-studio composition on
a fresh Proxmox VE host. Written for the operator doing the install
(you, the customer's field engineer, or a self-installing power user).

For the *architecture* — what the CTs do, how the pieces fit together
— see `README.md` in this folder plus the topology diagram in
`../../studio-stack/STACK.md` (waiting to be ported here too).

For the *why* — pricing, positioning, target customer — see
`../../sobol-business/OFFERINGS.md`.

---

## What you're installing

Ten CTs total on the PVE host, in two tiers:

| Tier | CTs | Role |
|---|---|---|
| **Foundation** (from `sobol-foundation`) | gitea, mattermost, n8n, ollama-pi-agent, homepage | Chat, code repo, workflow engine, dashboard, LLM agent |
| **Vertical** (creator-studio additions) | postgres-shared, ghost, plausible, calcom, cloudflared | Publishing, analytics, scheduling, public tunnel |

Plus optional foundation add-ons (sandbox, openwebui, filebrowser,
pi-mattermost-bridge, pi-web-uis) that you'll leave enabled unless
you have a specific reason not to.

The stack goes public via a Cloudflare Tunnel — no ports forwarded
from the customer's LAN, no public IP required.

---

## Order of operations

```
0. Prereqs (do these BEFORE running any scripts)
1. Foundation bootstrap — creates the 5 foundation CTs
2. Vertical bootstrap    — creates the 5 vertical CTs (300-304)
3. Foundation configure  — admin accounts, tokens, Mattermost/n8n
4. Vertical addons       — postgres → ghost/plausible/calcom → cloudflared
5. Manual admin signups  — Ghost, Plausible, Cal.com (browser required)
6. Mint API keys         — save 3 keys to studio-tokens.txt
7. CF Zero Trust hostnames — add 5 public hostnames in CF dashboard
8. wire.sh               — composition glue (5 idempotent phases)
9. Verify                — reachability + smoke tests
```

Phases 4a-4c are parallelizable. Phases 5-6 are manual. Phase 7 is
where the site actually becomes reachable from the internet.

---

## Phase 0: Prereqs

Everything below is a HARD prereq — the install will bounce or the
success banner will document a manual step if you skip anything.

### 0.1 Domain on Cloudflare (Add Site, not Registrar transfer)

- [ ] In CF: **Add Site** → your domain → Free plan
- [ ] Update your registrar to use the two CF nameservers CF hands
      you (`xxx.ns.cloudflare.com`, `yyy.ns.cloudflare.com`)
- [ ] Wait for propagation:
      ```
      dig NS <yourdomain> @1.1.1.1 +short
      dig NS <yourdomain> @8.8.8.8 +short
      ```
      Both should return CF's nameservers.

Not required: transferring domain registration to Cloudflare Registrar
(that's a separate process with a 60-day post-transfer lock).

### 0.2 Cloudflare Tunnel created + Tunnel Token in hand

- [ ] CF dashboard → **Zero Trust** → **Networks** → **Tunnels** →
      **Create tunnel** → name it (e.g. `<customer>-studio`)
- [ ] Copy the **Tunnel Token** (`eyJh...` — long)
- [ ] Do NOT configure ingress hostnames yet — we'll do that in Phase 7
      AFTER the internal CTs are up and we know their tailnet IPs

### 0.3 Postmark account with verified sender

- [ ] Signed up at postmarkapp.com (free 100/mo tier is fine)
- [ ] Server created (e.g. `<customer>-transactional`)
- [ ] Server API Token in hand (used as both SMTP username AND password)
- [ ] Sender signature verified for your domain
- [ ] DKIM + Return-Path CNAMEs added to Cloudflare DNS
- [ ] Both showing **Verified** in Postmark dashboard (allow up to 24h
      for CNAME propagation — DKIM TXT usually verifies within minutes)

Postmark's dashboard is the source of truth here. If DKIM says
**Verified** but Return-Path says **Not Verified**, mail still sends
but with reduced deliverability. Wait for both green before Phase 7.

### 0.4 Tailscale reusable auth key on the customer's tailnet

- [ ] Tailscale admin → **Settings** → **Keys** → **Generate auth key**
- [ ] **Reusable: YES** (all 10 CTs use this one key)
- [ ] **Ephemeral: NO** (CTs must persist across restarts)
- [ ] Tag suggestion: `tag:studio-<customer>` for ACL filtering

Important: creator-studio installs run on the customer's private
tailnet (typically `<customer>@soboldata.com` for the Sobol-provided
customer tailnet, or their own if they self-host). It is NOT on the
same tailnet as the sobol homelab. Confirm which tailnet identity
this key belongs to before generating.

### 0.5 PVE host ready

- [ ] PVE 8.x or 9.x, reachable via SSH as root
- [ ] Minimum: 16 GB RAM, 200 GB disk free, 4 CPU cores
- [ ] Recommended for creator-studio: 32 GB RAM, 500 GB SSD, 4-8 cores
- [ ] `apt update && apt full-upgrade -y` done recently
- [ ] PVE subscription nag disabled (community-scripts has a one-liner)

### 0.6 Save credentials in a scratch file

Paste everything into `/tmp/studio-prereqs.txt` (delete after install):

```
# Stack identity
DOMAIN=<customer.tld>
CUSTOMER_ID=<kebab-slug>

# Foundation basics
TS_AUTHKEY=tskey-auth-...
CT_PASSWORD=<chosen root password for all CTs>
ADMIN_USER=admin
ADMIN_EMAIL=<real email>
ADMIN_PASSWORD=<chosen; used for Ghost + Plausible + Cal.com admin accounts>

# Email (canonical SMTP_* schema)
SMTP_HOST=smtp.postmarkapp.com
SMTP_PORT=587
SMTP_USERNAME=<Postmark Server API Token>
SMTP_PASSWORD=<same token>
SMTP_FROM="Sobol Data" <hello@<customer.tld>>
ADMIN_NOTIFY_EMAIL=<real inbox for PVE alerts>

# Cloudflare
CF_TUNNEL_TOKEN=eyJh...
```

---

## Phase 1: Foundation bootstrap

Get the sobol-foundation repo onto the PVE host and run the one-liner
bootstrap.

**Case B — usual first-install (host NOT yet on the tailnet):** MagicDNS
doesn't resolve `gitea:3000` before Tailscale is joined. Use the Gitea
host's LAN IP for both the `curl` and the `SOBOL_REPO_URL` override:

```bash
ssh root@<pve-host>

# Replace 10.27.0.226 with your Gitea host's LAN IP
export SOBOL_REPO_URL=http://10.27.0.226:3000/td/sobol-foundation.git
curl -fsSL http://10.27.0.226:3000/td/sobol-foundation/raw/branch/main/bootstrap-fresh-pve.sh | bash
```

After bootstrap-pve.sh joins Tailscale (~30s into the run), subsequent
`git pull` commands can use the `gitea` hostname normally.

**Case A — host is somehow already on the tailnet** (rare, e.g. Sobol
field engineer pre-joined it):

```bash
curl -fsSL http://gitea:3000/td/sobol-foundation/raw/branch/main/bootstrap-fresh-pve.sh | bash
```

The bootstrap prompts for SSH key, TS_AUTHKEY, CT_PASSWORD. Or you can
pre-set them in `/root/td-tokens.txt` (see `sobol-foundation/CLAUDE.md`)
and it'll pick them up unattended.

**Result**: 5 foundation CTs running + joined to tailnet:
- gitea (200), mattermost (101), n8n (102), ollama-pi-agent (200),
  homepage (110), plus optional sandbox (215) + openwebui (100)

Verify:
```bash
pct list                                # all CTs running
ssh root@homepage "hostname"            # basic reachability
ssh root@n8n "tailscale status | head"  # tailnet OK
```

---

## Phase 2: Vertical bootstrap

The creator-studio verticals need their own 5 CTs in the 300-range.
There are two paths — the second is temporary.

### 2a. Path A (target — waiting on setup-stack.sh real dispatch)

```bash
cd /root
git clone http://gitea:3000/td/stacks.git
cd stacks
../proxmox-stack-foundations/setup-stack.sh creator-studio
```

This walks `creator-studio/manifest.yaml` and creates each vertical CT
via community-scripts helpers, then chains into Phase 3 automatically.

**Status:** setup-stack.sh is SKELETON as of 2026-07-01 — validates
the manifest + prints the plan, but doesn't yet execute. Use Path B
below in the meantime.

### 2b. Path B (temporary — legacy studio-stack automation)

```bash
cd /root
git clone http://gitea:3000/td/studio-stack.git
cd studio-stack
./automation/bootstrap-pve.sh
```

This creates the 5 vertical CTs at IDs 300-304 and joins each to the
tailnet. Writes credentials to `/root/studio-tokens.txt`.

**Retirement note:** the `studio-stack/` folder is in end-of-life
mode. When setup-stack.sh dispatch lands (see `stacks/CLAUDE.md`),
these bootstrap + configure scripts get retired.

CT assignments:
- `ghost`       → CT 300
- `plausible`   → CT 301
- `calcom`      → CT 302
- `postgres`    → CT 303
- `cloudflared` → CT 304

Verify:
```bash
pct list | grep -E ' 30[0-4] '   # 5 vertical CTs running
pct exec 304 -- tailscale status  # cloudflared joined
```

---

## Phase 3: Foundation configure

Sets up admin accounts on Mattermost + n8n, wires Homepage, deploys
the pi-mattermost-bridge, etc.

```bash
cd /root/sobol-foundation
./automation/configure-apps.sh
```

Prompts for `ADMIN_EMAIL` and `ADMIN_PASSWORD` (or reads from
`td-tokens.txt`). Idempotent — safe to re-run.

**Result:** foundation CTs fully configured. Mattermost has an admin +
`#bot` channel + pi-bot user. n8n has admin + credentials wired for
Mattermost, Gitea, Ollama.

---

## Phase 4: Vertical addons

All library addons live at `sobol-foundation/addons/`. Run in
dependency order — postgres first, then the three apps in parallel,
then cloudflared last (needs the other three responding first).

```bash
cd /root/sobol-foundation

./addons/setup-postgres-shared.sh
./addons/setup-ghost.sh
./addons/setup-plausible.sh
./addons/setup-calcom.sh
./addons/setup-cloudflared.sh
```

Each writes its progress + honest gaps to stdout. Cal.com's first-run
Prisma migrations are slow (90–180s), which is expected. Everything
else finishes in under 5 minutes.

**Result:** All 5 vertical apps are running on the tailnet. External
hostnames don't work yet (Phase 7 configures that). Ghost + Plausible
+ Cal.com don't yet have admins created (Phase 5).

---

## Phase 5: Manual admin signups (browser required)

None of Ghost, Plausible, or Cal.com expose a first-run admin API —
you must sign up in the browser. Each app is reachable via the tailnet
hostname during this phase.

### 5a. Ghost

- [ ] Open `http://ghost:2368/ghost/setup` in your browser (on the tailnet)
- [ ] Site name: `<customer name>`
- [ ] Admin email: your `ADMIN_EMAIL` from Phase 0.6
- [ ] Admin password: your `ADMIN_PASSWORD` from Phase 0.6
- [ ] Skip the "Invite team" step

### 5b. Plausible

- [ ] Open `http://plausible:8000/register`
- [ ] Create an account with `ADMIN_EMAIL` + `ADMIN_PASSWORD`
- [ ] After account creation: **Add a Site** → enter your domain
      (no `https://` prefix; just `<customer.tld>`)
- [ ] Note the tracking-snippet page — you'll skip this for now, wire.sh
      will inject it into Ghost automatically in Phase 8

### 5c. Cal.com

- [ ] Open `http://calcom:3000/auth/setup`
- [ ] Complete the 3-step admin setup wizard
- [ ] Configure external calendar integrations you need (Google, Outlook,
      Zoom, etc.) — Settings → Apps → Install

**Do NOT create event types manually.** wire.sh's Phase 2 creates the
two standard creator-studio types (`audit-consult` + `compliance-discovery`).

---

## Phase 6: Mint API keys

Each app has its own key ceremony. Save each to `/root/studio-tokens.txt`
as you go.

### 6a. Ghost admin API key

- [ ] In Ghost: **Settings → Integrations → Add custom integration**
- [ ] Name it `wire.sh` or `creator-studio-glue`
- [ ] Copy the **Admin API Key** (looks like `<24-hex>:<64-hex>`)
- [ ] Save:
  ```bash
  echo "GHOST_ADMIN_API_KEY=<id>:<secret>" >> /root/studio-tokens.txt
  ```

### 6b. Plausible API key

- [ ] User avatar → **Personal API Keys** → **New API Key**
- [ ] Give it a name (`wire.sh`), select scopes (**Stats: Read**)
- [ ] Save:
  ```bash
  echo "PLAUSIBLE_API_KEY=<key>" >> /root/studio-tokens.txt
  echo "PLAUSIBLE_SITE_ID=<customer.tld>" >> /root/studio-tokens.txt
  ```

### 6c. Cal.com API key

- [ ] Settings → **Developer → API keys** → **Add**
- [ ] Give it a name (`wire.sh`)
- [ ] Save:
  ```bash
  echo "CALCOM_API_KEY=<key>" >> /root/studio-tokens.txt
  ```

---

## Phase 7: Cloudflare Zero Trust — public hostnames

Configure ingress rules in the CF dashboard so the tunnel routes each
public URL to the right internal CT.

- [ ] CF dashboard → **Zero Trust → Networks → Tunnels →** *your tunnel*
- [ ] **Public Hostname** tab → **Add a public hostname** — five times:

| Public URL | Service (internal) |
|---|---|
| `<customer.tld>` | `http://ghost:2368` |
| `audit.<customer.tld>` | `http://ghost:2368` |
| `cal.<customer.tld>` | `http://calcom:3000` |
| `analytics.<customer.tld>` | `http://plausible:8000` |
| `tracking.<customer.tld>` | `http://plausible:8000` |

DNS CNAME records are auto-created for each hostname.

**Verify from your laptop** (not on the tailnet):
```bash
for sub in '' audit. cal. analytics. tracking.; do
  echo -n "https://${sub}<customer.tld>: "
  curl -sS -o /dev/null -w "%{http_code}\n" -m 10 "https://${sub}<customer.tld>/"
done
```

Expect five `200`s. If any are `502`/`521`/`1033`, the internal
hostname doesn't resolve or the target service isn't listening — check
that CT's addon logs.

---

## Phase 8: wire.sh — composition glue

The final piece. Five idempotent phases that connect the apps to each
other and to n8n.

```bash
cd /root/stacks/creator-studio
./wire.sh
```

Phases wire.sh runs:

1. **Ghost Code Injection** ← Plausible tracking snippet (via Ghost
   Admin API + `GHOST_ADMIN_API_KEY`)
2. **Cal.com event types** — creates `audit-consult` (30 min) +
   `compliance-discovery` (60 min) via Cal.com API
3. **Ghost webhook** — registers `post.published` → n8n
4. **Cal.com webhook** — registers `BOOKING_*` events → n8n
5. **Reachability check** — curls all 5 public URLs

Every phase is safely re-runnable. If Phase 3 says "SKIP:
`GHOST_ADMIN_API_KEY` missing", go back to Phase 6a, save the key, and
re-run `./wire.sh --phase 3` to catch just that one up.

**Result:** every internal integration is live. Publishing a post in
Ghost fires a message in Mattermost. Booking a Cal.com meeting fires a
message in Mattermost. Plausible tracking is embedded in every Ghost
page. All 5 public URLs return 200.

---

## Phase 9: Verify (final smoke tests)

### 9a. Reachability

Already run in Phase 8's Phase 5, but worth re-verifying from a fresh
browser tab (mobile carrier network is a good "cold" test):

- [ ] `https://<customer.tld>` — Ghost landing (default theme initially)
- [ ] `https://audit.<customer.tld>` — Ghost audit page (or landing
      until you build the audit theme)
- [ ] `https://cal.<customer.tld>` — Cal.com landing
- [ ] `https://analytics.<customer.tld>` — Plausible login page
- [ ] `https://tracking.<customer.tld>/js/script.js` — returns the
      Plausible tracker JS

### 9b. End-to-end integration

- [ ] Publish a test post in Ghost → message appears in Mattermost
      `#bot` channel within ~2 seconds
- [ ] Make a test booking on `cal.<customer.tld>` → message appears
      in Mattermost `#bot`
- [ ] Visit `<customer.tld>` in a browser → within ~1 minute, the
      visit shows up in Plausible dashboard
- [ ] Send yourself an email through any of the apps → arrives via
      Postmark and shows in Postmark's Activity view

### 9c. Backups + monitoring

- [ ] Run `ssh root@<pve-host> /usr/local/bin/td-health-check` — all green
- [ ] Wait until 09:00 (customer's local time) — the daily heartbeat
      posts to Mattermost `#bot` confirming everything is live
- [ ] Run first vzdump manually to seed a backup: `vzdump 300 301 302 303 304`

---

## Troubleshooting

The `sobol-foundation/TROUBLESHOOTING_LOG.md` has entries for the
common issues. Highlights specific to creator-studio:

| Symptom | Where to look |
|---|---|
| Cloudflare `502` / `521` / `1033` on a public URL | Wrong internal hostname in Public Hostname config, or upstream CT not responding on the expected port |
| Cal.com `500` on signup | Prisma migrations still running (wait 3 min) or `DATABASE_URL` typo in `/opt/calcom/.env` |
| Ghost won't start | Almost always `config.production.json` — `pct exec 300 -- su - ghost -c 'cd /var/www/ghost && ghost log'` |
| Plausible admin signup times out | ClickHouse still initializing on first boot (up to 2 min). Retry. |
| Mail delivery flaky, but Postmark says sent | DKIM or Return-Path CNAME not yet **Verified** in Postmark — go back to 0.3 and wait for both |
| wire.sh Phase 3/4 says "SKIP" | Missing API key in `/root/studio-tokens.txt` — Phase 6 |

---

## Where things live

| What | Where |
|---|---|
| Stack secrets | `/root/studio-tokens.txt` on PVE host (creator-studio-specific) |
| Foundation secrets | `/root/td-tokens.txt` on PVE host (inherited) |
| CF Tunnel config | Managed in CF Zero Trust dashboard (dashboard-first — no local `config.yml`) |
| Cloudflared service | CT 304, systemd-managed as `cloudflared.service` |
| Ghost config | CT 300, `/var/www/ghost/config.production.json` |
| Ghost data | CT 300, SQLite in `/var/www/ghost/content/data/` |
| Cal.com env | CT 302, `/opt/calcom/.env` |
| Plausible env | CT 301, `/opt/plausible/.env` |
| Postgres data | CT 303, `/var/lib/postgresql/16/main/` |
| Nightly DB backups | CT 303, `/var/backups/postgres-daily/` (14-day retention) |
| Vzdump backups | Wherever `usb-backup` PVE storage points (usually external USB) |
| Watchdog state | PVE host, `/var/lib/td-health/state.json` |

---

## After MVP

Once the customer is live and stable for 2-4 weeks, consider:

- **Cloudflare Access policies** to lock down `analytics.<customer.tld>`
  to specific emails (default is public Plausible login)
- **Content-editor persona** deployed to a new pi-agent CT for pre-
  publish review of Ghost drafts
- **Social-scheduler persona** deployed for Cal.com + Ghost timing
  coordination
- **Listmonk** in its own CT for newsletter sends (paired with
  Postmark for delivery)
- **CF Workers** in front of Ghost for sub-100ms TTFB worldwide
- **Staging environment** — copy of the stack on a `.dev` or
  `staging.` subdomain

---

## Uninstall / rollback

If the install goes sideways and you want a clean reset:

```bash
# Nuclear option — destroy all creator-studio CTs (300-304)
for id in 300 301 302 303 304; do
  pct stop $id 2>/dev/null
  pct destroy $id
done

# Remove the studio-tokens file
rm /root/studio-tokens.txt

# In the CF dashboard, delete the tunnel + DNS records
# (foundation CTs 100-215 are untouched)
```

Foundation-level uninstall is a separate process — see
`sobol-foundation/TROUBLESHOOTING_LOG.md`.

---

## Retirement notes

This RUNBOOK reflects the current install path as of 2026-07-01. Two
pieces are temporary:

1. **`studio-stack/automation/bootstrap-pve.sh`** (Phase 2b) is
   legacy — retiring when `setup-stack.sh` real dispatch lands.
2. **The tokens-file layout** may get consolidated in a future pass
   (right now we have `td-tokens.txt` + `studio-tokens.txt`
   coexisting; that's per §2.2 tokens-files-coexist convention).

When those change, this RUNBOOK gets an update. Check the CHANGELOG
for version transitions.
