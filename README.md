<div align="center">

# Agent OS

**Your inbox, turned into a knowledge tree you can ask questions of.**

[![CI](https://img.shields.io/github/actions/workflow/status/CodinGakpo/Autonomous-Personal-Intelligence/ci.yml?branch=main&label=harness&style=flat-square)](https://github.com/CodinGakpo/Autonomous-Personal-Intelligence/actions)
[![Python](https://img.shields.io/badge/python-3.11%2B-blue?style=flat-square)](https://www.python.org/)
[![uv](https://img.shields.io/badge/pkg--manager-uv-purple?style=flat-square)](https://github.com/astral-sh/uv)

*Connect your Gmail → mail is sorted into categories and topics automatically → ask it "what's due this week?" and get a real answer, grounded in your actual mail.*

</div>

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Project Structure](#project-structure)
- [Quick Start](#quick-start)
- [Testing](#testing)
- [Known Limitations](#known-limitations)
- [More Documentation](#more-documentation)

---

## Overview

Each user connects their own Gmail (and optionally Slack and Google Calendar). A local service
ingests those messages into a per-user knowledge tree, classifies every thread into a category
and topic, flags what's urgent, tracks deadlines, and answers natural-language questions about
the result — all behind a React web console, with an Android app in progress.

There's no shared server and no vector database: everyone runs their own full stack against
their own mailbox, and retrieval is BM25 ranking over real threads, not embedding similarity
search. See [`CURRENT_STATE.md`](CURRENT_STATE.md) for the complete, current technical picture.

## How It Works

```
Gmail / Slack ──▶ parse attachments ──▶ classify ──▶ merge into a thread, or create one ──▶ store
                                            │
                              hand-tuned keyword scorer overrides
                              a weak LLM guess when it's confident
```

Classification uses an LLM call arbitrated against a deterministic, hand-built keyword scorer
(`brain/mail_ingest.py`) — the scorer wins whenever its signal is confidently ahead, which
catches the common cases a small free-tier model gets wrong. Duplicate emails collapse into the
same thread; near-identical content is detected with `difflib`, not another LLM call. Urgency
and action items are deterministic keyword/regex passes — no LLM, no cost.

Asking a question (`brain/mail_ask.py`) BM25-ranks every thread against it, expands only the
top few into full text, and answers from that bounded context — a question that shares no words
with an email still gets a correct "no, it isn't there" from the one-line mailbox overview.

## Architecture

Three local processes, no shared instance — every user runs the full stack against their own
data:

| Process | Port | Purpose |
|---|---|---|
| `brain` (`brain/viz_server.py`) | 8080 | Ingest pipelines, classification, Q&A, Gmail/Calendar OAuth, analytics |
| `console/backend` | 8000 | Accounts, login, chat-session storage, the Slack token, voice proxy |
| `console/frontend` | 5173 | The web UI (Vite dev server) |

Both backends independently verify the same HS256 JWT (`OPS_SECRET_KEY`) rather than one
calling the other — `brain` never talks to `console/backend` to validate a token, which is what
lets the Android app hold one token that works against both.

SQLite throughout (one file per user for mail, `brain/data/users/<id>/brain.db`); Postgres is
supported for `console/backend` but not required for local development.

## Project Structure

```
agent-os/
├── brain/                # Mail knowledge-tree pipeline: ingest, classify, ask, OAuth — see brain/README.md
├── console/
│   ├── backend/          # FastAPI: accounts, JWT, chat sessions, Slack token, voice proxy
│   ├── frontend/         # Vite + React + TypeScript + shadcn/ui
│   └── deploy/           # Dockerfile + docker-compose (Unraid) + railway.json
├── app/                  # Android client (Flutter) — see app/README.md
├── security/             # Shared JWT signing/verification, used by brain/ and console/backend
├── slack/                # Slack outbound client
├── scripts/               # Utility scripts (e.g. a Windows scheduled-task mail-sync helper)
├── tests/                # pytest suite
├── e2e/                  # Playwright end-to-end fixtures
└── docs/
    ├── adr/               # Architecture Decision Records
    ├── prd/                # Product requirements
    ├── app/                # Android app decision records
    ├── superpowers/        # Specs and implementation plans
    └── archive/            # Superseded design docs from an earlier, abandoned pitch
```

## Quick Start

Full walkthrough — including the one-time Google OAuth client setup — is in
[`SETUP.md`](SETUP.md). Short version:

```bash
uv sync                                              # Python deps (brain + console/backend)
cd console/frontend && npm install && cd ../..       # frontend deps

cp .env.example .env                                 # fill in OPENROUTER_API_KEYS, OPS_SECRET_KEY

uv run uvicorn brain.viz_server:app --port 8080       # terminal 1 — mail ingest, classify, Q&A
uv run uvicorn console.backend.main:app --port 8000   # terminal 2 — accounts, chat
cd console/frontend && npm run dev                    # terminal 3 — the UI, at :5173
```

Log in with `OPS_ADMIN_EMAIL` / `OPS_ADMIN_PASSWORD` (from `.env`), connect Gmail from the
Integrations page, and sync.

## Testing

```bash
uv run pytest -q                                  # Python: classification, store, ingest, API
cd console/frontend && npm run build               # typecheck + production build
npx playwright install --with-deps chromium && npm run test:e2e   # end-to-end
```

The end-to-end suite boots the real frontend and both real backends, faking only what would
leave the machine (OpenRouter, voice) — it never touches real Gmail or real user data.

## Known Limitations

- Classification is a deterministic keyword scorer arbitrating against an LLM guess — it
  catches common cases, not every genuinely ambiguous email; low-confidence results are flagged
  for manual review rather than silently guessed.
- Gmail's refresh token expires roughly weekly (an unverified OAuth client requesting a
  restricted scope) — reconnect before a demo.
- Slack ingestion is built and unit-tested but has never run against a real Slack workspace.
- There is no scheduler: mail syncs when you press the button, not automatically.

Full, current list in [`CURRENT_STATE.md`](CURRENT_STATE.md#known-gaps--read-before-demoing).

## More Documentation

- [`CURRENT_STATE.md`](CURRENT_STATE.md) — the accurate, detailed technical picture as of today.
- [`SETUP.md`](SETUP.md) — full setup, including Gmail OAuth client registration.
- [`HANDOFF.md`](HANDOFF.md) — complete project state for someone picking this up fresh.
- [`INTEGRATIONS.md`](INTEGRATIONS.md) — connecting Gmail, Google Calendar, and Slack.
- [`brain/README.md`](brain/README.md), [`console/README.md`](console/README.md),
  [`app/README.md`](app/README.md) — per-component detail.
- [`docs/archive/`](docs/archive/) — an earlier pitch (Fathom meeting transcripts → ClickUp
  tasks) that was never built; kept for historical reference only.
