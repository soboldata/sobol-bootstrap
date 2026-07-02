# Changelog

All notable changes to stack-sobol-mirror follow this format.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-06-29

### Added

- Initial manifest.yaml declaring the wedge product
- `tier: mirror` — first stack at this tier
- Inherits from `stack-sobol-foundation >= 1.0.0`
- Core apps: postgres-mirror + connector-slack + (inherited) mattermost,
  n8n, ollama-pi-agent, homepage
- Excludes: gitea, pi-mattermost-bridge, pi-web-uis, filebrowser, sandbox,
  openwebui — keeps the install light, per the wedge thesis
- Workflows shipped: slack-mirror-sync + comms-agent-digest +
  td-health-to-mattermost (inherited)
- Default persona: comms-agent (auto-deployed at install)
- Available persona: ops-engineer (for managed-support customers)
- Required features: email_relay, vzdump_backup, health_watchdog
- Commercial SKU lineup: Trial $49, Solo $99/mo, Team $249/mo, Pro $499/mo

### Implementation notes

The connectors/agents/workflows live in `sobol-foundation/repo/addons/`
(inherited via base_stack). When this stack matures and needs its own
addon namespace, those move to `stack-sobol-mirror/addons/` and the
inheritance becomes pure-manifest.

For tonight (2026-06-29): the implementation pieces are real and tested,
the manifest just makes the contract explicit.
