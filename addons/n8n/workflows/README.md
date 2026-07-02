# n8n Workflow Library

This folder is the canonical workflow library for the TD-Proxmox stack. Every JSON
file in this folder is auto-imported when `setup-n8n.sh` runs against a fresh n8n
CT. As the stack grows, this library grows — and each workflow doubles as both a
smoke test (it proves the addon it depends on is integrated correctly) and as a
fork-able reference pattern for users to build their own automation on top of.

This file is the catalog: what each workflow does, what triggers it, what apps it
touches, and how to use it as a starting point for your own.

---

## Why these workflows exist

A standalone Mattermost CT is a chat app. A standalone n8n CT is a workflow engine.
A standalone Gitea CT is a git host. The value of a stack is in the wiring between
them, and **n8n workflows are the executable, observable, demonstration of that
wiring**. They prove that:

1. Each app's credentials are correct and usable
2. The apps can actually talk to each other on the tailnet
3. The integration patterns we describe in `proxmox-stack-foundations` actually run

If you build a new addon (a Ghost CT, a Plausible CT, a Cal.com CT) and can't
write a workflow that uses it together with another app in the stack, the addon
probably isn't well-integrated yet. Building the workflow surfaces the gaps.

---

## Current library

### Notifications (something happened → tell me in Mattermost)

| File | Trigger | Touches | What it does |
|---|---|---|---|
| `hello-mattermost.json` | Webhook `/hello` | Mattermost | Smoke test — POST to the webhook, message appears in `town-square`. Use as a starter pattern for any webhook→MM flow. |
| `gitea-events-to-mattermost.json` | Gitea system webhook | Gitea → MM | Every push, PR, issue, release, etc. on any Gitea repo posts a formatted message in `#bot`. Per-event-type formatting; high-frequency events (e.g. push of small commits) are condensed. |
| `postmark-events-to-mattermost.json` | Postmark webhook `/postmark-events` | Postmark → MM | Bounces, spam complaints, and subscription changes from Postmark land in `#bot`. Delivery/open/click events are silently dropped to avoid channel spam. |
| `td-health-to-mattermost.json` | Watchdog webhook `/td-health` | PVE host watchdog → MM | The hourly `td-health-check` POSTs its full state to this webhook. The workflow classifies (new alert / cleared / heartbeat / silent) and only posts when there's something to say. Daily 09:00 heartbeat confirms the watchdog is alive — silence becomes a signal. |
| `ghost-publish-to-mattermost.json` | Ghost admin webhook `/ghost-publish` | Ghost → MM | Every `post.published` event from Ghost is formatted (title, author, excerpt, URL) and posted to `#bot`. Wire Ghost's admin webhook to `POST /webhook/ghost-publish`. `setup-ghost.sh --wire-webhook` does this after `GHOST_ADMIN_API_KEY` is minted. Applicable to any stack that composes `ghost` — currently exercised by creator-studio. |
| `calcom-booking-to-mattermost.json` | Cal.com booking webhook `/calcom-booking` | Cal.com → MM | Booking events (`BOOKING_CREATED` / `RESCHEDULED` / `CANCELLED` / `MEETING_ENDED`) → formatted per-event emoji + verb → posted to `#bot`. Register the webhook inside Cal.com: Settings → Developer → Webhooks → New; URL = `http://<n8n-ip>:5678/webhook/calcom-booking`. Applicable to any stack that composes `calcom` — currently exercised by creator-studio. |
| `cloudflared-tunnel-health-to-mattermost.json` | Cron hourly + Manual webhook `/cloudflared-status` | Cloudflared metrics → MM | Polls cloudflared's `:2000/metrics` endpoint, parses `cloudflared_tunnel_ha_connections`. Cron is silent when healthy — only posts on DOWN state. Webhook `/cloudflared-status` forces a post regardless (on-demand health check). Needs `CLOUDFLARED_HOST` env var on n8n CT (defaults to `cloudflared` MagicDNS). Applicable to any stack composing `cloudflared`. |

### Digests (cron → summarize → send)

| File | Trigger | Touches | What it does |
|---|---|---|---|
| `gitea-daily-digest.json` | Cron `0 9 * * *` | Gitea API → MM | Daily 9am summary of yesterday's activity across all Gitea repos (commits, opened/closed issues, opened/closed PRs). Posts to `town-square`. |
| `comms-agent-digest.json` | Cron `0 9 * * *` + Manual webhook | Postgres mirror → Ollama → MM | Daily 9am digest from the comms-agent persona. Reads `agent_view.slack_*` views, passes aggregated JSON to Ollama (default `qwen2.5:14b`), posts to MM (default `#bot`, configurable). Skips with explanatory message when sync is stale or zero messages. Logs every run to `_meta.agent_actions`. |
| `plausible-weekly-digest-to-mattermost.json` | Cron `0 9 * * 1` + Manual webhook `/plausible-weekly-digest` | Plausible API → MM | Every Monday 9am, pulls last week's Plausible stats (visitors, pageviews, visits, bounce rate, avg duration + top 5 pages) via the Plausible v2 query API and posts a formatted digest to `#bot`. Requires `PLAUSIBLE_API_KEY` (minted post-signup) as httpHeaderAuth credential and `PLAUSIBLE_SITE_ID` env var. Currently exercised by creator-studio; any stack composing `plausible` can enable. |

### Mirror sync (Sobol Mirror — read SaaS → land in Postgres)

| File | Trigger | Touches | What it does |
|---|---|---|---|
| `slack-mirror-sync.json` | Hourly cron `0 * * * *` | Slack API → Postgres mirror | First Sobol Mirror connector. Pulls conversations.list + users.list + conversations.history for every non-archived channel; upserts to `slack.*` tables in the `sobol_mirror` DB. Updates `_meta.sync_state` cursor. Consumed by `comms-agent` persona via `agent_view.slack_*` views. Requires `setup-postgres-mirror.sh` + `setup-connector-slack.sh` to be installed first. |

### Chat actions (MM command → action elsewhere → reply)

| File | Trigger | Touches | What it does |
|---|---|---|---|
| `mm-ollama-chat.json` | Mattermost outgoing webhook | MM → Ollama → MM | When a user posts in any watched channel, the message routes to Ollama, gets a response, and the response posts back to the same channel as a reply. |

---

## Workflow design patterns we keep reusing

These four patterns cover ~all workflow shapes you'll need. Each existing workflow
above is an instance of one of them.

### Pattern A: Webhook → Format → Filter → Post

```
[Webhook]  →  [Code: Format payload]  →  [IF: should post?]  →  [Mattermost: post]
                                                            └→  [Respond: skipped]
```

Used by `gitea-events-to-mattermost`, `postmark-events-to-mattermost`,
`hello-mattermost`. Best for "X happened, sometimes I want to know about it."

The Code node decides format AND whether to skip (for low-value events). The IF
node gates the post. Always include a `respondToWebhook` node on both branches
so the source service gets a 200 even when we skip — Postmark, Gitea, etc. retry
on non-200 responses.

### Pattern B: Cron → Pull → Format → Post

```
[Cron]  →  [HTTP: pull from API]  →  [Code: format digest]  →  [Mattermost: post]
```

Used by `gitea-daily-digest`. Best for "show me yesterday's activity / this
week's metrics / last hour's logs."

The Code node gets the entire API response array AT ONCE (via `$input.all()`),
not item-by-item. n8n's default behavior splits arrays into separate executions,
which breaks digest summarization. The "auto-array-split surprise" is one of
the entries in `TROUBLESHOOTING_LOG.md`.

### Pattern C: Chat command → Service → Reply

```
[Outgoing webhook]  →  [IF: matches command]  →  [HTTP: call service]  →  [Reply]
                                              └→  [Respond: no match]
```

Used by `mm-ollama-chat`. Best for "user types a slash command in MM, get a
result back."

Mattermost outgoing webhooks include the channel ID and user token in the body.
The Reply node can use either Mattermost's bot API or just return JSON for the
outgoing webhook's auto-reply.

### Pattern D: Multi-source aggregation → Decision → Action

```
[Trigger 1]  ┐
[Trigger 2]  ├→  [Merge]  →  [Code: decide]  →  [Action]
[Trigger 3]  ┘
```

We don't have an example yet but this is where the library grows next. Examples
that fit: "watchdog alert on disk full → cron also-runs-cleanup → Mattermost
gets the summary," or "Gitea push to main + CI passed + tests green → deploy
to staging."

---

## How to add a new workflow

When you build a new addon (e.g. `setup-ghost.sh`), part of the deliverable is
**at least one workflow that uses Ghost together with ≥1 other app in the
stack**. This is non-negotiable — it's the smoke test.

1. **Pick a pattern** (A/B/C/D above) and a use case. Examples for a Ghost addon:
   - Pattern A: Ghost webhook on publish → format → post to MM `#new-posts`
   - Pattern B: Cron daily → Ghost API → summarize this week's drafts → MM
   - Pattern C: MM command `/draft <title>` → create a Ghost draft → reply with URL

2. **Build it in the n8n UI first.** Don't write the JSON by hand. Use the n8n
   editor on the CT, get the workflow working end-to-end, then export it.

3. **Export → save to this folder as `<source>-<verb>-<target>.json`.** Examples:
   - `ghost-publish-to-mattermost.json`
   - `mm-draft-to-ghost.json`
   - `ghost-weekly-drafts-digest.json`

4. **Edit the JSON** to:
   - Replace concrete IDs with placeholder strings that `setup-n8n.sh` can patch
     at import time (e.g. channel UUIDs are resolved from Mattermost at runtime,
     not baked in).
   - Set `"active": false` so the import doesn't activate it on every fresh
     install. The user toggles it on after they've verified credentials.
   - Add a `meta.description` field at the bottom of the JSON describing what
     it does, what services it depends on, and how to wire up the trigger (e.g.
     "Configure Ghost → Settings → Integrations → Custom Integration → add this
     URL as a webhook").
   - Add `"tags": ["td-proxmox", "ghost", "mattermost"]` so workflows can be
     filtered/grouped in the n8n UI.

5. **Add a row to the table above** in the appropriate category.

6. **Reference it from the addon README.** In `setup-ghost.sh`'s end-of-run
   banner, mention "this addon enables `ghost-publish-to-mattermost.json` —
   activate it in n8n once Ghost is publishing."

---

## Where each workflow's dependencies live

If you fork this library into a different stack, here's what you need to swap:

| Workflow | Hard dependencies | Soft dependencies |
|---|---|---|
| `hello-mattermost` | Mattermost CT with `bot` credentials | none |
| `gitea-daily-digest` | Gitea CT + token, Mattermost CT | Repos to digest must exist |
| `gitea-events-to-mattermost` | Gitea CT + system webhook configured, Mattermost CT | `allowed_host_list` in Gitea's `webhook.*` config must include n8n's hostname |
| `mm-ollama-chat` | Mattermost CT + outgoing webhook, Ollama CT (or pi-agent CT) | Channel ID hardcoded — patch via `setup-n8n.sh` channel resolver |
| `postmark-events-to-mattermost` | n8n CT reachable from public internet (Cloudflare tunnel), Mattermost CT | Postmark account with webhook configured at your public URL |
| `td-health-to-mattermost` | `setup-health-watchdog.sh` installed, Mattermost CT | `MATTERMOST_WEBHOOK_URL` in `/root/td-tokens.txt` — copy from this workflow's webhook node after activating |

---

## Auto-import behavior

`setup-n8n.sh` imports every `.json` file in this folder during install. It also:

1. **Resolves channel UUIDs from Mattermost at import time** — workflow JSONs
   use channel slugs like `"channelId":"=bot"` and the script substitutes the
   actual UUID before importing. This avoids hard-coding UUIDs that differ per
   install.
2. **Patches credential references** to point at the credentials it just created
   (Mattermost API, Gitea API, Ollama HTTP, OpenWebUI HTTP).
3. **Imports inactive** so workflows don't fire on credentials that haven't
   been smoke-tested yet. The operator activates each one manually after
   verifying it works in the n8n UI.

If you want a workflow to NOT be imported (e.g. it's WIP and broken), prefix
the filename with `_` — `setup-n8n.sh` skips those.

---

## Anti-patterns to avoid

| Anti-pattern | Why it bites |
|---|---|
| Hardcoding channel UUIDs in the JSON | UUIDs differ per install; workflow fails immediately |
| Using `n8n-nodes-base.<service>` for services that don't have a real node | We hit this with `n8n-nodes-base.ollama` (fake). HTTP Request to `/api/chat` works. |
| Importing as `"active": true` | Fires on placeholder/broken credentials, floods MM with errors |
| Skipping `respondToWebhook` | Webhook source retries forever, fills logs |
| Code node assuming single-item input | n8n auto-splits arrays — use `$input.all()` for aggregations |
| Bare `console.log` in Code nodes | n8n's execution log eats them — use `return [{ json: { debug: ... } }]` instead |

---

## Future workflows on the radar

These don't exist yet but should as we land more integration:

- **`vzdump-completed-to-mattermost.json`** — PVE vzdump completion event →
  format → MM `#ops`. Pairs with `setup-vzdump-schedule`. The PVE
  `notification-mode` setting can be wired to a webhook target instead of email.
- **`mm-chat-to-summary-to-gitea.json`** — daily MM channel transcript →
  Ollama summarize → commit to a Gitea wiki page. Pairs with `setup-mattermost`.
- **`filebrowser-upload-to-mattermost.json`** — file dropped in shared folder →
  notification with link in `#bot`. Pairs with `setup-filebrowser`.
- **`homepage-service-down-to-mattermost.json`** — Homepage status check fails
  → MM alert. Pairs with `setup-port80-redirect`.
- **`gitea-pr-to-ollama-review.json`** — PR opened → fetch diff → Ollama
  reviews → comments on PR with summary. Pairs with `setup-gitea-email`.

Each one expands what the stack proves it can do without the operator writing
any code.
