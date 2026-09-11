# Research task: Flutter Android client + AWS deployment for Agent OS

You are researching, not implementing. Produce a written plan; change no code.

## The situation

This repo is Agent OS: a personal knowledge-graph "brain" over a user's Gmail, plus a chat
console. Read `CURRENT_STATE.md` FIRST — it is the source of truth and explicitly supersedes
`README.md`, `system-overview.md`, and `agent-os-clean-room-architecture.md`, which describe an
original Fathom→Hermes→ClickUp pitch that was never built. Then read `SETUP.md`,
`brain/viz_server.py`, `console/backend/main.py`, `console/frontend/src/api.ts`, and
`console/frontend/src/lib/brainApi.ts`.

Today it runs as three local processes per developer: `brain` (FastAPI :8080),
`console/backend` (FastAPI :8000), `console/frontend` (React+Vite :5173). Both backends
independently verify the same HS256 JWT signed with a shared `OPS_SECRET_KEY`.

**Note on recent history:** commit `ab79bdb` removed the résumé/hiring surface. Gone:
`brain/ask.py`, `brain/ingest.py`, `brain/act.py`, `brain/query.py`, `console/backend/resume.py`,
`console/backend/onboarding.py`, `console/backend/rbac.py`, `clickup/`, `tools/fathom/`,
`slack/bot.py`, and the brain routes `/api/data`, `/api/ask`, `/api/ingest_resume`. No frontend
page was removed. Two traps that have already caught one reader: `pages/Applications.tsx` is the
**Integrations** page (connect cards, offline toggle, automation rules), *not* onboarding; and
the console chat router carries a **`/chat` prefix**, so it is `/chat/sessions`, not
`/sessions`. Re-derive every route from source with grep and trust no inventory you are handed,
this prompt included.

Auth is unchanged and you should build against it: HS256 JWT from `/auth/login`, shared
`OPS_SECRET_KEY`, brain independently decoding the same token (`brain/auth.py`) rather than
calling console. Roles now collapse to "admin can create accounts, everyone else can't".

## The goal

A **Flutter Android app**, distributed as a **`.apk`** (no Play Store listing), talking to this
same backend **hosted on AWS**.

Hard constraints:
- **Fewer than 10 users.** Demo / college project, not a product.
- **~$70 total AWS budget**, for **1–2 months** of uptime. Do not exceed it.
- Google OAuth consent screen stays in **Testing** status. Restricted-scope verification and
  CASA are out of scope — do not plan for them.
- The React console stays; Flutter is an additional client, not a replacement.

## What to investigate

**0. Three requirements the user stated directly. These are settled; design to them.**
- **The knowledge map must be browsable with no network.** On-device persistence is a Tier 1
  feature, not a cache. `GET /api/mail_tree` returns the whole tree in one small response, so
  this is tractable: persist it plus both feeds locally, render every read-only screen from
  local storage, and make the network a background refresh. Work out which screens must degrade
  (Q&A, ingest, OAuth, reclassify) and how they should *look* when degraded. Assess queue-and-
  replay for reclassify. **Do not confuse this with the repo's `offline_mode` flag**, which only
  means "don't call OpenRouter".
- **Live new-mail detection, not polling, if feasible.** Evaluate Gmail API `users.watch` +
  Cloud Pub/Sub versus server-side **IMAP IDLE** versus timed polling. Note that stdlib
  `imaplib` has no IDLE on Python 3.11 (`.python-version`), so IDLE means an `imapclient`
  dependency; that the existing path is IMAP + XOAUTH2 (`brain/emailtool.py:_connect`), so
  Pub/Sub would add a parallel Gmail REST surface; and that `cmd_list(since_minutes)` already
  does `UNSEEN SINCE` polling for free. Then solve the separate server→phone hop: FCM works
  with a sideloaded APK and is the only option that wakes a closed app. Recommend a build order.
- **OAuth shape is free to change, as are the Slack and Calendar linkings.** You are not
  constrained to preserve current signatures. Design the whole integration surface coherently.

**1. The OAuth rewrite (treat as the critical path).**
`brain/emailtool.py:_load_oauth_credentials` and `brain/calendar_tool.py:connect` use
`InstalledAppFlow.run_local_server(port=0)`, and `POST /api/mail/connect` calls it inside the
request handler. Confirm this cannot work headless on EC2, then design the replacement
three-legged web flow: authorize-URL endpoint, hosted callback, `state` handling and CSRF,
which Google Cloud OAuth client type is required, and exactly which existing functions change
vs. stay. Determine what the Flutter side needs (`flutter_web_auth_2` vs `url_launcher` +
deep link, and the `AndroidManifest.xml` intent filter). Also establish the real behaviour of
refresh-token expiry while the consent screen is in Testing, and recommend whether to publish
to Production and accept the unverified-app warning.

**2. AWS topology and a real cost table.**
Evaluate single EC2 vs ECS Fargate vs Lambda+API Gateway against these specific constraints:
per-user SQLite files on local disk (`brain/store.py`, `BRAIN_DATA_DIR`), three local token
caches (`~/.hermes/mail/<user_id>/token.json`, `~/.hermes/calendar/<user_id>/token.json`, and
the org-wide `~/.hermes/console-integrations.json`), minutes-long SSE ingest, and a `tesseract`
binary dependency.
Produce an itemised monthly cost table with current on-demand prices and a 2-month total.
State plainly which option you recommend and why the others lose. Cover: instance type and
size (justify the RAM), how the two FastAPI processes are supervised, how one origin is
presented to the app, TLS certificate acquisition, and whether `console/deploy/` is worth
reusing given it does not containerise `brain`.

**3. HTTPS and Android networking.** Android 9+ cleartext blocking, what a bare EC2 public IP
can and cannot get a certificate for, domain vs. `network_security_config.xml` exemption, and
how that choice interacts with the OAuth `redirect_uri`.

**4. Flutter scope.** Inventory every screen and capability in `console/frontend/src/pages`
and `console/frontend/src/components`, map each to the endpoints it calls, and propose a
tiered cut (must-have / high-value / optional) with a per-surface effort estimate. Give the
`MailMindmap.tsx` D3 tree particular attention — assess `graphview` vs `CustomPainter` vs
replacing it with nested lists, and say whether it earns its cost on a phone screen.

The scope decision has already been made by two independent readings and you should **start from
it, then try to break it**: the app is a **"Today" action inbox** — urgent threads plus open
action items, cross-channel — and *not* a port of the console. Supporting evidence: `is_urgent()`
(`brain/mail_ingest.py:218`) and `extract_action_items()` (`:236`) are deterministic (keyword
and regex, no LLM), stored at ingest (`:1135`), surfaced cross-channel by `/api/needs-attention`
and `/api/action-items`, and therefore free to poll. The mail tree is a browsing tool and
browsing is better on a laptop. Say plainly whether you agree and what would change your mind.

Two corrections to carry, both from the engineer who owns this code:
- **Offline mode does not mean "works without a network."** It means "don't call OpenRouter":
  IMAP still runs, `classify_email` falls back to keyword scoring, summary synthesis falls back
  to BM25 + raw text, calendar extraction is skipped. Do not model Flutter caching on it — the
  app needs ordinary local persistence of the last feed/tree responses, which is entirely
  client-side. Do assess whether offline mode should be the *default* for a demo on a free quota.
- **The domain is channel-agnostic by design.** `_ingest_message` takes any
  `{uid, from, subject, body_text, attachments}` plus a `channel` tag; Gmail and Slack are
  adapters and thread merging has no channel filter. Model "a thread that may span channels",
  not "an email", and don't hardcode two sources.

Also determine what notification polling needs. Both feed endpoints currently scan every thread
and return the full set; entities carry ISO-8601 UTC `created_at`/`updated_at`
(`brain/store.py`), so assess a `since` parameter versus client-side diffing and recommend one.

**5. Flutter implementation specifics.** Recommend and justify: state management, HTTP client,
JWT storage (`flutter_secure_storage`), **consuming the `/api/mail/reload/stream` SSE endpoint
in Dart** (check the event shape in `brainApi.ts:reloadMailStream`), the **offline persistence
layer** (Drift vs sqflite vs plain JSON files — the dataset is tens of threads, so justify any
complexity), whether to generate Dart models from an OpenAPI spec off FastAPI's
`/openapi.json`, FCM setup for a sideloaded APK, and WorkManager for background refresh. Pin
package choices to versions and verify each is currently maintained.

**6. Ingest ergonomics on mobile.** Trace `brain/mail_ingest.py` and decide whether the phone
should hold an SSE connection for a multi-minute ingest or whether this becomes a background
job with polling. Note the free-tier OpenRouter rate limits as the actual throughput ceiling.

**7. Risks.** Anything that could sink this in week 3. Be specific and ranked.

## Rules

- Verify every claim about this codebase against the source, with `file:line` citations.
- Use web search for anything time-sensitive: AWS pricing, Google OAuth policy, Flutter
  package health. State the date of what you find.
- Where you are uncertain, say so explicitly rather than hedging in prose.
- Give **one** recommendation per decision, not a survey of options. Include what you rejected
  and why, in one line each.

## Deliverable

A single markdown document containing: a go / no-go verdict with reasoning; the AWS cost table
and topology recommendation; the OAuth rewrite design; the tiered Flutter scope with effort
estimates; a phased build order with rough durations; and a ranked risk list. Written so
someone can start building from it on day one.
