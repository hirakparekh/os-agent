# HANDOFF — read this first

You are picking up **Agent OS** on a Linux machine with a full toolchain (Flutter, Gradle,
Android SDK, Node, Python). The previous work happened on Windows **without** the Flutter SDK,
which is the single most important fact in this document: **the Android app has never been
compiled.**

This file is the complete state of the project — what works, what has never run, what is
deliberately absent, and what to do next. It is long on purpose. Prefer it over
`README.md`, `system-overview.md`, and `agent-os-clean-room-architecture.md`, which describe an
original pitch (Fathom → Hermes → ClickUp) that was never built and has since been deleted.

`CURRENT_STATE.md` is accurate and complementary — it covers the backend in more depth.
`docs/app/` holds the Android app's decision records with reasoning.

**Position as of this writing:** branch `dev` at `67f0e33`, **25 commits ahead of `main`**,
working tree clean.

---

## 1. What this project is

Each user connects their own Gmail. A local FastAPI service ingests that mail over IMAP,
classifies every thread into a category → topic tree, extracts deadlines and to-dos, and
answers natural-language questions over the result. Slack messages flow into the *same* tree.
There is a React web console and, new and unverified, an Android app.

Three processes:

| Process | Port | What it is |
|---|---|---|
| `brain` (`brain/viz_server.py`) | 8080 | Mail/Slack ingest, classification, the knowledge tree, Q&A, OAuth. 33 routes. |
| `console/backend` | 8000 | Accounts, JWT, chat session persistence, voice proxy. Routers: health, auth, chat, applications, voice. |
| `console/frontend` | 5173 | React + Vite. Pages: Home, Chat, Analytics, Applications (= Integrations), Profile, Login. |

Both backends independently verify the **same HS256 JWT** signed with a shared
`OPS_SECRET_KEY`. One login authenticates both; `brain` never calls `console` to validate a
token. This is why both `.env` values must match, and it is what lets the Android app hold a
single token.

---

## 2. What is built and genuinely working

All of this is committed, tested, and has been exercised against real services.

**Mail pipeline.** IMAP fetch (windowed, unread/recent) → attachment parsing → classification →
merge/place → store. Per-user SQLite at `brain/data/users/<id>/brain.db`.

**Classification.** A hand-built vocabulary scorer, deliberately *not* BM25 — BM25's length
normalisation actively penalised categories with richer keyword lists, so adding synonyms to a
category could make it lose. The scorer counts keyword presence per zone (subject ×3, body ×1,
negative keywords veto) and only overrides the model's own guess when confidently ahead.
`brain/bm25.py` survives and is used correctly, for ranking threads against a question.

**Learning from corrections.** Reclassifying a thread teaches the scorer per-user, so the same
mistake does not repeat.

**Attachments.** Excel/CSV/PDF/DOCX parsed locally; images via Tesseract OCR, falling back to a
vision model only when Tesseract is absent. Findings are treated as authoritative over a
thread's prose summary.

**Urgency and action items.** Deterministic keyword and regex passes — **no model call**, so
they are exact, free, and keep working with AI processing switched off. Surfaced by
`/api/needs-attention` and `/api/action-items`, both cross-channel.

**Duplicate suppression.** Near-identical body text (difflib ≥ 0.85) collapses into the existing
thread rather than creating a second one.

**Slack ingestion.** Messages adapt into the same `{uid, from, subject, body_text, attachments}`
shape and ingest with `channel="slack"`. Thread merging has no channel filter, so the same
announcement arriving by both email and Slack becomes one node. **See §4 — this has never run
against real Slack.**

**Mail timeline.** Each thread records `received_at` (each source message's own Date header,
keyed by uid, no model) and `events` (deadlines and dates the existing merge/place call already
extracts). Dates are thread *attributes*, never a tree level — the console's "By time" view
regroups the same nodes client-side. Threads predating this fall back to `created_at`, marked
approximate.

**Chat / Q&A.** Sessions persist in the console DB; the question is proxied to brain's
`/api/mail/ask` with the same bearer token. The prompt carries today's date, the user's real
Google Calendar events, and a DATED ITEMS block from the timeline.

**Voice.** Sarvam AI speech-to-text and text-to-speech through `console/backend/voice.py`.

**Analytics**, **automation rules** (plain English, parsed once by a model then evaluated in
pure code forever after), **knowledge tree export** to Markdown, **review queue** for
low-confidence filings.

**Google OAuth — redirect flow.** This is recent and important. It used to call
`InstalledAppFlow.run_local_server`, which opened a consent window *on the server* and blocked
until someone clicked it — which only worked because the server was somebody's laptop. It was
the single thing making this project impossible to host. Now: `POST /api/{mail,calendar}/connect`
returns a Google URL, the user's own browser consents, Google redirects to
`GET /api/oauth/callback`, the server exchanges the code, and the client polls status. `state`
is a short-lived JWT signed with `OPS_SECRET_KEY` carrying `(user_id, service)` — there is no
pending-state table, so it is correct under multiple workers, and a forged callback is useless.

### Verified state of the test suites

| Gate | Result |
|---|---|
| `uv run pytest` | **252 passed** |
| Playwright e2e | **26 passed** (6 spec files, real stack) |
| `npm run build` (tsc + vite) | clean |
| `uv run mypy` | clean, strict |
| `uv run lint-imports` | 2 of 2 contracts kept |
| `uv run ruff check .` | **11 errors** — pre-existing, see §5 |
| `uv run ruff format --check .` | **10 files** unformatted — pre-existing, see §5 |

---

## 3. The Android app — written, never compiled

`app/` holds ~4,500 lines across 18 Dart files. **Nothing has been built or run.** There is no
`android/` directory, no Gradle, and `flutter analyze` has never executed. This is your first
job and §7 walks it through.

**What it is:** a *"Today" action inbox* — urgent threads and open to-dos, Gmail and Slack in
one list — with the knowledge tree behind it. Deliberately not a port of the web console:
browsing is better on a laptop; a phone is for the thing you would otherwise miss.

| Surface | File |
|---|---|
| Backend config (two base URLs, or one hosted origin) | `lib/config.dart` |
| Models | `lib/models.dart` |
| API client, including the sync stream | `lib/api.dart` |
| Offline cache (JSON files, atomic writes) | `lib/cache.dart` |
| App state, offline-first | `lib/app_state.dart` |
| Sign in | `lib/screens/login.dart` |
| Shell, status strip, Gmail connect | `lib/screens/home.dart` |
| Today feed | `lib/screens/today.dart` |
| Knowledge tree (nested lists) | `lib/screens/tree.dart` |
| Thread detail with dates | `lib/screens/thread.dart` |
| Chat, with voice | `lib/screens/chat.dart`, `lib/voice.dart` |
| Review queue + reclassify | `lib/screens/review.dart` |
| Insights | `lib/screens/insights.dart` |
| Automation rules | `lib/screens/rules.dart` |
| Settings and connections | `lib/screens/settings.dart` |
| Urgent-mail notifications (polling) | `lib/notifications.dart` |

**Architecture:** five layers, each depending only on the one below — `screens/` → `app_state`
→ `api`/`cache` → `models`. `provider` with a single `ChangeNotifier`. No router: the OAuth
redirect is completed by the *server*, so nothing ever needs to route into a cold app at a
specific screen. Full reasoning in `docs/app/0001-architecture.md`.

**Offline-first is structural, not a cache.** Every read-only screen renders from disk first and
treats the network as a background refresh. A failed refresh keeps the last good data on screen
with a "synced N ago" marker rather than showing an error. `GET /api/mail_tree` returns thread
bodies inline with no pagination, so one cached payload covers the whole tree *and* every thread
detail offline — there is no per-thread endpoint and none is needed.

### Backend shapes that already caused silent failures

Read `docs/app/0004-api-contract-traps.md` before touching `api.dart`. The two worst:

1. **`POST /api/mail/reload/stream` is NDJSON, not server-sent events.** It sets
   `application/x-ndjson` and writes one bare JSON object per line, with **no `data:` prefix**.
   An SSE parser matches nothing and produces a sync that appears to hang forever with no error.
2. **`done` in those events is a count, not a boolean.** `{"stage":"ingesting","done":3,"total":10}`.
   Modelling it as `bool` is a runtime type error partway through a sync. Detect the end with
   `stage == 'done' || stage == 'failed'`.

Both were written the wrong way first and caught by reading the server source.

---

## 4. Built but never proven — do not demo these untested

This distinction matters more than feature count.

1. **Slack ingestion.** Fully wired, unit-tested with a stand-in, but no bot token is configured
   and the `channels:history` scope has never been granted. The real call to Slack has never
   executed.
2. **Automation rule delivery.** Rule creation and matching are tested. A rule has never actually
   posted to Slack, because that path shares Slack's setup.
3. **Calendar auto-add from mail.** Writing events works and reading works, but the full chain —
   an email arrives, an event appears — has not been observed on real mail, because no recent
   message contained a detectable dated event.
4. **The entire Android app.** Never compiled. See §3 and §7.

---

## 5. Known rough edges, none of them mysteries

**Ruff is red, and it is not from recent work.** 11 errors (9 line-too-long, 3 `datetime.UTC`
alias, 1 deprecated import) and 10 unformatted files. `brain/engine.py` fails the formatter *as
it exists on `main`*, untouched by any of this. `uv.lock` pins ruff `0.15.16` exactly, so CI runs
the same version — this is a formatter upgrade landing newer rules on older code that nobody
re-ran the formatter over.

CI triggers on `push: branches: [main]` and on `pull_request`, so **pushing `dev` does not run
CI**; the red only appears when a PR is opened. If you want it green, `uv run ruff format . &&
uv run ruff check --fix .` fixes it in under a minute — but do it as **its own commit on its own
branch**, because reformatting files nobody touched buries real changes under a mechanical diff.

**The Mail page promises an automatic sync it does not perform.** `Home.tsx` displays
*"Automatic sync every 4 hours."* There is **no scheduler anywhere in the application**.
`scripts/mail_cron.ps1` exists but must be registered manually as a Windows task, and the setup
docs never explain how. Mail syncs when the button is pressed. Either build the scheduler or
delete the label; leaving it is a promise the software does not keep.

**Empty Today / needs-attention panels are correct, not broken.** Urgency and action items are
computed *during ingest*, so threads ingested before those features existed carry neither until
the next sync. Do not debug this.

**`clickup/` still exists** but nothing references it — the résumé/hiring removal took its
consumers. It is dead weight, safe to delete, and nobody has.

---

## 6. The weekly Gmail reconnect — a permanent constraint, not a bug

This project requests `https://mail.google.com/` — full Gmail access, which IMAP requires, and a
**restricted** scope. The app is unverified, and **Google expires refresh tokens for unverified
apps after 7 days.**

Publishing to Production does **not** lift this. The expiry attaches to the app being
*unverified*, not to the Testing publish status. Clearing it on a restricted scope requires full
Google verification including a third-party security assessment: weeks of calendar time and a
four-figure floor. Categorically out of scope for a two-month project.

So: roughly **eight reconnections per user over the project's life**, by design, forever.

The code already handles this properly. `ReconnectRequired` separates "the grant expired, ask
the user" from a genuine fault; `mailbox_status` returns `needs_reconnect`; `connected_at` is
recorded so the UI can warn *before* expiry; and `prompt=consent` is sent on every authorization
because Google only reliably returns a refresh token when it re-prompts. The Android app renders
this as a tertiary-coloured **Connect** action, never a red error.

**Operationally: reconnect deliberately before any demo.** An expired grant looks exactly like
an empty inbox, with no error anywhere to explain it. This is the single most likely way this
project embarrasses someone.

---

## 7. Your first job: compile the Android app

Nothing else in this document is blocked on anything. This is.

```bash
cd app

# flutter create writes android/ and Gradle — but it also OVERWRITES lib/main.dart and
# pubspec.yaml. The tree is committed, so anything it clobbers is recoverable.
flutter create --platforms=android --project-name agent_os .

# restore the hand-written source that flutter create just overwrote
git checkout -- lib pubspec.yaml

flutter pub get
flutter analyze
```

**Expect `flutter analyze` to find real problems.** Every API shape was verified against the
server source, but reading source is a weaker guarantee than running it. The highest-risk file
is `lib/voice.dart` — the only one touching device hardware, with two native plugins (`record`,
`audioplayers`) and platform channels. If it fights back, deleting `voice.dart`, its two
packages, and the voice wiring in `chat.dart` leaves the app fully working minus speech.

Then add to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<!-- voice: hold-to-speak in chat -->
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<!-- Android 13+ asks at runtime before showing any notification -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<application
    android:usesCleartextTraffic="true"
    ... >
```

`usesCleartextTraffic` is **local development only** — the dev backends have no TLS. Remove it
once the backend is hosted behind HTTPS. Nothing else is needed: there is no custom URL scheme
and no intent filter anywhere in this project, because Google's consent redirect goes to the
*server's* callback, never back into the app.

Run it:

```bash
# start all three backends first — see SETUP.md §5
flutter run
```

The app defaults to `http://10.0.2.2:8000` / `:8080`, which is how the Android emulator reaches
the host's localhost. On a physical device use **Server settings** on the sign-in screen and
enter the machine's LAN address, or a hosted origin. Sign in with `OPS_ADMIN_EMAIL` /
`OPS_ADMIN_PASSWORD` from the repo-root `.env`.

Release build:

```bash
flutter build apk --release
# build/app/outputs/flutter-apk/app-release.apk
```

---

## 8. AWS deployment — decided, not built

**No infrastructure exists.** No Terraform, no instance, no domain, no Caddyfile, no systemd
units. What exists is a decision and a costing.

**The shape:** one `t4g.small` EC2 (ARM, 2 vCPU, 2 GB) + 20 GB gp3 EBS + Caddy for automatic
TLS + a hostname. **≈ $28 for two months**, against a $70 budget.

**Why not serverless**, since it will come up again: per-user SQLite lives on local disk
(`brain/store.py`) and so do three token caches (`~/.hermes/mail/<id>/token.json`,
`~/.hermes/calendar/<id>/token.json`, `~/.hermes/console-integrations.json`) — an ephemeral
filesystem breaks all four. Ingest runs for minutes, past Lambda's 15-minute cap. API Gateway
cannot carry the NDJSON sync stream. And an ALB alone is ~$16/month — a quarter of the budget —
to route for fewer than ten users, where Caddy does it for nothing.

**Use `t4g.small`, not `t4g.micro`.** 1 GB will not hold Tesseract plus the Python dependency
tree.

### What has to be built

- a `Dockerfile` for `brain` — **nothing deploys brain today**, and it is the entire product
- a fix for `console/deploy/Dockerfile.backend`, which is **currently broken**: it runs
  `COPY tools ./tools` and `COPY skills ./skills`, and both directories were deleted
- a `Caddyfile` routing `/api/*` → 8080 and everything else → 8000, so the app has one origin
- two systemd units, or a compose file that actually includes brain
- a bootstrap script: Ubuntu → uv, Node, `tesseract-ocr`, the services, Caddy

`console/deploy/docker-compose.yml` is also stale — it still wires Postgres and
`CLICKUP_TOKEN`/`FATHOM_API_KEY`, none of which exist in `Settings` any more.

### The hostname — resolved decision, not yet created

**Do not use a `*.vercel.app` hostname.** This was tried. `agentos.exec-adidev.vercel.app`
resolves to `216.198.79.131 / 64.29.17.131` — Vercel's edge — because Vercel publishes a
wildcard for its own zone. You cannot point it at an EC2 instance; every request goes to Vercel,
so Google's redirect would 404 on the portfolio project and the code exchange would never
happen, with nothing in your server logs because the request never arrives.

**The decision is DuckDNS** — free, no purchase, and you control the A record. Register
something like `agentos-adidev.duckdns.org`, point it at the EC2 Elastic IP. Let's Encrypt
issues for DuckDNS normally, so Caddy's automatic TLS works and Android gets the HTTPS it
requires.

### Google OAuth changes for hosting

The existing client is **Desktop** type, which only accepts loopback redirects. Hosting needs a
**Web application** client in the same Google Cloud project:

- **Authorized redirect URI**, verbatim — exact scheme, host, path, no wildcard, no trailing
  slash:
  ```
  https://<your-duckdns-host>/api/oauth/callback
  ```
  That path is fixed in code: `redirect_uri()` is `OAUTH_REDIRECT_BASE_URL + "/api/oauth/callback"`
  (`brain/oauth_flow.py:88`). A mismatch fails with `redirect_uri_mismatch` *before* the consent
  screen renders.
- Add `http://localhost:8080/api/oauth/callback` as a second redirect URI on the same client —
  Google permits localhost on Web clients, so one client covers local dev and the server.
- Download the JSON to `~/.hermes/mail/credentials.json` (or set `GMAIL_CREDENTIALS_PATH`).
  Calendar reuses the same file by default.
- Set `OAUTH_REDIRECT_BASE_URL=https://<your-duckdns-host>` in `.env`.

**None of this costs money.** OAuth client IDs, the consent screen, and the Calendar API are
free with no billing account. Gmail is reached over IMAP with XOAUTH2, which is not a metered
API. Ignore prompts to enable billing.

**One consequence:** refresh tokens are bound to the client that issued them. Moving from the
Desktop client to the Web client means everyone re-consents once. Given the weekly reconnect in
§6, that is noise.

---

## 9. Git — the exact commands

The remote is `origin` → `https://github.com/CodinGakpo/Autonomous-Personal-Intelligence.git`.
`dev` is the integration branch; `main` is the stable one. **`dev` is currently 25 commits ahead
of `main`.**

Interactive git (`rebase -i`, `add -i`) is not available in this environment.

### Get current

```bash
git fetch origin
git switch dev
git pull --ff-only origin dev
```

`--ff-only` is deliberate: if it refuses, someone else has pushed and you want to know that
explicitly rather than get a surprise merge commit.

### Pull main into dev

Usually a no-op right now, since `main` is fully contained in `dev`. Check before doing
anything:

```bash
git merge-base --is-ancestor origin/main dev && echo "main already in dev — nothing to pull"
```

If that prints nothing, `main` has moved and you do need to merge:

```bash
git switch dev
git merge origin/main
# resolve conflicts, then:
git add -A
git commit            # git writes the merge message; edit it to say what you decided
```

### Normal work: commit and push to dev

```bash
git switch dev
git pull --ff-only origin dev

# stage explicitly — never `git add -A` blind, two agents have shared this worktree before
git add <paths>
git status                      # read it before committing
git commit -m "feat: ..."

git push origin dev
```

**Do not add Claude or Anthropic attribution to commit messages in this project.**

### Merge dev into main when it is ready

Verify first — merging into `main` is what triggers CI:

```bash
uv run pytest -q
cd console/frontend && npm run build && npm run test:e2e && cd ../..
uv run mypy && uv run lint-imports
```

Then:

```bash
git switch main
git pull --ff-only origin main
git merge --no-ff dev -m "Merge dev into main: <what this release contains>"
git push origin main
git switch dev                  # go back, so later work does not land on main by accident
```

`--no-ff` keeps the integration point visible in history rather than flattening 25 commits into
a straight line.

### If a merge goes badly

Never run a risky merge directly on a shared branch. Trial it:

```bash
git switch -c merge/trial dev
git merge origin/<their-branch>
# if it goes wrong:
git merge --abort
git switch dev && git branch -D merge/trial
```

Nothing is lost and `dev` was never touched. When the trial is green, fast-forward the real
branch onto it:

```bash
git switch dev
git merge --ff-only merge/trial
git branch -d merge/trial
```

### Merge-conflict guidance specific to this repo

A previous merge produced 21 conflicts; these patterns recur.

- **Modify/delete conflicts are common and usually resolve to "keep the deletion."** A large
  hiring/résumé surface was removed (`brain/{act,ask,ingest,query}.py`,
  `console/backend/{onboarding,resume}.py`, `tools/resume/`, `skills/`, `slack/bot.py`). Branches
  cut before that removal still carry edits to those files. Check whether the incoming edit is
  substantive before discarding — last time all ten were pure `ruff format` reflows, so nothing
  was lost.
- **A clean merge is not a working app.** Git resolves text; it does not know that a merged
  component calls a function that was deleted. After *every* merge run `npm run build` (the
  typecheck is what catches dangling references) and `uv run pytest`. Last time three things
  merged cleanly and still broke.
- **Prefer `dev` for `api.ts` / `brainApi.ts`.** They track backend endpoints that have changed
  underneath older branches.
- **Never hand-merge `package-lock.json`.** Resolve `package.json` by hand, then
  `rm package-lock.json && npm install`.

---

## 10. Running everything locally

`SETUP.md` is authoritative and current. The short version:

```bash
# system: python 3.11+, uv, node 20+, tesseract-ocr
sudo apt-get update && sudo apt-get install -y tesseract-ocr

uv sync
cd console/frontend && npm install && cd ../..

cp .env.example .env     # then fill OPENROUTER_API_KEYS, OPS_SECRET_KEY, admin email/password
```

The frontend needs its own file or it silently runs in a demo mode that blocks real login with
no visible error:

```bash
cat > console/frontend/.env.local <<'EOF'
VITE_API_BASE_URL=http://localhost:8000
VITE_BRAIN_API_BASE_URL=http://localhost:8080
EOF
```

Three terminals — all must stay running:

```bash
uv run uvicorn brain.viz_server:app --port 8080
uv run uvicorn console.backend.main:app --port 8000
cd console/frontend && npm run dev
```

**Do not use `--reload`.** It has repeatedly failed to pick up changes to
`brain/viz_server.py` — new routes keep 404ing after edits even with the watcher apparently
active. Stop and restart plainly instead.

Check:

```bash
curl http://localhost:8080/            # {"service":"brain","status":"ok"}
curl http://localhost:8000/health      # JSON integrations status
```

---

## 11. What needs a human, not an agent

These cannot be done from code and are worth surfacing early rather than discovering blocked:

1. **Create the DuckDNS hostname** and point it at the EC2 Elastic IP (§8).
2. **Create the Web-type Google OAuth client** with the exact redirect URI (§8).
3. **Provision the EC2 instance.** AWS credentials are already in `.env`, so this is a go/no-go
   rather than a setup task.
4. **Grant Slack `channels:history`** and add a bot token, to turn two finished-but-unproven
   features into working ones (§4).

---

## 12. Suggested order of work

1. **Compile the Android app** (§7). Everything about it is unknown until `flutter analyze`
   runs, and that unknown is the largest in the project.
2. **Build the deploy layer** (§8) — Dockerfile for brain, fixed console Dockerfile, Caddyfile,
   systemd units, bootstrap script. All of it is local work needing no AWS spend.
3. **Deploy, and point the existing React console at it** before touching the app. It is the
   cheapest possible proof that hosting is sound.
4. **Point the Android app at the hosted origin** and test the OAuth flow end to end on a real
   device. This is the first time the redirect flow will run against a real domain.
5. Optional cleanups: the stale "every 4 hours" label, the ruff baseline, deleting `clickup/`.
