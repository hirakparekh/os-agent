# 0002 — Cache-first rendering

## Decision

Every read-only screen renders from on-device storage first. The network is a background
refresh that updates that storage, never something the UI waits on.

A failed refresh **keeps the last good data on screen** with a "synced N ago" marker. It does
not clear the screen, show an error page, or replace content with a spinner.

Storage is **plain JSON files** via `path_provider`, not SQLite.

## Why

The user asked for the knowledge map to work with no network, which makes persistence a
feature rather than a cache. Retrofitting local-first onto a network-first app is a rewrite;
building it in from the first screen costs almost nothing.

JSON files rather than a database because the whole dataset arrives as three whole-payload
responses totalling tens of threads. There is nothing to query, nothing to page, and no schema
to migrate. `sqflite` would add a dependency, a schema, and migration handling to store three
blobs. `drift` would add code generation on top of that.

Writes go to a temporary file and are renamed into place, so a process kill mid-write cannot
leave a truncated file that fails to parse on next launch. A corrupt cache is treated as an
absent one rather than crashing.

## What works offline, and what does not

Working, from one cached `/api/mail_tree` payload plus the two feeds:

- the Today feed — urgent threads and action items
- the whole knowledge tree
- **every thread's full detail**, because bodies ride inline in the tree response
  ([0004](0004-api-contract-traps.md) §5)
- past chat conversations, from the cached session list

Not working, and visibly disabled rather than silently failing:

- asking a new question (needs the model)
- syncing mail (needs IMAP)
- connecting Gmail or Calendar (needs consent in a browser)
- reclassifying a thread (a write)
- speaking or transcribing (needs the voice service)

## Deliberately not done: an offline write queue

Reclassification could be queued and replayed on reconnect. It is not, because a correction
replayed against a tree that has since changed can land the thread in a category that no longer
exists, and resolving that needs conflict handling the app has no UI for. Showing the control
as unavailable is honest; queueing it and silently dropping or misapplying it later is not.

Worth revisiting if triage-on-the-train becomes a real usage pattern.

## Naming trap

The backend has a setting called `offline_mode`. It means **"do not call the language model"** —
IMAP still runs. It has nothing to do with this document. The app surfaces it as
*"Skip AI processing"* rather than repeating a name that means something else here.
