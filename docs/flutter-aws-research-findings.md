# Flutter Android client + AWS deployment — research findings

Research executed 2026-09-11 against commit `3bc36a6` on `dev`. Companion to
`docs/flutter-aws-research-prompt.md`. Codebase claims are cited `file:line`; time-sensitive
claims carry a source and a date.

## Verdict: GO, with one unavoidable operational tax

Nothing here is technically blocked. The budget is not tight. But **one finding changes the
plan materially and cannot be engineered away**, so it goes first.

---

## 1. The finding that changes things: weekly Gmail re-consent is mandatory

The approved plan said: while the OAuth consent screen is in Testing, refresh tokens expire
after 7 days, and the fix is to publish to Production and let users click through the
"unverified app" warning.

**The second half is wrong.** The 7-day expiry attaches to *unverified apps*, not to Testing
status specifically. Publishing to Production does not lift it while the app remains unverified
for the scopes it requests.

And this project requests the most sensitive tier there is. `GMAIL_OAUTH_SCOPES` is
`https://mail.google.com/` (`brain/emailtool.py:63`) — full Gmail access, required for IMAP,
and a **restricted** scope rather than merely sensitive. Lifting the 7-day expiry for a
restricted scope requires completing Google verification including a third-party security
assessment: weeks of calendar time and a four-figure minimum cost. For a two-month college
demo that is categorically out of scope.

**So, as a fixed constraint:** every connected user re-consents to Gmail **every 7 days**,
roughly 8 times over the project's life. No configuration avoids it.

That is an annoyance rather than a blocker at fewer than 10 users — but it has to be *designed
for* rather than discovered:

- Treat `invalid_grant` as a **routine expected state**, not an error. "Reconnect Gmail" should
  be a first-class call to action, not a red failure toast.
- The server knows when consent happened, so **show the expiry proactively**: "Gmail connection
  expires in 2 days" beats a silently empty inbox.
- **Reconnect immediately before any demo.** The most likely way this project embarrasses
  someone is a demo on day 8 with an empty screen and nobody knowing why.
- The same applies to Calendar (`calendar.events`, `brain/calendar_tool.py:33`) — sensitive
  rather than restricted, but unverified all the same.

This is risk number one, precisely because it presents as a bug.

---

## 2. A simplification the plan missed: the app needs no deep links

The plan specified `flutter_web_auth_2` plus an `AndroidManifest.xml` intent filter to capture
the OAuth redirect. **Neither is necessary**, because the token exchange happens server-side.

The flow is: app asks the server for an authorize URL → app opens it in a browser → Google
redirects to the *server's* callback → server exchanges the code and stores the token → app
polls `GET /api/mail/status` until it flips to connected.

The redirect never has to reach the app at all. That removes custom URL schemes, intent
filters, and the entire class of "the callback didn't come back" bugs. **Use `url_launcher`
plus status polling.** `flutter_web_auth_2` is the right tool when the *client* completes the
exchange; here it solves a problem we don't have.

This is the single biggest reduction in client-side risk found.

---

## 3. AWS: single EC2, confirmed against current prices

`t4g.small` on-demand in `us-east-1` is **$0.0168/hr = $12.26/month** (verified 2026-09-11),
matching the plan's estimate.

| Component | Choice | Monthly | 2 months |
|---|---|---|---|
| Compute | 1x `t4g.small` (ARM, 2 vCPU, 2 GB) | $12.26 | $24.52 |
| Storage | 20 GB gp3 EBS | ~$1.60 | ~$3.20 |
| Elastic IP | free while attached | $0 | $0 |
| TLS + routing | Caddy on-box, auto Let's Encrypt | $0 | $0 |
| Data transfer | negligible at <10 users | ~$0 | ~$0 |
| **AWS subtotal** | | | **~$28** |
| Domain | one year, cheap registrar | — | ~$12 one-off |
| **Total** | | | **~$40 of $70** |

Headroom is roughly $30 — enough to absorb a mistake, or to size up to `t4g.medium` if OCR
proves memory-hungry. **Do not use `t4g.micro`**: 1 GB will not hold tesseract plus the Python
dependency tree.

FCM is free. Cloud Pub/Sub would sit inside its free tier. Fewer than ten held-open IMAP
sockets are free. **Engineering time, not money, is the binding constraint on this project.**

**Rejected, one line each.** *Lambda + API Gateway*: ephemeral filesystem breaks per-user SQLite
(`brain/store.py:78`) and three token caches, the 15-minute cap breaks ingest, and API Gateway
cannot carry the SSE at `/api/mail/reload/stream`. *ECS Fargate*: same filesystem problem, needs
EFS to fix it, more moving parts for no gain. *ALB*: ~$16/month — a quarter of the budget — to
route for ten users, where Caddy does it for nothing. *RDS*: SQLite is already correct at this
scale.

---

## 4. Scope and effort

Confirmed at source: `/api/mail_tree` returns the entire nested tree **including thread bodies**
(`brain/viz_server.py:84`) with no pagination. One cached payload therefore renders the whole
tree *and* every thread detail offline, with no detail-level cache to invalidate.

| Surface | Tier | Estimate |
|---|---|---|
| Login + JWT + secure storage | 1 | 1 d |
| Local persistence layer (offline-first) | 1 | 2–3 d |
| "Today" feed: urgent + action items | 1 | 2 d |
| Thread detail | 1 | 1 d |
| Tree browse (nested lists, offline) | 1 | 2 d |
| Gmail connect + reconnect UX | 1 | 1–2 d |
| Ingest trigger + SSE progress | 1 | 2 d |
| Notifications (FCM + server watcher) | 2 | 3–4 d |
| Mail Q&A chat | 2 | 2 d |
| Review queue + reclassify | 2 | 2 d |
| Analytics / rules / profile / calendar | 3 | 1–2 d each |
| **D3 mindmap** | **don't build** | — |

**Tier 1 ≈ 2 weeks. Tiers 1–2 ≈ 3–4 weeks**, plus the 2–3 days of backend OAuth rework that
must land first. This matches the approved plan.

**Persistence:** `sqflite` with hand-written mappers, or simply store the tree payload as JSON.
The dataset is tens of threads; Drift's codegen is not worth its setup cost here.

---

## 5. Build order

1. **OAuth rewrite** (2–3 d, backend). Redirect flow for Gmail and Calendar, tokens off
   `~/.hermes/` into the per-user store, all three linkings unified. Nothing hosted works until
   this lands. **Currently unassigned.**
2. **Deploy** (1 d). EC2, Caddy, two systemd units, domain, tesseract. Point the existing React
   console at it and confirm it works *before* writing any Dart — the cheapest possible test of
   the host.
3. **Flutter Tier 1** (2 w), offline-first from the first screen. Retrofitting local-first onto
   a network-first app is a rewrite; building it in from the start is nearly free.
4. **Tier 2** (1–1.5 w), notifications last — most likely to overrun.

---

## 6. Risks, ranked

1. **Weekly re-consent (§1).** Certain, recurring, unfixable. Mitigate with UX and a pre-demo
   reconnect ritual. Ranked first because it presents as a bug.
2. **The OAuth rewrite is unassigned.** It gates everything and nobody owns it. Assign it first.
3. **Free-tier OpenRouter is the real throughput ceiling on ingest**, not AWS. LLM-free ingest
   (`offline_mode`) sidesteps it while keeping deterministic urgency and action-item extraction
   working — a sensible default for a demo.
4. **Notifications may overrun.** FCM plus a server-side watcher is the least-known territory
   here. It is Tier 2 for that reason; cut it before cutting anything in Tier 1.
5. **Empty feeds on pre-existing data.** `urgent`/`action_items` are computed at ingest, so
   threads predating the feature return nothing until a re-sync. Not a bug — do not debug it.
6. **Slack has never run against real Slack** — wired and unit-tested only, and needs
   `channels:history`. Do not demo it untested.
7. **Shared worktree.** Two sessions on `dev`; stage explicitly, never `git add -A`.

---

## Sources

- [EC2 t4g.small pricing](https://instances.vantage.sh/aws/ec2/t4g.small) ·
  [AWS on-demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/)
- [Google OAuth refresh token 7-day limit](https://www.unipile.com/google-oauth-refresh-token/) ·
  [OAuth 2.0 policies](https://developers.google.com/identity/protocols/oauth2/policies) ·
  [Manage app audience / user cap](https://support.google.com/cloud/answer/15549945?hl=en)
- [flutter_web_auth_2](https://pub.dev/packages/flutter_web_auth_2)
