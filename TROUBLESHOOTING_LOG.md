# Troubleshooting Log

Running log of issues encountered building / running the TD-Proxmox stack and
the solutions that fixed them. **Reverse chronological** — newest entries at
the top. Each entry is self-contained so you can copy/paste it into a customer
SOW, a Slack channel, or an MR description without context.

## How to add an entry

Use this skeleton. Stamp with `YYYY-MM-DD HH:MM CT` (the local timezone matters
— overnight failures look different from mid-debug ones).

```markdown
## YYYY-MM-DD HH:MM CT — Short title

**Symptom:** what the user saw  
**Root cause:** technical explanation  
**Fix:** what we changed  
**Files / Commit:** where the fix lives in this repo  
**Related:** other entries this pattern matches (optional)
```

If multiple entries share an architectural pattern (e.g., "SSRF gate") cross-link
them via `**Related:**` so a reader skimming for one issue stumbles into the
sibling issues.

---

## Architectural patterns to recognize fast

These show up repeatedly across services. When debugging anything new, check
these first:

### SSRF / outgoing-webhook gates
Many self-hosted services ship anti-SSRF protection that blocks outgoing
connections to RFC1918 / private addresses by default. Symptom: webhook
configured in the UI, delivery log shows success or a benign error, but the
target service never receives the call. Known instances:

- **Mattermost** — `ServiceSettings.AllowedUntrustedInternalConnections`
- **Gitea** — `[webhook] ALLOWED_HOST_LIST` in `app.ini`
- (Likely others — watch for it on any new service.)

Fix pattern: open the allowlist to cover `private,loopback,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10` (named groups + explicit CIDRs + Tailscale CGNAT).

### Channel UUIDs vs slugs
Mattermost's REST API expects 26-char channel IDs, not slugs like `town-square`.
n8n's Mattermost node won't auto-resolve slugs; pasting the UUID directly works
only in **Expression mode** (`={{...}}`) — Fixed mode validation rejects
26-char strings as malformed. Live town-square UUID for THIS install:
`te9ckat1p3b3ukshup6z5jaesr`.

### Shell quoting through `pct exec`
`pct exec <CTID> -- bash -lc "..."` with double-quoted heredoc and embedded
`curl -d '...'` containing JSON `"` characters is a quoting trap. Three rules:
1. Write JSON payloads to a file inside the CT and `curl -d @file`.
2. Pass values via env vars **prefixed** before `python3 -c` (not appended).
3. For nested Python `"..."` inside single-quoted bash, single-quote the dict
   keys: `r['name']` not `r[\"name\"]`.

### Two-PVE / two-CT name collisions
When you have parallel installs on multiple PVE hosts, Tailscale MagicDNS
arbitrates which `n8n` / `gitea` / etc. wins. The "wrong" one being served can
look like every other category of bug. Always verify: `nslookup n8n` from the
client, `getent hosts n8n` from inside relevant CTs.

### Test URL vs Production URL (n8n webhooks)
n8n's Webhook node exposes both:
- `/webhook-test/<path>` — registered only after clicking "Execute workflow",
  unregisters after one event
- `/webhook/<path>` — registered when the workflow is **Active**

Easy to copy the wrong one from the UI. Symptom: external system reports
"delivered" but no n8n execution exists.

### SMTP / postfix relay
Most "email not arriving" issues fall into one of four patterns:

1. **Sender not verified at the provider.** Postmark / Mailgun / SES all
   require the `From:` address (or its domain) to be pre-verified before
   accepting outbound mail. Symptom: `mailq` shows the message stuck
   with `Sender address rejected` / `SenderSignatureNotConfirmed`.
2. **Wrong port × wrong TLS mode.** 587 = STARTTLS, 465 = TLS, 25 = none.
   Mismatched values usually surface as a TLS handshake timeout.
3. **Generic map missing.** Without `/etc/postfix/generic`, `From:`
   header stays as `root@<hostname>.localdomain`, which fails SPF/DKIM
   and gets silently dropped.
4. **PVE `mail-from` empty.** PVE alerts use `/etc/pve/datacenter.cfg`'s
   `mail-from` for the alert sender. If empty, alerts fall back to the
   local user's address, which usually isn't verified at the provider.

`setup-pve-email.sh` handles all four if the tokens file has SMTP_* +
ADMIN_NOTIFY_EMAIL set. `--test-only` lets you verify without re-config.

---

## Entries

## 2026-07-02 xx:xx CT — CT can't resolve DNS because its resolv.conf points at Tailscale MagicDNS from an unjoined CT

**Symptom:** Real-hardware install of `setup-mattermost.sh` on `creator`
PVE host stalled ~5 min after "Waiting for CT to come back after
reboot...", then produced:

```
W: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/noble/InRelease
   Temporary failure resolving 'archive.ubuntu.com'
[repeated for postgresql apt repo, mattermost apt repo]
curl: (6) Could not resolve host: tailscale.com
lxc-attach: 100: ... Failed to exec "tailscale"
```

Ping to `1.1.1.1` from inside the CT worked (IP was fine). But every
hostname resolution failed.

**Diagnostic output:**

```
# pct exec 100 -- cat /etc/resolv.conf
# --- BEGIN PVE ---
search tailc4f63c.ts.net
nameserver 100.100.100.100
nameserver fd7a:115c:a1e0::53
# --- END PVE ---
# pct exec 100 -- systemctl status systemd-resolved
Active: active (running) since Thu 2026-07-02 07:34:15 CDT; 9min ago
```

**Root cause:** The CT's `/etc/resolv.conf` points at Tailscale
MagicDNS (`100.100.100.100`) — but the CT is not on the tailnet yet.
systemd-resolved is running fine, it's just configured to send queries
to an unreachable server.

Chain of events:
1. `boot.sh` joined the PVE HOST to the customer tailnet
2. Tailscale rewrote the host's `/etc/resolv.conf` to point at
   `100.100.100.100`
3. Community-scripts helper ran `pct create` for Mattermost — which
   by default copies the host's `/etc/resolv.conf` into the new CT
4. New CT inherited `100.100.100.100` as its nameserver
5. New CT hasn't installed/joined Tailscale yet, so it can't reach
   `100.100.100.100`
6. All DNS lookups fail → apt fails → tailscale install fails

This is a chicken-and-egg: to install Tailscale (which makes MagicDNS
usable inside the CT), we need DNS. To have MagicDNS, we need
Tailscale.

**NOT the initial hypothesis:** I first assumed a systemd-resolved
race after reboot. Wrong. resolved was up and stable; it was just
configured against an unreachable server. Documenting the wrong turn
so future debuggers don't chase the same hypothesis.

**Fix (in code, per CLAUDE.md "Install debugging: fix the script"):**

`addons/lib/ct-helpers.sh` has two new functions:

- `ct_stage_public_dns <CTID>` — writes `1.1.1.1` + `8.8.8.8` to the
  CT's `/etc/resolv.conf`. Idempotent. Tailscale will overwrite this
  once `tailscale up --accept-dns` runs inside the CT.
- `ct_fix_dns <CTID>` — smart recovery. Reads the CT's current
  resolv.conf. If it points at `100.100.100.100` (Case A —
  Tailscale MagicDNS from an unjoined CT), stages public DNS. If
  systemd-resolved is present but flaky (Case B — original hypothesis,
  still worth trying), restarts it.

`ct_wait_ready()` calls `ct_fix_dns` automatically if the initial DNS
check fails, then retries. This means every addon that calls
`ct_wait_ready` gets the fix for free.

`setup-mattermost.sh` sources the library and uses `ct_wait_ready`
after the LXC config edit + reboot.

**Files / Commit:** `addons/lib/ct-helpers.sh` (adds
`ct_stage_public_dns` + smarter `ct_fix_dns`); `addons/setup-mattermost.sh`
(sources helper, uses `ct_wait_ready`); TROUBLESHOOTING_LOG entry
(this one).

**Immediate remediation for a stuck box:**

```bash
# Stage public DNS in the CT manually
pct exec 100 -- bash -c "cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF"

# Confirm resolution works
pct exec 100 -- getent hosts tailscale.com

# Re-run the addon (idempotent — picks up where it left off)
cd /root/sobol-foundation && git pull && ./addons/setup-mattermost.sh
```

**Related:** ANY addon that does `pct create` after joining the PVE
host to a tailnet is vulnerable. Task #247 migrates
setup-n8n / setup-new-pi-agent / setup-postgres-shared etc. to use
`ct_wait_ready` so they inherit this fix. Consider also fixing at CT
creation time by passing `--nameserver 1.1.1.1` to `pct create` — but
community-scripts helpers don't accept nameserver overrides, so the
post-create staging is the reliable path.

---

## 2026-07-01 14:xx CT — Fresh PVE 9 install 401s on enterprise.proxmox.com (bootstrap-fresh-pve.sh)

**Symptom:** First real-hardware install of a fresh PVE 9.1.1 host via
`curl -fsSL http://<gitea>:3000/td/sobol-foundation/raw/branch/main/bootstrap-fresh-pve.sh | bash`
fails at the git-install step:

```
[sobol-bootstrap] Installing git...
E: Failed to fetch https://enterprise.proxmox.com/debian/ceph-squid/dists/trixie/InRelease  401 Unauthorized
E: The repository 'https://enterprise.proxmox.com/debian/ceph-squid trixie InRelease' is not signed.
E: Failed to fetch https://enterprise.proxmox.com/debian/pve/dists/trixie/InRelease  401 Unauthorized
```

Script dies (`set -Eeuo pipefail`) at `apt-get update` exit code 100.

**Root cause:** Fresh PVE installs default to enterprise repos (both
`pve-enterprise.list` / `.sources` AND `ceph-squid.list` on PVE 9). Without
a paid subscription these 401. `bootstrap-fresh-pve.sh` was written
assuming the repos were already swapped (which is typical on the author's
dev boxes) and didn't handle the fresh-install case.

The fix already existed in `sobol-business/tools/templates/firstboot.sh.template`
for the custom-ISO path (per prior entry — same debug session in June
2026), but was never backported to the manual-curl-install path.

**Fix:** Backport the repo-swap logic to `bootstrap-fresh-pve.sh` before
the `apt-get install git` step. Two moves:

1. Disable enterprise + ceph enterprise sources — handle both PVE 8
   `.list` format and PVE 9 `.sources` format:
   ```bash
   for f in /etc/apt/sources.list.d/pve-enterprise.list \
            /etc/apt/sources.list.d/ceph.list \
            /etc/apt/sources.list.d/pve-enterprise.sources \
            /etc/apt/sources.list.d/ceph.sources; do
     [[ -f "$f" ]] || continue
     sed -i 's/^deb /# deb /g; s/^Enabled: true/Enabled: false/' "$f"
   done
   ```

2. Add no-subscription — detect codename dynamically so PVE 8 gets
   `bookworm`, PVE 9 gets `trixie`:
   ```bash
   DEB_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
   echo "deb http://download.proxmox.com/debian/pve $DEB_CODENAME pve-no-subscription" \
     > /etc/apt/sources.list.d/pve-no-subscription.list
   ```

Also documented the pre-tailnet IP workaround in the script header —
on first install before Tailscale is joined, `gitea:3000` doesn't
resolve; operators must use the LAN IP for both the curl AND the
`SOBOL_REPO_URL` override.

**Files / Commit:** `bootstrap-fresh-pve.sh` (add §1a repo-swap block
before §1b git-install; +40 lines).

**Related:** Same pattern as the June 2026 ISO iteration-1 fix in
`firstboot.sh.template`. Third time we've hit this class of issue
(enterprise-repos-on-fresh-install); worth promoting to the top-of-log
"architectural patterns" section.

---

## 2026-06-28 19:45 CT — Health watchdog false-alerted VZDUMP_STALE despite working backups

**Symptom:** After `setup-usb-backup.sh` registered `usb-backup` as a
PVE storage at `/mnt/pve-backup` and `vzdump --all --storage usb-backup`
successfully wrote backup files there, the hourly `td-health-watchdog`
timer still emailed:

> No vzdump backup files found in any standard location
> (/var/lib/vz/dump, /mnt/pve/*/dump, /var/backups). Backup may not be
> configured.

`ls -la /mnt/pve-backup/dump/` showed seven fresh `vzdump-lxc-*.tar.zst`
files. `pvesm status --content backup` showed `usb-backup` as `active`.
Backups WERE working — the watchdog just couldn't see them.

**Root cause:** The VZDUMP_STALE check hard-coded its search paths:

```bash
for dir in /var/lib/vz/dump /mnt/pve/*/dump /etc/pve/local /var/backups; do
```

That `/mnt/pve/*/dump` glob assumes the PVE convention of storage names
mounted under `/mnt/pve/<storage-name>/`. But `setup-usb-backup.sh`
mounts at `/mnt/pve-backup/` (no `/pve/` subdir) by design — a single
mount path that's easier to remember and inspect. The glob never
expanded to that location, the find returned empty, and the check
falsely concluded no backups existed.

**Companion bug along the way (commit `b9d8dc0`):** While diagnosing,
discovered that `setup-vzdump-schedule.sh`'s preflight also relied on a
non-existent command — `pvesm config <name>` — which silently returned
no output, causing the preflight to falsely die with
"storage doesn't include backup in content types" even though
`/etc/pve/storage.cfg` showed `content backup,snippets,iso`. Replaced
with `pvesm status --content backup` (which filters to backup-capable
storages) plus a `/etc/pve/storage.cfg` parse as fallback.

**Fix:** Replace the hard-coded path list with discovery from
`/etc/pve/storage.cfg`. awk parses every `dir:` stanza, grabs the
`path` and `content` fields, and any stanza whose content includes
`backup` contributes `<path>/dump` to the search list. `/var/lib/vz/dump`
stays in as a legacy fallback. Result: any future addon that registers
a backup-content storage at any path is automatically picked up.

**awk parser pitfall worth remembering:** First version of the parser
had two separate header rules — one for `/^dir: /` and one for
"next stanza header while in_block". When two `dir:` stanzas appeared
back-to-back, the second rule never fired because the first rule
matched and called `next` before it could emit the previous block.
The fix was to merge into a single boundary rule that emits any
pending block FIRST, then conditionally opens a new one if the boundary
is a `dir:`. Test fixture for this:

```
dir: local
        path /var/lib/vz
        content backup,iso,vztmpl

dir: usb-backup
        path /mnt/pve-backup
        content backup,snippets,iso
```

Should output BOTH lines. The buggy version only printed `usb-backup`.

**Files / Commits:**
- `repo/addons/setup-vzdump-schedule.sh` — preflight check rewritten
  (commit `b9d8dc0`)
- `repo/addons/setup-health-watchdog.sh` — VZDUMP_STALE path discovery
  (commit `5570c7a`)
- `repo/addons/setup-usb-backup.sh` — auto-install `parted` +
  `e2fsprogs` (commit `e728eea`); was the original USB-prep addon
  (commit `beaa4d2`)

**Related architectural pattern:** Any time a script asks "where on
disk are my backups / snippets / ISOs / templates?" — query PVE's
storage config, don't assume the layout. The storage.cfg parsing
snippet in `setup-health-watchdog.sh` is the reference implementation;
copy it into any future addon that needs to discover storage paths.

**Operator verification after fix:**
```bash
rm /var/lib/td-health/state.json
/usr/local/bin/td-health-check
# silent run = all 7 checks pass
```

---

## 2026-06-28 19:30 CT — Email layer added to foundations + TD-Proxmox + studio-stack

**Symptom (preventative, not reactive):** PVE alerts (vzdump completion,
subscription nag, root mail) silently go into the local Postfix queue
and never reach a real inbox. Mattermost @mentions never email offline
users. Cal.com booking confirmations sit in queue.

**Root cause:** Default PVE postfix tries to deliver mail directly from
the home IP, which gets blocked by every modern receiver. There's no
SMTP relay configured out of the box, and no service in the stack has
SMTP credentials wired.

**Fix:** Centralize SMTP credentials in `<stack>-tokens.txt` as
`SMTP_HOST/PORT/USERNAME/PASSWORD/FROM/FROM_NAME` + `ADMIN_NOTIFY_EMAIL`.
Run `setup-pve-email.sh` to configure host postfix relay. Each app's
config picks up the same vars by name.

**Files / Commit:**
- `proxmox-stack-foundations/templates/addons/setup-pve-email.sh` (commit `1840514`)
- `proxmox-stack-foundations/foundations.md` §5 Email layer (same)
- `td-proxmox/addons/setup-pve-email.sh` + `setup-email-relay.sh` (commit `f6c3b2d`)
- `td-proxmox/automation/configure-apps.sh` — `resolve_smtp_creds()` + `configure_email()` (same)
- `td-proxmox/addons/setup-mattermost.sh` — `EmailSettings` in config PUT (same)
- `studio-stack/automation/bootstrap-pve.sh` — SMTP_* prompts (commit `28b1f89`)

**Related:** SMTP / postfix relay architectural pattern (top of this file).

---

## 2026-06-28 17:00 CT — Postmark rejects "Sender signature not confirmed"

**Symptom (anticipated):** First test email from `setup-pve-email.sh`
fails. Postmark API returns `SenderSignatureNotConfirmed`. Either the
`--test-only` run errors out or the message sits in `mailq` with the
rejection.

**Root cause:** Postmark requires sender domain or address verification
BEFORE allowing outbound. You can't just claim `From: alerts@yourdomain.com`
— you have to verify it in the Postmark dashboard first.

**Two verification options:**

1. **Sender Signature** (fastest, per-address) — Postmark → Sender
   Signatures → Add → enter `alerts@soboldata.com` → click the link in
   the confirmation email they send you. ~2 min, works immediately.
2. **Domain verification** (better, covers all addresses on the domain)
   — Postmark → Sender Signatures → DKIM → add the suggested DKIM TXT
   record to your domain's DNS. Once propagated (~5 min on Cloudflare),
   ALL `@soboldata.com` senders work without per-address signup.

**Fix:** Don't run the email addon until at least one sender is verified
in Postmark. Then `--test-only` succeeds.

**Related:** SMTP / postfix relay pattern. The default-deny is on the
provider's side, not the service's.

---

## 2026-06-28 16:30 CT — MM SMTP works in test but @mention emails silently drop

**Symptom (anticipated):** Mattermost `setup-mattermost.sh` runs cleanly
with SMTP_* set. Test email from System Console succeeds. But @mention
notifications to offline users don't arrive.

**Three likely causes, in order:**

1. **`SendEmailNotifications = false`.** MM defaults this to true on
   fresh installs but flips to false if you ever set
   `EmailSettings.EnableEmailNotifications` to false elsewhere.
2. **`FeedbackEmail` not verified at Postmark.** MM uses
   `FeedbackEmail` (not the SMTP `From:`) as the actual sender. Even
   if SMTP_FROM is verified, FeedbackEmail must match — and if it's
   empty MM falls back to `mattermost@<hostname>`, which Postmark
   rejects.
3. **User-level notification preferences.** Each MM user has individual
   email-notification settings. If the recipient has them disabled, no
   amount of SMTP wiring delivers.

**Fix:** `setup-mattermost.sh`'s config PUT (commit `f6c3b2d`) now sets:
- `SendEmailNotifications = true`
- `FeedbackEmail = $SMTP_FROM`
- `FeedbackName = $SMTP_FROM_NAME`

For cause #3, the recipient flips Account Settings → Notifications →
Email → Always send email notifications.

---

## 2026-06-28 16:00 CT — vzdump completion email never arrives

**Symptom:** vzdump runs nightly per `/etc/pve/jobs.cfg`. Log shows
success. But no email lands in `ADMIN_NOTIFY_EMAIL`.

**Three causes to check in order:**

1. **Postfix queue stuck.** Run `mailq` on the PVE host. If messages
   are queued with errors, the SMTP relay isn't configured (run
   `setup-pve-email.sh`) OR the auth is wrong (check
   `/etc/postfix/sasl_passwd`, re-run `postmap` after edit).

2. **PVE's `mail-from` empty.** Check `/etc/pve/datacenter.cfg`:
   ```bash
   grep mail-from /etc/pve/datacenter.cfg
   ```
   If empty, the alert is sent with no `From:` header, which the relay
   rejects. `setup-pve-email.sh` writes `mail-from: $SMTP_FROM` to fix.

3. **vzdump's per-job notification setting.** `/etc/pve/jobs.cfg`
   entries can override notification. Check the `mailto:` and
   `mailnotification:` fields on the vzdump job. Default
   `mailnotification: always` is what you want; `failure` only sends on
   errors.

**Quick bisect:** `echo "test" | mail -s "manual test" you@inbox.com`
from the PVE host. If THIS works, the relay is fine and the issue is
PVE-side (cause 2 or 3). If it doesn't, the relay needs setup (cause 1).

---

## 2026-06-28 12:15 CT — n8n died overnight (V8 heap OOM)

**Symptom:** Wake up to `n8n.service` in `failed (Result: signal)` state after
~3h uptime. Service was running fine, then died at 02:49:48 with:
```
FATAL ERROR: Ineffective mark-compacts near heap limit
Allocation failed - JavaScript heap out of memory
Main process exited, code=killed, status=6/ABRT
Mem peak: 1.3G
```

**Root cause:** Node.js's default V8 heap limit is ~1.4GB on 64-bit. Under
sustained load (Gitea retrying SSRF-blocked webhooks, Mattermost credential
403 retries, execution log accumulation in memory before flush) n8n hit the
ceiling. CT had 2GB RAM available but V8 never asked the OS for more than its
internal default. SIGABRT killed the process. systemd unit had no `Restart=`
directive so it stayed dead.

**Fix:** Edit the systemd unit at `/etc/systemd/system/n8n.service`:
- Add `Environment=NODE_OPTIONS=--max-old-space-size=2048` (gives V8 2GB heap)
- Add `Restart=on-failure` + `RestartSec=10` (auto-recover from future OOMs)

Then `systemctl daemon-reload && systemctl restart n8n`. For extra cushion, bump
CT RAM to 4GB: `pct set <CTID> -memory 4096`.

**Files / Commit:** `addons/setup-n8n.sh` (commit `055d83a`) — baked into fresh
installs; existing CTs get the patch on next `--credentials-only` run.

**Related:** Future overnight-failure entries should compare against this.

---

## 2026-06-28 02:15 CT — Gitea webhook to n8n silently blocked (SSRF gate)

**Symptom:** Gitea webhook configured with correct URL `http://10.27.0.218:5678/webhook/gitea-events`. Recent Deliveries shows attempts, but the response is:
```
Post "http://10.27.0.218:5678/webhook/gitea-events": dial tcp ...:
webhook can only call allowed HTTP servers (check your
webhook.ALLOWED_HOST_LIST setting), deny '10.27.0.218'
```
No execution appears in n8n.

**Root cause:** Gitea has its own anti-SSRF gate — `webhook.ALLOWED_HOST_LIST`
in `app.ini`. Default empty value blocks every RFC1918 destination. Same
architectural pattern as Mattermost's `AllowedUntrustedInternalConnections`.

**Fix:** Edit `app.ini`'s `[webhook]` section:
```ini
[webhook]
ALLOWED_HOST_LIST = private,loopback,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10
```
Then `systemctl reload gitea` (or restart). Belt-and-suspenders: both Gitea's
named groups (`private`, `loopback`) and explicit CIDR fallbacks.

**Files / Commit:** `automation/configure-apps.sh` (commit `baa5f04`) — fresh
installs get this baked in from `configure_gitea`.

**Related:** Mattermost SSRF gate (2026-06-27 22:30 entry). Both follow the
same architectural pattern; always check this first when a service-to-service
webhook silently fails.

---

## 2026-06-28 01:30 CT — Gitea events workflow saved with wrong resource/operation

**Symptom:** Gitea webhook reaches n8n, workflow runs, `finished: True` with no
error, Post to Mattermost node output is `{}` — but no message appears in Town
Square.

**Root cause:** While poking the Mattermost node's Channel dropdown to test if
the credential could fetch the channel list, accidentally **saved the workflow**
with `resource: user, operation: getById` instead of `resource: message,
operation: post`. The node was fetching a user (with no ID) and returning empty
`{}`. n8n reported success because MM returned 200 OK to the user-fetch call.

**Fix:** Open the Post to Mattermost node in the n8n UI. Set:
- Resource: Message
- Operation: Post  
- Channel: Expression mode → paste `te9ckat1p3b3ukshup6z5jaesr`
- Message: `={{$json.text}}`
- Credential: Mattermost (pi-bot)

Save. Workflow now posts correctly.

**Files / Commit:** Live config only — no script change needed (this was a
user-side mistake, the JSON in the repo is correct).

**Related:** Channel UUIDs (Fixed vs Expression mode) — see architectural
patterns above.

---

## 2026-06-28 01:00 CT — Webhook Test URL vs Production URL confusion

**Symptom:** Gitea webhook configured with what looked like the right n8n URL,
delivery log shows success, but no execution in n8n.

**Root cause:** Copied `/webhook-test/gitea-events` (the test URL, only listens
for one event after clicking "Execute workflow" in the editor) instead of
`/webhook/gitea-events` (the production URL, registered when workflow is
Active). The test URL responds with a benign 200 even when not actively
listening, fooling Gitea's delivery log.

**Fix:** In Gitea webhook config, change target URL from `/webhook-test/...` to
`/webhook/...`. Re-trigger to verify.

**Files / Commit:** Live config only.

**Related:** Always copy the **Production URL** shown at the bottom of the
Webhook node's parameter panel — never the Test URL, even though n8n's UI
often displays the test URL more prominently.

---

## 2026-06-28 00:30 CT — Format digest reported "no activity" despite recent commits

**Symptom:** Workflow ran all green end-to-end, Mattermost post landed, but
text said `:sleeping: No Gitea activity in the last 24 hours.` even though
commits within 24h existed.

**Root cause:** n8n's HTTP Request node **auto-splits array responses** into
individual items. When `Fetch commits per repo` returned `[commit1, commit2,
...]`, n8n unpacked the array and each commit became a separate item.
My old Format digest code assumed `item.json` was an array of commits and
did `(item.json || []).filter(...)`. Since each `item.json` was actually a
single commit object (not an array), `.filter` is undefined on the wrong shape
and crashed; the `!Array.isArray(raw)` guard then skipped every commit.

**Fix:** Rewrite Format digest to iterate commit-by-commit via `$input.all()`
and group by `c.repository.full_name` (Gitea sometimes includes it) or a URL
parse of `c.url` (which is always present). Filter on `c.commit.author.date >=
cutoff`.

**Files / Commit:** `addons/n8n/workflows/gitea-daily-digest.json` (commit `480b6a5`).

**Related:** Any workflow with HTTP Request → Code: assume auto-array-split,
treat each item as a single record, not a collection. Set "Split Into Items"
off explicitly if you want the array as a single item.

---

## 2026-06-27 23:50 CT — Wrong n8n CT — two-PVE name collision

**Symptom:** Two browser tabs to "n8n" — one logs in fine (LAN IP
`http://10.27.0.218:5678`), the other rejects the password
(`http://n8n:5678`). The tab favicons are different colors.

**Root cause:** Tailscale's DNS server (`100.100.100.100`) resolves the
hostname `n8n` to `10.27.0.124` (the **other** PVE host's n8n CT, from an
earlier parallel test build), not `10.27.0.218` (THIS PVE's n8n CT, where the
password was set). They're separate installs with different credentials, hence
the login mismatch.

**Diagnosis from client:**
```bash
nslookup n8n          # returns 100.100.100.100 → 10.27.0.124 ≠ expected
tailscale status | grep n8n
```

**Fix options:**
- **Use the LAN IP directly** (simplest): bookmark `http://10.27.0.218:5678`.
- **Update Tailscale's static DNS record** in admin → DNS → Custom records to
  point `n8n.localdomain` at `10.27.0.218`.
- **Decommission the other n8n CT** on the other PVE host.
- **Rename this CT** in Tailscale (`tailscale up --hostname=td-n8n`) so the
  two coexist without colliding.

**Files / Commit:** Live config only — this is an infrastructure-level
collision, not a script issue.

**Related:** The same pattern bit us with `gitea.localdomain` resolving to
`10.27.0.239` (other PVE) on the n8n CT — fixed by `/etc/hosts` override.

---

## 2026-06-27 23:30 CT — n8n password DB direct-update needed (locked out)

**Symptom:** Could not log in to n8n UI with the password used at signup, even
after multiple attempts. API key still worked. Account exists in `user` table
with `role=global:owner, disabled=0`.

**Root cause:** Unknown — possibly mistyped at original signup, possibly a
script side-effect that hashed something wrong. Symptom matched a corrupt or
unknown password hash, not a disabled account.

**Fix:** Reset the bcrypt hash directly in `database.sqlite`:

```bash
N8N_CTID=$(pct list | awk '/n8n /{print $1}')
DB=/.n8n/database.sqlite

# Install bcrypt via apt (not pip — pip isn't installed in the community CT)
pct exec $N8N_CTID -- apt-get install -y python3-bcrypt

NEW_PASSWORD='TdHomelab1234!'
NEW_HASH=$(pct exec $N8N_CTID -- python3 -c "
import bcrypt
print(bcrypt.hashpw('$NEW_PASSWORD'.encode(), bcrypt.gensalt(10)).decode())
")

pct exec $N8N_CTID -- sqlite3 $DB "
  UPDATE \"user\" 
  SET password = '$NEW_HASH', mfaEnabled = 0, mfaSecret = NULL, mfaRecoveryCodes = NULL
  WHERE email = 'posaprivy@tutanota.com';
"
```

Browser-side: stale session cookie may persist; use an Incognito window OR
clear cookies + localStorage for the n8n origin to log in with the new password.

Verify the hash is exactly 60 chars and starts with `$2a$10$` or `$2b$10$`. If
shorter, the shell mangled it (use file-based update via heredoc instead).

**Files / Commit:** No script change — recovery is one-off. But this is the
escape hatch if it happens again.

**Related:** If everything else fails: `pct exec <ctid> -- n8n user-management:reset`
deletes the owner (workflows + credentials preserved) and re-renders the signup
form.

---

## 2026-06-27 23:00 CT — n8n CT had no Tailscale (silent install failure)

**Symptom:** `pct exec <n8n-ct> -- tailscale status` returns `bash: tailscale:
command not found`. Earlier setup-n8n.sh run had said "Joining Tailscale..."
but the binary isn't there.

**Root cause:** Earlier version of `setup-n8n.sh` ran the Tailscale install
inside `bash -lc "... >/dev/null 2>&1"`, masking any install failure. The
install actually failed (network blip, repo unreachable, etc.) but the script
reported success.

**Fix:** Make the Tailscale install step loud:
- Strip `>/dev/null 2>&1` from the install
- After install, verify `command -v tailscale` exists before attempting `up`
- If the binary is missing, surface a clear warning that the CT is LAN-only
  and the user needs `/etc/hosts` entries to resolve in-stack hostnames

**Files / Commit:** `addons/setup-n8n.sh` (commit `f8c85d8`).

**Related:** When LAN-only, the n8n CT also needs `/etc/hosts` entries for
`gitea`, `mattermost`, `ollama-pi-agent`, etc., to resolve correctly. The user
got bit because of a stale `10.27.0.239 gitea.localdomain` entry — see next.

---

## 2026-06-27 22:45 CT — Wrong Gitea reached due to stale /etc/hosts

**Symptom:** Gitea daily digest workflow runs but gets HTTP 401 on every API
call. The Gitea token works against `10.27.0.226` (the local CT) but not
against the URL n8n was resolving to.

**Root cause:** n8n CT's `/etc/hosts` had a stale entry from an earlier debug
session:
```
10.27.0.239     gitea.localdomain
```
`10.27.0.239` is the OTHER PVE host's Gitea CT — different install with a
different token. The Tailscale DNS search domain `localdomain` was auto-appended
to bare `gitea`, matching this entry, routing the request to the wrong server.

**Fix:** Strip the stale entry and add proper local mappings:
```bash
N8N_CTID=$(pct list | awk '/n8n /{print $1}')
pct exec $N8N_CTID -- sed -i '/gitea\.localdomain/d' /etc/hosts
pct exec $N8N_CTID -- bash -lc "cat >> /etc/hosts <<EOF
10.27.0.226 gitea
10.27.0.91 mattermost
10.27.0.116 ollama-pi-agent
10.27.0.157 openwebui
10.27.0.9 homepage
10.27.0.100 sandbox
EOF"
```

**Files / Commit:** Live fix only. Future work: bake an `/etc/hosts` writer
into every CT-creating addon so each new CT has a definitive local hostname →
local IP mapping for all in-stack services.

**Related:** Two-PVE name collision (above). Same root cause: parallel installs
on multiple machines using the same hostnames.

---

## 2026-06-27 22:15 CT — pi-bot 403 when posting to Mattermost channel

**Symptom:** Mattermost workflow run errors with:
```
"errorMessage": "Forbidden - perhaps check your credentials?",
"errorData": {"id": "api.context.permissions.app_error"}
```

**Root cause:** pi-bot is a valid Mattermost user with a valid token, but it
isn't a **member** of `#town-square` (or whatever channel the workflow targets).
Bots don't auto-join any channel at creation — including the default
town-square that every human user gets.

**Fix:** Add pi-bot to town-square via MM API (no admin required — bot can join
public channels itself):
```bash
MM_CTID=$(pct list | awk '/mattermost/{print $1}')
TOKEN=$(awk -F= '/^MATTERMOST_BOT_TOKEN=/ {sub(/^[^=]*=/,"",$0); val=$0} END {print val}' /root/td-tokens.txt)
TEAM_ID=$(awk -F= '/^MATTERMOST_TEAM_ID=/ {sub(/^[^=]*=/,"",$0); val=$0} END {print val}' /root/td-tokens.txt)
pct exec $MM_CTID -- bash -lc "
  BOT_USER=\$(curl -sS -H 'Authorization: Bearer $TOKEN' http://localhost:8065/api/v4/users/me | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"id\"])')
  CHAN_ID=\$(curl -sS -H 'Authorization: Bearer $TOKEN' http://localhost:8065/api/v4/teams/$TEAM_ID/channels/name/town-square | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"id\"])')
  curl -sS -X POST -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' -d \"{\\\"user_id\\\":\\\"\$BOT_USER\\\"}\" http://localhost:8065/api/v4/channels/\$CHAN_ID/members
"
```

**Files / Commit:** `addons/setup-mattermost.sh` (commit `017997e`) — fresh
installs auto-add pi-bot to town-square + #bot + #ai-chat.

**Related:** Mattermost SSRF gate (below) — different layer of "this should
just work" but doesn't out of the box.

---

## 2026-06-27 21:45 CT — Mattermost outgoing webhooks blocked by SSRF gate

**Symptom:** Outgoing webhook configured to point at `http://n8n:5678/webhook/mm-chat`. Trigger word fires. Nothing reaches n8n. Mattermost server log silent.

**Root cause:** Mattermost has anti-SSRF protection that blocks outgoing
webhook destinations resolving to RFC1918 / private IPs. The gate setting is
`ServiceSettings.AllowedUntrustedInternalConnections`, default empty (= block
all). Famously under-documented.

**Fix:** Set the allowlist via API config PUT (admin token required):
```bash
"ServiceSettings": {
  "AllowedUntrustedInternalConnections":
    "localhost 127.0.0.1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 n8n ollama-pi-agent gitea openwebui homepage sandbox mattermost",
  "EnablePostUsernameOverride": true,
  "EnablePostIconOverride": true,
  "EnableDynamicClientRegistration": true
}
```

Restart Mattermost. (`EnableDynamicClientRegistration` was the user's recall
from a prior install — included as belt-and-suspenders, possibly fixes an
unrelated MM bug that interfered with webhooks.)

**Files / Commit:** `addons/setup-mattermost.sh` (commits `40c874e` + `f520111`)
— baked into `configure_mattermost`'s config PUT block.

**Related:** Gitea SSRF gate (2026-06-28 02:15 entry). Same architectural
pattern — check both first when service-to-service webhooks silently fail.

---

## 2026-06-27 21:30 CT — Owner password update via UI fails (browser cache)

**Symptom:** Updated password hash in n8n's `database.sqlite` directly. `curl`
against `/rest/login` returns HTTP 200 OK with valid session cookie. Browser
form keeps saying "Wrong username or password."

**Root cause:** Browser has stale `n8n-auth` session cookie from a previous
login attempt + cached frontend state. n8n's frontend uses the stale cookie
before falling back to fresh form auth, getting 401, and looping.

**Fix:** Open n8n in an **Incognito / Private** browser window. Or clear
cookies + localStorage for the n8n origin in DevTools → Application tab,
hard-refresh.

**Files / Commit:** No code change — pure browser-side state.

**Related:** Any auth flow where direct API works but UI doesn't — first
suspect is browser session state.

---

## 2026-06-27 21:00 CT — Mistakenly pasted placeholder text as a token

**Symptom:** `N8N_API_KEY=<paste the key here>` appears literally in
`/root/td-tokens.txt`. Script keeps using the 20-char placeholder string as
the API key and getting 401 from n8n.

**Root cause:** Followed copy-paste instructions including the literal
`<paste the key here>` placeholder. Appended the real key on a second line
later. `read_token` originally took the **first** match for a key, returning
the bogus placeholder.

**Fix:** Two changes to `read_token` in `setup-n8n.sh`:
- Return the **last** match (so later appends override earlier values)
- Reject obvious placeholder values: `<...>`, `REPLACE_ME`, `CHANGEME`,
  empty string

Also added a duplicate-line warning to `diagnose-n8n.sh` that fires loudly if
multiple `N8N_API_KEY=` lines exist.

**Files / Commit:** `addons/setup-n8n.sh` + `addons/n8n/diagnose-n8n.sh`
(commit `5c2710b`).

**Related:** Generic shell-instruction-following risk. If a copy-paste
snippet contains a `<placeholder>`, run-as-is is a possible failure mode.

---

## 2026-06-27 20:30 CT — n8n owner setup needed real email + numeric password

**Symptom:** First-run n8n owner setup via `/rest/owner/setup` fails. Manual
signup via UI works, but only with a real email and a password containing at
least one number.

**Root cause:** n8n 2.x's owner setup:
- Requires the email field to be a real reachable mailbox (sends activation
  code). `admin@homelab.local` doesn't work.
- Validates that the password contains at least one digit (in addition to the
  usual 8+ chars).

The stack-wide `ADMIN_PASSWORD` is letters-only by default and `ADMIN_EMAIL`
is synthetic, so neither field satisfies n8n.

**Fix:** Add per-app overrides in `/root/td-tokens.txt`:
```
N8N_OWNER_EMAIL=you@tutanota.com
N8N_OWNER_PASSWORD=Xnrs9gRWeHLGM7p
```
`setup-n8n.sh` prefers these when set, falls back to `ADMIN_*` otherwise. The
script's pre-flight prints a warning if the password it's about to use has no
digit, so the failure mode is explicit not silent.

**Files / Commit:** `addons/setup-n8n.sh` (commit `e2dd1da`). README-addons.md
documents the requirements.

**Related:** Service-specific account requirements that don't match
stack-wide defaults — pattern likely to repeat with other services. Each
addon's preflight should validate against the service's specific rules.

---

## 2026-06-27 20:00 CT — Shell quoting: env-vars must precede python3

**Symptom:** Python `KeyError: 'ADMIN_EMAIL'` when running:
```bash
OWNER_BODY="$(python3 -c '...' ADMIN_EMAIL="$ADMIN_EMAIL" ...)"
```

**Root cause:** Bash treats `KEY=VAL` at the **end** of a command line as
positional argv (which python ignores), not env vars. Only `KEY=VAL` at the
**start** of the command sets env.

**Fix:** Move env vars before the command:
```bash
OWNER_BODY="$(ADMIN_EMAIL="$ADMIN_EMAIL" python3 -c '...')"
```

**Files / Commit:** `addons/setup-n8n.sh` (commit `fcded8b`).

**Related:** General shell pattern — applies anywhere `VAR=val cmd` is used
to inject env. Always at the start.

---

## 2026-06-27 19:45 CT — JSON payload corrupted through pct exec quoting

**Symptom:** n8n credential creation via REST API returns 4xx errors with
mangled JSON in the request body. Direct curl from inside the CT works.

**Root cause:** `pct exec <ct> -- bash -lc "curl -d '$body'"` where `$body`
contains JSON with `"` characters: the `"` in JSON collides with the outer
`bash -lc "..."` double-quote delimiter, mangling curl's `-d` argument.

**Fix:** Write the payload to a temp file inside the CT and use `curl
--data-binary @file`:
```bash
printf '%s' "$body" > /tmp/payload.tmp
pct push "$CTID" /tmp/payload.tmp /tmp/n8n-body.json
pct exec "$CTID" -- bash -lc "curl ... --data-binary @/tmp/n8n-body.json"
```

**Files / Commit:** `addons/setup-n8n.sh` (commit `c3e3553`).

**Related:** Generic — any time a payload contains arbitrary characters and
needs to traverse multiple quoting layers, use file-based transport.

---

## 2026-06-27 19:30 CT — n8n public API rejects giteaApi / ollamaApi credentials

**Symptom:** Creating a credential of type `giteaApi` (or `ollamaApi`) via
`POST /api/v1/credentials` returns:
```json
{"message": "req.body.type is not a known type"}
```

**Root cause:** n8n 2.x's public REST API maintains a smaller whitelist of
credential types than the UI's full picker. Some types (including `giteaApi`
and `ollamaApi`) exist in the UI but are blocked from creation via REST for
security.

**Fix:** Use a generic credential that IS on the API whitelist and is
functionally equivalent. For Gitea: create `httpHeaderAuth` named
"Gitea (admin) — Bearer" with value `token <PAT>`. Any HTTP Request node can
use it against any Gitea endpoint. Same for Ollama: skip the credential
entirely; Ollama is unauthenticated on tailnet, use a plain HTTP Request node
to `http://ollama-pi-agent:11434/api/chat`.

**Files / Commit:** `addons/setup-n8n.sh` (commits `017997e` + `1bf2761`).

**Related:** When the n8n public API doesn't accept a credential type, fall
back to `httpHeaderAuth` or `httpBasicAuth` plus an HTTP Request node.

---

## 2026-06-27 19:00 CT — Fake n8n node type in workflow JSON

**Symptom:** Activating the `mm-ollama-chat` workflow fails with:
```
Unrecognized node type: n8n-nodes-base.ollama
```

**Root cause:** `n8n-nodes-base.ollama` doesn't exist as a node type. The real
Ollama node lives in the LangChain package at
`@n8n/n8n-nodes-langchain.lmChatOllama`, which may or may not be installed in
the community-scripts n8n image.

**Fix:** Replace the dedicated Ollama node with a generic HTTP Request node
posting to `http://ollama-pi-agent:11434/api/chat` with body:
```json
{
  "model": "gemma4:31b-cloud",
  "stream": false,
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "{{$json.body.text}}"}
  ]
}
```
Ollama is unauthenticated on tailnet so no credential needed. Works on any n8n
install regardless of LangChain package presence.

**Files / Commit:** `addons/n8n/workflows/mm-ollama-chat.json` + `addons/setup-n8n.sh` (commit `1bf2761`).

**Related:** Generic: when a node type doesn't exist or depends on an optional
package, fall back to HTTP Request + the service's REST API.

---

## 2026-06-27 18:30 CT — Gitea webhook payload structure surprise

**Symptom:** Gitea events fired, n8n received the webhook, but Format event
node returned `{skip: true}` for every push — never matched the push branch.

**Root cause:** My switch statement checked `headers['x-gitea-event']` but
wasn't seeing the value I expected. Turned out the actual issue was n8n's
header normalization: it lowercases everything, but my code was
case-sensitive on the **value** side (`'push'` vs `'Push'`). Gitea sends
lowercase event values so this happened to work, but other services with
mixed-case values would fail.

**Fix:** Lowercase the event value defensively:
```javascript
const eventType = (headers['x-gitea-event'] || '').toLowerCase();
```

**Files / Commit:** `addons/n8n/workflows/gitea-events-to-mattermost.json` (initial commit `884c33e`).

**Related:** Anything reading HTTP headers from n8n: keys are lowercased,
but values are passed through as-is. Always normalize the value side too.

---

## 2026-06-27 18:00 CT — n8n owner-setup REST endpoint returns conflicting codes

**Symptom:** `POST /rest/owner/setup` returns HTTP 400 even though the owner
doesn't exist yet. Or returns 400 the second time when the owner is set up.

**Root cause:** n8n 2.x returns:
- HTTP 200/201 on first successful setup
- HTTP 400 if owner already exists (response body says "already")
- HTTP 400 if the request body fails validation (e.g., password rules)
The same status code means two very different things; need to check the body.

**Fix:** Case on the HTTP code, but distinguish:
- 200/201 → success
- 400 + body mentions "already" → owner exists, log in instead
- 400 + body says validation → re-prompt with corrected fields

**Files / Commit:** `addons/setup-n8n.sh` (commit `fcded8b`).

**Related:** When a REST API uses overloaded status codes, always inspect the
response body before reacting.

---

## 2026-06-27 17:00 CT — Gitea CLI deprecated --username flag

**Symptom:** `gitea admin user delete-access-token --username admin --name pi-agent`
fails on Gitea 1.26: `unknown flag --username`.

**Root cause:** Gitea 1.26 removed `--username` from the token-management
CLI subcommands. The CLI's surface is unstable across versions.

**Fix:** Switch all token management to the REST API (stable since 1.18):
```bash
# Delete: DELETE /api/v1/users/{user}/tokens/{name}
# Mint:   POST /api/v1/users/{user}/tokens  → returns sha1
```
Both accept basic auth as the target user.

**Files / Commit:** `automation/configure-apps.sh` (commit history pre-dates
this log; check `configure_gitea` for the REST-based implementation).

**Related:** When a service's CLI is unstable but the REST API is documented
to be stable, prefer the API even from inside the CT.

---

## End-of-log housekeeping

When this file gets long, the oldest entries can be moved to
`TROUBLESHOOTING_LOG_<year>.md` archive files. Don't delete — they're the
record of what was tried.

If a new entry duplicates an existing one (same symptom, same fix), add a
cross-reference to `**Related:**` instead of writing a duplicate entry. If
the same architectural pattern shows up a third time, promote it to the
"Architectural patterns to recognize fast" section at the top.
