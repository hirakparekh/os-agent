import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../voice.dart';

/// Ask questions over the mail tree.
///
/// Conversations live on the console backend, which persists them and forwards the question to
/// brain. Past conversations read fine offline from cache; asking a new one does not, and says
/// so rather than failing silently.
class ChatTab extends StatefulWidget {
  const ChatTab({super.key});

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<AppState>();
      state.loadSessions();
      state.loadVoiceOptions();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.openSession != null) {
      return _Conversation(session: state.openSession!);
    }
    return _SessionList(sessions: state.sessions, offline: state.offline);
  }
}

class _SessionList extends StatelessWidget {
  const _SessionList({required this.sessions, required this.offline});

  final List<ChatSession> sessions;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: sessions.isEmpty
          ? _EmptyChats(offline: offline)
          : RefreshIndicator(
              onRefresh: state.loadSessions,
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: sessions.length,
                separatorBuilder: (_, __) => Divider(height: 1, color: scheme.outlineVariant),
                itemBuilder: (_, i) {
                  final session = sessions[i];
                  return Dismissible(
                    key: ValueKey(session.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      color: scheme.errorContainer,
                      child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
                    ),
                    onDismissed: (_) => state.deleteChat(session.id),
                    child: ListTile(
                      title: Text(
                        session.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15),
                      ),
                      subtitle: session.updatedAt == null
                          ? null
                          : Text(
                              _when(session.updatedAt!),
                              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                            ),
                      trailing: Icon(Icons.chevron_right, color: scheme.outline),
                      onTap: () => state.openChat(session.id),
                    ),
                  );
                },
              ),
            ),
      floatingActionButton: offline
          ? null
          : FloatingActionButton.extended(
              onPressed: state.startChat,
              icon: const Icon(Icons.add),
              label: const Text('Ask'),
            ),
    );
  }

  static String _when(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }
}

class _EmptyChats extends StatelessWidget {
  const _EmptyChats({required this.offline});

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
              offline ? Icons.cloud_off : Icons.forum_outlined,
              size: 44,
              color: scheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              offline ? 'No saved conversations' : 'Ask about your mail',
              style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              offline
                  ? 'Conversations you have already had will be readable here without a '
                      'connection. Asking something new needs the network.'
                  : '"What deadlines do I have this week?" · "Did anything come in about '
                      'placements?" · "What did I miss?"',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _Conversation extends StatefulWidget {
  const _Conversation({required this.session});

  final ChatSession session;

  @override
  State<_Conversation> createState() => _ConversationState();
}

class _ConversationState extends State<_Conversation> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final Voice _voice = Voice();
  String? _lastSpoken;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _voice.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final state = context.read<AppState>();
    _scrollToEnd();
    await state.ask(text);
    _scrollToEnd();
    _maybeSpeakLatest(state);
  }

  /// Read a new answer aloud when the user has asked for that — once per answer, never
  /// re-reading one already spoken.
  void _maybeSpeakLatest(AppState state) {
    if (!state.readAloud || !state.voice.configured) return;
    final messages = state.openSession?.messages ?? const [];
    if (messages.isEmpty) return;
    final last = messages.last;
    if (last.isUser || last.content == _lastSpoken) return;
    _lastSpoken = last.content;
    _voice.speak(state, last.content);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final session = state.openSession ?? widget.session;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: state.closeChat,
        ),
        title: Text(session.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (state.voice.configured)
            IconButton(
              tooltip: state.readAloud ? 'Stop reading answers aloud' : 'Read answers aloud',
              icon: Icon(state.readAloud ? Icons.volume_up : Icons.volume_off),
              onPressed: () => state.setReadAloud(!state.readAloud),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: session.messages.isEmpty
                ? const _AskSomething()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
                    itemCount: session.messages.length,
                    itemBuilder: (_, i) => _Bubble(
                      message: session.messages[i],
                      voice: _voice,
                      canSpeak: state.voice.configured,
                    ),
                  ),
          ),
          if (state.chatError != null)
            Container(
              width: double.infinity,
              color: scheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                state.chatError!,
                style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
              ),
            ),
          _Composer(
            controller: _input,
            voice: _voice,
            sending: state.sending,
            offline: state.offline,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

class _AskSomething extends StatelessWidget {
  const _AskSomething();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          'Ask anything about your mail — deadlines, who wrote about what, or what you missed '
          'while you were away.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant, height: 1.55),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.voice, required this.canSpeak});

  final ChatMessage message;
  final Voice voice;
  final bool canSpeak;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.isUser;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 14),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              message.content,
              style: TextStyle(
                fontSize: 14.5,
                height: 1.45,
                color: isUser ? scheme.onPrimaryContainer : scheme.onSurface,
              ),
            ),
            if (message.pending) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 11,
                    width: 11,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Reading your mail…',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ],
            if (!isUser && canSpeak && !message.pending) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: () => voice.speak(context.read<AppState>(), message.content),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.volume_up_outlined, size: 15, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 5),
                      Text(
                        'Listen',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.voice,
    required this.sending,
    required this.offline,
    required this.onSend,
  });

  final TextEditingController controller;
  final Voice voice;
  final bool sending;
  final bool offline;
  final VoidCallback onSend;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _recording = false;
  bool _transcribing = false;

  /// Hold to record, release to transcribe.
  ///
  /// The transcript goes into the field rather than being sent: speech recognition is wrong
  /// often enough that auto-sending would mean firing a misheard question at a slow model and
  /// waiting a minute to discover it.
  Future<void> _startRecording() async {
    if (!await widget.voice.startRecording()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission is needed to speak a question.')),
      );
      return;
    }
    setState(() => _recording = true);
  }

  Future<void> _stopRecording({required bool keep}) async {
    if (!_recording) return;
    setState(() {
      _recording = false;
      _transcribing = keep;
    });
    final state = context.read<AppState>();
    final text = await widget.voice.stopAndTranscribe(state, keep: keep);
    if (!mounted) return;
    setState(() => _transcribing = false);
    if (text == null || text.isEmpty) return;
    widget.controller.text = widget.controller.text.isEmpty
        ? text
        : '${widget.controller.text} $text';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = context.watch<AppState>();
    final busy = widget.sending || _transcribing;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: widget.controller,
                enabled: !busy,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: _recording
                      ? 'Listening — release to stop'
                      : _transcribing
                          ? 'Transcribing…'
                          : widget.offline
                              ? 'Asking needs a connection'
                              : 'Ask about your mail',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ),
            if (state.voice.configured && !widget.offline) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onLongPressStart: (_) => _startRecording(),
                onLongPressEnd: (_) => _stopRecording(keep: true),
                onLongPressCancel: () => _stopRecording(keep: false),
                // Deliberately not an IconButton: this responds to press-and-hold, and an
                // IconButton with a null onPressed renders greyed out as though unavailable.
                child: Tooltip(
                  message: 'Hold to speak',
                  child: Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _recording ? scheme.errorContainer : Colors.transparent,
                    ),
                    child: Icon(
                      _recording ? Icons.mic : Icons.mic_none,
                      color: busy
                          ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
                          : _recording
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 2),
            IconButton.filled(
              onPressed: busy || widget.offline ? null : widget.onSend,
              icon: widget.sending
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ),
    );
  }
}
