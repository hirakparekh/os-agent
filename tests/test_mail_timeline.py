"""Tests for mail thread dates: parsing, persistence at ingest, the tree API, and chat context."""

from datetime import date

import pytest
from fastapi.testclient import TestClient

from brain import auth as brain_auth
from brain import mail_ask, mail_ingest, mail_timeline, store, viz_server

TODAY = date(2026, 9, 11)


def _event(start, kind="event", uid="1", title="Thing"):
    return {
        "title": title,
        "start": start,
        "end": None,
        "kind": kind,
        "location": None,
        "source_uid": uid,
    }


# --- pure rules ------------------------------------------------------------------------------


def test_parse_received_keeps_offset_and_rejects_garbage():
    assert (
        mail_timeline.parse_received("Thu, 10 Sep 2026 18:30:00 +0530")
        == "2026-09-10T18:30:00+05:30"
    )
    assert mail_timeline.parse_received("not a date") is None
    assert mail_timeline.parse_received("") is None


def test_normalize_event_validates_the_llm_output():
    ok = mail_timeline.normalize_event(
        {"has_event": True, "kind": "Deadline", "title": "Fee", "start": "2026-09-14"}, "5"
    )
    assert ok == _event("2026-09-14", kind="deadline", uid="5", title="Fee")
    # A small model writing prose into an ISO field must not become a bogus date.
    assert mail_timeline.normalize_event({"has_event": True, "start": "next Friday"}, "5") is None
    assert mail_timeline.normalize_event({"has_event": False, "start": "2026-09-14"}, "5") is None
    odd_kind = mail_timeline.normalize_event(
        {"has_event": True, "kind": "?", "start": "2026-09-14"}, "5"
    )
    assert odd_kind["kind"] == "event"


def test_merge_events_dedupes_per_email_and_sorts():
    merged = mail_timeline.merge_events(
        [_event("2026-09-20", uid="2")], _event("2026-09-14T10:00:00", uid="3")
    )
    assert [e["source_uid"] for e in merged] == ["3", "2"]
    # A retried ingest of the same email adds nothing.
    again = mail_timeline.merge_events(merged, _event("2026-09-30", uid="3"))
    assert len(again) == 2


def test_thread_timeline_falls_back_for_threads_that_predate_dates():
    legacy = {
        "created_at": "2026-09-01T08:00:00+00:00",
        "data": {
            "calendar_events": [{"title": "Interview", "start": "2026-09-15", "source_uid": "9"}]
        },
    }
    timeline = mail_timeline.thread_timeline(legacy)
    assert timeline["last_received"] == "2026-09-01T08:00:00+00:00"
    assert timeline["received_estimated"] is True
    assert [e["title"] for e in timeline["events"]] == ["Interview"]


def test_thread_timeline_orders_received_dates_across_offsets():
    thread = {
        "data": {
            "received_at": {"1": "2026-09-10T23:00:00+05:30", "2": "2026-09-10T18:00:00+00:00"}
        }
    }
    timeline = mail_timeline.thread_timeline(thread)
    assert timeline["first_received"] == "2026-09-10T23:00:00+05:30"  # 17:30 UTC
    assert timeline["last_received"] == "2026-09-10T18:00:00+00:00"
    assert timeline["received_estimated"] is False


@pytest.mark.parametrize(
    ("events", "status", "days"),
    [
        ([_event("2026-09-11")], "soon", 0),
        ([_event("2026-09-14")], "soon", 3),
        ([_event("2026-09-15")], "upcoming", 4),
        ([_event("2026-09-09", kind="deadline")], "overdue", -2),
        ([_event("2026-08-01", kind="deadline")], "past", -41),  # outside the overdue window
        ([_event("2026-09-09", kind="event")], "past", -2),  # a missed *event* isn't overdue
        ([_event("2026-09-01", kind="deadline"), _event("2026-09-20")], "upcoming", 9),
        ([], "none", None),
    ],
)
def test_thread_status(events, status, days):
    result = mail_timeline.thread_status({"events": events}, TODAY)
    assert result["status"] == status
    assert result["days"] == days


# --- ingest ----------------------------------------------------------------------------------


def _email(uid, date_header, subject="Accenture OA"):
    return {
        "uid": uid,
        "from": "hr@acme.com",
        "to": "me@x.com",
        "subject": subject,
        "body_text": "...",
        "attachments": [],
        "date": date_header,
    }


def _fake_llm(monkeypatch, decision):
    monkeypatch.setattr(
        mail_ingest,
        "classify_email",
        lambda email, findings, categories: {
            "category": "Placements",
            "new_category": True,
            "topic": "Acme",
            "new_topic": True,
        },
    )
    # "Accenture" in the subject is confident for Placements via keywords, so classify_email is
    # skipped and classify_topic_only runs instead; a same-sender+topic second email then
    # short-circuits straight past merge_or_create_thread to merge_into_known_thread (see
    # _ingest_message) -- mock both too, so tests using this helper never hit the real API.
    monkeypatch.setattr(
        mail_ingest,
        "classify_topic_only",
        lambda email, findings, category_title, topics: {"topic": "Acme"},
    )
    monkeypatch.setattr(
        mail_ingest, "merge_or_create_thread", lambda email, findings, existing: decision
    )
    monkeypatch.setattr(
        mail_ingest, "merge_into_known_thread", lambda email, findings, existing_thread: decision
    )


def test_ingest_stores_received_date_and_event(tmp_path, monkeypatch):
    conn = store.connect(tmp_path / "t.db")
    _fake_llm(
        monkeypatch,
        {
            "action": "new",
            "merge_into_id": None,
            "summary": "s",
            "body": "b",
            "event": {"has_event": True, "kind": "deadline", "title": "OA", "start": "2026-09-14"},
        },
    )
    result = mail_ingest.ingest_email(conn, _email("1", "Thu, 10 Sep 2026 09:00:00 +0530"), {})

    data = store.get(conn, result["thread_id"])["data"]
    assert data["received_at"] == {"1": "2026-09-10T09:00:00+05:30"}
    assert data["events"] == [_event("2026-09-14", kind="deadline", uid="1", title="OA")]


def test_ingest_merge_accumulates_dates(tmp_path, monkeypatch):
    conn = store.connect(tmp_path / "t.db")
    _fake_llm(
        monkeypatch,
        {
            "action": "new",
            "merge_into_id": None,
            "summary": "s",
            "body": "b",
            "event": {
                "has_event": True,
                "kind": "event",
                "title": "Interview",
                "start": "2026-09-20",
            },
        },
    )
    first = mail_ingest.ingest_email(conn, _email("1", "Thu, 10 Sep 2026 09:00:00 +0000"), {})
    _fake_llm(
        monkeypatch,
        {
            "action": "merge",
            "merge_into_id": first["thread_id"],
            "summary": "s",
            "body": "b",
            "event": {"has_event": True, "kind": "deadline", "title": "OA", "start": "2026-09-14"},
        },
    )
    mail_ingest.ingest_email(conn, _email("2", "Fri, 11 Sep 2026 09:00:00 +0000"), {})

    timeline = mail_timeline.thread_timeline(store.get(conn, first["thread_id"]))
    assert timeline["first_received"].startswith("2026-09-10")
    assert timeline["last_received"].startswith("2026-09-11")
    assert [e["title"] for e in timeline["events"]] == ["OA", "Interview"]


def test_ingest_merge_into_legacy_thread_keeps_an_estimated_first_date(tmp_path, monkeypatch):
    conn = store.connect(tmp_path / "t.db")
    topic = mail_ingest.ensure_topic(conn, "Placements", "Acme")
    store.upsert(
        conn,
        "mail_thread",
        {"source_id": "mail:thread:old", "title": "Old", "body": "b", "source_uids": ["old"]},
        title="Old",
        summary="s",
        source="mail:old",
    )
    store.add_edge(conn, topic, "mail:thread:old", "contains")
    created = store.get(conn, "mail:thread:old")["created_at"]

    _fake_llm(
        monkeypatch,
        {"action": "merge", "merge_into_id": "mail:thread:old", "summary": "s", "body": "b"},
    )
    mail_ingest.ingest_email(conn, _email("2", "Fri, 11 Sep 2026 09:00:00 +0000"), {})

    received = store.get(conn, "mail:thread:old")["data"]["received_at"]
    assert received == {"old": created, "2": "2026-09-11T09:00:00+00:00"}


# --- tree API and chat context ---------------------------------------------------------------


@pytest.fixture
def conn(tmp_path):
    connection = store.connect(tmp_path / "brain.db")
    yield connection
    connection.close()


def _seed_thread(conn, uid, title, events, received):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Acme")
    thread_id = f"mail:thread:{uid}"
    store.upsert(
        conn,
        "mail_thread",
        {
            "source_id": thread_id,
            "title": title,
            "body": "b",
            "source_uids": [uid],
            "received_at": {uid: received},
            "events": events,
        },
        title=title,
        summary="s",
        source=f"mail:{uid}",
    )
    store.add_edge(conn, topic, thread_id, "contains")
    # Real ingest indexes each event via mail_ingest._index_dated_item as it's produced (see
    # _ingest_message) — mirror that here so tests seeding events directly still populate the
    # index mail_ask._format_dated_items now reads from.
    for event in events:
        mail_ingest._index_dated_item(
            conn,
            event,
            thread_id=thread_id,
            thread_title=title,
            category="Placements",
            topic="Acme",
        )


def test_mail_tree_threads_carry_category_topic_and_dates(conn):
    _seed_thread(
        conn,
        "1",
        "Accenture OA",
        [_event("2026-09-14", kind="deadline")],
        "2026-09-10T09:00:00+00:00",
    )
    viz_server.app.dependency_overrides[viz_server.get_user_conn] = lambda: conn
    viz_server.app.dependency_overrides[brain_auth.get_current_user_id] = lambda: 1
    try:
        with TestClient(viz_server.app) as client:
            tree = client.get("/api/mail_tree").json()
    finally:
        viz_server.app.dependency_overrides.clear()

    thread = tree["children"][0]["children"][0]["children"][0]
    assert thread["category"] == "Placements"
    assert thread["topic"] == "Acme"
    assert thread["last_received"] == "2026-09-10T09:00:00+00:00"
    assert thread["received_estimated"] is False
    assert thread["events"][0]["kind"] == "deadline"


def test_dated_items_list_upcoming_and_overdue_but_not_old_events(conn):
    # Distinct uids per event: the dated-items index is keyed by source_uid globally (one entry
    # per real email, across the whole mailbox — see mail_ingest._index_dated_item), not scoped
    # per thread the way merge_events is, so events on different threads sharing a uid would
    # collide and overwrite each other in the index.
    _seed_thread(
        conn,
        "1",
        "Accenture OA",
        [_event("2026-09-14", kind="deadline", title="OA", uid="1")],
        "2026-09-10T09:00:00+00:00",
    )
    _seed_thread(
        conn,
        "2",
        "Scholarship",
        [_event("2026-09-09", kind="deadline", title="Form", uid="2")],
        "2026-09-01T09:00:00+00:00",
    )
    _seed_thread(
        conn,
        "3",
        "Fest",
        [_event("2026-06-01", title="Fest day", uid="3")],
        "2026-05-20T09:00:00+00:00",
    )

    text = mail_ask._format_dated_items(conn, TODAY)
    lines = text.splitlines()
    assert lines[0].startswith("  OVERDUE DEADLINE 2026-09-09 (2 days ago): Form")
    assert lines[1].startswith("  SOON DEADLINE 2026-09-14 (in 3 days): OA")
    assert "Fest day" not in text


def test_overview_shows_when_mail_arrived(conn):
    _seed_thread(conn, "1", "Accenture OA", [], "2026-09-10T09:00:00+00:00")
    overview = mail_ask._format_overview(mail_ask._walk_tree(conn))
    assert "Accenture OA (received 2026-09-10)" in overview
