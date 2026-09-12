import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';

/// Threads the classifier wasn't sure about.
///
/// Worth doing on a phone specifically because a correction teaches the classifier — this is
/// the one screen where a spare minute in a queue makes the system permanently better, rather
/// than just clearing a list.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().loadReview());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Needs a decision')),
      body: state.reviewLoading && state.review.items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : state.review.items.isEmpty
              ? _AllClear(offline: state.offline)
              : RefreshIndicator(
                  onRefresh: state.loadReview,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 32),
                    itemCount: state.review.items.length + 1,
                    itemBuilder: (_, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Text(
                            'These were filed with low confidence. Correcting one also teaches '
                            'the classifier, so the same mistake is less likely next time.',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        );
                      }
                      return _ReviewCard(
                        item: state.review.items[i - 1],
                        categories: state.review.categories,
                      );
                    },
                  ),
                ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.item, required this.categories});

  final ReviewItem item;
  final List<String> categories;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.name,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, height: 1.3),
            ),
            if (item.summary != null && item.summary!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                item.summary!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant, height: 1.4),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.folder_outlined, size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Filed under ${item.category ?? 'nothing'}'
                    '${item.topic == null ? '' : ' › ${item.topic}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            if (item.disputed) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'The model said "${item.llmCategory}", the keyword scorer said '
                  '"${item.keywordCategory}".',
                  style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer, height: 1.4),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () => _pickCategory(context, item, categories),
                icon: const Icon(Icons.drive_file_move_outline, size: 18),
                label: const Text('Move'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _pickCategory(
  BuildContext context,
  ReviewItem item,
  List<String> categories,
) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);

  final chosen = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Move to',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: categories
                  .map((c) => ListTile(
                        title: Text(c),
                        // Picking the current category is a real choice, not a no-op: it says
                        // the filing was right, which clears the flag and teaches the scorer.
                        subtitle: c == item.category
                            ? const Text('Keep it here — confirms the filing')
                            : null,
                        trailing: c == item.category ? const Icon(Icons.check, size: 18) : null,
                        onTap: () => Navigator.of(sheetContext).pop(c),
                      ))
                  .toList(growable: false),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (chosen == null) return;

  // Choosing the category it is already in used to be dropped here, which made the ticked row
  // — the one the sheet opens on — do nothing at all. It is a confirmation: the server clears
  // the low-confidence flag and learns from it exactly as it does for a correction.
  final keeping = chosen == item.category;
  final ok = await state.reclassify(item.id, chosen);
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        ok
            ? (keeping ? 'Kept in $chosen' : 'Moved to $chosen')
            : 'Could not save it — this needs a connection.',
      ),
    ),
  );
}

class _AllClear extends StatelessWidget {
  const _AllClear({required this.offline});

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
              offline ? Icons.cloud_off : Icons.inbox_outlined,
              size: 42,
              color: scheme.outline,
            ),
            const SizedBox(height: 14),
            Text(
              offline ? 'Needs a connection' : 'Nothing to review',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              offline
                  ? 'The review queue is read fresh from the server rather than from saved data, '
                      'because filing changes as mail arrives.'
                  : 'Everything that has come in was filed confidently.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
