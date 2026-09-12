// Pins the Dart port of console/frontend/src/lib/mailTimeline.ts: both clients must group,
// filter and colour the same tree identically.
import 'package:agent_os/mail_timeline.dart';
import 'package:agent_os/models.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 9, 12, 10);

String _iso(int daysFromNow) {
  final d = _now.add(Duration(days: daysFromNow));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

TreeNode _thread(
  String id, {
  List<MailEvent> events = const [],
  String? received,
  bool estimated = false,
  String? summary,
  String? category,
}) =>
    TreeNode(
      id: id,
      name: id,
      type: 'mail_thread',
      summary: summary,
      category: category,
      events: events,
      lastReceived: received,
      receivedEstimated: estimated,
    );

TreeNode _tree(List<TreeNode> categories) =>
    TreeNode(id: 'mail:root', name: 'Mail', type: 'root', children: categories);

TreeNode _category(String name, List<TreeNode> children) => TreeNode(
      id: 'mail:cat:$name',
      name: name,
      type: 'mail_category',
      children: children,
    );

void main() {
  group('threadStatus', () {
    test('a deadline within three days is soon, further out is upcoming', () {
      final soon = _thread('a', events: [MailEvent(date: _iso(2), kind: 'deadline')]);
      final later = _thread('b', events: [MailEvent(date: _iso(9), kind: 'deadline')]);
      expect(threadStatus(soon, _now).status, ThreadStatus.soon);
      expect(threadStatus(soon, _now).days, 2);
      expect(threadStatus(later, _now).status, ThreadStatus.upcoming);
    });

    test('a passed deadline is overdue for 14 days, then simply past', () {
      final recent = _thread('a', events: [MailEvent(date: _iso(-3), kind: 'deadline')]);
      final ancient = _thread('b', events: [MailEvent(date: _iso(-40), kind: 'deadline')]);
      expect(threadStatus(recent, _now).status, ThreadStatus.overdue);
      expect(threadStatus(ancient, _now).status, ThreadStatus.past);
    });

    test('a passed non-deadline event is past, never overdue', () {
      final event = _thread('a', events: [MailEvent(date: _iso(-2), kind: 'event')]);
      expect(threadStatus(event, _now).status, ThreadStatus.past);
    });

    test('no dates at all', () {
      expect(threadStatus(_thread('a'), _now).status, ThreadStatus.none);
    });
  });

  test('threadMeta describes the most pressing date, else when it arrived', () {
    final overdue = _thread('a', events: [MailEvent(date: _iso(-1), kind: 'deadline')]);
    expect(threadMeta(overdue, _now), startsWith('Overdue · was due '));

    final due = _thread('b', events: [MailEvent(date: _iso(1), kind: 'deadline')]);
    expect(threadMeta(due, _now), startsWith('Due '));
    expect(threadMeta(due, _now), endsWith('· tomorrow'));

    final arrived = _thread('c', received: _now.subtract(const Duration(hours: 3)).toIso8601String());
    expect(threadMeta(arrived, _now), 'Received 3h ago');

    final approx = _thread(
      'd',
      received: _now.subtract(const Duration(hours: 3)).toIso8601String(),
      estimated: true,
    );
    expect(threadMeta(approx, _now), 'Received ~3h ago');
  });

  test('isNew only counts a real Date header, isStale needs 30 quiet days', () {
    final fresh = _thread('a', received: _now.subtract(const Duration(hours: 2)).toIso8601String());
    final guessed = _thread(
      'b',
      received: _now.subtract(const Duration(hours: 2)).toIso8601String(),
      estimated: true,
    );
    final old = _thread('c', received: _now.subtract(const Duration(days: 40)).toIso8601String());
    expect(isNew(fresh, _now), isTrue);
    expect(isNew(guessed, _now), isFalse);
    expect(isStale(old, _now), isTrue);
    expect(isStale(fresh, _now), isFalse);
  });

  test('category colours are assigned alphabetically, so they never shuffle', () {
    final colors = categoryColors(_tree([
      _category('Placements', const []),
      _category('Account Security', const []),
    ]));
    expect(colors['Account Security'], categoryPalette[0]);
    expect(colors['Placements'], categoryPalette[1]);
  });

  group('filters', () {
    final overdue = _thread('overdue', events: [MailEvent(date: _iso(-2), kind: 'deadline')]);
    final soon = _thread('soon', events: [MailEvent(date: _iso(2), kind: 'deadline')]);
    final far = _thread('far', events: [MailEvent(date: _iso(30), kind: 'event')]);
    final arrived = _thread('arrived', received: _now.subtract(const Duration(days: 2)).toIso8601String());

    test('each chip keeps only what it names', () {
      expect(matchesFilter(overdue, TimeFilter.overdue, '', _now), isTrue);
      expect(matchesFilter(soon, TimeFilter.overdue, '', _now), isFalse);
      expect(matchesFilter(soon, TimeFilter.week, '', _now), isTrue);
      expect(matchesFilter(far, TimeFilter.week, '', _now), isFalse);
      expect(matchesFilter(far, TimeFilter.upcoming, '', _now), isTrue);
      expect(matchesFilter(arrived, TimeFilter.recent, '', _now), isTrue);
      expect(matchesFilter(overdue, TimeFilter.all, '', _now), isTrue);
    });

    test('search looks at title, summary, topic, category and event titles', () {
      final node = _thread('x', summary: 'Accenture drive', category: 'Placements');
      expect(matchesFilter(node, TimeFilter.all, 'accenture', _now), isTrue);
      expect(matchesFilter(node, TimeFilter.all, 'placements', _now), isTrue);
      expect(matchesFilter(node, TimeFilter.all, 'yoga', _now), isFalse);
    });

    test('filterTree drops branches left empty', () {
      final tree = _tree([
        _category('Placements', [_thread('keep', summary: 'accenture')]),
        _category('Other', [_thread('drop', summary: 'nothing')]),
      ]);
      final filtered = filterTree(tree, (t) => matchesFilter(t, TimeFilter.all, 'accenture', _now))!;
      expect(filtered.children.map((c) => c.name), ['Placements']);
      expect(collectThreads(filtered).map((t) => t.id), ['keep']);
    });
  });

  group('buildTimeTree', () {
    test('upcoming groups into the web buckets, in the web order', () {
      final tree = _tree([
        _category('A', [
          _thread('overdue', events: [MailEvent(date: _iso(-1), kind: 'deadline')]),
          _thread('today', events: [MailEvent(date: _iso(0), kind: 'event')]),
          _thread('thisweek', events: [MailEvent(date: _iso(5), kind: 'event')]),
          _thread('nextweek', events: [MailEvent(date: _iso(12), kind: 'event')]),
          _thread('later', events: [MailEvent(date: _iso(40), kind: 'event')]),
          _thread('nodate'),
        ]),
      ]);
      final buckets = buildTimeTree(tree, TimeMode.upcoming, _now).children;
      expect(
        buckets.map((b) => b.name),
        ['Overdue', 'Today', 'This week', 'Next week', 'Later', 'No date'],
      );
      expect(buckets.first.summary, '1 thread');
      expect(buckets.every((b) => b.type == 'time_bucket'), isTrue);
    });

    test('the past and no-date buckets are the ones that start collapsed', () {
      expect(collapsedBuckets, {'time:upcoming:past', 'time:upcoming:none'});
    });

    test('received groups by month then day, newest first', () {
      final tree = _tree([
        _category('A', [
          _thread('new', received: '2026-09-11T09:00:00'),
          _thread('sameday', received: '2026-09-11T18:00:00'),
          _thread('older', received: '2026-08-02T09:00:00'),
          _thread('undated'),
        ]),
      ]);
      final months = buildTimeTree(tree, TimeMode.received, _now).children;
      expect(months.map((m) => m.name), ['September 2026', 'August 2026', 'Unknown date']);
      expect(months.first.summary, '2 threads');
      expect(months.first.children.single.children.map((t) => t.id), ['sameday', 'new']);
    });
  });
}
