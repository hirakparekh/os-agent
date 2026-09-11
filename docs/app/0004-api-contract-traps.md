# 0004 — Backend shapes that look obvious and are not

Read this before changing anything in `api.dart` or `models.dart`. Every item below was found
by reading the server source; each one had already been written the wrong way first, and none
of them fail loudly.

## 1. The sync stream is NDJSON, not server-sent events

`POST /api/mail/reload/stream` sets `application/x-ndjson` and writes one bare JSON object per
line (`brain/viz_server.py`, `events()`). It has **no `data:` prefix and no blank-line frame
separator**.

An SSE parser filtering for `data:` matches nothing, yields nothing, and produces a sync that
appears to hang forever with no error. The endpoint superficially resembles SSE, which is what
makes it dangerous.

## 2. `done` in those events is a count, not a boolean

Events are `{"stage": "ingesting", "done": 3, "total": 10, "subject": "..."}`. `done` is how
many messages have been processed. Modelling it as `bool` is a runtime type error partway
through a sync, after the first few frames have already parsed.

Use `stage == 'done' || stage == 'failed'` to detect the end. Stages run
`connecting → fetched → (ingesting → ingested)* → done`, or `failed`.

## 3. Feed filtering keys on update time, not creation time

`?since=` on `/api/needs-attention` and `/api/action-items` filters on `updated_at`.
`brain/store.py` COALESCEs the original `created_at` through an upsert, so a thread that has
just *become* urgent keeps its old creation date. Filtering on `created_at` would miss exactly
the case notifications exist for.

## 4. Action items have no id, and recur legitimately

They are flattened out of thread payloads, so identity is `(thread_id, text)` — `ActionItem.dedupKey`.
Urgency and action items are recomputed on **every** merge, so an old thread can re-enter the
feed when a new message lands on it. A notifier that assumes "anything in the window is unseen"
will re-notify about the same to-do repeatedly.

## 5. The tree carries thread bodies inline

`GET /api/mail_tree` returns the whole tree with `body`, `classification`, `channel`, and the
timeline fields on each thread node, with no pagination. There is **no per-thread endpoint** and
none is needed. This is what makes offline detail free — see [0002](0002-offline-first.md).

## 6. Two services, one token

`console` (`/auth`, `/chat`, `/voice`) and `brain` (`/api/*`) are separate processes that both
verify the same HS256 JWT. One login authenticates both. In a hosted deployment they sit behind
one origin with `/api/*` routed to brain, which is why `ApiConfig` collapses to a single base
URL outside local development.

## 7. Empty feeds are a correct state

Urgency and action items are computed during ingest. Threads ingested before those features
existed carry neither until the next sync. An empty Today screen is not a bug and the UI says so
rather than showing a spinner or an error.
