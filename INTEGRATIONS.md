# Connecting Gmail, Google Calendar, and Slack

The detailed, step-by-step version of all three — including the one-time Google Cloud OAuth
client setup — lives in `SETUP.md` (§6 "First login and connecting Gmail" for Gmail/Calendar).
This file is the short summary.

> ⚠️ Never commit `.env` or paste tokens into chat. `.env` is git-ignored on purpose.

## 1. Gmail and Google Calendar (OAuth, per-user)

Both go through the same redirect-based consent flow (`brain/oauth_flow.py`): open the
Integrations page → **Connect** → approve in your own browser → the app polls and flips to
"Connected." No tokens ever go in `.env` for these — each user's grant is stored server-side,
keyed to their account.

One-time setup, done once per deployment (not per user): register an OAuth client in Google
Cloud Console and save its credentials JSON where `GMAIL_CREDENTIALS_PATH` points. Full steps
in `SETUP.md` §6.

**Expect to reconnect about weekly** — this app requests a restricted Gmail scope
(`https://mail.google.com/`) on an unverified OAuth client, so Google expires refresh tokens
after 7 days. That's routine, not a bug; the UI offers **Connect** again when it happens.

## 2. Slack (message ingestion)

Slack messages flow into the *same* knowledge tree as mail — same categories, same topics, and
a Slack message about the same subject as an email can merge into one thread
(`brain/slack_ingest.py` feeds the same channel-agnostic pipeline as Gmail).

1. Create an app at https://api.slack.com/apps → *From scratch*.
2. *OAuth & Permissions* → *Bot Token Scopes* → add **`channels:history`**.
3. *Install to Workspace* → copy the **Bot User OAuth Token** (`xoxb-...`).
4. Invite the bot to the channel you want ingested: `/invite @YourApp`.
5. Get the channel id (click the channel name → id is at the bottom of the popup).

```
SLACK_BOT_TOKEN=xoxb-...
SLACK_CHANNEL=C0XXXXXXX
```

**Known gap:** this has been built and unit-tested with a stand-in, but the real Slack API call
has never executed against a live workspace — see `CURRENT_STATE.md`'s "Known gaps."

## What I need from you (summary)

| To turn on | You provide |
|---|---|
| Gmail | nothing in `.env` for the token itself — connect from the Integrations page (needs the one-time OAuth client from `SETUP.md` §6) |
| Google Calendar | same redirect flow, same OAuth client, a separate **Connect** on the Integrations page |
| Slack ingestion | `SLACK_BOT_TOKEN`, `SLACK_CHANNEL` (+ invite the bot to the channel) |
