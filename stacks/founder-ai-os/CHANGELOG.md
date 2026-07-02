# Changelog

All notable changes to stack-founder-ai-os follow
[Keep a Changelog](https://keepachangelog.com/) format with semver per
`proxmox-stack-foundations/conventions.md` §4.

## [Unreleased]

Planned for v1.0.0:

- End-to-end install test on a 64GB host via custom ISO
- First paying customer install (validates the runbook + handoff)
- Build the 4 cross-agent orchestration workflows:
  - `persona-handoff-coordinator.json` — task handoff via MM threads
  - `daily-orchestrator-standup.json` — 9am roll-call from each persona
  - `weekly-founder-state-of-the-os.json` — Friday status from Chief Python
  - `persona-conflict-resolver.json` — arbitration when personas disagree
- Add per-persona daily heartbeats (premium observability promise)
- Document persona-arbitration rules so they're configurable per-customer
- Decide + implement shared-inference optimization (single Ollama vs.
  per-persona Ollama)

## [0.7.0] - 2026-06-29

### Added

- Initial manifest.yaml declaring the v1.0.0 contract
- README documenting positioning, current state, path to v1.0.0
- Implicit scaffolding from prior session tasks:
  - Founder AI OS design doc (founder-ai-os-proxmox-stack.md)
  - Starter kit: factory script + Gatekeeper persona + first n8n workflow
  - 5 persona scaffolds (Gatekeeper, Ops Director, Customer Voice,
    Content Engine, Growth Analyst)
  - Chief Python services scaffold
  - Standalone packaging (no TD-Proxmox runtime dependency)

### Stack-spec patterns this manifest validates

- `tier: premium` (vs. foundation, mirror, office-in-a-box) — first
  premium-tier manifest, validates pricing-as-positioning at the top
  of the ladder
- `default_personas`: 5 auto-deployed personas (largest yet) — first
  stack where the personas ARE the product, not a post-install option
- New `features` keys: `persona_orchestration: required`,
  `new_pi_agent: required`, `usb_backup_target: required`,
  `config_backup: required` — premium tier upgrades several optional
  features to required
- Capacity floor of 32GB / 8 cores — first manifest where the
  hardware tier explicitly constrains BYO customers (8GB / 16GB
  hardware is rejected at the manifest level)
- `monthly_support_tiers` does NOT include `standard` — first manifest
  to validate "this tier requires premium support; Standard not
  offered" via the absence of the field

### Implementation gap

Manifest declares v1.0.0 intent. Reality is v0.7.0 — scaffold +
persona definitions exist but the end-to-end install + cross-agent
orchestration aren't validated against a paying customer. README has
the punch list.

### Open architectural questions for v1.0.0

1. **Per-persona Ollama vs. shared inference**: do we run 5 Ollama
   instances (one per pi-agent CT) or a single Ollama that all
   personas call? Per-persona is simpler architecturally but 5x the
   model memory cost. Shared is more efficient but adds dependency.
   Decision blocked on first-customer load test.

2. **Persona-arbitration rules**: when ops-director and customer-voice
   disagree on a thread routing, who wins? Each customer probably has
   different rules. The spec mentions "configurable per-customer" but
   the config format is TBD.

3. **Persona-spawning UX**: the factory pattern (one-command spawn of
   persona N+1) exists at the script level, but does the customer
   self-serve via Mattermost command, or does the operator do it
   during a managed-support call? Decision: probably the latter for
   v1.0, self-serve for v2.0.
