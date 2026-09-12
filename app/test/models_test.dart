// The tree endpoint serves a thread's dates as `start`, not `date` (brain/mail_timeline.py:83
// and 125). Parsing the wrong key drops every date silently: no urgency colours, an empty
// "Dates" block, and every thread landing in the time view's "No date" bucket.
import 'package:agent_os/mail_timeline.dart';
import 'package:agent_os/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// One thread exactly as `GET /api/mail_tree` returns it.
Map<String, dynamic> _threadJson(String start, {String kind = 'deadline'}) => {
      'id': 'mail:thread:103',
      'name': 'Guest Lecture on Compilers',
      'type': 'mail_thread',
      'summary': 'Guest lecture by a visiting professor.',
      'category': 'Lectures & Profs',
      'topic': 'Compilers',
      'events': [
        {
          'title': 'Assignment submission',
          'start': start,
          'kind': kind,
          'end': null,
          'location': null,
          'source_uid': '103',
        },
      ],
    };

void main() {
  test('MailEvent reads the server\'s `start` field', () {
    final event = MailEvent.fromJson(const {
      'title': 'Online assessment',
      'start': '2026-09-14',
      'kind': 'deadline',
    });
    expect(event.date, '2026-09-14');
    expect(event.title, 'Online assessment');
    expect(event.isDeadline, isTrue);
  });

  test('a cached event survives the round trip through the offline cache', () {
    final event = MailEvent.fromJson(const {'start': '2026-09-14', 'kind': 'event'});
    expect(MailEvent.fromJson(event.toJson()).date, '2026-09-14');
  });

  test('a thread parsed from the API keeps its dates, so urgency can be computed', () {
    final now = DateTime(2026, 9, 12);
    final overdue = TreeNode.fromJson(_threadJson('2026-09-08'));
    final soon = TreeNode.fromJson(_threadJson('2026-09-14'));

    expect(overdue.events.single.date, '2026-09-08');
    expect(threadStatus(overdue, now).status, ThreadStatus.overdue);
    expect(threadStatus(soon, now).status, ThreadStatus.soon);
    expect(matchesFilter(overdue, TimeFilter.overdue, '', now), isTrue);
  });

  test('upcomingEvents keeps what is still ahead, by date rather than a server flag', () {
    // The server sends no `status` on events, so filtering on it kept everything.
    final past = TreeNode.fromJson(_threadJson('2020-01-01'));
    final ahead = TreeNode.fromJson(_threadJson('2099-01-01'));
    expect(past.upcomingEvents, isEmpty);
    expect(ahead.upcomingEvents, hasLength(1));
  });
}
