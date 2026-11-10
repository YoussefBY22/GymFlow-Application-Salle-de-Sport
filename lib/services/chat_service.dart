import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../models/chat.dart';
import '../models/enums.dart';
import 'backend.dart';
import 'friends/friends_remote.dart';

/// Une discussion ouverte : ses messages, le « vu » de l'autre et son état
/// « en train d'écrire ».
class ChatThread extends ChangeNotifier {
  ChatThread(this.friendId);

  final String friendId;

  /// Du plus ancien au plus récent.
  List<ChatMessage> messages = [];
  ChatInfo info = const ChatInfo();
  bool loaded = false;
  bool loadingMore = false;
  bool hasMore = true;
  bool peerTyping = false;
  Timer? _typingTimer;

  void changed() => notifyListeners();

  @override
  void dispose() {
    _typingTimer?.cancel();
    super.dispose();
  }
}

/// Messagerie 1 contre 1 entre amis, sur Supabase.
///
/// Les messages sont **chiffrés dans la base** : le serveur ne les renvoie
/// déchiffrés qu'aux deux personnes de la discussion. Texte et emojis
/// seulement (et des cartes de partage), aucune limite d'envoi.
class ChatService extends ChangeNotifier {
  ChatService(this._b, this._remote);

  final Backend _b;
  final FriendsRemote? _remote;

  /// Route de l'écran de discussion (l'argument est l'identifiant de l'ami).
  static const route = '/chat';

  final Map<String, ChatThread> _threads = {};
  List<Conversation> _conversations = const [];
  List<Conversation> _archived = const [];
  List<BlockedUser> _blocks = const [];
  StreamSubscription<FriendsEvent>? _sub;
  String? _activeFriendId;
  int _localCounter = 0;
  final Set<String> _notified = {};
  final Map<String, DateTime> _typingSentAt = {};
  final Map<String, Timer> _typingOff = {};

  bool get available => _remote != null;

  /// Discussions de la liste principale (les plus récentes d'abord).
  List<Conversation> get conversations => _conversations;

  /// Discussions archivées.
  List<Conversation> get archived => _archived;

  List<BlockedUser> get blocks => _blocks;

  /// Messages non lus (hors discussions en silence), pour la pastille du menu.
  int get unreadTotal =>
      _conversations.where((c) => !c.muted).fold(0, (sum, c) => sum + c.unread);

  /// Discussion actuellement à l'écran.
  String? get activeFriendId => _activeFriendId;

  FriendsRemote get _r =>
      _remote ??
      (throw const BusinessRuleException('Messagerie indisponible.'));

  // ------------------------------------------------------------ Cycle de vie

  /// Branche la messagerie sur les événements en direct (appelé à la
  /// connexion de la fonction Amis).
  void attach() {
    final remote = _remote;
    if (remote == null) return;
    _sub?.cancel();
    _sub = remote.events.listen(
      (e) => unawaited(_onEvent(e).catchError((Object _) {})),
    );
  }

  /// Débranche l'écoute et efface tout (déconnexion, désactivation).
  void reset() {
    _sub?.cancel();
    _sub = null;
    for (final t in _threads.values) {
      t.dispose();
    }
    _threads.clear();
    for (final t in _typingOff.values) {
      t.cancel();
    }
    _typingOff.clear();
    _typingSentAt.clear();
    _conversations = const [];
    _archived = const [];
    _blocks = const [];
    _activeFriendId = null;
    _notified.clear();
    notifyListeners();
  }

  /// Arrête les minuteurs (tests, fermeture de l'application).
  void stop() {
    for (final t in _typingOff.values) {
      t.cancel();
    }
    _typingOff.clear();
    _sub?.cancel();
    _sub = null;
    for (final t in _threads.values) {
      t._typingTimer?.cancel();
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  // ------------------------------------------------------------ Discussions

  /// Relit la liste des discussions (principale et archivées).
  Future<void> refreshConversations() async {
    _conversations = await _r.loadConversations();
    _archived = await _r.loadConversations(archived: true);
    notifyListeners();
  }

  Future<void> refreshBlocks() async {
    _blocks = await _r.loadBlocks();
    notifyListeners();
  }

  ChatThread thread(String friendId) =>
      _threads.putIfAbsent(friendId, () => ChatThread(friendId));

  /// Ouvre une discussion : charge les derniers messages, marque comme lu.
  Future<ChatThread> open(String friendId) async {
    final t = thread(friendId);
    final msgs = await _r.loadMessages(friendId);
    final pending = t.messages.where((m) => m.isLocal).toList();
    t.messages = [...msgs.reversed, ...pending];
    t.hasMore = msgs.length >= 50;
    t.info = await _r.conversationInfo(friendId);
    t.loaded = true;
    t.changed();
    await markRead(friendId);
    return t;
  }

  /// Charge des messages plus anciens (défilement vers le haut).
  Future<void> loadMore(String friendId) async {
    final t = thread(friendId);
    if (t.loadingMore || !t.hasMore || t.messages.isEmpty) return;
    t.loadingMore = true;
    t.changed();
    try {
      final oldest = t.messages.firstWhere((m) => !m.isLocal).createdAt;
      final older = await _r.loadMessages(friendId, before: oldest);
      t.hasMore = older.length >= 50;
      t.messages = [...older.reversed, ...t.messages];
    } finally {
      t.loadingMore = false;
      t.changed();
    }
  }

  /// La discussion est à l'écran (ou n'y est plus) : sert à ne pas notifier
  /// un message qu'on est en train de lire.
  void setActive(String? friendId) {
    _activeFriendId = friendId;
  }

  Future<void> markRead(String friendId) async {
    try {
      await _r.markRead(friendId);
    } catch (_) {
      return;
    }
    final i = _conversations.indexWhere((c) => c.friendId == friendId);
    if (i >= 0 && _conversations[i].unread > 0) {
      final list = [..._conversations];
      final c = list[i];
      list[i] = Conversation(
        friendId: c.friendId,
        friendName: c.friendName,
        avatarUrl: c.avatarUrl,
        lastAt: c.lastAt,
        lastMine: c.lastMine,
        lastPreview: c.lastPreview,
        muted: c.muted,
        archived: c.archived,
      );
      _conversations = list;
      notifyListeners();
    }
  }

  /// Messages à proposer dans l'écran de signalement : toute la
  /// discussion (jusqu'à 200 messages), du plus ancien au plus récent, sans
  /// les messages supprimés pour tout le monde.
  Future<List<ChatMessage>> messagesForReport(String friendId) async {
    final list = await _r.loadMessages(friendId, limit: 200);
    return list.where((m) => !m.deleted).toList().reversed.toList();
  }

  // ------------------------------------------------------------- Envoi

  /// Envoie un message. Il apparaît tout de suite (« envoi… »), puis passe à
  /// « envoyé » ou « échec » (réessayer).
  Future<void> send(
    String friendId,
    String text, {
    MessageKind kind = MessageKind.text,
  }) async {
    final body = text.trim();
    if (body.isEmpty) return;
    if (kind == MessageKind.text && body.length > maxMessageLength) {
      throw const ValidationException(
        'Message trop long (1 000 caractères au plus).',
      );
    }
    final t = thread(friendId);
    final local = ChatMessage(
      id: 'local:${++_localCounter}',
      peerId: friendId,
      mine: true,
      kind: kind,
      text: body,
      createdAt: _b.friends.serverNow(),
      state: SendState.sending,
    );
    t.messages = [...t.messages, local];
    stopTyping(friendId);
    t.changed();
    await _deliver(t, local);
  }

  /// Renvoie un message dont l'envoi a échoué.
  Future<void> retry(String friendId, String localId) async {
    final t = thread(friendId);
    final i = t.messages.indexWhere((m) => m.id == localId);
    if (i < 0) return;
    final sending = t.messages[i].copyWith(state: SendState.sending);
    t.messages = [...t.messages]..[i] = sending;
    t.changed();
    await _deliver(t, sending);
  }

  Future<void> _deliver(ChatThread t, ChatMessage local) async {
    try {
      final id = await _r.sendMessage(t.friendId, local.kind, local.text!);
      final canonical = await _r.messageById(id);
      _remove(t, local.id);
      _merge(t, canonical ?? local.copyWith(id: id, state: SendState.sent));
      t.changed();
      unawaited(refreshConversations().catchError((Object _) {}));
    } catch (e) {
      final i = t.messages.indexWhere((m) => m.id == local.id);
      if (i >= 0) {
        t.messages = [...t.messages]
          ..[i] = local.copyWith(state: SendState.failed);
        t.changed();
      }
      rethrow;
    }
  }

  void _remove(ChatThread t, String id) {
    t.messages = t.messages.where((m) => m.id != id).toList();
  }

  /// Ajoute ou remplace un message (par identifiant) en gardant l'ordre.
  void _merge(ChatThread t, ChatMessage m) {
    final list = t.messages.where((x) => x.id != m.id).toList()..add(m);
    list.sort((a, b) {
      final c = a.createdAt.compareTo(b.createdAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    t.messages = list;
  }

  // ----------------------------------------------------- En train d'écrire

  /// À appeler quand la personne tape (ou efface) du texte.
  void userTyping(String friendId, bool hasText) {
    _b.friends.noteActivity();
    if (_b.friends.settings.hideTyping) return;
    if (thread(friendId).info.hideTyping) return;
    if (!hasText) {
      stopTyping(friendId);
      return;
    }
    final now = _b.now();
    final last = _typingSentAt[friendId];
    if (last == null || now.difference(last) > const Duration(seconds: 3)) {
      _typingSentAt[friendId] = now;
      unawaited(_r.setTyping(friendId, true).catchError((Object _) {}));
    }
    // Sans nouvelle frappe pendant 4 s, on dit qu'on a arrêté.
    _typingOff[friendId]?.cancel();
    _typingOff[friendId] = Timer(const Duration(seconds: 4), () {
      stopTyping(friendId);
    });
  }

  /// La personne a fini d'écrire (envoi, champ vidé, discussion quittée).
  void stopTyping(String friendId) {
    _typingOff.remove(friendId)?.cancel();
    if (_typingSentAt.remove(friendId) != null) {
      unawaited(_r.setTyping(friendId, false).catchError((Object _) {}));
    }
  }

  // ------------------------------------------------------------- Actions

  /// Supprime un message : pour moi, ou pour tout le monde (mes messages ;
  /// une trace « Ce message a été supprimé » reste alors).
  Future<void> delete(
    String friendId,
    ChatMessage message, {
    required bool forAll,
  }) async {
    final t = thread(friendId);
    if (message.isLocal) {
      _remove(t, message.id);
      t.changed();
      return;
    }
    await _r.deleteMessage(message.id, forAll: forAll);
    if (forAll) {
      final i = t.messages.indexWhere((m) => m.id == message.id);
      if (i >= 0) {
        t.messages = [...t.messages]
          ..[i] = ChatMessage(
            id: message.id,
            peerId: message.peerId,
            mine: message.mine,
            kind: message.kind,
            createdAt: message.createdAt,
            deleted: true,
          );
      }
    } else {
      _remove(t, message.id);
    }
    t.changed();
    unawaited(refreshConversations().catchError((Object _) {}));
  }

  /// Supprimer la discussion : pour moi seulement.
  Future<void> clear(String friendId) async {
    await _r.clearConversation(friendId);
    final t = thread(friendId);
    t.messages = const [];
    t.hasMore = false;
    t.changed();
    await refreshConversations();
  }

  Future<void> setArchived(String friendId, bool value) async {
    await _r.setArchived(friendId, value);
    final t = thread(friendId);
    t.info = t.info.copyWith(archived: value);
    t.changed();
    await refreshConversations();
  }

  /// Règle « Vu » et « en train d'écrire » pour **cette** discussion
  /// seulement (menu de la discussion). Même règle de réciprocité que les
  /// réglages généraux de Mes amis.
  Future<void> setPrivacy(
    String friendId, {
    bool? hideReceipts,
    bool? hideTyping,
  }) async {
    final t = thread(friendId);
    final receipts = hideReceipts ?? t.info.hideReceipts;
    final typing = hideTyping ?? t.info.hideTyping;
    await _r.setChatPrivacy(
      friendId,
      hideReceipts: receipts,
      hideTyping: typing,
    );
    if (typing) stopTyping(friendId);
    t.info = t.info.copyWith(hideReceipts: receipts, hideTyping: typing);
    // Le « Vu » de l'autre apparaît ou disparaît selon ce réglage.
    t.info = await _r.conversationInfo(friendId);
    t.changed();
  }

  Future<void> setMuted(String friendId, bool value) async {
    await _r.setMuted(friendId, value);
    final t = thread(friendId);
    t.info = t.info.copyWith(muted: value);
    t.changed();
    await refreshConversations();
  }

  /// Bloquer : l'amitié disparaît des deux côtés ; l'autre personne ne sait
  /// pas qui a bloqué qui.
  Future<void> block(String friendId) async {
    await _r.blockUser(friendId);
    _threads.remove(friendId)?.dispose();
    await _b.friends.refresh();
    await refreshConversations();
    await refreshBlocks();
  }

  Future<void> unblock(String userId) async {
    await _r.unblockUser(userId);
    await refreshBlocks();
  }

  /// Signaler une **discussion** : au moins 1 message choisi, remarque
  /// facultative.
  Future<void> reportConversation(
    String friendId,
    List<String> messageIds, {
    String? remark,
    bool alsoBlock = false,
  }) async {
    if (messageIds.isEmpty) {
      throw const ValidationException('Sélectionnez au moins un message.');
    }
    final text = remark?.trim();
    if (text != null && text.length > 500) {
      throw const ValidationException('Remarque : 500 caractères au plus.');
    }
    await _r.reportConversation(
      friendId,
      messageIds,
      remark: (text == null || text.isEmpty) ? null : text,
      alsoBlock: alsoBlock,
    );
    if (alsoBlock) {
      _threads.remove(friendId)?.dispose();
      await _b.friends.refresh();
      await refreshConversations();
      await refreshBlocks();
    }
  }

  /// Signaler une **personne** depuis la liste d'amis (motif obligatoire).
  Future<void> reportPerson(String friendId, String remark) async {
    final text = remark.trim();
    if (text.length < 5 || text.length > 500) {
      throw const ValidationException('Motif : 5 à 500 caractères.');
    }
    await _r.reportPerson(friendId, text);
  }

  // ----------------------------------------------------- Événements en direct

  Future<void> _onEvent(FriendsEvent e) async {
    switch (e) {
      case MessageEvent():
        await _onMessage(e);
      case ReadMarkChanged():
        final t = _threads[e.peerId];
        if (t == null) return;
        final current = t.info.peerReadAt;
        if (current == null || e.readAt.isAfter(current)) {
          t.info = t.info.copyWith(peerReadAt: e.readAt);
          t.changed();
        }
      case TypingChanged():
        final t = _threads[e.peerId];
        if (t == null) return;
        t._typingTimer?.cancel();
        t.peerTyping = e.typing;
        if (e.typing) {
          // Sans nouvel événement, on cesse d'afficher au bout de quelques secondes.
          t._typingTimer = Timer(typingTimeout, () {
            t.peerTyping = false;
            t.changed();
          });
        }
        t.changed();
      case RelationsChanged():
        await refreshConversations();
      default:
        break;
    }
  }

  Future<void> _onMessage(MessageEvent e) async {
    final m = await _r.messageById(e.messageId);
    final t = _threads[e.peerId];
    if (m != null && t != null && t.loaded) {
      // Un envoi en cours a le même contenu : l'événement ne le double pas.
      if (e.mine) {
        t.messages = t.messages
            .where(
              (x) =>
                  !(x.isLocal &&
                      x.state == SendState.sending &&
                      x.text == m.text &&
                      x.kind == m.kind),
            )
            .toList();
      }
      _merge(t, m);
      t.peerTyping = e.isNew && !e.mine ? false : t.peerTyping;
      t.changed();
    } else if (m == null && t != null) {
      // Supprimé pour moi depuis un autre appareil.
      _remove(t, e.messageId);
      t.changed();
    }
    if (e.isNew && !e.mine && m != null) {
      final watching = _activeFriendId == e.peerId && _b.friends.isAppActive;
      if (watching) {
        await markRead(e.peerId);
      } else {
        await _notify(e.peerId, m);
      }
    }
    unawaited(refreshConversations().catchError((Object _) {}));
  }

  /// Notification d'un nouveau message (sauf discussion en silence).
  Future<void> _notify(String friendId, ChatMessage m) async {
    if (!_notified.add(m.id)) return;
    final known = [
      ..._conversations,
      ..._archived,
    ].where((c) => c.friendId == friendId);
    if (known.any((c) => c.muted)) return;
    final me = _b.auth.currentUser;
    if (me == null) return;
    var name = 'Un ami';
    for (final f in _b.friends.friends) {
      if (f.id == friendId) name = f.name;
    }
    final preview = m.preview;
    final body = preview.length > 140
        ? '${preview.substring(0, 140)}…'
        : preview;
    await _b.notifications.notify(
      me.id,
      NotificationType.friend,
      name,
      body,
      route: route,
      refId: friendId,
    );
    try {
      await _b.notifier.show((m.id.hashCode) & 0x7fffffff, name, body);
    } catch (_) {}
  }
}
