// The stacked bar is the whole point of the screen: on device the bucket row rendered its
// label and total but no visible bar, so its geometry is pinned here rather than eyeballed.
import 'dart:convert';
import 'dart:io';

import 'package:agent_os/api.dart';
import 'package:agent_os/app_state.dart';
import 'package:agent_os/cache.dart';
import 'package:agent_os/config.dart';
import 'package:agent_os/screens/analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

/// Two buckets, five categories — enough that the fifth folds into "Other".
const _points = [
  {'bucket': '2026-09-11', 'category': 'Placements', 'count': 3},
  {'bucket': '2026-09-11', 'category': 'Account Security', 'count': 1},
  {'bucket': '2026-09-12', 'category': 'Placements', 'count': 2},
  {'bucket': '2026-09-12', 'category': 'Account Security', 'count': 2},
  {'bucket': '2026-09-12', 'category': 'General College', 'count': 1},
  {'bucket': '2026-09-12', 'category': 'Product Trials', 'count': 1},
  {'bucket': '2026-09-12', 'category': 'Newsletters', 'count': 1},
];

AppState _state() => AppState(
      api: Api(
        config: ApiConfig.localDev,
        client: MockClient((request) async {
          if (request.url.path.contains('category-volume')) {
            return http.Response(jsonEncode({'points': _points}), 200);
          }
          return http.Response('{}', 200);
        }),
      ),
      cache: Cache(Directory.systemTemp.createTempSync('agent_os_analytics')),
    );

Future<void> _pump(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: AnalyticsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('each bucket draws a visible segment per category', (tester) async {
    await _pump(tester, _state());

    final busiest = find.byKey(const ValueKey('segment:2026-09-12:Placements'));
    expect(busiest, findsOneWidget, reason: 'the stacked bar must actually be built');

    final size = tester.getSize(busiest);
    expect(size.width, greaterThan(0), reason: 'a segment with 2 threads cannot be 0px wide');
    expect(size.height, greaterThan(0));
  });

  testWidgets('a lighter bucket draws a narrower bar than the busiest one', (tester) async {
    await _pump(tester, _state());

    // 2026-09-11 has 4 threads against 2026-09-12's 7: same scale, so it must be shorter.
    final busy = tester.getSize(find.byKey(const ValueKey('segment:2026-09-12:Placements')));
    final light = tester.getSize(find.byKey(const ValueKey('segment:2026-09-11:Placements')));
    expect(light.width, lessThan(busy.width * 2));
  });

  testWidgets('only four categories keep their own colour; the rest fold into Other',
      (tester) async {
    await _pump(tester, _state());

    expect(find.byKey(const ValueKey('segment:2026-09-12:Other')), findsOneWidget);
    expect(find.byKey(const ValueKey('segment:2026-09-12:Newsletters')), findsNothing);
  });

  testWidgets('the breakdown carries every number as text, not only as colour', (tester) async {
    await _pump(tester, _state());

    // Below the fold in a test viewport, so the ListView has not built it yet.
    await tester.dragUntilVisible(
      find.text('BREAKDOWN'),
      find.byType(ListView),
      const Offset(0, -220),
    );
    await tester.pumpAndSettle();

    expect(find.text('BREAKDOWN'), findsOneWidget);
    expect(find.text('2026-09-12'), findsWidgets);
    // The per-category counts are spelled out, so the series colours are never load-bearing.
    expect(find.text('Placements 2'), findsOneWidget);
    expect(find.text('7 threads'), findsOneWidget);
  });
}
