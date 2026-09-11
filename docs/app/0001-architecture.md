# 0001 — Layering, state, and no router

## Decision

Five layers, each depending only on the one below:

```
screens/          Flutter widgets. No HTTP, no JSON, no persistence.
app_state.dart    One ChangeNotifier holding everything the UI reads.
api.dart          The only place that speaks HTTP. Returns models, never maps.
cache.dart        On-device persistence. Returns models, never maps.
models.dart       Plain data. No imports beyond dart:core.
```

**State: a single `ChangeNotifier` via `provider`.** Not Riverpod, not Bloc.

**Navigation: `Navigator.push` and an `IndexedStack`.** No `go_router`, no named routes.

## Why

The app has one user, one account, and perhaps a dozen screens' worth of content sourced from
three whole-payload endpoints. A single observable object holds all of it without strain, and
`provider` is the smallest thing that makes it observable. Riverpod's providers and Bloc's
event/state classes both buy testability and independent invalidation that this app has no use
for — every screen wants the same three payloads, refreshed together.

No router because there are no deep links to serve. The OAuth redirect — the one flow that
would normally demand them — is completed by the *server*, so nothing ever needs to route into
a cold app at a specific screen (see [0005](0005-auth-and-reconnect.md)). Adding a router would
be paying for an address space nothing addresses.

`api.dart` and `cache.dart` both return models rather than maps so that no JSON key appears
above the data layer. A renamed backend field then breaks in one file, loudly, instead of
spreading `thread['name']` lookups through the widget tree.

## What would make this wrong

- **A second user, or roles.** Shared mutable state across accounts needs scoping this does not
  have.
- **Push notifications that open a specific thread.** That is a genuine deep link and wants a
  router — this is the most likely trigger, and it arrives with the notification work.
- **Screens that need independent refresh.** If a list has to reload without the rest of the app
  following it, one notifier becomes a bottleneck and the rebuilds get wasteful.

None of these are true yet. The first of them to become true is the moment to revisit.
