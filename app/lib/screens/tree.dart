import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import 'thread.dart';

/// The knowledge tree as nested expandable lists.
///
/// Deliberately not the web console's force-directed mind map. That visualisation is the
/// largest single piece of work in a port and the worst fit for a small screen; nested lists
/// carry the same structure, are navigable with a thumb, and render from the cached payload
/// with no network.
class TreeTab extends StatelessWidget {
  const TreeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tree = state.tree;

    if (tree == null) {
      return _NoTreeYet(offline: state.offline);
    }

    final categories = tree.children;
    if (categories.isEmpty) {
      return _NoTreeYet(offline: state.offline);
    }

    return RefreshIndicator(
      onRefresh: state.refresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
        itemCount: categories.length,
        itemBuilder: (_, i) => _CategoryTile(node: categories[i]),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.node});

  final TreeNode node;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final threadCount = node.threads.length;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          node.name,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        subtitle: Text(
          threadCount == 1 ? '1 thread' : '$threadCount threads',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        children: node.children.map((child) {
          if (child.isThread) return _ThreadTile(node: child, indent: 16);
          return _TopicTile(node: child);
        }).toList(growable: false),
      ),
    );
  }
}

class _TopicTile extends StatelessWidget {
  const _TopicTile({required this.node});

  final TreeNode node;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExpansionTile(
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.only(left: 28, right: 16),
      title: Text(node.name, style: const TextStyle(fontSize: 14.5)),
      subtitle: Text(
        '${node.threads.length} threads',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      children: node.children
          .map((child) => _ThreadTile(node: child, indent: 44))
          .toList(growable: false),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({required this.node, required this.indent});

  final TreeNode node;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.only(left: indent, right: 16),
      leading: Icon(
        node.channel == 'slack' ? Icons.tag : Icons.mail_outline,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
      title: Text(
        node.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: node.summary == null || node.summary!.isEmpty
          ? null
          : Text(
              node.summary!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
      trailing: node.needsReview
          ? Tooltip(
              message: 'Filed with low confidence',
              child: Icon(Icons.help_outline, size: 17, color: scheme.tertiary),
            )
          : null,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ThreadScreen(threadId: node.id, fallbackTitle: node.name),
        ),
      ),
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
