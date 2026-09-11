"""brain/automation.py — natural-language automation rules over incoming mail/Slack messages.

"Notify me on Slack when a Placements email arrives" is parsed into a structured
{trigger_category, trigger_urgent_only, action} exactly once, at rule-creation time, via a
single LLM call — evaluating a rule against every ingested message afterwards is then pure
code with zero LLM cost, so this doesn't conflict with mail_ingest's offline mode: rules
authored while online keep firing correctly even with offline_mode on, since only their
authoring needed the model, not their evaluation.
"""

from __future__ import annotations

import json
import uuid
from typing import Any

from brain import store
from brain.openrouter import call_openrouter
from slack.client import SlackClient


def _strip_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        text = text.split("```", 2)[1]
        if text.startswith("json"):
            text = text[4:]
    return text.strip()


def parse_rule_text(text: str, known_categories: list[str]) -> dict[str, Any]:
    """The one LLM call this module ever makes — turns free text into a structured trigger."""
    cat_list = ", ".join(known_categories) or "(none yet)"
    prompt = (
        "Parse this automation rule into structured JSON. The rule describes when to send a "
        "Slack notification about incoming mail or Slack messages.\n\n"
        f"KNOWN CATEGORIES: {cat_list}\n\n"
        f"RULE TEXT: {text}\n\n"
        "Reply with ONLY this JSON object, nothing else:\n"
        '{"trigger_category": "<the best-matching known category, or empty if the rule '
        'applies to any category>", "trigger_urgent_only": true|false}'
    )
    return json.loads(_strip_fences(call_openrouter(prompt)))


def _public(rule: dict[str, Any]) -> dict[str, Any]:
    d = rule["data"]
    return {
        "id": rule["id"],
        "text": d.get("text"),
        "trigger_category": d.get("trigger_category") or None,
        "trigger_urgent_only": bool(d.get("trigger_urgent_only")),
        "enabled": d.get("enabled", True),
    }


def create_rule(conn: Any, text: str, known_categories: list[str]) -> dict[str, Any]:
    parsed = parse_rule_text(text, known_categories)
    rule_id = f"mail:rule:{uuid.uuid4().hex[:12]}"
    store.upsert(
        conn,
        "automation_rule",
        {
            "source_id": rule_id,
            "text": text,
            "trigger_category": (parsed.get("trigger_category") or "").strip() or None,
            "trigger_urgent_only": bool(parsed.get("trigger_urgent_only")),
            "action": "slack_notify",
            "enabled": True,
        },
        title=text,
        summary=text,
        source="user",
    )
    return _public(store.get(conn, rule_id))


def list_rules(conn: Any) -> list[dict[str, Any]]:
    return [_public(r) for r in store.all_of_type(conn, "automation_rule")]


def delete_rule(conn: Any, rule_id: str) -> bool:
    return store.delete(conn, rule_id)


def evaluate_and_notify(
    conn: Any, *, category: str | None, urgent: bool, title: str, channel: str
) -> list[str]:
    """Check every enabled rule against one just-ingested message; post a Slack notification
    per match. Called from mail_ingest._ingest_message after classification/urgency-flagging —
    pure code, no LLM. Returns the ids of rules that fired (mainly for tests)."""
    fired: list[str] = []
    for rule in store.all_of_type(conn, "automation_rule"):
        d = rule["data"]
        if not d.get("enabled", True):
            continue
        trigger_category = d.get("trigger_category")
        if trigger_category and trigger_category != category:
            continue
        if d.get("trigger_urgent_only") and not urgent:
            continue
        label = category or "Uncategorized"
        SlackClient().post(f":inbox_tray: New {label} message via {channel}: {title}")
        fired.append(rule["id"])
    return fired
