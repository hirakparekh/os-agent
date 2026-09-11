import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';

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
  }) async {
    http.Response res;
    try {
      final request = http.Request(method, url)..headers.addAll(_headers);
      if (body != null) request.body = jsonEncode(body);
      final streamed = await _client.send(request).timeout(const Duration(seconds: 30));
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
    final issued = (data as Map<String, dynamic>)['token'] as String;
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
    return (data as Map<String, dynamic>)['auth_url'] as String;
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

  void close() => _client.close();
}
