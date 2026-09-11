// The sync endpoint's two traps (docs/app/0004-api-contract-traps.md): it is NDJSON, not
// server-sent events, and `done` is a count, not a boolean. Frames below mirror
// brain/mail_ingest.py and brain/viz_server.py exactly.
import 'dart:convert';

import 'package:agent_os/api.dart';
import 'package:agent_os/config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Api _api(List<String> chunks, {int status = 200}) => Api(
      config: ApiConfig.localDev,
      client: MockClient.streaming(
        (request, body) async => http.StreamedResponse(
          Stream.fromIterable(chunks.map(utf8.encode)),
          status,
          headers: {'content-type': 'application/x-ndjson'},
        ),
      ),
    );

void main() {
  test('parses bare NDJSON lines, even when a line is split across chunks', () async {
    final events = await _api([
      '{"stage": "connecting"}\n{"stage": "fet',
      'ched", "total": 2}\n',
      '{"stage": "ingesting", "done": 0, "total": 2, "subject": "Drive"}\n',
      '{"stage": "ingested", "done": 1, "total": 2}\n',
      '{"stage": "done", "processed": 2, "results": []}\n',
    ]).reloadMailStream().toList();

    expect(events.map((e) => e.stage),
        ['connecting', 'fetched', 'ingesting', 'ingested', 'done']);
    expect(events[2].done, 0, reason: '`done` is a count; 0 must not read as false');
    expect(events[2].label, 'Sorting 1 of 2 — Drive');
    expect(events.where((e) => e.isTerminal).length, 1);
    expect(events.last.label, 'Sorted 2 messages.');
  });

  test('a failed frame is terminal and carries the server error', () async {
    final events = await _api([
      '{"stage": "connecting"}\n',
      '{"stage": "failed", "error": "Gmail needs reconnecting"}\n',
    ]).reloadMailStream().toList();

    expect(events.last.isTerminal, isTrue);
    expect(events.last.failed, isTrue);
    expect(events.last.label, 'Gmail needs reconnecting');
  });

  test('a malformed frame is skipped rather than aborting the sync', () async {
    final events = await _api([
      'data: {"stage": "connecting"}\n',
      '\n',
      '{"stage": "done", "processed": 0}\n',
    ]).reloadMailStream().toList();

    expect(events.map((e) => e.stage), ['done']);
  });

  test('401 surfaces as a sign-out, not a hanging stream', () async {
    await expectLater(
      _api(const [], status: 401).reloadMailStream().toList(),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
    );
  });
}
