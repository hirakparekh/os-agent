import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Keeps Flutter's failure modes off the screen of someone reading their mail.
///
/// Three separate things can put a fault in front of a user, and each is handled here:
/// a widget that throws while building (Flutter's red box), an uncaught async error, and an
/// error reported through FlutterError. None of them should end the session; all of them still
/// reach the log, which is where a fault belongs.
///
/// Kept out of main() so it can be installed in a test as well as at startup.
void installFriendlyErrorScreens() {
  installErrorWidgetBuilder();

  FlutterError.onError = (details) {
    FlutterError.presentError(details); // still logged, still visible in `flutter run`
  };

  // A stray future — a plugin callback after dispose, a socket that closes late — must not
  // tear down the frame.
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught: $error\n$stack');
    return true;
  };
}

/// Just the red-box replacement, without touching the error *handlers*.
///
/// Separate from [installFriendlyErrorScreens] because a widget test needs this half and must
/// not have the other: `flutter_test` captures failures through FlutterError.onError and
/// PlatformDispatcher.onError, so overriding those inside a test leaves the framework waiting
/// on an error it will never be told about.
void installErrorWidgetBuilder() {
  ErrorWidget.builder = (details) => SomethingBroke(details: details);
}

/// What replaces the red screen.
///
/// Deliberately small and quiet: it occupies only the subtree that failed, so one broken card
/// leaves the rest of the screen usable. It names no exception — the log has that, and a stack
/// trace helps nobody holding a phone.
class SomethingBroke extends StatelessWidget {
  const SomethingBroke({super.key, required this.details});

  final FlutterErrorDetails details;

  /// No Theme lookup: this can be built before, outside, or instead of a MaterialApp.
  static const _ink = Color(0xFF9AA0A6);
  static const _faint = Color(0xFF80868B);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 22, color: _ink),
          SizedBox(height: 8),
          Text(
            "This part didn't load",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: _ink,
              decoration: TextDecoration.none,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Pull to refresh, or reopen the screen.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: _faint,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}
