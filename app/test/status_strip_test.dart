// Unplugging the USB cable drops the adb reverse tunnel, so every request fails. The app used
// to render that as "Gmail not connected" — because an unfetched status is `connected: false`
// — and Connect then failed too. Not being able to reach the server is a different fact from
// the mailbox being disconnected, and the strip has to say which one it is.
import 'dart:io';

import 'package:agent_os/api.dart';
import 'package:agent_os/app_state.dart';
import 'package:agent_os/cache.dart';
import 'package:agent_os/config.dart';
import 'package:agent_os/models.dart';
import 'package:agent_os/screens/home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

AppState _state() => AppState(
      api: Api(
        config: ApiConfig.localDev,
        // Nothing in these tests should depend on a reachable server.
        client: MockClient((_) async => http.Response('{}', 500)),
      ),
      cache: Cache(Directory.systemTemp.createTempSync('agent_os_strip')),
    );

Widget _app(AppState state) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: HomeScreen()),
    );

void main() {
  testWidgets('an unreachable server reads as offline, not as a disconnected mailbox',
      (tester) async {
    final state = _state()..offline = true;

    await tester.pumpWidget(_app(state));
    await tester.pump();

    expect(find.textContaining('Offline'), findsOneWidget);
    expect(find.text('Gmail not connected'), findsNothing);
  });

  testWidgets('a status that has never been fetched does not claim Gmail is disconnected',
      (tester) async {
    final state = _state(); // mailStatus is MailStatus.unknown

    await tester.pumpWidget(_app(state));
    await tester.pump();

    expect(find.text('Gmail not connected'), findsNothing);
  });

  testWidgets('a mailbox the server says is disconnected still offers Connect', (tester) async {
    final state = _state()..mailStatus = MailStatus.fromJson(const {'connected': false});

    await tester.pumpWidget(_app(state));
    await tester.pump();

    expect(find.text('Gmail not connected'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('a lapsed grant asks for a reconnect rather than reporting a fault',
      (tester) async {
    final state = _state()
      ..mailStatus = MailStatus.fromJson(const {'connected': false, 'needs_reconnect': true});

    await tester.pumpWidget(_app(state));
    await tester.pump();

    expect(find.text('Gmail needs reconnecting'), findsOneWidget);
  });
}
