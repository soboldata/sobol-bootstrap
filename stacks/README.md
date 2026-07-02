# stacks — Sobol Data derived stack manifests

Monorepo for Sobol Data's commercial stack definitions. Each subfolder
is one stack with its `manifest.yaml` + README + CHANGELOG.

## Why one repo instead of N

For our scale (4 stacks, mostly metadata, single contributor) one repo
wins on:

- One push / one pull / one set of branches
- Cross-stack refactors land atomically
- Easier discoverability (`ls stacks/` = "what stacks exist")
- Less Gitea overhead
- Consistent CI / validation runs across all stacks at once

If a particular stack ever grows substantial unique code (custom
addons, custom automation), it can graduate to its own repo at that
point — but until then, mono.

## What's here

| Folder | Tier | Status |
|---|---|---|
| [sobol-foundation](sobol-foundation/) | foundation | v1.0.0 — most-tested build; all others inherit from this |
| [sobol-mirror](sobol-mirror/) | mirror | v1.0.0 — wedge product, ready |
| [creator-studio](creator-studio/) | office-in-a-box | v0.9.0 beta — full install path documented; needs first customer install |
| [founder-ai-os](founder-ai-os/) | premium | v0.7.0 beta — needs first customer to validate |

`sobol-foundation` is the foundation tier — the runtime code (addons,
bootstrap, automation) lives in the sibling `../sobol-foundation/`
repo. All three commercial stacks above declare
`inherits.base_stack: sobol-foundation` to pull in that addon library.

The original `td-proxmox` lives at `../repo/` as a frozen public
archive on GitHub (`github.com/artofax/td-proxmox` tag
`v1.0.0-archive`). It does not evolve. `sobol-foundation` is the
private active-development continuation of that codebase.

## Conventions

Each stack folder follows
[`proxmox-stack-foundations/conventions.md`](../proxmox-stack-foundations/conventions.md)
§6 — required files at the root:

```
<stack-name>/
├── manifest.yaml      The contract (see ../proxmox-stack-foundations/stack-manifest-spec.md)
├── README.md          What is this, who is it for
└── CHANGELOG.md       Versioned release log
```

The folder name = `manifest.name` exactly. Kebab-case nouns.

## Adding a new stack

1. `mkdir <stack-name>/` in this repo
2. Write `<stack-name>/manifest.yaml` per the spec
3. Write `<stack-name>/README.md` + `<stack-name>/CHANGELOG.md`
4. Add a row to the table above
5. Commit + push

That's it. No new Gitea repo needed.

## How stacks get installed

Operators run the framework runner against any stack folder:

```bash
# From a PVE host with the framework cloned
../proxmox-stack-foundations/setup-stack.sh sobol-mirror \
    --stack-path .../stacks/sobol-mirror
```

The runner reads `manifest.yaml`, validates against the spec, walks
core_apps + workflows + personas in order.

## Related repos

- `../sobol-foundation/` — actively-developed foundation runtime (addons, bootstrap, automation)
- `../repo/` — TD-Proxmox public archive (frozen at v1.0.0-archive)
- `../proxmox-stack-foundations/` — framework docs (manifest specs, conventions)
- `../pi-personas/` — persona library
- `../sobol-business/` — GTM, OFFERINGS, runbooks
- `../intake-website/` — customer-facing intake

## License

All rights reserved. Internal/customer use only.

## Maintainer

Sobol Data.
