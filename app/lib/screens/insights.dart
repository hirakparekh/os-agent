import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';

/// How much mail arrives, and in what.
///
/// Drawn with plain widgets rather than a charting package: this is one horizontal bar chart
/// over at most a few dozen rows, and a chart library would be a dependency, a theme surface,
/// and a render pipeline to make one `Container` wide.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  String _bucket = 'week';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => context.read<AppState>().loadVolume(bucket: _bucket));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final byCategory = _totalsByCategory(state.volume);
    final busiest = _busiestBuckets(state.volume);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Insights'),
        actions: [
          PopupMenuButton<String>(
            initialValue: _bucket,
            onSelected: (value) {
              setState(() => _bucket = value);
              state.loadVolume(bucket: value);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'day', child: Text('By day')),
              PopupMenuItem(value: 'week', child: Text('By week')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Text(_bucket == 'day' ? 'Daily' : 'Weekly',
                      style: TextStyle(fontSize: 13.5, color: scheme.primary)),
                  Icon(Icons.arrow_drop_down, color: scheme.primary),
                ],
              ),
            ),
          ),
        ],
      ),
      body: state.volume.isEmpty
          ? _NoData(offline: state.offline)
          : RefreshIndicator(
              onRefresh: () => state.loadVolume(bucket: _bucket),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 40),
                children: [
                  _Stat(
                    value: '${state.volume.fold<int>(0, (a, p) => a + p.count)}',
                    label: 'threads sorted',
                  ),
                  const SizedBox(height: 26),
                  Text(
                    'WHERE IT GOES',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...byCategory.map((e) => _Bar(
                        label: e.key,
                        count: e.value,
                        max: byCategory.first.value,
                      )),
                  if (busiest.isNotEmpty) ...[
                    const SizedBox(height: 30),
                    Text(
                      _bucket == 'day' ? 'BUSIEST DAYS' : 'BUSIEST WEEKS',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...busiest.map((e) => _Bar(
                          label: e.key,
                          count: e.value,
                          max: busiest.first.value,
                        )),
                  ],
                ],
              ),
            ),
    );
  }

  /// Totals per category, heaviest first.
  static List<MapEntry<String, int>> _totalsByCategory(List<VolumePoint> points) {
    final totals = <String, int>{};
    for (final p in points) {
      totals[p.category] = (totals[p.category] ?? 0) + p.count;
    }
    return totals.entries.toList(growable: false)
      ..sort((a, b) => b.value.compareTo(a.value));
  }

  /// The five heaviest time buckets, so a spike is visible without a time axis.
  static List<MapEntry<String, int>> _busiestBuckets(List<VolumePoint> points) {
    final totals = <String, int>{};
    for (final p in points) {
      totals[p.bucket] = (totals[p.bucket] ?? 0) + p.count;
    }
    final sorted = totals.entries.toList(growable: false)
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(5).toList(growable: false);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 40,
            fontWeight: FontWeight.w700,
            height: 1,
            letterSpacing: -1,
            color: scheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.label, required this.count, required this.max});

  final String label;
  final int count;
  final int max;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = max == 0 ? 0.0 : count / max;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 7,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(scheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoData extends StatelessWidget {
  const _NoData({required this.offline});

  final bool offline;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              offline ? Icons.cloud_off : Icons.bar_chart_outlined,
              size: 42,
              color: scheme.outline,
            ),
            const SizedBox(height: 14),
            Text(
              offline ? 'Needs a connection' : 'Nothing to chart yet',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              offline
                  ? 'Insights are calculated on the server rather than saved to the device.'
                  : 'Sync some mail and this fills in.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
