# Ops Console (full-stack)

The web app for Agent OS: accounts/login, chat over your mail tree, and the Integrations page
(Gmail/Calendar/Slack connect, automation rules). Mail ingestion, classification, and Q&A
themselves live in `brain/` (a separate process) — this console is the UI and account layer in
front of it. See `../CURRENT_STATE.md` for how the two talk to each other.

## What it does

- **Login** — email/password, admin-seeded on first startup (`POST /auth/users` to add more).
- **Chat** — ask natural-language questions over your ingested mail (proxies to `brain`'s
  `/api/mail/ask`).
- **Mail / Integrations pages** — connect Gmail, Google Calendar, and Slack; review queue;
  needs-attention and action-item panels; automation rules; offline-mode toggle.
- **Analytics** — category volume over your mail tree.

## Layout

```
console/
├── backend/    # FastAPI (Python). Accounts, JWT, chat-session storage, the Slack token, voice proxy.
├── frontend/   # Vite + React + TypeScript SPA. Talks to backend/ AND directly to brain/ for mail routes.
└── deploy/     # Dockerfile + docker-compose (Unraid) + railway.json (Railway) — backend only for now.
```

## Run locally

There are two ways to start the full stack. Both end with the seeded admin login
`admin@agent-os.local` / `changeme` (override via `OPS_ADMIN_EMAIL` / `OPS_ADMIN_PASSWORD`).
Add more logins via `POST /auth/users` (admin only).

### Option A — With Docker (recommended)

Runs everything (frontend + backend + Postgres) with one command. Needs only Docker.

```bash
cd console/deploy
docker compose up --build            # add -d to run in the background
```

| Service | URL |
|---|---|
| Frontend | http://localhost:8080 |
| Backend API + docs | http://localhost:8000 · http://localhost:8000/docs |
| Postgres | internal `db:5432` (data persists in the `ops_db` volume) |

```bash
docker compose logs -f backend       # tail logs
docker compose down                  # stop (keeps the database)
docker compose down -v               # stop + wipe the database
```

### Option B — Without Docker (manual)

Run each piece yourself. The backend still needs a Postgres; the quickest is a one-off
container on port **5433** (matches the backend's default `DATABASE_URL`, and avoids clashing
with any Postgres already on 5432):

```bash
# 1. Postgres (one-time container; or use a locally installed Postgres)
docker run --name ops-db -p 5433:5432 \
  -e POSTGRES_USER=ops -e POSTGRES_PASSWORD=ops -e POSTGRES_DB=ops_console \
  -d postgres:16-alpine

# 2. Backend — from the repo root, uses the shared uv env (creates tables + seeds admin)
uv sync
uv run uvicorn console.backend.main:app --reload       # http://localhost:8000

# 3. Frontend — from console/frontend
npm install
npm run dev                                            # http://localhost:5173
```

Point the backend at a different database any time by setting `DATABASE_URL`, e.g.
`DATABASE_URL=postgresql+psycopg://user:pass@host:5432/dbname uv run uvicorn ...`.
The dev frontend (`:5173`) is already an allowed CORS origin; for other origins set
`OPS_CORS_ORIGINS` (comma-separated) on the backend.

## Boundaries

- `frontend/` → no third-party SDKs or tokens in the browser. It calls `backend/` for
  accounts/chat/integrations, and `brain/` directly for mail-specific routes (see
  `console/frontend/src/lib/brainApi.ts`) since those are hosted by the `brain` process, not
  proxied through `backend/`.
- `backend/` and `brain/` independently verify the same JWT (`OPS_SECRET_KEY` must match on
  both) rather than one calling the other — see `../CURRENT_STATE.md`.
