import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api.dart';
import 'app_state.dart';

/// Tells the user about urgent mail they would otherwise miss.
///
/// **This polls while the app is running. It does not wake a closed app.** Doing that needs
/// Firebase Cloud Messaging and a server-side push — see `docs/app/0003-scope.md`. Polling is
/// what can be built without new infrastructure, and at one user checking every few minutes it
/// costs the server nothing.
///
/// Two details make this behave rather than spam:
///
///  * The poll asks `?since=` the last time it ran, filtered server-side on *update* time — so
///    a thread that has just become urgent is included even though it was created long ago.
///  * Threads and to-dos are deduplicated on identity, not recency, because urgency and action
///    items are recomputed on every merge and an old thread legitimately re-enters the feed
///    when a new message lands on it. Without this the same deadline is announced repeatedly.
class Notifier {
  Notifier(this._state);

  final AppState _state;
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  static const _channel = AndroidNotificationDetails(
    'urgent_mail',
    'Urgent mail',
    channelDescription: 'Deadlines and messages flagged as needing attention',
    importance: Importance.high,
    priority: Priority.high,
  );

  Timer? _timer;
  bool _ready = false;
  DateTime _since = DateTime.now().toUtc();
  final Set<String> _announced = {};
  int _nextId = 0;

  Future<void> start() async {
    if (_timer != null) return;
    _ready = await _init();
    if (!_ready) return;
    // Long enough that it is never the reason a battery drains, short enough that "urgent"
    // still means something. Mail arrives on the server's schedule, not this one.
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => _poll());
    unawaited(_poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<bool> _init() async {
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // Android 13+ asks at runtime. A refusal is an answer, not a failure — polling simply
      // stops rather than the app complaining.
      final granted = await android?.requestNotificationsPermission();
      return granted ?? true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _poll() async {
    if (!_ready || _state.stage != AuthStage.signedIn) return;
    final asOf = DateTime.now().toUtc();
    try {
      final threads = await _state.api.needsAttention(since: _since.toIso8601String());
      final items = await _state.api.actionItems(since: _since.toIso8601String());
      _since = asOf;

      for (final thread in threads) {
        if (!_announced.add('thread:${thread.id}')) continue;
        await _show(
          title: 'Needs attention',
          body: thread.name,
        );
      }
      for (final item in items) {
        if (!_announced.add('action:${item.dedupKey}')) continue;
        await _show(
          title: item.threadName ?? 'New to-do',
          body: item.text,
        );
      }
    } on OfflineException {
      // Try again at the next tick; `_since` is deliberately not advanced, so nothing that
      // arrived during the outage is skipped.
    } on ApiException {
      // Includes an expired session — the UI handles that on its own next refresh.
    }
  }

  Future<void> _show({required String title, required String body}) async {
    try {
      await _plugin.show(
        _nextId++,
        title,
        body,
        const NotificationDetails(android: _channel),
      );
    } catch (_) {
      // A notification that cannot be shown should never take the poller down with it.
    }
  }
}
