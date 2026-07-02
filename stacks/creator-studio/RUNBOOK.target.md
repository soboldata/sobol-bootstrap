# Creator Studio — Runbook (Target State)

**This is the target-state install runbook** — what a creator-studio
install will look like once `setup-stack.sh` real dispatch lands.
Draft dated 2026-07-01. Live version is `RUNBOOK.md`; this doc is
the framework's north star for the retirement work.

When `setup-stack.sh` dispatch is real, this doc becomes `RUNBOOK.md`
and the current one moves to `RUNBOOK-v0.9.md` (or gets deleted).

---

## Why write this now

Two reasons:

1. **Spec for the setup-stack.sh implementation.** Reading this
   backwards tells you what dispatch has to do. It's the concrete
   target the framework work aims at.
2. **Honest positioning for prospective customers.** "Here's what
   installing this stack will look like in a few weeks" lets the
   sales conversation be about the destination, not the interim.

---

## Before / after — the collapse

The current `RUNBOOK.md` has ten phases. This target has seven.
Where the four phases went:

| Current phase | Target | Reason |
|---|---|---|
| 2. Vertical bootstrap | Merged into Phase 2 (single command) | `setup-stack.sh` walks manifest.core_apps and creates any missing CTs via community-scripts helpers |
| 3. Foundation configure | Merged into Phase 1 | The one-liner bootstrap already invokes configure-apps.sh; no separate step |
| 4. Vertical addons | Merged into Phase 2 (single command) | `setup-stack.sh` walks manifest.core_apps and runs each `setup-<name>.sh` in dependency order |
| 8. wire.sh | Merged into Phase 2 (single command) | `setup-stack.sh` runs `wire.sh` at the end (5-phase graceful-skip means it does what it can and leaves the rest to a follow-up run) |

**Phases 5, 6, 7 (manual admin signups, API-key minting, CF public-hostname configuration) do NOT collapse.** Those are upstream limits — Ghost/Plausible/Cal.com don't expose API paths for first-admin creation, and Cloudflare's Zero Trust ingress config is a customer-facing thing that should stay in the CF UI. The target flow keeps them as explicit human steps between the two `setup-stack.sh` invocations.

---

## Order of operations (target)

```
0. Prereqs (do these BEFORE running any scripts)
1. Foundation install     — one-liner curl
2. Commercial stack install (mechanical) — setup-stack.sh creator-studio
3. Manual admin signups    — Ghost, Plausible, Cal.com (browser required)
4. Mint API keys           — save 3 keys to studio-tokens.txt
5. CF Zero Trust hostnames — add 5 public hostnames in CF dashboard
6. Complete wiring         — setup-stack.sh creator-studio --continue
7. Verify                  — reachability + smoke tests
```

Human time: ~90 minutes total, ~30 of it hands-on. Machine time:
~45 minutes wall clock across phases 1 and 2, mostly unattended.

---

## Phase 0: Prereqs

Unchanged from `RUNBOOK.md` §0. Same checklist:

- 0.1 Domain on Cloudflare (Add Site, not registrar transfer)
- 0.2 Cloudflare Tunnel created, `CF_TUNNEL_TOKEN` in hand
- 0.3 Postmark account, sender verified, DKIM + Return-Path CNAMEs green
- 0.4 Tailscale reusable auth key on customer's tailnet
- 0.5 PVE host ready (PVE 9.x, 32GB RAM recommended, 500GB SSD)
- 0.6 Scratch credentials file at `/tmp/studio-prereqs.txt`

---

## Phase 1: Foundation install

```bash
ssh root@<pve-host>
curl -fsSL http://gitea:3000/td/sobol-foundation/raw/branch/main/bootstrap-fresh-pve.sh | bash
```

Same as today. Idempotent. Creates the 5 foundation CTs + joins tailnet
+ configures Homepage + wires foundation credentials into
`/root/td-tokens.txt`.

**Terminates at:** foundation running.

---

## Phase 2: Commercial stack install (mechanical)

```bash
cd /root
git clone http://gitea:3000/td/stacks.git
./stacks/../proxmox-stack-foundations/setup-stack.sh creator-studio
```

Or equivalent one-liner:

```bash
curl -fsSL http://gitea:3000/td/proxmox-stack-foundations/raw/branch/main/setup-stack.sh | \
  bash -s -- creator-studio
```

`setup-stack.sh` walks the creator-studio manifest and performs:

1. **Validate** the manifest (identity, apps, capacity floor, dependency
   chain against sobol-foundation)
2. **Resolve inheritance** — union creator-studio's core_apps with
   sobol-foundation's; dedupe; sort by declared install order
3. **Classify** each app: **INSTALL** (missing) / **RECONFIGURE**
   (present, run configure step) / **SKIP** (already at target state)
4. **Print the plan** — dry-run summary the operator confirms
5. **Create missing CTs** — walks any app that's INSTALL, invokes the
   community-scripts helper (ct/debian.sh / ct/docker.sh / ct/postgres.sh
   / etc.) with the right resource specs from `manifest.capacity`
6. **Run each library setup-*.sh** in dependency order, honoring
   INSTALL/RECONFIGURE/SKIP classification for each
7. **Import n8n workflows** — walks `manifest.workflows[]`, imports
   each from `sobol-foundation/addons/n8n/workflows/` inactive
8. **Deploy default_personas** — walks `manifest.default_personas[]`,
   invokes `pi-personas/deploy-persona.sh`
9. **Run stacks/creator-studio/wire.sh** — 5 idempotent phases,
   graceful-skip on missing prereqs (which is expected on first run —
   the operator hasn't done Phases 3-5 yet)
10. **Emit the next-steps banner** — clear list of what the operator
    must do manually before running `--continue`

**Output the operator sees at the end:**

```
[setup-stack] ================================================================
[setup-stack] creator-studio install: mechanical steps complete.
[setup-stack]
[setup-stack] To finish the install, complete these manual steps:
[setup-stack]
[setup-stack]   1. Browser sign-ups:
[setup-stack]      - http://ghost:2368/ghost/setup
[setup-stack]      - http://plausible:8000/register
[setup-stack]      - http://calcom:3000/auth/setup
[setup-stack]
[setup-stack]   2. Mint 3 API keys and save to /root/studio-tokens.txt:
[setup-stack]      - GHOST_ADMIN_API_KEY
[setup-stack]      - PLAUSIBLE_API_KEY (also PLAUSIBLE_SITE_ID)
[setup-stack]      - CALCOM_API_KEY
[setup-stack]
[setup-stack]   3. Add 5 public hostnames in the CF Zero Trust dashboard:
[setup-stack]      soboldata.com                → http://ghost:2368
[setup-stack]      audit.soboldata.com          → http://ghost:2368
[setup-stack]      cal.soboldata.com            → http://calcom:3000
[setup-stack]      analytics.soboldata.com      → http://plausible:8000
[setup-stack]      tracking.soboldata.com       → http://plausible:8000
[setup-stack]
[setup-stack]   When done, run:
[setup-stack]     setup-stack.sh creator-studio --continue
[setup-stack] ================================================================
```

---

## Phase 3: Manual admin signups

Same as `RUNBOOK.md` §5. Upstream limit. Not automatable.

- Ghost `/ghost/setup`
- Plausible `/register` + add site
- Cal.com `/auth/setup`

---

## Phase 4: Mint API keys

Same as `RUNBOOK.md` §6.

- `GHOST_ADMIN_API_KEY` — Ghost Settings → Integrations
- `PLAUSIBLE_API_KEY` + `PLAUSIBLE_SITE_ID` — Plausible User → API keys
- `CALCOM_API_KEY` — Cal.com Settings → Developer → API keys

All saved to `/root/studio-tokens.txt`.

---

## Phase 5: CF Zero Trust hostnames

Same as `RUNBOOK.md` §7. Add 5 public hostnames in CF dashboard.
DNS CNAMEs auto-create.

---

## Phase 6: Complete wiring

```bash
setup-stack.sh creator-studio --continue
```

`--continue` mode:
1. Re-runs `wire.sh` (5 phases, now with prereqs met)
2. Re-runs `setup-cloudflared.sh` (external reachability check will
   now pass with hostnames configured)
3. Emits final success banner

**wire.sh phases** (unchanged from today):
1. Ghost Code Injection ← Plausible tracking snippet
2. Cal.com event types (audit-consult + compliance-discovery)
3. Ghost post.published webhook → n8n
4. Cal.com booking webhook → n8n
5. Public reachability check across 5 hostnames

---

## Phase 7: Verify

Same as `RUNBOOK.md` §9. End-to-end smoke tests:

- Publish a test post in Ghost → message in Mattermost #bot
- Make a test Cal.com booking → message in Mattermost #bot
- Visit `<domain>` → visit shows in Plausible dashboard
- Backups seeded, watchdog reporting green, daily heartbeat firing

---

## What setup-stack.sh needs to implement (spec)

For this target-state RUNBOOK to become reality, `setup-stack.sh`'s
skeleton install functions need real implementations:

### `resolve_inheritance_chain(stack_name)`
- Read stack's `manifest.yaml`
- Follow `inherits.base_stack` recursively (currently just one level:
  sobol-foundation)
- Refuse if `inherits.base_stack_version` isn't satisfied by the
  installed base
- Return: dedup'd list of core_apps in install order (base's first,
  then this stack's additions)

### `classify_apps(app_list)`
For each app, determine INSTALL / RECONFIGURE / SKIP:
- **INSTALL**: `pct list | grep <hostname>` empty
- **RECONFIGURE**: CT exists, run addon's configure path
- **SKIP**: CT exists AND addon's state marker (`/root/.setup-<name>.done`
  or similar) matches expected version

### `install_features(feature_map)`
- Walk `manifest.features` (e.g. `email_relay: required`)
- For each `required` feature, check host-level state (e.g.
  `/etc/postfix/main.cf` has SMTP relay lines)
- Skip if satisfied. Install if missing.

### `install_core_apps(app_list)`
- For each app in the classified list:
  - INSTALL: run community-scripts helper via
    `bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/<name>.sh)"`
    with resource specs from `manifest.capacity`
    then run `sobol-foundation/addons/setup-<name>.sh`
  - RECONFIGURE: just run the addon (it's idempotent)
  - SKIP: log and move on

### `import_workflows(workflow_list)`
- Walk `manifest.workflows[]`
- For each, POST the JSON at
  `sobol-foundation/addons/n8n/workflows/<name>.json` to n8n's
  `/api/v1/workflows` endpoint (already implemented in setup-n8n.sh —
  extract into a callable function)
- Import inactive so the operator activates after binding credentials

### `deploy_default_personas(persona_list)`
- Walk `manifest.default_personas[]`
- For each, invoke `pi-personas/deploy-persona.sh <name>`

### `run_wire_sh(stack_name)`
- If `stacks/<stack_name>/wire.sh` exists, run it
- Always runs, even on `--continue` — the graceful-skip pattern
  handles idempotence

### `--continue` mode
- Skip everything up to and including `install_core_apps` (already
  done)
- Re-run `wire.sh` + `setup-cloudflared.sh` external reachability
- Emit final success banner

### State file at `/root/installed-stacks.json`
- Track: which stacks are installed at what versions, which shared
  addons each depends on
- Enables uninstall logic per §2.2 (last-dependent-removed → offer
  to clean up shared addons)

---

## Migration from current to target

When setup-stack.sh dispatch lands, the migration steps are:

1. **Verify setup-stack.sh implements everything above** — dry-run
   against a fresh host, walk the plan
2. **Test end-to-end** on the 32GB Mini PC — same customer path
3. **Update `RUNBOOK.md`** — rename current to `RUNBOOK-v0.9.md`,
   rename this doc to `RUNBOOK.md`
4. **Retire `../../studio-stack/`** — automation scripts go
5. **Cut `stacks/creator-studio` to v1.0.0** — no more caveats about
   Path 2b or SKELETON runners

Estimated timeline: 1-2 weeks of framework work + real hardware
validation.

---

## What doesn't change

Deliberately keeping these the same, even in the target state:

- **Manual browser signups** — upstream limit, can't automate
- **API key minting** — upstream limit
- **CF Zero Trust hostname config** — we deliberately chose
  dashboard-first over local config.yml
- **wire.sh's 5-phase structure** — already the right shape,
  already idempotent
- **Prereq checklist** — same 6 items
- **Verify phase** — same smoke tests

The framework work is about collapsing the mechanical steps into
`setup-stack.sh`. The human-shaped steps stay put.