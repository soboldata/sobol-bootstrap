# stack-creator-studio

The publishing-and-scheduling office-in-a-box for solo creators and small
studios (1-10 people). This is the soboldata.com dogfood stack — the one
we run our own business on — and the first commercial SKU after the
Sobol Mirror wedge.

## What's in the box

| Layer | Apps |
|---|---|
| **Publishing** | Ghost (CMS), Cloudflared (public tunnel) |
| **Engagement** | Plausible (privacy-first analytics), Cal.com (scheduling) |
| **Shared DB** | Postgres (used by Ghost + Plausible + Cal.com) |
| **Operations** | Gitea, Mattermost, n8n, Ollama-pi-agent, Homepage, FileBrowser |
| **Infrastructure** | Email relay, watchdog, nightly backups, daily heartbeat |

Plus optional add-ons (Sandbox for Docker tinkering, OpenWebUI for
browser LLM chat) and a planned persona library (content-editor,
social-scheduler).

## Why this tier

Creators paying $100-300/month across SaaS subscriptions (Ghost Pro,
Plausible Cloud, Calendly, Substack revenue cut) save the recurring
cost AND gain:

- **Privacy** — data stays on customer hardware
- **Custom domain control** — Cloudflared tunnel does the public-access
  routing without exposing any port to the LAN
- **Agent leverage** — content-editor reviews drafts before publish,
  social-scheduler coordinates Cal.com + Ghost timing
- **No platform risk** — no algorithm changes, no policy changes, no
  account suspensions

## Tier

`office-in-a-box` — the most-included tier so far. Full sobol-foundation
foundation + 5 vertical apps.

## Inherits from

`stack-sobol-foundation >= 1.0.0`. Adds 5 vertical apps + the
`cloudflared_tunnel` feature key (new at this tier).

## Current state — v0.5.0 (alpha)

The scaffolding is complete:

- ✅ bootstrap-pve.sh creates the 5 vertical CTs (300-304)
- ✅ configure-apps.sh orchestrates the addons
- ✅ postgres-shared addon (~340 lines, real)
- ✅ Email relay layer inherited from foundations

But the four vertical app installers are currently **STUBS** — their
`setup-<app>.sh` scripts document the planned flow but exit early
without doing the actual config work:

- 🚧 `setup-ghost.sh` — STUB (planned: config.production.json, admin
  user, audit page route, Plausible JS inject)
- 🚧 `setup-plausible.sh` — STUB (planned: docker-compose, ClickHouse,
  first site, JS snippet emit)
- 🚧 `setup-calcom.sh` — STUB (planned: docker, .env, first admin,
  audit-consult + compliance-discovery event types)
- 🚧 `setup-cloudflared.sh` — STUB (planned: tunnel creation, 3
  hostname routes, DNS record creation via CF API)

Until those land, this manifest declares **intent**. The `setup-stack.sh`
runner will skip the stubbed apps with a warning and complete the rest
of the install.

## Path to v1.0.0

The implementation punch list to graduate from alpha to 1.0.0:

- [ ] Implement `setup-ghost.sh` per its inline TODO comments
- [ ] Implement `setup-plausible.sh` per its inline TODO comments
- [ ] Implement `setup-calcom.sh` per its inline TODO comments
- [ ] Implement `setup-cloudflared.sh` per its inline TODO comments
- [ ] Build `ghost-publish-to-mattermost.json` workflow (notification on publish)
- [ ] Build `plausible-anomaly-to-mattermost.json` workflow (traffic anomaly alerts)
- [ ] Build `calcom-booking-to-mattermost.json` workflow (new booking alerts)
- [ ] Draft `content-editor` persona (pre-publish review)
- [ ] Draft `social-scheduler` persona (timing orchestration)
- [ ] End-to-end test on a 32GB Mini PC via custom ISO
- [ ] Migrate implementation from `../studio-stack/` into this folder
- [ ] First paying customer end-to-end install (validates the runbook)

Each item is roughly 1-3 hours of focused work. Realistic v1.0.0
landing: ~2-3 weeks of evenings.

## Pricing

| SKU | $ | Includes |
|---|---|---|
| Studio Stack BYO | 2500 | Install on customer's hardware, 30-day support |
| Studio Stack Shipped | 3500 | + Pre-imaged Mini PC (Beelink/Minisforum class) |
| Managed Standard | 500/mo | NBD SLA, 1 new persona/quarter |
| Managed Pro | 1000/mo | 4-hour SLA, 2 personas/quarter |
| Managed Premium | 2000/mo | 1-hour SLA, 4 personas/quarter, roadmap input |

See `sobol-business/OFFERINGS.md` §1B for tier definitions and
`sobol-business/runbooks/first-customer-install.md` for fulfillment.

## Migration note

The implementation files currently live at `../studio-stack/` per the
older naming. Per `proxmox-stack-foundations/conventions.md` §3, this
folder uses the canonical `stack-creator-studio` name. The folder
rename + git history merge is a planned migration step — for tonight,
this manifest captures the contract and points at the legacy
implementation path until then.

## Related repos

- `proxmox-stack-foundations` — framework + manifest spec + conventions
- `stack-sobol-foundation` — the base this inherits from
- `stack-sobol-mirror` — the wedge that customers may upgrade from
- `pi-personas` — agent definitions (content-editor + social-scheduler
  pending)
- `sobol-business` — GTM, OFFERINGS, runbooks, ISO toolchain
- `intake-website` — lead capture; vertical landing page at
  `https://soboldata.com/creator-studio` (TBD)

## License

All rights reserved. Internal/customer use only.

## Maintainer

Sobol Data.
