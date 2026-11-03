import '../../models/chat.dart';
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

/// Un ami a changé de présence. `lastSeen` nul = caché ou jamais vu.
class PresenceChanged extends FriendsEvent {
  const PresenceChanged(this.userId, this.online, this.lastSeen);
  final String userId;
  final bool online;
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

/// Un ami m'a envoyé un message d'encouragement (« poke »).
class PokeReceived extends FriendsEvent {
  const PokeReceived(this.poke);
  final IncomingPoke poke;
}

/// Un message est apparu ou a changé (supprimé pour tous). Le contenu est
/// chiffré dans l'événement : on le relit déchiffré avec `messageById`.
class MessageEvent extends FriendsEvent {
  const MessageEvent({
    required this.messageId,
    required this.peerId,
    required this.mine,
    required this.isNew,
  });

  final String messageId;
  final String peerId;

  /// Envoyé par moi (depuis un autre appareil, par exemple).
  final bool mine;

  /// Nouveau message (sinon : modifié ou supprimé).
  final bool isNew;
}

/// L'autre personne a lu la discussion (« vu »).
class ReadMarkChanged extends FriendsEvent {
  const ReadMarkChanged(this.peerId, this.readAt);
  final String peerId;
  final DateTime readAt;
}

/// L'autre personne commence ou arrête d'écrire.
class TypingChanged extends FriendsEvent {
  const TypingChanged(this.peerId, this.typing);
  final String peerId;
  final bool typing;
}

/// Accès au serveur de la fonction Amis et de la messagerie.
///
/// Une interface plutôt que Supabase directement : les services ne savent
/// pas d'où viennent les données, ce qui permet de tester toute la logique
/// sans réseau avec un faux serveur (voir `test/friends_fake.dart`).
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

  // ------------------------------------------------------------ Présence

  /// Signal de présence ; renvoie l'heure du serveur.
  Future<DateTime> heartbeat();

  /// Hors ligne tout de suite, en gardant la date du dernier signal.
  Future<void> goOffline();

  /// Mode « Apparaître hors ligne » : les amis ne voient plus ma présence.
  Future<void> setInvisible(bool invisible);

  // ----------------------------------------------------------- Réglages

  /// Tous mes réglages privés (présence, messagerie, rôle administrateur).
  Future<ChatSettings> loadSettings();

  /// « Vu », « en train d'écrire » et aperçu des notifications.
  Future<void> setChatSettings({
    required bool hideReadReceipts,
    required bool hideTyping,
    required bool pushPreview,
  });

  // --------------------------------------------------------------- Amis

  Future<FriendsSnapshot> loadFriends();

  Future<List<FriendRequest>> loadRequests();

  /// Envoie une invitation. Lève « aucun compte avec cette adresse » si
  /// personne n'a activé la fonction Amis avec cette adresse.
  Future<SendResult> sendRequest(String email);

  /// Invitations que j'ai envoyées et qui n'ont pas abouti.
  Future<List<SentRequest>> loadSentRequests();

  Future<void> cancelRequest(String requestId);

  Future<void> respond(String requestId, bool accept);

  Future<void> removeFriend(String friendId);

  Future<void> sendPoke(String toId, PokeKind kind);

  /// Messages d'encouragement reçus pendant que l'application était fermée.
  Future<List<IncomingPoke>> unseenPokes();

  Future<void> markPokesSeen(List<String> ids);

  /// Efface mes amitiés, demandes et messages sur le serveur.
  Future<void> leave();

  // ------------------------------------------------------------ Messagerie

  /// Envoie un message ; renvoie son identifiant sur le serveur.
  Future<String> sendMessage(String toId, MessageKind kind, String body);

  /// Messages d'une discussion, du plus récent au plus ancien.
  Future<List<ChatMessage>> loadMessages(
    String friendId, {
    DateTime? before,
    int limit = 50,
  });

  Future<ChatMessage?> messageById(String id);

  Future<List<Conversation>> loadConversations({bool archived = false});

  Future<ChatInfo> conversationInfo(String friendId);

  /// J'ai lu la discussion (met à jour mes non-lus et le « vu » de l'autre).
  Future<void> markRead(String friendId);

  Future<void> setTyping(String friendId, bool typing);

  Future<void> deleteMessage(String messageId, {required bool forAll});

  /// Supprimer la discussion : pour moi seulement.
  Future<void> clearConversation(String friendId);

  Future<void> setArchived(String friendId, bool archived);

  Future<void> setMuted(String friendId, bool muted);

  // ----------------------------------------------- Blocage et signalements

  Future<void> blockUser(String userId);

  Future<void> unblockUser(String userId);

  Future<List<BlockedUser>> loadBlocks();

  Future<void> reportConversation(
    String friendId,
    List<String> messageIds, {
    String? remark,
    bool alsoBlock = false,
  });

  Future<void> reportPerson(String friendId, String remark);

  /// Écran administrateur : signalements (réservé au compte administrateur).
  Future<List<ReportEntry>> adminLoadReports({bool? handled});

  Future<void> adminHandleReport(String reportId, {String? note});

  Future<int> adminNewReportsCount();

  // ----------------------------------------------------------- Notifications

  /// Enregistre ce téléphone pour les notifications push.
  Future<void> registerPushToken(String token);

  /// Retire ce téléphone (déconnexion, désactivation).
  Future<void> unregisterPushToken(String token);

  // ------------------------------------------------------------ Temps réel

  /// Démarre l'écoute en direct.
  Future<void> subscribe();

  Future<void> unsubscribe();
}
