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
  });

  final String id;
  final String name;
  final String type; // root | mail_category | mail_topic | mail_thread
  final String? summary;
  final String? body;
  final String? channel;
  final bool needsReview;
  final List<TreeNode> children;

  bool get isThread => type == 'mail_thread';

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
