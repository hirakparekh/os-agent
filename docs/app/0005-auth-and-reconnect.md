# 0005 — Tokens, and why reconnecting weekly is a feature

## Decision

Two separate credentials, handled differently:

| | Stored | Lifetime | On expiry |
|---|---|---|---|
| App session (JWT) | `flutter_secure_storage` | long | sign out, return to login |
| Google grant | **server-side only** | **7 days** | show *Connect*, not an error |

The app never holds a Google token, and never sees the OAuth redirect.

## The consent flow, and why there is no deep link

1. app asks the server for a consent URL (`POST /api/mail/connect` → `{auth_url}`)
2. app opens it with `url_launcher` in an external browser
3. the user consents; **Google redirects to the server's** `/api/oauth/callback`
4. the server exchanges the code and stores the token
5. the app polls `GET /api/mail/status` until it flips to connected

The redirect never returns to the app. That means **no custom URL scheme, no intent filter, no
`flutter_web_auth_2`** — and none of the failure modes where a callback fails to reach the app.
`flutter_web_auth_2` is the right tool when the *client* performs the code exchange; here the
server does.

Polling gives up after two minutes so an abandoned consent does not leave a poller running.

## Weekly reconnect is not a bug

This project requests `https://mail.google.com/` — full Gmail access, which IMAP requires, and a
**restricted** scope. The app is unverified, and Google expires refresh tokens for unverified
apps after **7 days**. Publishing to Production does not lift this; only full verification with a
third-party security assessment does, which is weeks and four figures — out of scope for a
two-month project.

So roughly eight reconnections per user over the project's life, forever, by design.

The UI is built around that:

- `needs_reconnect` from the server renders as a **tertiary-coloured action bar with a Connect
  button**, never a red error
- `connected_at` lets the app warn *before* the grant lapses rather than reporting failure after
- copy says "Gmail needs reconnecting", not "authentication failed"

**Operationally: reconnect deliberately before any demo.** An expired grant looks exactly like an
empty inbox, with no error anywhere to explain it. This is the single most likely way the project
embarrasses someone.
