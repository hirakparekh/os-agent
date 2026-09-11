# Agent OS — Android app

The phone client for the Agent OS brain. Android only, shipped as an `.apk`.

**What it is:** a *"Today" action inbox* — urgent threads and open to-dos, across Gmail and
Slack at once — plus the knowledge tree, browsable with no connection. It is deliberately not
a port of the web console: browsing is better on a laptop, and what a phone is uniquely good
at is surfacing the thing you would otherwise miss.

## State

The Dart source under `lib/` is written. The platform scaffolding (`android/`, Gradle) is
**not** — it has never been compiled, because the Flutter SDK was not installed on the machine
where this was authored. Expect to fix whatever `flutter analyze` finds on the first run.

| Piece | File | Done |
|---|---|---|
| Backend config | `lib/config.dart` | yes |
| Data models | `lib/models.dart` | yes |
| API client, incl. sync stream | `lib/api.dart` | yes |
| Offline cache | `lib/cache.dart` | yes |
| App state (offline-first) | `lib/app_state.dart` | yes |
| Sign in | `lib/screens/login.dart` | yes |
| Shell, status strip, Gmail connect | `lib/screens/home.dart` | yes |
| Today feed | `lib/screens/today.dart` | yes |
| Knowledge tree | `lib/screens/tree.dart` | yes |
| Thread detail, with dates | `lib/screens/thread.dart` | yes |
| Chat, with voice | `lib/screens/chat.dart`, `lib/voice.dart` | yes |
| Review queue + reclassify | `lib/screens/review.dart` | yes |
| Insights | `lib/screens/insights.dart` | yes |
| Automation rules | `lib/screens/rules.dart` | yes |
| Settings and connections | `lib/screens/settings.dart` | yes |
| Urgent-mail notifications (polling) | `lib/notifications.dart` | yes |
| Push that wakes a closed app | — | no, needs FCM |
| The force-directed mind map | — | deliberately not built |

Decisions and their reasoning live in `docs/app/`.

## 1. Install Flutter

Not installed on this machine. JDK 17 already is, which is what the Android build wants.

```powershell
# Windows
winget install --id Google.Flutter -e
```

Then install Android Studio (for the SDK and an emulator) and run `flutter doctor` until it is
clean. `flutter doctor --android-licenses` accepts the SDK licences.

## 2. Generate the platform scaffolding

`flutter create` writes `android/` — but it also overwrites `lib/main.dart` and `pubspec.yaml`.
Commit first so the hand-written source can be restored:

```bash
git add app && git commit -m "wip: flutter app source"

cd app
flutter create --platforms=android --project-name agent_os .

# restore anything flutter create clobbered
git checkout -- lib pubspec.yaml

flutter pub get
flutter analyze
```

## 3. Let the app reach your machine

In `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<!-- Voice: hold-to-speak in chat. Drop this and the two audio packages if voice is cut. -->
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<!-- Android 13+ asks at runtime before any notification is shown. -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<application
    android:usesCleartextTraffic="true"
    ... >
```

`usesCleartextTraffic` is for local development only — the dev backends have no TLS. Drop it
once the backend is hosted behind HTTPS.

Nothing else is needed: there is no custom URL scheme and no intent filter anywhere in this
project, because Google's consent redirect goes to the *server's* callback, never back into the
app.

## 4. Run

Start all three backend services first (repository root `SETUP.md` §5), then:

```bash
flutter run
```

The app defaults to `http://10.0.2.2:8000` and `:8080` — how the Android emulator reaches the
host machine's localhost. On a physical device, use **Server settings** on the sign-in screen
and enter your machine's LAN address, or a hosted origin.

Sign in with `OPS_ADMIN_EMAIL` / `OPS_ADMIN_PASSWORD` from the repository root `.env`.

## 5. Build the APK

```bash
flutter build apk --release
# build/app/outputs/flutter-apk/app-release.apk
```

## Things worth knowing before you debug something that isn't broken

- **Gmail disconnects about weekly, by design.** The project requests a restricted Gmail scope
  and is unverified, so Google expires the grant every 7 days. The status strip offers
  *Connect* — that is routine, not a fault. Reconnect deliberately before any demo, because an
  expired grant looks exactly like an empty inbox.
- **An empty Today screen is a real state.** Urgency and action items are computed during
  ingest, so threads that predate those features carry neither until the next sync.
- **Sync takes minutes, not seconds.** It is gated by a rate-limited free-tier model, not by
  the network. The progress strip is driven by the server's event stream.
- **The tree renders from one cached payload.** `/api/mail_tree` returns thread bodies inline,
  so the tree and every thread detail work offline off a single response. What cannot work
  offline — Q&A, sync, connecting Gmail — should be visibly unavailable rather than silently
  failing.
