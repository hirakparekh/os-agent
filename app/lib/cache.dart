import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// On-device persistence, so every read-only screen renders with the radio off.
///
/// Plain JSON files rather than a database: the whole dataset is tens of threads and arrives
/// as three whole-payload responses, so there is nothing to query, page, or migrate. A local
/// SQLite layer here would be ceremony without a use.
///
/// Each payload is stored with the time it was fetched, so the UI can say "synced 20 minutes
/// ago" instead of silently presenting stale data as current.
class Cache {
  Cache(this._dir);

  final Directory _dir;

  static Future<Cache> open() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return Cache(dir);
  }

  File _file(String name) => File('${_dir.path}/$name.json');

  Future<void> _write(String name, Object payload) async {
    final envelope = {
      'fetched_at': DateTime.now().toUtc().toIso8601String(),
      'payload': payload,
    };
    // Write to a temporary file then rename, so a kill mid-write cannot leave a truncated
    // file that fails to parse on next launch.
    final tmp = File('${_file(name).path}.tmp');
    await tmp.writeAsString(jsonEncode(envelope), flush: true);
    await tmp.rename(_file(name).path);
  }

  Future<_Envelope?> _read(String name) async {
    final file = _file(name);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return _Envelope(
        fetchedAt: DateTime.tryParse(decoded['fetched_at'] as String? ?? ''),
        payload: decoded['payload'],
      );
    } catch (_) {
      // Corrupt cache is not worth crashing over — behave as though it were absent.
      return null;
    }
  }

  Future<void> saveUrgent(List<UrgentThread> threads) =>
      _write('urgent', threads.map((t) => t.toJson()).toList(growable: false));

  Future<CachedList<UrgentThread>> loadUrgent() async {
    final env = await _read('urgent');
    if (env == null) return const CachedList.empty();
    final list = (env.payload as List<dynamic>)
        .map((t) => UrgentThread.fromJson(t as Map<String, dynamic>))
        .toList(growable: false);
    return CachedList(list, env.fetchedAt);
  }

  Future<void> saveActions(List<ActionItem> items) =>
      _write('actions', items.map((i) => i.toJson()).toList(growable: false));

  Future<CachedList<ActionItem>> loadActions() async {
    final env = await _read('actions');
    if (env == null) return const CachedList.empty();
    final list = (env.payload as List<dynamic>)
        .map((i) => ActionItem.fromJson(i as Map<String, dynamic>))
        .toList(growable: false);
    return CachedList(list, env.fetchedAt);
  }

  Future<void> saveTree(TreeNode tree) => _write('tree', tree.toJson());

  Future<CachedValue<TreeNode>> loadTree() async {
    final env = await _read('tree');
    if (env == null) return const CachedValue(null, null);
    return CachedValue(
      TreeNode.fromJson(env.payload as Map<String, dynamic>),
      env.fetchedAt,
    );
  }

  Future<void> saveSessions(List<ChatSession> sessions) =>
      _write('sessions', sessions.map((s) => s.toJson()).toList(growable: false));

  Future<CachedList<ChatSession>> loadSessions() async {
    final env = await _read('sessions');
    if (env == null) return const CachedList.empty();
    final list = (env.payload as List<dynamic>)
        .map((s) => ChatSession.fromJson(s as Map<String, dynamic>))
        .toList(growable: false);
    return CachedList(list, env.fetchedAt);
  }

  Future<void> clear() async {
    if (await _dir.exists()) await _dir.delete(recursive: true);
    await _dir.create(recursive: true);
  }
}

class _Envelope {
  _Envelope({this.fetchedAt, this.payload});
  final DateTime? fetchedAt;
  final dynamic payload;
}

class CachedList<T> {
  const CachedList(this.items, this.fetchedAt);
  const CachedList.empty()
      : items = const [],
        fetchedAt = null;

  final List<T> items;
  final DateTime? fetchedAt;
}

class CachedValue<T> {
  const CachedValue(this.value, this.fetchedAt);
  final T? value;
  final DateTime? fetchedAt;
}
