import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'error_fallback.dart';

import 'api.dart';
import 'app_state.dart';
import 'cache.dart';
import 'config.dart';
import 'screens/home.dart';
import 'screens/login.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // A widget that throws, or a stray async error, must not put a red screen in front of
  // someone reading their mail. Failures still reach the log; only what is shown changes.
  installFriendlyErrorScreens();

  final cache = await Cache.open();
  final api = Api(config: ApiConfig.localDev);
  final state = AppState(api: api, cache: cache);
  await state.boot();
  runApp(AgentOsApp(state: state));
}

class AgentOsApp extends StatelessWidget {
  const AgentOsApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        title: 'Agent OS',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: const _Root(),
      ),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E6265),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final stage = context.select<AppState, AuthStage>((s) => s.stage);
    switch (stage) {
      case AuthStage.starting:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case AuthStage.signedOut:
        return const LoginScreen();
      case AuthStage.signedIn:
        return const HomeScreen();
    }
  }
}
