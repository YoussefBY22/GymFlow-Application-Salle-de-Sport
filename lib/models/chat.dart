// Modèles de la messagerie entre amis (données hébergées sur Supabase).
import 'dart:convert';

/// Plafond d'un message écrit (le serveur applique le même).
const int maxMessageLength = 1000;

/// Combien de temps « X est en train d'écrire… » reste affiché sans nouvel
/// événement (le serveur écrit 6 s).
const Duration typingTimeout = Duration(seconds: 6);

/// Type d'un message.
enum MessageKind {
  /// Texte et emojis.
  text('text'),

  /// Carte partagée (séance, workout, exercice, programme).
  share('share');

  const MessageKind(this.key);
  final String key;

  static MessageKind fromKey(String? key) =>
      key == 'share' ? MessageKind.share : MessageKind.text;
}

/// État d'envoi d'un message de moi (jamais stocké : seulement à l'écran).
enum SendState { sent, sending, failed }

/// Un message d'une discussion, déjà déchiffré par le serveur.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.peerId,
    required this.mine,
    required this.kind,
    required this.createdAt,
    this.text,
    this.deleted = false,
    this.state = SendState.sent,
  });

  /// Identifiant du serveur, ou `local:…` tant que l'envoi n'a pas abouti.
  final String id;

  /// L'autre personne de la discussion.
  final String peerId;
  final bool mine;
  final MessageKind kind;

  /// Contenu clair ; `null` si le message a été supprimé pour tout le monde.
  final String? text;
  final DateTime createdAt;

  /// Supprimé pour tout le monde : une trace reste.
  final bool deleted;
  final SendState state;

  bool get isLocal => id.startsWith('local:');

  /// Carte partagée, si c'en est une et si son contenu est lisible.
  ShareCard? get share {
    if (kind != MessageKind.share || text == null) return null;
    return ShareCard.tryParse(text!);
  }

  ChatMessage copyWith({String? id, SendState? state, DateTime? createdAt}) =>
      ChatMessage(
        id: id ?? this.id,
        peerId: peerId,
        mine: mine,
        kind: kind,
        text: text,
        createdAt: createdAt ?? this.createdAt,
        deleted: deleted,
        state: state ?? this.state,
      );

  /// Extrait lisible pour la liste des discussions et les notifications.
  String get preview {
    if (deleted) return 'Message supprimé';
    if (kind == MessageKind.share) {
      return share?.previewLine ?? 'Élément partagé';
    }
    return text ?? '';
  }
}

/// Un élément partagé dans une discussion (séance, workout, exercice,
/// programme). Le contenu voyage **chiffré** comme un message, sous forme
/// d'un instantané : le destinataire le lit même si l'élément n'existe pas
/// sur son téléphone.
class ShareCard {
  const ShareCard({
    required this.type,
    required this.title,
    required this.data,
    this.subtitle = '',
  });

  /// `session`, `workout`, `exercise` ou `program`.
  final String type;
  final String title;
  final String subtitle;

  /// Instantané complet (structure propre à chaque type).
  final Map<String, dynamic> data;

  static const types = ['session', 'workout', 'exercise', 'program'];

  String get typeLabel => switch (type) {
    'session' => 'Séance',
    'workout' => 'Workout',
    'exercise' => 'Exercice',
    'program' => 'Programme',
    _ => 'Élément',
  };

  String get previewLine => '$typeLabel partagé : $title';

  String encode() => jsonEncode({
    'type': type,
    'title': title,
    'subtitle': subtitle,
    'data': data,
  });

  static ShareCard? tryParse(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final type = j['type'];
      if (type is! String || !types.contains(type)) return null;
      return ShareCard(
        type: type,
        title: (j['title'] as String?) ?? '',
        subtitle: (j['subtitle'] as String?) ?? '',
        data: Map<String, dynamic>.from((j['data'] as Map?) ?? const {}),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Une ligne de la liste des discussions.
class Conversation {
  const Conversation({
    required this.friendId,
    required this.friendName,
    required this.lastAt,
    required this.lastMine,
    required this.lastPreview,
    this.avatarUrl,
    this.unread = 0,
    this.muted = false,
    this.archived = false,
  });

  final String friendId;
  final String friendName;
  final String? avatarUrl;
  final DateTime lastAt;
  final bool lastMine;
  final String lastPreview;
  final int unread;
  final bool muted;
  final bool archived;
}

/// Informations d'une discussion.
class ChatInfo {
  const ChatInfo({this.peerReadAt, this.muted = false, this.archived = false});

  /// Dernier « vu » de l'autre (`null` : pas de « vu » visible).
  final DateTime? peerReadAt;
  final bool muted;
  final bool archived;
}

/// Réglages de la messagerie et de la présence (privés).
class ChatSettings {
  const ChatSettings({
    this.invisible = false,
    this.hideReadReceipts = false,
    this.hideTyping = false,
    this.pushPreview = true,
    this.isAdmin = false,
  });

  final bool invisible;
  final bool hideReadReceipts;
  final bool hideTyping;
  final bool pushPreview;
  final bool isAdmin;

  ChatSettings copyWith({
    bool? invisible,
    bool? hideReadReceipts,
    bool? hideTyping,
    bool? pushPreview,
  }) => ChatSettings(
    invisible: invisible ?? this.invisible,
    hideReadReceipts: hideReadReceipts ?? this.hideReadReceipts,
    hideTyping: hideTyping ?? this.hideTyping,
    pushPreview: pushPreview ?? this.pushPreview,
    isAdmin: isAdmin,
  );
}

/// Une personne que j'ai bloquée (visible de moi seul).
class BlockedUser {
  const BlockedUser({required this.id, required this.name, this.avatarUrl});
  final String id;
  final String name;
  final String? avatarUrl;
}

/// Un message cité dans un signalement.
class ReportedMessage {
  const ReportedMessage({
    required this.from,
    required this.mine,
    required this.at,
    required this.kind,
    this.text,
  });

  final String from;

  /// Écrit par la personne qui signale.
  final bool mine;
  final DateTime at;
  final MessageKind kind;
  final String? text;

  String get display {
    if (text == null) return 'Message supprimé';
    if (kind == MessageKind.share) {
      return ShareCard.tryParse(text!)?.previewLine ?? 'Élément partagé';
    }
    return text!;
  }
}

/// Un signalement, tel que l'administrateur le voit.
class ReportEntry {
  const ReportEntry({
    required this.id,
    required this.isConversation,
    required this.handled,
    required this.createdAt,
    required this.reporterName,
    required this.reportedName,
    required this.messages,
    this.remark,
    this.handledAt,
    this.handledNote,
  });

  final String id;

  /// `true` : discussion (messages choisis) ; `false` : personne.
  final bool isConversation;
  final bool handled;
  final DateTime createdAt;
  final String reporterName;
  final String reportedName;
  final String? remark;
  final List<ReportedMessage> messages;
  final DateTime? handledAt;
  final String? handledNote;
}
