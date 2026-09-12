import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import 'analytics.dart';
import 'profile.dart';
import 'review.dart';
import 'settings.dart';
import 'thread.dart';

/// The home screen: what needs a decision today, from every channel at once, over the actions
/// worth one tap.
///
/// This is the app's reason to exist. Browsing the tree is better on a laptop; what a phone is
/// uniquely good at is telling you the thing you would otherwise miss. Both feeds below are
/// computed deterministically during ingest — no model call — so they are exact and cost
/// nothing to poll.
///
/// The actions used to live behind an overflow menu, which put every one of them two taps and
/// a guess away. They are cards here because on a phone the menu is the least discoverable
/// place a feature can be.
class HomeTab extends StatelessWidget {
  const HomeTab({super.key});

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
          const _QuickActions(),
          const SizedBox(height: 24),
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

/// One tap to each place the app can go. Each card carries its own hue so they are told apart
/// by shape and colour before the label is read; the tint is the same in both themes because
/// it is mixed against the surface rather than being a fixed light or dark fill.
class _QuickActions extends StatelessWidget {
  const _QuickActions();

  static const _sync = Color(0xFF0E6265);
  static const _review = Color(0xFFF59E0B);
  static const _analytics = Color(0xFF2A78D6);
  static const _about = Color(0xFF8B5CF6);
  static const _settings = Color(0xFF64748B);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.5,
      children: [
        _ActionTile(
          icon: state.syncing ? null : Icons.sync,
          label: state.syncing ? (state.syncStage ?? 'Syncing…') : 'Sync mail',
          tint: _sync,
          busy: state.syncing,
          onTap: state.syncing ? null : () => state.runSync(),
        ),
        _ActionTile(
          icon: Icons.rule,
          label: 'Needs a decision',
          tint: _review,
          onTap: () => _open(context, const ReviewScreen()),
        ),
        _ActionTile(
          icon: Icons.bar_chart,
          label: 'Analytics',
          tint: _analytics,
          onTap: () => _open(context, const AnalyticsScreen()),
        ),
        _ActionTile(
          icon: Icons.person_outline,
          label: 'About you',
          tint: _about,
          onTap: () => _open(context, const ProfileScreen()),
        ),
        _ActionTile(
          icon: Icons.settings_outlined,
          label: 'Settings',
          tint: _settings,
          onTap: () => _open(context, const SettingsScreen()),
        ),
      ],
    );
  }

  static void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.tint,
    required this.onTap,
    this.busy = false,
  });

  final IconData? icon;
  final String label;
  final Color tint;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Mixed against the surface so one hue works in both themes: a fixed pastel would go muddy
    // in dark mode, a fixed dark fill would disappear in light mode.
    final background = Color.alphaBlend(tint.withValues(alpha: dark ? 0.22 : 0.12), scheme.surface);
    final foreground = dark ? Color.alphaBlend(tint.withValues(alpha: 0.6), Colors.white) : tint;

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: busy
                    ? Center(
                        child: SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
                        ),
                      )
                    : Icon(icon, size: 21, color: foreground),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
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
      padding: const EdgeInsets.only(top: 40),
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
