"""Tests for brain/chat_pins.py — the one piece of per-conversation state brain keeps."""

from __future__ import annotations

from pathlib import Path

from brain import chat_pins, store


def _conn(tmp_path: Path):
    return store.connect(tmp_path / "t.db")


def test_a_session_starts_with_no_pin(tmp_path: Path) -> None:
    assert chat_pins.get_pin(_conn(tmp_path), 1) is None


def test_pin_round_trips(tmp_path: Path) -> None:
    conn = _conn(tmp_path)
    chat_pins.set_pin(conn, 7, "mail:thread:101")
    assert chat_pins.get_pin(conn, 7) == "mail:thread:101"


def test_repinning_replaces_rather_than_accumulating(tmp_path: Path) -> None:
    """The row key is derived from the session id, so a conversation has one pin, not a pile."""
    conn = _conn(tmp_path)
    chat_pins.set_pin(conn, 7, "mail:thread:101")
    chat_pins.set_pin(conn, 7, "mail:thread:202")

    assert chat_pins.get_pin(conn, 7) == "mail:thread:202"
    assert len(store.all_of_type(conn, chat_pins.PIN_TYPE)) == 1


def test_sessions_do_not_see_each_other(tmp_path: Path) -> None:
    conn = _conn(tmp_path)
    chat_pins.set_pin(conn, 1, "mail:thread:101")
    chat_pins.set_pin(conn, 2, "mail:thread:202")

    assert chat_pins.get_pin(conn, 1) == "mail:thread:101"
    assert chat_pins.get_pin(conn, 2) == "mail:thread:202"


def test_a_missing_session_id_is_a_no_op(tmp_path: Path) -> None:
    """ask_mail passes session_id straight through, and it is None for callers that have none."""
    conn = _conn(tmp_path)
    chat_pins.set_pin(conn, None, "mail:thread:101")

    assert chat_pins.get_pin(conn, None) is None
    assert store.all_of_type(conn, chat_pins.PIN_TYPE) == []
