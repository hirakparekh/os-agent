// A red screen is the worst thing this app can show: it looks like the phone broke, it covers
// the surrounding UI, and it says nothing a person can act on. These pin the replacement.
import 'dart:convert';
import 'dart:io';

import 'package:agent_os/api.dart';
import 'package:agent_os/app_state.dart';
import 'package:agent_os/cache.dart';
import 'package:agent_os/config.dart';
import 'package:agent_os/error_fallback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A widget that fails the way a real one does: while building.
class _Exploding extends StatelessWidget {
  const _Exploding();

  @override
  Widget build(BuildContext context) => throw StateError('boom');
}

/// flutter_test asserts that ErrorWidget.builder is back to its default by the time the test
/// body *returns* — that check runs before tearDown — so restoring it has to happen in the
/// body, and in a finally so a failed expectation still puts it back.
Future<void> withFriendlyErrorScreen(Future<void> Function() body) async {
  final previous = ErrorWidget.builder;
  installErrorWidgetBuilder();
  try {
    await body();
  } finally {
    ErrorWidget.builder = previous;
  }
}

void main() {
  testWidgets('a widget that throws shows a calm message, not the red screen', (tester) async {
    await withFriendlyErrorScreen(() async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Center(child: _Exploding()))),
      );

      expect(tester.takeException(), isA<StateError>(), reason: 'reported, just not shown');
      expect(find.byType(SomethingBroke), findsOneWidget);
      expect(find.text("This part didn't load"), findsOneWidget);
    });
  });

  testWidgets('the failure is contained: the rest of the screen still works', (tester) async {
    await withFriendlyErrorScreen(() async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const _Exploding(),
                TextButton(onPressed: () => taps++, child: const Text('Still here')),
              ],
            ),
          ),
        ),
      );
      tester.takeException();

      await tester.tap(find.text('Still here'));
      expect(taps, 1, reason: 'one broken card must not disable the screen around it');
    });
  });

  test('a malformed login response raises ApiException, not a TypeError', () async {
    final api = Api(
      config: ApiConfig.localDev,
      // The server answers 200 with a body that does not carry a token.
      client: MockClient((_) async => http.Response(jsonEncode({'oops': true}), 200)),
    );

    expect(
      () => api.login('a@b.c', 'pw'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 502)),
    );
  });

  test('a malformed connect response raises ApiException, not a TypeError', () async {
    final api = Api(
      config: ApiConfig.localDev,
      client: MockClient((_) async => http.Response(jsonEncode({'nope': 1}), 200)),
    );

    expect(() => api.beginGmailConnect(), throwsA(isA<ApiException>()));
  });

  testWidgets('sign-in surfaces a malformed response as a message, never as a crash',
      (tester) async {
    final state = AppState(
      api: Api(
        config: ApiConfig.localDev,
        client: MockClient((_) async => http.Response(jsonEncode({'oops': true}), 200)),
      ),
      cache: Cache(Directory.systemTemp.createTempSync('agent_os_err')),
    );

    final ok = await state.signIn('a@b.c', 'pw');

    expect(ok, isFalse);
    expect(state.signInError, isNotNull);
  });
}
