# Stack Manifest Specification

The YAML contract every stack carries. Makes "what is in this stack" a
machine-readable, comparable, version-controlled declaration instead of
something operators have to infer from the addon list.

A stack manifest is consumed at three different times:

1. **At install time** — `setup-stack.sh` reads it and runs the right
   addons in the right order
2. **At runtime** — workflows declare their dependencies; `setup-n8n.sh`
   validates each workflow's deps against the stack's installed apps
   before importing
3. **At reporting time** — inventory tools, customer-facing dashboards,
   and the sales process can answer "what does this stack include?"
   without anyone reading source code

This spec is a peer to `connector-manifest-spec.md` (which serves the
same role for Sobol Mirror connectors). Both follow the same shape so
operators only have to internalize one pattern.

---

## Where it lives

`<stack-repo>/manifest.yaml` — at the root of the stack repository,
alongside the `automation/` and `addons/` folders.

Stack repos use the `stack-<name>` prefix convention (see
`conventions.md` §3 for the naming rules).

---

## Full schema (with all optional fields)

```yaml
# ===== REQUIRED: identity =====================================================
name: creator-studio                # short, kebab-case, used as the canonical ID
display_name: Creator Studio        # human-facing; what we say in sales calls
version: 1.0.0                      # semver; bump when manifest or addons change
tier: office-in-a-box               # foundation | mirror | office-in-a-box | premium | custom
maintainer: sobol-data              # team responsible for keeping this current
description: |                      # one paragraph — what is this stack FOR?
  A self-hosted creator's office for solo creators and small studios
  (1-10 people). Bundles Ghost (publishing), Plausible (analytics),
  Cal.com (scheduling), and Cloudflared (public access) on top of the
  TD-Proxmox foundation.

# ===== REQUIRED: app inventory ================================================
# Apps the stack installs by default. Listed in install order — the
# setup-stack runner uses this order, so dependencies must come before
# dependents (postgres-shared before ghost; mattermost before n8n).
core_apps:
  - postgres-shared                 # shared DB host (used by ghost, plausible, cal.com)
  - gitea                           # version control + secrets repo
  - mattermost                      # chat + agent surface
  - n8n                             # integration / workflow engine
  - ollama-pi-agent                 # local LLM + persona runtime
  - homepage                        # dashboard
  - ghost                           # vertical: publishing CMS
  - plausible                       # vertical: privacy-first analytics
  - calcom                          # vertical: scheduling
  - cloudflared                     # vertical: secure public access

# Apps the stack CAN install via opt-in flag. Operators can add these post-
# install without rebuilding from scratch. Useful for "I want all of office-
# in-a-box plus the openwebui for ad-hoc LLM chat."
optional_apps:
  - openwebui
  - sandbox

# Apps the stack explicitly excludes (won't install even if the tier
# normally would). Documents intent so future contributors don't
# 'helpfully' add them. e.g. Mirror tier excludes Gitea because the
# wedge is "we don't need to install much."
excludes_apps: []

# ===== REQUIRED: the workflow library =========================================
# Workflows that ship installed (active=false by default — see
# repo/addons/n8n/workflows/README.md). Each name must match a JSON file
# in the n8n workflows directory.
workflows:
  - gitea-events-to-mattermost
  - gitea-daily-digest
  - mm-ollama-chat
  - postmark-events-to-mattermost
  - td-health-to-mattermost
  - comms-agent-digest             # added by Sobol Mirror — TBD if Mirror is bundled

# ===== REQUIRED: the agent layer ==============================================
# Personas available for deployment. These don't auto-deploy — the
# operator picks during install (or later). The list is just the
# universe of supported personas for this stack.
available_personas:
  - ops-engineer
  - digest-comms
  - code-reviewer

# Personas that DO auto-deploy on install. Empty by default — most
# stacks want the operator to choose so they're not surprised by a
# bot speaking in their channel.
default_personas: []

# ===== REQUIRED: stack-level features =========================================
# Things that aren't apps but are stack-level concerns (email relay,
# backup target, watchdog). Each one is either required, optional, or
# omitted. The setup-stack runner provisions required features.
features:
  email_relay: required             # required | optional | omitted
  vzdump_backup: required           # USB backup target via setup-usb-backup.sh
  health_watchdog: required         # td-health-watchdog.timer + workflow
  config_backup: optional           # setup-pve-etc-backup.sh
  smb_share: omitted

# ===== REQUIRED: dependencies =================================================
# Other stacks/frameworks this stack inherits from. Most stacks inherit
# from the Sobol Foundation; some derive from another stack
# (e.g. Sobol Mirror builds on sobol-foundation).
inherits:
  framework: proxmox-stack-foundations
  framework_version: ">=2.0.0"
  base_stack: sobol-foundation     # null if standalone; otherwise the parent stack
  base_stack_version: ">=1.5.0"

# ===== OPTIONAL: capacity planning ============================================
# Hardware requirements documented in the manifest so sales can quote
# the right SKU. ISO builder can also use this to validate target
# hardware before flashing.
capacity:
  ram_min_gb: 16                    # absolute minimum
  ram_recommended_gb: 32            # recommended for comfortable headroom
  disk_min_gb: 200                  # for OS + all CTs + backups
  cpu_min_cores: 4                  # vCPUs across all CTs
  network: "1 gigabit, DHCP — no static IP needed"

# ===== OPTIONAL: observability ================================================
# How an operator (or our managed-support team) knows this stack is healthy.
observability:
  watchdog_required: true
  watchdog_alert_channels:
    - mattermost                    # via td-health-to-mattermost workflow
    - email                         # via setup-pve-email + ADMIN_NOTIFY_EMAIL
  daily_heartbeat: true             # td-health-heartbeat.timer at 09:00 local

# ===== OPTIONAL: commercial metadata ==========================================
# Surfaces this stack carries for customer-facing context. Sales tools
# and the intake-website can read this to render the "what's included"
# bullets.
commercial:
  sku_name: "Creator Studio — Standard"
  base_price_usd: 2500              # BYO hardware
  shipped_price_usd: 3500           # with hardware
  monthly_support_tiers:
    standard: 500
    pro: 1000
    premium: 2000
  vertical_landing_page: https://soboldata.com/creator-studio
```

---

## Minimum viable manifest

```yaml
name: sobol-mirror
display_name: Sobol Mirror
version: 1.0.0
tier: mirror
maintainer: sobol-data
description: Read-only sync from customer SaaS + AI agents — the wedge product.

core_apps:
  - postgres-mirror
  - mattermost
  - n8n
  - ollama-pi-agent
  - homepage

workflows:
  - slack-mirror-sync
  - comms-agent-digest

available_personas:
  - comms-agent

features:
  email_relay: required
  vzdump_backup: required
  health_watchdog: required

inherits:
  framework: proxmox-stack-foundations
```

That's all the spec strictly requires. Everything else is optional refinement.

---

## How the manifest is used

### At install time

```bash
./automation/setup-stack.sh creator-studio
```

The runner:

1. Locates `manifest.yaml` in the named stack repo
2. Validates the manifest against this spec (every required field
   present, app names match `setup-<app>.sh` files, workflow names
   match JSON files in the library)
3. Walks `core_apps` in order, running `./addons/setup-<app>.sh` for each
4. Walks `features` and runs the corresponding setup script for each
   `required` entry (e.g. `email_relay: required` →
   `./addons/setup-pve-email.sh`)
5. Imports each workflow in `workflows[]`
6. Prints a summary banner listing what was installed and what's optional

### At runtime (workflow import)

When `setup-n8n.sh` (or `setup-stack.sh`) imports a workflow, it reads
the workflow's own `meta.stack_dependencies` and compares against the
stack's installed `core_apps`. Workflows whose required deps aren't
installed are skipped with a warning. Workflows whose deps include only
optional apps are imported but flagged as "needs you to also install X
before this works."

### At reporting time

```bash
./automation/manifest-info.sh creator-studio
```

Prints a human-readable summary — perfect for support tickets,
inventory checks, "what version is this customer running" questions.
The intake-website's stack-comparison page reads from manifests
directly to keep marketing claims in sync with what we actually ship.

---

## Versioning + migrations

Stack manifest version follows semver:

- **Patch** (1.0.0 → 1.0.1): Documentation fix, no install changes.
  Customers don't need to do anything.
- **Minor** (1.0.0 → 1.1.0): New app added to `core_apps`, new
  workflow shipped, new optional feature. Customer runs
  `setup-stack.sh creator-studio --upgrade` to pull deltas. Existing
  apps untouched.
- **Major** (1.0.0 → 2.0.0): Breaking change. App removed from
  `core_apps`, schema migration required, vertical app version
  pinned to a new major. Customer runs an explicit migration
  procedure documented in `<stack-repo>/CHANGELOG.md`.

The `inherits.framework_version` and `inherits.base_stack_version`
fields use npm-style semver constraints (`>=2.0.0`, `~1.5.0`,
`^2.1.0`). If a constraint isn't satisfied, the install fails fast
rather than silently producing a broken stack.

---

## What's enforced vs. just documented

**Enforced** (install fails if violated):

- All `core_apps` have a corresponding `setup-<name>.sh` in the addon
  library
- All `workflows[]` entries match a JSON file in
  `repo/addons/n8n/workflows/`
- All `available_personas` match a folder in `pi-personas/`
- All `features` keys are recognized values
- Versions match semver format
- `inherits` constraints satisfiable against currently-installed
  framework/base

**Documented but not enforced** (warnings, not failures):

- `capacity.*` values vs. actual hardware
- `commercial.*` consistency with `OFFERINGS.md`
- `description` length / clarity

---

## What's intentionally NOT in the manifest

To resist sprawl:

- ❌ Tokens / credentials (those live in `<stack>-tokens.txt`, never
  in the manifest)
- ❌ Customer-specific values (those are install-time parameters,
  prompted by `setup-stack.sh` or read from a customer-overlay file)
- ❌ Persona contents / SYSTEM.md (those live in `pi-personas/`)
- ❌ Workflow JSON contents (those live in the workflows library)
- ❌ Addon implementations (those live in `addons/`)
- ❌ Per-customer customizations (those go in a customer overlay
  repo — see `conventions.md` §5)

The manifest is the **what**, not the **how** or the **who**.

---

## Workflow-side declaration

Workflows declare their own dependencies in their JSON's `meta` block,
so the install-time validator can match them up:

```json
{
  "meta": {
    "description": "...",
    "stack_dependencies": {
      "required_apps": ["mattermost", "gitea", "n8n"],
      "optional_apps": ["ollama-pi-agent"],
      "required_features": ["email_relay"]
    },
    "addon_dependencies": [
      "setup-mattermost",
      "setup-gitea-email"
    ]
  }
}
```

Backfilling this on existing workflows is mechanical (a follow-up task,
not blocking this spec). The library README catalog at
`repo/addons/n8n/workflows/README.md` will be updated to render
dependency info from these meta blocks.

---

## Reference implementations

The first concrete manifests to write (in order of priority):

1. `stacks/sobol-foundation/manifest.yaml` — the foundation stack. Lowest
   tier, sets the baseline.
2. `stacks/sobol-mirror/manifest.yaml` — the wedge product. Validates
   the `tier: mirror` baseline differs from office-in-a-box.
3. `stacks/creator-studio/manifest.yaml` — the first commercial stack.
   Should match `OFFERINGS.md` SKU descriptions exactly.
4. `stack-founder-ai-os/manifest.yaml` — the premium tier.

Once these four exist, the spec has been stress-tested against four
different shapes and is ready for new-stack contributors to use as
boilerplate.

---

## Validation tooling

`scripts/lib/stack-manifest.sh` provides shared validation logic
(mirroring `scripts/lib/manifest.sh` for connector manifests):

```bash
validate_stack_manifest /path/to/manifest.yaml
# Exit 0 if valid; 1 with line-by-line errors if invalid.

read_stack_field /path/to/manifest.yaml core_apps
# yq-based read of any JSONpath into the manifest.

list_installed_apps /path/to/manifest.yaml
# Echoes one app per line — used by workflow dep checker.
```

These are TBD as a follow-up; for now, `setup-stack.sh` can hard-parse
with `yq` directly and refactor when we have two stacks sharing parser
logic.

---

## Revision log

| Date | Change |
|---|---|
| 2026-06-29 | Initial draft. Establishes the contract before first formal stack manifest ships. |
