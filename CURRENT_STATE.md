# Agent OS — Current State (2026-09-11)

> **Why this file exists:** `README.md`, `system-overview.md`, and
> `agent-os-clean-room-architecture.md` describe the *original* pitch (a Fathom → Hermes →
> ClickUp co-pilot loop, résumé parsing, staff onboarding). None of that exists any more — it
> was removed once it became clear nothing in the app could reach it. This file describes what
> is actually here today. Treat the others as historical.

---

## One sentence

Each user connects their own Gmail (and optionally Slack and Google Calendar); a local FastAPI
service ingests those messages into a per-user SQLite knowledge tree, sorts them into
categories and topics, flags what's urgent, and answers natural-language questions about them —
all behind a React console with its own login.

---

## Processes (three, all local)

| Process | Port | Purpose |
|---|---|---|
| `brain` (`brain/viz_server.py`) | 8080 | The knowledge tree, ingest pipelines, Google OAuth, Q&A, analytics |
| `console/backend` | 8000 | Accounts, login, chat-session storage, the Slack token |
| `console/frontend` | 5173 | The UI (Vite dev server) |

SQLite throughout; no Postgres needed locally. Start them per `SETUP.md`.

**Auth is shared, not proxied.** `console/backend` issues an HS256 JWT at `/auth/login` and is
the only place that can create accounts (admin-only `POST /auth/users`; there is no self-signup).
`brain` verifies that *same* token itself via `security/tokens.py` rather than calling
console/backend. Hence the hard requirement that **both processes run with the same
`OPS_SECRET_KEY`** — mismatch means every cross-service call 401s.

---

## Data model (`brain/store.py`)

One SQLite file per user (`brain/data/users/<user_id>/brain.db`), two tables:

- **`entities`**: `id, type, natural_key, title, summary, data (JSON), source, needs_review,
  created_at, updated_at`
- **`edges`**: `src_id, dst_id, relation, data` — the tree is
  `mail_category --contains--> mail_topic --contains--> mail_thread`

Entity types in use: `mail_category`, `mail_topic`, `mail_thread`, `mail_rule` (keywords learned
from your corrections), `mail_settings` (per-user toggles), `automation_rule`, `profile`.

`data` is an unconstrained JSON blob, which is why features like urgency flags, action items and
calendar bookkeeping were added without a single migration.

No embeddings and no vector database. Retrieval is "BM25-rank the threads, expand only the top
few into full text" (`brain/mail_ask.py`) — bounded by prompt size, not similarity search.

---

## The ingest pipeline

`brain/mail_ingest.py::_ingest_message` is **channel-agnostic**. It takes
`{uid, from, subject, body_text, attachments}` plus a `channel` tag; Gmail and Slack are just two
adapters feeding the same function. Nothing downstream branches on the source, which is why a
Slack message and an email about the same subject land under the same topic and can merge into
one thread.

Per message: parse attachments → classify → decide merge/new/duplicate → store.

- **Classification** is a hand-built vocabulary scorer (`score_categories` + `arbitrate_category`),
  *not* BM25. BM25's length normalisation actively penalised categories with richer keyword
  lists — adding synonyms to a category could make it lose. The scorer counts keyword presence
  per zone (subject ×3, body ×1, negative keywords veto), and only overrides the model's own
  guess when the keyword signal is confidently ahead. `brain/bm25.py` is still used, correctly,
  for ranking threads against a question.
- **Learning**: reclassifying a thread by hand teaches the scorer (`mail_rule`), so the same
  mistake doesn't repeat.
- **Duplicate suppression**: near-identical body text (difflib ≥ 0.85) collapses into the
  existing thread instead of creating a second one.
- **Urgency and action items** are deterministic keyword/regex passes — no LLM, no cost.
- **Dates** (`brain/mail_timeline.py`): each thread records `received_at` — every source message's own Date header, keyed by uid, no LLM — and `events`, the deadlines and dates
  the existing merge/place model call already extracts, kept now even when Calendar is not
  connected. Dates are thread *attributes*, never a level of the tree: the console's "By
  time" view regroups the same thread nodes client-side. Threads ingested before this fall
  back to `created_at`, marked approximate, so no migration was needed. Overdue / due-soon /
  upcoming is derived from today on every read, never stored.
- **Attachments**: Excel/CSV/PDF/DOCX parsed locally; images via local OCR, falling back to a
  vision model only if Tesseract is absent.

**Offline mode** (`mail_settings.offline_mode`, toggled on the Integrations page) means *"never
call the LLM"* — not *"works without a network"*. IMAP still runs. Classification falls back to
keyword scoring, summaries become raw email text, and calendar-event extraction is skipped.

---

## Google OAuth

Consent is a **redirect flow** (`brain/oauth_flow.py`): `connect` returns a Google URL, the
user's own browser consents, Google redirects to `/api/oauth/callback`, the server exchanges the
code, and the client polls status. The `state` is a short-lived JWT signed with `OPS_SECRET_KEY`
carrying `(user_id, service)` — the callback can't carry a bearer token, so that signature is how
the server knows whose grant arrived and why a forged callback is useless.

This replaced an older flow that opened a consent window *on the server* and blocked; it only
worked because the server and the browser were the same machine, and it was the one thing
preventing this from being hosted anywhere.

> **Expect to reconnect Gmail about weekly.** The app requests `https://mail.google.com/` — a
> *restricted* scope, required for IMAP — on an unverified OAuth client, so Google expires its
> refresh tokens after 7 days. Clearing that needs full Google verification plus a third-party
> security assessment. It is a permanent property of this project, not a bug. Status reports
> `needs_reconnect` so the UI offers a button. **Reconnect before any demo** — an expired grant
> looks exactly like an empty inbox.

Tokens live at `~/.hermes/mail/<user_id>/token.json` and `~/.hermes/calendar/<user_id>/token.json`.
The Slack bot token is org-wide at `~/.hermes/console-integrations.json`.

---

## API surface

**brain** (all bearer-auth except `GET /`, `GET /mail-tree`, and the OAuth callback):
`/api/mail_tree`, `/api/mail_tree/export`, `/api/mail/reload(+/stream)`,
`/api/mail/status|connect|disconnect`, `/api/mail/ask`, `/api/mail/review`,
`/api/mail/reclassify`, `/api/mail/attachments/rescan`,
`/api/calendar/status|connect|disconnect|events`, `/api/calendar/events/{id}/undo`,
`/api/slack/status|reload|reload/stream`, `PUT /api/slack/channel`, `/api/profile`,
`/api/settings`, `/api/rules` (+`DELETE /api/rules/{id}`), `/api/needs-attention`,
`/api/action-items`, `/api/analytics/category-volume`, `/api/oauth/callback`.

**console/backend**: `/health`, `/auth/login`, `/auth/me`, `/auth/users`,
`/applications/{id}/connect|disconnect`, and chat under a `/chat` prefix —
`/chat/sessions`, `/chat/sessions/{id}`, `/chat/sessions/{id}/messages`.

Chat goes through `/api/mail/ask`. Its prompt carries today's date and, when Calendar is
connected, your real upcoming events — so "how many days until X" and "what's on my calendar"
are both answerable.

---

## Frontend

Pages: **Chat**, **Mail** (`Home.tsx` — sync, review queue, needs-attention, action items, D3
mindmap), **Analytics**, **Integrations** (`Applications.tsx` — Gmail/Calendar/Slack cards,
offline toggle, automation rules), **Profile**. No router; navigation is component state, so
there is no deep-linking.

---

## Multi-machine / multi-user model

Everyone runs their **own full stack**; there is no shared instance.

- `console-local.db` is per-machine. `seed_admin()` creates exactly one admin from that
  machine's `.env` on startup. Accounts created on one machine do not exist on another.
- Each person connects their own Gmail, and each Google account must be added under **Test
  users** on the OAuth consent screen or consent fails with an unhelpful `access_denied`.
- `SETUP.md` is authoritative for setting up a new machine.

---

## Testing

- `uv run pytest` — **220 passing, 0 failing.**
- Playwright (`console/frontend`, `npm run test:e2e`) — **18 passing**, against the real
  frontend and both real backends, faking only OpenRouter and pre-seeding the mail tree.
- `uv run mypy` and `uv run lint-imports` are clean.
- **`ruff` is not clean, and predates this work**: 13 lint errors and 17 files the formatter
  would rewrite, including files untouched for months. CI (`ruff format --check`) has therefore
  been red on `main` independently of any recent change. CI runs on pushes to `main` and on pull
  requests only.

---

## Known gaps — read before demoing

1. **Slack ingestion has never run against real Slack.** Every surrounding piece is tested with
   a stand-in, but the actual API call has never executed: it needs the `channels:history` scope,
   which hasn't been granted. Same caveat applies to automation rules actually *posting*.
2. **"Automatic sync every 4 hours" on the Mail page is not true.** There is no scheduler in the
   app. `scripts/mail_cron.ps1` exists but must be registered manually as a Windows task, and
   `SETUP.md` never explains how. Mail syncs when you press the button.
3. **Needs-attention and action-items are empty for threads ingested before those features
   existed.** They populate on the next sync. Nothing is broken.
4. **Calendar auto-add from mail** works in both directions individually, but the full
   "email arrives → event appears" chain hasn't been observed on real mail yet.
5. **The weekly Gmail reconnect**, above.
