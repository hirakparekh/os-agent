"""brain/mail_timeline.py — when a mail thread's emails arrived, and what dates they mention.

Dates are an *attribute* of a thread (inside its `data` JSON), never a level of the tree. The
category > topic > thread structure stays the single source of truth; the console's time view
regroups those same thread nodes at display time, so the two views can't drift apart and a
merge or reclassification never has a second tree to keep in sync.

Two kinds of date, neither costing an extra LLM call:
- `received_at` — each source email's own Date header, keyed by uid. Deterministic.
- `events` — dated things an email describes (a deadline, an interview, an exam), extracted by
  the merge/place call mail_ingest already makes.

Threads ingested before these fields existed have neither. `thread_timeline` falls back to the
row's `created_at` (flagged as estimated — ingest runs soon after mail arrives) and to any
Google Calendar events recorded on the thread, so old threads appear in the time view without a
migration.

Urgency (`thread_status`) is derived from today's date whenever it's asked for, never stored — a
stored "due soon" would silently go stale.
"""

from __future__ import annotations

from datetime import UTC, date, datetime
from email.utils import parsedate_to_datetime
from typing import Any

EVENT_KINDS = ("deadline", "event")
SOON_DAYS = 3
# A missed deadline stays flagged as overdue for this long, then quietly becomes "past" — a
# form due three months ago isn't something to keep shouting about.
OVERDUE_WINDOW_DAYS = 14


def _parse_iso(value: Any) -> datetime | None:
    try:
        return datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None


def _sort_key(dt: datetime) -> datetime:
    # Received dates carry offsets; a bare date-only event does not. Comparing the two directly
    # raises, so treat naive values as UTC purely for ordering.
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


def parse_received(raw: str | None) -> str | None:
    """An RFC 2822 Date header as ISO 8601 with its offset, or None if it won't parse."""
    if not raw:
        return None
    try:
        dt = parsedate_to_datetime(raw)
    except (TypeError, ValueError, IndexError):
        return None
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.isoformat(timespec="seconds")


def merge_received(prior: dict[str, str] | None, uid: str, raw_date: str | None) -> dict[str, str]:
    merged = dict(prior or {})
    iso = parse_received(raw_date)
    if iso:
        merged[uid] = iso
    return merged


def normalize_event(event: dict[str, Any] | None, source_uid: str) -> dict[str, Any] | None:
    """The LLM's `event` object, validated. None unless it names a date that actually parses —
    a small model sometimes writes "next Friday" or "TBD" into a field that asked for ISO."""
    if not isinstance(event, dict) or not event.get("has_event"):
        return None
    start = str(event.get("start") or "").strip()
    if not start or _parse_iso(start) is None:
        return None
    end = str(event.get("end") or "").strip()
    kind = str(event.get("kind") or "").strip().lower()
    return {
        "title": str(event.get("title") or "").strip() or "Untitled",
        "start": start,
        "end": end if end and _parse_iso(end) is not None else None,
        "kind": kind if kind in EVENT_KINDS else "event",
        "location": str(event.get("location") or "").strip() or None,
        "source_uid": source_uid,
    }


def merge_events(
    prior: list[dict[str, Any]] | None, new: dict[str, Any] | None
) -> list[dict[str, Any]]:
    """Prior events plus `new`, at most one per source email (a retried ingest of the same email
    must not duplicate it), in chronological order."""
    events = [e for e in (prior or []) if isinstance(e, dict) and _parse_iso(e.get("start"))]
    if new and not any(e.get("source_uid") == new["source_uid"] for e in events):
        events.append(new)
    return sorted(events, key=lambda e: _sort_key(_parse_iso(e["start"])))  # type: ignore[arg-type]


def thread_timeline(thread: dict[str, Any]) -> dict[str, Any]:
    """First/last received and the dated events for a stored thread entity, with the fallbacks
    described in the module docstring for threads that predate these fields."""
    data = thread.get("data") or {}
    parsed = [
        (dt, iso)
        for iso in (data.get("received_at") or {}).values()
        if (dt := _parse_iso(iso)) is not None
    ]
    estimated = False
    if not parsed:
        fallback = thread.get("created_at")
        if fallback and (dt := _parse_iso(fallback)) is not None:
            parsed = [(dt, fallback)]
            estimated = True
    parsed.sort(key=lambda pair: _sort_key(pair[0]))

    events = data.get("events")
    if events is None:
        events = merge_events(
            [
                {
                    "title": e.get("title") or "Untitled",
                    "start": e.get("start"),
                    "end": e.get("end"),
                    "kind": "event",
                    "location": None,
                    "source_uid": e.get("source_uid"),
                }
                for e in (data.get("calendar_events") or [])
                if isinstance(e, dict)
            ],
            None,
        )
    return {
        "first_received": parsed[0][1] if parsed else None,
        "last_received": parsed[-1][1] if parsed else None,
        "received_estimated": estimated,
        "events": events,
    }


def _event_day(event: dict[str, Any]) -> date:
    return _parse_iso(event["start"]).date()  # type: ignore[union-attr]


def thread_status(timeline: dict[str, Any], today: date) -> dict[str, Any]:
    """Where a thread stands relative to `today`: the nearest upcoming event if there is one
    ("soon" within SOON_DAYS, else "upcoming"), otherwise the latest past one ("overdue" for a
    recently missed deadline, else "past"), otherwise "none"."""
    events = [e for e in timeline.get("events") or [] if _parse_iso(e.get("start"))]
    upcoming = sorted((e for e in events if _event_day(e) >= today), key=_event_day)
    if upcoming:
        event = upcoming[0]
        days = (_event_day(event) - today).days
        return {"status": "soon" if days <= SOON_DAYS else "upcoming", "event": event, "days": days}
    if events:
        event = max(events, key=_event_day)
        days = (_event_day(event) - today).days
        overdue = event.get("kind") == "deadline" and -days <= OVERDUE_WINDOW_DAYS
        return {"status": "overdue" if overdue else "past", "event": event, "days": days}
    return {"status": "none", "event": None, "days": None}
