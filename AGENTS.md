# Agent OS — contributor & agent guide

A mail knowledge-tree pipeline: each user connects their own Gmail (optionally Slack, Google
Calendar); a local service ingests, classifies, and answers questions over the result behind a
web console and an Android app. See [`CURRENT_STATE.md`](CURRENT_STATE.md) for the accurate,
current picture and [`SETUP.md`](SETUP.md) to run it. `README.md` covers the same ground for a
first-time reader.

This file is the single source of truth for **where files go**. Place every new file
(human- or agent-written) per the layout below. If a needed location isn't listed, add it
here first rather than placing files ad hoc.

## Repository layout

| Path | Holds |
|---|---|
| `pyproject.toml` | Project metadata, deps, tool config (ruff, mypy, import-linter) |
| `.python-version`, `uv.lock` | Pinned interpreter and locked deps (managed by `uv`) |
| `.pre-commit-config.yaml` | Local git-hook chain (the harness) |
| `.github/workflows/` | CI — runs the identical harness chain |
| `brain/` | The mail knowledge-tree pipeline: ingest, classification, Q&A, Gmail/Calendar OAuth, the FastAPI app (`viz_server.py`) — see `brain/README.md` |
| `console/` | Full-stack ops console: `console/backend` (FastAPI: accounts, chat, Slack token) + `console/frontend` (Vite/React/shadcn) — see `console/README.md` |
| `app/` | Android app (Flutter) — see `app/README.md` |
| `security/` | Shared JWT signing/verification (`security/tokens.py`), used by both `brain/` and `console/backend` |
| `slack/` | Slack outbound client |
| `scripts/` | Utility scripts (e.g. `mail_cron.ps1`) |
| `tests/` | `pytest` tests |
| `e2e/` | Playwright end-to-end support fixtures (fake OpenRouter/voice, DB seeding) |
| `docs/adr/` | Architecture Decision Records |
| `docs/prd/` | Product requirements (problem · goal · user journey) |
| `docs/design-system/` | UI rules (visual ADRs); scoped to any web UI |
| `docs/solutions/` | Documented solutions to past problems (bugs, best practices, workflow patterns), by category with YAML frontmatter (`module`, `tags`, `problem_type`). Relevant when implementing or debugging in documented areas |
| `docs/superpowers/` | Specs and implementation plans |
| `docs/app/` | Android app decision records |
| `docs/archive/` | Superseded design docs from an earlier, abandoned pitch — historical only |
| `.claude/` | Committed team config (`settings.json`); `settings.local.json` is gitignored |

## Develop

Install `uv` first (one-time, per machine) — every command below depends on it:

```bash
# macOS
brew install uv
# or cross-platform
curl -LsSf https://astral.sh/uv/install.sh | sh
uv --version   # verify before continuing
```

Then:

```bash
uv sync                            # install deps
uv run pre-commit install          # enable the harness git hooks
uv run pre-commit run --all-files  # run the full harness locally
```

## Governance

Changes are gated locally (pre-commit) and on CI (`.github/workflows/ci.yml`) by the same
checks. Before writing code, read the relevant ADR (`docs/adr/`) and PRD (`docs/prd/`).
Architecture rules are encoded as `import-linter` contracts; a violation message points back
to the governing ADR. Workflow: one issue → one branch → one PR; no direct pushes to `main`.
