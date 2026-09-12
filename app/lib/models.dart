/// Data shapes returned by the brain service.
///
/// Deliberately modelled as "a thread that may span channels" rather than "an email": the
/// backend pipeline is channel-agnostic (Gmail and Slack are two adapters feeding the same
/// ingest path, and a message arriving by both collapses into one thread), so nothing here
/// assumes a source. `channel` is a label, never a branch point.
library;

/// An urgent thread, from `GET /api/needs-attention`.
class UrgentThread {
  const UrgentThread({
    required this.id,
    required this.name,
    this.summary,
    this.category,
    this.topic,
    this.channel = 'gmail',
    this.updatedAt,
  });

  final String id;
  final String name;
  final String? summary;
  final String? category;
  final String? topic;
  final String channel;
  final String? updatedAt;

  factory UrgentThread.fromJson(Map<String, dynamic> json) => UrgentThread(
        id: json['id'] as String,
        name: json['name'] as String? ?? '(untitled)',
        summary: json['summary'] as String?,
        category: json['category'] as String?,
        topic: json['topic'] as String?,
        channel: json['channel'] as String? ?? 'gmail',
        updatedAt: json['updated_at'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'summary': summary,
        'category': category,
        'topic': topic,
        'channel': channel,
        'updated_at': updatedAt,
      };
}

/// An extracted to-do, from `GET /api/action-items`.
///
/// Note there is no id: the backend flattens these out of thread payloads, so the stable
/// identity is (threadId, text). That pair is also the dedup key for notifications, because
/// action items are recomputed on every merge and an old thread can legitimately reappear.
class ActionItem {
  const ActionItem({
    required this.text,
    required this.threadId,
    this.threadName,
    this.category,
    this.topic,
    this.channel = 'gmail',
    this.updatedAt,
  });

  final String text;
  final String threadId;
  final String? threadName;
  final String? category;
  final String? topic;
  final String channel;
  final String? updatedAt;

  String get dedupKey => '$threadId::${text.toLowerCase()}';

  factory ActionItem.fromJson(Map<String, dynamic> json) => ActionItem(
        text: json['text'] as String? ?? '',
        threadId: json['thread_id'] as String? ?? '',
        threadName: json['thread_name'] as String?,
        category: json['category'] as String?,
        topic: json['topic'] as String?,
        channel: json['channel'] as String? ?? 'gmail',
        updatedAt: json['updated_at'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'thread_id': threadId,
        'thread_name': threadName,
        'category': category,
        'topic': topic,
        'channel': channel,
        'updated_at': updatedAt,
      };
}

/// A node in the knowledge tree, from `GET /api/mail_tree`.
///
/// The endpoint returns the whole tree in one response, and thread nodes carry their `body`
/// inline — so a single cached payload renders both the tree and every thread detail with no
/// network. That is what makes offline browsing cheap here.
class TreeNode {
  const TreeNode({
    required this.id,
    required this.name,
    required this.type,
    this.summary,
    this.body,
    this.channel,
    this.needsReview = false,
    this.children = const [],
    this.category,
    this.topic,
    this.firstReceived,
    this.lastReceived,
    this.receivedEstimated = false,
    this.events = const [],
  });

  final String id;
  final String name;
  final String type; // root | mail_category | mail_topic | mail_thread
  final String? summary;
  final String? body;
  final String? channel;
  final bool needsReview;
  final List<TreeNode> children;

  // Thread-only. Category and topic ride on the thread itself because the time view regroups
  // threads by date, where they are no longer the thread's ancestors.
  final String? category;
  final String? topic;
  final String? firstReceived;
  final String? lastReceived;

  /// The received dates were inferred from when the thread was stored, not from a Date header
  /// — true for threads ingested before dates were recorded.
  final bool receivedEstimated;
  final List<MailEvent> events;

  bool get isThread => type == 'mail_thread';

  /// Used by the tree's filter and time views, which rebuild branches out of the same nodes.
  TreeNode copyWith({List<TreeNode>? children, String? summary}) => TreeNode(
        id: id,
        name: name,
        type: type,
        summary: summary ?? this.summary,
        body: body,
        channel: channel,
        needsReview: needsReview,
        children: children ?? this.children,
        category: category,
        topic: topic,
        firstReceived: firstReceived,
        lastReceived: lastReceived,
        receivedEstimated: receivedEstimated,
        events: events,
      );

  /// Dated items still ahead, soonest first.
  ///
  /// Decided from the date itself: the server sends no status with an event
  /// (`brain/mail_timeline.py`), so filtering on one kept every past date too.
  List<MailEvent> get upcomingEvents {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return events.where((e) {
      final day = DateTime.tryParse(e.date);
      return day != null && !day.isBefore(today);
    }).toList(growable: false)
      ..sort((a, b) => a.date.compareTo(b.date));
  }

  /// Every thread anywhere beneath this node.
  Iterable<TreeNode> get threads sync* {
    if (isThread) {
      yield this;
      return;
    }
    for (final child in children) {
      yield* child.threads;
    }
  }

  TreeNode? findById(String target) {
    if (id == target) return this;
    for (final child in children) {
      final hit = child.findById(target);
      if (hit != null) return hit;
    }
    return null;
  }

  factory TreeNode.fromJson(Map<String, dynamic> json) => TreeNode(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '(untitled)',
        type: json['type'] as String? ?? 'mail_thread',
        summary: json['summary'] as String?,
        body: json['body'] as String?,
        channel: json['channel'] as String?,
        needsReview: json['needs_review'] as bool? ?? false,
        category: json['category'] as String?,
        topic: json['topic'] as String?,
        firstReceived: json['first_received'] as String?,
        lastReceived: json['last_received'] as String?,
        receivedEstimated: json['received_estimated'] as bool? ?? false,
        events: ((json['events'] as List<dynamic>?) ?? const [])
            .map((e) => MailEvent.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        children: ((json['children'] as List<dynamic>?) ?? const [])
            .map((c) => TreeNode.fromJson(c as Map<String, dynamic>))
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'summary': summary,
        'body': body,
        'channel': channel,
        'needs_review': needsReview,
        'category': category,
        'topic': topic,
        'first_received': firstReceived,
        'last_received': lastReceived,
        'received_estimated': receivedEstimated,
        'events': events.map((e) => e.toJson()).toList(growable: false),
        'children': children.map((c) => c.toJson()).toList(growable: false),
      };
}

/// `GET /api/mail/status`.
///
/// `needsReconnect` is not an error state. This project requests a restricted Gmail scope and
/// is unverified, so Google expires its refresh tokens weekly — reconnecting is routine and
/// the UI must offer it as an action, not report it as a failure.
class MailStatus {
  const MailStatus({
    required this.connected,
    this.email,
    this.reason,
    this.needsReconnect = false,
  });

  final bool connected;
  final String? email;
  final String? reason;
  final bool needsReconnect;

  static const MailStatus unknown = MailStatus(connected: false, reason: 'not checked yet');

  factory MailStatus.fromJson(Map<String, dynamic> json) => MailStatus(
        connected: json['connected'] as bool? ?? false,
        email: json['email'] as String?,
        reason: json['reason'] as String?,
        needsReconnect: json['needs_reconnect'] as bool? ?? false,
      );
}

/// One progress event from `POST /api/mail/reload/stream`.
///
/// The stream is NDJSON — one JSON object per line, no `data:` prefix — not server-sent
/// events, despite looking similar. Stages run:
/// `connecting` -> `fetched` -> (`ingesting` -> `ingested`)* -> `done`, or `failed`.
///
/// Note `done` is a *count of messages processed*, not a boolean. Use [isTerminal] to detect
/// the end of the stream.
class IngestProgress {
  const IngestProgress({
    required this.stage,
    this.done,
    this.total,
    this.subject,
    this.error,
    this.processed,
  });

  final String stage;
  final int? done;
  final int? total;
  final String? subject;
  final String? error;
  final int? processed;

  bool get isTerminal => stage == 'done' || stage == 'failed';
  bool get failed => stage == 'failed';

  /// What to put in front of the user while this is happening.
  String get label {
    switch (stage) {
      case 'connecting':
        return 'Connecting to your mailbox…';
      case 'fetched':
        final n = total ?? 0;
        if (n == 0) return 'No new mail.';
        return n == 1 ? 'Found 1 message' : 'Found $n messages';
      case 'ingesting':
      case 'ingested':
        final at = (done ?? 0) + (stage == 'ingesting' ? 1 : 0);
        final of = total ?? 0;
        final where = of > 0 ? 'Sorting $at of $of' : 'Sorting';
        return subject == null || subject!.isEmpty ? '$where…' : '$where — $subject';
      case 'done':
        final n = processed ?? 0;
        if (n == 0) return 'Nothing new.';
        return n == 1 ? 'Sorted 1 message.' : 'Sorted $n messages.';
      case 'failed':
        return error ?? 'Sync failed.';
      default:
        return stage;
    }
  }

  factory IngestProgress.fromJson(Map<String, dynamic> json) => IngestProgress(
        stage: json['stage'] as String? ?? 'unknown',
        done: json['done'] as int?,
        total: json['total'] as int?,
        subject: json['subject'] as String?,
        error: json['error'] as String?,
        processed: json['processed'] as int?,
      );
}

/// A date found in a thread — a deadline or an event (`brain/mail_timeline.py`).
class MailEvent {
  const MailEvent({required this.date, this.title, this.kind = 'event'});

  /// The day the event falls on, ISO-8601. The API calls this field `start`.
  final String date;
  final String? title;
  final String kind; // deadline | event

  bool get isDeadline => kind == 'deadline';

  /// `start` is what the tree endpoint sends; `date` is only read so a cache written by an
  /// older build still parses.
  factory MailEvent.fromJson(Map<String, dynamic> json) => MailEvent(
        date: json['start'] as String? ?? json['date'] as String? ?? '',
        title: json['title'] as String?,
        kind: json['kind'] as String? ?? 'event',
      );

  Map<String, dynamic> toJson() => {'start': date, 'title': title, 'kind': kind};
}

/// A thread awaiting a human decision, from `GET /api/mail/review`.
class ReviewItem {
  const ReviewItem({
    required this.id,
    required this.name,
    this.summary,
    this.category,
    this.topic,
    this.llmCategory,
    this.keywordCategory,
  });

  final String id;
  final String name;
  final String? summary;
  final String? category;
  final String? topic;
  final String? llmCategory;
  final String? keywordCategory;

  /// True when the model and the keyword scorer disagreed — the reason this needs a human.
  bool get disputed =>
      llmCategory != null && keywordCategory != null && llmCategory != keywordCategory;

  factory ReviewItem.fromJson(Map<String, dynamic> json) => ReviewItem(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '(untitled)',
        summary: json['summary'] as String?,
        category: json['category'] as String?,
        topic: json['topic'] as String?,
        llmCategory: json['llm_category'] as String?,
        keywordCategory: json['keyword_category'] as String?,
      );
}

/// An automation rule, from `GET /api/rules`.
class AutomationRule {
  const AutomationRule({
    required this.id,
    required this.text,
    this.triggerCategory,
    this.urgentOnly = false,
    this.enabled = true,
  });

  final String id;
  final String text;
  final String? triggerCategory;
  final bool urgentOnly;
  final bool enabled;

  factory AutomationRule.fromJson(Map<String, dynamic> json) => AutomationRule(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        triggerCategory: json['trigger_category'] as String?,
        urgentOnly: json['trigger_urgent_only'] as bool? ?? false,
        enabled: json['enabled'] as bool? ?? true,
      );
}

/// A chat conversation, from the console's `/chat/sessions`.
class ChatSession {
  const ChatSession({required this.id, this.title, this.updatedAt, this.messages = const []});

  final int id;
  final String? title;
  final DateTime? updatedAt;
  final List<ChatMessage> messages;

  String get displayTitle => (title == null || title!.isEmpty) ? 'New conversation' : title!;

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
        id: json['id'] as int,
        title: json['title'] as String?,
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
        messages: ((json['messages'] as List<dynamic>?) ?? const [])
            .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updated_at': updatedAt?.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(growable: false),
      };
}

class ChatMessage {
  const ChatMessage({required this.role, required this.content, this.pending = false});

  final String role; // user | assistant
  final String content;

  /// Set on the optimistic local echo of a question, before the answer returns.
  final bool pending;

  bool get isUser => role == 'user';

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        role: json['role'] as String? ?? 'assistant',
        content: json['content'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

/// `GET /voice/options`. When [configured] is false the server has no Sarvam key and every
/// voice control stays hidden — an unconfigured server degrades to plain text chat.
class VoiceOptions {
  const VoiceOptions({
    required this.configured,
    this.languages = const [],
    this.speakers = const [],
    this.defaultLanguage = 'en-IN',
    this.defaultSpeaker = 'shubh',
  });

  final bool configured;
  final List<String> languages;
  final List<String> speakers;
  final String defaultLanguage;
  final String defaultSpeaker;

  static const VoiceOptions off = VoiceOptions(configured: false);

  factory VoiceOptions.fromJson(Map<String, dynamic> json) => VoiceOptions(
        configured: json['configured'] as bool? ?? false,
        languages: ((json['languages'] as List<dynamic>?) ?? const []).cast<String>(),
        speakers: ((json['speakers'] as List<dynamic>?) ?? const []).cast<String>(),
        defaultLanguage: json['default_language'] as String? ?? 'en-IN',
        defaultSpeaker: json['default_speaker'] as String? ?? 'shubh',
      );
}

/// One bar of `GET /api/analytics/category-volume`.
class VolumePoint {
  const VolumePoint({required this.bucket, required this.category, required this.count});

  final String bucket;
  final String category;
  final int count;

  factory VolumePoint.fromJson(Map<String, dynamic> json) => VolumePoint(
        bucket: json['bucket'] as String? ?? '',
        category: json['category'] as String? ?? 'Uncategorized',
        count: json['count'] as int? ?? 0,
      );
}

/// `GET /api/settings`. `offlineMode` is the server's "don't call the model" switch — it is
/// unrelated to the device being offline. The UI calls it "Skip AI processing".
class BrainSettings {
  const BrainSettings({this.offlineMode = false, this.slackChannelId = ''});

  final bool offlineMode;
  final String slackChannelId;

  factory BrainSettings.fromJson(Map<String, dynamic> json) => BrainSettings(
        offlineMode: json['offline_mode'] as bool? ?? false,
        slackChannelId: json['slack_channel_id'] as String? ?? '',
      );
}
