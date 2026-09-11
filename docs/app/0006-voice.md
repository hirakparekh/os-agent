# 0006 — Speech in and out

## Decision

Voice is included: hold-to-record a question, and read answers aloud. It runs through the
console backend's `/voice` routes (Sarvam AI), which arrived with the `Dev-Devansh` merge.

- **In:** `record` captures audio → `POST /voice/transcribe` (multipart) → text lands **in the
  composer, not sent**.
- **Out:** `POST /voice/speak` returns WAV bytes → `audioplayers` plays them.

## Why it earns its place on a phone

Typing a paragraph-long question on a phone keyboard is the worst interaction in the app, and
listening to an answer while walking is something a laptop cannot do at all. Of everything
carried over from the web console, this is the feature that gets *better* on mobile rather than
worse.

## Transcription fills the composer rather than sending

Speech-to-text is wrong often enough that auto-sending would mean firing a misheard question at
a rate-limited model and waiting a minute to find out. The user sees the text and presses send.
This matches the web console's behaviour, which its e2e suite pins explicitly.

## The risk, stated plainly

This is the highest-risk part of the app and the first thing to cut if the build fights back:

- two native plugins (`record`, `audioplayers`) with platform channels — the only place in the
  app where a Dart-level mistake becomes a device-level one
- a runtime **microphone permission**, which needs a manifest entry and a denial path
- `RECORD_AUDIO` is the app's only sensitive permission; everything else needs `INTERNET` alone
- voice is unavailable unless `SARVAM_API_KEY` is set on the server — the app asks
  `GET /voice/options` and hides the controls when `configured` is false, so an unconfigured
  server degrades to a normal text chat rather than showing broken buttons

Nothing else in the app depends on this. Deleting `useVoice` wiring and the two packages leaves
chat working.
