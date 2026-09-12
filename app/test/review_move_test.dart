// The Move sheet lists every category and puts a tick beside the one the thread is already in.
// Tapping that tick did nothing at all — no request, no feedback — because the caller threw the
// choice away when it matched the current category. Choosing it means "this filing is right":
// the server clears the low-confidence flag and teaches the scorer, which is the whole point of
// the queue.
import 'dart:convert';
import 'dart:io';

import 'package:agent_os/api.dart';
import 'package:agent_os/app_state.dart';
import 'package:agent_os/cache.dart';
import 'package:agent_os/config.dart';
import 'package:agent_os/screens/review.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

const _queue = {
  'threads': [
    {
      'id': 'mail:thread:501',
      'name': 'Slack account sign in from a new device',
      'summary': 'A Slack notification reports a sign-in from a new browser.',
      'category': 'Account Security',
      'topic': 'Acme Inc',
      'llm_category': 'Account Security',
      'keyword_category': 'General College',
    },
  ],
  'categories': ['Placements', 'Account Security', 'General College'],
};

/// Records every reclassify the screen sends.
({AppState state, List<Map<String, dynamic>> moves}) _harness() {
  final moves = <Map<String, dynamic>>[];
  final state = AppState(
    api: Api(
      config: ApiConfig.localDev,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/api/mail/reclassify')) {
          moves.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{}', 200);
        }
        if (request.url.path.endsWith('/api/mail/review')) {
          return http.Response(jsonEncode(_queue), 200);
        }
        // A successful move refreshes the feeds; they need their real shapes, not a bare {}.
        if (request.url.path.endsWith('/api/needs-attention')) {
          return http.Response(jsonEncode({'threads': []}), 200);
        }
        if (request.url.path.endsWith('/api/action-items')) {
          return http.Response(jsonEncode({'items': []}), 200);
        }
        if (request.url.path.endsWith('/api/mail_tree')) {
          return http.Response(
            jsonEncode({'id': 'mail:root', 'name': 'Mail', 'type': 'root', 'children': []}),
            200,
          );
        }
        if (request.url.path.endsWith('/api/mail/status')) {
          return http.Response(jsonEncode({'connected': true}), 200);
        }
        return http.Response('{}', 200);
      }),
    ),
    cache: Cache(Directory.systemTemp.createTempSync('agent_os_review')),
  );
  return (state: state, moves: moves);
}

Future<void> _openSheet(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: ReviewScreen()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Move'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('choosing the category it is already in confirms the filing', (tester) async {
    final h = _harness();
    await _openSheet(tester, h.state);

    await tester.tap(find.widgetWithText(ListTile, 'Account Security'));
    await tester.pumpAndSettle();

    expect(h.moves, hasLength(1), reason: 'the tap must reach the server, not be swallowed');
    expect(h.moves.single['category'], 'Account Security');
    expect(h.moves.single['thread_id'], 'mail:thread:501');
    expect(find.textContaining('Kept in Account Security'), findsOneWidget);
  });

  testWidgets('choosing a different category still moves the thread', (tester) async {
    final h = _harness();
    await _openSheet(tester, h.state);

    await tester.tap(find.widgetWithText(ListTile, 'Placements'));
    await tester.pumpAndSettle();

    expect(h.moves.single['category'], 'Placements');
    expect(find.textContaining('Moved to Placements'), findsOneWidget);
  });

  testWidgets('dismissing the sheet without choosing sends nothing', (tester) async {
    final h = _harness();
    await _openSheet(tester, h.state);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(h.moves, isEmpty);
  });
}
