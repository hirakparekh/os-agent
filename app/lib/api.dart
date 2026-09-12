import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';

/// What `GET /api/mail/review` returns: the threads needing a decision, plus the categories
/// available to move them into.
class ReviewQueue {
  const ReviewQueue({required this.items, required this.categories});
  final List<ReviewItem> items;
  final List<String> categories;
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  bool get isAuthFailure => statusCode == 401;

  @override
  String toString() => message;
}

/// Raised when the device has no usable connection. Separated from [ApiException] because the
/// app treats it as "show cached data", not "something went wrong".
class OfflineException implements Exception {
  OfflineException([this.cause]);
  final Object? cause;

  @override
  String toString() => 'No connection';
}

/// The only place that talks to the backends.
///
/// Both services verify the same HS256 JWT (console issues it, brain decodes it independently),
/// so one token authenticates against both and there is no second login.
class Api {
  Api({required this.config, http.Client? client}) : _client = client ?? http.Client();

  ApiConfig config;
  String? token;
  final http.Client _client;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<dynamic> _send(
    String method,
    Uri url, {
    Object? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    http.Response res;
    try {
      final request = http.Request(method, url)..headers.addAll(_headers);
      if (body != null) request.body = jsonEncode(body);
      final streamed = await _client.send(request).timeout(timeout);
      res = await http.Response.fromStream(streamed);
    } on TimeoutException catch (e) {
      throw OfflineException(e);
    } catch (e) {
      // SocketException, HandshakeException, and friends all mean the same thing to the UI.
      throw OfflineException(e);
    }

    if (res.statusCode == 401) {
      throw ApiException(401, 'Signed out. Please log in again.');
    }
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, _describe(res));
    }
    if (res.body.isEmpty) return null;
    return jsonDecode(res.body);
  }

  /// Reads a field the API promised to send.
  ///
  /// A malformed or unexpected body is a server problem, not a crash: raising ApiException here
  /// means it surfaces as the same quiet message every other failed request does, instead of a
  /// TypeError escaping into the widget tree as a red screen.
  String _requireString(Object? data, String field, String action) {
    final value = data is Map<String, dynamic> ? data[field] : null;
    if (value is String && value.isNotEmpty) return value;
    throw ApiException(502, "The server's response to $action could not be read.");
  }

  String _describe(http.Response res) {
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['detail'] != null) return decoded['detail'].toString();
      if (decoded is Map && decoded['error'] != null) return decoded['error'].toString();
    } catch (_) {
      // Not JSON — fall through to the raw body.
    }
    final body = res.body.trim();
    return body.isEmpty ? 'Request failed (${res.statusCode})' : body;
  }

  Uri _console(String path, [Map<String, String>? query]) =>
      Uri.parse('${config.consoleBase}$path').replace(queryParameters: query);

  Uri _brain(String path, [Map<String, String>? query]) =>
      Uri.parse('${config.brainBase}$path').replace(queryParameters: query);

  // ---------------------------------------------------------------- accounts

  /// Returns the bearer token. Caller is responsible for storing it.
  Future<String> login(String email, String password) async {
    final data = await _send('POST', _console('/auth/login'),
        body: {'email': email, 'password': password});
    final issued = _requireString(data, 'token', 'signing in');
    token = issued;
    return issued;
  }

  Future<Map<String, dynamic>> me() async =>
      (await _send('GET', _console('/auth/me'))) as Map<String, dynamic>;

  // ------------------------------------------------------------------- feeds

  /// Urgent threads. [since] (ISO-8601 UTC) narrows to threads touched at or after that
  /// moment — filtered on the thread's *update* time, so a thread that has just become urgent
  /// is included even though it was created long ago.
  Future<List<UrgentThread>> needsAttention({String? since}) async {
    final data = await _send(
      'GET',
      _brain('/api/needs-attention', since == null ? null : {'since': since}),
    );
    final threads = (data as Map<String, dynamic>)['threads'] as List<dynamic>;
    return threads
        .map((t) => UrgentThread.fromJson(t as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<List<ActionItem>> actionItems({String? since}) async {
    final data = await _send(
      'GET',
      _brain('/api/action-items', since == null ? null : {'since': since}),
    );
    final items = (data as Map<String, dynamic>)['items'] as List<dynamic>;
    return items
        .map((i) => ActionItem.fromJson(i as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// The whole knowledge tree, thread bodies included, in one response.
  Future<TreeNode> mailTree() async {
    final data = await _send('GET', _brain('/api/mail_tree'));
    return TreeNode.fromJson(data as Map<String, dynamic>);
  }

  // -------------------------------------------------------------------- mail

  Future<MailStatus> mailStatus() async {
    final data = await _send('GET', _brain('/api/mail/status'));
    return MailStatus.fromJson(data as Map<String, dynamic>);
  }

  /// Starts Gmail consent and returns the Google URL to open in the user's own browser.
  ///
  /// The server completes the code exchange at its own callback, so the redirect never has to
  /// come back to this app — no custom URL scheme, no intent filter. Poll [mailStatus] until
  /// it flips to connected.
  Future<String> beginGmailConnect() async {
    final data = await _send('POST', _brain('/api/mail/connect'));
    return _requireString(data, 'auth_url', 'connecting your account');
  }

  Future<Map<String, dynamic>> askMail(String question) async =>
      (await _send('POST', _brain('/api/mail/ask'), body: {'question': question}))
          as Map<String, dynamic>;

  /// Re-run ingestion, streaming progress.
  ///
  /// This is a minutes-long operation gated by a rate-limited free-tier model, not a request
  /// that returns promptly — hence the stream rather than a future of the result.
  Stream<IngestProgress> reloadMailStream({int sinceMinutes = 1440}) async* {
    final request = http.Request('POST', _brain('/api/mail/reload/stream'))
      ..headers.addAll(_headers)
      ..body = jsonEncode({'since_minutes': sinceMinutes});

    http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } catch (e) {
      throw OfflineException(e);
    }

    if (response.statusCode == 401) {
      throw ApiException(401, 'Signed out. Please log in again.');
    }
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode, 'Sync failed (${response.statusCode})');
    }

    // NDJSON: one bare JSON object per line, no `data:` prefix. (It is not server-sent
    // events, despite the similarity — the endpoint sets application/x-ndjson.)
    final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      final payload = line.trim();
      if (payload.isEmpty) continue;
      try {
        yield IngestProgress.fromJson(jsonDecode(payload) as Map<String, dynamic>);
      } catch (_) {
        // A malformed frame should not abort a sync that is otherwise progressing.
        continue;
      }
    }
  }

  // ------------------------------------------------------------------- chat
  //
  // Chat goes through the *console*, not brain: it persists the conversation and proxies the
  // question to brain's /api/mail/ask with the same bearer token. Calling brain directly would
  // answer correctly and forget the exchange.

  Future<List<ChatSession>> chatSessions() async {
    final data = await _send('GET', _console('/chat/sessions'));
    return (data as List<dynamic>)
        .map((s) => ChatSession.fromJson(s as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<ChatSession> chatSession(int id) async {
    final data = await _send('GET', _console('/chat/sessions/$id'));
    return ChatSession.fromJson(data as Map<String, dynamic>);
  }

  Future<ChatSession> createChatSession() async {
    final data = await _send('POST', _console('/chat/sessions'));
    return ChatSession.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteChatSession(int id) async {
    await _send('DELETE', _console('/chat/sessions/$id'));
  }

  Future<void> renameChatSession(int id, String title) async {
    await _send('PATCH', _console('/chat/sessions/$id'), body: {'title': title});
  }

  /// Ask a question in a session. Slow — a model round-trip over the whole mail tree, gated by
  /// a rate-limited free tier, so it gets a far longer timeout than an ordinary request.
  Future<ChatMessage> sendChatMessage(int sessionId, String question) async {
    final data = await _send(
      'POST',
      _console('/chat/sessions/$sessionId/messages'),
      body: {'question': question},
      timeout: const Duration(minutes: 3),
    );
    return ChatMessage.fromJson(data as Map<String, dynamic>);
  }

  // ------------------------------------------------------------------ review

  Future<ReviewQueue> mailReview() async {
    final data = await _send('GET', _brain('/api/mail/review')) as Map<String, dynamic>;
    return ReviewQueue(
      items: (data['threads'] as List<dynamic>)
          .map((t) => ReviewItem.fromJson(t as Map<String, dynamic>))
          .toList(growable: false),
      categories: ((data['categories'] as List<dynamic>?) ?? const []).cast<String>(),
    );
  }

  /// Move a thread to a different category. The server also learns from the correction, so the
  /// same mistake is less likely next time — which is what makes triage worth doing on a phone
  /// rather than deferring to a laptop.
  Future<void> reclassify(String threadId, String category, {String? topic}) async {
    await _send(
      'POST',
      _brain('/api/mail/reclassify'),
      body: {'thread_id': threadId, 'category': category, if (topic != null) 'topic': topic},
    );
  }

  // ------------------------------------------------------- rules & analytics

  Future<List<AutomationRule>> rules() async {
    final data = await _send('GET', _brain('/api/rules')) as Map<String, dynamic>;
    return (data['rules'] as List<dynamic>)
        .map((r) => AutomationRule.fromJson(r as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Create a rule from plain English. The model is called once, here; evaluating the rule
  /// against future mail is pure code, so rules keep firing even with AI processing switched
  /// off on the server.
  Future<AutomationRule> createRule(String text) async {
    final data = await _send('POST', _brain('/api/rules'), body: {'text': text});
    return AutomationRule.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteRule(String id) async {
    await _send('DELETE', _brain('/api/rules/$id'));
  }

  Future<List<VolumePoint>> categoryVolume({String bucket = 'day'}) async {
    final data = await _send('GET', _brain('/api/analytics/category-volume', {'bucket': bucket}))
        as Map<String, dynamic>;
    return (data['points'] as List<dynamic>)
        .map((p) => VolumePoint.fromJson(p as Map<String, dynamic>))
        .toList(growable: false);
  }

  // ----------------------------------------------------------------- profile

  Future<UserProfile> profile() async {
    final data = await _send('GET', _brain('/api/profile'));
    return UserProfile.fromJson(data as Map<String, dynamic>);
  }

  /// Replaces the whole list — the API has no per-row endpoint.
  ///
  /// Saving re-scans attachments that were already ingested whenever the identifiers change:
  /// findings are frozen at ingest, so a roll number added today would otherwise leave every
  /// shortlist that arrived yesterday still claiming you are not on it.
  Future<UserProfile> saveProfile(List<ProfileDetail> details) async {
    final data = await _send(
      'PUT',
      _brain('/api/profile'),
      body: {'details': details.map((d) => d.toJson()).toList(growable: false)},
    );
    return UserProfile.fromJson(data as Map<String, dynamic>);
  }

  // ---------------------------------------------------------------- settings

  Future<BrainSettings> settings() async {
    final data = await _send('GET', _brain('/api/settings'));
    return BrainSettings.fromJson(data as Map<String, dynamic>);
  }

  Future<BrainSettings> setOfflineMode(bool enabled) async {
    final data = await _send('PUT', _brain('/api/settings'), body: {'offline_mode': enabled});
    return BrainSettings.fromJson(data as Map<String, dynamic>);
  }

  Future<MailStatus> disconnectGmail() async {
    final data = await _send('POST', _brain('/api/mail/disconnect'));
    return MailStatus.fromJson(data as Map<String, dynamic>);
  }

  Future<MailStatus> calendarStatus() async {
    final data = await _send('GET', _brain('/api/calendar/status'));
    return MailStatus.fromJson(data as Map<String, dynamic>);
  }

  Future<String> beginCalendarConnect() async {
    final data = await _send('POST', _brain('/api/calendar/connect'));
    return _requireString(data, 'auth_url', 'connecting your account');
  }

  Future<MailStatus> disconnectCalendar() async {
    final data = await _send('POST', _brain('/api/calendar/disconnect'));
    return MailStatus.fromJson(data as Map<String, dynamic>);
  }

  // ------------------------------------------------------------------- voice

  Future<VoiceOptions> voiceOptions() async {
    try {
      final data = await _send('GET', _console('/voice/options'));
      return VoiceOptions.fromJson(data as Map<String, dynamic>);
    } on ApiException {
      // A backend without the voice routes is not an error — it just means no voice.
      return VoiceOptions.off;
    }
  }

  /// Upload recorded audio, get text back. Multipart, so it does not go through [_send].
  Future<String> transcribe(List<int> audio, {required String languageCode}) async {
    final request = http.MultipartRequest('POST', _console('/voice/transcribe'))
      ..fields['language_code'] = languageCode
      ..files.add(http.MultipartFile.fromBytes('file', audio, filename: 'speech.wav'));
    if (token != null) request.headers['Authorization'] = 'Bearer $token';

    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(request));
    } catch (e) {
      throw OfflineException(e);
    }
    if (res.statusCode == 401) throw ApiException(401, 'Signed out. Please log in again.');
    if (res.statusCode >= 400) throw ApiException(res.statusCode, _describe(res));
    return (jsonDecode(res.body) as Map<String, dynamic>)['transcript'] as String? ?? '';
  }

  /// Synthesise speech. Returns WAV bytes for the caller to play.
  Future<List<int>> speak(
    String text, {
    required String languageCode,
    required String speaker,
  }) async {
    final request = http.Request('POST', _console('/voice/speak'))
      ..headers.addAll(_headers)
      ..body = jsonEncode({'text': text, 'language_code': languageCode, 'speaker': speaker});

    http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } catch (e) {
      throw OfflineException(e);
    }
    if (response.statusCode == 401) throw ApiException(401, 'Signed out. Please log in again.');
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode, 'Could not read that aloud.');
    }
    return response.stream.toBytes();
  }

  void close() => _client.close();
}
