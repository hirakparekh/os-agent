"""brain/chat_pins.py — which mail thread a chat session is currently about.

A follow-up question ("when is it due?", "tell me more", "why?") shares no words with the
thread it refers to, so BM25 ranks noise for it and the answer wanders to unrelated mail.
Remembering the thread the last well-matched question landed on lets those questions be
answered from the right place — with no query rewriting, no history injection, and no second
model call.

Kept in the user's own brain.db rather than a process-local dict: brain is restarted whenever
backend code changes, and a pin that vanishes mid-conversation is worse than no pin at all.
This is the same one-row-of-JSON pattern mail_settings uses (brain/mail_ingest.py), and the
per-user database file (brain/store.py) is what keeps one person's sessions out of another's.
"""

from __future__ import annotations

from typing import Any

from brain import store

PIN_TYPE = "chat_pin"


def _pin_id(session_id: int | str) -> str:
    """A deterministic row key, so re-pinning a session replaces rather than accumulates."""
    return f"chat:pin:{session_id}"


def get_pin(conn: Any, session_id: int | str | None) -> str | None:
    """The thread id this session is currently about, or None if it has none yet."""
    if session_id is None:
        return None
    entity = store.get(conn, _pin_id(session_id))
    if not entity:
        return None
    thread_id = (entity.get("data") or {}).get("thread_id")
    return str(thread_id) if thread_id else None


def set_pin(conn: Any, session_id: int | str | None, thread_id: str) -> None:
    """Remember `thread_id` as what this session is about, replacing any previous pin."""
    if session_id is None or not thread_id:
        return
    store.upsert(
        conn,
        PIN_TYPE,
        {
            "source_id": _pin_id(session_id),
            "session_id": str(session_id),
            "thread_id": thread_id,
        },
        title=f"Chat session {session_id}",
        summary="The mail thread this conversation is currently about.",
        source="chat",
    )
