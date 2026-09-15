# Prompt: hand this to your teammate's Claude Code agent

Paste the block below into a fresh Claude Code session in the cloned repo. It walks the agent
through full setup, asking the human for secrets interactively rather than guessing/inventing
them, and never commits anything sensitive.

---

```
Set up the mail knowledge-tree pipeline in this repo (see SETUP.md for full reference — follow
it, and ask me questions when you need a value from me). Do this step by step:

1. Confirm prerequisites: Python matching .python-version, and `uv` installed. If uv is
   missing, tell me how to install it and stop.

2. Run `uv sync` to install dependencies.

3. Create `.env` from `.env.example` (copy, don't invent placeholder values as if they were
   real). Then ask me, one at a time, for:
   - My OpenRouter API key(s) — tell me to sign up free at openrouter.ai if I don't have one,
     generate a key, and I can give you multiple comma-separated keys for rotation resilience.
   - My email address and IMAP app password for the mailbox I want the pipeline to read.
     If I say I use Gmail: walk me through turning on 2-Step Verification, generating an App
     Password (Google Account -> Security -> App Passwords), and enabling IMAP
     (Gmail Settings -> Forwarding and POP/IMAP -> Enable IMAP) BEFORE asking me for the
     16-character app password — don't ask for it until I've confirmed I have it.
   Fill EMAIL_EMAIL, EMAIL_APP_PASSWORD, EMAIL_IMAP_HOST (imap.gmail.com for Gmail),
   OPENROUTER_API_KEYS, and OPENROUTER_MODEL (default liquid/lfm-2.5-2.6b:free — check
   https://openrouter.ai/api/v1/models if that model 404s, free models get deprecated) into
   .env with what I give you. Do not print my secrets back to me or into any file other than
   .env. Confirm .env is git-ignored (`git check-ignore .env`) before doing anything else.

4. Create `brain/mail_config.json` from `brain/mail_config.example.json`. Ask me:
   - Do I want the default 3-category scheme (Lectures & Profs / Placements / General
     College), or different categories? Update seeded_categories if I want something else.
   - Do I want the placement-tracking attachment features (matching my student ID against
     Excel selection lists, matching my résumé against job-description PDFs)? If yes, ask for
     my student ID and the path to a résumé file, and fill those into mail_config.json.
     If no, leave those two fields blank.
   Confirm brain/mail_config.json is git-ignored before moving on.

5. Run the test suite (`uv run pytest -q`) and ruff (`uv run ruff check brain/ tests/`) to
   confirm the environment is sound. Report the results to me plainly — don't just say
   "success," show the actual pass/fail counts.

6. Do a live smoke test: run `uv run python -c "from brain import mail_ingest; print(len(mail_ingest.fetch_unread_emails()))"`
   and tell me how many unread emails it found. If it errors, read the error message back to
   me verbatim and help me fix the .env value it's complaining about — don't guess.

7. Ask me: do I want to actually run the full pipeline now? Warn me first that it will mark
   processed emails as read in my real inbox and spend OpenRouter API calls. If I say yes, run
   `uv run python -m brain.mail_ingest run` and report what it built (categories/topics/threads
   created).

8. Start the visualization server (`uv run uvicorn brain.viz_server:app --port 8080`) and tell
   me to open http://127.0.0.1:8080/mail-tree in my browser to see the tree.

Never commit .env or brain/mail_config.json — both are already git-ignored, just don't
override that. If anything in SETUP.md conflicts with what I tell you interactively, ask me
which should win rather than picking silently.
```
