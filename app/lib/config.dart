/// Where the two backends live.
///
/// The project runs two FastAPI services: `console` (accounts, login, chat sessions) and
/// `brain` (mail ingest, the knowledge tree, the feeds). A hosted deployment puts both behind
/// one origin — `/api/*` routed to brain, everything else to console — so in production both
/// of these are the same value. They are separate here only because local development runs
/// them on two ports.
///
/// Local development defaults to localhost, reached over USB with
/// `adb reverse tcp:8000 tcp:8000 && adb reverse tcp:8080 tcp:8080` — the same on the emulator
/// and a physical phone. It also lets Google's OAuth redirect to localhost:8080 complete on the
/// phone itself. A device on the same wifi can use the host's LAN address instead, which is why
/// these are overridable at runtime rather than baked in.
class ApiConfig {
  const ApiConfig({required this.consoleBase, required this.brainBase});

  final String consoleBase;
  final String brainBase;

  /// Defaults for local development over `adb reverse`.
  static const ApiConfig localDev = ApiConfig(
    consoleBase: 'http://localhost:8000',
    brainBase: 'http://localhost:8080',
  );

  /// What the user typed in Server settings. Local dev runs two ports, so an address on :8000
  /// keeps its host and pairs it with :8080 for brain; anything else is one hosted origin.
  factory ApiConfig.parse(String address) {
    var value = address.trim();
    if (!value.contains('://')) value = 'http://$value';
    final uri = Uri.parse(value);
    if (uri.hasPort && uri.port == 8000) {
      final host = '${uri.scheme}://${uri.host}';
      return ApiConfig(consoleBase: '$host:8000', brainBase: '$host:8080');
    }
    return ApiConfig.hosted(value);
  }

  /// A hosted deployment: one origin, Caddy routing `/api/*` to brain.
  factory ApiConfig.hosted(String origin) {
    final trimmed = origin.endsWith('/') ? origin.substring(0, origin.length - 1) : origin;
    return ApiConfig(consoleBase: trimmed, brainBase: trimmed);
  }

  Map<String, String> toJson() => {'console': consoleBase, 'brain': brainBase};

  factory ApiConfig.fromJson(Map<String, dynamic> json) => ApiConfig(
        consoleBase: json['console'] as String? ?? localDev.consoleBase,
        brainBase: json['brain'] as String? ?? localDev.brainBase,
      );
}
