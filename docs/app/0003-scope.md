# 0003 — What the app is, and what it is not

## What it is

A **"Today" action inbox** with the knowledge tree behind it — not a port of the web console.

The reasoning, which two people reached independently: browsing and orientation are strictly
better on a laptop. What a phone is uniquely good at is telling you the thing you would
otherwise miss. So the feeds lead and the tree follows.

Three properties make the feeds the right thing to build around. Urgency and action items are
computed **deterministically** at ingest — keyword and regex, no model — so they are exact,
cost nothing to poll, and keep working with AI processing switched off. They are already
**cross-channel**, flattening Gmail and Slack into one list. And they are tiny, which is what a
phone screen wants.

## Built

| Surface | Where |
|---|---|
| Sign in | `screens/login.dart` |
| Today — urgent threads, open to-dos | `screens/today.dart` |
| Knowledge tree, offline | `screens/tree.dart` |
| Thread detail, with dates | `screens/thread.dart` |
| Ask questions, with voice | `screens/chat.dart`, `voice.dart` |
| Needs a decision (review + reclassify) | `screens/review.dart` |
| Insights | `screens/insights.dart` |
| Automation rules | `screens/rules.dart` |
| Connections, processing, sign out | `screens/settings.dart` |
| Urgent-mail notifications | `notifications.dart` |

## Deliberately not built

**The force-directed mind map.** The largest single piece of work in a port and the worst fit
for a small screen. Nested expandable lists carry the same structure, navigate with a thumb,
and render from cache. Both agents working on this project reached that independently.

**Push that wakes a closed app.** Notifications poll while the app is running. Real push needs
Firebase Cloud Messaging plus a server-side sender — free, but it is a Firebase project, a
`google-services.json`, a server change, and a device token to register. Polling delivers most
of the value with none of that. This is the most likely next thing to build, and the point at
which the app will also want a router ([0001](0001-architecture.md)).

**Slack channel configuration.** Slack *results* appear in the tree tagged by channel, but
setup stays on the web console: typing a channel ID on a phone keyboard is miserable and the
token is organisation-wide anyway. Note the Slack path has never run against real Slack — it
needs a scope that has not been granted — so do not demo it untested.

**An offline write queue.** See [0002](0002-offline-first.md).

**A charting library.** One horizontal bar chart over a few dozen rows is a `LinearProgressIndicator`
and a sort. A chart package would be a dependency, a theme surface, and a render pipeline for
that.

## Not yet verified

None of this has been compiled. The Flutter SDK was absent from the machine where it was
written, so the platform scaffolding does not exist and `flutter analyze` has never run.

API shapes were checked against the server source rather than guessed — which caught two
silent failures before they shipped ([0004](0004-api-contract-traps.md)) — but reading the
source is a weaker guarantee than running it. Expect the first `flutter analyze` to find real
problems, most likely in `voice.dart`, which is the only file touching device hardware.
