// Backing out of a conversation while the answer is still coming used to throw: `ask` resumes
// after its await and dereferences openSession!, which closeChat() has since set to null. It is
// an async gap, so ErrorWidget.builder cannot catch it — the app dies mid-question.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_os/api.dart';
import 'package:agent_os/app_state.dart';
import 'package:agent_os/cache.dart';
import 'package:agent_os/config.dart';
import 'package:agent_os/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AppState _state(Future<http.Response> reply) => AppState(
      api: Api(
        config: ApiConfig.localDev,
        client: MockClient((request) async {
          if (request.url.path.contains('/messages')) return reply;
          if (request.url.path.endsWith('/chat/sessions')) {
            return http.Response(jsonEncode([]), 200);
          }
          return http.Response('{}', 200);
        }),
      ),
      cache: Cache(Directory.systemTemp.createTempSync('agent_os_chat')),
    );

/// The shape sendChatMessage parses: a ChatMessage, so `ask` reaches the code after the await
/// rather than diverting into its ApiException branch.
final _answer = http.Response(
  jsonEncode({'role': 'assistant', 'content': 'Two deadlines this week.'}),
  200,
);

void main() {
  test('closing the conversation while an answer is in flight does not throw', () async {
    final held = Completer<http.Response>();
    final state = _state(held.future)..openSession = const ChatSession(id: 1, title: 'Open');

    final asking = state.ask('what is due?');
    state.closeChat(); // the user hits back before the model answers
    held.complete(_answer);

    await expectLater(asking, completes);
    expect(state.openSession, isNull, reason: 'a closed conversation must stay closed');
  });

  test('the answer still lands when the conversation is left open', () async {
    final state = _state(Future.value(_answer))
      ..openSession = const ChatSession(id: 1, title: 'Open');

    await state.ask('what is due?');

    expect(state.openSession?.messages.last.content, 'Two deadlines this week.');
    expect(state.openSession?.messages.any((m) => m.pending), isFalse);
  });

  test('switching to another conversation mid-answer does not overwrite it', () async {
    final held = Completer<http.Response>();
    final state = _state(held.future)..openSession = const ChatSession(id: 1, title: 'First');

    final asking = state.ask('what is due?');
    state.openSession = const ChatSession(id: 2, title: 'Second'); // user opens another
    held.complete(_answer);
    await asking;

    expect(state.openSession?.id, 2);
    expect(state.openSession?.title, 'Second');
    expect(state.openSession?.messages, isEmpty, reason: 'the reply belonged to session 1');
  });
}
