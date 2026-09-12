---
description: One autonomous iteration on Agent OS — repair env, take the next task from .loop/PROGRESS.md, implement, verify, commit to dev locally. Run as `/loop /agentos-tick`.
---

You are running ONE unattended iteration of the Agent OS work loop. The user is away. Never ask
questions — if something needs a human, record it under **Blockers** in `.loop/PROGRESS.md` and move
on to the next unblocked task.

Run from the repository root. Put the tools on PATH in every shell:
`export PATH=$HOME/.local/bin:$HOME/Android/Sdk/emulator:$HOME/Android/Sdk/platform-tools:$PATH`
(`uv` lives in the first, `emulator`/`adb` in the others).

## 1. Orient (keep it cheap)
- Read `.loop/PROGRESS.md` fully. It is the source of truth for queue, done log, blockers, notes.
- `git status --short` and `git branch --show-current`. You must be on `dev`. If there are
  uncommitted changes you did not make this tick, read them: finish them if they are a half-done
  slice from a previous tick (per PROGRESS notes), otherwise leave them and record a blocker.
- Consult `HANDOFF.md` / `docs/app/*.md` only for the section relevant to the chosen task.

## 2. Environment check & repair
- `curl -sf localhost:8080/` and `curl -sf localhost:8000/health`. If either is down, restart it
  detached (NEVER `--reload`):
  `setsid nohup uv run uvicorn brain.viz_server:app --host 127.0.0.1 --port 8080 > .loop/logs/brain.log 2>&1 < /dev/null &`
  `setsid nohup uv run uvicorn console.backend.main:app --host 127.0.0.1 --port 8000 > .loop/logs/console.log 2>&1 < /dev/null &`
  Restart them also after changing backend Python code.
- `adb devices`. Prefer a physical phone if one is attached and unlocked — check with
  `adb -s <serial> shell dumpsys window | grep isKeyguardShowing`; a locked phone screenshots
  as a black rectangle and swallows every tap, so fall back to the emulator.
- If no usable device, boot the emulator headless. `-gpu host` has been required in practice:
  `swiftshader_indirect` and `guest` both segfault qemu on at least one Linux host.
  `setsid nohup emulator -avd agentos -no-window -no-audio -no-boot-anim -no-snapshot -gpu host > .loop/logs/emulator.log 2>&1 < /dev/null &`
  then `adb wait-for-device` and poll `adb shell getprop sys.boot_completed` until `1`.
- A phone that is unplugged and replugged loses its `adb reverse` mappings, which the app
  reports as "Gmail not connected" rather than as a network fault. Re-run them after every
  reconnect before concluding anything is broken.
- With a device attached: `adb reverse tcp:8000 tcp:8000 && adb reverse tcp:8080 tcp:8080`.

## 3. Pick and do ONE slice
- Take the top unblocked item in **Queue**. Do the smallest slice that can be verified and
  committed on its own. Write the test first when the change is testable (Dart: `app/test/`;
  Python: `tests/`).
- Follow `~/.claude/CLAUDE.md`: surgical changes, match surrounding style and comment density, no
  speculative features, no refactors of unrelated code.

## 4. Verify (only the gates for what you touched — all must pass)
- `app/`: `flutter analyze` (zero issues) + `flutter test` + `flutter build apk --debug`.
  For UI-visible changes: `adb install -r build/app/outputs/flutter-apk/app-debug.apk`,
  `adb shell monkey -p dev.agentos.agent_os -c android.intent.category.LAUNCHER 1`, drive with
  `adb shell input tap/text/swipe`, capture `adb exec-out screencap -p > .loop/shots/<name>.png`
  and Read the PNG to actually look at it.
  Never tap hard-coded coordinates after the keyboard opens — the layout shifts. Get bounds
  first: `adb shell uiautomator dump /sdcard/ui.xml && adb exec-out cat /sdcard/ui.xml`.
  Logcat does NOT carry Dart exception text; to capture it run the app with
  `flutter run -d <device> > .loop/logs/flutter-run.log 2>&1` (background task) and read the
  `EXCEPTION CAUGHT` block. Stop that task when done. Reproduce any device bug as a widget test
  first, then fix.
- Python: `uv run pytest -q && uv run mypy && uv run lint-imports && uv run ruff check . && uv run ruff format --check .`
- Frontend: `cd console/frontend && npm run build`.
- Deploy files: `docker compose -f <file> build` and `up -d`, curl through Caddy, then `down`.

If still red after two fix attempts: `git restore`/`git clean` ONLY the files of this slice,
record the failure (command + key error lines) under Blockers, and end the tick.

## 5. Commit (local only)
- `git add <explicit paths>` (never `git add -A` / `git add .`), read `git status`, then
  `git commit -m "<type>(<scope>): <what and why>"`. Conventional style matching `git log`.
- NO Claude/Anthropic attribution or trailers in commit messages (repo rule, HANDOFF §9).

## 6. Record
Update `.loop/PROGRESS.md`: move the item to **Done** with the commit hash and a one-line result,
add any new tasks discovered to **Queue** (in priority order), update **Blockers**, and refresh
the **Morning summary** section (what works now, how to test on the phone, what needs the user).
If the Queue has no unblocked items left, end the loop with ScheduleWakeup `stop: true`.

## Hard rules
- Never `git push`, never switch to/merge into/modify `main`, never rewrite history.
- No AWS / `aws` CLI calls, no infra provisioning, no spending money.
- Never commit `.env`, `console/frontend/.env.local`, `~/.hermes/*`, credentials, or `*.db`.
  `.loop/` is scratch (progress log, screenshots, the disposable test account's password) and
  is gitignored — keep it that way.
- Never tap remembered screen coordinates. Dump the UI, find the label, tap that: layouts shift
  between builds and between keyboard states, and a stray tap has already mutated real data
  and opened a Sign out dialog on someone's phone.
- Never read/modify real users' data under `brain/data/users/<id>/`; test with the disposable
  loop test account (see PROGRESS notes) or the e2e fixtures.
- Don't reformat or lint-fix files outside the slice. Don't delete anything not named in the task.
- Don't kill processes you didn't start (only the uvicorn/emulator ones described above).
