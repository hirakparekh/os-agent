import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import 'chat.dart';
import 'home_tab.dart';
import 'tree.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: Text(const ['Home', 'Knowledge tree', 'Chat'][_tab]),
        // No overflow menu: everything it held is a card on the home screen, one tap away.
        actions: [
          if (state.refreshing)
            const Padding(
              padding: EdgeInsets.only(right: 18),
              child: Center(
                child: SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: state.refresh,
            ),
        ],
        bottom: _StatusStrip(state: state),
      ),
      body: IndexedStack(
        index: _tab,
        children: const [HomeTab(), TreeTab(), ChatTab()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_tree_outlined),
            selectedIcon: Icon(Icons.account_tree),
            label: 'Tree',
          ),
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: 'Chat',
          ),
        ],
      ),
    );
  }
}

/// The thin band under the app bar carrying whatever the user most needs to know right now:
/// a sync in progress, a lapsed Gmail grant, or that they are looking at cached data.
///
/// The reconnect prompt is styled as an action rather than an error on purpose. This project
/// requests a restricted Gmail scope and is unverified, so Google expires the grant weekly —
/// reconnecting is a routine part of using the app, not a fault to apologise for.
class _StatusStrip extends StatelessWidget implements PreferredSizeWidget {
  const _StatusStrip({required this.state});

  final AppState state;

  @override
  Size get preferredSize => Size.fromHeight(_visible ? 44 : 0);

  bool get _visible =>
      state.syncing || state.offline || state.mailStatus.needsReconnect || _neverConnected;

  /// Only once the server has actually answered. An unfetched status is not a disconnected
  /// mailbox: when the app cannot reach the backend at all, offering Connect just fails again.
  bool get _neverConnected =>
      state.mailStatus.checked &&
      !state.mailStatus.connected &&
      !state.mailStatus.needsReconnect;

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    if (state.syncing) {
      return _band(
        context,
        background: scheme.secondaryContainer,
        foreground: scheme.onSecondaryContainer,
        icon: null,
        text: state.syncStage ?? 'Syncing…',
        leading: const SizedBox(
          height: 14,
          width: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    // Checked before the Gmail bands on purpose: with no route to the server, "Gmail not
    // connected" is a guess, and the Connect it offers cannot succeed.
    if (state.offline) {
      return _band(
        context,
        background: scheme.surfaceContainerHighest,
        foreground: scheme.onSurfaceVariant,
        icon: Icons.cloud_off,
        text: 'Offline — showing saved data',
      );
    }

    if (state.mailStatus.needsReconnect || _neverConnected) {
      final lapsed = state.mailStatus.needsReconnect;
      return _band(
        context,
        background: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
        icon: Icons.link_off,
        text: lapsed ? 'Gmail needs reconnecting' : 'Gmail not connected',
        action: TextButton(
          onPressed: () => _connectGmail(context),
          child: const Text('Connect'),
        ),
      );
    }

    return _band(
      context,
      background: scheme.surfaceContainerHighest,
      foreground: scheme.onSurfaceVariant,
      icon: Icons.cloud_off,
      text: 'Offline — showing saved data',
    );
  }

  Widget _band(
    BuildContext context, {
    required Color background,
    required Color foreground,
    required IconData? icon,
    required String text,
    Widget? leading,
    Widget? action,
  }) {
    return Container(
      height: 44,
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.only(left: 16, right: 8),
      child: Row(
        children: [
          if (leading != null) leading,
          if (icon != null) Icon(icon, size: 17, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: foreground, fontSize: 13.5),
            ),
          ),
          if (action != null) action,
        ],
      ),
    );
  }
}

/// Opens Google consent in the user's own browser.
///
/// The server completes the code exchange at its own callback, so nothing needs to redirect
/// back into the app — we simply poll until the status flips. That is why there is no custom
/// URL scheme or intent filter anywhere in this project.
Future<void> _connectGmail(BuildContext context) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final url = await state.api.beginGmailConnect();
    final launched = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
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
    await _pollUntilConnected(state);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not start sign-in: $e')));
  }
}

/// Polls the mailbox status while the user completes consent elsewhere. Gives up after two
/// minutes so a user who abandons the flow does not leave a poller running forever.
Future<void> _pollUntilConnected(AppState state) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await Future<void>.delayed(const Duration(seconds: 3));
    await state.refreshMailStatus();
    if (state.mailStatus.connected) {
      await state.refresh();
      return;
    }
  }
}

