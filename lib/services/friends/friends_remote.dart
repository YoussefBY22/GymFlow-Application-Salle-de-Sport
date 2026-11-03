import '../../models/friends.dart';

/// Liste d'amis et heure du serveur au moment de la lecture.
class FriendsSnapshot {
  const FriendsSnapshot({required this.friends, required this.serverNow});
  final List<Friend> friends;

  /// Heure du serveur : sert à calculer « en ligne » sans dépendre de
  /// l'horloge (parfois fausse) du téléphone.
  final DateTime serverNow;
}

/// Ce qui arrive en direct depuis le serveur.
sealed class FriendsEvent {
  const FriendsEvent();
}

/// Un ami a changé de présence (`lastSeen` nul = hors ligne).
class PresenceChanged extends FriendsEvent {
  const PresenceChanged(this.userId, this.lastSeen);
  final String userId;
  final DateTime? lastSeen;
}

/// Quelqu'un m'a envoyé une demande d'ami.
class RequestReceived extends FriendsEvent {
  const RequestReceived(this.requestId);
  final String requestId;
}

/// Quelqu'un a accepté ma demande d'ami.
class RequestAccepted extends FriendsEvent {
  const RequestAccepted(this.friendId);
  final String friendId;
}

/// Les amitiés ont changé (suppression, refus…) : relire la liste.
class RelationsChanged extends FriendsEvent {
  const RelationsChanged();
}

/// Un ami m'a envoyé un message.
class PokeReceived extends FriendsEvent {
  const PokeReceived(this.poke);
  final IncomingPoke poke;
}

/// Accès au serveur de la fonction Amis.
///
/// Une interface plutôt que Supabase directement : `FriendsService` ne sait
/// pas d'où viennent les données, ce qui permet de tester toute la logique
/// sans réseau avec un faux serveur (voir `test/friends_test.dart`).
abstract class FriendsRemote {
  /// Identifiant du compte connecté au serveur, ou `null`.
  String? get userId;

  /// Adresse e-mail du compte connecté au serveur, ou `null`.
  String? get userEmail;

  /// Événements en direct (actifs après [subscribe]).
  Stream<FriendsEvent> get events;

  /// Reprend une session déjà ouverte sur ce téléphone. `true` si elle existe.
  Future<bool> restore();

  /// Ouvre la session du serveur ; crée le compte au premier passage.
  Future<void> signIn({
    required String email,
    required String password,
    required String displayName,
  });

  Future<void> signOut();

  /// Change le mot de passe du compte du serveur (après un changement local).
  Future<void> updatePassword(String password);

  Future<void> updateProfile({
    required String displayName,
    required bool enabled,
    String? avatarUrl,
  });

  /// Signal de présence ; renvoie l'heure du serveur.
  Future<DateTime> heartbeat();

  Future<void> goOffline();

  Future<FriendsSnapshot> loadFriends();

  Future<List<FriendRequest>> loadRequests();

  /// Envoie une demande d'ami. Ne révèle jamais si l'adresse a un compte.
  Future<void> sendRequest(String email);

  Future<void> respond(String requestId, bool accept);

  Future<void> removeFriend(String friendId);

  Future<void> sendPoke(String toId, PokeKind kind);

  /// Messages reçus pendant que l'application était fermée.
  Future<List<IncomingPoke>> unseenPokes();

  Future<void> markPokesSeen(List<String> ids);

  /// Efface mes amitiés, demandes et messages sur le serveur.
  Future<void> leave();

  /// Démarre l'écoute en direct.
  Future<void> subscribe();

  Future<void> unsubscribe();
}
