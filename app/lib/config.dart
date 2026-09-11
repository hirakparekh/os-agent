/// Where the two backends live.
///
/// The project runs two FastAPI services: `console` (accounts, login, chat sessions) and
/// `brain` (mail ingest, the knowledge tree, the feeds). A hosted deployment puts both behind
/// one origin — `/api/*` routed to brain, everything else to console — so in production both
/// of these are the same value. They are separate here only because local development runs
/// them on two ports.
///
/// 10.0.2.2 is how the Android emulator reaches the host machine's localhost. A physical
/// device on the same wifi needs the host's LAN address instead, which is why these are
/// overridable at runtime rather than baked in.
class ApiConfig {
  const ApiConfig({required this.consoleBase, required this.brainBase});

  final String consoleBase;
  final String brainBase;

  /// Emulator-friendly defaults for local development.
  static const ApiConfig localDev = ApiConfig(
    consoleBase: 'http://10.0.2.2:8000',
    brainBase: 'http://10.0.2.2:8080',
  );

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
