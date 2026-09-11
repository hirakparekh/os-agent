import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import 'thread.dart';

/// The home screen: everything that needs a decision today, from every channel at once.
///
/// This is the app's reason to exist. Browsing the tree is better on a laptop; what a phone is
/// uniquely good at is telling you the thing you would otherwise miss. Both lists below are
/// computed deterministically during ingest — no model call — so they are exact and cost
/// nothing to poll.
class TodayTab extends StatelessWidget {
  const TodayTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final hasNothing = state.urgent.isEmpty && state.actions.isEmpty;

    return RefreshIndicator(
      onRefresh: state.refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          if (state.lastSynced != null) _SyncedAgo(when: state.lastSynced!),
          if (hasNothing)
            const _EmptyToday()
          else ...[
            if (state.urgent.isNotEmpty) ...[
              _SectionHeader(label: 'Needs attention', count: state.urgent.length),
              const SizedBox(height: 8),
              ...state.urgent.map((t) => _UrgentCard(thread: t)),
              const SizedBox(height: 24),
            ],
            if (state.actions.isNotEmpty) ...[
              _SectionHeader(label: 'Action items', count: state.actions.length),
              const SizedBox(height: 8),
              ...state.actions.map((a) => _ActionCard(item: a)),
            ],
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _UrgentCard extends StatelessWidget {
  const _UrgentCard({required this.thread});

  final UrgentThread thread;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openThread(context, thread.id, thread.name),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      thread.name,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (thread.summary != null && thread.summary!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  thread.summary!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 10),
              _Trail(channel: thread.channel, category: thread.category, topic: thread.topic),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.item});

  final ActionItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openThread(context, item.threadId, item.threadName ?? 'Thread'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_box_outline_blank, size: 18, color: scheme.outline),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(item.text, style: const TextStyle(fontSize: 14.5, height: 1.35)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _Trail(
                channel: item.channel,
                category: item.category,
                topic: item.topic,
                source: item.threadName,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The breadcrumb under each card: which channel it arrived on and where it was filed.
class _Trail extends StatelessWidget {
  const _Trail({
    required this.channel,
    this.category,
    this.topic,
    this.source,
  });

  final String channel;
  final String? category;
  final String? topic;
  final String? source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = <String>[
      if (source != null && source!.isNotEmpty) source!,
      if (category != null && category!.isNotEmpty) category!,
      if (topic != null && topic!.isNotEmpty) topic!,
    ];
    return Row(
      children: [
        Icon(
          channel == 'slack' ? Icons.tag : Icons.mail_outline,
          size: 13,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            parts.isEmpty ? channel : parts.join('  ·  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _SyncedAgo extends StatelessWidget {
  const _SyncedAgo({required this.when});

  final DateTime when;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(
        'Synced ${_ago(when)}',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
    );
  }

  static String _ago(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }
}

/// Shown when both feeds are empty — which is a real and correct state, not a failure.
///
/// Urgency and action items are computed during ingest, so threads that predate those
/// features carry neither until the next sync. Saying so here saves someone debugging a
/// working system.
class _EmptyToday extends StatelessWidget {
  const _EmptyToday();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 64),
      child: Column(
        children: [
          Icon(Icons.done_all, size: 44, color: scheme.outline),
          const SizedBox(height: 16),
          const Text(
            'Nothing needs you right now',
            style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Urgent threads and to-dos are picked out while mail syncs. If you have just '
              'added this account, run a sync to fill this in.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant, height: 1.45),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => context.read<AppState>().runSync(),
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('Sync mail now'),
          ),
        ],
      ),
    );
  }
}

void _openThread(BuildContext context, String threadId, String fallbackTitle) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ThreadScreen(threadId: threadId, fallbackTitle: fallbackTitle),
    ),
  );
}
