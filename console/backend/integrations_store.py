"""Local persistence for org-wide integration secrets connected from the Applications UI.

Mirrors the project's existing convention (brain/emailtool.py caches Gmail OAuth tokens under
`~/.hermes/`) rather than inventing a new pattern: one small JSON file, not a DB table, since
these are org-wide singletons (one Slack workspace), not per-user records. An env var
(`SLACK_BOT_TOKEN`) still works and takes precedence — this store is what lets someone paste a
token into the UI instead of editing `.env` and restarting the process.
"""

from __future__ import annotations

import json
import os
from pathlib import Path


def _store_path() -> Path:
    override = os.environ.get("CONSOLE_INTEGRATIONS_PATH")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".hermes" / "console-integrations.json"


def _read_all() -> dict[str, str]:
    path = _store_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def get_secret(name: str) -> str | None:
    return _read_all().get(name) or None


def set_secret(name: str, value: str) -> None:
    path = _store_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    data = _read_all()
    data[name] = value
    path.write_text(json.dumps(data), encoding="utf-8")


def clear_secret(name: str) -> None:
    path = _store_path()
    data = _read_all()
    if name in data:
        del data[name]
        path.write_text(json.dumps(data), encoding="utf-8")
