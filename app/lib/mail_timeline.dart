/// The mind map's time view, filters and colours — a direct port of the console's
/// `console/frontend/src/lib/mailTimeline.ts`, so both clients group and colour the same tree
/// the same way.
///
/// Nothing here is stored. The brain keeps dates as thread attributes
/// (`brain/mail_timeline.py`) and urgency is recomputed against today on every build, so "due
/// soon" can never go stale. The thread's own `status` field from the server is deliberately
/// ignored for the same reason: it was true when the payload was cached, not necessarily now.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'models.dart';

enum ThreadStatus { overdue, soon, upcoming, past, none }

enum TimeMode { upcoming, received }

enum TimeFilter { all, overdue, week, upcoming, recent }

// Keep in step with brain/mail_timeline.py, which applies the same rules for chat answers.
const int soonDays = 3;
const int overdueWindowDays = 14;
const Duration newWithin = Duration(days: 1);
const int staleAfterDays = 30;

const Map<ThreadStatus, Color?> statusColors = {
  ThreadStatus.overdue: Color(0xFFEF4444),
  ThreadStatus.soon: Color(0xFFF59E0B),
  ThreadStatus.upcoming: Color(0xFF3B82F6),
  ThreadStatus.past: null,
  ThreadStatus.none: null,
};

const Map<ThreadStatus, String> statusLabels = {
  ThreadStatus.overdue: 'Overdue',
  ThreadStatus.soon: 'Due within 3 days',
  ThreadStatus.upcoming: 'Upcoming',
  ThreadStatus.past: 'Past',
  ThreadStatus.none: 'No date',
};

/// Short label for one event's status chip.
String eventStatusLabel(ThreadStatus status, String kind) {
  if (status == ThreadStatus.soon) return kind == 'deadline' ? 'Due soon' : 'Soon';
  if (status == ThreadStatus.past) return kind == 'deadline' ? 'Passed' : 'Done';
  return statusLabels[status]!;
}

// Category hues avoid red, amber and blue, which belong to urgency. Ordered so the first few
// are as far apart as possible — most inboxes have only a handful of categories.
const List<Color> categoryPalette = [
  Color(0xFF8B5CF6),
  Color(0xFF10B981),
  Color(0xFFEC4899),
  Color(0xFF06B6D4),
  Color(0xFFA3E635),
  Color(0xFFD946EF),
  Color(0xFF6366F1),
  Color(0xFF14B8A6),
];

DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

/// The calendar day an event is on, as written in the mail — not shifted into local time.
DateTime? eventDay(MailEvent event) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(event.date);
  if (match == null) return null;
  return DateTime(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
}

int dayDiff(DateTime a, DateTime b) =>
    (startOfDay(a).difference(startOfDay(b)).inHours / 24).round();

class StatusInfo {
  const StatusInfo(this.status, this.event, this.days);

  final ThreadStatus status;
  final MailEvent? event;
  final int? days;
}

StatusInfo threadStatus(TreeNode node, DateTime today) {
  final dated = <({MailEvent event, DateTime day})>[];
  for (final event in node.events) {
    final day = eventDay(event);
    if (day != null) dated.add((event: event, day: day));
  }

  final upcoming = dated.where((e) => dayDiff(e.day, today) >= 0).toList()
    ..sort((a, b) => a.day.compareTo(b.day));
  if (upcoming.isNotEmpty) {
    final days = dayDiff(upcoming.first.day, today);
    return StatusInfo(
      days <= soonDays ? ThreadStatus.soon : ThreadStatus.upcoming,
      upcoming.first.event,
      days,
    );
  }
  if (dated.isNotEmpty) {
    final latest = dated.reduce((a, b) => b.day.isAfter(a.day) ? b : a);
    final days = dayDiff(latest.day, today);
    final overdue = latest.event.isDeadline && -days <= overdueWindowDays;
    return StatusInfo(overdue ? ThreadStatus.overdue : ThreadStatus.past, latest.event, days);
  }
  return const StatusInfo(ThreadStatus.none, null, null);
}

/// One event's own urgency, for screens listing a thread's dates rather than the thread.
ThreadStatus eventStatus(MailEvent event, DateTime today) {
  final day = eventDay(event);
  if (day == null) return ThreadStatus.none;
  final days = dayDiff(day, today);
  if (days >= 0) return days <= soonDays ? ThreadStatus.soon : ThreadStatus.upcoming;
  return event.isDeadline && -days <= overdueWindowDays
      ? ThreadStatus.overdue
      : ThreadStatus.past;
}

DateTime? receivedAt(TreeNode node) =>
    node.lastReceived == null ? null : DateTime.tryParse(node.lastReceived!);

bool isNew(TreeNode node, DateTime now) {
  final r = receivedAt(node);
  return !node.receivedEstimated && r != null && now.difference(r) < newWithin;
}

/// Old, with nothing pending — drawn faded so what matters stands out.
bool isStale(TreeNode node, DateTime now) {
  final r = receivedAt(node);
  final status = threadStatus(node, now).status;
  return r != null &&
      (status == ThreadStatus.none || status == ThreadStatus.past) &&
      dayDiff(now, r) > staleAfterDays;
}

final DateFormat _fmtDay = DateFormat('EEE, d MMM');
final DateFormat _fmtMonth = DateFormat('MMMM y');

String formatEventDate(MailEvent event) {
  final day = eventDay(event);
  if (day == null) return event.date;
  final time = RegExp(r'T(\d{2}):(\d{2})').firstMatch(event.date);
  final hasTime = time != null && !(time[1] == '00' && time[2] == '00');
  return hasTime ? '${_fmtDay.format(day)}, ${time[1]}:${time[2]}' : _fmtDay.format(day);
}

String relativeDays(int days) {
  if (days == 0) return 'today';
  if (days == 1) return 'tomorrow';
  if (days == -1) return 'yesterday';
  return days > 0 ? 'in $days days' : '${-days} days ago';
}

String _relativeAgo(DateTime then, DateTime now) {
  final mins = (now.difference(then).inSeconds / 60).round();
  if (mins < 60) return '${mins < 1 ? 1 : mins}m ago';
  final hours = (mins / 60).round();
  if (hours < 24) return '${hours}h ago';
  return relativeDays(-dayDiff(now, then));
}

/// The second line under a thread's title: its most pressing date, or when it arrived.
String threadMeta(TreeNode node, DateTime now) {
  final info = threadStatus(node, now);
  final event = info.event;
  if (event != null && info.days != null && info.status != ThreadStatus.past) {
    if (info.status == ThreadStatus.overdue) {
      return 'Overdue · was due ${formatEventDate(event)}';
    }
    final lead = event.isDeadline ? 'Due ' : '';
    return '$lead${formatEventDate(event)} · ${relativeDays(info.days!)}';
  }
  final r = receivedAt(node);
  if (r == null) return '';
  return 'Received ${node.receivedEstimated ? '~' : ''}${_relativeAgo(r, now)}';
}

/// A colour per category, assigned in alphabetical order so it is the same in both views and
/// across reloads, and so a small set of categories always gets the most distinct hues.
Map<String, Color> categoryColors(TreeNode root) {
  final names = <String>{
    for (final child in root.children)
      if (child.type == 'mail_category') child.name,
  }.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return {
    for (var i = 0; i < names.length; i++)
      names[i]: categoryPalette[i % categoryPalette.length],
  };
}

List<TreeNode> collectThreads(TreeNode node) {
  if (node.isThread) return [node];
  return [for (final child in node.children) ...collectThreads(child)];
}

bool matchesFilter(TreeNode node, TimeFilter filter, String query, DateTime now) {
  final q = query.trim().toLowerCase();
  if (q.isNotEmpty) {
    final haystack = [
      node.name,
      node.summary,
      node.topic,
      node.category,
      for (final event in node.events) event.title,
    ].whereType<String>().join(' ').toLowerCase();
    if (!haystack.contains(q)) return false;
  }
  if (filter == TimeFilter.all) return true;

  final info = threadStatus(node, now);
  if (filter == TimeFilter.overdue) return info.status == ThreadStatus.overdue;
  final pending = info.status == ThreadStatus.soon || info.status == ThreadStatus.upcoming;
  if (filter == TimeFilter.week) return pending && info.days != null && info.days! <= 7;
  if (filter == TimeFilter.upcoming) return pending;
  final r = receivedAt(node);
  return r != null && dayDiff(now, r) <= 7;
}

/// A copy of the tree keeping only matching threads, and dropping branches left empty.
TreeNode? filterTree(TreeNode node, bool Function(TreeNode thread) keep) {
  if (node.isThread) return keep(node) ? node : null;
  final children = <TreeNode>[
    for (final child in node.children)
      if (filterTree(child, keep) case final kept?) kept,
  ];
  if (children.isEmpty && node.type != 'root') return null;
  return node.copyWith(children: children);
}

// --- the time view -----------------------------------------------------------------------

TreeNode _bucket(String id, String name, List<TreeNode> threads) => TreeNode(
      id: 'time:$id',
      name: name,
      type: 'time_bucket',
      summary: '${threads.length} thread${threads.length == 1 ? '' : 's'}',
      children: threads,
    );

/// Buckets that start collapsed: history nobody needs to see first.
const Set<String> collapsedBuckets = {'time:upcoming:past', 'time:upcoming:none'};

List<TreeNode> _upcomingTree(List<TreeNode> threads, DateTime now) {
  final order = ['overdue', 'today', 'week', 'next', 'later', 'past', 'none'];
  const names = {
    'overdue': 'Overdue',
    'today': 'Today',
    'week': 'This week',
    'next': 'Next week',
    'later': 'Later',
    'past': 'Past events',
    'none': 'No date',
  };
  final groups = {for (final key in order) key: <({TreeNode node, num sort})>[]};

  for (final node in threads) {
    final info = threadStatus(node, now);
    final d = info.days ?? 0;
    final key = switch (info.status) {
      ThreadStatus.overdue => 'overdue',
      ThreadStatus.past => 'past',
      ThreadStatus.none => 'none',
      _ => d == 0
          ? 'today'
          : d <= 7
              ? 'week'
              : d <= 14
                  ? 'next'
                  : 'later',
    };
    // Overdue and past read most-recent first; everything ahead reads soonest first.
    final sort = key == 'none'
        ? -(receivedAt(node)?.millisecondsSinceEpoch ?? 0)
        : (key == 'overdue' || key == 'past' ? -d : d);
    groups[key]!.add((node: node, sort: sort));
  }

  return [
    for (final key in order)
      if (groups[key]!.isNotEmpty)
        _bucket(
          'upcoming:$key',
          names[key]!,
          (groups[key]!..sort((a, b) => a.sort.compareTo(b.sort)))
              .map((i) => i.node)
              .toList(growable: false),
        ),
  ];
}

List<TreeNode> _receivedTree(List<TreeNode> threads) {
  final dated = threads.map((node) => (node: node, at: receivedAt(node))).toList()
    ..sort((a, b) =>
        (b.at?.millisecondsSinceEpoch ?? 0).compareTo(a.at?.millisecondsSinceEpoch ?? 0));

  final months = <String, ({String label, Map<String, ({String label, List<TreeNode> nodes})> days})>{};
  final undated = <TreeNode>[];

  for (final entry in dated) {
    final at = entry.at;
    if (at == null) {
      undated.add(entry.node);
      continue;
    }
    final monthKey = '${at.year}-${at.month.toString().padLeft(2, '0')}';
    final dayKey = '$monthKey-${at.day.toString().padLeft(2, '0')}';
    final month = months.putIfAbsent(
      monthKey,
      () => (label: _fmtMonth.format(at), days: {}),
    );
    month.days.putIfAbsent(dayKey, () => (label: _fmtDay.format(at), nodes: []));
    month.days[dayKey]!.nodes.add(entry.node);
  }

  final out = <TreeNode>[
    for (final month in months.entries)
      () {
        final days = [
          for (final day in month.value.days.entries)
            _bucket('received:${day.key}', day.value.label, day.value.nodes),
        ];
        final count = days.fold<int>(0, (n, d) => n + d.children.length);
        return _bucket('received:${month.key}', month.value.label, const []).copyWith(
          children: days,
          summary: '$count thread${count == 1 ? '' : 's'}',
        );
      }(),
  ];
  if (undated.isNotEmpty) out.add(_bucket('received:unknown', 'Unknown date', undated));
  return out;
}

TreeNode buildTimeTree(TreeNode data, TimeMode mode, DateTime now) {
  final threads = collectThreads(data);
  return TreeNode(
    id: 'time:root:${mode.name}',
    name: mode == TimeMode.upcoming ? 'Upcoming' : 'Received',
    type: 'root',
    children: mode == TimeMode.upcoming ? _upcomingTree(threads, now) : _receivedTree(threads),
  );
}
