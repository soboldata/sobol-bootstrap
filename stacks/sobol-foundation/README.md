# stack-sobol-foundation

The foundation tier — the baseline self-hosted office stack that all
Sobol Data commercial stacks (sobol-mirror, creator-studio,
founder-ai-os) inherit from.

## What this is

A Proxmox-based stack delivering:

- **Chat** — Mattermost (team comms + bot surface for AI personas)
- **Code repo** — Gitea (private git host, webhooks, CI later)
- **Workflow engine** — n8n (the integration tier; every addon ships
  ≥1 workflow that exercises it)
- **Dashboard** — Homepage (auto-registered tiles per addon)
- **Local LLM agent** — ollama-pi-agent (Ollama + pi runtime; the
  surface AI personas inhabit)
- **Email layer** — Postmark SMTP relay used by PVE + Gitea + watchdog
- **Backup layer** — vzdump nightly + optional USB target
- **Observability** — hourly health watchdog → Mattermost + email,
  daily heartbeat

This is the **most-tested Sobol build** to date. Three real-hardware
ISO iterations have validated the unattended install path end-to-end.

## Lineage

This stack is the active continuation of **TD-Proxmox**. The original
TD-Proxmox build was shared publicly as a reference for the author's
trading group and is now archived at
`github.com/artofax/td-proxmox` tag `v1.0.0-archive`.

The public archive does not evolve. New addon work, bootstrap
improvements, and tier-defining features land here in
`sobol-foundation/` going forward.

## Tier

`foundation` — every other Sobol Data stack inherits from this via
`inherits.base_stack: sobol-foundation` in its manifest. Not a
commercial SKU on its own; it's the baseline the commercial tiers
build on.

## Inherits from

Nothing. This is the root of the inheritance tree. Inherits only the
framework spec from `proxmox-stack-foundations/` (rules, not code).

## What inherits from this

| Stack | Tier | Status |
|---|---|---|
| `sobol-mirror` | mirror | v1.0.0 — wedge product, ready |
| `creator-studio` | office-in-a-box | v0.5.0 — alpha, 4 vertical addons stubbed |
| `founder-ai-os` | premium | v0.7.0 — needs first paying customer to validate |

## Current state — v1.0.0

| Component | Status |
|---|---|
| Bootstrap → 5 core CTs | ✅ Tested, idempotent |
| Tailscale layer | ✅ Tested, reusable-key support |
| Email layer (Postmark + Gitea + watchdog) | ✅ Tested end-to-end |
| Backup layer (vzdump + USB target + path discovery) | ✅ Tested |
| Health watchdog (hourly + heartbeat → Mattermost + email) | ✅ Tested |
| Custom ISO toolchain (PAI + first-boot) | ✅ Validated through 3 real-hardware iterations |
| 8 reference n8n workflows | ✅ Imported inactive, operator activates |
| 4 personas drafted | ✅ Available, none default-deployed |

## Install

```bash
# From a fresh PVE host
curl -fsSL https://gitea:3000/td/sobol-foundation/raw/branch/main/bootstrap-fresh-pve.sh | bash
```

For unattended install on customer hardware, use the custom-ISO
toolchain at `sobol-business/tools/build-customer-iso.sh` to bake a
customer-specific ISO that runs the bootstrap on first boot.

## Customizing this stack for a customer

Don't fork. Use the customer overlay pattern documented in
`proxmox-stack-foundations/conventions.md` §5: a per-customer
`customer-<id>/` repo declares an `overlay.yaml` that references this
stack by version, then adds the customer-specific deltas.

## Repo layout reminder

The runtime code (addons, bootstrap, automation) lives at
`/sobol-foundation/` (sibling to this `stacks/` folder). This
`stacks/sobol-foundation/` folder holds only the manifest declaration
that `setup-stack.sh` reads to plan an install.
