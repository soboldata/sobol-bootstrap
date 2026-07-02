# Changelog

All notable changes to stack-creator-studio follow
[Keep a Changelog](https://keepachangelog.com/) format with semver per
`proxmox-stack-foundations/conventions.md` §4.

## [Unreleased]

Planned for v1.0.0:

- `config/homepage.overrides.yaml` (optional) — custom tile grouping
- Retire `../../studio-stack/` entirely (automation/ scripts retired
  when setup-stack.sh real dispatch lands; docs already ported)
- Add planned personas (post real-usage feedback):
  - content-editor (pre-publish review of Ghost drafts)
  - social-scheduler (Cal.com + Ghost coordination)
- First paying customer install (validates the runbook)
- End-to-end test on a 32GB Mini PC via the custom ISO
- Consider tightening n8n workflow CORS from `*` to the specific
  soboldata.com hostnames per intake-website workshop-decisions —
  this touches the intake-website workflow directly, so it lives in
  the intake-website repo more naturally than in wire.sh

## [0.9.0] - 2026-07-01

### Added

- **`RUNBOOK.md`** — ported + freshened from
  `../../studio-stack/RUNBOOK.md`. ~400 lines of operator-facing
  install procedure organized as ten phases:
  0. Prereqs (domain, CF tunnel, Postmark w/ DKIM + return-path,
     Tailscale, PVE host, scratch credentials file)
  1. Foundation bootstrap (`sobol-foundation` bootstrap-fresh-pve.sh)
  2. Vertical bootstrap (interim: `../../studio-stack/`; target:
     `setup-stack.sh creator-studio` when dispatch is real)
  3. Foundation configure (`sobol-foundation/automation/configure-apps.sh`)
  4. Vertical addons (5 library setup-*.sh in dependency order)
  5. Manual admin signups (Ghost/Plausible/Cal.com browser)
  6. Mint API keys (3 keys → studio-tokens.txt)
  7. CF Zero Trust hostnames (5 public URLs in CF dashboard)
  8. `wire.sh` (5 idempotent phases)
  9. Verify (reachability + end-to-end smoke tests)
- Troubleshooting table for the top 6 creator-studio-specific gotchas
  plus a "where things live" reference table
- "After MVP" pointers to Phase-2 add-ons (Listmonk, Twenty CRM,
  Documenso, CF Access policies, Workers, staging environment)
- Uninstall / rollback commands for a clean reset
- Retirement notes calling out which parts of the RUNBOOK are
  temporary (studio-stack Path 2b, tokens-file layout)

### Changed

- Version 0.8.0 → 0.9.0 (docs milestone — install path is now
  documented end-to-end; v1.0.0 requires first-customer validation +
  studio-stack retirement)

## [0.8.0] - 2026-07-01

### Added

- **`wire.sh` — first real composition-wiring script in the
  framework.** ~500 lines, five idempotent phases:
  1. **Ghost Code Injection** — inject the Plausible tracking
     `<script>` into Ghost's Settings → Code Injection → Site Header
     via the Ghost Admin API. JWT-signed with GHOST_ADMIN_API_KEY;
     preserves existing head injection; SKIP-idempotent if the
     snippet is already present.
  2. **Cal.com event types** — create `audit-consult` (30 min) +
     `compliance-discovery` (60 min) via the Cal.com API. GET first,
     skip existing slugs. Persist URLs to studio-tokens.txt as
     `CALCOM_AUDIT_URL` + `CALCOM_COMPLIANCE_URL` for
     intake-website consumption.
  3. **Ghost webhook** — register post.published → n8n's
     `/webhook/ghost-publish`. GET existing webhooks first; skip
     if already registered for our URL.
  4. **Cal.com webhook** — register BOOKING_CREATED / RESCHEDULED /
     CANCELLED → n8n's `/webhook/calcom-booking`. GET first,
     idempotent by subscriberUrl.
  5. **Reachability check** — curl all 5 public hostnames
     (soboldata.com, audit., cal., analytics., tracking.), report
     which return 200. Warnings-not-fails on missing hostnames
     (operator may still be adding them in CF dashboard).
- Each phase checks its prereqs and SKIPs with clear "come back
  after minting X API key" messaging when the operator hasn't
  finished manual admin signups yet. Safe to re-run wire.sh multiple
  times as prereqs are completed.
- `--phase N` flag runs a single phase (useful for iterating on one
  piece); `--dry-run` previews all changes; `--skip-check` short-
  circuits phase 5 in dev environments where the tunnel isn't fully
  configured yet.

### Design notes

- **JWT generation via inline `python3` heredoc.** Bash HMAC-SHA256
  is doable but fiddly; python stdlib (`hmac` + `hashlib` + `base64`)
  is cleaner and doesn't need any pip installs. GHOST_ADMIN_API_KEY
  is passed via env var (`GHOST_ADMIN_API_KEY="$api_key" python3 ...`)
  so it never appears on the command line — `ps aux` doesn't expose
  it.
- **Every phase is idempotent** per §2.2. GET-then-POST pattern
  everywhere: skip if the target state already matches, only mutate
  if new.
- **Every phase is skippable** per graceful-degradation: missing
  prereqs → SKIP with clear message + point at what to fix. Operator
  can re-run to pick up where they left off.
- **n8n CORS tightening deferred** — the intake-website workflow
  lives in the intake-website repo, so tightening its allowlist is
  more naturally that repo's job than wire.sh's. Noted in Unreleased.
- **First wire.sh in the framework.** Referenced from
  `../CLAUDE.md` as the model for future stacks. Framework
  convention (§2.1) says wire.sh is optional per stack; creator-
  studio exercises it fully.

### Changed

- Version 0.7.0 → **0.8.0** (minor bump reflects "composition wiring
  written and idempotent" — one step closer to v1.0.0)

## [0.7.0] - 2026-07-01

### Milestone

**All four vertical addons are now real in the library.** The
scaffolding phase of creator-studio is complete; remaining v1.0.0
work is composition-specific wiring + operator docs + real hardware
validation.

### Added

- **setup-cloudflared.sh promoted from stub to real** — landed in the
  library at `sobol-foundation/addons/setup-cloudflared.sh` (~300
  lines). Uses the dashboard-first model: installs the pinned
  cloudflared .deb, registers as a systemd-managed connector with
  `CF_TUNNEL_TOKEN`, lets the operator manage ingress rules in the CF
  Zero Trust dashboard (no local config.yml). Idempotent via a
  token-hash file — re-runs with the same token SKIP registration;
  rotated token → re-register. Waits for tunnel HA connections at CF
  edge before returning success; external reachability check is
  warning-not-fail (operator may still be adding public hostnames).
- **cloudflared-tunnel-health-to-mattermost.json workflow** shipped
  in the library. Cron (hourly, silent when healthy) + manual webhook
  `/cloudflared-status` (forces post regardless of state). Polls
  cloudflared's `:2000/metrics` endpoint, alerts on
  `cloudflared_tunnel_ha_connections == 0`. Fulfills §10.1.

### Changed

- Manifest `core_apps:` — cloudflared line no longer marked `(STUB)`
- Manifest `workflows:` — cloudflared-tunnel-health-to-mattermost added
- Version 0.6.3 → **0.7.0** (minor bump reflects the "all addons real"
  milestone)

### Design notes for future readers

- CF API automation (auto-create tunnel + configure ingress + create
  DNS records) was DEFERRED to a future version — it needs
  CF_API_TOKEN with broad scopes and adds significant complexity for
  marginal MVP benefit. Operator flow today: create the tunnel in the
  CF dashboard, copy the token to studio-tokens.txt, run this addon.
- The dashboard-first model was chosen over legacy config.yml
  intentionally. See the script header for the rationale (simpler
  token rotation, ingress edits auditable via CF UI, DNS auto-created).

## [0.6.3] - 2026-07-01

### Added

- **setup-calcom.sh promoted from stub to real** — landed in the
  library at `sobol-foundation/addons/setup-calcom.sh` (~390 lines).
  Runs Cal.com self-hosted via docker-compose inside the Cal.com CT;
  DATABASE_URL points at the shared Postgres CT (setup-postgres-shared.sh
  provisions `calcom_db`); pinned image + calcom/docker repo ref.
  Generates + persists `NEXTAUTH_SECRET` and `CALENDSO_ENCRYPTION_KEY`
  on first run. Refuses to rotate `CALENDSO_ENCRYPTION_KEY` without
  explicit interactive `ROTATE` confirmation (rotation would make
  encrypted calendar-integration DB rows unreadable — destructive).
  Runs `prisma migrate deploy` after start as belt-and-suspenders.
  Detects INSTALL vs RECONFIGURE mode.
- **calcom-booking-to-mattermost.json workflow** shipped in the
  library. Handles BOOKING_CREATED / RESCHEDULED / CANCELLED /
  MEETING_ENDED events with per-event emoji + verb formatting;
  attendee summary kept compact to avoid leaking full attendee lists.
  Fulfills §10.1: every addon ships ≥1 workflow.
- Event-type creation (audit-consult + compliance-discovery) is
  DEFERRED to a future `stacks/creator-studio/wire.sh` per the
  addon-vs-wiring convention (§2.1) — it's stack-specific business
  logic, not library material.

### Changed

- Manifest `core_apps:` — calcom line no longer marked `(STUB)`
- Manifest `workflows:` — calcom-booking-to-mattermost added
- Version 0.6.2 → 0.6.3
- Only Cloudflared remains stubbed. Three of four vertical apps down.

## [0.6.2] - 2026-07-01

### Added

- **setup-plausible.sh promoted from stub to real** — landed in the
  library at `sobol-foundation/addons/setup-plausible.sh` (~330 lines).
  Runs Plausible Community Edition + ClickHouse via docker-compose
  inside the Plausible CT; DATABASE_URL points at the shared Postgres
  CT (setup-postgres-shared.sh provisions `plausible_db`); ClickHouse
  is co-located in the same CT (event storage). Hard-pins image
  versions (`plausible/community-edition:v2.1.4`,
  `clickhouse/clickhouse-server:24.3.6.48-alpine`) so container
  recreation can't silently upgrade. Detects INSTALL vs RECONFIGURE
  mode. Docker-compose.override.yml disables the bundled postgres
  service via the `donotuse` profile.
- **plausible-weekly-digest-to-mattermost.json workflow** shipped in
  the library. Monday 9am cron (plus manual webhook) pulls last week's
  Plausible v2 query API stats (visitors, pageviews, visits, bounce
  rate, avg duration + top 5 pages), formats, posts to MM `#bot`.
  Fulfills §10.1: every addon ships ≥1 workflow.

### Changed

- Manifest `core_apps:` — plausible line no longer marked `(STUB)`
- Manifest `workflows:` — plausible-weekly-digest-to-mattermost added
- Version 0.6.1 → 0.6.2

## [0.6.0] - 2026-06-30

### Added

- **setup-ghost.sh promoted from stub to real** — `addons/setup-ghost.sh`
  (~360 lines) implements the flow that was previously documented only
  in stub comments:
  - Reads GHOST_CTID + DOMAIN + ADMIN_* + SMTP_* from studio-tokens.txt
  - Discovers Ghost's install user + directory via ghost-cli
  - Rewrites `config.production.json` via python (url, server bind, mail)
  - ghost stop → apply config → ghost start
  - Admin API setup (`POST /ghost/api/admin/authentication/setup/`) —
    idempotent; skips if already set up
  - Homepage tile registration (idempotent per convention)
  - Smoke test from PVE host
  - Ghost admin webhook wiring to n8n's ghost-publish flow is stubbed
    for MVP: needs GHOST_ADMIN_API_KEY minted manually, then
    `setup-ghost.sh --wire-webhook` re-runs. Post-MVP: mint via
    `POST /ghost/api/admin/integrations`.
- **ghost-publish-to-mattermost.json workflow** shipped
  (`addons/n8n/workflows/`) — Ghost's `post.published` webhook →
  Format headline/author/excerpt → post to Mattermost #bot channel.
  Response is 200 so Ghost doesn't retry. Fulfills §10.1 contract:
  every addon ships ≥1 workflow.

### Changed

- Manifest `core_apps:` — ghost line no longer marked `(STUB)`
- Manifest `workflows:` — `ghost-publish-to-mattermost` moved from
  commented-out "planned" list to active `workflows[]`
- postgres-shared comment updated: DB creation for plausible + calcom
  (ghost uses SQLite; doesn't need shared DB)

### Location convention (revised in v0.6.1)

Initial v0.6.0 placed setup-ghost.sh + workflow under
`stacks/creator-studio/addons/`. That was wrong — Ghost isn't
creator-studio-specific; any future stack that composes `ghost` could
reuse the same installer. See v0.6.1 below.

## [0.6.1] - 2026-07-01

### Changed

- **Ghost addon + workflow relocated to the library.** Moved from
  `stacks/creator-studio/addons/` to `sobol-foundation/addons/` per
  the crystallized addon-library-vs-stack-wiring convention (see
  `proxmox-stack-foundations/conventions.md`).
- Rule of thumb: addons that install ONE app belong in the reusable
  library at `sobol-foundation/addons/`. Only stack-specific WIRING —
  post-install glue, config overrides, multi-app orchestration
  specific to this composition — lives under `stacks/<name>/`.
- creator-studio manifest still declares `ghost` in `core_apps[]` and
  `ghost-publish-to-mattermost` in `workflows[]`; the setup-stack.sh
  resolver finds them in the library.
- Cleared the empty `stacks/creator-studio/addons/` tree.

## [0.5.0] - 2026-06-29

### Added

- Initial manifest.yaml declaring the v1.0.0 contract
- README documenting current state vs. planned v1.0.0 punch list
- Implicit scaffolding (currently in `../studio-stack/`):
  - bootstrap-pve.sh creates 5 vertical CTs (300-304)
  - configure-apps.sh orchestrates the addon chain
  - setup-postgres-shared.sh (~340 lines, real)
  - setup-email-relay.sh + setup-pve-email.sh (real, inherited from
    foundations)

### Stubbed (awaiting implementation for v1.0.0)

- setup-ghost.sh — comments document the planned flow
- setup-plausible.sh — comments document the planned flow
- setup-calcom.sh — comments document the planned flow
- setup-cloudflared.sh — comments document the planned flow

### Implementation status summary

The gap between v0.5.0 (current) and v1.0.0 (manifest intent) is the
implementation of the four stubbed vertical addons plus three planned
workflows plus two planned personas. See README.md "Path to v1.0.0"
for the punch list.

The setup-stack.sh runner reads this manifest and currently SKIPS the
stubbed apps (with a clear warning) while completing the rest of the
install. Customers signing for v0.5.0 know they're alpha; v1.0.0 marks
"first paying customer can complete the runbook end-to-end without
operator hand-holding for stubbed components."
