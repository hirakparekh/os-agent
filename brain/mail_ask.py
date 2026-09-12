"""brain/mail_ask.py — answer natural-language questions over the ingested mail tree.

Walks mail_category -> mail_topic -> mail_thread, then hands the model a bounded slice of it.
Rides brain.openrouter, the same engine the mail pipeline already uses for classification and
summarization (mail_ingest.py). This is the single Q&A path the console's Chat tab calls.

Retrieval is bounded, not "dump the mailbox": every thread gets one summary line in the
prompt (cheap — titles/summaries are short even at hundreds of threads), but only the BM25
top-K threads against the question get their full body text included, so prompt size stays
roughly constant as the mailbox grows. Plain-text answer, no citation contract — matches the
MailChat UI, which has no "sources" affordance today.
"""

from __future__ import annotations

import logging
from datetime import date, datetime
from typing import Any

from brain import bm25, calendar_tool, chat_pins, mail_timeline, profile, store
from brain.openrouter import call_openrouter

_log = logging.getLogger(__name__)

TOP_K = 8  # tunable: how many full thread bodies to include, see module docstring

# Below this BM25 top score, a question is treated as a follow-up that cannot stand on its own
# ("when is it due?", "tell me more") and is answered from the session's pinned thread instead
# of from whatever the ranking happened to surface.
#
# Measured against a real 15-thread mailbox: specific questions scored 5.09, 7.64 and 19.74,
# while every follow-up and a generic "what should I do today" scored 3.45 or less. Per-term
# normalisation was tried and is worse — "tell me more" scores 0.97/term against a genuine
# question's 0.85. BM25 here is unnormalised (brain/bm25.py), so this drifts as the mailbox
# grows; every ask logs its score so the number can be retuned from real data.
FOLLOW_UP_SCORE_FLOOR = 4.0

SYSTEM = """You are a mail assistant answering questions about someone's inbox, using a
knowledge tree built from their ingested email (organized as category > topic > thread).
Answer ONLY from the MAIL CONTEXT below — never invent senders, dates, deadlines, or facts
that aren't there. If the answer isn't in the context, say plainly that you don't see it in
the ingested mail rather than guessing. Keep answers short and direct (a sentence or two,
longer only if the question needs a list). Do not mention internal details like "BM25",
"top threads", or how this context was assembled — just answer the question.

Attachment findings are authoritative. They come from actually reading the file, whereas a
thread's summary is prose written earlier and may be out of date — where the two disagree
about whether an attachment mentions the user, trust the attachment finding.

A TODAY line gives the current real-world date. Use it to resolve relative time questions
("today", "this week", "how many days until the deadline", "is this overdue") — never guess
today's date from anything else.

A CALENDAR EVENTS section, when present, lists the user's real upcoming Google Calendar
events. It is the authoritative source for "what's on my calendar" / "what meetings do I have
today" — prefer it over anything the mail implies about their schedule. It is separate from
the mail tree, so don't describe those events as emails.

RELEVANT THREADS may include the thread the *previous* question was about, carried over so a
follow-up like "when is it due?" or "tell me more" can be answered without the user repeating
the subject. Treat the conversation as continuous: if the question is a follow-up, it is about
that thread.

Each overview line shows when that thread's mail was received ("~" means approximate) — use it
for questions about when something arrived ("what came in last week"). DATED ITEMS lists the
deadlines and events found in the mail, already marked OVERDUE / SOON / UPCOMING / PAST relative
to TODAY — use it for "what's due", "what's coming up" and "what did I miss" questions. Where a
dated item and a calendar event describe the same commitment, the calendar is authoritative."""

# Dated items shown to the model: everything overdue or upcoming, capped so a mailbox full of
# far-future events can't crowd out the actual mail context.
MAX_DATED_ITEMS = 20


def _walk_tree(conn: Any) -> list[tuple[str, str, dict[str, Any]]]:
    """Flatten mail_category -> mail_topic -> mail_thread into (category_title, topic_title,
    thread_entity) tuples — same traversal shape as viz_server's _mail_children/_mail_node."""
    rows: list[tuple[str, str, dict[str, Any]]] = []
    for cat in store.all_of_type(conn, "mail_category"):
        for topic in store.neighbors(conn, cat["id"], "contains"):
            if topic["type"] != "mail_topic":
                continue
            for thread in store.neighbors(conn, topic["id"], "contains"):
                if thread["type"] != "mail_thread":
                    continue
                rows.append((cat["title"], topic["title"], thread))
    return rows


def _thread_doc_text(thread: dict[str, Any]) -> str:
    body = (thread.get("data") or {}).get("body") or ""
    # Attachment text is part of what a thread "says": a shortlist spreadsheet may be the only
    # place a company name or your roll number appears, so it must be rankable too.
    attachments = " ".join(
        " ".join(
            [
                str(f.get("file") or ""),
                str(f.get("finding") or ""),
                *(str(m) for m in (f.get("mentions_you") or [])),
            ]
        )
        for f in ((thread.get("data") or {}).get("attachments") or [])
        if isinstance(f, dict)
    )
    parts = (thread.get("title"), thread.get("summary"), body, attachments)
    return " ".join(str(p) for p in parts if p)


def _rank_threads(
    question: str,
    rows: list[tuple[str, str, dict[str, Any]]],
    *,
    top_k: int = TOP_K,
) -> list[tuple[tuple[str, str, dict[str, Any]], float]]:
    """BM25-rank every thread against `question`; return the top_k scoring above zero, best
    first, each paired with its score.

    A thread that shares no terms with the question is never expanded to full body — the
    one-line overview is enough for the model to (correctly) say it isn't there. The scores
    come back with the rows because the caller decides, from the top one, whether this question
    ranked well enough to be trusted at all (see FOLLOW_UP_SCORE_FLOOR).
    """
    if not rows:
        return []
    documents = {thread["id"]: _thread_doc_text(thread) for _, _, thread in rows}
    ranked = bm25.rank(question, documents)
    by_id = {thread["id"]: (cat, topic, thread) for cat, topic, thread in rows}
    return [(by_id[tid], score) for tid, score in ranked if score > 0][:top_k]


def _overview_attachment_note(thread: dict[str, Any]) -> str:
    """A compact attachment marker for the one-line overview.

    "Is my name in any attachment?" is a question about *every* thread, but only the top few
    are expanded in full — so the answer has to be visible from the overview alone.
    """
    findings = [
        f for f in ((thread.get("data") or {}).get("attachments") or []) if isinstance(f, dict)
    ]
    if not findings:
        return ""
    named = sorted({m for f in findings for m in (f.get("mentions_you") or [])})
    if named:
        return f" [{len(findings)} attachment(s); NAMES THE USER: {', '.join(map(str, named))}]"
    return f" [{len(findings)} attachment(s); does not name the user]"


def _received_note(thread: dict[str, Any]) -> str:
    timeline = mail_timeline.thread_timeline(thread)
    last = timeline["last_received"]
    if not last:
        return ""
    approx = "~" if timeline["received_estimated"] else ""
    first = timeline["first_received"]
    if first and first[:10] != last[:10]:
        return f" (received {approx}{first[:10]} to {approx}{last[:10]})"
    return f" (received {approx}{last[:10]})"


def _format_overview(rows: list[tuple[str, str, dict[str, Any]]]) -> str:
    lines = []
    for cat, topic, thread in rows:
        summary = thread.get("summary") or "(no summary)"
        # The attachment verdict leads the line. Appended to the end it landed ~525 characters
        # in, after a long summary, and a small model simply did not attend to it — it answered
        # "not listed" about a shortlist the line said named the user.
        note = _overview_attachment_note(thread)
        prefix = f"{note} " if note else ""
        received = _received_note(thread)
        lines.append(f"  {prefix}[{cat} > {topic}] {thread['title']}{received} — {summary}")
    return "\n".join(lines)


def _format_dated_items(rows: list[tuple[str, str, dict[str, Any]]], today: date) -> str:
    """Every overdue or upcoming event across the mailbox, soonest first.

    The overview's one-liners and the BM25-expanded bodies can't answer "what's due this week":
    that question shares no words with the emails it's about, so ranking never surfaces them.
    """
    items: list[tuple[int, str]] = []
    for cat, topic, thread in rows:
        for event in mail_timeline.thread_timeline(thread)["events"]:
            status = mail_timeline.thread_status({"events": [event]}, today)
            days = status["days"]
            if status["status"] == "past" and days is not None and days < -1:
                continue
            unit = "day" if abs(days) == 1 else "days"
            when = (
                "today" if days == 0 else f"in {days} {unit}" if days > 0 else f"{-days} {unit} ago"
            )
            kind = "DEADLINE" if event.get("kind") == "deadline" else "EVENT"
            items.append(
                (
                    days,
                    f"  {status['status'].upper()} {kind} {event['start'][:16]} ({when}): "
                    f'{event["title"]} — from "{thread["title"]}" [{cat} > {topic}]',
                )
            )
    items.sort(key=lambda item: item[0])
    lines = [line for _, line in items[:MAX_DATED_ITEMS]]
    return "\n".join(lines) or "(no dated items found in the mail)"


def _format_attachments(thread: dict[str, Any]) -> str:
    """What was found inside this thread's attachments, including whether it named the user.

    Without this the answer side is blind to attachments entirely: findings are produced at
    ingest and would otherwise never reach the question being asked.
    """
    findings = (thread.get("data") or {}).get("attachments") or []
    if not findings:
        return ""
    lines = []
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        name = finding.get("file", "attachment")
        kind = finding.get("kind", "file")
        mentions = finding.get("mentions_you") or []
        marker = f" [NAMES THE USER: {', '.join(map(str, mentions))}]" if mentions else ""
        detail = finding.get("finding")
        lines.append(f"- {name} ({kind}){marker}: {detail}")
    return "\nAttachments:\n" + "\n".join(lines) if lines else ""


def _format_full_thread(cat: str, topic: str, thread: dict[str, Any]) -> str:
    body = (thread.get("data") or {}).get("body") or "(no body captured)"
    # Attachments precede the prose. A summary is written by the model at ingest and can go
    # stale — one here read "attachments indicate the sender was not listed" for a spreadsheet
    # that does name the user — so the scanned facts must be read first, not last.
    return (
        f"### {thread['title']}  [{cat} > {topic}]{_received_note(thread)}"
        f"{_format_attachments(thread)}\n"
        f"Summary: {thread.get('summary') or '(none)'}\n"
        f"Body:\n{body}"
    )


def _format_profile(profile_details: list[dict[str, str]]) -> str:
    lines = [f"  {d.get('key', '')}: {d.get('value', '')}" for d in profile_details if d.get("key")]
    return "\n".join(lines) if lines else "(none provided)"


def _calendar_section(user_id: str | int | None) -> str:
    """Live Google Calendar events for the prompt, or "" when the calendar isn't connected.

    Calendar access is optional, so a disconnected user just gets the mail-only behaviour —
    but when it IS connected this is what lets "what meetings do I have today" be answered
    from the real calendar rather than inferred from mail.
    """
    if user_id is None:
        return ""
    try:
        events = calendar_tool.list_upcoming_events(user_id)
    except Exception:
        return ""
    if not events:
        return ""
    lines = [
        f"  {e['start']} — {e['title']}" + (f" @ {e['location']}" if e.get("location") else "")
        for e in events
    ]
    return "=== CALENDAR EVENTS (upcoming, real, live) ===\n" + "\n".join(lines) + "\n\n"


def build_prompt(
    question: str,
    rows: list[tuple[str, str, dict[str, Any]]],
    top_threads: list[tuple[str, str, dict[str, Any]]],
    profile_details: list[dict[str, str]],
    user_id: str | int | None = None,
    follow_up_about: str | None = None,
) -> str:
    overview = _format_overview(rows)
    full = "\n\n".join(_format_full_thread(c, t, th) for c, t, th in top_threads) or (
        "(no thread matched this question closely — rely on the overview above, and say so "
        "if it isn't enough to answer)"
    )
    # Not named `profile`: that would shadow the imported brain.profile module.
    profile_block = _format_profile(profile_details)
    now = datetime.now()
    dated = _format_dated_items(rows, now.date())
    # A follow-up ranked too poorly to stand alone, so it is being answered from the thread the
    # conversation was already about. Without saying so, the model answers from DATED ITEMS and
    # the overview instead — "when is it due?" came back with every deadline in the mailbox.
    follow_up = (
        f"=== THIS IS A FOLLOW-UP ===\nThe question continues a conversation about "
        f'"{follow_up_about}". Answer about that thread specifically, using the section below, '
        f"unless the question plainly changes the subject.\n\n"
        if follow_up_about
        else ""
    )
    return (
        f"{SYSTEM}\n\n"
        f"=== TODAY ===\n{now.strftime('%A, %Y-%m-%d')}\n\n"
        f"{follow_up}"
        f"{_calendar_section(user_id)}"
        f"=== DATED ITEMS (deadlines and events, soonest first) ===\n{dated}\n\n"
        f"=== MAIL OVERVIEW (every thread, one line each) ===\n{overview}\n\n"
        f"=== RELEVANT THREADS IN FULL ===\n{full}\n\n"
        f"=== ABOUT THE PERSON ASKING (optional context) ===\n{profile_block}\n\n"
        f"=== QUESTION ===\n{question}\n"
    )


def _find_row(
    rows: list[tuple[str, str, dict[str, Any]]], thread_id: str | None
) -> tuple[str, str, dict[str, Any]] | None:
    if not thread_id:
        return None
    return next((row for row in rows if row[2]["id"] == thread_id), None)


def _choose_context(
    conn: Any,
    question: str,
    rows: list[tuple[str, str, dict[str, Any]]],
    *,
    top_k: int,
    session_id: int | str | None,
) -> tuple[list[tuple[str, str, dict[str, Any]]], str]:
    """Which threads get expanded in full for this question.

    Either the fresh ranking wins or the session's pinned thread does — never a second search
    and never a rewrite. The pin is updated only when the ranking wins, so a run of vague
    follow-ups all resolve against the same thread.
    """
    ranked = _rank_threads(question, rows, top_k=top_k)
    top_score = ranked[0][1] if ranked else 0.0
    pinned_id = chat_pins.get_pin(conn, session_id)

    if ranked and top_score >= FOLLOW_UP_SCORE_FLOOR:
        context = [row for row, _ in ranked]
        winner = context[0][2]["id"]
        # Carry the thread the conversation was already about, so "how does that compare?"
        # still has both in view. It goes last: the fresh match is what the question asked for.
        carried = _find_row(rows, pinned_id)
        if carried is not None and all(row[2]["id"] != pinned_id for row in context):
            context.append(carried)
        chat_pins.set_pin(conn, session_id, winner)
        decision = "fresh"
    else:
        # Too vague to rank: "when is it due?" shares no words with the thread it means, so the
        # ranking is noise. Answer from what the session is already about, and leave the pin.
        carried = _find_row(rows, pinned_id)
        context = [carried] if carried is not None else [row for row, _ in ranked]
        decision = "pinned" if carried is not None else "unranked"

    # The tuning data for FOLLOW_UP_SCORE_FLOOR. Lands in the brain log next to the request.
    _log.info(
        "ask: session=%s top_score=%.2f floor=%.1f decision=%s context=%s",
        session_id,
        top_score,
        FOLLOW_UP_SCORE_FLOOR,
        decision,
        ",".join(row[2]["id"] for row in context) or "-",
    )
    return context, decision


def ask_mail(
    conn: Any,
    question: str,
    profile_details: list[dict[str, str]] | None = None,
    *,
    top_k: int = TOP_K,
    user_id: str | int | None = None,
    session_id: int | str | None = None,
) -> dict[str, str]:
    """Answer `question` over the mail knowledge tree. Returns {"answer": str}.

    `user_id` is only needed to pull this user's live calendar events into the prompt — the
    mail side all rides `conn`, which is already per-user.

    `session_id` ties this question to the conversation it came from. With one, a question that
    ranks too poorly to stand alone is answered from the thread the session is already about
    (brain/chat_pins.py); without one, every question is a one-shot, exactly as before.

    Empty tree short-circuits to a canned message without calling the LLM.
    """
    rows = _walk_tree(conn)
    if not rows:
        return {
            "answer": "Your mail knowledge tree is empty — connect your mailbox and let it "
            "ingest some mail first, then ask again."
        }
    # The profile lives server-side (brain/profile.py) so headless ingestion can read it too;
    # anything the caller passes is merged on top rather than replacing it.
    stored = profile.load_profile(conn)
    seen = {d.get("key", "").strip().lower() for d in (profile_details or [])}
    merged = list(profile_details or []) + [d for d in stored if d["key"].lower() not in seen]

    top_threads, decision = _choose_context(
        conn, question, rows, top_k=top_k, session_id=session_id
    )
    following = top_threads[0][2]["title"] if decision == "pinned" and top_threads else None
    prompt = build_prompt(question, rows, top_threads, merged, user_id, follow_up_about=following)
    reply = call_openrouter(prompt)
    return {"answer": reply.strip()}
