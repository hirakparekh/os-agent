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

    return RefreshIndicator(
      onRefresh: state.refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (state.lastSynced != null) _SyncedAgo(when: state.lastSynced!),
          const _QuickActions(),
          // Nothing stands in for an empty feed: the cards are the screen when there is
          // nothing to act on, rather than being pushed into a corner by a paragraph
          // explaining that there is nothing to act on.
          if (state.urgent.isNotEmpty) ...[
            const SizedBox(height: 28),
            _SectionHeader(label: 'Needs attention', count: state.urgent.length),
            const SizedBox(height: 10),
            ...state.urgent.map((t) => _UrgentCard(thread: t)),
          ],
          if (state.actions.isNotEmpty) ...[
            const SizedBox(height: 28),
            _SectionHeader(label: 'Action items', count: state.actions.length),
            const SizedBox(height: 10),
            ...state.actions.map((a) => _ActionCard(item: a)),
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

    return Column(
      children: [
        // Sync is the one action with a duty cycle — it is the reason to open the app after a
        // few hours away — so it gets the full width and carries its own progress.
        _HeroCard(
          icon: Icons.sync,
          title: state.syncing ? 'Syncing your mail' : 'Sync mail',
          subtitle: state.syncing
              ? (state.syncStage ?? 'Fetching and sorting…')
              : 'Fetch what arrived and sort it',
          tint: _sync,
          busy: state.syncing,
          onTap: state.syncing ? null : () => state.runSync(),
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.02,
          children: [
            _ActionTile(
              icon: Icons.rule,
              label: 'Needs a decision',
              detail: 'Threads filed with low confidence',
              tint: _review,
              onTap: () => _open(context, const ReviewScreen()),
            ),
            _ActionTile(
              icon: Icons.bar_chart,
              label: 'Analytics',
              detail: 'Volume by category over time',
              tint: _analytics,
              onTap: () => _open(context, const AnalyticsScreen()),
            ),
            _ActionTile(
              icon: Icons.person_outline,
              label: 'About you',
              detail: 'Facts the assistant can use',
              tint: _about,
              onTap: () => _open(context, const ProfileScreen()),
            ),
            _ActionTile(
              icon: Icons.settings_outlined,
              label: 'Settings',
              detail: 'Connections and processing',
              tint: _settings,
              onTap: () => _open(context, const SettingsScreen()),
            ),
          ],
        ),
      ],
    );
  }

  static void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }
}

/// Tint mixed against the surface rather than being a fixed fill: one hue then works in both
/// themes, where a pastel would go muddy in the dark and a dark fill would vanish in the light.
({Color background, Color foreground, Color chip}) _tones(BuildContext context, Color tint) {
  final scheme = Theme.of(context).colorScheme;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return (
    background: Color.alphaBlend(tint.withValues(alpha: dark ? 0.20 : 0.11), scheme.surface),
    foreground: dark ? Color.alphaBlend(tint.withValues(alpha: 0.65), Colors.white) : tint,
    chip: Color.alphaBlend(tint.withValues(alpha: dark ? 0.32 : 0.18), scheme.surface),
  );
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tint,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color tint;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tones = _tones(context, tint);

    return Material(
      color: tones.background,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: tones.chip,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: busy
                    ? Center(
                        child: SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: tones.foreground,
                          ),
                        ),
                      )
                    : Icon(icon, size: 26, color: tones.foreground),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.detail,
    required this.tint,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String detail;
  final Color tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tones = _tones(context, tint);

    return Material(
      color: tones.background,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: tones.chip,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 23, color: tones.foreground),
              ),
              const Spacer(),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15.5,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, height: 1.3, color: scheme.onSurfaceVariant),
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

void _openThread(BuildContext context, String threadId, String fallbackTitle) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ThreadScreen(threadId: threadId, fallbackTitle: fallbackTitle),
    ),
  );
}
