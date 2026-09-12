import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';

/// "About you" — free-form key/value facts the assistant can use.
///
/// A port of the console's Profile page. These live on the server, not the device, because the
/// place they matter most is attachment scanning at ingest, which runs headless: "is my name on
/// this shortlist?" is only answerable if the server knows your name. Identity-ish keys (Name,
/// Roll no, Neo ID, …) are promoted to attachment identifiers by `brain/profile.py`; everything
/// else is still given to the model when it answers questions about your mail.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _keyController = TextEditingController();
  final _valueController = TextEditingController();
  final _valueFocus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().loadProfile());
  }

  @override
  void dispose() {
    _keyController.dispose();
    _valueController.dispose();
    _valueFocus.dispose();
    super.dispose();
  }

  Future<void> _save(List<ProfileDetail> next) async {
    final message = await context.read<AppState>().saveProfile(next);
    if (!mounted) return;
    setState(() => _error = message);
    final rescanned = context.read<AppState>().profile.rescanned;
    if (message == null && rescanned > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            rescanned == 1
                ? 'Re-read 1 attachment with your new details.'
                : 'Re-read $rescanned attachments with your new details.',
          ),
        ),
      );
    }
  }

  Future<void> _add() async {
    final key = _keyController.text.trim();
    final value = _valueController.text.trim();
    if (key.isEmpty || value.isEmpty) return;
    final details = [
      ...context.read<AppState>().profile.details,
      ProfileDetail(key: key, value: value),
    ];
    _keyController.clear();
    _valueController.clear();
    await _save(details);
  }

  Future<void> _remove(int index) async {
    final details = [...context.read<AppState>().profile.details]..removeAt(index);
    await _save(details);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final profile = state.profile;

    return Scaffold(
      appBar: AppBar(
        title: const Text('About you'),
        actions: [
          if (state.profileSaving)
            const Padding(
              padding: EdgeInsets.only(right: 20),
              child: Center(
                child: SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 40),
        children: [
          Text(
            'Details you want the assistant to know when it answers — your name, roll number, '
            'timezone, whatever is useful. Saved to your account, not this phone.',
            style: TextStyle(fontSize: 13.5, height: 1.45, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          if (_error != null) ...[
            _Banner(text: _error!, tone: scheme.errorContainer, ink: scheme.onErrorContainer),
            const SizedBox(height: 14),
          ],
          if (profile.details.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Nothing added yet — try "Name", "Roll no" or "Timezone" below.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
              ),
            )
          else
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < profile.details.length; i++) ...[
                    if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
                    _DetailRow(
                      detail: profile.details[i],
                      isIdentifier: profile.identifiers.contains(profile.details[i].value.trim()),
                      onRemove: state.profileSaving ? null : () => _remove(i),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 18),
          _AddCard(
            keyController: _keyController,
            valueController: _valueController,
            valueFocus: _valueFocus,
            onAdd: state.profileSaving ? null : _add,
          ),
          const SizedBox(height: 22),
          _IdentifierSummary(identifiers: profile.identifiers),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.detail, required this.isIdentifier, required this.onRemove});

  final ProfileDetail detail;
  final bool isIdentifier;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Row(
        children: [
          Flexible(
            child: Text(
              detail.key,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          if (isIdentifier) ...[
            const SizedBox(width: 8),
            // Marks the rows that do more than inform the chat: these are searched for inside
            // spreadsheets and PDFs attached to your mail.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'searched in attachments',
                style: TextStyle(fontSize: 10.5, color: scheme.onSecondaryContainer),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        detail.value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
      ),
      trailing: IconButton(
        onPressed: onRemove,
        icon: const Icon(Icons.delete_outline, size: 20),
        tooltip: 'Remove ${detail.key}',
      ),
    );
  }
}

class _AddCard extends StatelessWidget {
  const _AddCard({
    required this.keyController,
    required this.valueController,
    required this.valueFocus,
    required this.onAdd,
  });

  final TextEditingController keyController;
  final TextEditingController valueController;
  final FocusNode valueFocus;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant, style: BorderStyle.solid),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: keyController,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => valueFocus.requestFocus(),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Label',
              hintText: 'Roll no',
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: valueController,
            focusNode: valueFocus,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onAdd?.call(),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Detail',
              hintText: '23BCE1234',
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add detail'),
          ),
        ],
      ),
    );
  }
}

class _IdentifierSummary extends StatelessWidget {
  const _IdentifierSummary({required this.identifiers});

  final List<String> identifiers;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.find_in_page_outlined, size: 17, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                'Looked for inside attachments',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            identifiers.isEmpty
                ? 'Add a Name, Roll no or Neo ID and the assistant will check whether '
                    'spreadsheets and PDFs attached to your mail mention you.'
                : identifiers.join(', '),
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: identifiers.isEmpty ? scheme.onSurfaceVariant : scheme.onSurface,
              fontWeight: identifiers.isEmpty ? FontWeight.w400 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.tone, required this.ink});

  final String text;
  final Color tone;
  final Color ink;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: tone, borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: TextStyle(fontSize: 13, color: ink)),
      );
}
