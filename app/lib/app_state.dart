import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'cache.dart';
import 'config.dart';
import 'models.dart';

enum AuthStage { starting, signedOut, signedIn }

/// Application state, offline-first by construction.
///
/// The rule everywhere below: **render from cache, then refresh from network**. Screens never
/// wait on a request to show something, and a failed refresh leaves the last good data on
/// screen with a staleness marker rather than replacing it with an error. That is what makes
/// the knowledge tree usable with no connection.
class AppState extends ChangeNotifier {
  AppState({required this.api, required this.cache});

  final Api api;
  final Cache cache;
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'auth_token';

  AuthStage stage = AuthStage.starting;
  String? signInError;
  bool signingIn = false;

  List<UrgentThread> urgent = const [];
  List<ActionItem> actions = const [];
  TreeNode? tree;
  DateTime? lastSynced;

  MailStatus mailStatus = MailStatus.unknown;
  bool offline = false;
  bool refreshing = false;

  String? syncStage;
  bool syncing = false;

  /// Restore a previous session and paint cached content before any network call.
  Future<void> boot() async {
    await _loadFromCache();
    final saved = await _storage.read(key: _tokenKey);
    if (saved == null) {
      stage = AuthStage.signedOut;
      notifyListeners();
      return;
    }
    api.token = saved;
    stage = AuthStage.signedIn;
    notifyListeners();
    // Cached content is already on screen; this only updates it.
    unawaited(refresh());
  }

  Future<void> _loadFromCache() async {
    final cachedUrgent = await cache.loadUrgent();
    final cachedActions = await cache.loadActions();
    final cachedTree = await cache.loadTree();
    urgent = cachedUrgent.items;
    actions = cachedActions.items;
    tree = cachedTree.value;
    lastSynced = [
      cachedUrgent.fetchedAt,
      cachedActions.fetchedAt,
      cachedTree.fetchedAt,
    ].whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    notifyListeners();
  }

  Future<bool> signIn(String email, String password) async {
    signingIn = true;
    signInError = null;
    notifyListeners();
    try {
      final token = await api.login(email, password);
      await _storage.write(key: _tokenKey, value: token);
      stage = AuthStage.signedIn;
      signingIn = false;
      notifyListeners();
      unawaited(refresh());
      return true;
    } on OfflineException {
      signInError = 'No connection. Signing in needs the network.';
    } on ApiException catch (e) {
      signInError = e.statusCode == 401 ? 'Wrong email or password.' : e.message;
    } finally {
      signingIn = false;
      notifyListeners();
    }
    return false;
  }

  Future<void> signOut() async {
    await _storage.delete(key: _tokenKey);
    await cache.clear();
    api.token = null;
    urgent = const [];
    actions = const [];
    tree = null;
    lastSynced = null;
    mailStatus = MailStatus.unknown;
    stage = AuthStage.signedOut;
    notifyListeners();
  }

  /// Pull all three payloads and the mailbox status.
  ///
  /// Failures are absorbed: losing the network marks the app offline and keeps whatever was
  /// last cached on screen. Only an expired session is escalated, because that genuinely
  /// requires the user to act.
  Future<void> refresh() async {
    if (refreshing) return;
    refreshing = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        api.needsAttention(),
        api.actionItems(),
        api.mailTree(),
        api.mailStatus(),
      ]);
      urgent = results[0] as List<UrgentThread>;
      actions = results[1] as List<ActionItem>;
      tree = results[2] as TreeNode;
      mailStatus = results[3] as MailStatus;
      lastSynced = DateTime.now();
      offline = false;
      await cache.saveUrgent(urgent);
      await cache.saveActions(actions);
      await cache.saveTree(tree!);
    } on OfflineException {
      offline = true;
    } on ApiException catch (e) {
      if (e.isAuthFailure) {
        await signOut();
      }
    } finally {
      refreshing = false;
      notifyListeners();
    }
  }

  Future<void> refreshMailStatus() async {
    try {
      mailStatus = await api.mailStatus();
      offline = false;
    } on OfflineException {
      offline = true;
    } on ApiException {
      // Leave the previous status in place rather than inventing a worse one.
    }
    notifyListeners();
  }

  /// Run a sync, surfacing progress. Returns when the stream ends.
  Future<void> runSync({int sinceMinutes = 1440}) async {
    if (syncing) return;
    syncing = true;
    syncStage = 'Starting…';
    notifyListeners();
    try {
      var failed = false;
      await for (final event in api.reloadMailStream(sinceMinutes: sinceMinutes)) {
        syncStage = event.label;
        if (event.failed) failed = true;
        notifyListeners();
      }
      // Re-read the feeds and tree so the new mail is on screen, unless the sync itself
      // failed — in which case the last good data is better than an empty refresh.
      if (!failed) await refresh();
    } on OfflineException {
      offline = true;
      syncStage = 'No connection.';
    } on ApiException catch (e) {
      syncStage = e.message;
      if (e.isAuthFailure) await signOut();
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  void setConfig(ApiConfig config) {
    api.config = config;
    notifyListeners();
  }
}
