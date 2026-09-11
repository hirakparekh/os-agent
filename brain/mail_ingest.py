"""brain/mail_ingest.py — the mail knowledge-tree pipeline.

    list ─▶ attachments ─▶ classify (LLM) ─▶ merge (LLM) ─▶ store ─▶ mark-read

Builds three new node types in the existing brain (brain/store.py's entities/edges):

    mail_category ──contains──▶ mail_topic ──contains──▶ mail_thread

Plain Python, no Hermes — run manually or from a scheduled task. See
docs/superpowers/specs/2026-08-30-mail-knowledge-tree-design.md for the design.

Usage:
    uv run python -m brain.mail_ingest run
"""

from __future__ import annotations

import copy
import difflib
import json
import re
import subprocess
import sys
from collections import Counter
from collections.abc import Iterator
from datetime import datetime, timedelta
from email.utils import parseaddr, parsedate_to_datetime
from pathlib import Path
from typing import Any

from brain import automation, bm25, calendar_tool, mail_timeline, profile, store
from brain.emailtool import ATTACHMENT_CACHE
from brain.mail_attachments import process_attachment
from brain.openrouter import call_openrouter
from brain.resolver import normalize

CONFIG_PATH = Path(__file__).resolve().parent / "mail_config.json"

# --- Category scoring -------------------------------------------------------------------
# Keyword lists are a controlled vocabulary, not documents, so they are matched by weighted
# phrase *presence* rather than ranked with BM25. BM25's document-length normalization makes
# enriching one category devalue its own hits and inflate every rival's — measured, adding 20
# General College keywords (including "yoga") still lost to Placements and *raised* Placements'
# per-hit score. brain/bm25.py is untouched and still serves brain/mail_ask.py, where documents
# really are documents; only `bm25.tokenize` is reused here so keywords and email text normalize
# identically.
SUBJECT_WEIGHT = 3.0
BODY_WEIGHT = 1.0
NEGATIVE_PENALTY = 2.0
BODY_CHAR_LIMIT = 2000  # mirrors classify_email's body truncation

# A hit is worth 1.0 (body) or 3.0 (subject), so the floor means "one subject keyword, or three
# distinct body keywords" — a signature block alone can never clear it. The margin needs both a
# ratio and a delta: ratio alone is meaningless when the runner-up is 0, delta alone is too
# permissive once scores are large.
MIN_ABSOLUTE_SCORE = 3.0
MARGIN_RATIO = 2.0
MARGIN_DELTA = 2.0

# Single-token keywords in this set never score. Multi-token keywords are never dropped, which is
# what lets this list be aggressive: "dream company" and "off-campus" survive as phrases while the
# bare tokens they used to leak (`dream`, `company`, `off`, `on`) cannot vote. `on` in particular
# matched virtually every English email and handed Placements a free point on every one.
KEYWORD_STOPWORDS = frozenset(
    {
        "a",
        "an",
        "and",
        "all",
        "any",
        "are",
        "as",
        "at",
        "be",
        "by",
        "can",
        "do",
        "for",
        "from",
        "has",
        "have",
        "if",
        "in",
        "into",
        "is",
        "it",
        "its",
        "new",
        "no",
        "not",
        "of",
        "off",
        "on",
        "open",
        "or",
        "our",
        "so",
        "that",
        "the",
        "then",
        "there",
        "these",
        "they",
        "this",
        "to",
        "up",
        "us",
        "via",
        "was",
        "we",
        "were",
        "what",
        "when",
        "where",
        "which",
        "who",
        "why",
        "will",
        "with",
        "you",
        "your",
        # generic-business poison that shows up in real keyword lists
        "company",
        "dream",
        "college",
        "student",
        "students",
        "email",
        "mail",
        "link",
        "form",
        "team",
        "update",
        "details",
        "information",
        "please",
        "kindly",
        "dear",
        "regards",
        "register",
        "registration",
    }
)

# Terms that describe a *recruitment process*. Deliberately excludes bare "placement": the
# "Training and Placement Cell" is the organiser of nearly every college email — including the
# yoga-competition one this guardrail exists to get right — so it must not license a brand term.
PLACEMENT_CONTEXT: tuple[str, ...] = (
    "drive",
    "recruit",
    "recruitment",
    "recruiter",
    "hiring",
    "interview",
    "internship",
    "ctc",
    "lpa",
    "stipend",
    "offer letter",
    "shortlisted",
    "eligibility",
    "job description",
    "on-campus",
    "off-campus",
    "campus drive",
    "career fair",
)

# Brand names that are also ubiquitous products ("Google Form", "Google Meet"). They score only
# when a real recruitment term appears somewhere in the mail.
DEFAULT_CONDITIONAL_KEYWORDS: dict[str, tuple[str, ...]] = {
    "google": PLACEMENT_CONTEXT,
    "microsoft": PLACEMENT_CONTEXT,
    "amazon": PLACEMENT_CONTEXT,
    "meta": PLACEMENT_CONTEXT,
    "apple": PLACEMENT_CONTEXT,
    "ibm": PLACEMENT_CONTEXT,
}

DEFAULT_CONFIG = {
    "student_id": "",
    # Anything that counts as "you" inside an attachment — name, roll/neo id, registration
    # number. Used to answer "am I on this shortlist?" (see brain/mail_attachments.py).
    "identifiers": [],
    "seeded_categories": ["Lectures & Profs", "Placements", "General College"],
    "category_keywords": {
        "Lectures & Profs": [
            "lecture",
            "lectures",
            "guest lecture",
            "professor",
            "faculty",
            "assignment",
            "submission",
            "class",
            "classes",
            "syllabus",
            "course",
            "curriculum",
            "lab",
            "seminar",
            "tutorial",
            "instructor",
            "grade",
            "marks",
            "attendance",
        ],
        # NOTE: "training" is deliberately absent — "Training and Placement Cell" is the
        # organiser line of nearly every college email, including non-placement ones.
        "Placements": [
            "placement",
            "placements",
            "placement drive",
            "campus drive",
            "off-campus",
            "on-campus",
            "pre-placement talk",
            "internship",
            "intern",
            "recruiter",
            "recruitment",
            "hiring",
            "job",
            "jobs",
            "career fair",
            "job description",
            "offer letter",
            "ctc",
            "lpa",
            "stipend",
            "package",
            "dream company",
            "onboarding",
            "interview",
            "hr round",
            "technical round",
            "aptitude test",
            "online assessment",
            "shortlisted",
            "eligibility criteria",
            "resume",
            "accenture",
            "honeywell",
            "epsilon",
            "tcs",
            "infosys",
            "wipro",
            "cognizant",
            "capgemini",
            "deloitte",
            "hcl",
            "tech mahindra",
            # conditional — score only alongside a PLACEMENT_CONTEXT term
            "google",
            "microsoft",
            "amazon",
        ],
        "General College": [
            # athletics / wellness
            "sport",
            "sports",
            "sports day",
            "sports meet",
            "tournament",
            "championship",
            "match",
            "athletics",
            "athletic",
            "yoga",
            "wellness",
            "fitness",
            "meditation",
            "zumba",
            "marathon",
            "gym",
            # events / culture
            "event",
            "events",
            "competition",
            "contest",
            "quiz",
            "debate",
            "hackathon",
            "fest",
            "festival",
            "cultural",
            "celebration",
            "celebrations",
            "annual day",
            "dance",
            "music",
            "drama",
            "prize distribution",
            "trip",
            "excursion",
            # student life / bodies
            "workshop",
            "club",
            "clubs",
            "society",
            "student council",
            "chapter",
            "ncc",
            "nss",
            "blood donation",
            "volunteer",
            "volunteers",
            "alumni meet",
            "farewell",
            "freshers",
            "orientation",
            "induction",
            "convocation",
            # admin notices
            "exam",
            "exams",
            "schedule",
            "timetable",
            "holiday",
            "notice",
        ],
    },
    # A negative phrase in the SUBJECT vetoes that category outright ("Yoga Competition" is
    # dispositive about what the mail is); in the body it only costs NEGATIVE_PENALTY, so a
    # genuine placement drive that mentions the NSS office in a footer isn't thrown out.
    "category_negative_keywords": {
        "Placements": [
            "yoga",
            "meditation",
            "zumba",
            "sports day",
            "sports meet",
            "annual day",
            "cultural fest",
            "farewell",
            "freshers",
            "blood donation",
            "ncc",
            "nss",
            "convocation",
            "marathon",
            "prize distribution",
            "republic day",
            "independence day",
        ],
    },
    "conditional_keywords": {k: list(v) for k, v in DEFAULT_CONDITIONAL_KEYWORDS.items()},
    # When true, ingest never calls the LLM: classification falls back to pure keyword
    # scoring (already tolerated by arbitrate_category), and merge/summary/event-extraction
    # falls back to _offline_merge_or_create_thread. See config_with_settings — this default
    # is overridden per-user via the mail_settings entity, not by editing this file.
    "offline_mode": False,
}


_PER_CATEGORY_KEYS = ("category_keywords", "category_negative_keywords", "conditional_keywords")


def load_config(path: Path = CONFIG_PATH) -> dict[str, Any]:
    """Read brain/mail_config.json (copy brain/mail_config.example.json to get started),
    filling in defaults for anything missing.

    The per-category dicts merge *per category*, not per key: supplying keywords for one
    category no longer wipes the other categories' defaults. Within a category the user's list
    replaces the default one, so a bad built-in keyword can actually be removed. The deepcopy
    stops a caller mutating a returned list from corrupting DEFAULT_CONFIG process-wide.
    """
    config = copy.deepcopy(DEFAULT_CONFIG)
    if not path.exists():
        return config
    data = json.loads(path.read_text(encoding="utf-8"))
    for key, value in data.items():
        current = config.get(key)
        if key in _PER_CATEGORY_KEYS and isinstance(value, dict) and isinstance(current, dict):
            merged = dict(current)
            for name, words in value.items():
                merged[name] = list(words)
            config[key] = merged
        else:
            config[key] = value
    return config


def _normalize_zone(text: str) -> str:
    """Tokenize and re-join space-padded, so phrase containment is word-boundary exact."""
    return " " + " ".join(bm25.tokenize(text)) + " "


def _phrase_hit(keyword: str, zone: str) -> bool:
    """Whether `keyword` occurs in `zone` as whole words, in order.

    Padding both sides with spaces means a single token matches a whole word only (never a
    substring), and a multi-word keyword matches only as a contiguous phrase: "off-campus"
    matches "off-campus drive" but not "the drive is on and off again".
    """
    tokens = bm25.tokenize(keyword)
    return bool(tokens) and f" {' '.join(tokens)} " in zone


# A separate keyword list from category scoring — urgency is a different axis (how soon,
# not what about), so it needs its own vocabulary and no threshold tuning shared with
# arbitrate_category's confidence floors.
URGENCY_PHRASES = [
    "urgent", "asap", "immediately", "deadline", "final reminder", "last date",
    "closing soon", "action required", "time-sensitive", "time sensitive",
    "expires today", "last chance", "respond by", "due today", "due tomorrow",
]


def is_urgent(subject: str, body: str) -> bool:
    """Deterministic urgency flag — no LLM. A subject hit is dispositive; a body hit is still
    a signal, since "URGENT" in all-caps subjects is common but not universal."""
    subject_zone = _normalize_zone(subject)
    body_zone = _normalize_zone(body)
    return any(_phrase_hit(p, subject_zone) or _phrase_hit(p, body_zone) for p in URGENCY_PHRASES)


# Imperative verb + "by <window>" — matches "submit by Friday", "send it by 5 PM", "reply by
# tomorrow", "complete this by 10th March". Deliberately narrow (verb-anchored) rather than
# matching every stray "by" in a sentence, which would flag almost every email.
_ACTION_ITEM_RE = re.compile(
    r"\b(submit|send|complete|reply|register|apply|confirm|upload|fill|pay)\b"
    r"[^.\n]{0,60}?\bby\b[^.\n]{0,30}",
    re.IGNORECASE,
)


def extract_action_items(body: str) -> list[dict[str, str]]:
    """Deterministic to-do extraction — no LLM. Each match is one candidate action item; the
    caller decides what to do with duplicates across merges (see _ingest_message)."""
    body = body or ""
    seen: set[str] = set()
    items: list[dict[str, str]] = []
    for match in _ACTION_ITEM_RE.finditer(body):
        text = re.sub(r"\s+", " ", match.group(0)).strip().rstrip(",;")
        key = text.lower()
        if text and key not in seen:
            seen.add(key)
            items.append({"text": text})
    return items


def score_categories(
    subject: str,
    body: str,
    sender: str,
    config: dict[str, Any],
) -> list[tuple[str, float]]:
    """Score each category by weighted keyword presence. Returns [(name, score), ...] desc.

    Presence, not frequency: a keyword contributes at most SUBJECT_WEIGHT + BODY_WEIGHT, so a
    word repeated through a footer cannot outvote the subject line. The sender goes in the body
    zone — it keeps `placements@college.edu` as real signal at a weight that can't dominate.
    """
    keywords: dict[str, list[str]] = config.get("category_keywords") or {}
    negatives: dict[str, list[str]] = config.get("category_negative_keywords") or {}
    conditional: dict[str, Any] = config.get("conditional_keywords") or DEFAULT_CONDITIONAL_KEYWORDS

    subject_zone = _normalize_zone(subject)
    body_zone = _normalize_zone(f"{body[:BODY_CHAR_LIMIT]} {sender}")
    whole = subject_zone + body_zone

    scores: dict[str, float] = {}
    for category, words in keywords.items():
        total = 0.0
        for word in words:
            tokens = bm25.tokenize(word)
            if not tokens:
                continue
            if len(tokens) == 1 and tokens[0] in KEYWORD_STOPWORDS:
                continue
            context = conditional.get(" ".join(tokens))
            if context and not any(_phrase_hit(c, whole) for c in context):
                continue
            if _phrase_hit(word, subject_zone):
                total += SUBJECT_WEIGHT
            if _phrase_hit(word, body_zone):
                total += BODY_WEIGHT

        for negative in negatives.get(category, []):
            if _phrase_hit(negative, subject_zone):
                total = 0.0
                break
            if _phrase_hit(negative, body_zone):
                total = max(0.0, total - NEGATIVE_PENALTY)

        scores[category] = total

    # Tiebreak on name so ordering is deterministic (the old code left ties in dict order).
    return sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))


CORRECTION_WEIGHT = 10  # a human's decision about a sender outvotes any number of auto-filings


def _address_of(sender: str) -> str:
    """The bare address from a From: header ("Google <no-reply@x.com>" -> "no-reply@x.com")."""
    return parseaddr(sender or "")[1].strip().lower()


def sender_precedent(conn: Any, sender: str) -> str | None:
    """Where this sender's mail has been filed before, if anywhere.

    Identical mail from one sender must not scatter across categories just because a weak model
    answered differently on two occasions. When the keyword vocabulary has nothing to say — as
    it does for account/security notifications — precedent is a deterministic answer, and it is
    available from the *second* such email rather than only after a human intervenes.
    """
    address = _address_of(sender)
    if not address:
        return None
    votes: Counter[str] = Counter()
    for thread in store.all_of_type(conn, "mail_thread"):
        data = thread.get("data") or {}
        if _address_of(data.get("sender") or "") != address:
            continue
        classification = data.get("classification") or {}
        category = classification.get("category")
        if not category:
            continue
        votes[category] += CORRECTION_WEIGHT if classification.get("corrected_by_user") else 1
    return votes.most_common(1)[0][0] if votes else None


def _is_confident(ranked: list[tuple[str, float]]) -> bool:
    """Whether the top category is far enough clear of the runner-up to overrule the LLM."""
    if not ranked or ranked[0][1] < MIN_ABSOLUTE_SCORE:
        return False
    runner = ranked[1][1] if len(ranked) > 1 else 0.0
    return ranked[0][1] >= MARGIN_RATIO * runner and ranked[0][1] - runner >= MARGIN_DELTA


def arbitrate_category(
    llm_category: str | None,
    ranked: list[tuple[str, float]],
    known_categories: set[str],
    *,
    sender_category: str | None = None,
) -> tuple[str, str]:
    """Combine the deterministic keyword verdict with the LLM's. -> (category, confidence).

    The keyword vocabulary stays an override rather than a mere tie-breaker — that is the whole
    point of a guardrail against a weak free model — but "confident" now means a real margin.
    When the vocabulary shortlists several plausible categories the LLM is exactly the right
    instrument to choose between them, so it wins there. `confidence` is "high" | "medium" |
    "low"; "low" is what flags a thread for human review.
    """
    top_name = ranked[0][0] if ranked else None
    top_score = ranked[0][1] if ranked else 0.0
    llm = (llm_category or "").strip()

    if not ranked or top_name is None:
        return llm or "General College", "low"

    if _is_confident(ranked):
        if llm and normalize(llm) == normalize(top_name):
            return top_name, "high"
        return top_name, "medium"

    if top_score >= MIN_ABSOLUTE_SCORE:
        contenders = [name for name, score in ranked if score >= MIN_ABSOLUTE_SCORE]
        if llm and any(normalize(llm) == normalize(c) for c in contenders):
            return llm, "high"
        # The vocabulary is unsure and the LLM answered outside its shortlist; if this sender
        # has been filed before, that is a better answer than either.
        if sender_category:
            return sender_category, "medium"
        return top_name, "low"

    # No keyword signal at all. Precedent first — it is deterministic, so repeat mail from one
    # sender lands in one place instead of wherever the model happens to land this time.
    if sender_category:
        return sender_category, "medium"
    if not llm:
        return top_name, "low"
    if any(normalize(llm) == normalize(k) for k in known_categories):
        return llm, "medium"
    # The model invented a category with no vocabulary support and no precedent to lean on.
    # Accept it (it is often right) but flag it, so the first of its kind gets a human look
    # rather than silently seeding a category the rest of the mailbox will drift into.
    return llm, "low"


def guess_category_bm25(
    text: str,
    category_keywords: dict[str, list[str]],
    *,
    k1: float = 1.5,
    b: float = 0.75,
) -> str | None:
    """Deprecated: confident category guess over one blob of text, with no subject weighting.

    Kept for callers that only have undifferentiated text. `k1`/`b` are accepted and ignored —
    scoring is no longer BM25 (see score_categories for why). New code should call
    score_categories() + arbitrate_category().
    """
    ranked = score_categories("", text, "", {"category_keywords": category_keywords})
    return ranked[0][0] if _is_confident(ranked) else None


def _slugify(text: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return slug or "untitled"


def _strip_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        lines = text.splitlines()
        lines = lines[1:] if lines and lines[0].startswith("```") else lines
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        text = "\n".join(lines)
    return text.strip()


def classify_email(
    email: dict[str, Any],
    attachment_findings: list[dict[str, Any]],
    categories: list[dict[str, Any]],
) -> dict[str, Any]:
    """LLM call: which category + topic does this email belong to (existing or new)?"""
    cat_lines = (
        "\n".join(f"- {c['title']}: {c.get('summary', '')}" for c in categories) or "(none yet)"
    )
    findings_text = (
        "\n".join(f"- {f['file']} ({f['kind']}): {f['finding']}" for f in attachment_findings)
        or "(none)"
    )
    prompt = (
        "You file one email into a knowledge tree. Pick the best-fitting CATEGORY "
        "(a broad area) and, within it, the best-fitting TOPIC (a specific thing, "
        "e.g. a company name or account). Prefer an existing category/topic; only "
        "propose a new one when nothing existing fits.\n\n"
        f"EXISTING CATEGORIES:\n{cat_lines}\n\n"
        f"EMAIL\nFrom: {email.get('from')}\nSubject: {email.get('subject')}\n"
        f"Body: {email.get('body_text', '')[:2000]}\n"
        f"Attachment findings:\n{findings_text}\n\n"
        "Reply with ONLY this JSON object, nothing else:\n"
        '{"category": "<name>", "new_category": true|false, "topic": "<name>", '
        '"new_topic": true|false}'
    )
    raw = _strip_fences(call_openrouter(prompt))
    return json.loads(raw)


def _reference_date(email: dict[str, Any]) -> str:
    """The email's own Date header, not "now" — ingest can run hours or days after an email
    arrived (a backlog catch-up), and relative phrases in the email ("this Friday", "tomorrow")
    were written relative to when it was *sent*, not when it happens to be processed."""
    raw = email.get("date") or ""
    try:
        dt = parsedate_to_datetime(raw)
        if dt is not None:
            return dt.strftime("%A, %Y-%m-%d")
    except (TypeError, ValueError):
        pass
    return datetime.now().strftime("%A, %Y-%m-%d")


def merge_or_create_thread(
    email: dict[str, Any],
    attachment_findings: list[dict[str, Any]],
    existing_threads: list[dict[str, Any]],
) -> dict[str, Any]:
    """LLM call: merge into an existing thread node, or create a new one, and — in the same
    call, since the model already has the full email in front of it — extract whether this
    email describes a concrete, dated event worth adding to the user's calendar."""
    thread_lines = (
        "\n".join(f"- id={t['id']}: {t.get('summary', '')}" for t in existing_threads)
        or "(none yet)"
    )
    findings_text = (
        "\n".join(f"- {f['file']} ({f['kind']}): {f['finding']}" for f in attachment_findings)
        or "(none)"
    )
    prompt = (
        "You maintain a knowledge node for one topic. Given a new email and the "
        "topic's existing nodes (id + summary), decide whether this email is "
        "closely related enough to merge into one of them (e.g. another round of "
        "the same process: interview, PPT, OA, result) or is unrelated enough to "
        "start a new node.\n\n"
        "If merging, write an updated body that folds the new information into "
        "the existing one coherently (a running picture, not a raw concatenation) "
        "and a fresh short summary.\n"
        "If new, write a body and summary for just this email.\n\n"
        "Separately, decide whether this email describes something happening at a specific, "
        "concrete date/time — an interview, exam, meeting, deadline, competition, festival, "
        "or similar — as opposed to a vague or ongoing topic with no fixed occurrence. "
        'Its kind is "deadline" when it\'s something the reader must do or submit by that date '
        '(a form, fee, registration, assignment, application), otherwise "event". '
        f"REFERENCE DATE (when this email was sent, for resolving 'tomorrow'/'this Friday'): "
        f"{_reference_date(email)}.\n\n"
        f"EXISTING NODES IN THIS TOPIC:\n{thread_lines}\n\n"
        f"NEW EMAIL\nFrom: {email.get('from')}\nSubject: {email.get('subject')}\n"
        f"Body: {email.get('body_text', '')[:2000]}\n"
        f"Attachment findings:\n{findings_text}\n\n"
        "Reply with ONLY this JSON object, nothing else:\n"
        '{"action": "merge"|"new", "merge_into_id": "<id or null>", '
        '"summary": "<routing digest, <=120 words>", "body": "<full content>", '
        '"event": {"has_event": true|false, "kind": "deadline"|"event", '
        '"title": "<short event title, or empty>", '
        '"start": "<YYYY-MM-DD, or YYYY-MM-DDTHH:MM:SS if a specific time is given; '
        'empty if has_event is false>", '
        '"end": "<same format, or empty to default to start + 1 hour>", '
        '"location": "<or empty>"}}'
    )
    raw = _strip_fences(call_openrouter(prompt))
    return json.loads(raw)


# A BM25 score this high against an existing thread's summary is treated as "clearly a later
# round of the same process" — same order of magnitude as mail_ingest's own confidence floors
# (MIN_ABSOLUTE_SCORE), tuned empirically the same way.
OFFLINE_MERGE_THRESHOLD = 2.0

# A same-topic candidate whose body text is at least this similar to a new message is treated
# as the same announcement arriving twice (e.g. via mail and Slack), not a new round — high
# enough that two genuinely different rounds of the same process ("Round 1"/"Round 2") stay
# distinct threads, since their bodies differ far more than a verbatim repost does.
DUPLICATE_SIMILARITY_THRESHOLD = 0.85


def _find_duplicate_thread(
    body_text: str, existing_threads: list[dict[str, Any]]
) -> dict[str, Any] | None:
    """The existing thread (if any) whose body text is a near-duplicate of `body_text`.

    Uses difflib.SequenceMatcher — the same primitive brain/resolver.py already uses for
    fuzzy matching — rather than the LLM's or BM25's topic-level judgment, since "is this the
    same announcement" is a finer-grained question than "is this the same topic". Runs before
    both the LLM and offline merge paths so a duplicate is caught regardless of which one is
    active (see _ingest_message).
    """
    body_text = (body_text or "").strip()
    if not body_text:
        return None
    best_thread, best_ratio = None, 0.0
    for t in existing_threads:
        existing_body = (t.get("data", {}).get("body") or "").strip()
        if not existing_body:
            continue
        ratio = difflib.SequenceMatcher(None, body_text, existing_body).ratio()
        if ratio > best_ratio:
            best_thread, best_ratio = t, ratio
    return best_thread if best_ratio >= DUPLICATE_SIMILARITY_THRESHOLD else None


def _offline_merge_or_create_thread(
    email: dict[str, Any], existing_threads: list[dict[str, Any]]
) -> dict[str, Any]:
    """Non-LLM fallback for merge_or_create_thread, used when offline_mode is on.

    No narrative synthesis is possible without a model, so this is deliberately plainer than
    the LLM path: body is the raw email text (no folding-in of prior rounds), summary is a
    truncation of it, and no calendar event is ever extracted (that needs the same synthesis
    the LLM path provides). The merge decision itself is real, not a stub — it BM25-ranks the
    new email against existing threads' summaries in this topic, the same primitive
    brain/mail_ask.py already uses for thread search.
    """
    body_text = (email.get("body_text") or "").strip()
    summary = " ".join(body_text.split()[:30]) or (email.get("subject") or "")
    event = {"has_event": False, "title": "", "start": "", "end": "", "location": ""}

    if existing_threads:
        documents = {t["id"]: t.get("summary") or "" for t in existing_threads}
        ranked = bm25.rank(body_text, documents)
        if ranked and ranked[0][1] >= OFFLINE_MERGE_THRESHOLD:
            return {
                "action": "merge",
                "merge_into_id": ranked[0][0],
                "summary": summary,
                "body": body_text,
                "event": event,
            }
    return {
        "action": "new",
        "merge_into_id": None,
        "summary": summary,
        "body": body_text,
        "event": event,
    }


def gather_attachment_findings(
    email: dict[str, Any], config: dict[str, Any]
) -> list[dict[str, Any]]:
    """Process all attachments in an email and gather findings."""
    findings = []
    for att in email.get("attachments", []):
        saved_to = att.get("saved_to")
        if not saved_to:
            continue
        findings.append(process_attachment(Path(saved_to), config))
    return findings


def reparent_thread(conn: Any, thread_id: str, new_topic_id: str) -> None:
    """Ensure a thread has exactly one 'contains' parent.

    Drops any stale incoming 'contains' edge from a different topic before the
    caller adds the new one.
    """
    conn.execute(
        "DELETE FROM edges WHERE dst_id = ? AND relation = 'contains' AND src_id != ?",
        (thread_id, new_topic_id),
    )
    conn.commit()


def _merge_attachments(
    existing_thread: dict[str, Any] | None, findings: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    """Attachment findings for a thread, keeping those from earlier emails in it.

    A thread accumulates emails, and the shortlist naming you may have arrived in the first
    one — so a later email must not erase it. Deduplicated by filename.
    """
    prior = ((existing_thread or {}).get("data") or {}).get("attachments") or []
    merged = {f.get("file"): f for f in prior if isinstance(f, dict)}
    for finding in findings:
        merged[finding.get("file")] = finding
    return list(merged.values())


def _clean_subject(subject: str) -> str:
    """A subject usable as a topic name: strip Re:/Fwd: chains, collapse whitespace."""
    text = re.sub(r"^\s*(?:re|fwd|fw)\s*:\s*", "", subject or "", flags=re.I)
    while re.match(r"^\s*(?:re|fwd|fw)\s*:", text, flags=re.I):
        text = re.sub(r"^\s*(?:re|fwd|fw)\s*:\s*", "", text, flags=re.I)
    return re.sub(r"\s+", " ", text).strip() or "Untitled"


def ensure_category(conn: Any, title: str) -> str:
    """Upsert a mail_category and return its id. Shared by ingest and reclassification so both
    agree on the `mail:cat:<slug>` convention."""
    cat_id = f"mail:cat:{_slugify(title)}"
    store.upsert(
        conn,
        "mail_category",
        {"source_id": cat_id, "title": title},
        title=title,
        summary=f"Mail about {title}.",
        source="mail",
    )
    return cat_id


def ensure_topic(conn: Any, category_title: str, topic_title: str) -> str:
    """Upsert a mail_topic under a category, link them, and return the topic id.

    Ensures the parent category too, so the helper can never leave an edge pointing at a
    category row that doesn't exist. The topic id embeds the category slug, so moving a thread
    across categories necessarily creates a *new* topic row — the old one cannot be renamed,
    since the id is the primary key.
    """
    cat_id = ensure_category(conn, category_title)
    topic_id = f"mail:topic:{_slugify(category_title)}:{_slugify(topic_title)}"
    existing = store.get(conn, topic_id)
    store.upsert(
        conn,
        "mail_topic",
        {"source_id": topic_id, "title": topic_title},
        title=topic_title,
        summary=existing["summary"] if existing else f"Mail about {topic_title}.",
        source="mail",
    )
    store.add_edge(conn, cat_id, topic_id, "contains")
    return topic_id


MIN_LEARNED_TOKEN_LEN = 4
LEARNED_RULE_PREFIX = "mail:rule:"


def _learnable_tokens(text: str) -> list[str]:
    """Distinctive words from a corrected subject, usable as category keywords.

    Drops stopwords, short words and bare numbers ("2026"), which carry no category signal and
    would only add noise to the vocabulary.
    """
    seen: dict[str, None] = {}
    for token in bm25.tokenize(text):
        if len(token) < MIN_LEARNED_TOKEN_LEN or token.isdigit():
            continue
        if token in KEYWORD_STOPWORDS:
            continue
        seen[token] = None
    return list(seen)


def learn_category_keywords(conn: Any, category: str, text: str) -> list[str]:
    """Record the distinctive words of a corrected mail as keywords for its right category.

    This is what makes a manual fix durable: the next similar email is scored with the user's
    correction already in the vocabulary, instead of being misfiled the same way again. Stored
    per user (the brain DB is per-user), never in the shared config.
    """
    tokens = _learnable_tokens(text)
    if not tokens:
        return []
    rule_id = f"{LEARNED_RULE_PREFIX}{_slugify(category)}"
    existing = store.get(conn, rule_id)
    known: list[str] = list((existing["data"].get("keywords") if existing else []) or [])
    merged = known + [t for t in tokens if t not in known]
    store.upsert(
        conn,
        "mail_rule",
        {"source_id": rule_id, "title": category, "category": category, "keywords": merged},
        title=category,
        summary=f"Learned keywords for {category} (from manual corrections).",
        source="user-correction",
    )
    return merged


def learned_keywords(conn: Any) -> dict[str, list[str]]:
    """Every category's learned keywords for this user, as {category: [words]}."""
    out: dict[str, list[str]] = {}
    for rule in store.all_of_type(conn, "mail_rule"):
        category = rule["data"].get("category") or rule["title"]
        words = rule["data"].get("keywords") or []
        if category and words:
            out[category] = list(words)
    return out


def config_with_learned(conn: Any, config: dict[str, Any]) -> dict[str, Any]:
    """`config` with this user's learned keywords folded into category_keywords."""
    learned = learned_keywords(conn)
    if not learned:
        return config
    merged = {name: list(words) for name, words in (config.get("category_keywords") or {}).items()}
    for category, words in learned.items():
        current = merged.get(category, [])
        merged[category] = current + [w for w in words if w not in current]
    return {**config, "category_keywords": merged}


SETTINGS_ID = "mail:settings"


def get_settings(conn: Any) -> dict[str, Any]:
    """This user's saved pipeline settings (currently just offline_mode), as a plain dict."""
    entity = store.get(conn, SETTINGS_ID)
    if not entity:
        return {}
    return {k: v for k, v in entity["data"].items() if k != "source_id"}


def _update_settings(conn: Any, **updates: Any) -> dict[str, Any]:
    store.upsert(
        conn,
        "mail_settings",
        {"source_id": SETTINGS_ID, **get_settings(conn), **updates},
        title="Mail settings",
        summary="Per-user mail pipeline settings.",
        source="user",
    )
    return get_settings(conn)


def set_offline_mode(conn: Any, enabled: bool) -> dict[str, Any]:
    """Persist the offline-mode toggle for this user (brain.db is already per-user)."""
    return _update_settings(conn, offline_mode=enabled)


def set_slack_channel(conn: Any, channel_id: str) -> dict[str, Any]:
    """Persist which Slack channel /api/slack/reload pulls history from for this user."""
    return _update_settings(conn, slack_channel_id=channel_id)


def config_with_settings(conn: Any, config: dict[str, Any]) -> dict[str, Any]:
    """`config` with this user's saved settings overriding the file-based defaults."""
    settings = get_settings(conn)
    if "offline_mode" not in settings:
        return config
    return {**config, "offline_mode": bool(settings["offline_mode"])}


def cached_attachments_for(uids: list[str]) -> list[Path]:
    """The still-on-disk attachment files belonging to these source uids.

    emailtool saves them as `<uid>__<filename>` under its cache, which is what makes a re-scan
    possible at all — the mail itself is marked read and can never be fetched again.
    """
    found: list[Path] = []
    for uid in uids:
        found.extend(sorted(ATTACHMENT_CACHE.glob(f"{uid}__*")))
    return found


def rescan_attachments(conn: Any, config: dict[str, Any]) -> list[dict[str, Any]]:
    """Re-evaluate every thread's attachments against the *current* identifiers.

    Findings are computed once at ingest, so adding your roll number afterwards would other-
    wise leave every already-ingested shortlist saying "you were not listed" — silently wrong
    about the one thing this feature exists to answer. Returns the threads whose answer changed.
    """
    identifiers = [
        *(config.get("identifiers") or []),
        *profile.identifiers_from_profile(profile.load_profile(conn)),
    ]
    scan_config = {**config, "identifiers": identifiers}

    changed: list[dict[str, Any]] = []
    for thread in store.all_of_type(conn, "mail_thread"):
        data = thread.get("data") or {}
        paths = cached_attachments_for([str(u) for u in (data.get("source_uids") or [])])
        if not paths:
            continue

        # Compare the whole finding, not just the identifier hits: a file can go from
        # "attachment not parsed" to a fully transcribed menu without ever naming the user,
        # and that is exactly the change worth persisting.
        def _signature(
            findings: list[dict[str, Any]],
        ) -> dict[str, tuple[str, str, tuple[str, ...]]]:
            return {
                str(f.get("file")): (
                    str(f.get("kind")),
                    str(f.get("finding")),
                    tuple(sorted(f.get("mentions_you") or [])),
                )
                for f in findings
                if isinstance(f, dict)
            }

        old_findings = [f for f in (data.get("attachments") or []) if isinstance(f, dict)]
        before = _signature(old_findings)
        findings = [process_attachment(p, scan_config) for p in paths]
        after = _signature(findings)
        if after == before:
            continue

        payload = {**data, "attachments": findings}
        store.upsert(
            conn,
            "mail_thread",
            payload,
            title=thread["title"],
            summary=thread["summary"],
            source=thread["source"],
        )
        was = {m for _, _, mentions in before.values() for m in mentions}
        now = {m for _, _, mentions in after.values() for m in mentions}
        changed.append(
            {
                "thread_id": thread["id"],
                "title": thread["title"],
                "now_mentions": sorted(now - was),
            }
        )
    return changed


def prune_empty_mail_nodes(conn: Any) -> list[str]:
    """Delete mail topics with no threads and categories with no topics. Returns removed ids.

    Reclassification moves a thread out of its old topic, which can leave that topic — and its
    category — childless. /api/mail_tree renders every category regardless of children, so
    without this the mindmap accumulates ghosts.
    """
    removed: list[str] = []
    for topic in store.all_of_type(conn, "mail_topic"):
        if not store.neighbors(conn, topic["id"], "contains"):
            store.delete(conn, topic["id"])
            removed.append(topic["id"])
    for category in store.all_of_type(conn, "mail_category"):
        if not store.neighbors(conn, category["id"], "contains"):
            store.delete(conn, category["id"])
            removed.append(category["id"])
    return removed


def _resolve_event_times(event: dict[str, Any]) -> tuple[str, str] | None:
    """Normalize the extractor's event.start/end into a (start, end) pair Calendar can use, or
    None if there's nothing usable. A missing end defaults to start + 1 hour for a timed event,
    or the same single day for an all-day (date-only) one."""
    start = (event.get("start") or "").strip()
    if not start:
        return None
    end = (event.get("end") or "").strip()
    if end:
        return start, end
    if len(start) == 10:  # date-only, e.g. "2026-03-12"
        return start, start
    try:
        start_dt = datetime.fromisoformat(start)
    except ValueError:
        return None
    return start, (start_dt + timedelta(hours=1)).isoformat()


def _create_calendar_event_for_thread(
    event: dict[str, Any], uid: str, user_id: str | int | None
) -> dict[str, Any] | None:
    """If this email describes a dated event and the user's Google Calendar is connected, add
    it — returning the bookkeeping record to store on the thread (and to surface to the UI so
    it can offer an Undo), or None if nothing was created.

    Best-effort by design: a flaky Calendar API call must not fail the whole mail ingest, so any
    error here is swallowed rather than propagated.
    """
    if not event.get("has_event") or user_id is None:
        return None
    times = _resolve_event_times(event)
    if not times:
        return None
    try:
        if not calendar_tool.calendar_status(user_id).get("connected"):
            return None
        start, end = times
        title = event.get("title") or "Untitled event"
        location = event.get("location") or None
        event_id = calendar_tool.create_event(user_id, title, start, end, location)
    except Exception:
        return None
    return {"event_id": event_id, "title": title, "start": start, "end": end, "source_uid": uid}


def ingest_email(
    conn: Any, email: dict[str, Any], config: dict[str, Any], user_id: str | int | None = None
) -> dict[str, Any]:
    """Ingest one Gmail message. Thin adapter over `_ingest_message` — see that function for
    the actual pipeline, which is channel-agnostic (Slack messages ride the same code, see
    brain/slack_ingest.py)."""
    return _ingest_message(conn, email, config, user_id, channel="gmail")


def _ingest_message(
    conn: Any,
    message: dict[str, Any],
    config: dict[str, Any],
    user_id: str | int | None = None,
    *,
    channel: str = "gmail",
) -> dict[str, Any]:
    """Full per-message pipeline: attachments -> classify -> merge/place -> store.

    `message` is channel-agnostic: `{uid, from, subject, body_text, date, attachments}`.
    Nothing below branches on where it came from — classification, merging, and topic
    assignment all key off the same category/topic vocabulary regardless of `channel`, which
    is precisely what lets a Slack message and a Gmail thread about the same subject land
    under the same topic node (existing_threads below is queried by topic membership only,
    with no channel filter).

    No mark-read here — that's channel-specific and stays the caller's job.
    """
    # Attachment identifiers come from the user's stored profile ("About you"), so adding your
    # name there is enough — no config file to edit. Anything in config is kept as a fallback.
    config = config_with_settings(
        conn,
        {
            **config,
            "identifiers": [
                *(config.get("identifiers") or []),
                *profile.identifiers_from_profile(profile.load_profile(conn)),
            ],
        },
    )
    offline = bool(config.get("offline_mode"))
    findings = gather_attachment_findings(message, config)

    stored_categories = store.all_of_type(conn, "mail_category")
    seeded_names = {c["title"] for c in stored_categories}
    categories = stored_categories + [
        {"title": name, "summary": ""}
        for name in config.get("seeded_categories", [])
        if name not in seeded_names
    ]
    # Offline mode skips the LLM call entirely — arbitrate_category already tolerates a blank
    # llm_category (falls back to the top keyword score, or "low" confidence with none).
    classification = {} if offline else classify_email(message, findings, categories)

    subject = message.get("subject", "") or ""
    llm_category = (classification.get("category") or "").strip()
    # Fold in whatever this user has taught the classifier by correcting past mail.
    ranked = score_categories(
        subject,
        message.get("body_text", "") or "",
        message.get("from", "") or "",
        config_with_learned(conn, config),
    )
    cat_title, confidence = arbitrate_category(
        llm_category,
        ranked,
        {c["title"] for c in categories},
        sender_category=sender_precedent(conn, message.get("from", "") or ""),
    )
    classification["category"] = cat_title

    # A topic the LLM picked while assuming a different category is often just a restatement of
    # that rejected category ("Academics"), which reads as nonsense once the category is
    # corrected. Fall back to the subject line in that case.
    topic_title = (classification.get("topic") or "").strip()
    if not topic_title or normalize(topic_title) == normalize(llm_category):
        topic_title = _clean_subject(subject)
    classification["topic"] = topic_title
    topic_id = ensure_topic(conn, cat_title, topic_title)

    # No channel filter here — this is what lets a Slack message and a Gmail thread about the
    # same subject land in the same merge-candidate pool (see the docstring above).
    existing_threads = [
        t
        for t in store.all_of_type(conn, "mail_thread")
        if any(
            n["id"] == topic_id for n in store.neighbors(conn, t["id"], "contains", incoming=True)
        )
    ]
    duplicate_thread = _find_duplicate_thread(message.get("body_text", "") or "", existing_threads)
    if duplicate_thread:
        # Same announcement, second copy (e.g. mail + Slack) — collapse into the existing
        # thread untouched rather than treating it as a new round or a fresh thread.
        decision = {
            "action": "duplicate",
            "merge_into_id": duplicate_thread["id"],
            "summary": duplicate_thread.get("summary") or "",
            "body": duplicate_thread.get("data", {}).get("body") or "",
            "event": {"has_event": False, "title": "", "start": "", "end": "", "location": ""},
        }
    else:
        decision = (
            _offline_merge_or_create_thread(message, existing_threads)
            if offline
            else merge_or_create_thread(message, findings, existing_threads)
        )

    # Validate against every real thread, not just this topic's existing_threads: a merge target
    # from a different topic is legitimate (reclassification), a fully hallucinated id is not.
    valid_thread_ids = {t["id"] for t in store.all_of_type(conn, "mail_thread")}
    merges = decision["action"] in ("merge", "duplicate")
    if merges and decision.get("merge_into_id") in valid_thread_ids:
        thread_id = decision["merge_into_id"]
        existing_thread = store.get(conn, thread_id)
        prior_uids = (
            existing_thread["data"].get("source_uids", [])
            if existing_thread
            else []
        )
        uids = sorted({*prior_uids, message["uid"]})
        title = existing_thread["title"] if existing_thread else message.get("subject", "")
        source = ",".join(f"mail:{u}" for u in uids)
    else:
        existing_thread = None
        # Gmail keeps its historical id shape (untouched, so existing data/tests still match);
        # every other channel is namespaced to avoid a uid collision across channels.
        thread_id = (
            f"mail:thread:{message['uid']}"
            if channel == "gmail"
            else f"mail:thread:{channel}:{message['uid']}"
        )
        uids = [message["uid"]]
        title = message.get("subject", "")
        source = f"mail:{message['uid']}"

    # A thread the user has re-filed by hand stays where they put it. Without this, the next
    # message in that thread is scored afresh and reparent_thread drags the whole thread back —
    # silently undoing the correction.
    prior = (existing_thread or {}).get("data", {}).get("classification") or {}
    if prior.get("corrected_by_user") and prior.get("category"):
        cat_title = prior["category"]
        confidence = "high"
        parents = store.neighbors(conn, thread_id, "contains", incoming=True)
        topic_title = parents[0]["title"] if parents else topic_title
        topic_id = ensure_topic(conn, cat_title, topic_title)
        classification["category"] = cat_title
        classification["topic"] = topic_title

    prior_calendar_events = (existing_thread or {}).get("data", {}).get("calendar_events", [])
    # Guard against double-booking the same message (e.g. a retried ingest after a mark-read
    # failure on the previous attempt) — never a new API call for a uid already handled.
    created_event = None
    if not any(e.get("source_uid") == message["uid"] for e in prior_calendar_events):
        created_event = _create_calendar_event_for_thread(
            decision.get("event") or {}, message["uid"], user_id
        )
    calendar_events = [*prior_calendar_events, *([created_event] if created_event else [])]

    # Both deterministic, no LLM — computed on every message so a thread's urgency reflects
    # its most recent round (a "final reminder" reply should re-flag an otherwise-quiet
    # thread), while action items accumulate across merges instead of only keeping the latest.
    urgent = is_urgent(subject, message.get("body_text", "") or "") or bool(
        (existing_thread or {}).get("data", {}).get("urgent")
    )
    prior_action_items = (existing_thread or {}).get("data", {}).get("action_items", [])
    new_action_items = extract_action_items(message.get("body_text", "") or "")
    seen_texts = {item["text"].lower() for item in prior_action_items}
    action_items = prior_action_items + [
        item for item in new_action_items if item["text"].lower() not in seen_texts
    ]
    # A thread from before dates were recorded gets its earlier emails stamped with the row's
    # created_at, so first_received stays roughly right instead of jumping to this email.
    prior_received = (existing_thread or {}).get("data", {}).get("received_at")
    if prior_received is None and existing_thread and existing_thread.get("created_at"):
        prior_received = {
            u: existing_thread["created_at"] for u in existing_thread["data"].get("source_uids", [])
        }
    received_at = mail_timeline.merge_received(prior_received, message["uid"], message.get("date"))
    events = mail_timeline.merge_events(
        mail_timeline.thread_timeline(existing_thread)["events"] if existing_thread else [],
        mail_timeline.normalize_event(decision.get("event"), message["uid"]),
    )

    store.upsert(
        conn,
        "mail_thread",
        {
            "source_id": thread_id,
            "title": title,
            "body": decision["body"],
            "source_uids": uids,
            # Which channel this thread's most recent message arrived on — a thread that's
            # merged across channels keeps whichever channel ingested last, which is fine
            # since it's display metadata (a badge), not used for any routing decision.
            "channel": channel,
            # Kept so later mail from the same sender can be filed consistently
            # (see sender_precedent).
            "sender": message.get("from", "") or "",
            # Attachment findings used to be handed to the ingest-time prompts and thrown
            # away, so nothing downstream could answer "was I named in that spreadsheet?".
            # Persisting them is what makes attachments visible to mail Q&A.
            "attachments": _merge_attachments(existing_thread, findings),
            # Google Calendar events auto-created from this thread's messages — kept so a
            # repeat ingest doesn't double-book, and so the UI's Undo can find the event id.
            "calendar_events": calendar_events,
            # Deterministic "needs attention" signal (GET /api/needs-attention) and a unified
            # to-do list (GET /api/action-items) — both computed with zero LLM cost.
            "urgent": urgent,
            "action_items": action_items,
            # When each email arrived, and the dates they mention — see brain/mail_timeline.py.
            "received_at": received_at,
            "events": events,
            # Provenance for the UI and for debugging a wrong call: what each half of the
            # classifier thought, and how sure the combination was.
            "classification": {
                "category": cat_title,
                "confidence": confidence,
                "llm_category": llm_category or None,
                "keyword_category": ranked[0][0] if ranked else None,
                "scores": {name: round(score, 2) for name, score in ranked[:3]},
                # Carried forward so the pin survives every later message in this thread.
                **(
                    {"corrected_by_user": True, "auto_category": prior.get("auto_category")}
                    if prior.get("corrected_by_user")
                    else {}
                ),
            },
        },
        title=title,
        summary=decision["summary"],
        source=source,
        needs_review=(confidence == "low"),
    )
    reparent_thread(conn, thread_id, topic_id)
    store.add_edge(conn, topic_id, thread_id, "contains")

    try:
        # Best-effort: a flaky Slack post must not fail the whole ingest, same rationale as
        # the calendar-event creation above.
        automation.evaluate_and_notify(
            conn, category=cat_title, urgent=urgent, title=title, channel=channel
        )
    except Exception:
        pass

    return {
        "uid": message["uid"],
        "category": cat_title,
        "topic": topic_title,
        "thread_id": thread_id,
        "action": decision["action"],
        "confidence": confidence,
        "channel": channel,
        "calendar_event": {**created_event, "thread_id": thread_id} if created_event else None,
    }


EMAILTOOL = Path(__file__).resolve().parent / "emailtool.py"


def fetch_unread_emails(
    since_minutes: int | None = None, user_id: str | int | None = None
) -> list[dict[str, Any]]:
    """Run emailtool.py list; return the parsed unread-email list.

    `user_id` crosses the subprocess boundary as an explicit CLI argument, not an inherited
    env var — mutating process-global env vars per request would leak identity across
    concurrently-running per-user ingest calls in the same server process.
    """
    cmd = [sys.executable, str(EMAILTOOL), "list"]
    if since_minutes is not None:
        cmd += ["--since-minutes", str(since_minutes)]
    if user_id is not None:
        cmd += ["--user-id", str(user_id)]
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=600,
    )
    if proc.returncode != 0:
        raise SystemExit(f"emailtool.py list failed: {proc.stderr.strip()}")
    return json.loads(proc.stdout)


def mark_email_read(uid: str, user_id: str | int | None = None) -> None:
    """Run emailtool.py mark-read <uid>."""
    cmd = [sys.executable, str(EMAILTOOL), "mark-read", uid]
    if user_id is not None:
        cmd += ["--user-id", str(user_id)]
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=60,
    )
    if proc.returncode != 0:
        raise SystemExit(f"emailtool.py mark-read failed: {proc.stderr.strip()}")


def run_iter(
    conn: Any = None,
    since_minutes: int | None = None,
    user_id: str | int | None = None,
) -> Iterator[dict[str, Any]]:
    """Same pipeline as `run`, yielding a progress event per step.

    Each email costs two LLM round-trips plus attachment parsing, so a batch of ten can run for
    a minute or more. Emitting events as they complete is what lets the UI show a percentage
    that reflects reality instead of an animation that guesses.

    Events: {"stage": "connecting"} -> {"stage": "fetched", "total": N} ->
    {"stage": "ingested", "done": i, "total": N, ...} per email -> {"stage": "done", ...}
    """
    conn = conn or store.connect(user_id=user_id)
    config = load_config()

    yield {"stage": "connecting"}
    emails = fetch_unread_emails(since_minutes, user_id=user_id)
    total = len(emails)
    yield {"stage": "fetched", "total": total}

    results: list[dict[str, Any]] = []
    for index, email in enumerate(emails, start=1):
        subject = email.get("subject") or "(no subject)"
        # Announce *before* the slow part, so the UI can name what it is currently working on.
        yield {"stage": "ingesting", "done": index - 1, "total": total, "subject": subject}
        try:
            result = ingest_email(conn, email, config, user_id=user_id)
            mark_email_read(email["uid"], user_id=user_id)
        except (Exception, SystemExit) as exc:  # one bad email must not stop the whole run
            result = {"uid": email.get("uid"), "error": str(exc)}
            results.append(result)
            yield {
                "stage": "ingested",
                "done": index,
                "total": total,
                "subject": subject,
                "error": str(exc),
            }
            continue
        results.append(result)
        yield {
            "stage": "ingested",
            "done": index,
            "total": total,
            "subject": subject,
            "category": result.get("category"),
            "topic": result.get("topic"),
            "calendar_event": result.get("calendar_event"),
        }

    yield {"stage": "done", "processed": len(results), "results": results}


def run(
    conn: Any = None,
    since_minutes: int | None = None,
    user_id: str | int | None = None,
) -> list[dict[str, Any]]:
    """Fetch unread mail, ingest each into the tree, mark read only on success.

    Thin wrapper over `run_iter` for the CLI and any caller that just wants the outcome.
    """
    results: list[dict[str, Any]] = []
    for event in run_iter(conn, since_minutes, user_id=user_id):
        if event["stage"] == "done":
            results = event["results"]
    return results


def main() -> None:
    usage = "usage: python -m brain.mail_ingest run [--since-minutes N]"
    if len(sys.argv) < 2 or sys.argv[1] != "run":
        print(usage, file=sys.stderr)
        sys.exit(2)
    since_minutes = None
    if "--since-minutes" in sys.argv:
        idx = sys.argv.index("--since-minutes")
        if idx + 1 >= len(sys.argv):
            print(usage, file=sys.stderr)
            sys.exit(2)
        since_minutes = int(sys.argv[idx + 1])
    for result in run(since_minutes=since_minutes):
        if "error" in result:
            print(f"[error] uid {result['uid']}: {result['error']}")
        else:
            tid = result["thread_id"]
            print(f"[{result['action']}] {result['category']} / {result['topic']} -> {tid}")


if __name__ == "__main__":
    main()
