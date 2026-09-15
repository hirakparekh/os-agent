"""Tests for brain/mail_ask.py — mail-tree Q&A retrieval + prompting."""

from datetime import date

from brain import mail_ask, store


def _conn(tmp_path):
    return store.connect(tmp_path / "t.db")


def _seed_thread(conn, cat_title, topic_title, thread_id, title, summary, body):
    cat_id = f"mail:cat:{cat_title.lower()}"
    topic_id = f"mail:topic:{cat_title.lower()}:{topic_title.lower()}"
    store.upsert(
        conn,
        "mail_category",
        {"source_id": cat_id, "title": cat_title},
        title=cat_title,
        summary=f"Mail about {cat_title}.",
        source="mail",
    )
    store.upsert(
        conn,
        "mail_topic",
        {"source_id": topic_id, "title": topic_title},
        title=topic_title,
        summary=f"Mail about {topic_title}.",
        source="mail",
    )
    store.upsert(
        conn,
        "mail_thread",
        {"source_id": thread_id, "title": title, "body": body, "source_uids": ["1"]},
        title=title,
        summary=summary,
        source="mail:1",
    )
    store.add_edge(conn, cat_id, topic_id, "contains")
    store.add_edge(conn, topic_id, thread_id, "contains")


def test_ask_mail_empty_tree_returns_canned_message_without_calling_llm(tmp_path, monkeypatch):
    conn = _conn(tmp_path)

    def boom(prompt, **kwargs):
        raise AssertionError("should not call the LLM on an empty tree")

    monkeypatch.setattr(mail_ask, "call_openrouter", boom)
    result = mail_ask.ask_mail(conn, "anything?")
    assert "empty" in result["answer"].lower()


def test_ask_mail_includes_matching_thread_body_in_prompt(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    _seed_thread(
        conn,
        "Placements",
        "Acme",
        "mail:thread:1",
        "Interview Round 1",
        "Interview scheduled Monday.",
        "Please join the interview call on Monday at 10am.",
    )
    _seed_thread(
        conn,
        "Lectures",
        "DBMS",
        "mail:thread:2",
        "Assignment 2",
        "Assignment due Friday.",
        "Submit assignment 2 by Friday via the portal.",
    )
    captured = {}

    def fake_call(prompt, **kwargs):
        captured["prompt"] = prompt
        return "You have an interview Monday at 10am."

    monkeypatch.setattr(mail_ask, "call_openrouter", fake_call)

    result = mail_ask.ask_mail(conn, "When is my Acme interview?")

    assert "interview call on Monday" in captured["prompt"]  # top match expanded in full
    assert "Assignment 2" in captured["prompt"]  # unrelated thread still in overview
    assert "Submit assignment 2 by Friday via the portal." not in captured["prompt"]  # not expanded
    assert result["answer"] == "You have an interview Monday at 10am."


def test_ask_mail_respects_top_k(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    for i in range(12):
        _seed_thread(
            conn,
            "Placements",
            "Acme",
            f"mail:thread:{i}",
            f"Interview Round {i}",
            "Interview scheduled.",
            "interview interview interview call scheduled",
        )
    captured = {}
    monkeypatch.setattr(
        mail_ask, "call_openrouter", lambda p, **kw: captured.setdefault("prompt", p) or "ok"
    )
    mail_ask.ask_mail(conn, "interview call", top_k=3)
    assert captured["prompt"].count("### ") == 3


def test_ask_mail_folds_profile_details_into_prompt(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    _seed_thread(conn, "Placements", "Acme", "mail:thread:1", "Interview", "s", "interview body")
    captured = {}
    monkeypatch.setattr(
        mail_ask, "call_openrouter", lambda p, **kw: captured.setdefault("prompt", p) or "ok"
    )
    mail_ask.ask_mail(conn, "interview", [{"key": "Timezone", "value": "IST"}])
    assert "Timezone: IST" in captured["prompt"]


# --- Attachments reach the answer ---------------------------------------------------------


def _thread_with_attachment(mentions, *, title="Hevo Data shortlist", body="See attached."):
    return {
        "id": "mail:thread:1",
        "title": title,
        "summary": "Shortlist for the next round.",
        "data": {
            "body": body,
            "attachments": [
                {
                    "file": "shortlist.xlsx",
                    "kind": "excel",
                    "finding": [{"matched": mentions, "values": {"Name": "Adidev Anand"}}]
                    if mentions
                    else "you were not listed in this spreadsheet (40 rows)",
                    "mentions_you": mentions,
                }
            ],
        },
    }


def test_overview_flags_a_thread_whose_attachment_names_you():
    rows = [("Placements", "Hevo", _thread_with_attachment(["23BCE1234"]))]
    overview = mail_ask._format_overview(rows)
    assert "NAMES THE USER: 23BCE1234" in overview


def test_overview_says_when_an_attachment_does_not_name_you():
    rows = [("Placements", "Hevo", _thread_with_attachment([]))]
    overview = mail_ask._format_overview(rows)
    assert "does not name the user" in overview


def test_overview_is_unchanged_for_threads_without_attachments():
    thread = {"id": "t", "title": "Plain mail", "summary": "s", "data": {"body": "b"}}
    assert "attachment" not in mail_ask._format_overview([("C", "T", thread)])


def test_full_thread_includes_attachment_findings():
    rendered = mail_ask._format_full_thread(
        "Placements", "Hevo", _thread_with_attachment(["23BCE1234"])
    )
    assert "shortlist.xlsx" in rendered
    assert "Adidev Anand" in rendered
    assert "NAMES THE USER" in rendered


def test_attachment_text_is_rankable():
    """A shortlist may be the only place a name appears — ranking must see it."""
    thread = _thread_with_attachment(["23BCE1234"], body="See attached.")
    doc = mail_ask._thread_doc_text(thread)
    assert "shortlist.xlsx" in doc
    assert "23BCE1234" in doc


def test_prompt_carries_attachments_to_the_model(tmp_path):
    conn = _conn(tmp_path)
    rows = [("Placements", "Hevo", _thread_with_attachment(["23BCE1234"]))]
    prompt = mail_ask.build_prompt(conn, "is my name in any attachment?", rows, rows, [])
    assert "NAMES THE USER: 23BCE1234" in prompt
    assert "shortlist.xlsx" in prompt


def test_prompt_includes_live_calendar_events_when_connected(tmp_path, monkeypatch):
    """Regression guard: the calendar context used to live in the now-deleted brain/ask.py.
    Chat runs through mail_ask, so "what meetings do I have today" only works if the live
    calendar is injected here."""
    conn = _conn(tmp_path)
    monkeypatch.setattr(
        mail_ask.calendar_tool,
        "list_upcoming_events",
        lambda user_id, *a, **k: [
            {"start": "2026-09-12T10:00:00", "title": "Ethos online test", "location": "SJT 717"},
        ],
    )
    prompt = mail_ask.build_prompt(conn, "what meetings do I have?", [], [], [], user_id=1)

    assert "=== CALENDAR EVENTS" in prompt
    assert "Ethos online test" in prompt
    assert "SJT 717" in prompt


def test_prompt_omits_calendar_section_when_not_connected(tmp_path, monkeypatch):
    conn = _conn(tmp_path)

    def _boom(user_id, *a, **k):
        raise RuntimeError("no calendar connected")

    monkeypatch.setattr(mail_ask.calendar_tool, "list_upcoming_events", _boom)
    prompt = mail_ask.build_prompt(conn, "anything?", [], [], [], user_id=1)
    assert "=== CALENDAR EVENTS" not in prompt


def test_prompt_omits_calendar_section_without_a_user(tmp_path, monkeypatch):
    """No user_id (CLI/tests) must never trigger a calendar lookup at all."""
    conn = _conn(tmp_path)

    def _never(user_id, *a, **k):
        raise AssertionError("must not look up a calendar without a user_id")

    monkeypatch.setattr(mail_ask.calendar_tool, "list_upcoming_events", _never)
    assert "=== CALENDAR EVENTS" not in mail_ask.build_prompt(conn, "anything?", [], [], [])


def test_format_dated_items_reads_the_index_not_the_thread_rows(tmp_path):
    """DATED ITEMS now comes from brain/mail_ingest.py's dated-items index (built once at
    ingest time), not from re-scanning thread rows on every question — see
    mail_ingest._index_dated_item. Seeding the index directly, with no `rows` at all, is the
    regression guard that this wiring actually happened."""
    conn = _conn(tmp_path)
    store.upsert(
        conn,
        "mail_dated_item",
        {
            "source_id": "mail:event:1",
            "title": "Application deadline",
            "start": "2026-09-20",
            "end": None,
            "kind": "deadline",
            "location": None,
            "source_uid": "1",
            "thread_id": "mail:thread:1",
            "thread_title": "Accenture application",
            "category": "Placements",
            "topic": "Accenture",
        },
        title="Application deadline",
        summary="Placements > Accenture — Accenture application",
        source="mail:event:1",
    )

    formatted = mail_ask._format_dated_items(conn, date(2026, 9, 15))

    assert "Application deadline" in formatted
    assert "Accenture application" in formatted
    assert "[Placements > Accenture]" in formatted
    assert "DEADLINE" in formatted


# --- conversational follow-ups -----------------------------------------------------------
#
# A follow-up ("when is it due?") shares no words with the thread it refers to, so BM25 ranks
# noise. These pin the rule: rank well and you are trusted, rank badly and the session's last
# good thread answers instead. Scores are asserted through behaviour, not mocked, so the
# threshold is exercised against the real ranker.


def _two_threads(conn):
    _seed_thread(
        conn,
        "Placements",
        "PayU",
        "mail:thread:payu",
        "Software Engineer at PayU",
        "A job posting for a backend role at PayU in Bengaluru.",
        "PayU is hiring a Software Engineer. Apply before the closing date.",
    )
    _seed_thread(
        conn,
        "Lectures",
        "Compilers",
        "mail:thread:compilers",
        "Guest Lecture on Compilers",
        "A guest lecture by a visiting professor.",
        "The compiler design lecture is in the seminar hall on Friday.",
    )


def _capture(monkeypatch):
    captured = {}

    def fake(prompt, **kwargs):
        captured["prompt"] = prompt
        return "ok"

    monkeypatch.setattr(mail_ask, "call_openrouter", fake)
    return captured


def _full_section(prompt):
    return prompt.split("=== RELEVANT THREADS IN FULL ===")[1]


def _floor(monkeypatch, value):
    """Calibrate the threshold to this fixture.

    FOLLOW_UP_SCORE_FLOOR ships at 4.0, tuned against a real 15-thread mailbox. BM25's IDF term
    shrinks as the corpus does — with two documents the ceiling is 0.69 per matched term — so a
    question matching one distinctive word here scores 1.13 where the same question scores 5.09
    against real mail. What these tests pin is the rule (below the floor, answer from the pin),
    not the constant, so they set a floor that separates *this* corpus: measured 1.13 and 5.38
    for real questions against 0.19 and 0.00 for follow-ups.
    """
    monkeypatch.setattr(mail_ask, "FOLLOW_UP_SCORE_FLOOR", value)


def test_a_well_ranked_question_pins_the_thread_it_found(tmp_path, monkeypatch):
    from brain import chat_pins

    conn = _conn(tmp_path)
    _two_threads(conn)
    _floor(monkeypatch, 1.0)
    _capture(monkeypatch)

    mail_ask.ask_mail(conn, "What did PayU email me about?", session_id=1)

    assert chat_pins.get_pin(conn, 1) == "mail:thread:payu"


def test_a_vague_follow_up_is_answered_from_the_pinned_thread(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    _two_threads(conn)
    _floor(monkeypatch, 1.0)
    captured = _capture(monkeypatch)

    mail_ask.ask_mail(conn, "What did PayU email me about?", session_id=1)
    mail_ask.ask_mail(conn, "when is it due?", session_id=1)

    full = _full_section(captured["prompt"])
    assert "Software Engineer at PayU" in full
    assert "Guest Lecture on Compilers" not in full


def test_a_vague_follow_up_leaves_the_pin_where_it_was(tmp_path, monkeypatch):
    from brain import chat_pins

    conn = _conn(tmp_path)
    _two_threads(conn)
    _floor(monkeypatch, 1.0)
    _capture(monkeypatch)

    mail_ask.ask_mail(conn, "What did PayU email me about?", session_id=1)
    mail_ask.ask_mail(conn, "tell me more", session_id=1)

    assert chat_pins.get_pin(conn, 1) == "mail:thread:payu"


def test_a_new_subject_carries_the_previous_thread_along(tmp_path, monkeypatch):
    """The point of carrying it: "how does that compare?" needs both threads in view."""
    from brain import chat_pins

    conn = _conn(tmp_path)
    _two_threads(conn)
    _floor(monkeypatch, 1.0)
    captured = _capture(monkeypatch)

    mail_ask.ask_mail(conn, "What did PayU email me about?", session_id=1)
    mail_ask.ask_mail(conn, "Guest Lecture on Compilers seminar hall", session_id=1)

    full = _full_section(captured["prompt"])
    assert "Guest Lecture on Compilers" in full
    assert "Software Engineer at PayU" in full
    assert chat_pins.get_pin(conn, 1) == "mail:thread:compilers"


def test_a_vague_first_question_behaves_as_before(tmp_path, monkeypatch):
    """No pin yet: nothing to fall back to, so the ranking stands however weak it is."""
    from brain import chat_pins

    conn = _conn(tmp_path)
    _two_threads(conn)
    _floor(monkeypatch, 1.0)
    captured = _capture(monkeypatch)

    mail_ask.ask_mail(conn, "tell me more", session_id=99)

    assert chat_pins.get_pin(conn, 99) is None
    assert "=== RELEVANT THREADS IN FULL ===" in captured["prompt"]


def test_without_a_session_nothing_is_pinned(tmp_path, monkeypatch):
    """Every other caller of ask_mail keeps the old one-shot behaviour."""
    from brain import chat_pins

    conn = _conn(tmp_path)
    _two_threads(conn)
    _floor(monkeypatch, 1.0)
    _capture(monkeypatch)

    mail_ask.ask_mail(conn, "What did PayU email me about?")

    assert store.all_of_type(conn, chat_pins.PIN_TYPE) == []


def test_a_follow_up_tells_the_model_which_thread_it_is_about(tmp_path, monkeypatch):
    """Pinning the right thread is not enough on its own.

    The prompt also carries DATED ITEMS for the whole mailbox and a one-line overview of every
    thread, so an unanchored "when is it due?" was answered with every deadline in the mailbox
    even though the correct thread was pinned and expanded. The follow-up banner is what makes
    the pinned thread the subject rather than merely available.
    """
    conn = _conn(tmp_path)
    _two_threads(conn)
    captured = _capture(monkeypatch)
    _floor(monkeypatch, 1.0)

    mail_ask.ask_mail(conn, "What did PayU email me about?", session_id=1)
    mail_ask.ask_mail(conn, "when is it due?", session_id=1)

    prompt = captured["prompt"]
    assert "=== THIS IS A FOLLOW-UP ===" in prompt
    assert "Software Engineer at PayU" in prompt.split("=== TODAY ===")[0] + prompt
    assert prompt.index("THIS IS A FOLLOW-UP") < prompt.index("=== QUESTION ===")


def test_a_question_that_stands_alone_gets_no_follow_up_banner(tmp_path, monkeypatch):
    conn = _conn(tmp_path)
    _two_threads(conn)
    captured = _capture(monkeypatch)
    _floor(monkeypatch, 1.0)

    mail_ask.ask_mail(conn, "What did PayU email me about?", session_id=1)

    assert "=== THIS IS A FOLLOW-UP ===" not in captured["prompt"]
