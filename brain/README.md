# The Agent OS Brain — mail knowledge-tree pipeline

Each user connects their own Gmail (and optionally Slack, Google Calendar). This service
ingests those messages into a per-user SQLite knowledge tree, sorts them into categories and
topics, flags what's urgent, and answers natural-language questions about them.

```
Gmail / Slack ──▶ classify (LLM + keyword guardrail) ──▶ merge/place ──▶ store ──▶ answer (LLM)
```

The entity graph underneath (`brain/store.py`) is generic — typed nodes + typed edges in
SQLite — and mail is what it's used for today:

```
mail_category ──contains──▶ mail_topic ──contains──▶ mail_thread
```

Everything except the two LLM calls per email (classify, merge) and the one per question (ask)
is plain, deterministic, testable code. See `../CURRENT_STATE.md` for the full current picture
and `../SETUP.md` to run it.

## Pieces

| File | Role | LLM? |
|---|---|---|
| `brain/store.py` | the entity graph — `entities` + `edges` tables, `upsert` / `neighbors` / query helpers | no |
| `brain/resolver.py` | deterministic dedup: candidate + existing → create / update / review | no |
| `brain/mail_ingest.py` | the ingest pipeline: attachments → classify → merge/place → store, channel-agnostic | via LLM + keyword guardrail |
| `brain/mail_ask.py` | question answering: BM25-rank threads, expand the top few, answer from that context | yes |
| `brain/mail_attachments.py` | Excel/CSV/PDF/DOCX parsing, local OCR for images | no (vision-model fallback only if Tesseract is absent) |
| `brain/mail_timeline.py` | deadline/event dates per thread — overdue / due-soon / upcoming, derived on every read | no |
| `brain/chat_pins.py` | follow-up-question handling — "when is it due?" resolves against the thread the chat was already about | no |
| `brain/automation.py` | natural-language automation rules ("notify me on Slack when a Placements email arrives"), parsed once at rule-creation time | once per rule |
| `brain/bm25.py` | shared BM25 ranking, used correctly for thread search (not for classification — see `mail_ingest.py`'s module docstring) | no |
| `brain/oauth_flow.py` | redirect-based Google OAuth (Gmail + Calendar), shared consent flow | no |
| `brain/emailtool.py` | Gmail IMAP client (list/fetch/mark-read) | no |
| `brain/calendar_tool.py` | Google Calendar REST client (list/create/delete events) | no |
| `brain/slack_ingest.py` | pulls Slack channel history into the same `_ingest_message` pipeline as Gmail | via LLM + keyword guardrail |
| `brain/profile.py` | per-user "About you" details (name, roll number, …), used to match attachments | no |
| `brain/engine.py` | the one non-mail LLM seam — routes a prompt to the configured backend (see below) | — |
| `brain/openrouter.py` | OpenRouter client used by the mail pipeline: free-tier key rotation, `max_tokens` safety net | — |
| `brain/auth.py` | bearer-token auth for this service, verifying the same JWT `console/backend` issues | no |
| `brain/viz_server.py` | the FastAPI app: every `/api/mail_*`, `/api/calendar_*`, `/api/slack_*` route, plus the OAuth callback and the D3 tree viewer | — |

## Run it

```bash
uv sync
uv run uvicorn brain.viz_server:app --port 8080     # the knowledge tree, ingest, Q&A, OAuth — at :8080
```

Full setup (Gmail OAuth client, `.env`, the console, Slack, Calendar) is in `../SETUP.md`. The
store lands at `brain/data/users/<user_id>/brain.db` (git-ignored — it's data, regenerate by
syncing).

**Offline mode** (toggle on the Integrations page) means *"never call the LLM,"* not *"works
without a network"* — IMAP/Slack still run; classification falls back to keyword scoring.

## Engine-agnostic (for the non-mail LLM seam)

`brain/engine.py::run_llm` is a separate, older seam not used by the mail pipeline (which calls
OpenRouter directly via `brain/openrouter.py`), switched by one env var:

```
BRAIN_ENGINE=claude   (default)  ->  claude -p     (prompt on stdin)
BRAIN_ENGINE=hermes              ->  hermes -z     (prompt as arg, final text out)
```

## Design provenance

The entity-graph store (`brain/store.py`, `brain/resolver.py`) predates the mail pipeline — it
was built for an earlier, since-abandoned version of this project (résumé/candidate matching)
and reused as-is for mail, because the create/update/review resolution logic and the typed
node/edge model didn't need to change, only what's stored in them. `brain/samples/` and
`brain/hermes-skill/SKILL.md` are leftovers from that earlier version; safe to ignore.

See `../CURRENT_STATE.md` and `../HANDOFF.md` for what's real today. `../README.md`,
`../system-overview.md`, and `../agent-os-clean-room-architecture.md` (now under
`../docs/archive/`) describe an earlier pitch (Fathom meeting transcripts → ClickUp tasks) that
was never built on top of this store and has since been fully replaced by the mail pipeline.
