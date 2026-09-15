# Deploy — Ops Console

Two deploy targets are kept side by side: Unraid/self-hosted (docker-compose) and Railway.

## Environment variables (backend)

| Var | Purpose |
|---|---|
| `DATABASE_URL` | Postgres connection (e.g. `postgresql+psycopg://ops:ops@db:5432/ops_console`) |
| `OPS_SECRET_KEY` | JWT signing key — use 32+ random bytes in production |
| `OPS_ADMIN_EMAIL` / `OPS_ADMIN_PASSWORD` | Seed admin login, created on first startup if absent |
| `SLACK_BOT_TOKEN` | Slack app bot token, for Slack message ingestion into the mail tree |
| `OPS_CORS_ORIGINS` | Comma-separated origins allowed to call the API |

This compose file builds `console/backend` (accounts/login/chat) only — the `brain` service
(mail ingest, classification, Q&A, OAuth; see the root `SETUP.md`) is a separate process and
isn't part of this stack yet.

The compose stack runs Postgres (`db` service, volume `ops_db`); the backend waits for it to be
healthy and creates tables + seeds the admin on startup. Add more logins via
`POST /auth/users` (admin only).

Frontend bakes `VITE_API_BASE_URL` at build time — point it at the deployed backend.

## Unraid / self-hosted (docker-compose)

```bash
cd console/deploy
docker compose up --build      # backend :8000, frontend :8080
```

## Railway

- Backend: deploy this repo with `console/deploy/railway.json` (Dockerfile builder). Set the
  env vars above in the Railway service.
- Frontend: deploy `console/frontend` as a separate static service (build `npm run build`,
  serve `dist/`), with `VITE_API_BASE_URL` set to the backend URL.

> These are starting stubs — not yet smoke-tested against a live target. Harden when the
> deploy target is chosen.
