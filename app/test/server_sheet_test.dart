import 'dart:io';

import 'package:agent_os/api.dart';
import 'package:agent_os/app_state.dart';
import 'package:agent_os/cache.dart';
import 'package:agent_os/config.dart';
import 'package:agent_os/screens/login.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

void main() {
  // Found on the emulator: closing Server settings with Back disposed the address controller
  // while the sheet's exit animation was still building the TextField — a red error screen.
  testWidgets('dismissing Server settings without saving does not use a disposed controller',
      (tester) async {
    final state = AppState(
      api: Api(
        config: ApiConfig.localDev,
        client: MockClient((_) async => http.Response('{}', 200)),
      ),
      cache: Cache(Directory.systemTemp.createTempSync('agent_os_test')),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: LoginScreen()),
      ),
    );

    await tester.tap(find.text('Server settings'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Address'), 'http://10.0.0.5:8000');

    // Android Back: pops the sheet without Save.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Address'), findsNothing);
    expect(state.api.config.consoleBase, ApiConfig.localDev.consoleBase);
  });
}
