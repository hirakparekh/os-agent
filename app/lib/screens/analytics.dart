import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';

/// Mail volume by category over time — the console's Analytics page, on a phone.
///
/// Same shape as the web: the top four categories keep their own colour and everything else
/// folds into a neutral "Other" rather than generating more hues, and the numbers are always
/// available as a plain table underneath. That table is not decoration: two of the four series
/// colours fall below 3:1 contrast, so the chart alone is not readable for everyone.
///
/// Bars run horizontally, one row per time bucket, because a phone has height to spare and no
/// width for a date axis. Drawn with plain widgets: this is a stacked bar over a few dozen
/// rows, and a charting package would be a dependency and a theme surface to make one `Row`.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  String _bucket = 'day';

  // The web's categorical palette (Analytics.tsx), light and dark.
  static const _seriesLight = [
    Color(0xFF2A78D6),
    Color(0xFFEB6834),
    Color(0xFF1BAF7A),
    Color(0xFFEDA100),
  ];
  static const _otherLight = Color(0xFF8B8A85);
  static const _seriesDark = [
    Color(0xFF3987E5),
    Color(0xFFD95926),
    Color(0xFF199E70),
    Color(0xFFC98500),
  ];
  static const _otherDark = Color(0xFF9C9B95);

  static const _maxSeries = 4;
  static const _other = 'Other';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => context.read<AppState>().loadVolume(bucket: _bucket));
  }

  void _setBucket(String bucket) {
    if (bucket == _bucket) return;
    setState(() => _bucket = bucket);
    context.read<AppState>().loadVolume(bucket: bucket);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;

    final pivot = _Pivot.of(state.volume, _maxSeries, _other);
    final colors = <String, Color>{
      for (var i = 0; i < pivot.categories.length; i++)
        pivot.categories[i]: pivot.categories[i] == _other
            ? (dark ? _otherDark : _otherLight)
            : (dark ? _seriesDark : _seriesLight)[i % _maxSeries],
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'day', label: Text('Day')),
                ButtonSegment(value: 'week', label: Text('Week')),
              ],
              selected: {_bucket},
              onSelectionChanged: (s) => _setBucket(s.first),
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                  Text(
                    'Mail volume by category over time.',
                    style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _Stat(value: '${pivot.total}', label: 'threads sorted'),
                      const Spacer(),
                      _Stat(
                        value: '${pivot.allCategories.length}',
                        label: pivot.allCategories.length == 1 ? 'category' : 'categories',
                        small: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  _SectionLabel(_bucket == 'day' ? 'BY DAY' : 'BY WEEK'),
                  const SizedBox(height: 12),
                  ...pivot.rows.map((row) => _BucketBar(
                        row: row,
                        categories: pivot.categories,
                        colors: colors,
                        max: pivot.busiest,
                      )),
                  const SizedBox(height: 24),
                  _Legend(categories: pivot.categories, colors: colors),
                  const SizedBox(height: 28),
                  const _SectionLabel('WHERE IT GOES'),
                  const SizedBox(height: 12),
                  ...pivot.totalsByCategory.map((e) => _TotalRow(
                        label: e.key,
                        count: e.value,
                        max: pivot.totalsByCategory.first.value,
                        color: colors[e.key] ?? scheme.primary,
                      )),
                  const SizedBox(height: 28),
                  // The relief rule: the series colours alone are not readable for everyone,
                  // so every number is also here as text.
                  const _SectionLabel('DATA TABLE'),
                  const SizedBox(height: 10),
                  _DataTable(pivot: pivot, bucketLabel: _bucket == 'day' ? 'Date' : 'Week'),
                ],
              ),
            ),
    );
  }
}

/// The same reshaping the web does: rank categories by total, keep the top few, fold the rest
/// into one neutral series, and index the counts by time bucket.
class _Pivot {
  const _Pivot({
    required this.rows,
    required this.categories,
    required this.allCategories,
    required this.totalsByCategory,
    required this.total,
    required this.busiest,
  });

  final List<_Row> rows;

  /// Series drawn, in order, including "Other" last when it exists.
  final List<String> categories;

  /// Every category the server reported, before folding.
  final List<String> allCategories;

  final List<MapEntry<String, int>> totalsByCategory;
  final int total;

  /// The heaviest bucket, so every bar shares one scale.
  final int busiest;

  static _Pivot of(List<VolumePoint> points, int maxSeries, String other) {
    final totals = <String, int>{};
    for (final p in points) {
      totals[p.category] = (totals[p.category] ?? 0) + p.count;
    }
    final ranked = totals.entries.toList(growable: false)
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = ranked.take(maxSeries).map((e) => e.key).toList(growable: false);
    final categories = [...top, if (ranked.length > maxSeries) other];

    final byBucket = <String, Map<String, int>>{};
    for (final p in points) {
      final key = top.contains(p.category) ? p.category : other;
      final row = byBucket.putIfAbsent(p.bucket, () => <String, int>{});
      row[key] = (row[key] ?? 0) + p.count;
    }
    final rows = byBucket.entries.map((e) => _Row(e.key, e.value)).toList(growable: false)
      ..sort((a, b) => a.bucket.compareTo(b.bucket));

    return _Pivot(
      rows: rows,
      categories: categories,
      allCategories: ranked.map((e) => e.key).toList(growable: false),
      totalsByCategory: ranked,
      total: points.fold<int>(0, (a, p) => a + p.count),
      busiest: rows.isEmpty ? 0 : rows.map((r) => r.total).reduce((a, b) => a > b ? a : b),
    );
  }
}

class _Row {
  _Row(this.bucket, this.counts);

  final String bucket;
  final Map<String, int> counts;

  int get total => counts.values.fold(0, (a, b) => a + b);
}

/// One time bucket: a stacked bar across the categories that landed in it.
class _BucketBar extends StatelessWidget {
  const _BucketBar({
    required this.row,
    required this.categories,
    required this.colors,
    required this.max,
  });

  final _Row row;
  final List<String> categories;
  final Map<String, Color> colors;
  final int max;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.bucket,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              Text(
                '${row.total}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          // One scale across every row — a light day is visibly a light day — expressed as flex
          // weights, with the unused remainder as a Spacer. Not a FractionallySizedBox: under
          // the loose constraints a ListView hands its children, that sizes itself to the child
          // and the segments inside collapse to zero width.
          SizedBox(
            height: 10,
            width: double.infinity,
            child: Row(
              // stretch, or the segments inherit a loose height: a ColoredBox with no child
              // takes the smallest size it is offered, which is zero, and the bar disappears.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final category in categories)
                  if ((row.counts[category] ?? 0) > 0)
                    Expanded(
                      flex: row.counts[category]!,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 1.5),
                        // Keyed here rather than on the Expanded: a ParentDataWidget owns no
                        // render object, so measuring it in a test tells you nothing.
                        child: ClipRRect(
                          key: ValueKey('segment:${row.bucket}:$category'),
                          borderRadius: BorderRadius.circular(3),
                          child: ColoredBox(color: colors[category] ?? scheme.primary),
                        ),
                      ),
                    ),
                if (max > row.total) Spacer(flex: max - row.total),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Category totals across the whole window, heaviest first.
class _TotalRow extends StatelessWidget {
  const _TotalRow({
    required this.label,
    required this.count,
    required this.max,
    required this.color,
  });

  final String label;
  final int count;
  final int max;
  final Color color;

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
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
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
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.categories, required this.colors});

  final List<String> categories;
  final Map<String, Color> colors;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 14,
      runSpacing: 8,
      children: [
        for (final category in categories)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: colors[category],
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                category,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
      ],
    );
  }
}

class _DataTable extends StatelessWidget {
  const _DataTable({required this.pivot, required this.bucketLabel});

  final _Pivot pivot;
  final String bucketLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final head = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
    );
    const cell = TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()]);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 34,
        dataRowMinHeight: 30,
        dataRowMaxHeight: 38,
        horizontalMargin: 0,
        columnSpacing: 22,
        columns: [
          DataColumn(label: Text(bucketLabel, style: head)),
          for (final category in pivot.categories) DataColumn(label: Text(category, style: head)),
        ],
        rows: [
          for (final row in pivot.rows)
            DataRow(cells: [
              DataCell(Text(row.bucket, style: cell)),
              for (final category in pivot.categories)
                DataCell(Text('${row.counts[category] ?? 0}', style: cell)),
            ]),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.small = false});

  final String value;
  final String label;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: small ? 22 : 40,
            fontWeight: FontWeight.w700,
            height: 1,
            letterSpacing: -1,
            color: small ? scheme.onSurface : scheme.primary,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(fontSize: small ? 12.5 : 14, color: scheme.onSurfaceVariant),
        ),
      ],
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
                  ? 'Analytics are calculated on the server rather than saved to the device.'
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
