# Keyword-first category classification (skip the LLM when confident)

## Problem

Every ingested email triggers one LLM call (`classify_email`) that decides both category and
topic together, sending the full list of existing categories and reasoning about which one
fits. Separately, a deterministic keyword scorer (`score_categories` + `_is_confident`) already
runs afterward and overrides the LLM's category choice whenever it's confident — which happens
often, since the keyword lists are hand-tuned per category. That confident keyword answer is
computed today, but only used *after* paying for the full LLM call.

## Change

Reorder ingestion so the keyword scorer runs first, before any LLM call:

1. Run `score_categories` (unchanged, same confidence bar: `MIN_ABSOLUTE_SCORE`, `MARGIN_RATIO`,
   `MARGIN_DELTA` — the exact bar already used today to override the LLM).
2. If `_is_confident(ranked)`: the category is decided deterministically. Skip `classify_email`
   entirely. Call a new, smaller LLM function, `classify_topic_only`, that takes the category as
   a given fact and the existing topics *under that category only* (not the whole category
   list), and asks only for the topic name. No category reasoning, no full category list, no
   `new_category`/`new_topic` fields (checked: unused anywhere downstream today).
3. If not confident: unchanged. Call `classify_email` (full prompt) then `arbitrate_category`
   exactly as today.
4. Both paths produce the same `{category, topic}` shape, so everything downstream (`ensure_topic`,
   duplicate detection, `merge_or_create_thread`) is untouched.

The filing decision is identical to today's in the confident case — `arbitrate_category`'s
`_is_confident` branch already returns the same keyword top-pick regardless of what the LLM
said. Only the cost changes, not the outcome.

## New pieces

- `topics_under_category(conn, category_title) -> list[dict]`: filters `mail_topic` entities by
  the `mail:topic:<cat-slug>:` id prefix (topics are already namespaced this way via
  `ensure_topic`). No new schema.
- `classify_topic_only(email, attachment_findings, category_title, topics) -> dict`: same shape
  of LLM call as `classify_email`, but the prompt fixes the category and only asks for
  `{"topic": "<name>"}`.

## Out of scope

- Topic assignment stays LLM-driven in both paths (per discussion: topic names are
  free-form/specific, e.g. company names, and there's no reliable deterministic matcher for them
  yet — a separate, bigger idea if pursued later).
- No change to `ask_mail` / the questioning side — this is ingestion-only.
- No change to the confidence bar itself.

## Testing

- Existing `classify_email`/`arbitrate_category` tests are unaffected (non-confident path).
- New test: when `score_categories` returns a confident result, `classify_email` must not be
  called at all, `classify_topic_only` must be called instead, and the resulting category must
  equal `arbitrate_category`'s output for the same confident input on the old path (same
  decision, different cost).
- New test: `topics_under_category` returns only topics under the given category, not other
  categories' topics.
