# Agent OS — Current State (2026-09-11)

> **Why this file exists:** `README.md`, `system-overview.md`, and
> `agent-os-clean-room-architecture.md` describe the *original* pitch (Fathom → Hermes →
> ClickUp co-pilot loop). That loop was never built. What actually got built instead is a
> **personal knowledge-graph brain with a Gmail mail pipeline and a chat console** — this doc
> describes *that*, as it exists in the repo today, not the original vision. Treat this as the
> source of truth for "what actually works right now"; treat the other docs as historical
> context / possible future direction.

---

## One sentence

Each user connects their own Gmail; a local FastAPI service (`brain`) ingests mail into a
per-user SQLite entity graph, classifies threads into categories/topics, and answers natural-
language questions over that graph (and separately over ingested résumés/meetings) via a free
OpenRouter LLM — all fronted by a React console with its own login/session layer.

---

## Processes (three, all local)

| Process | Port | Framework | Purpose |
|---|---|---|---|
| `brain` (`brain/viz_server.py`) | 8080 | FastAPI | mail ingest, classification, entity graph, LLM Q&A |
| `console/backend` | 8000 | FastAPI | user accounts, JWT auth, chat sessions, onboarding/roster |
| `console/frontend` | 5173 | React + Vite | the UI (login, chat, mail mindmap, profile) |

Started per `SETUP.md`; no Docker/Postgres required for local dev (SQLite everywhere,
Postgres is compose-only and not currently wired up).

Auth is shared, not proxied: **console/backend** issues JWTs (HS256, `OPS_SECRET_KEY`) on
login and is the only place able to *create* accounts (admin-only `POST /auth/users`, no
self-registration). **brain** independently decodes the same JWT (`brain/auth.py:
get_current_user_id`) — it never calls console/backend to validate a token, it just needs the
same secret. This is why both `.env` files must share `OPS_SECRET_KEY`, and why two people
running their own separate stacks each get their own independent admin account, database, and
mailbox (see "Multi-machine / multi-user model" below).

---

## Data model (`brain/store.py`)

One SQLite file per user (`brain/data/users/<user_id>/brain.db`, or a shared `brain.db` when
no user context applies), two tables:

- **`entities`**: `id, type, title, summary, data (JSON), needs_review, created_at, updated_at`
  — types in use: `person`, `task`, `meeting` (résumé/meeting pipeline) and `mail_category` /
  `mail_topic` / `mail_thread` (mail pipeline).
- **`edges`**: `src_id, dst_id, relation` — e.g. `mail_category --contains--> mail_topic
  --contains--> mail_thread`.

No embeddings, no vector DB. Retrieval is "read the whole graph into a compact text catalogue
and let the LLM reason over it" (`brain/ask.py`) or "BM25-rank threads, expand only the top-K
into full text" (`brain/mail_ask.py`) — both bounded by prompt size, not semantic search.

---

## Mail pipeline (`brain/mail_ingest.py`, `brain/emailtool.py`)

1. **Auth**: Gmail OAuth2 (`InstalledAppFlow.run_local_server` — a local, server-side browser
   consent flow; cannot be completed remotely). Token cached at
   `~/.hermes/mail/<user_id>/{token,meta}.json`. The Google Cloud OAuth consent screen is in
   **Testing** publish status, so any Gmail account must be added under **Test users** or
   consent fails with an unhelpful `access_denied`. There is no separate "hermes" auth path —
   that name only refers to an unrelated LLM CLI tool used for a different deploy workflow
   (`docs/hermes-integration-guide.md`); for mail, OAuth + Test Users is the *only* mechanism.
2. **Fetch**: IMAP XOAUTH2, windowed (unread / recent), one thread per email chain.
3. **Classify** (`score_categories` + `arbitrate_category`): a hand-built vocabulary scorer,
   **not BM25** — BM25's length-normalization was found to actively penalize categories with
   richer keyword lists (proven bug: adding synonyms to a category could make it lose to a
   rival). The scorer counts presence (not frequency) of phrase/word keywords per zone
   (subject weighted 3x, body 1x, negative keywords veto/penalize), floors low-signal
   categories out, and only overrides the LLM's own guess when the keyword signal is confident
   (margin check, not just a tie-break). `brain/bm25.py` is unchanged and still used for
   `mail_ask.py`'s thread ranking, where ranking real documents against a query is exactly
   what BM25 is for.
4. **Learn**: `learn_category_keywords` / `learned_keywords` — manual reclassifications feed
   back into future scoring per-user, so corrections compound instead of being one-off.
5. **Attachments**: local Excel/PDF parsing (`mail_attachments.py`), OCR for scanned content,
   findings merged into thread data and treated as authoritative over the thread summary.
6. **Dates** (`brain/mail_timeline.py`): each thread stores `received_at` (every source email's
   own Date header, keyed by uid — no LLM) and `events` (deadlines/events the existing
   merge/place LLM call already extracts, now kept even when Calendar isn't connected, each
   tagged `deadline` or `event`). Dates are thread *attributes*, never a tree level — the
   console's "By time" view regroups the same thread nodes client-side. Threads from before this
   fall back to `created_at` (marked approximate) and any recorded calendar events, so no
   migration was needed. Urgency (overdue / due within 3 days / upcoming) is derived from today
   on every read, never stored. Mail Q&A gets each thread's received date plus a DATED ITEMS
   block, so "what's due this week" works even though it shares no words with the emails.
7. **Review queue**: low-confidence classifications set `needs_review`, surfaced via
   `GET /api/mail/review` and `MailReviewQueue.tsx`. `POST /api/mail/reclassify` moves a
   thread to a different category/topic (creating the destination if needed), clears the flag,
   and `prune_empty_mail_nodes` removes any category/topic left with no children.

## Brain API (`brain/viz_server.py`, all under `CurrentUser` JWT auth unless noted)

| Route | Purpose |
|---|---|
| `GET /api/data` | full entity graph (résumé/meeting side) |
| `POST /api/ask` | Q&A over the person/task/meeting graph (`brain/ask.py`) |
| `POST /api/ingest_resume` | ingest a résumé/meeting transcript |
| `GET /api/mail_tree` | category → topic → thread tree for the mindmap UI; thread nodes also carry `category`, `topic`, `first_received`, `last_received`, `received_estimated`, `events` |
| `POST /api/mail/reload`, `/reload/stream` | re-run ingest (streaming variant reports progress) |
| `GET /api/mail/status`, `POST /connect`, `POST /disconnect` | Gmail OAuth lifecycle |
| `POST /api/mail/ask` | Q&A over the mail tree (`brain/mail_ask.py`) |
| `GET/PUT /api/profile` | free-form key/value profile used as optional chat context |
| `POST /api/mail/attachments/rescan` | re-run attachment OCR/parsing |
| `GET /api/mail/review`, `POST /api/mail/reclassify` | review queue + manual correction |

## Console backend API (`console/backend`)

| Route | Purpose |
|---|---|
| `POST /auth/login`, `GET /auth/me`, `POST /auth/users` (admin only) | accounts |
| `GET /health` | composite health incl. brain reachability |
| `POST/GET /sessions`, `GET/DELETE /sessions/{id}`, `POST /sessions/{id}/messages` | chat sessions persisted in the console's own DB; message POST calls `brain`'s `/api/ask` server-side |
| `POST /onboarding` (admin/team_lead/hr), `GET /roster`, `GET /roster/me` | employee onboarding → ClickUp task + roster |
| `GET /resume` | résumé retrieval |
| `GET /voice/options`, `POST /voice/transcribe`, `POST /voice/speak` | Sarvam AI speech-to-text (`saaras:v3`) and text-to-speech (`bulbul:v3`), proxied so `SARVAM_API_KEY` never reaches the browser (`console/backend/voice.py`). A transcript is dropped into the chat composer for review, not auto-sent; long answers are split at sentence boundaries under Sarvam's 2500-char limit and stitched back into one WAV |

## Frontend (`console/frontend/src`)

Pages: `Login`, `Home` (mail-first dashboard + mindmap entry), `Chat`, `Applications`
(onboarding/roster), `Profile`. No router — navigation is component state, so there is no
deep-linking. Key components: `MailMindmap` (D3 tree, reclassify control inline against
`--mm-*` CSS vars since the panel is dark against an otherwise light/Tailwind app; a
"By topic / By time" switch — time view groups by Upcoming deadline or Received date — plus
filter chips, search, per-category colours and urgency outlines, all in `lib/mailTimeline.ts`),
`MailReviewQueue`, `MailIngestProgress`, `ChatThread`. Demo mode: if
`VITE_API_BASE_URL` is unset at build time the app runs against fake local data instead of a
backend — a Vite-inlined constant, not runtime-configurable.

---

## Multi-machine / multi-user model (the thing that caused teammate login confusion)

Each developer runs **their own full stack** locally — there is no shared/hosted instance.
Consequences that aren't obvious from the code alone:

- `console-local.db` (SQLite) is per-machine. `seed_admin()` auto-creates exactly one admin
  account from that machine's own `.env` (`OPS_ADMIN_EMAIL`/`OPS_ADMIN_PASSWORD`) on every
  startup. Accounts created via `POST /auth/users` on one machine **do not exist** on anyone
  else's machine — there's no sync.
- A teammate should log in with the admin credentials from *their own* `.env`, not credentials
  created on someone else's machine.
- Each teammate needs their own Gmail account added to their own Google Cloud project's OAuth
  **Test users** list, and must complete the OAuth consent flow **on their own machine**
  (it's a local browser callback — not remotely completable).
- `SETUP.md` is the authoritative onboarding doc for a brand-new machine, including the exact
  server-start commands and the Test Users troubleshooting step.

---

## Testing

- `uv run pytest` — Python unit/integration tests for `brain` and `console/backend`
  (189 passing as of this doc; one pre-existing unrelated failure,
  `test_onboarding_creates_clickup_task_and_appears_in_roster`, fails on a clean tree too).
- `console/frontend/e2e/*.spec.ts` (Playwright) — real frontend + real both backends, with
  only OpenRouter faked (`e2e/support/fake_openrouter.py`) and Gmail/IMAP untouched (mail data
  is pre-seeded directly into a temp per-user SQLite file, `e2e/support/seed.py`). Covers
  login, chat send/persist/reload, mail mindmap, thread reclassification, and a two-user
  isolation check (user B can't see user A's chats or mail). Run via `npm run test:e2e` in
  `console/frontend`.

## Recently fixed (this repo's classification work)

- BM25 was replaced as the mail classifier (kept only for thread search ranking) after a
  reproducible bug: a college-wide "yoga competition" email was misfiled under "Placements"
  because BM25's length normalization rewarded a category for having *fewer* keywords, so
  enriching the correct category's vocabulary made things worse, not better.
- The LLM chat/mail-Q&A prompts (`brain/ask.py`, `brain/mail_ask.py`) previously had **no
  notion of the current date**, so relative-time questions ("what meetings do I have today",
  "how many days until X") were unanswerable. Both prompts now include a `=== TODAY ===` line
  (`datetime.now()`, computed per-request) plus an instruction to resolve relative-time
  questions against it rather than guessing.
