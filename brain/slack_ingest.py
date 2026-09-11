"""brain/slack_ingest.py — pull a Slack channel's history into the same knowledge tree as mail.

Mirrors brain/mail_ingest.py's fetch -> adapt -> ingest -> "mark read" shape (see run_iter
below), but for Slack instead of Gmail. Every message is adapted into the same
{uid, from, subject, body_text, attachments} shape mail_ingest._ingest_message expects and
ingested with channel="slack" — the classify/merge/topic pipeline itself is untouched (see
mail_ingest.py's docstring on why this is what makes cross-channel topic merging free).

The Slack bot token lives in console/backend's integrations store
(~/.hermes/console-integrations.json, written by console/backend/applications.py) — brain
reads the same file rather than importing console.backend (ADR-0002 forbids that import), the
same way brain/emailtool.py and console/backend both read/write under ~/.hermes/ without
either importing the other.
"""

from __future__ import annotations

import json
import os
from collections.abc import Iterator
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from brain import mail_ingest


def _integrations_path() -> Path:
    override = os.environ.get("CONSOLE_INTEGRATIONS_PATH")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".hermes" / "console-integrations.json"


def get_bot_token() -> str | None:
    """The Slack bot token, wherever it was configured — an env var override (matching
    slack/client.py's own convention) takes precedence over the console-connected one."""
    override = os.environ.get("SLACK_BOT_TOKEN")
    if override:
        return override
    path = _integrations_path()
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        token = data.get("slack_bot_token")
        return token if isinstance(token, str) and token else None
    except Exception:
        return None


def channel_status(conn: Any) -> dict[str, Any]:
    """Whether Slack ingestion can actually run right now: a bot token AND a channel to read."""
    token = get_bot_token()
    channel_id = mail_ingest.get_settings(conn).get("slack_channel_id") or os.environ.get(
        "SLACK_CHANNEL"
    )
    if not token:
        return {"connected": False, "reason": "no Slack bot token connected"}
    if not channel_id:
        return {"connected": False, "reason": "no channel configured to sync from"}
    return {"connected": True, "channel_id": channel_id}


def fetch_channel_messages(
    channel_id: str, token: str, oldest_ts: str | None = None
) -> list[dict[str, Any]]:
    """Real (non-system) messages in `channel_id` newer than `oldest_ts`, oldest first."""
    from slack_sdk import WebClient
    from slack_sdk.errors import SlackApiError

    client = WebClient(token=token)
    messages: list[dict[str, Any]] = []
    cursor: str | None = None
    try:
        while True:
            resp = client.conversations_history(
                channel=channel_id, oldest=oldest_ts, cursor=cursor, limit=200
            )
            messages.extend(resp.get("messages") or [])
            cursor = (resp.get("response_metadata") or {}).get("next_cursor") or None
            if not cursor:
                break
    except SlackApiError as exc:
        detail = exc.response.get("error", str(exc)) if exc.response is not None else str(exc)
        raise RuntimeError(f"Slack API error: {detail}") from exc

    # Slack returns newest-first; process oldest-first so thread merging sees earlier rounds
    # before later ones, same order Gmail's UNSEEN search already produces.
    messages.reverse()
    return [
        m
        for m in messages
        if m.get("type") == "message" and not m.get("subtype") and (m.get("text") or "").strip()
    ]


def _channel_name(token: str, channel_id: str) -> str:
    from slack_sdk import WebClient

    try:
        info = WebClient(token=token).conversations_info(channel=channel_id)
        return info["channel"]["name"]
    except Exception:
        return channel_id


def to_mail_shaped_message(slack_message: dict[str, Any], channel_name: str) -> dict[str, Any]:
    """Adapt one Slack message into the shape brain/mail_ingest.py's pipeline expects,
    regardless of channel — a Slack message has no subject line, so one is synthesized from
    the channel name plus the message's own opening words."""
    text = slack_message.get("text") or ""
    ts = slack_message["ts"]
    subject = f"#{channel_name}: " + " ".join(text.split()[:8])
    when = datetime.fromtimestamp(float(ts), tz=UTC)
    return {
        "uid": ts,
        "from": slack_message.get("user") or slack_message.get("bot_id") or "unknown",
        "subject": subject,
        "body_text": text,
        "date": when.strftime("%a, %d %b %Y %H:%M:%S +0000"),
        "attachments": [],  # Slack file attachments aren't downloaded yet — text only for now.
    }


def run_iter(
    conn: Any, channel_id: str | None = None, user_id: str | int | None = None
) -> Iterator[dict[str, Any]]:
    """Same shape as mail_ingest.run_iter: yields progress events, ends with {"stage": "done"}.

    Slack has no per-message "unread" flag like IMAP, so instead of marking messages read, the
    timestamp of the last-ingested message is saved as `slack_last_ts` in this user's settings
    and passed as `oldest` on the next sync — the Slack-native way to avoid reprocessing.
    """
    token = get_bot_token()
    if not token:
        yield {"stage": "failed", "error": "No Slack bot token connected."}
        return

    settings = mail_ingest.get_settings(conn)
    channel_id = channel_id or settings.get("slack_channel_id") or os.environ.get("SLACK_CHANNEL")
    if not channel_id:
        yield {"stage": "failed", "error": "No Slack channel configured to sync from."}
        return

    config = mail_ingest.load_config()
    yield {"stage": "connecting"}
    try:
        oldest_ts = settings.get("slack_last_ts")
        raw_messages = fetch_channel_messages(channel_id, token, oldest_ts=oldest_ts)
        channel_name = _channel_name(token, channel_id)
    except Exception as exc:
        yield {"stage": "failed", "error": str(exc)}
        return

    total = len(raw_messages)
    yield {"stage": "fetched", "total": total}

    results: list[dict[str, Any]] = []
    latest_ts = oldest_ts
    for index, raw in enumerate(raw_messages, start=1):
        message = to_mail_shaped_message(raw, channel_name)
        yield {
            "stage": "ingesting",
            "done": index - 1,
            "total": total,
            "subject": message["subject"],
        }
        try:
            result = mail_ingest._ingest_message(
                conn, message, config, user_id=user_id, channel="slack"
            )
        except (Exception, SystemExit) as exc:  # one bad message must not stop the whole sync
            result = {"uid": message["uid"], "error": str(exc)}
            results.append(result)
            yield {
                "stage": "ingested",
                "done": index,
                "total": total,
                "subject": message["subject"],
                "error": str(exc),
            }
            continue
        latest_ts = raw["ts"]
        results.append(result)
        yield {
            "stage": "ingested",
            "done": index,
            "total": total,
            "subject": message["subject"],
            "category": result.get("category"),
            "topic": result.get("topic"),
        }

    if latest_ts and latest_ts != oldest_ts:
        mail_ingest._update_settings(conn, slack_last_ts=latest_ts)

    yield {"stage": "done", "processed": len(results), "results": results}


def run(
    conn: Any, channel_id: str | None = None, user_id: str | int | None = None
) -> list[dict[str, Any]]:
    """Thin wrapper over run_iter for callers that just want the outcome."""
    results: list[dict[str, Any]] = []
    for event in run_iter(conn, channel_id, user_id=user_id):
        if event["stage"] == "done":
            results = event["results"]
    return results
