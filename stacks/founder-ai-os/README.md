# stack-founder-ai-os

The premium tier. An AI workforce for ambitious solo founders, inspired
by Dan Martel's "Buy Back Your Time" framework.

## The thesis

A solo founder has 1,000 things competing for attention. The traditional
answer is "hire people." The faster, cheaper answer in 2026 is "deploy a
team of role-specific AI agents."

But that's not "ChatGPT in a tab." It's a **team** — each persona with
its own:

- **Lane** (gatekeeper handles inbound; ops-director coordinates internal
  work; customer-voice speaks to customers)
- **Voice** (each persona's SYSTEM.md captures personality, tone,
  bounded authority)
- **Surface** (each persona lives in its own Mattermost channel +
  responds to @mentions)
- **State** (each persona has memory; cross-agent state is mediated by
  the Chief Python orchestration backend)

The founder doesn't manage prompts. They run a small office where
specialized workers handle their lanes and check in via the team's
shared chat.

## What ships

| Layer | Components |
|---|---|
| **Operations** (inherited from sobol-foundation) | Gitea, Mattermost, n8n, Homepage, Ollama-pi-agent |
| **The 5 Default Personas** | Gatekeeper, Ops Director, Customer Voice, Content Engine, Growth Analyst |
| **Chief Python Services** | FastAPI orchestration backend — cross-agent handoffs + shared state |
| **The Factory** | `setup-new-pi-agent.sh` provisions persona N+1 with one command |
| **Required Infrastructure** | Email relay, daily backups, hourly watchdog, daily heartbeat |

Plus a stable of additional personas available via `pi-personas/`
(code-reviewer, ops-engineer, digest-comms, trading-assistant) that can
be deployed on demand.

## Tier

`premium` — the heaviest, most capability-rich Sobol Data tier. Floor
is 32GB RAM / 8 cores / 500GB. Recommended is 64GB / 8+ cores / 1TB.

## Inherits from

`stack-sobol-foundation >= 1.0.0` for the operations layer. Adds:

- 5 additional `pi-agent-*` CTs (one per default persona)
- 1 Chief Python services CT
- New required features: `new_pi_agent`, `persona_orchestration`,
  `config_backup`, `usb_backup_target`

## Current state — v0.7.0 (beta)

What exists:

- ✅ founder-ai-os-proxmox-stack.md (the design doc — task #149)
- ✅ Starter kit: factory script + Gatekeeper persona + n8n workflow (#150)
- ✅ 5 persona scaffolds + Chief Python services + setup scripts (#151)
- ✅ Standalone packaging (no TD-Proxmox runtime dependency — #154)
- ✅ Manifest now declares the v1.0.0 contract

What's missing to reach v1.0.0:

- ❌ End-to-end install on a fresh PVE host (validates 32GB capacity floor)
- ❌ First paying customer (validates the runbook + handoff)
- ❌ Cross-agent orchestration workflows (the 4 planned `persona-*` workflows)
- ❌ Per-persona daily heartbeats (the premium observability promise)
- ❌ Shared inference optimization (run Ollama once, agents call shared
  endpoint vs. each persona running its own — post-v1.0 optimization)

## Why this tier costs more

Beyond pure compute (32-64GB hardware = $700-1200 retail), the premium
tier carries higher operator cost:

- **5 personas to keep behaving** — each one's SYSTEM.md + AGENT.md
  needs maintenance as the founder's business evolves
- **Cross-agent coordination is the hardest design problem** — when
  two personas disagree, who wins? The Chief Python services
  arbitrate, but the arbitration rules are the operator's job to
  tune for each customer
- **Faster SLA** — Premium Managed Support is required (Standard isn't
  offered) because 5 concurrent personas mean more surface area to
  monitor

That's why pricing starts at $5000 BYO / $7000 Shipped + $2000/mo
minimum (Pro Managed Support). Customers paying this expect their
agents to feel like a team that showed up to work — not a tab they
have to drive.

## Pricing

| SKU | $ | Includes |
|---|---|---|
| Founder AI OS BYO | 5000 | Install on customer hardware (32GB+ required) |
| Founder AI OS Shipped | 7000 | + Pre-imaged 64GB Mini PC |
| Managed Pro | 2000/mo | 4-hour SLA, 2 personas/quarter, quarterly review |
| Managed Premium | 4000/mo | 1-hour SLA, 4 personas/quarter, monthly roadmap |

**Note: Standard managed support is NOT offered for this tier** — the
operational complexity makes NBD response inadequate. Pro is the floor.

See `sobol-business/OFFERINGS.md` §1B and the (planned) vertical
landing page at `https://soboldata.com/founder-ai-os` for the full
positioning.

## Path to v1.0.0

The implementation punch list:

- [ ] End-to-end install test on a 64GB host (preferably via custom ISO)
- [ ] First paying customer install (validates handoff runbook)
- [ ] Write the 4 cross-agent orchestration workflows:
  - [ ] `persona-handoff-coordinator.json`
  - [ ] `daily-orchestrator-standup.json`
  - [ ] `weekly-founder-state-of-the-os.json`
  - [ ] `persona-conflict-resolver.json`
- [ ] Add per-persona daily heartbeats
- [ ] Document the persona-arbitration rules so they're configurable
      per-customer (not hardcoded)
- [ ] Decide and document shared-inference optimization plan

Realistic v1.0.0 timing: 4-6 weeks of focused build, gated on customer
demand. We don't push for v1.0 in absence of a paying customer who
NEEDS it.

## Related repos

- `proxmox-stack-foundations` — framework + contracts
- `stack-sobol-foundation` — base operations layer
- `stack-creator-studio` — adjacent tier; some customers may migrate up
- `stack-sobol-mirror` — wedge tier; some Mirror customers may grow into this
- `pi-personas` — persona definitions (5 default Founder AI OS personas
  + others available on demand)
- `sobol-business` — GTM, OFFERINGS, runbooks

## License

All rights reserved. Internal/customer use only.

## Maintainer

Sobol Data.
