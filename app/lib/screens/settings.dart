import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../config.dart';
import 'rules.dart';

/// Connections, processing options, and the way out.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().loadSettings());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const _SectionLabel('Connections'),
          _ConnectionTile(
            icon: Icons.mail_outline,
            name: 'Gmail',
            connected: state.mailStatus.connected,
            detail: state.mailStatus.connected
                ? (state.mailStatus.email ?? 'Connected')
                : state.mailStatus.needsReconnect
                    ? 'Access expired — reconnect to keep syncing'
                    : 'Not connected',
            warn: state.mailStatus.needsReconnect,
            onConnect: () => _connect(context, state.api.beginGmailConnect, isMail: true),
            onDisconnect: state.disconnectGmail,
          ),
          _ConnectionTile(
            icon: Icons.event_outlined,
            name: 'Google Calendar',
            connected: state.calendarStatus.connected,
            detail: state.calendarStatus.connected
                ? 'Deadlines can be added to your calendar'
                : 'Not connected',
            warn: state.calendarStatus.needsReconnect,
            onConnect: () => _connect(context, state.api.beginCalendarConnect, isMail: false),
            onDisconnect: state.disconnectCalendar,
          ),
          const _Explainer(
            'Google requires this app to be reconnected about once a week. That is a limit of '
            'unverified apps, not a fault — reconnect before anything important.',
          ),

          const _SectionLabel('Processing'),
          SwitchListTile(
            value: state.brainSettings.offlineMode,
            onChanged: state.offline ? null : state.setOfflineMode,
            title: const Text('Skip AI processing'),
            subtitle: const Text(
              'Sorts mail with keywords only. Faster and free, but summaries become the raw '
              'message text. Urgent flags and to-dos are unaffected.',
            ),
            isThreeLine: true,
          ),
          ListTile(
            leading: const Icon(Icons.rule),
            title: const Text('Automation rules'),
            subtitle: const Text('Get told when certain mail arrives'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RulesScreen()),
            ),
          ),
          SwitchListTile(
            value: state.notificationsEnabled,
            onChanged: state.setNotificationsEnabled,
            title: const Text('Notify me about urgent mail'),
            subtitle: const Text('Checks periodically while the app is open'),
          ),

          const _SectionLabel('App'),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server'),
            subtitle: Text(state.api.config.consoleBase),
            onTap: () => _editServer(context),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            subtitle: const Text('Clears saved mail from this device'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Sign out?'),
                  content: const Text(
                    'Saved mail is removed from this device. Your Gmail connection stays on the '
                    'server, so you will not need to reconnect it.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              );
              if (ok == true) await state.signOut();
            },
          ),
        ],
      ),
    );
  }
}

/// Open Google consent, then poll until the server reports the grant landed.
Future<void> _connect(
  BuildContext context,
  Future<String> Function() begin, {
  required bool isMail,
}) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final url = await begin();
    final launched = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!launched) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open a browser for sign-in.')),
      );
      return;
    }
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Finish in your browser, then come back — this updates on its own.'),
        duration: Duration(seconds: 6),
      ),
    );
    // Poll only the service being connected — waiting on both would keep polling for the
    // full two minutes whenever the other one happens to be disconnected.
    for (var attempt = 0; attempt < 40; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (isMail) {
        await state.refreshMailStatus();
        if (state.mailStatus.connected) break;
      } else {
        await state.loadSettings();
        if (state.calendarStatus.connected) break;
      }
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not start sign-in: $e')));
  }
}

Future<void> _editServer(BuildContext context) {
  final state = context.read<AppState>();
  return showDialog<void>(
    context: context,
    builder: (_) => _ServerDialog(state: state),
  );
}

/// Owns its controller so it is disposed with the route, after the dialog's exit animation
/// has stopped building the TextField (same bug as the login screen's server sheet).
class _ServerDialog extends StatefulWidget {
  const _ServerDialog({required this.state});

  final AppState state;

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  late final _controller = TextEditingController(text: widget.state.api.config.consoleBase);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Server address'),
      content: TextField(
        controller: _controller,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final value = _controller.text.trim();
            if (value.isNotEmpty) widget.state.setConfig(ApiConfig.parse(value));
            Navigator.of(context).pop();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({
    required this.icon,
    required this.name,
    required this.connected,
    required this.detail,
    required this.warn,
    required this.onConnect,
    required this.onDisconnect,
  });

  final IconData icon;
  final String name;
  final bool connected;
  final String detail;
  final bool warn;
  final VoidCallback onConnect;
  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: warn ? scheme.tertiary : null),
      title: Text(name),
      subtitle: Text(
        detail,
        style: TextStyle(color: warn ? scheme.tertiary : scheme.onSurfaceVariant),
      ),
      trailing: connected
          ? TextButton(onPressed: onDisconnect, child: const Text('Disconnect'))
          : FilledButton.tonal(onPressed: onConnect, child: const Text('Connect')),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: scheme.primary,
        ),
      ),
    );
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.45),
      ),
    );
  }
}
