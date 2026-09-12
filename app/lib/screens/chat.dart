import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../answer_text.dart';
import '../app_state.dart';
import '../models.dart';
import '../voice.dart';

/// Ask questions over the mail tree.
///
/// Laid out the way a modern assistant app is: the answer is the page, not a speech bubble.
/// Only the person's own turns are bubbled — they are short and benefit from being visually
/// attributable — while the model's reply runs full width as ordinary prose, because it is
/// often several paragraphs and a bubble makes long text harder to read, not easier.
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
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                itemCount: sessions.length,
                itemBuilder: (_, i) {
                  final session = sessions[i];
                  return Dismissible(
                    key: ValueKey(session.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.only(right: 20),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
                    ),
                    onDismissed: (_) => state.deleteChat(session.id),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => state.openChat(session.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      session.displayTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 15.5,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    if (session.updatedAt != null) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        _when(session.updatedAt!),
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right, size: 20, color: scheme.outline),
                            ],
                          ),
                        ),
                      ),
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
              label: const Text('New chat'),
            ),
    );
  }

  static String _when(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'just now';
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
                  : 'Deadlines, who wrote about what, or what you missed while you were away.',
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
                ? _AskSomething(onPick: (q) => _input.text = q)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
                    itemCount: session.messages.length,
                    itemBuilder: (_, i) => _Turn(
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

/// The opening screen of a new conversation: a prompt and a few things worth asking, which fill
/// the field rather than sending, so the question can be edited before it costs a model call.
class _AskSomething extends StatelessWidget {
  const _AskSomething({required this.onPick});

  final ValueChanged<String> onPick;

  static const _suggestions = [
    'What deadlines do I have this week?',
    'What did I miss while I was away?',
    'Did anything come in about placements?',
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 60, 24, 24),
      children: [
        Text(
          'What do you want to know?',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Answers come from the mail already sorted on this account.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13.5, height: 1.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 26),
        for (final suggestion in _suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => onPick(suggestion),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  child: Row(
                    children: [
                      Icon(Icons.north_east, size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          suggestion,
                          style: const TextStyle(fontSize: 14, height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One turn. The person's is a bubble; the assistant's is the page.
class _Turn extends StatelessWidget {
  const _Turn({required this.message, required this.voice, required this.canSpeak});

  final ChatMessage message;
  final Voice voice;
  final bool canSpeak;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
          margin: const EdgeInsets.only(bottom: 20, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomLeft: Radius.circular(20),
              bottomRight: Radius.circular(6),
            ),
          ),
          child: Text(
            message.content,
            style: TextStyle(fontSize: 15, height: 1.4, color: scheme.onSurface),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.pending)
            _Thinking(scheme: scheme)
          else
            AnswerText(
              text: message.content,
              style: TextStyle(fontSize: 15.5, height: 1.6, color: scheme.onSurface),
            ),
          if (!message.pending) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                _TurnAction(
                  icon: Icons.copy_outlined,
                  label: 'Copy',
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: message.content));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
                    );
                  },
                ),
                if (canSpeak)
                  _TurnAction(
                    icon: Icons.volume_up_outlined,
                    label: 'Listen',
                    onTap: () => voice.speak(context.read<AppState>(), message.content),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 13,
          width: 13,
          child: CircularProgressIndicator(strokeWidth: 1.8, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 10),
        Text(
          'Reading your mail…',
          style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _TurnAction extends StatelessWidget {
  const _TurnAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
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
    widget.controller.text =
        widget.controller.text.isEmpty ? text : '${widget.controller.text} $text';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = context.watch<AppState>();
    final busy = widget.sending || _transcribing;

    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
          ),
          padding: const EdgeInsets.fromLTRB(18, 4, 6, 4),
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
                  style: const TextStyle(fontSize: 15, height: 1.35),
                  decoration: InputDecoration(
                    hintText: _recording
                        ? 'Listening — release to stop'
                        : _transcribing
                            ? 'Transcribing…'
                            : widget.offline
                                ? 'Asking needs a connection'
                                : 'Ask about your mail',
                    hintStyle: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              if (state.voice.configured && !widget.offline)
                GestureDetector(
                  onLongPressStart: (_) => _startRecording(),
                  onLongPressEnd: (_) => _stopRecording(keep: true),
                  onLongPressCancel: () => _stopRecording(keep: false),
                  // Deliberately not an IconButton: this responds to press-and-hold, and an
                  // IconButton with a null onPressed renders greyed out as though unavailable.
                  child: Tooltip(
                    message: 'Hold to speak',
                    child: Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _recording ? scheme.errorContainer : Colors.transparent,
                      ),
                      child: Icon(
                        _recording ? Icons.mic : Icons.mic_none,
                        size: 21,
                        color: busy
                            ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
                            : _recording
                                ? scheme.error
                                : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 2),
              _SendButton(
                sending: widget.sending,
                enabled: !busy && !widget.offline,
                onSend: widget.onSend,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.sending, required this.enabled, required this.onSend});

  final bool sending;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: enabled ? scheme.primary : scheme.surfaceContainerHighest,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onSend : null,
          child: SizedBox(
            width: 40,
            height: 40,
            child: sending
                ? Center(
                    child: SizedBox(
                      height: 17,
                      width: 17,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onPrimary,
                      ),
                    ),
                  )
                : Icon(
                    Icons.arrow_upward,
                    size: 20,
                    color: enabled ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
          ),
        ),
      ),
    );
  }
}
