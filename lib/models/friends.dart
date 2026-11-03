// Modèles de la fonction « Amis » (données hébergées sur Supabase).

/// Un signal de présence plus ancien que cela = hors ligne.
///
/// L'application envoie un signal toutes les 30 secondes ; on laisse deux
/// signaux manqués avant de considérer la personne hors ligne.
const Duration presenceTimeout = Duration(seconds: 75);

/// Un ami accepté.
class Friend {
  const Friend({
    required this.id,
    required this.name,
    required this.since,
    this.avatarUrl,
    this.lastSeen,
  });

  /// Identifiant Supabase (et non l'identifiant du compte GymFlow local).
  final String id;
  final String name;
  final String? avatarUrl;

  /// Dernier signal de présence, à l'heure du serveur ; `null` = jamais vu
  /// ou volontairement hors ligne.
  final DateTime? lastSeen;
  final DateTime since;

  /// En ligne = signal récent. [serverNow] est l'heure du serveur estimée.
  bool isOnline(DateTime serverNow) {
    final seen = lastSeen;
    if (seen == null) return false;
    return serverNow.difference(seen) < presenceTimeout;
  }

  /// « En ligne », « Vu il y a 5 min »… (texte pour l'écran).
  String presenceLabel(DateTime serverNow) {
    final seen = lastSeen;
    if (isOnline(serverNow)) return 'En ligne';
    if (seen == null) return 'Hors ligne';
    final d = serverNow.difference(seen);
    if (d.inMinutes < 60) {
      return 'Vu il y a ${d.inMinutes < 1 ? 1 : d.inMinutes} min';
    }
    if (d.inHours < 24) return 'Vu il y a ${d.inHours} h';
    return 'Vu il y a ${d.inDays} j';
  }

  Friend copyWith({DateTime? lastSeen, bool clearLastSeen = false}) => Friend(
    id: id,
    name: name,
    avatarUrl: avatarUrl,
    since: since,
    lastSeen: clearLastSeen ? null : (lastSeen ?? this.lastSeen),
  );
}

/// Demande d'ami reçue, en attente de réponse.
class FriendRequest {
  const FriendRequest({
    required this.id,
    required this.fromName,
    required this.createdAt,
    this.avatarUrl,
  });

  final String id;
  final String fromName;
  final String? avatarUrl;
  final DateTime createdAt;
}

/// Messages prédéfinis qu'on peut envoyer à un ami (« poke »).
///
/// Le texte est dans l'application, pas dans la base : rien à modérer, et
/// personne ne peut envoyer un texte libre à quelqu'un.
enum PokeKind {
  encourage('encourage', 'Encourager', 'vous encourage'),
  challenge('challenge', 'Lancer un défi', 'vous lance un défi');

  const PokeKind(this.key, this.label, this._titleSuffix);

  /// Valeur stockée dans la base (colonne `kind`).
  final String key;
  final String label;
  final String _titleSuffix;

  static PokeKind fromKey(String? key) => PokeKind.values.firstWhere(
    (k) => k.key == key,
    orElse: () => PokeKind.encourage,
  );

  /// Titre de la notification : « Sarra vous encourage ».
  String title(String senderName) => '$senderName $_titleSuffix';

  /// Corps de la notification.
  String body(String senderName) => switch (this) {
    PokeKind.encourage =>
      'Votre ami(e) vous encourage à dépasser vos limites aujourd\'hui !',
    PokeKind.challenge =>
      '$senderName vous défie : une séance aujourd\'hui, partant(e) ?',
  };
}

/// Message reçu d'un ami.
class IncomingPoke {
  const IncomingPoke({
    required this.id,
    required this.senderId,
    required this.kind,
    required this.createdAt,
  });

  final String id;
  final String senderId;
  final PokeKind kind;
  final DateTime createdAt;
}
