"""Tests for brain/slack_ingest.py: the Slack-message adapter and sync loop.

Network-free: slack_sdk itself is never exercised — fetch_channel_messages and _channel_name
are monkeypatched, since their job (paginating conversations_history) is Slack's contract to
keep, not ours to test. What's ours to test: the message shape adapter, the last-synced-ts
bookkeeping, and that ingestion rides the same channel-agnostic pipeline mail uses.
"""

from __future__ import annotations

from brain import mail_ingest, slack_ingest, store


def _conn(tmp_path):
    return store.connect(tmp_path / "t.db")


def test_to_mail_shaped_message_synthesizes_a_subject_and_date():
    raw = {"ts": "1700000000.000100", "user": "U123", "text": "standup notes: shipped the fix"}
    message = slack_ingest.to_mail_shaped_message(raw, "engineering")

    assert message["uid"] == "1700000000.000100"
    assert message["from"] == "U123"
    assert message["subject"] == "#engineering: standup notes: shipped the fix"
    assert message["body_text"] == "standup notes: shipped the fix"
    assert message["attachments"] == []
    assert message["date"].startswith("Tue, 14 Nov 2023")


def test_fetch_channel_messages_drops_system_messages_and_reverses_order(monkeypatch):
    calls = {"n": 0}

    class _FakeClient:
        def __init__(self, token):
            pass

        def conversations_history(self, channel, oldest, cursor, limit):
            calls["n"] += 1
            return {
                "messages": [
                    {"type": "message", "text": "second", "ts": "2"},
                    {"type": "message", "subtype": "channel_join", "text": "joined", "ts": "1.5"},
                    {"type": "message", "text": "", "ts": "1.2"},  # blank text, dropped
                    {"type": "message", "text": "first", "ts": "1"},
                ],
                "response_metadata": {},
            }

    monkeypatch.setattr("slack_sdk.WebClient", _FakeClient)
    messages = slack_ingest.fetch_channel_messages("C1", "xoxb-fake")

    assert [m["ts"] for m in messages] == ["1", "2"]
    assert calls["n"] == 1


def test_channel_status_reports_missing_token_and_missing_channel(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    monkeypatch.setattr(slack_ingest, "get_bot_token", lambda: None)
    monkeypatch.delenv("SLACK_CHANNEL", raising=False)
    assert slack_ingest.channel_status(conn)["connected"] is False

    monkeypatch.setattr(slack_ingest, "get_bot_token", lambda: "xoxb-fake")
    assert slack_ingest.channel_status(conn)["connected"] is False

    mail_ingest.set_slack_channel(conn, "C123")
    status = slack_ingest.channel_status(conn)
    assert status == {"connected": True, "channel_id": "C123"}


def test_run_iter_ingests_via_the_shared_pipeline_and_saves_last_ts(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    mail_ingest.set_slack_channel(conn, "C123")
    monkeypatch.setattr(slack_ingest, "get_bot_token", lambda: "xoxb-fake")
    monkeypatch.setattr(slack_ingest, "_channel_name", lambda token, channel_id: "general")
    monkeypatch.setattr(
        slack_ingest,
        "fetch_channel_messages",
        lambda channel_id, token, oldest_ts=None: [
            {"ts": "1700000000.000100", "user": "U1", "text": "Placements: interview shortlisted"},
        ],
    )
    monkeypatch.setattr(
        mail_ingest,
        "classify_email",
        lambda message, findings, categories: {
            "category": "Placements",
            "new_category": True,
            "topic": "T",
            "new_topic": True,
        },
    )
    monkeypatch.setattr(
        mail_ingest,
        "merge_or_create_thread",
        lambda message, findings, existing: {
            "action": "new",
            "merge_into_id": None,
            "summary": "s",
            "body": "b",
        },
    )

    events = list(slack_ingest.run_iter(conn))

    done = next(e for e in events if e["stage"] == "done")
    assert done["processed"] == 1
    result = done["results"][0]
    assert result["channel"] == "slack"
    assert result["thread_id"] == "mail:thread:slack:1700000000.000100"

    assert mail_ingest.get_settings(conn)["slack_last_ts"] == "1700000000.000100"


def test_run_iter_fails_gracefully_with_no_token(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    monkeypatch.setattr(slack_ingest, "get_bot_token", lambda: None)

    events = list(slack_ingest.run_iter(conn))

    assert events == [{"stage": "failed", "error": "No Slack bot token connected."}]
