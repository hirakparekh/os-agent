"""Tests for brain/automation.py: rule authoring (one mocked LLM call) and evaluation (pure
code, no LLM) against ingested messages."""

from __future__ import annotations

from brain import automation, store


def _conn(tmp_path):
    return store.connect(tmp_path / "t.db")


def test_create_rule_parses_text_via_one_llm_call_and_persists(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    monkeypatch.setattr(
        automation, "call_openrouter",
        lambda prompt: '{"trigger_category": "Placements", "trigger_urgent_only": false}',
    )

    rule = automation.create_rule(
        conn, "notify me on Slack when a Placements email arrives", ["Placements", "Lectures"]
    )

    assert rule["trigger_category"] == "Placements"
    assert rule["trigger_urgent_only"] is False
    assert rule["enabled"] is True
    assert automation.list_rules(conn) == [rule]


def test_create_rule_tolerates_fenced_json(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    monkeypatch.setattr(
        automation, "call_openrouter",
        lambda prompt: '```json\n{"trigger_category": "", "trigger_urgent_only": true}\n```',
    )

    rule = automation.create_rule(conn, "urgent things", [])
    assert rule["trigger_category"] is None
    assert rule["trigger_urgent_only"] is True


def test_delete_rule_removes_it(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    monkeypatch.setattr(
        automation, "call_openrouter",
        lambda prompt: '{"trigger_category": "", "trigger_urgent_only": false}',
    )
    rule = automation.create_rule(conn, "anything", [])
    assert automation.delete_rule(conn, rule["id"]) is True
    assert automation.list_rules(conn) == []


def test_evaluate_and_notify_fires_only_matching_enabled_rules(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    posted = []
    monkeypatch.setattr(
        automation, "SlackClient",
        lambda: type("F", (), {"post": lambda self, text: posted.append(text)})(),
    )

    def _make(category, urgent_only):
        payload = (
            f'{{"trigger_category": "{category}", '
            f'"trigger_urgent_only": {str(urgent_only).lower()}}}'
        )
        monkeypatch.setattr(automation, "call_openrouter", lambda prompt: payload)
        return automation.create_rule(conn, "r", [category] if category else [])

    placements_rule = _make("Placements", False)
    urgent_only_rule = _make("", True)

    fired = automation.evaluate_and_notify(
        conn, category="Placements", urgent=False, title="Interview shortlist", channel="gmail"
    )
    assert fired == [placements_rule["id"]]
    assert len(posted) == 1

    posted.clear()
    fired = automation.evaluate_and_notify(
        conn, category="General College", urgent=True, title="Yoga event", channel="slack"
    )
    assert fired == [urgent_only_rule["id"]]
    assert len(posted) == 1


def test_evaluate_and_notify_skips_disabled_rules(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    monkeypatch.setattr(
        automation, "call_openrouter",
        lambda prompt: '{"trigger_category": "", "trigger_urgent_only": false}',
    )
    rule = automation.create_rule(conn, "anything", [])
    disabled_data = {
        **store.get(conn, rule["id"])["data"], "enabled": False, "source_id": rule["id"],
    }
    store.upsert(
        conn, "automation_rule", disabled_data,
        title="anything", summary="anything", source="user",
    )

    posted = []
    monkeypatch.setattr(
        automation, "SlackClient",
        lambda: type("F", (), {"post": lambda self, text: posted.append(text)})(),
    )
    fired = automation.evaluate_and_notify(
        conn, category="Placements", urgent=False, title="x", channel="gmail"
    )
    assert fired == []
    assert posted == []
