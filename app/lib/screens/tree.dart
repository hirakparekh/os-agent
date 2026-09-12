import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../mail_timeline.dart';
import '../models.dart';
import 'thread.dart';

/// The knowledge tree as the console's collapsible mind map, on a pinch-zoom canvas.
///
/// A port of `console/frontend/src/components/MailMindmap.tsx` (itself a port of
/// `brain/mail_tree.html`): the same geometry, the same colours, the same By topic / By time
/// views, filter chips and search — so the phone shows the same picture as the web rather than
/// a second, differently-shaped idea of the tree. Rendering is Flutter's own painting instead
/// of D3/SVG, and pan/zoom is a gesture instead of scroll-to-zoom, which is the only part a
/// phone genuinely needs done differently.
///
/// Everything renders from the cached tree payload, so it works with no connection.

// Geometry, identical to MailMindmap.tsx.
const double _nodeHeight = 44;
const double _nodeGapY = 14;
const double _levelWidth = 280;
const double _dotPad = 12;
const double _minNodeWidth = 150;
const double _maxNodeWidth = 340;
const double _canvasMargin = 48;

enum _View { topic, time }

/// The CSS custom properties from MailMindmap.css, both themes.
class _Palette {
  const _Palette({
    required this.bg,
    required this.panel,
    required this.panel2,
    required this.line,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.cat,
    required this.topic,
    required this.thread,
    required this.link,
  });

  final Color bg, panel, panel2, line, ink, muted, accent, cat, topic, thread, link;

  static const light = _Palette(
    bg: Color(0xFFF8FAFC),
    panel: Color(0xFFFFFFFF),
    panel2: Color(0xFFF1F5F9),
    line: Color(0xFFE2E8F0),
    ink: Color(0xFF0F172A),
    muted: Color(0xFF64748B),
    accent: Color(0xFF0F766E),
    cat: Color(0xFF475569),
    topic: Color(0xFF059669),
    thread: Color(0xFF2563EB),
    link: Color(0xFFCBD5E1),
  );

  static const dark = _Palette(
    bg: Color(0xFF09090B),
    panel: Color(0xFF18181B),
    panel2: Color(0xFF27272A),
    line: Color(0xFF3F3F46),
    ink: Color(0xFFFAFAFA),
    muted: Color(0xFFA1A1AA),
    accent: Color(0xFF4DD0C4),
    cat: Color(0xFF6B7A99),
    topic: Color(0xFF3FAE90),
    thread: Color(0xFF5B8CFF),
    link: Color(0xFF52525B),
  );

  static _Palette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

String _truncate(String text, int max) =>
    text.length > max ? '${text.substring(0, max - 2)}…' : text;

/// One node with its place on the canvas.
class _Placed {
  _Placed({
    required this.node,
    required this.depth,
    required this.x,
    required this.y,
    required this.width,
    required this.meta,
    required this.status,
    required this.categoryColor,
    required this.expandable,
    required this.expanded,
  });

  final TreeNode node;
  final int depth;
  final double x;
  final double y;
  final double width;
  final String meta;
  final ThreadStatus status;
  final Color? categoryColor;
  final bool expandable;
  final bool expanded;
}

class _Link {
  const _Link(this.from, this.to);
  final Offset from;
  final Offset to;
}

class _Layout {
  const _Layout(this.nodes, this.links, this.size);
  final List<_Placed> nodes;
  final List<_Link> links;
  final Size size;
}

class TreeTab extends StatefulWidget {
  const TreeTab({super.key});

  @override
  State<TreeTab> createState() => _TreeTabState();
}

class _TreeTabState extends State<TreeTab> {
  _View _view = _View.topic;
  TimeMode _timeMode = TimeMode.upcoming;
  TimeFilter _filter = TimeFilter.all;
  String _query = '';

  final _searchController = TextEditingController();
  final _transform = TransformationController();

  /// Ids the user (or the default rule) has folded away.
  final Set<String> _collapsed = {};

  /// The (tree, view, mode) the collapse defaults were last computed for.
  String? _defaultsKey;

  /// The view the camera was last framed for — framing again on every rebuild would fight the
  /// user's own panning.
  String? _framedKey;

  /// "Now" is pinned per build of the layout, so urgency cannot shift mid-gesture.
  DateTime _now = DateTime.now();

  @override
  void dispose() {
    _searchController.dispose();
    _transform.dispose();
    super.dispose();
  }

  bool get _filtering => _filter != TimeFilter.all || _query.trim().isNotEmpty;

  void _applyDefaultCollapse(TreeNode displayed, String key) {
    _defaultsKey = key;
    _collapsed.clear();
    final top = displayed.children;
    if (_view == _View.topic) {
      // Categories expanded, topics collapsed — matches brain/mail_tree.html.
      for (final category in top) {
        for (final topic in category.children) {
          if (topic.children.isNotEmpty) _collapsed.add(topic.id);
        }
      }
    } else if (_timeMode == TimeMode.upcoming) {
      for (final bucket in top) {
        if (collapsedBuckets.contains(bucket.id)) _collapsed.add(bucket.id);
      }
    } else {
      // Newest month open with its newest day open; everything older folded away.
      for (var i = 0; i < top.length; i++) {
        final month = top[i];
        if (i == 0) {
          for (final day in month.children.skip(1)) {
            _collapsed.add(day.id);
          }
        } else {
          _collapsed.add(month.id);
        }
      }
    }
  }

  void _resetView(VoidCallback change) {
    setState(() {
      change();
      _defaultsKey = null; // recompute the fold defaults for the new view
      _framedKey = null; // and point the camera at the new root
      _now = DateTime.now();
    });
  }

  /// Open on the root at the left edge, vertically centred, zoomed out far enough to show it
  /// with the level beside it. The web can afford `scale(0.9)` on a wide canvas; 280px levels
  /// on a phone cannot, and starting at 1:1 leaves the first level off-screen.
  void _frameOnce(String key, Size viewport, _Layout layout) {
    if (_framedKey == key || viewport.isEmpty || layout.nodes.isEmpty) return;
    _framedKey = key;
    final root = layout.nodes.firstWhere(
      (p) => p.depth == 0,
      orElse: () => layout.nodes.first,
    );
    final scale = (viewport.width / (_levelWidth + _maxNodeWidth + 80)).clamp(0.35, 0.9);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _transform.value = Matrix4.identity()
        ..translateByDouble(
          16 - root.x * scale,
          viewport.height / 2 - root.y * scale,
          0,
          1,
        )
        ..scaleByDouble(scale, scale, 1, 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tree = state.tree;
    if (tree == null || tree.children.isEmpty) {
      return _NoTreeYet(offline: state.offline);
    }

    final palette = _Palette.of(context);
    final colors = categoryColors(tree);

    final base = _view == _View.topic ? tree : buildTimeTree(tree, _timeMode, _now);
    final displayed = _filtering
        ? (filterTree(base, (t) => matchesFilter(t, _filter, _query, _now)) ??
            base.copyWith(children: const []))
        : base;

    final key = '${identityHashCode(tree)}|${_view.name}|${_timeMode.name}';
    if (_defaultsKey != key) _applyDefaultCollapse(displayed, key);

    // Searching or filtering shows every match rather than making the user dig for it.
    final expanded = _filtering ? const <String>{} : _collapsed;
    final layout = _layout(displayed, expanded, colors);
    final shownThreads = collectThreads(displayed).length;

    return Column(
      children: [
        _Toolbar(
          palette: palette,
          view: _view,
          timeMode: _timeMode,
          filter: _filter,
          searchController: _searchController,
          onView: (v) => _resetView(() => _view = v),
          onTimeMode: (m) => _resetView(() => _timeMode = m),
          onFilter: (f) => setState(() => _filter = f),
          onQuery: (q) => setState(() => _query = q),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            _frameOnce(key, constraints.biggest, layout);
            return ColoredBox(
              color: palette.bg,
              child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    transformationController: _transform,
                    constrained: false,
                    minScale: 0.3,
                    maxScale: 2,
                    boundaryMargin: const EdgeInsets.all(600),
                    child: SizedBox(
                      width: layout.size.width,
                      height: layout.size.height,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(painter: _LinkPainter(layout.links, palette.link)),
                          ),
                          for (final placed in layout.nodes) ..._nodeWidgets(placed, palette),
                        ],
                      ),
                    ),
                  ),
                ),
                if (shownThreads == 0)
                  Center(
                    child: Text(
                      _filtering ? 'Nothing matches this filter.' : 'No threads yet.',
                      style: TextStyle(fontSize: 13, color: palette.muted),
                    ),
                  ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 8,
                  child: _Footer(palette: palette, root: tree, colors: colors),
                ),
                ],
              ),
            );
          }),
        ),
      ],
    );
  }

  List<Widget> _nodeWidgets(_Placed placed, _Palette palette) {
    return [
      Positioned(
        left: placed.x,
        top: placed.y - _nodeHeight / 2,
        width: placed.width,
        height: _nodeHeight,
        child: _NodeCard(
          placed: placed,
          palette: palette,
          faded: placed.node.isThread && isStale(placed.node, _now),
          isNewToday: placed.node.isThread && isNew(placed.node, _now),
          onTap: () {
            if (placed.node.isThread) {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ThreadScreen(
                    threadId: placed.node.id,
                    fallbackTitle: placed.node.name,
                  ),
                ),
              );
              return;
            }
            setState(() {
              if (!_collapsed.remove(placed.node.id)) _collapsed.add(placed.node.id);
            });
          },
        ),
      ),
      if (placed.expandable)
        Positioned(
          left: placed.x + placed.width + 4,
          top: placed.y - 10,
          width: 20,
          height: 20,
          child: GestureDetector(
            onTap: () => setState(() {
              if (!_collapsed.remove(placed.node.id)) _collapsed.add(placed.node.id);
            }),
            child: Container(
              decoration: BoxDecoration(
                color: palette.panel2,
                shape: BoxShape.circle,
                border: Border.all(color: palette.line),
              ),
              alignment: Alignment.center,
              child: Text(
                placed.expanded ? '‹' : '›',
                style: TextStyle(fontSize: 11, color: palette.muted, height: 1),
              ),
            ),
          ),
        ),
    ];
  }

  /// d3.tree's tidy layout for the shapes this tree actually has: leaves stack down the canvas,
  /// a parent centres on its children, and siblings sit one slot apart where different parents
  /// get two — the same `separation` d3 defaults to.
  _Layout _layout(TreeNode root, Set<String> collapsed, Map<String, Color> colors) {
    final placed = <_Placed>[];
    final links = <_Link>[];
    const step = _nodeHeight + _nodeGapY;
    double cursor = 0;
    String? previousParentId;

    double walk(TreeNode node, int depth, String? parentId, String? inheritedCategory) {
      final category = switch (node.type) {
        'mail_category' => node.name,
        'mail_thread' => node.category ?? inheritedCategory,
        'mail_topic' => inheritedCategory,
        _ => null,
      };
      final color = category == null ? null : colors[category];
      final status = node.isThread ? threadStatus(node, _now).status : ThreadStatus.none;
      final meta = node.isThread
          ? threadMeta(node, _now)
          : node.type == 'root'
              ? ''
              : () {
                  final n = collectThreads(node).length;
                  return '$n thread${n == 1 ? '' : 's'}';
                }();

      final showChildren = node.children.isNotEmpty && !collapsed.contains(node.id);
      double y;
      if (!showChildren) {
        if (previousParentId != null) {
          cursor += previousParentId == parentId ? step : step * 2;
        }
        previousParentId = parentId;
        y = cursor;
      } else {
        final childYs = [
          for (final child in node.children) walk(child, depth + 1, node.id, category),
        ];
        y = (childYs.first + childYs.last) / 2;
      }

      final x = depth * _levelWidth;
      final width = _measure(_truncate(node.name, 40), meta, color != null);
      placed.add(_Placed(
        node: node,
        depth: depth,
        x: x,
        y: y,
        width: width,
        meta: meta,
        status: status,
        categoryColor: color,
        expandable: node.children.isNotEmpty,
        expanded: showChildren,
      ));

      if (showChildren) {
        for (final child in node.children) {
          final target = placed.firstWhere((p) => identical(p.node, child));
          links.add(_Link(Offset(x + width, y), Offset(target.x, target.y)));
        }
      }
      return y;
    }

    walk(root, 0, null, null);

    // Shift into positive space and leave room for the toggle circles on the right.
    final minY = placed.map((p) => p.y).reduce(math.min) - _nodeHeight;
    final maxY = placed.map((p) => p.y).reduce(math.max) + _nodeHeight;
    final maxX = placed.map((p) => p.x + p.width).reduce(math.max);
    final shifted = <_Placed>[];
    for (final p in placed) {
      shifted.add(_Placed(
        node: p.node,
        depth: p.depth,
        x: p.x + _canvasMargin,
        y: p.y - minY + _canvasMargin,
        width: p.width,
        meta: p.meta,
        status: p.status,
        categoryColor: p.categoryColor,
        expandable: p.expandable,
        expanded: p.expanded,
      ));
    }
    final shiftedLinks = [
      for (final l in links)
        _Link(
          Offset(l.from.dx + _canvasMargin, l.from.dy - minY + _canvasMargin),
          Offset(l.to.dx + _canvasMargin, l.to.dy - minY + _canvasMargin),
        ),
    ];

    return _Layout(
      shifted,
      shiftedLinks,
      Size(maxX + _canvasMargin * 2 + 40, maxY - minY + _canvasMargin * 2),
    );
  }

  /// Node width follows the web's rule, but measured rather than guessed from character counts
  /// — the same string is a different number of pixels in Flutter than in a browser.
  double _measure(String title, String meta, bool hasDot) {
    double widthOf(String text, double size, FontWeight weight) {
      if (text.isEmpty) return 0;
      final painter = TextPainter(
        text: TextSpan(text: text, style: TextStyle(fontSize: size, fontWeight: weight)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      return painter.width;
    }

    final widest = math.max(widthOf(title, 13, FontWeight.w500), widthOf(meta, 11, FontWeight.w400));
    return (18 + (hasDot ? _dotPad : 0) + widest).clamp(_minNodeWidth, _maxNodeWidth);
  }
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.placed,
    required this.palette,
    required this.faded,
    required this.isNewToday,
    required this.onTap,
  });

  final _Placed placed;
  final _Palette palette;
  final bool faded;
  final bool isNewToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final node = placed.node;
    final urgent = statusColors[placed.status];
    final category = placed.categoryColor;

    // Category tints the fill, urgency owns the outline — two separate channels, so neither
    // colour has to mean two things.
    final fill = node.isThread && category != null
        ? Color.fromRGBO(
            (category.r * 255).round(),
            (category.g * 255).round(),
            (category.b * 255).round(),
            0.13,
          )
        : (node.type == 'time_bucket' ? palette.panel : palette.panel2);
    final stroke = urgent ??
        switch (node.type) {
          'mail_category' => category ?? palette.cat,
          'root' => palette.cat,
          'mail_topic' => category?.withValues(alpha: 0.55) ?? palette.topic,
          'mail_thread' => palette.thread,
          _ => palette.line,
        };
    final metaColor = switch (placed.status) {
      ThreadStatus.overdue => statusColors[ThreadStatus.overdue],
      ThreadStatus.soon => statusColors[ThreadStatus.soon],
      ThreadStatus.upcoming => statusColors[ThreadStatus.upcoming],
      _ => palette.muted,
    };

    return Opacity(
      opacity: faded ? 0.5 : 1,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: stroke, width: urgent != null ? 2.5 : 1.5),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (category != null)
                Positioned(
                  left: 10.5,
                  top: _nodeHeight / 2 - 4.5 - 1.5,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(color: category, shape: BoxShape.circle),
                  ),
                ),
              Padding(
                padding: EdgeInsets.only(left: category != null ? 26 : 14, right: 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _truncate(node.name, 40),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.2,
                        color: palette.ink,
                        fontWeight:
                            node.type == 'time_bucket' ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    if (placed.meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        placed.meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, height: 1.2, color: metaColor),
                      ),
                    ],
                  ],
                ),
              ),
              // Amber dot on threads the classifier wasn't sure about, so a wrong filing is
              // visible at a glance rather than only by opening every thread.
              if (node.needsReview)
                const Positioned(
                  left: 4,
                  top: 4,
                  child: _Dot(color: Color(0xFFF59E0B), size: 8),
                ),
              if (isNewToday)
                Positioned(
                  right: 5,
                  top: 5,
                  child: _Dot(color: palette.accent, size: 8, ring: palette.panel),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.size, this.ring});

  final Color color;
  final double size;
  final Color? ring;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: ring == null ? null : Border.all(color: ring!, width: 1.5),
        ),
      );
}

class _LinkPainter extends CustomPainter {
  const _LinkPainter(this.links, this.color);

  final List<_Link> links;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    for (final link in links) {
      final mx = (link.from.dx + link.to.dx) / 2;
      final path = Path()
        ..moveTo(link.from.dx, link.from.dy)
        ..cubicTo(mx, link.from.dy, mx, link.to.dy, link.to.dx, link.to.dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_LinkPainter old) => old.links != links || old.color != color;
}

/// The web's floating toolbar, laid out for a phone: each row scrolls sideways instead of
/// wrapping over the canvas.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.palette,
    required this.view,
    required this.timeMode,
    required this.filter,
    required this.searchController,
    required this.onView,
    required this.onTimeMode,
    required this.onFilter,
    required this.onQuery,
  });

  final _Palette palette;
  final _View view;
  final TimeMode timeMode;
  final TimeFilter filter;
  final TextEditingController searchController;
  final ValueChanged<_View> onView;
  final ValueChanged<TimeMode> onTimeMode;
  final ValueChanged<TimeFilter> onFilter;
  final ValueChanged<String> onQuery;

  static const _filters = <(TimeFilter, String)>[
    (TimeFilter.all, 'All'),
    (TimeFilter.overdue, 'Overdue'),
    (TimeFilter.week, 'Due in 7 days'),
    (TimeFilter.upcoming, 'Upcoming'),
    (TimeFilter.recent, 'Received this week'),
  ];

  static const _chipBorders = <TimeFilter, Color>{
    TimeFilter.overdue: Color(0xFFEF4444),
    TimeFilter.week: Color(0xFFF59E0B),
    TimeFilter.upcoming: Color(0xFF3B82F6),
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.bg,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        children: [
          Row(
            children: [
              _Segmented(
                palette: palette,
                options: const ['By topic', 'By time'],
                selected: view == _View.topic ? 0 : 1,
                onSelect: (i) => onView(i == 0 ? _View.topic : _View.time),
              ),
              if (view == _View.time) ...[
                const SizedBox(width: 8),
                _Segmented(
                  palette: palette,
                  options: const ['Upcoming', 'Received'],
                  selected: timeMode == TimeMode.upcoming ? 0 : 1,
                  onSelect: (i) =>
                      onTimeMode(i == 0 ? TimeMode.upcoming : TimeMode.received),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 28,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final (id, label) = _filters[i];
                final on = filter == id;
                return GestureDetector(
                  onTap: () => onFilter(id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on ? palette.panel2 : palette.panel,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: on ? (_chipBorders[id] ?? palette.accent) : palette.line,
                      ),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 12, color: on ? palette.ink : palette.muted),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
            child: TextField(
              controller: searchController,
              onChanged: onQuery,
              textAlignVertical: TextAlignVertical.center,
              style: TextStyle(fontSize: 12.5, color: palette.ink),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: palette.panel,
                hintText: 'Search threads…',
                hintStyle: TextStyle(fontSize: 12.5, color: palette.muted),
                prefixIcon: Icon(Icons.search, size: 17, color: palette.muted),
                prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(color: palette.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(color: palette.accent),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.palette,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final _Palette palette;
  final List<String> options;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++)
            GestureDetector(
              onTap: () => onSelect(i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: i == selected ? palette.panel2 : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  options[i],
                  style: TextStyle(
                    fontSize: 12.5,
                    color: i == selected ? palette.ink : palette.muted,
                    fontWeight: i == selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The web's legend and counts, on one line each.
class _Footer extends StatelessWidget {
  const _Footer({required this.palette, required this.root, required this.colors});

  final _Palette palette;
  final TreeNode root;
  final Map<String, Color> colors;

  @override
  Widget build(BuildContext context) {
    var categories = 0, topics = 0, threads = 0;
    void count(TreeNode n) {
      switch (n.type) {
        case 'mail_category':
          categories++;
        case 'mail_topic':
          topics++;
        case 'mail_thread':
          threads++;
      }
      n.children.forEach(count);
    }

    count(root);

    Widget item(Widget marker, String label) => Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              marker,
              const SizedBox(width: 5),
              Text(label, style: TextStyle(fontSize: 11.5, color: palette.muted)),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 18,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final status in [ThreadStatus.overdue, ThreadStatus.soon, ThreadStatus.upcoming])
                item(
                  Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: statusColors[status]!, width: 2),
                    ),
                  ),
                  statusLabels[status]!,
                ),
              item(_Dot(color: palette.accent, size: 8), 'New today'),
              for (final entry in colors.entries.take(6))
                item(_Dot(color: entry.value, size: 8), entry.key),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '$categories categories · $topics topics · $threads threads · pinch to zoom · drag to pan',
          style: TextStyle(fontSize: 11, color: palette.muted),
        ),
      ],
    );
  }
}

class _NoTreeYet extends StatelessWidget {
  const _NoTreeYet({required this.offline});

  final bool offline;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              offline ? Icons.cloud_off : Icons.account_tree_outlined,
              size: 44,
              color: scheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              offline ? 'Nothing saved yet' : 'No mail sorted yet',
              style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              offline
                  ? 'Connect once and the tree will be here next time, network or not.'
                  : 'Connect Gmail and run a sync — your mail gets grouped into categories '
                      'and topics automatically.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant, height: 1.45),
            ),
            if (!offline) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: () => context.read<AppState>().runSync(),
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('Sync mail now'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
