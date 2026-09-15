"""brain/viz_server.py — the brain's HTTP surface.

Everything the React console (console/frontend) talks to: the mail/Slack knowledge tree and its
ingest pipelines, Gmail + Google Calendar OAuth, the review queue and reclassification, urgency /
action-item worklists, analytics, automation rules, and the Markdown tree export.

    uv run uvicorn brain.viz_server:app --port 8080
"""

from __future__ import annotations

import html
import json
import logging
import os
import sqlite3
from collections.abc import Iterator
from datetime import datetime
from pathlib import Path
from typing import Annotated, Any

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel

from brain import (
    automation,
    calendar_tool,
    mail_ask,
    mail_ingest,
    mail_timeline,
    oauth_flow,
    profile,
    slack_ingest,
    store,
)
from brain.auth import CurrentUser
from brain.emailtool import _token_path, mailbox_status

# Uvicorn configures only its own loggers, so anything an application module logs at INFO is
# dropped on the floor. The ask path logs its retrieval decision and BM25 score there — that is
# the data the follow-up threshold is tuned from, so it has to actually reach the log.
logging.basicConfig(level=logging.INFO, format="%(levelname)s:     %(name)s %(message)s")

app = FastAPI(title="Agent OS Brain - Viz")
HERE = Path(__file__).resolve().parent


def get_user_conn(user: CurrentUser) -> Iterator[sqlite3.Connection]:
    """Per-request connection to *this user's own* SQLite file — the actual isolation
    boundary (see brain/store.py's connect()). Every endpoint except the unauthenticated
    legacy pages (GET /, GET /mail-tree) depends on this instead of calling store.connect()
    directly."""
    conn = store.connect(user_id=user)
    try:
        yield conn
    finally:
        conn.close()


ConnDep = Annotated[sqlite3.Connection, Depends(get_user_conn)]

# Lets the console frontend (a separate Vite dev server / origin) call this API directly.
_origins = os.environ.get("BRAIN_CORS_ORIGINS", "http://localhost:5173").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in _origins if o.strip()],
    allow_methods=["*"],
    allow_headers=["*"],
)


def _mail_children(conn: Any, parent_id: str) -> list[dict[str, Any]]:
    return [
        n
        for n in store.neighbors(conn, parent_id, "contains")
        if n["type"] in ("mail_category", "mail_topic", "mail_thread")
    ]


def _mail_node(
    conn: Any, node: dict[str, Any], category: str | None = None, topic: str | None = None
) -> dict[str, Any]:
    if node["type"] == "mail_category":
        category = node["title"]
    elif node["type"] == "mail_topic":
        topic = node["title"]
    children = [_mail_node(conn, c, category, topic) for c in _mail_children(conn, node["id"])]
    out: dict[str, Any] = {
        "id": node["id"],
        "name": node["title"],
        "type": node["type"],
        "summary": node.get("summary"),
        # Set when the classifier wasn't sure which category this belonged in — the UI flags
        # these so a wrong call is findable instead of silently wrong.
        "needs_review": bool(node.get("needs_review")),
    }
    if node["type"] == "mail_thread":
        out["body"] = node["data"].get("body")
        out["source_uids"] = node["data"].get("source_uids") or []
        out["classification"] = node["data"].get("classification")
        out["channel"] = node["data"].get("channel", "gmail")
        # Carried on the thread itself because the console's time view regroups threads by
        # date, where the category/topic are no longer the thread's ancestors.
        out["category"] = category
        out["topic"] = topic
        out.update(mail_timeline.thread_timeline(node))
    if children:
        out["children"] = children
    return out


def _mail_tree_json(conn: Any) -> dict[str, Any]:
    categories = store.all_of_type(conn, "mail_category")
    return {
        "id": "mail:root",
        "name": "Mail",
        "type": "root",
        "children": [_mail_node(conn, c) for c in categories],
    }


@app.get("/api/mail_tree")
def mail_tree(conn: ConnDep) -> dict[str, Any]:
    """The mail knowledge tree (mail_category -> mail_topic -> mail_thread) as nested JSON,
    rooted under a synthetic "Mail" node so the page always has a single root to render."""
    return _mail_tree_json(conn)


_CHANNEL_BADGE = {"gmail": "\U0001f4e7", "slack": "\U0001f4ac"}


def _mail_tree_markdown(node: dict[str, Any], depth: int = 0) -> str:
    """Render the same tree /api/mail_tree serves as human-readable Markdown — a category
    becomes a ##, a topic a ###, and a thread a bullet with its summary and source channel."""
    lines: list[str] = []
    node_type = node.get("type")
    if node_type == "mail_category":
        lines.append(f"## {node['name']}\n")
    elif node_type == "mail_topic":
        lines.append(f"### {node['name']}\n")
    elif node_type == "mail_thread":
        badge = _CHANNEL_BADGE.get(node.get("channel", "gmail"), "")
        flag = " ⚠️ needs review" if node.get("needs_review") else ""
        summary = node.get("summary") or "(no summary)"
        lines.append(f"- {badge} **{node['name']}**{flag} — {summary}\n")

    for child in node.get("children") or []:
        lines.append(_mail_tree_markdown(child, depth + 1))
    return "".join(lines)


@app.get("/api/mail_tree/export")
def mail_tree_export(conn: ConnDep) -> Any:
    """The knowledge tree as a downloadable, plain-text-readable Markdown file — opens in any
    editor, renders on GitHub, no app required to read it."""
    tree = _mail_tree_json(conn)
    body = f"# Mail Knowledge Tree\n\n{_mail_tree_markdown(tree)}"
    return StreamingResponse(
        iter([body]),
        media_type="text/markdown",
        headers={"Content-Disposition": 'attachment; filename="knowledge-tree.md"'},
    )


class MailReloadRequest(BaseModel):
    since_minutes: int


@app.post("/api/mail/reload")
def mail_reload(body: MailReloadRequest, user: CurrentUser, conn: ConnDep) -> dict[str, Any]:
    """Ingest unread mail from the last `since_minutes` minutes into the caller's own tree."""
    # `conn` (the injected per-request connection) is what actually gets written to — `user_id`
    # is passed separately only for the real IMAP fetch/mark-read, which has no test-injectable
    # seam of its own. Deriving the SQLite connection from `user_id` here instead of using `conn`
    # was the bug: a test overriding `get_user_conn` to an isolated tmp database while faking
    # `get_current_user_id` to a real id still ended up writing to that real id's production
    # file, because `mail_ingest.run` fell back to `store.connect(user_id=...)` whenever `conn`
    # was omitted.
    results = mail_ingest.run(conn, since_minutes=body.since_minutes, user_id=user)
    return {"processed": len(results), "results": results}


@app.post("/api/mail/reload/stream")
def mail_reload_stream(
    body: MailReloadRequest, user: CurrentUser, conn: ConnDep
) -> StreamingResponse:
    """Ingest unread mail, streaming one NDJSON progress event per step.

    Same work as /api/mail/reload, but the caller finds out what is happening while it happens
    — a batch of ten emails is twenty-odd LLM round-trips, and a single blocking request tells
    the UI nothing until it is over.
    """

    def events() -> Iterator[str]:
        try:
            # See mail_reload's comment: pass `conn` explicitly rather than letting run_iter
            # re-derive its own connection from `user_id`.
            for event in mail_ingest.run_iter(conn, since_minutes=body.since_minutes, user_id=user):
                yield json.dumps(event) + "\n"
        except (Exception, SystemExit) as exc:
            # A failure mid-stream still has to reach the client: the response is already 200
            # by the time it happens, so it travels as a terminal event, not a status code.
            yield json.dumps({"stage": "failed", "error": str(exc)}) + "\n"

    return StreamingResponse(
        events(),
        media_type="application/x-ndjson",
        # Stops a proxy buffering the whole response and defeating the point of streaming.
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/api/slack/status")
def slack_ingest_status(conn: ConnDep) -> dict[str, Any]:
    """Whether Slack ingestion can run right now (bot token connected + a channel configured)."""
    return slack_ingest.channel_status(conn)


@app.post("/api/slack/reload")
def slack_reload(user: CurrentUser, conn: ConnDep) -> dict[str, Any]:
    """Ingest new messages from the configured Slack channel into the caller's own tree."""
    results = slack_ingest.run(conn, user_id=user)
    return {"processed": len(results), "results": results}


@app.post("/api/slack/reload/stream")
def slack_reload_stream(user: CurrentUser, conn: ConnDep) -> StreamingResponse:
    """Same work as /api/slack/reload, streamed — same NDJSON shape as /api/mail/reload/stream."""

    def events() -> Iterator[str]:
        try:
            for event in slack_ingest.run_iter(conn, user_id=user):
                yield json.dumps(event) + "\n"
        except (Exception, SystemExit) as exc:
            yield json.dumps({"stage": "failed", "error": str(exc)}) + "\n"

    return StreamingResponse(
        events(),
        media_type="application/x-ndjson",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/api/mail/status")
def mail_status(user: CurrentUser) -> dict[str, Any]:
    """Whether this user's mailbox can actually be authenticated as.

    Checks the credentials really load and refresh rather than that a file exists — a token
    can be present and still be revoked, expired past refresh, or never have been a real
    grant, and reporting those as "connected" only defers the failure to the next fetch.
    """
    return mailbox_status(user)


@app.post("/api/mail/disconnect")
def mail_disconnect(user: CurrentUser) -> dict[str, Any]:
    """Revoke this user's cached OAuth token so their mailbox needs to be reconnected."""
    token_path = _token_path(user)
    if token_path.exists():
        token_path.unlink()
    meta = token_path.with_name("meta.json")
    if meta.exists():
        meta.unlink()  # the cached mailbox address belongs to the grant being revoked
    return mailbox_status(user)


@app.post("/api/mail/connect")
def mail_connect(user: CurrentUser) -> Any:
    """Start Gmail consent: returns the Google URL for the caller's own browser to visit.

    This no longer blocks on consent. It used to open a consent window on the *server* via
    InstalledAppFlow.run_local_server, which only worked while the server and the browser were
    the same machine — the single thing that made this app impossible to host. The browser now
    completes consent at Google and is redirected to /api/oauth/callback; the client polls
    /api/mail/status to see it land.
    """
    try:
        return {"auth_url": oauth_flow.build_auth_url("gmail", user)}
    except oauth_flow.OAuthFlowError as exc:
        return JSONResponse(status_code=502, content={"error": str(exc)})


@app.get("/api/calendar/status")
def calendar_status(user: CurrentUser) -> dict[str, Any]:
    """Whether this user's Google Calendar can actually be read right now."""
    return calendar_tool.calendar_status(user)


@app.post("/api/calendar/disconnect")
def calendar_disconnect(user: CurrentUser) -> dict[str, Any]:
    """Revoke this user's cached Calendar OAuth token."""
    calendar_tool.disconnect(user)
    return calendar_tool.calendar_status(user)


@app.post("/api/calendar/connect")
def calendar_connect(user: CurrentUser) -> Any:
    """Start Calendar consent — same redirect shape as /api/mail/connect."""
    try:
        return {"auth_url": oauth_flow.build_auth_url("calendar", user)}
    except oauth_flow.OAuthFlowError as exc:
        return JSONResponse(status_code=502, content={"error": str(exc)})


def _callback_page(title: str, detail: str) -> HTMLResponse:
    """The page Google's redirect lands on. It is the user's own browser tab, not the app, so
    it gets plain HTML telling them to go back — never JSON.

    `detail` (and sometimes `title`) can carry request-derived text — the `error` query param
    from oauth_callback, or an OAuthFlowError's message — so both are HTML-escaped before
    interpolation. Unescaped, a crafted callback URL like `?error=<script>...` would execute
    in this app's own origin when a victim opens the link.
    """
    title = html.escape(title)
    detail = html.escape(detail)
    return HTMLResponse(
        f"""<!doctype html><meta charset="utf-8">
<title>{title}</title>
<style>body{{font:16px/1.6 system-ui,sans-serif;margin:12vh auto;max-width:32rem;padding:0 1.5rem;
color:#0f172a}}h1{{font-size:1.25rem;margin:0 0 .5rem}}p{{color:#475569;margin:0}}</style>
<h1>{title}</h1><p>{detail}</p>"""
    )


@app.get("/api/oauth/callback")
def oauth_callback(state: str = "", code: str = "", error: str = "") -> Any:
    """Where Google sends the user back after consent.

    Deliberately unauthenticated: it is a browser redirect from Google and cannot carry a
    bearer token. `state` is a JWT this server signed at the start of the flow, so it both
    identifies the user and proves the callback wasn't forged (see brain/oauth_flow.py).
    """
    if error:
        return _callback_page(
            "Connection cancelled", f"Google reported: {error}. You can close this tab."
        )
    if not (state and code):
        return _callback_page(
            "Something went wrong",
            "That link is missing its state or code. Try connecting again.",
        )
    try:
        _user_id, service = oauth_flow.complete(state, code)
    except oauth_flow.OAuthFlowError as exc:
        return _callback_page(
            "Could not finish connecting", f"{exc} You can close this tab and try again."
        )
    label = "Gmail" if service == "gmail" else "Google Calendar"
    return _callback_page(f"{label} connected", "You can close this tab and return to Agent OS.")


@app.get("/api/calendar/events")
def calendar_events(user: CurrentUser) -> dict[str, Any]:
    """Upcoming events on the user's primary calendar, for the chat context and a dashboard
    widget. 502s with a clear reason rather than 500ing when the token is stale/missing."""
    try:
        events = calendar_tool.list_upcoming_events(user)
    except Exception as exc:
        return JSONResponse(status_code=502, content={"events": [], "error": str(exc)})
    return {"events": events}


class UndoCalendarEventRequest(BaseModel):
    # The mail thread this event was auto-created from, so its bookkeeping (mail_ingest.py's
    # calendar_events list, used to avoid double-booking on a re-ingest) can be cleaned up too.
    thread_id: str | None = None


@app.post("/api/calendar/events/{event_id}/undo")
def calendar_undo_event(
    event_id: str, body: UndoCalendarEventRequest, user: CurrentUser, conn: ConnDep
) -> dict[str, Any]:
    """Delete a calendar event the mail pipeline just auto-created — the "Undo" side of the
    popup shown right after a mail sync."""
    try:
        calendar_tool.delete_event(user, event_id)
    except Exception as exc:
        return JSONResponse(status_code=502, content={"undone": False, "error": str(exc)})

    if body.thread_id:
        thread = store.get(conn, body.thread_id)
        if thread:
            existing = thread["data"].get("calendar_events") or []
            remaining = [e for e in existing if e.get("event_id") != event_id]
            if len(remaining) != len(existing):
                store.upsert(
                    conn,
                    "mail_thread",
                    {**thread["data"], "source_id": body.thread_id, "calendar_events": remaining},
                    title=thread["title"],
                    summary=thread["summary"],
                    source=thread.get("source"),
                )
    return {"undone": True}


class ProfileDetail(BaseModel):
    key: str
    value: str


class MailAskRequest(BaseModel):
    question: str
    profile_details: list[ProfileDetail] = []
    # Which conversation this question belongs to, so a follow-up can be answered from the
    # thread the session is already about. Optional: a caller that omits it gets the old
    # one-shot behaviour.
    session_id: int | None = None


@app.post("/api/mail/ask")
def mail_ask_endpoint(body: MailAskRequest, conn: ConnDep, user: CurrentUser) -> Any:
    """Natural-language question over the caller's own ingested mail tree -> plain-text answer.

    `user` is passed on purely so the prompt can include this user's live calendar events —
    the mail side rides `conn`, which is already per-user."""
    details = [d.model_dump() for d in body.profile_details]
    try:
        return mail_ask.ask_mail(
            conn, body.question, details, user_id=user, session_id=body.session_id
        )
    except SystemExit as exc:
        # call_openrouter raises SystemExit when every OPENROUTER_API_KEYS entry is
        # exhausted/rejected.
        return JSONResponse(status_code=502, content={"error": str(exc)})


class ProfileDetailIn(BaseModel):
    key: str
    value: str = ""


class ProfileUpdate(BaseModel):
    details: list[ProfileDetailIn] = []


@app.get("/api/profile")
def get_profile(conn: ConnDep) -> dict[str, Any]:
    """This user's "About you" details, plus which of them the mail pipeline treats as
    identifiers when scanning attachments."""
    details = profile.load_profile(conn)
    return {"details": details, "identifiers": profile.identifiers_from_profile(details)}


@app.put("/api/profile")
def put_profile(body: ProfileUpdate, conn: ConnDep) -> dict[str, Any]:
    """Replace the stored profile. Stored server-side rather than in the browser because mail
    ingestion — which is where attachments are scanned — runs headless.

    Changing the identifiers re-scans already-ingested attachments: findings are frozen at
    ingest, so adding your roll number afterwards would otherwise leave every shortlist that
    arrived earlier still claiming you are not on it.
    """
    before = set(profile.identifiers_from_profile(profile.load_profile(conn)))
    saved = profile.save_profile(conn, [d.model_dump() for d in body.details])
    identifiers = profile.identifiers_from_profile(saved)

    rescanned: list[dict[str, Any]] = []
    if set(identifiers) != before:
        rescanned = mail_ingest.rescan_attachments(conn, mail_ingest.load_config())

    return {"details": saved, "identifiers": identifiers, "rescanned": rescanned}


@app.post("/api/mail/attachments/rescan")
def mail_rescan_attachments(conn: ConnDep) -> dict[str, Any]:
    """Re-check every cached attachment against the current identifiers, on demand."""
    changed = mail_ingest.rescan_attachments(conn, mail_ingest.load_config())
    return {"changed": changed}


class SettingsUpdate(BaseModel):
    offline_mode: bool


@app.get("/api/settings")
def get_settings(conn: ConnDep) -> dict[str, Any]:
    """This user's saved pipeline settings, filled in with defaults for anything unset."""
    config = mail_ingest.config_with_settings(conn, mail_ingest.load_config())
    settings = mail_ingest.get_settings(conn)
    return {
        "offline_mode": bool(config.get("offline_mode")),
        "slack_channel_id": settings.get("slack_channel_id") or "",
    }


@app.put("/api/settings")
def put_settings(body: SettingsUpdate, conn: ConnDep) -> dict[str, Any]:
    """Toggle offline mode: when on, mail ingest never calls the LLM (see
    brain/mail_ingest.py's config_with_settings / _offline_merge_or_create_thread)."""
    return mail_ingest.set_offline_mode(conn, body.offline_mode)


class SlackChannelUpdate(BaseModel):
    channel_id: str


@app.put("/api/slack/channel")
def put_slack_channel(body: SlackChannelUpdate, conn: ConnDep) -> dict[str, Any]:
    """Which Slack channel /api/slack/reload pulls history from (a channel ID, e.g. C0123ABC —
    visible in a channel's "Copy link", not its display name)."""
    return mail_ingest.set_slack_channel(conn, body.channel_id.strip())


class CreateRuleRequest(BaseModel):
    text: str


@app.get("/api/rules")
def list_rules(conn: ConnDep) -> dict[str, Any]:
    """Every automation rule this user has authored (see brain/automation.py)."""
    return {"rules": automation.list_rules(conn)}


@app.post("/api/rules")
def create_rule(body: CreateRuleRequest, conn: ConnDep) -> dict[str, Any]:
    """Parse a natural-language rule ("notify me on Slack when a Placements email arrives")
    into a structured trigger, via one LLM call at authoring time only — evaluation against
    future messages is pure code (see automation.evaluate_and_notify)."""
    categories = [c["title"] for c in store.all_of_type(conn, "mail_category")]
    try:
        return automation.create_rule(conn, body.text.strip(), categories)
    except Exception as exc:
        return JSONResponse(status_code=502, content={"error": f"Couldn't parse that rule: {exc}"})


@app.delete("/api/rules/{rule_id}")
def delete_rule(rule_id: str, conn: ConnDep) -> dict[str, bool]:
    return {"deleted": automation.delete_rule(conn, rule_id)}


def _thread_path(conn: Any, thread_id: str) -> tuple[str | None, str | None]:
    """The (category, topic) a thread currently sits under, by walking `contains` upwards."""
    topics = store.neighbors(conn, thread_id, "contains", incoming=True)
    if not topics:
        return None, None
    topic = topics[0]
    categories = store.neighbors(conn, topic["id"], "contains", incoming=True)
    return (categories[0]["title"] if categories else None), topic["title"]


@app.get("/api/mail/review")
def mail_review(conn: ConnDep) -> dict[str, Any]:
    """Threads whose category the classifier wasn't confident about.

    The mindmap flags these individually, but finding them there means expanding the tree node
    by node — this gives the UI a single actionable list to work through.
    """
    items: list[dict[str, Any]] = []
    for thread in store.all_of_type(conn, "mail_thread"):
        if not thread.get("needs_review"):
            continue
        category, topic = _thread_path(conn, thread["id"])
        classification = thread["data"].get("classification") or {}
        items.append(
            {
                "id": thread["id"],
                "name": thread["title"],
                "summary": thread.get("summary"),
                "category": category,
                "topic": topic,
                "llm_category": classification.get("llm_category"),
                "keyword_category": classification.get("keyword_category"),
                "scores": classification.get("scores") or {},
            }
        )
    categories = [c["title"] for c in store.all_of_type(conn, "mail_category")]
    return {"threads": items, "categories": categories}


def _newer_than(thread: dict[str, Any], since: str) -> bool:
    """Whether `thread` changed at or after `since` (ISO-8601).

    Filters on updated_at, never created_at: merging a new message into an existing thread
    leaves created_at alone, so a created_at filter would miss the exact case a poller cares
    about — an old thread that just became urgent. Both columns are ISO-8601 UTC from
    store._now(), so a lexicographic compare is a chronological one; no parsing needed.
    """
    return (thread.get("updated_at") or "") >= since


@app.get("/api/needs-attention")
def needs_attention(conn: ConnDep, since: str = "") -> dict[str, Any]:
    """Threads flagged urgent (brain/mail_ingest.py's deterministic keyword detector), across
    every channel — one worklist instead of hunting through the mindmap per source.

    `since` (ISO-8601 UTC, optional) narrows this to threads touched at or after that moment,
    so a notification poller can ask "what's new" instead of re-fetching everything. Omitted
    means everything, so existing callers are unaffected.
    """
    items: list[dict[str, Any]] = []
    for thread in store.all_of_type(conn, "mail_thread"):
        if not thread["data"].get("urgent"):
            continue
        if since and not _newer_than(thread, since):
            continue
        category, topic = _thread_path(conn, thread["id"])
        items.append(
            {
                "id": thread["id"],
                "name": thread["title"],
                "summary": thread.get("summary"),
                "category": category,
                "topic": topic,
                "channel": thread["data"].get("channel", "gmail"),
                "updated_at": thread.get("updated_at"),
            }
        )
    return {"threads": items}


@app.get("/api/action-items")
def action_items(conn: ConnDep, since: str = "") -> dict[str, Any]:
    """Every extracted to-do (brain/mail_ingest.py's deterministic regex extractor), flattened
    across all threads and channels into one unified list."""
    items: list[dict[str, Any]] = []
    for thread in store.all_of_type(conn, "mail_thread"):
        if since and not _newer_than(thread, since):
            continue
        category, topic = _thread_path(conn, thread["id"])
        for item in thread["data"].get("action_items") or []:
            items.append(
                {
                    "text": item.get("text"),
                    "thread_id": thread["id"],
                    "thread_name": thread["title"],
                    "category": category,
                    "topic": topic,
                    "channel": thread["data"].get("channel", "gmail"),
                    "updated_at": thread.get("updated_at"),
                }
            )
    return {"items": items}


@app.get("/api/analytics/category-volume")
def analytics_category_volume(conn: ConnDep, bucket: str = "day") -> dict[str, Any]:
    """Thread count per category per time bucket, using created_at — already timestamped on
    every entity, so this is pure aggregation with no new data collection."""
    if bucket not in ("day", "week"):
        return JSONResponse(status_code=400, content={"error": "bucket must be 'day' or 'week'"})

    counts: dict[tuple[str, str], int] = {}
    for thread in store.all_of_type(conn, "mail_thread"):
        category, _ = _thread_path(conn, thread["id"])
        created_at = thread.get("created_at") or ""
        try:
            when = datetime.fromisoformat(created_at)
        except ValueError:
            continue
        key_bucket = (
            when.strftime("%Y-%m-%d")
            if bucket == "day"
            else f"{when.isocalendar().year}-W{when.isocalendar().week:02d}"
        )
        key = (key_bucket, category or "Uncategorized")
        counts[key] = counts.get(key, 0) + 1

    points = [
        {"bucket": key_bucket, "category": category, "count": count}
        for (key_bucket, category), count in sorted(counts.items())
    ]
    return {"bucket": bucket, "points": points}


class MailReclassifyRequest(BaseModel):
    thread_id: str
    category: str
    topic: str | None = None


@app.post("/api/mail/reclassify")
def mail_reclassify(body: MailReclassifyRequest, conn: ConnDep) -> Any:
    """Move one mail thread under a different category (and optionally a different topic).

    The correction is authoritative: it clears the review flag and is recorded on the thread so
    the classifier can learn from it rather than refiling the same mail wrongly next time.
    """
    thread = store.get(conn, body.thread_id)
    if thread is None or thread["type"] != "mail_thread":
        return JSONResponse(status_code=404, content={"error": "Thread not found"})

    category = body.category.strip()
    if not category:
        return JSONResponse(status_code=400, content={"error": "category must not be empty"})

    # Default to the thread's current topic name so a category-only move keeps its grouping.
    topic = (body.topic or "").strip()
    if not topic:
        parents = store.neighbors(conn, body.thread_id, "contains", incoming=True)
        topic = parents[0]["title"] if parents else (thread["title"] or "Untitled")

    topic_id = mail_ingest.ensure_topic(conn, category, topic)

    payload = dict(thread["data"])
    classification = dict(payload.get("classification") or {})
    classification.update(
        {
            "category": category,
            "confidence": "high",
            "corrected_by_user": True,
            # What the classifier had said, kept so a future run can learn from the correction.
            "auto_category": classification.get("category"),
        }
    )
    payload["classification"] = classification

    store.upsert(
        conn,
        "mail_thread",
        payload,
        title=thread["title"],
        summary=thread["summary"],
        source=thread["source"],
        needs_review=False,
    )
    mail_ingest.reparent_thread(conn, body.thread_id, topic_id)
    store.add_edge(conn, topic_id, body.thread_id, "contains")
    # Teach the classifier from the correction, so similar mail isn't misfiled the same way.
    learned = mail_ingest.learn_category_keywords(conn, category, thread["title"] or "")
    pruned = mail_ingest.prune_empty_mail_nodes(conn)

    return {
        "thread_id": body.thread_id,
        "category": category,
        "topic": topic,
        "topic_id": topic_id,
        "pruned": pruned,
        "learned_keywords": learned,
    }


@app.get("/mail-tree")
def mail_tree_page() -> FileResponse:
    return FileResponse(HERE / "mail_tree.html")


@app.get("/")
def index() -> dict[str, str]:
    """Liveness probe. Used to serve viz.html (the résumé talent-radar page) — that whole
    surface is gone; the React console at :5173 is the only UI now."""
    return {"service": "brain", "status": "ok"}
