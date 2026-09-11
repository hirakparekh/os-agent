"""Tests for the brain's HTTP surface: auth gating, the review queue, and reclassification.

The per-user SQLite connection is injected via FastAPI's dependency_overrides so each test gets
its own throwaway database.
"""

import json

import pytest
from fastapi.testclient import TestClient

from brain import auth as brain_auth
from brain import mail_ingest, store, viz_server


@pytest.fixture
def conn(tmp_path):
    connection = store.connect(tmp_path / "brain.db")
    yield connection
    connection.close()


@pytest.fixture
def client(conn):
    """A client whose requests are already authenticated and bound to `conn`."""
    viz_server.app.dependency_overrides[viz_server.get_user_conn] = lambda: conn
    viz_server.app.dependency_overrides[brain_auth.get_current_user_id] = lambda: 1
    with TestClient(viz_server.app) as c:
        yield c
    viz_server.app.dependency_overrides.clear()


def _thread(conn, thread_id, title, topic_id, *, needs_review=False, classification=None):
    store.upsert(
        conn,
        "mail_thread",
        {
            "source_id": thread_id,
            "title": title,
            "body": "b",
            "source_uids": [thread_id.split(":")[-1]],
            **({"classification": classification} if classification else {}),
        },
        title=title,
        summary="s",
        source="mail",
        needs_review=needs_review,
    )
    store.add_edge(conn, topic_id, thread_id, "contains")


def test_endpoints_require_authentication():
    """No override here: the real bearer-token dependency must reject an anonymous request."""
    with TestClient(viz_server.app) as anonymous:
        assert anonymous.get("/api/mail/review").status_code == 401
        assert anonymous.get("/api/mail_tree").status_code == 401
        assert (
            anonymous.post(
                "/api/mail/reclassify", json={"thread_id": "x", "category": "y"}
            ).status_code
            == 401
        )


def test_review_lists_only_low_confidence_threads(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Yoga Competition")
    _thread(
        conn, "mail:thread:1", "Yoga Competition 2026", topic,
        needs_review=True,
        classification={"llm_category": "Placements", "keyword_category": "General College"},
    )
    confident = mail_ingest.ensure_topic(conn, "Placements", "Accenture")
    _thread(conn, "mail:thread:2", "Accenture Drive", confident)

    body = client.get("/api/mail/review").json()

    assert [t["name"] for t in body["threads"]] == ["Yoga Competition 2026"]
    item = body["threads"][0]
    assert item["category"] == "Placements"  # where it wrongly sits
    assert item["topic"] == "Yoga Competition"
    assert item["keyword_category"] == "General College"  # what the UI offers as the fix
    assert "Placements" in body["categories"]


def test_review_is_empty_when_nothing_is_flagged(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Accenture")
    _thread(conn, "mail:thread:9", "Accenture Drive", topic)
    assert client.get("/api/mail/review").json()["threads"] == []


def test_reclassify_moves_the_thread_and_clears_the_flag(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Yoga Competition")
    _thread(conn, "mail:thread:1", "Yoga Competition 2026", topic, needs_review=True)

    res = client.post(
        "/api/mail/reclassify",
        json={"thread_id": "mail:thread:1", "category": "General College"},
    )
    assert res.status_code == 200
    assert res.json()["topic_id"] == "mail:topic:general-college:yoga-competition"

    parents = store.neighbors(conn, "mail:thread:1", "contains", incoming=True)
    assert [p["id"] for p in parents] == ["mail:topic:general-college:yoga-competition"]
    assert store.get(conn, "mail:thread:1")["needs_review"] == 0
    # It drops off the review queue, which is the whole point of confirming it.
    assert client.get("/api/mail/review").json()["threads"] == []


def test_reclassify_prunes_the_emptied_branch(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Yoga Competition")
    _thread(conn, "mail:thread:1", "Yoga Competition 2026", topic)

    pruned = client.post(
        "/api/mail/reclassify",
        json={"thread_id": "mail:thread:1", "category": "General College"},
    ).json()["pruned"]

    # Placements held only that thread, so the whole branch goes rather than lingering as a
    # ghost category in the mail map.
    assert "mail:topic:placements:yoga-competition" in pruned
    assert "mail:cat:placements" in pruned
    assert store.get(conn, "mail:cat:placements") is None


def test_reclassify_teaches_the_classifier(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Yoga Competition")
    _thread(conn, "mail:thread:1", "Yoga Competition 2026", topic)

    learned = client.post(
        "/api/mail/reclassify",
        json={"thread_id": "mail:thread:1", "category": "General College"},
    ).json()["learned_keywords"]

    assert "yoga" in learned
    assert "2026" not in learned  # bare years are noise, not category signal
    assert "yoga" in mail_ingest.learned_keywords(conn)["General College"]


def test_reclassify_rejects_an_unknown_thread(client):
    res = client.post(
        "/api/mail/reclassify", json={"thread_id": "mail:thread:nope", "category": "X"}
    )
    assert res.status_code == 404


def test_reclassify_rejects_a_blank_category(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Yoga Competition")
    _thread(conn, "mail:thread:1", "Yoga Competition 2026", topic)
    res = client.post(
        "/api/mail/reclassify", json={"thread_id": "mail:thread:1", "category": "   "}
    )
    assert res.status_code == 400


def test_mail_tree_exposes_the_review_flag(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Yoga Competition")
    _thread(conn, "mail:thread:1", "Yoga Competition 2026", topic, needs_review=True)

    tree = client.get("/api/mail_tree").json()
    thread = tree["children"][0]["children"][0]["children"][0]
    assert thread["needs_review"] is True


def test_profile_starts_empty(client):
    body = client.get("/api/profile").json()
    assert body == {"details": [], "identifiers": []}


def test_profile_round_trips_and_reports_identifiers(client):
    res = client.put(
        "/api/profile",
        json={
            "details": [
                {"key": "Name", "value": "Adidev Anand"},
                {"key": "Timezone", "value": "IST"},
            ]
        },
    )
    assert res.status_code == 200
    # Only the identity-ish row is offered to attachment matching.
    assert res.json()["identifiers"] == ["Adidev Anand"]
    assert client.get("/api/profile").json()["details"] == [
        {"key": "Name", "value": "Adidev Anand"},
        {"key": "Timezone", "value": "IST"},
    ]


def test_profile_requires_authentication():
    with TestClient(viz_server.app) as anonymous:
        assert anonymous.get("/api/profile").status_code == 401
        assert anonymous.put("/api/profile", json={"details": []}).status_code == 401


def _stream_events(res):
    """Parse an NDJSON streaming response into a list of events."""
    return [json.loads(line) for line in res.text.splitlines() if line.strip()]


def test_reload_stream_emits_progress_per_email(client, monkeypatch):
    emails = [
        {"uid": "1", "from": "a@b.com", "to": "me@x.com", "subject": "Accenture drive",
         "body_text": "...", "attachments": []},
        {"uid": "2", "from": "a@b.com", "to": "me@x.com", "subject": "Yoga day",
         "body_text": "...", "attachments": []},
    ]
    monkeypatch.setattr(
        mail_ingest, "fetch_unread_emails", lambda since_minutes=None, user_id=None: emails
    )
    monkeypatch.setattr(mail_ingest, "mark_email_read", lambda uid, user_id=None: None)
    monkeypatch.setattr(
        mail_ingest, "classify_email",
        lambda e, f, c: {"category": "Placements", "new_category": True,
                         "topic": "T", "new_topic": True},
    )
    monkeypatch.setattr(
        mail_ingest, "merge_or_create_thread",
        lambda e, f, x: {"action": "new", "merge_into_id": None, "summary": "s", "body": "b"},
    )

    res = client.post("/api/mail/reload/stream", json={"since_minutes": 60})
    assert res.status_code == 200
    assert res.headers["content-type"].startswith("application/x-ndjson")

    events = _stream_events(res)
    assert events[0]["stage"] == "connecting"
    assert events[1] == {"stage": "fetched", "total": 2}
    assert [e["done"] for e in events if e["stage"] == "ingested"] == [1, 2]
    assert events[-1]["stage"] == "done"
    assert events[-1]["processed"] == 2


def test_reload_stream_reports_failure_as_a_terminal_event(client, monkeypatch):
    """The response is already 200 by the time a mid-stream failure happens, so the error has
    to travel in-band rather than as a status code."""
    def _boom(since_minutes=None, user_id=None):
        raise SystemExit("emailtool.py list failed: no mailbox connected")

    monkeypatch.setattr(mail_ingest, "fetch_unread_emails", _boom)

    res = client.post("/api/mail/reload/stream", json={"since_minutes": 60})
    assert res.status_code == 200
    final = _stream_events(res)[-1]
    assert final["stage"] == "failed"
    assert "no mailbox connected" in final["error"]


def test_reload_stream_requires_authentication():
    with TestClient(viz_server.app) as anonymous:
        res = anonymous.post("/api/mail/reload/stream", json={"since_minutes": 60})
        assert res.status_code == 401


def test_needs_attention_lists_only_urgent_threads(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Accenture")
    store.upsert(
        conn, "mail_thread",
        {"source_id": "mail:thread:1", "title": "Urgent!", "body": "b",
         "source_uids": ["1"], "urgent": True},
        title="Urgent!", summary="s", source="mail",
    )
    store.add_edge(conn, topic, "mail:thread:1", "contains")
    store.upsert(
        conn, "mail_thread",
        {"source_id": "mail:thread:2", "title": "Calm", "body": "b",
         "source_uids": ["2"], "urgent": False},
        title="Calm", summary="s", source="mail",
    )
    store.add_edge(conn, topic, "mail:thread:2", "contains")

    res = client.get("/api/needs-attention")
    assert res.status_code == 200
    names = [t["name"] for t in res.json()["threads"]]
    assert names == ["Urgent!"]


def test_action_items_flattens_across_threads(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Accenture")
    store.upsert(
        conn, "mail_thread",
        {"source_id": "mail:thread:1", "title": "T1", "body": "b", "source_uids": ["1"],
         "action_items": [{"text": "submit resume by Friday"}]},
        title="T1", summary="s", source="mail",
    )
    store.add_edge(conn, topic, "mail:thread:1", "contains")

    res = client.get("/api/action-items")
    assert res.status_code == 200
    items = res.json()["items"]
    assert len(items) == 1
    assert items[0]["text"] == "submit resume by Friday"
    assert items[0]["thread_id"] == "mail:thread:1"


def test_analytics_category_volume_buckets_by_day(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Accenture")
    store.upsert(
        conn, "mail_thread",
        {"source_id": "mail:thread:1", "title": "T1", "body": "b", "source_uids": ["1"]},
        title="T1", summary="s", source="mail",
    )
    store.add_edge(conn, topic, "mail:thread:1", "contains")

    res = client.get("/api/analytics/category-volume")
    assert res.status_code == 200
    body = res.json()
    assert body["bucket"] == "day"
    assert len(body["points"]) == 1
    point = body["points"][0]
    assert point["category"] == "Placements"
    assert point["count"] == 1


def test_analytics_category_volume_rejects_an_invalid_bucket(client):
    res = client.get("/api/analytics/category-volume?bucket=month")
    assert res.status_code == 400


def test_mail_tree_export_renders_markdown_with_category_topic_and_thread(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Accenture")
    store.upsert(
        conn, "mail_thread",
        {"source_id": "mail:thread:1", "title": "Interview shortlist", "body": "b",
         "source_uids": ["1"], "channel": "slack"},
        title="Interview shortlist", summary="Shortlisted for round 1.", source="mail",
    )
    store.add_edge(conn, topic, "mail:thread:1", "contains")

    res = client.get("/api/mail_tree/export")
    assert res.status_code == 200
    assert res.headers["content-type"].startswith("text/markdown")
    assert 'filename="knowledge-tree.md"' in res.headers["content-disposition"]

    text = res.text
    assert "## Placements" in text
    assert "### Accenture" in text
    assert "Interview shortlist" in text
    assert "Shortlisted for round 1." in text


def test_mail_tree_export_requires_authentication():
    with TestClient(viz_server.app) as anonymous:
        assert anonymous.get("/api/mail_tree/export").status_code == 401


def _touch(conn, thread_id, *, created_at, updated_at):
    """Force a thread's timestamps — the pipeline sets them, so tests must forge them to
    exercise time filtering deterministically."""
    conn.execute(
        "UPDATE entities SET created_at = ?, updated_at = ? WHERE id = ?",
        (created_at, updated_at, thread_id),
    )
    conn.commit()


def _urgent_thread(conn, thread_id, title, topic_id, *, action_text="submit form by Friday"):
    store.upsert(
        conn, "mail_thread",
        {"source_id": thread_id, "title": title, "body": "b", "source_uids": [thread_id[-1]],
         "urgent": True, "action_items": [{"text": action_text}]},
        title=title, summary="s", source="mail",
    )
    store.add_edge(conn, topic_id, thread_id, "contains")


def test_needs_attention_since_filters_on_update_time(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Accenture")
    _urgent_thread(conn, "mail:thread:1", "Old and quiet", topic)
    _urgent_thread(conn, "mail:thread:2", "Just became urgent", topic)
    _touch(conn, "mail:thread:1", created_at="2026-09-01T00:00:00+00:00",
           updated_at="2026-09-01T00:00:00+00:00")
    # Created long ago but touched just now — exactly the case a poller must still catch.
    _touch(conn, "mail:thread:2", created_at="2026-09-01T00:00:00+00:00",
           updated_at="2026-09-10T12:00:00+00:00")

    everything = client.get("/api/needs-attention").json()["threads"]
    assert {t["name"] for t in everything} == {"Old and quiet", "Just became urgent"}

    recent = client.get("/api/needs-attention?since=2026-09-05T00:00:00+00:00").json()["threads"]
    assert [t["name"] for t in recent] == ["Just became urgent"]


def test_action_items_since_filters_the_same_way(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Accenture")
    _urgent_thread(conn, "mail:thread:1", "Old", topic, action_text="submit old form by Friday")
    _urgent_thread(conn, "mail:thread:2", "New", topic, action_text="reply by Wednesday")
    _touch(conn, "mail:thread:1", created_at="2026-09-01T00:00:00+00:00",
           updated_at="2026-09-01T00:00:00+00:00")
    _touch(conn, "mail:thread:2", created_at="2026-09-01T00:00:00+00:00",
           updated_at="2026-09-10T12:00:00+00:00")

    assert len(client.get("/api/action-items").json()["items"]) == 2
    recent = client.get("/api/action-items?since=2026-09-05T00:00:00+00:00").json()["items"]
    assert [i["text"] for i in recent] == ["reply by Wednesday"]


def test_since_is_optional_so_existing_callers_are_unaffected(client, conn):
    topic = mail_ingest.ensure_topic(conn, "Placements", "Accenture")
    _urgent_thread(conn, "mail:thread:1", "Anything", topic)
    assert len(client.get("/api/needs-attention").json()["threads"]) == 1
    assert len(client.get("/api/action-items").json()["items"]) == 1


def test_feeds_expose_updated_at_for_client_side_cursors(client, conn):
    """The poller needs a value it can send back as `since` next time."""
    topic = mail_ingest.ensure_topic(conn, "Placements", "Accenture")
    _urgent_thread(conn, "mail:thread:1", "Anything", topic)
    assert client.get("/api/needs-attention").json()["threads"][0]["updated_at"]
    assert client.get("/api/action-items").json()["items"][0]["updated_at"]
