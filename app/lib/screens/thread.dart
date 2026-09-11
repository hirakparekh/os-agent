import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';

/// A single thread, read out of the cached tree rather than fetched.
///
/// `GET /api/mail_tree` returns thread bodies inline, so the one payload the app already has
/// covers detail too. There is no per-thread request to make, which is why this screen works
/// with no connection and needs no loading state.
class ThreadScreen extends StatelessWidget {
  const ThreadScreen({super.key, required this.threadId, required this.fallbackTitle});

  final String threadId;
  final String fallbackTitle;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final node = state.tree?.findById(threadId);
    final actions =
        state.actions.where((a) => a.threadId == threadId).toList(growable: false);
    final isUrgent = state.urgent.any((t) => t.id == threadId);

    return Scaffold(
      appBar: AppBar(title: Text(node?.name ?? fallbackTitle, maxLines: 1)),
      body: node == null
          ? _NotCached(title: fallbackTitle)
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [
                if (isUrgent) const _UrgentBanner(),
                Text(
                  node.name,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 10),
                _Meta(node: node),
                if (node.summary != null && node.summary!.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _Block(label: 'Summary', child: Text(node.summary!, style: _bodyStyle)),
                ],
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _Block(
                    label: actions.length == 1 ? 'Action item' : 'Action items',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: actions
                          .map((a) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('•  '),
                                    Expanded(child: Text(a.text, style: _bodyStyle)),
                                  ],
                                ),
                              ))
                          .toList(growable: false),
                    ),
                  ),
                ],
                if (node.upcomingEvents.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _Block(
                    label: 'Dates',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: node.upcomingEvents
                          .map((e) => _EventRow(event: e))
                          .toList(growable: false),
                    ),
                  ),
                ],
                if (node.body != null && node.body!.trim().isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _Block(label: 'Message', child: SelectableText(node.body!, style: _bodyStyle)),
                ],
              ],
            ),
    );
  }

  static const _bodyStyle = TextStyle(fontSize: 15, height: 1.55);
}

class _Meta extends StatelessWidget {
  const _Meta({required this.node});

  final TreeNode node;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(
          node.channel == 'slack' ? Icons.tag : Icons.mail_outline,
          size: 14,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text(
          node.channel == 'slack' ? 'Slack' : 'Gmail',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        if (node.lastReceived != null) ...[
          const SizedBox(width: 12),
          Icon(Icons.schedule, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(
            // "~" marks a date inferred from when the thread was stored rather than read off
            // a Date header — true for anything ingested before dates were recorded.
            '${node.receivedEstimated ? '~' : ''}${_day(node.lastReceived!)}',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ],
        if (node.needsReview) ...[
          const SizedBox(width: 12),
          Icon(Icons.help_outline, size: 14, color: scheme.tertiary),
          const SizedBox(width: 5),
          Text(
            'Filed with low confidence',
            style: TextStyle(fontSize: 12.5, color: scheme.tertiary),
          ),
        ],
      ],
    );
  }
}

class _UrgentBanner extends StatelessWidget {
  const _UrgentBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Icon(Icons.priority_high, size: 17, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Text(
            'Flagged urgent',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

/// Reachable if a feed references a thread the cached tree does not contain — for instance
/// after a sync added it but the tree has not been refetched.
class _NotCached extends StatelessWidget {
  const _NotCached({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 40, color: scheme.outline),
            const SizedBox(height: 14),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text(
              'This thread is not saved on the device yet.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () => context.read<AppState>().refresh(),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One dated item, colour-coded by how soon it is.
class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final MailEvent event;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colour = switch (event.status) {
      'overdue' => scheme.error,
      'soon' => scheme.tertiary,
      _ => scheme.onSurfaceVariant,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            event.isDeadline ? Icons.flag_outlined : Icons.event_outlined,
            size: 16,
            color: colour,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title ?? (event.isDeadline ? 'Deadline' : 'Event'),
                  style: const TextStyle(fontSize: 14.5, height: 1.35),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    _day(event.date),
                    if (event.status == 'overdue') 'overdue',
                    if (event.status == 'soon') 'soon',
                  ].join('  ·  '),
                  style: TextStyle(fontSize: 12.5, color: colour),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Dates arrive as ISO-8601 strings; only the day part is worth showing here.
String _day(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${parsed.day} ${months[parsed.month - 1]}';
}
