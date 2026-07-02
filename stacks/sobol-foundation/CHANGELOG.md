# Changelog — stack-sobol-foundation

Following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-06-30

### Changed

- **Split from `td-proxmox` public archive.** The original TD-Proxmox
  build was shared publicly with the author's trading group and is now
  frozen at `github.com/artofax/td-proxmox` tag `v1.0.0-archive`. All
  active foundation development moves to this stack
  (`sobol-foundation`) on the private Gitea instance going forward.
- Stack identity renamed `td-proxmox` → `sobol-foundation` to signal
  the active-development branch and align with the rest of the Sobol
  Data brand (`sobol-business`, `sobol-mirror`).
- Manifest moved from `repo/manifest.yaml` (the old code home) into
  `stacks/sobol-foundation/manifest.yaml` (the canonical home for
  stack declarations) so all four Sobol stacks are discoverable from
  one location.

### Inherited at split

Functionally identical to TD-Proxmox v1.0.0 at the moment of split:

- 5 core CTs (gitea, mattermost, n8n, ollama-pi-agent, homepage) +
  2 optional (sandbox, openwebui)
- Email layer (Postmark relay + Gitea + watchdog mail)
- Backup layer (vzdump nightly + USB target + path discovery)
- Hourly health watchdog → Mattermost + email + daily heartbeat
- 8 reference n8n workflows shipped (active=false on import)
- 4 personas drafted (trading-assistant, ops-engineer, code-reviewer,
  digest-comms) — available, none default-deployed
- Custom-ISO toolchain validated through 3 real-hardware iterations
- Three-contract framework: workflow per addon, manifest per stack,
  AGENT.md + SYSTEM.md per persona

### Migration notes

Downstream stacks that previously declared
`inherits.base_stack: td-proxmox` should switch to
`inherits.base_stack: sobol-foundation` at their next minor bump.
Both names refer to the same baseline for v1.0.0; `td-proxmox` will
not receive further updates beyond the v1.0.0-archive tag, so the
rename should be treated as forward-only.

### Path forward

This stack continues the TD-Proxmox roadmap:

- `setup-stack.sh` install dispatch implementation (skeleton today)
- Customer overlay pattern exercised end-to-end
- Postmark DKIM/Return-Path finalized for soboldata.com
- Two queued Gitea patches (must_change_password trap,
  setup-gitea-email cleanup)
