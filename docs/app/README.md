# Android app — decision log

Why the Flutter client is built the way it is. Each record states the decision, what it was
chosen over, and what would make it wrong — so a future change can tell whether it is
correcting a mistake or undoing something load-bearing.

Records are numbered in the order they were made and are not rewritten once landed; a reversal
gets a new record that supersedes the old one.

| # | Decision | Status |
|---|---|---|
| [0001](0001-architecture.md) | Layering, state management, and why there is no router | current |
| [0002](0002-offline-first.md) | Cache-first rendering, and what may not work offline | current |
| [0003](0003-scope.md) | What the app includes, what it deliberately omits | current |
| [0004](0004-api-contract-traps.md) | Backend shapes that look obvious and are not | current |
| [0005](0005-auth-and-reconnect.md) | Tokens, and why weekly reconnect is a feature not an error | current |
| [0006](0006-voice.md) | Speech in and out, and the risk it carries | current |

## Reading order for someone new

Start with [0003](0003-scope.md) to see what the app is, then [0001](0001-architecture.md) for
how it is put together. [0004](0004-api-contract-traps.md) is the one to read before touching
anything that talks to the backend — it documents two shapes that already caused silent
failures.

## Status of the build

The Dart source is complete for the scope in [0003](0003-scope.md). **None of it has been
compiled** — the Flutter SDK was not installed on the machine where it was written, so the
platform scaffolding (`android/`, Gradle) does not exist yet and `flutter analyze` has never
run. See `app/README.md` for the steps to generate it.

Treat every file as reviewed but unverified. The API shapes were checked against the server
source rather than assumed, which is a different and weaker guarantee than having run them.
