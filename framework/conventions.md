# Sobol Data — Development Conventions

How we work. Versioning, naming, repo structure, release process, and
the three contracts that hold the framework together.

This document is the "you're new to Sobol Data, read this first" doc.
Most things here are decisions, not preferences — please match the
existing pattern even when an alternative feels reasonable. The
consistency is what makes the framework legible at scale.

The deep technical patterns (Tailscale layer, email layer, CT lifecycle,
addon shape) live in `foundations.md`. The connector manifest format
lives in `connector-manifest-spec.md`. The stack manifest format lives
in `stack-manifest-spec.md`. **This doc** is about how the org operates
between those technical layers.

---

## 1. Three audiences, three layers

| Audience | What they care about | Where it lives |
|---|---|---|
| **Operators / contributors** | How do I build / debug a stack? | `foundations.md`, addon scripts, `TROUBLESHOOTING_LOG.md` |
| **Customers / sales** | What is in the box? What does it do? | Stack manifests, `OFFERINGS.md`, vertical landing pages |
| **Org / future Nathanial** | How do we make decisions? Why is it structured this way? | This file, `STRATEGY.md`, decision log |

Don't mix the audiences. If you find yourself writing customer-facing
copy inside a technical doc, factor it out.

---

## 2. Repo layout (the four buckets)

```
# 1. FRAMEWORK (public, open) — the building blocks
proxmox-stack-foundations         The contracts: foundations.md, manifest specs, conventions
                                    -- foundations.md
                                    -- stack-manifest-spec.md
                                    -- connector-manifest-spec.md
                                    -- conventions.md  (this file)
                                    -- templates/  (example stack scaffolds)

# 2. RUNTIME (the addon library + bootstrap that stacks inherit from)
sobol-foundation                  Active foundation runtime. Private Gitea.
                                  Contains all addon code + bootstrap + automation.
                                  Continuation of TD-Proxmox; new addon work and
                                  bootstrap improvements land here.
                                    -- automation/  (bootstrap-pve.sh, configure-apps.sh)
                                    -- addons/      (setup-<app>.sh + n8n/workflows/)
                                    -- bootstrap-fresh-pve.sh
                                    -- README.md, TROUBLESHOOTING_LOG.md

TD-Proxmox/repo                   Frozen public archive (github.com/artofax/td-proxmox
                                  tag v1.0.0-archive). Trading-group reference build;
                                  does not evolve.

# 3. STACKS (monorepo of all stack declarations)
stacks/                           Monorepo for ALL stack manifests, foundation
                                  + commercial. Each subfolder is one stack —
                                  manifest + README + CHANGELOG, no addon code.
                                  Commercial stacks inherit code from
                                  sobol-foundation via inherits.base_stack.
                                    -- README.md  (catalog of stacks here)
                                    -- sobol-foundation/  (the foundation manifest)
                                    -- sobol-mirror/      (the wedge product)
                                    -- creator-studio/    (publishing office-in-a-box)
                                    -- founder-ai-os/     (premium AI workforce)
                                    -- <future-stacks>/

# 3. BUSINESS (private — Gitea-only)
sobol-business                    Strategy, GTM, runbooks, ISO tooling
intake-website                    Lead capture site + questionnaire
pi-personas                       The persona library (agent layer)

# 4. CUSTOMER (private — one per paying customer)
customer-acme-001                 Per-customer overlay derived from a stack template
customer-zeno-002
```

Every repo's name carries its category via prefix or convention:

- `repo` (TD-Proxmox foundation framework) — the public reference
- `stacks` — monorepo of derived stack manifests (one repo, multiple stacks inside)
- `customer-*` — paying customers (kept entirely separate even from each other)
- `intake-*`, `sobol-*`, `pi-*` — business/operational repos
- `proxmox-stack-foundations` — the framework docs (one repo, no prefix)

**Why `stacks/` is one repo not N:** at our scale (4 stacks, mostly
metadata, single contributor) the multi-repo overhead is real with no
benefit. Cross-stack refactors land atomically; discovery is `ls
stacks/`; one push/pull/branch set instead of N. If a particular stack
ever grows substantial unique code (custom addons, custom automation
beyond what's inheritable from sobol-foundation), it can graduate to its
own repo at that point. Until then, mono wins.

Why this matters: `ls stack-*` answers "what stacks do we have?"
without anyone having to read README files. The same for `ls customer-*`.

### When a repo gets created

1. Pick the right category (framework / stack / business / customer)
2. Apply the prefix convention
3. Add the standard files (see §6 below)
4. Set up the Gitea remote BEFORE doing significant work
5. Push initial commit (so nothing exists only on a laptop)

### 2.1 Modularity — addons vs stack wiring

The single most important layout rule: **addons are a reusable library,
stacks are compositions**. Follow it or the whole framework devolves
into per-stack forks.

**The addon library lives at `sobol-foundation/addons/`.** Every
`setup-<app>.sh` in the ecosystem lives here. Every single-purpose n8n
workflow (webhook → format → post-to-mm) lives at
`sobol-foundation/addons/n8n/workflows/`. These are the building blocks —
self-contained, tokens-file-driven, following the §10 addon shape.

**Stacks (`stacks/<name>/`) are compositions.** They declare which
addons to install (via `manifest.yaml`) and provide only the wiring/
config specific to *this* composition. No addon implementation code
lives here. If it did, another stack couldn't reuse it — and modularity
is the whole point.

What belongs in `stacks/<name>/`:

- `manifest.yaml` — declaration (what apps + workflows + personas)
- `README.md` — what this composition is for, current state
- `CHANGELOG.md` — release log
- `wire.sh` (optional, rare) — post-install glue that only makes sense
  in this composition (e.g. "after Ghost and Plausible are both up,
  inject Plausible's tracking script into Ghost's Code Injection")
- `config/` (optional) — YAML overrides applied to specific addons at
  install time (e.g. custom Homepage tile arrangement)
- `workflows/` (rare) — multi-addon orchestrations that only exist
  because THIS stack composed those particular apps together

What does NOT belong in `stacks/<name>/`:

- Any `setup-<app>.sh` — belongs at `sobol-foundation/addons/`
- Any single-app workflow — belongs at `sobol-foundation/addons/n8n/workflows/`
- Any bootstrap/CT-creation logic — belongs at `sobol-foundation/automation/`

**The rule of thumb** — before adding a file to `stacks/<name>/`, ask:
*"If someone spun up a completely different stack that happened to
include this app, would they want this file too?"*

- Yes → it's a library addon or workflow → `sobol-foundation/addons/`
- No, it only makes sense in *this* combination → stack-specific →
  `stacks/<name>/wire.sh` or `stacks/<name>/config/`

**How `setup-stack.sh` resolves.** The runner reads the manifest,
walks `core_apps[]`, and for each app tries in order:
1. `sobol-foundation/addons/setup-<app>.sh` (the library — normal case)
2. `stacks/<name>/addons/setup-<app>.sh` (stack-specific — edge case)

Same two-layer lookup for workflows. The stack-local fallback exists
only for the rare case where a stack legitimately needs an addon that
would never be reused. If you find yourself hitting the fallback more
than once every few stacks, you're mis-classifying reusable pieces
as stack-specific.

**How the foundation stack differs.** `stacks/sobol-foundation/` is
still a stack manifest like any other; what makes it special is that
its `inherits.base_stack: null` and the runtime code it references
lives right next to it at `sobol-foundation/` (sibling folder). Other
stacks inherit `base_stack: sobol-foundation` and pull the same addon
library through that link.

### 2.2 Additive composition — stacks on existing hosts

The design assumes a host may accumulate stacks over time, not just
receive one at a time. A homelab that runs sobol-foundation for a
year, then adds creator-studio when the customer starts a
publishing business, then adds sobol-mirror for a Slack sync trial,
should install without breakage or resource stomping. Follow these
rules and it does.

**Every addon is idempotent.** This is already required by the §10
addon shape in `foundations.md` (`set -Eeuo pipefail`, `--dry-run`,
`--uninstall`, markered config blocks) — but call it out again here
because additive composition depends on it entirely. Re-running
`setup-mattermost.sh` on a host that already has a Mattermost CT must
detect that state, skip CT creation, and idempotently re-apply the
configure step. Same for every other addon in the library.

**The manifest declares the full required set, not the delta.** A
creator-studio manifest lists mattermost + n8n + ollama-pi-agent
(inherited from sobol-foundation) AND ghost + plausible + calcom
(its verticals). It does NOT try to be clever about "assume these
are already there." The manifest is a description of the composed
state; the runner is responsible for deciding what needs to change.

**The runner walks the inheritance chain, deduplicates, and skips
what's already there.** `setup-stack.sh <name>` resolves
`inherits.base_stack` transitively (creator-studio →
sobol-foundation), unions the `core_apps[]` in install order, then
walks the union. For each app:

- If the CT already exists with the expected hostname → run only the
  addon's configure/reconfigure path (idempotent), skip CT creation
- If the CT is missing → run the full addon (create + configure)
- Either way, log clearly whether this was `INSTALL`, `RECONFIGURE`,
  or `SKIP: already at expected state`

`--dry-run` MUST print this three-way classification for every app in
the union so the operator sees exactly what will change before it
does.

**Features are host-level and satisfied-once.** `email_relay`,
`vzdump_backup`, `health_watchdog` — these are per-host concerns.
Once installed, a second stack declaring them as `required` finds
them already satisfied and moves on. The runner does not re-run them
just because a new manifest happens to declare them. If a stack
needs a NEWER version of a feature (rare), that's expressed by
bumping `inherits.framework_version` and letting the framework layer
handle the upgrade, not by having the addon re-run.

**Wiring (`wire.sh`) is stack-specific and always runs.** When
creator-studio is added to a host with an existing sobol-foundation,
its `wire.sh` still runs — the wiring is what makes THIS stack THIS
stack (the Plausible-tracking-into-Ghost inject, the
Cloudflared-route-per-app fan-out, etc.). Wiring is where "add this
stack to that host" actually happens. Wiring scripts must also be
idempotent — reruns are common as stacks are updated.

**Tokens files coexist by stack.** A host that has both
sobol-foundation and creator-studio will have both
`/root/td-tokens.txt` (foundation-scoped) and
`/root/studio-tokens.txt` (creator-studio-scoped). Addons read from
their canonical file; nothing overwrites across stacks. The
`--tokens-file <path>` flag on every addon exists exactly for this
case (the runner may pass the right file per addon).

**Capacity check considers the TOTAL, not the delta.** When
installing creator-studio on top of sobol-foundation, the capacity
check is: does the host have RAM + disk + CPU for BOTH stacks
running together, using the recommended figures from each manifest's
`capacity:` block? If not, refuse the install with a clear message
rather than half-install.

**Refusing to install on version conflict is better than fudging.**
If creator-studio requires `inherits.base_stack_version: ">=1.0.0"`
and the host has sobol-foundation v0.9.0 installed, the runner
should refuse (with a message pointing at the upgrade path), not
attempt to install on an incompatible base.

**Uninstall reverses the last install.** Removing a stack removes
its unique CTs and its stack-specific wiring, but leaves shared
addons (mattermost, etc.) if another stack still uses them. This is
tracked by a simple `/root/installed-stacks.json` state file that
the runner maintains: which stacks are installed, what versions,
which shared addons each depends on. Deletion of the last dependent
lets the runner offer to remove shared addons too.

**Uninstall priority order (planned): manual first, then runner-managed.**
For MVP, uninstalls are operator-driven per-addon (`setup-<name>.sh
--uninstall`); the runner-managed shared-dependency tracker is a
future setup-stack.sh feature.

---

## 3. Stack naming

Stack names are **kebab-case nouns** that describe the vertical/use case:

- ✅ `sobol-foundation`, `sobol-mirror`, `creator-studio`, `small-law`, `small-medical`
- ❌ `tdProxmox`, `td_proxmox`, `td-g-oa-ow-h-n`, `stack42`

The app set goes in the manifest's `core_apps` field, NOT in the name.
Names are for humans; the manifest is for machines. Encoding the app
set into the name is a tax for every future contributor (see
`stack-manifest-spec.md` for the rationale).

Display names (used in sales / marketing) are Title Case with optional
qualifier:

- "Creator Studio — Standard"
- "Sobol Mirror — Solo"
- "Small Law Practice — Compliance Edition"

The display name lives in `manifest.yaml`'s `display_name` field. The
canonical kebab-case `name` is what file systems, URLs, and tooling use.

---

## 4. Versioning — semver, everywhere

Every artifact gets a version. Specifically:

- **Framework** (`proxmox-stack-foundations`) — semver, tagged in git
- **Each stack repo** — semver, tagged in git, declared in `manifest.yaml`
- **Each connector** (Sobol Mirror) — semver, declared in its
  `manifest.yaml`
- **Each workflow** — implicit semver via the parent stack's version
- **Each persona** — semver, declared in the persona's README

Semver rules across all artifacts:

- **Patch** — bug fix, doc fix, no behavior change. Customers don't act.
- **Minor** — additive: new feature, new optional app, new workflow.
  Customer runs `--upgrade` to pull in.
- **Major** — breaking: schema change, removed app, changed default
  behavior. Customer follows a documented migration in CHANGELOG.

Version mismatches between framework / stack / customer overlay are
caught at install time, not at runtime. If the framework version
requirement isn't met, the install fails fast with a clear message.

---

## 5. Customer-specific work

When a customer pays for a stack, their install becomes a new repo
under `customer-<id>`. It's not a fork of the stack repo — it's an
**overlay** that references the stack repo as a dependency.

```
customer-acme-001/
├── README.md              Customer-specific notes (private)
├── overlay.yaml           Differences from the base stack manifest
├── customizations/        Per-customer addon scripts (if any)
├── personas/              Customer's deployed personas (copy from pi-personas)
└── runbooks/              Customer-specific operational notes
```

At install time, the operator runs:

```bash
./setup-stack.sh creator-studio --customer acme-001
```

Which:

1. Clones `stack-creator-studio` at the version pinned in `overlay.yaml`
2. Applies `customer-acme-001/customizations/` on top
3. Deploys the customer's chosen personas

The benefit: every customer's stack remains **debuggable from a clean
slate** — we always know what's stock and what's their customization.
No customer becomes a snowflake we can't rebuild.

When a stack's framework version bumps, customers don't auto-upgrade —
each customer is a deliberate decision based on their support tier and
their tolerance for risk.

---

## 6. Required files in every repo

Every repo has these at the root (no exceptions, no excuses):

```
README.md           First doc anyone reads. What is this, who is it for, how do I run it.
CHANGELOG.md        Reverse-chronological list of versioned releases. Required even for v0.1.0.
LICENSE             Open repos: MIT or similar. Private repos: "All rights reserved, internal use only."
.gitignore          Standard for the language(s) used. No exceptions for "I'll add this later."
```

Stacks additionally have:

```
manifest.yaml       The stack manifest (see stack-manifest-spec.md)
automation/         Bootstrap + configure scripts
addons/             Setup scripts (setup-<app>.sh) + n8n/workflows/
```

Business repos additionally have what's specific (`STRATEGY.md`,
`OFFERINGS.md`, etc.).

---

## 7. The three contracts

Three contracts hold the framework together. Each is enforced at
install time and reviewed before any addon ships.

### 7.1 The workflow contract (`foundations.md` §10.1)

**Every addon ships with at least one n8n workflow that uses the
addon together with ≥1 other app in the stack.**

The workflow doubles as the smoke test. If you can't write a workflow
that uses the new app together with another app, the addon probably
isn't well-integrated yet. Building the workflow surfaces the gaps.

### 7.2 The agent layer contract (`foundations.md` §11.1)

**Every stack has three layers — infrastructure, integration,
orchestration — and they're explicit, not implied.**

Infrastructure: addons. Integration: workflows. Orchestration: agents
with `AGENT.md` (operational, shareable) + `SYSTEM.md` (persona,
private). When a new addon lands, the design question expands from
"what workflow does this enable?" to "what agent role does this make
possible?"

### 7.3 The stack manifest contract (`stack-manifest-spec.md`)

**Every stack has a `manifest.yaml` at the root that declares its
identity, apps, workflows, personas, features, and dependencies.**

The manifest is what makes stacks comparable, what makes workflows
dependency-aware, and what makes "what's in this customer's stack?"
answerable without reading source code.

Together: every addon → workflow → role. Every stack → manifest →
explicit identity. Every customer → overlay → debuggable from clean.

---

## 8. Release process

A "release" is a tagged commit. Releases follow this pattern, regardless
of which repo:

1. **Land all PRs intended for the release** on `main`
2. **Update `CHANGELOG.md`** at the top with a new version section:

   ```markdown
   ## [1.4.0] - 2026-07-15

   ### Added
   - Postgres-mirror connector for Slack

   ### Changed
   - Watchdog now also posts to Mattermost via n8n webhook

   ### Fixed
   - Email relay no longer leaks SMTP_USERNAME in logs
   ```

3. **Bump `version` in `manifest.yaml`** (for stacks) or relevant
   source file
4. **Tag the commit**: `git tag -a v1.4.0 -m "Release v1.4.0"`
5. **Push tags**: `git push --tags`
6. **Bump dependent repos** if this is a framework or base-stack
   release that downstream stacks depend on

The TROUBLESHOOTING_LOG entries that landed during the release cycle
should be referenced in the changelog where they map to a "Fixed"
entry.

---

## 9. Code review

Until we have more than one contributor, code review is informal —
but we follow the practice of letting the **code-reviewer persona**
(see `pi-personas/code-reviewer/`) take a first pass on every PR.
That trains the persona on our standards, AND surfaces issues a
human reviewer might miss.

Standards the code-reviewer enforces (and human reviewers should too):

- All shell scripts `set -Eeuo pipefail`
- All shell scripts support `--dry-run` and `--uninstall`
- All config-file edits use markered blocks (see `foundations.md` §10)
- All credentials come from `<stack>-tokens.txt`, never hardcoded
- All workflows ship inactive (`active: false` in JSON)
- All workflows have `respondToWebhook` on every branch
- All manifest fields validate against the relevant spec

Once we have 2+ contributors, formalize via Gitea PR review settings
(require N approvals, code-reviewer required).

---

## 10. The decision log

When we make a non-obvious architectural decision, write it down. A
short markdown file in `<repo>/decisions/<NNNN>-<title>.md` with:

```markdown
# 0042. Stack manifest is YAML, not JSON

**Status:** Accepted
**Date:** 2026-06-29

## Context
We need a machine-readable declaration of what's in each stack...

## Decision
Stack manifests are YAML files at the repo root...

## Consequences
- Operators can read manifests at a glance (comments, multi-line strings)
- Tooling needs `yq` (already a dependency)
- ...

## Alternatives considered
- JSON: machine-readable but harder to write by hand
- TOML: nicer for nested keys but less common in the ecosystem
- ...
```

Decision logs answer "why did we do it that way?" months later when
context has rotted.

---

## 11. Anti-patterns to call out

These look reasonable but compound badly:

| Pattern | Why it bites |
|---|---|
| Letting a customer's stack drift from the manifest | Customers become un-debuggable snowflakes |
| Adding to the framework without bumping its version | Downstream stacks can't pin to a known-good version |
| Renaming an app halfway through a release cycle | Workflows + manifests + personas all need cross-repo coordination |
| Letting tokens / secrets leak into the manifest | The manifest is meant to be reviewable; secrets aren't |
| Letting personas without an `AGENT.md` slip into deploys | The agent layer contract requires the public op-context file |
| Skipping the CHANGELOG entry "this is just a small fix" | Compound interest of skipped entries = unknowable history |

---

## 12. When in doubt

Match the existing pattern. The framework's strength is in its
consistency — adding a new variation costs more than picking
"slightly suboptimal but matches what's already there."

If you genuinely think a deviation is warranted, write a decision log
entry (§10) BEFORE making the change. The act of writing the decision
often reveals whether the deviation is worth it.

---

## Revision log

| Date | Change |
|---|---|
| 2026-06-29 | Initial draft. Codifies repo layout, naming, the three contracts, release process, and decision-log conventions. |
