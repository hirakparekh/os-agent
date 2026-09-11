import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// Rules written in plain English: "notify me on Slack when a placements email arrives".
///
/// The model is called once, when the rule is created. Matching it against future mail is
/// ordinary code — so rules keep working even with AI processing switched off.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().loadRules());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Automation rules')),
      body: state.rules.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.rule, size: 42, color: scheme.outline),
                    const SizedBox(height: 14),
                    const Text(
                      'No rules yet',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Describe what you want in your own words, and it will run on every '
                      'message from then on.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
              itemCount: state.rules.length,
              itemBuilder: (_, i) {
                final rule = state.rules[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    title: Text(rule.text, style: const TextStyle(fontSize: 14.5, height: 1.35)),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        [
                          if (rule.triggerCategory != null) 'when ${rule.triggerCategory} mail arrives',
                          if (rule.urgentOnly) 'urgent only',
                        ].join(' · '),
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete rule',
                      onPressed: () => state.removeRule(rule.id),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: state.offline
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addRule(context),
              icon: const Icon(Icons.add),
              label: const Text('New rule'),
            ),
    );
  }
}

Future<void> _addRule(BuildContext context) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);

  final text = await showDialog<String>(
    context: context,
    builder: (_) => const _NewRuleDialog(),
  );

  if (text == null || text.isEmpty) return;
  final error = await state.addRule(text);
  if (error != null) messenger.showSnackBar(SnackBar(content: Text(error)));
}

/// Owns its controller so it is disposed with the route, after the dialog's exit animation
/// has stopped building the TextField (same bug as the login screen's server sheet).
class _NewRuleDialog extends StatefulWidget {
  const _NewRuleDialog();

  @override
  State<_NewRuleDialog> createState() => _NewRuleDialogState();
}

class _NewRuleDialogState extends State<_NewRuleDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New rule'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Notify me on Slack when a placements email arrives',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Written once, then matched in plain code — so it keeps working even with AI '
            'processing off.',
            style: TextStyle(fontSize: 12, height: 1.4),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
