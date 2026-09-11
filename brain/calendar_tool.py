"""brain/calendar_tool.py — Google Calendar OAuth + event listing/creation/deletion.

Mirrors brain/emailtool.py's OAuth pattern exactly (same shape, same `~/.hermes/` convention,
same InstalledAppFlow local-browser consent), but for Calendar instead of Gmail, and it talks
to the Calendar REST API directly over `requests` instead of IMAP — no google-api-python-client
dependency needed for a single read-only endpoint.

Reuses the *same* OAuth client secrets file as Gmail (GMAIL_CREDENTIALS_PATH) by default: it's
the same Google Cloud project, and Google allows one OAuth client to be granted multiple scopes
across separate consent grants. Override with CALENDAR_CREDENTIALS_PATH if you'd rather use a
separate client. The token itself is always separate per service (Calendar's token must not be
reused for IMAP or vice versa — different scopes).

Env vars:
    CALENDAR_CREDENTIALS_PATH  (default: same file as GMAIL_CREDENTIALS_PATH, else
                                ~/.hermes/mail/credentials.json)
    CALENDAR_TOKEN_PATH        (default ~/.hermes/calendar/token.json, or
                                ~/.hermes/calendar/<user_id>/token.json per-user)
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import requests

# calendar.events (not calendar.readonly) — the mail pipeline creates events for detected
# meetings/deadlines (see brain/mail_ingest.py's event extraction), so read-only isn't enough.
# A token issued under the old readonly-only scope must be re-consented (Disconnect + Connect)
# — refreshing with a wider scope than was granted fails with `invalid_scope`.
CALENDAR_OAUTH_SCOPES = ["https://www.googleapis.com/auth/calendar.events"]
EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/primary/events"


def _default_path(env_var: str, filename: str, user_id: str | int | None = None) -> Path:
    override = os.environ.get(env_var)
    if override:
        return Path(override).expanduser()
    base = Path.home() / ".hermes" / "calendar"
    if user_id is not None:
        base = base / str(user_id)
    return base / filename


def _credentials_path() -> Path:
    override = os.environ.get("CALENDAR_CREDENTIALS_PATH")
    if override:
        return Path(override).expanduser()
    # Fall back to the Gmail OAuth client — same Google Cloud project, no second download
    # needed as long as the Calendar API is enabled on it too (see SETUP.md).
    gmail_override = os.environ.get("GMAIL_CREDENTIALS_PATH")
    if gmail_override:
        return Path(gmail_override).expanduser()
    return Path.home() / ".hermes" / "mail" / "credentials.json"


def _token_path(user_id: str | int | None = None) -> Path:
    return _default_path("CALENDAR_TOKEN_PATH", "token.json", user_id)


def _load_oauth_credentials(interactive: bool, user_id: str | int | None = None):
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow

    token_path = _token_path(user_id)
    creds = None
    if token_path.exists():
        creds = Credentials.from_authorized_user_file(str(token_path))

    if creds and creds.valid:
        return creds

    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    else:
        if not interactive:
            raise RuntimeError(
                f"No valid Calendar OAuth token at {token_path}. Connect Google Calendar from "
                "the Applications page first."
            )
        creds_path = _credentials_path()
        if not creds_path.exists():
            raise RuntimeError(
                f"Missing OAuth client secrets at {creds_path}. Download it from Google Cloud "
                "Console (see SETUP.md) and save it there, or set CALENDAR_CREDENTIALS_PATH."
            )
        flow = InstalledAppFlow.from_client_secrets_file(str(creds_path), CALENDAR_OAUTH_SCOPES)
        os.environ.setdefault("OAUTHLIB_RELAX_TOKEN_SCOPE", "1")
        creds = flow.run_local_server(port=0)

    token_path.parent.mkdir(parents=True, exist_ok=True)
    token_path.write_text(creds.to_json(), encoding="utf-8")
    return creds


def connect(user_id: str | int | None = None) -> None:
    """Run the interactive (browser) OAuth consent flow and cache the resulting token."""
    _load_oauth_credentials(interactive=True, user_id=user_id)


def calendar_status(user_id: str | int | None = None) -> dict[str, Any]:
    """Whether this user's calendar can actually be read right now, not just whether a token
    file exists — same rationale as brain/emailtool.py's mailbox_status."""
    if not _token_path(user_id).exists():
        return {"connected": False, "reason": "no calendar connected yet"}
    try:
        creds = _load_oauth_credentials(interactive=False, user_id=user_id)
    except Exception as exc:
        return {"connected": False, "reason": f"stored credentials are unusable: {exc}"}
    if not creds or not creds.valid:
        return {"connected": False, "reason": "stored credentials could not be refreshed"}
    return {"connected": True}


def disconnect(user_id: str | int | None = None) -> None:
    path = _token_path(user_id)
    if path.exists():
        path.unlink()


def _parse_when(node: dict[str, Any]) -> str:
    # All-day events carry "date" (YYYY-MM-DD); timed events carry "dateTime" (RFC3339).
    return str(node.get("dateTime") or node.get("date") or "")


def list_upcoming_events(
    user_id: str | int | None = None, max_results: int = 15
) -> list[dict[str, Any]]:
    """The next `max_results` upcoming events on the primary calendar, oldest first."""
    from datetime import UTC, datetime

    creds = _load_oauth_credentials(interactive=False, user_id=user_id)
    resp = requests.get(
        EVENTS_URL,
        headers={"Authorization": f"Bearer {creds.token}"},
        params={
            "timeMin": datetime.now(UTC).isoformat(),
            "singleEvents": "true",
            "orderBy": "startTime",
            "maxResults": max_results,
        },
        timeout=10,
    )
    resp.raise_for_status()
    items = resp.json().get("items", [])
    return [
        {
            "id": item.get("id"),
            "title": item.get("summary") or "(no title)",
            "start": _parse_when(item.get("start") or {}),
            "end": _parse_when(item.get("end") or {}),
            "location": item.get("location"),
        }
        for item in items
    ]


def _when_field(value: str) -> dict[str, str]:
    """Google's event start/end each take either {"date": "YYYY-MM-DD"} (all-day) or
    {"dateTime": "<RFC3339>"} (timed) — never both. `value` already carries whichever shape the
    extractor produced (see brain/mail_ingest.py's EVENT_JSON_SHAPE)."""
    return {"date": value} if len(value) == 10 else {"dateTime": value}


def create_event(
    user_id: str | int | None,
    title: str,
    start: str,
    end: str,
    location: str | None = None,
) -> str:
    """Create an event on the user's primary calendar; returns the new event's id (used later
    to undo the creation via delete_event)."""
    creds = _load_oauth_credentials(interactive=False, user_id=user_id)
    body: dict[str, Any] = {
        "summary": title,
        "start": _when_field(start),
        "end": _when_field(end),
    }
    if location:
        body["location"] = location
    resp = requests.post(
        EVENTS_URL,
        headers={"Authorization": f"Bearer {creds.token}"},
        json=body,
        timeout=10,
    )
    resp.raise_for_status()
    return str(resp.json()["id"])


def delete_event(user_id: str | int | None, event_id: str) -> None:
    """Remove a previously created event — the "Undo" side of the auto-add popup."""
    creds = _load_oauth_credentials(interactive=False, user_id=user_id)
    resp = requests.delete(
        f"{EVENTS_URL}/{event_id}",
        headers={"Authorization": f"Bearer {creds.token}"},
        timeout=10,
    )
    # Google returns 410 Gone if it was already deleted (e.g. a double-click on Undo) —
    # treat that the same as success rather than surfacing an error for a no-op.
    if resp.status_code not in (200, 204, 404, 410):
        resp.raise_for_status()
