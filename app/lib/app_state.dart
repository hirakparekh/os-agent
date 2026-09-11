import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'cache.dart';
import 'config.dart';
import 'models.dart';
import 'notifications.dart';

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
    _notifier?.stop();
    notificationsEnabled = false;
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

  // ------------------------------------------------------------------- chat
  //
  // Conversations are cached so past answers are readable offline; asking a new question is
  // not, because it needs the model.

  List<ChatSession> sessions = const [];
  ChatSession? openSession;
  bool sending = false;
  String? chatError;

  Future<void> loadSessions() async {
    final cached = await cache.loadSessions();
    if (sessions.isEmpty && cached.items.isNotEmpty) {
      sessions = cached.items;
      notifyListeners();
    }
    try {
      sessions = await api.chatSessions();
      offline = false;
      await cache.saveSessions(sessions);
    } on OfflineException {
      offline = true;
    } on ApiException catch (e) {
      if (e.isAuthFailure) await signOut();
    }
    notifyListeners();
  }

  /// Leave the open conversation and return to the list.
  void closeChat() {
    openSession = null;
    chatError = null;
    notifyListeners();
  }

  Future<void> openChat(int id) async {
    // Show whatever is cached immediately; the fetch below only fills in what is missing.
    openSession = sessions.firstWhere(
      (s) => s.id == id,
      orElse: () => ChatSession(id: id),
    );
    chatError = null;
    notifyListeners();
    try {
      openSession = await api.chatSession(id);
      offline = false;
    } on OfflineException {
      offline = true;
    } on ApiException catch (e) {
      if (e.isAuthFailure) await signOut();
    }
    notifyListeners();
  }

  Future<int?> startChat() async {
    try {
      final created = await api.createChatSession();
      sessions = [created, ...sessions];
      openSession = created;
      notifyListeners();
      return created.id;
    } on OfflineException {
      chatError = 'Starting a conversation needs a connection.';
      notifyListeners();
      return null;
    }
  }

  /// Send a question and wait for the answer.
  ///
  /// The question is echoed locally first so the conversation reads naturally during the
  /// minute or so the model takes — without it the screen sits empty and looks broken.
  Future<void> ask(String question) async {
    final session = openSession;
    if (session == null || sending || question.trim().isEmpty) return;

    sending = true;
    chatError = null;
    openSession = ChatSession(
      id: session.id,
      title: session.title,
      updatedAt: session.updatedAt,
      messages: [
        ...session.messages,
        ChatMessage(role: 'user', content: question.trim(), pending: true),
      ],
    );
    notifyListeners();

    try {
      final answer = await api.sendChatMessage(session.id, question.trim());
      final settled = openSession!.messages
          .map((m) => m.pending ? ChatMessage(role: m.role, content: m.content) : m)
          .toList();
      openSession = ChatSession(
        id: session.id,
        title: openSession!.title,
        updatedAt: DateTime.now(),
        messages: [...settled, answer],
      );
      await loadSessions(); // the server titles a conversation from its first question
    } on OfflineException {
      offline = true;
      chatError = 'No connection — this needs the network.';
      _dropPendingMessage();
    } on ApiException catch (e) {
      chatError = e.message;
      _dropPendingMessage();
      if (e.isAuthFailure) await signOut();
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  /// Remove the optimistic echo when the question never made it, so the user does not see
  /// their own message sitting in a conversation the server has no record of.
  void _dropPendingMessage() {
    final session = openSession;
    if (session == null) return;
    openSession = ChatSession(
      id: session.id,
      title: session.title,
      updatedAt: session.updatedAt,
      messages: session.messages.where((m) => !m.pending).toList(growable: false),
    );
  }

  Future<void> deleteChat(int id) async {
    try {
      await api.deleteChatSession(id);
      sessions = sessions.where((s) => s.id != id).toList(growable: false);
      if (openSession?.id == id) openSession = null;
      await cache.saveSessions(sessions);
      notifyListeners();
    } on OfflineException {
      chatError = 'Deleting needs a connection.';
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ review

  ReviewQueue review = const ReviewQueue(items: [], categories: []);
  bool reviewLoading = false;

  Future<void> loadReview() async {
    reviewLoading = true;
    notifyListeners();
    try {
      review = await api.mailReview();
      offline = false;
    } on OfflineException {
      offline = true;
    } on ApiException catch (e) {
      if (e.isAuthFailure) await signOut();
    } finally {
      reviewLoading = false;
      notifyListeners();
    }
  }

  Future<bool> reclassify(String threadId, String category) async {
    try {
      await api.reclassify(threadId, category);
      review = ReviewQueue(
        items: review.items.where((i) => i.id != threadId).toList(growable: false),
        categories: review.categories,
      );
      notifyListeners();
      unawaited(refresh()); // the tree and feeds have both changed
      return true;
    } on OfflineException {
      offline = true;
      notifyListeners();
      return false;
    } on ApiException {
      return false;
    }
  }

  // ---------------------------------------------------------- rules & charts

  List<AutomationRule> rules = const [];
  List<VolumePoint> volume = const [];

  Future<void> loadRules() async {
    try {
      rules = await api.rules();
      offline = false;
    } on OfflineException {
      offline = true;
    } on ApiException {
      // Leave whatever was loaded before rather than blanking the list.
    }
    notifyListeners();
  }

  Future<String?> addRule(String text) async {
    try {
      final rule = await api.createRule(text);
      rules = [...rules, rule];
      notifyListeners();
      return null;
    } on OfflineException {
      return 'Creating a rule needs a connection.';
    } on ApiException catch (e) {
      return e.message;
    }
  }

  Future<void> removeRule(String id) async {
    try {
      await api.deleteRule(id);
      rules = rules.where((r) => r.id != id).toList(growable: false);
      notifyListeners();
    } on OfflineException {
      offline = true;
      notifyListeners();
    }
  }

  Future<void> loadVolume({String bucket = 'day'}) async {
    try {
      volume = await api.categoryVolume(bucket: bucket);
      offline = false;
    } on OfflineException {
      offline = true;
    } on ApiException {
      // Keep the previous chart.
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- settings

  BrainSettings brainSettings = const BrainSettings();
  MailStatus calendarStatus = MailStatus.unknown;

  Future<void> loadSettings() async {
    try {
      brainSettings = await api.settings();
      calendarStatus = await api.calendarStatus();
      offline = false;
    } on OfflineException {
      offline = true;
    } on ApiException catch (e) {
      if (e.isAuthFailure) await signOut();
    }
    notifyListeners();
  }

  Future<void> setOfflineMode(bool enabled) async {
    try {
      brainSettings = await api.setOfflineMode(enabled);
    } on OfflineException {
      offline = true;
    } on ApiException {
      // Server rejected it; leave the switch reflecting the server's actual state.
    }
    notifyListeners();
  }

  Future<void> disconnectGmail() async {
    try {
      mailStatus = await api.disconnectGmail();
    } on OfflineException {
      offline = true;
    } on ApiException {
      // Nothing useful to say; the status below is unchanged.
    }
    notifyListeners();
  }

  Future<void> disconnectCalendar() async {
    try {
      calendarStatus = await api.disconnectCalendar();
    } on OfflineException {
      offline = true;
    } on ApiException {
      // As above.
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------- voice

  VoiceOptions voice = VoiceOptions.off;
  bool readAloud = false;

  Future<void> loadVoiceOptions() async {
    try {
      voice = await api.voiceOptions();
    } on OfflineException {
      voice = VoiceOptions.off;
    }
    notifyListeners();
  }

  void setReadAloud(bool value) {
    readAloud = value;
    notifyListeners();
  }

  // ----------------------------------------------------------- notifications

  bool notificationsEnabled = false;
  Notifier? _notifier;

  /// Start or stop the background poller. Off by default: it is the app's only recurring
  /// battery cost and the only thing that asks for a system permission at rest.
  void setNotificationsEnabled(bool enabled) {
    notificationsEnabled = enabled;
    if (enabled) {
      _notifier ??= Notifier(this);
      unawaited(_notifier!.start());
    } else {
      _notifier?.stop();
    }
    notifyListeners();
  }

  void setConfig(ApiConfig config) {
    api.config = config;
    notifyListeners();
  }
}
