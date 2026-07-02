# stack-sobol-mirror

The wedge product. Read-only sync from customer SaaS + AI agents.

## What this is

A self-hosted Proxmox-based stack that **sits alongside** the customer's
existing SaaS (Slack, QuickBooks, HubSpot, Notion, Gmail) — reading their
data into a local Postgres mirror and running AI agents on top — without
requiring the customer to migrate off anything.

The product thesis (full version: `sobol-business/gtm/read-only-sync.md`):

> Small businesses pay 8-20% of revenue to SaaS. They can't switch
> overnight. Asking them to "rip out QuickBooks/Slack/HubSpot and
> self-host" is a 6-month sales cycle. "Keep everything you have. We
> read your data and run agents on top. Decide after 30 days what to
> keep, migrate, or cancel" is a 2-week sales cycle.

## Tier

`mirror` — deliberately lighter than office-in-a-box. Lightness IS the
sales pitch. See `manifest.yaml` for the exact app set.

## Inherits from

`stack-sobol-foundation >= 1.0.0` — uses the foundation's bootstrap,
addon library, and conventions. This stack's manifest is a *delta*
declaration on top.

## What ships at v1.0.0 (MVP)

| Component | Status |
|---|---|
| postgres-mirror CT | ✅ Built |
| Slack connector (schema + n8n workflow + 8 agent views) | ✅ Built |
| comms-agent persona | ✅ Drafted |
| comms-agent-digest workflow (9am daily) | ✅ Built |
| Mattermost + n8n + ollama-pi-agent + homepage | ✅ Inherited from sobol-foundation |
| QuickBooks connector | 🚧 Planned v1.1 |
| Google Workspace connector | 🚧 Planned v1.1 |
| Notion connector | 🚧 Planned v1.1 |
| HubSpot connector | 🚧 Planned v1.1 |

## Pricing

| SKU | $/mo | Includes |
|---|---|---|
| Trial | 49 one-time | 30 days, 2 connectors, 1 agent |
| Solo | 99 | 3 connectors, 2 agents |
| Team | 249 | 6 connectors, 4 agents |
| Pro | 499 | Unlimited connectors + agents, priority support |

See `sobol-business/OFFERINGS.md` §1A for tier definitions and
`sobol-business/gtm/read-only-sync.md` for sales motion.

## How to install

```bash
# On a fresh PVE host (use the custom ISO from sobol-business/tools/
# OR install PVE manually and clone the framework)
setup-stack.sh sobol-mirror
```

For the customer flow, see `sobol-business/runbooks/first-customer-install.md`.

## Related repos

- `proxmox-stack-foundations` — framework + manifest spec + conventions
- `stack-sobol-foundation` — the base this inherits from
- `pi-personas` — `comms-agent/` persona definition
- `sobol-business` — GTM, runbooks, ISO toolchain

## License

All rights reserved. Internal/customer use only.

## Maintainer

Sobol Data.
