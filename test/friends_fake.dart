// Faux serveur de la fonction Amis et de la messagerie, pour tester toute la
// logique sans réseau.
//
// Il reproduit les règles de `supabase/` : un compte par e-mail, invitations
// (« aucun compte » si l'adresse est inconnue), amitié acceptée des deux
// côtés, présence à l'heure du serveur, mode invisible, messages (suppression
// pour moi / pour tous, archivage, silence, « vu » et « en train d'écrire »
// avec réciprocité), blocage discret et signalements pour l'administrateur.
// Plusieurs « téléphones » (un `FakeFriendsRemote` chacun) se parlent à
// travers le même serveur.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:gymflow/core/errors.dart';
import 'package:gymflow/models/chat.dart';
import 'package:gymflow/models/friends.dart';
import 'package:gymflow/services/friends/friends_remote.dart';

class _Account {
  _Account(this.id, this.email, this.password, this.name);
  final String id;
  final String email;
  String password;
  String name;
  String? avatar;
  bool enabled = false;
  bool online = false;
  bool invisible = false;
  bool hideReceipts = false;
  bool hideTyping = false;
  bool pushPreview = true;
  DateTime? lastSeen;
  bool get isAdmin => email == 'admin@gymflow.tn';
}

class _Friendship {
  _Friendship(this.id, this.requester, this.addressee, this.createdAt);
  final String id;
  final String requester;
  final String addressee;
  String status = 'pending';
  final DateTime createdAt;
}

class _Poke {
  _Poke(this.id, this.sender, this.recipient, this.kind, this.createdAt);
  final String id;
  final String sender;
  final String recipient;
  final PokeKind kind;
  final DateTime createdAt;
  bool seen = false;
}

class _Msg {
  _Msg(this.id, this.sender, this.recipient, this.kind, this.body, this.at);
  final String id;
  final String sender;
  final String recipient;
  final MessageKind kind;
  String body;
  final DateTime at;
  DateTime? deletedAt;
  final Set<String> deletedFor = {};
}

class _Conv {
  bool archived = false;
  bool muted = false;
  bool hideReceipts = false;
  bool hideTyping = false;
  DateTime cleared = DateTime.utc(1970);
  DateTime lastRead = DateTime.utc(1970);
}

class _Report {
  _Report({
    required this.id,
    required this.reporter,
    required this.reported,
    required this.kind,
    required this.remark,
    required this.messages,
    required this.at,
  });
  final String id;
  final String reporter;
  final String reported;
  final String kind;
  final String? remark;
  final List<ReportedMessage> messages;
  final DateTime at;
  bool handled = false;
  DateTime? handledAt;
  String? note;
}

class FakeFriendsServer {
  FakeFriendsServer({DateTime Function()? clock})
    : clock = clock ?? (() => DateTime.utc(2026, 11, 3, 10));

  /// Horloge du serveur (indépendante de celle des téléphones).
  DateTime Function() clock;

  final Map<String, _Account> _byEmail = {};
  final List<_Friendship> _friendships = [];
  final List<_Poke> _pokes = [];
  final List<_Msg> _messages = [];
  final Map<String, _Conv> _convs = {};
  final Map<String, DateTime> _reads = {};
  final Set<String> _blocks = {};
  final List<_Report> _reports = [];
  final Map<String, FakeFriendsRemote> _remotes = {};
  int _n = 0;
  int _tick = 0;

  /// Jetons de notification enregistrés (jeton → identifiant du compte).
  final Map<String, String> pushTokens = {};

  /// Panne simulée : toute requête échoue avec ce message.
  String? failWith;

  /// Heure du serveur strictement croissante (un message envoyé après un
  /// autre a toujours une heure plus récente, même si l'horloge est figée).
  DateTime stamp() => clock().add(Duration(microseconds: ++_tick));

  int get accountCount => _byEmail.length;
  int get friendshipCount => _friendships.length;
  int get pokeCount => _pokes.length;
  int get messageCount => _messages.length;
  int get reportCount => _reports.length;
  int get blockCount => _blocks.length;

  /// Contenu brut des messages enregistrés (pour vérifier ce qui est stocké).
  List<String> get storedBodies => [for (final m in _messages) m.body];

  bool accountExists(String email) =>
      _byEmail.containsKey(email.trim().toLowerCase());

  bool isEnabled(String email) =>
      _byEmail[email.trim().toLowerCase()]?.enabled ?? false;

  bool isInvisible(String email) =>
      _byEmail[email.trim().toLowerCase()]?.invisible ?? false;

  String? lastSeenOf(String email) =>
      _byEmail[email.trim().toLowerCase()]?.lastSeen?.toIso8601String();

  bool isOnlineOnServer(String email) =>
      _byEmail[email.trim().toLowerCase()]?.online ?? false;

  String passwordOf(String email) =>
      _byEmail[email.trim().toLowerCase()]!.password;

  /// Compte créé par l'ancien système (mot de passe GymFlow côté serveur).
  void seedLegacyAccount(String email, String password, String name) {
    final key = email.trim().toLowerCase();
    _byEmail[key] = _Account('sb_${++_n}', key, password, name);
  }

  FakeFriendsRemote phone() => FakeFriendsRemote(this);

  _Account _acct(String id) => _byEmail.values.firstWhere((a) => a.id == id);

  String _key(String a, String b) => '$a|$b';
  _Conv _conv(String user, String friend) =>
      _convs.putIfAbsent(_key(user, friend), _Conv.new);

  void _push(String userId, FriendsEvent e) {
    final r = _remotes[userId];
    if (r != null && r._subscribed) r._events.add(e);
  }

  bool areFriends(String a, String b) => _friendships.any(
    (f) =>
        f.status == 'accepted' &&
        ((f.requester == a && f.addressee == b) ||
            (f.requester == b && f.addressee == a)),
  );

  bool isBlockedBy(String blocker, String blocked) =>
      _blocks.contains(_key(blocker, blocked));

  Iterable<String> _friendsOf(String id) => _friendships
      .where(
        (f) =>
            f.status == 'accepted' && (f.requester == id || f.addressee == id),
      )
      .map((f) => f.requester == id ? f.addressee : f.requester);

  void _presence(_Account a) {
    for (final f in _friendsOf(a.id)) {
      _push(f, PresenceChanged(a.id, a.online, a.lastSeen));
    }
  }

  /// Le message est-il visible pour [me] dans la discussion avec [peer] ?
  bool _visible(_Msg m, String me, String peer) {
    if (m.deletedFor.contains(me)) return false;
    return m.at.isAfter(_conv(me, peer).cleared);
  }

  ChatMessage _toChat(_Msg m, String me) => ChatMessage(
    id: m.id,
    peerId: m.sender == me ? m.recipient : m.sender,
    mine: m.sender == me,
    kind: m.kind,
    text: m.deletedAt == null ? m.body : null,
    createdAt: m.at,
    deleted: m.deletedAt != null,
  );
}

class FakeFriendsRemote implements FriendsRemote {
  FakeFriendsRemote(this.server);
  final FakeFriendsServer server;
  String? _uid;
  bool _subscribed = false;
  bool _restorable = false;
  final StreamController<FriendsEvent> _events =
      StreamController<FriendsEvent>.broadcast();

  /// Nombre d'appels de chaque méthode (vérifications des tests).
  final Map<String, int> calls = {};
  void _count(String name) {
    calls[name] = (calls[name] ?? 0) + 1;
    final f = server.failWith;
    if (f != null) throw BusinessRuleException(f);
  }

  _Account get _me => server._acct(_uid!);

  @override
  String? get userId => _uid;

  @override
  String? get userEmail => _uid == null ? null : _me.email;

  @override
  Stream<FriendsEvent> get events => _events.stream;

  /// Simule une session du serveur conservée sur le téléphone.
  void keepSessionFor(String email) {
    _uid = server._byEmail[email.toLowerCase()]!.id;
    server._remotes[_uid!] = this;
    _restorable = true;
  }

  @override
  Future<bool> restore() async {
    _count('restore');
    return _restorable && _uid != null;
  }

  @override
  Future<RemoteSignIn> signIn({
    required String email,
    required String password,
    required String displayName,
    bool create = false,
  }) async {
    _count('signIn');
    final key = email.trim().toLowerCase();
    var a = server._byEmail[key];
    var created = false;
    if (a == null) {
      if (!create) return RemoteSignIn.refused;
      a = _Account('sb_${++server._n}', key, password, displayName);
      server._byEmail[key] = a;
      created = true;
    } else if (a.password != password) {
      return RemoteSignIn.refused;
    }
    _uid = a.id;
    server._remotes[a.id] = this;
    return created ? RemoteSignIn.created : RemoteSignIn.signedIn;
  }

  @override
  Future<void> signOut() async {
    _count('signOut');
    final id = _uid;
    if (id != null) server._remotes.remove(id);
    _uid = null;
    _subscribed = false;
    _restorable = false;
  }

  @override
  Future<void> updatePassword(String password) async {
    _count('updatePassword');
    _me.password = password;
  }

  @override
  Future<void> updateProfile({
    required String displayName,
    required bool enabled,
    String? avatarUrl,
  }) async {
    _count('updateProfile');
    final a = _me;
    a.name = displayName;
    a.avatar = avatarUrl;
    a.enabled = enabled;
  }

  // ------------------------------------------------------------ Présence

  @override
  Future<DateTime> heartbeat() async {
    _count('heartbeat');
    final a = _me;
    if (a.enabled && !a.invisible) {
      a.online = true;
      a.lastSeen = server.clock();
      server._presence(a);
    }
    return server.clock();
  }

  @override
  Future<void> goOffline() async {
    _count('goOffline');
    if (_uid == null) return;
    final a = _me;
    // On garde lastSeen : les amis voient « Vu il y a 5 min ».
    if (a.online) {
      a.online = false;
      server._presence(a);
    }
  }

  @override
  Future<void> setInvisible(bool invisible) async {
    _count('setInvisible');
    final a = _me;
    a.invisible = invisible;
    if (invisible) {
      a.online = false;
      a.lastSeen = null;
    } else if (a.enabled) {
      a.online = true;
      a.lastSeen = server.clock();
    }
    server._presence(a);
  }

  @override
  Future<ChatSettings> loadSettings() async {
    _count('loadSettings');
    final a = _me;
    return ChatSettings(
      invisible: a.invisible,
      hideReadReceipts: a.hideReceipts,
      hideTyping: a.hideTyping,
      pushPreview: a.pushPreview,
      isAdmin: a.isAdmin,
    );
  }

  @override
  Future<void> setChatSettings({
    required bool hideReadReceipts,
    required bool hideTyping,
    required bool pushPreview,
  }) async {
    _count('setChatSettings');
    final a = _me;
    a.hideReceipts = hideReadReceipts;
    a.hideTyping = hideTyping;
    a.pushPreview = pushPreview;
    if (hideReadReceipts) {
      server._reads.removeWhere((k, _) => k.startsWith('${a.id}|'));
    }
  }

  // --------------------------------------------------------------- Amis

  @override
  Future<FriendsSnapshot> loadFriends() async {
    _count('loadFriends');
    final me = _me;
    final list = <Friend>[];
    for (final f in server._friendships.where(
      (f) =>
          f.status == 'accepted' &&
          (f.requester == me.id || f.addressee == me.id),
    )) {
      final other = server._acct(
        f.requester == me.id ? f.addressee : f.requester,
      );
      list.add(
        Friend(
          id: other.id,
          name: other.name,
          avatarUrl: other.avatar,
          online: other.online,
          lastSeen: other.lastSeen,
          since: f.createdAt,
        ),
      );
    }
    list.sort((a, b) => a.name.compareTo(b.name));
    return FriendsSnapshot(friends: list, serverNow: server.clock());
  }

  @override
  Future<List<FriendRequest>> loadRequests() async {
    _count('loadRequests');
    final me = _me;
    return [
      for (final f in server._friendships.where(
        (f) => f.status == 'pending' && f.addressee == me.id,
      ))
        FriendRequest(
          id: f.id,
          fromName: server._acct(f.requester).name,
          avatarUrl: server._acct(f.requester).avatar,
          createdAt: f.createdAt,
        ),
    ];
  }

  @override
  Future<List<SentRequest>> loadSentRequests() async {
    _count('loadSentRequests');
    final me = _me;
    // Une invitation refusée reste « en attente » pour son auteur.
    return [
      for (final f in server._friendships.where(
        (f) => f.requester == me.id && f.status != 'accepted',
      ))
        SentRequest(
          id: f.id,
          toName: server._acct(f.addressee).name,
          avatarUrl: server._acct(f.addressee).avatar,
          createdAt: f.createdAt,
        ),
    ];
  }

  @override
  Future<SendResult> sendRequest(String email) async {
    _count('sendRequest');
    final me = _me;
    if (!me.enabled) throw const BusinessRuleException('friends_disabled');
    final target = server._byEmail[email.trim().toLowerCase()];
    if (target == null || !target.enabled || target.id == me.id) {
      throw const BusinessRuleException(
        'Aucun compte avec cette adresse. Votre ami doit avoir activé la '
        'fonction Amis.',
      );
    }
    if (server.isBlockedBy(me.id, target.id)) {
      throw const BusinessRuleException(
        'Vous avez bloqué cette personne. Débloquez-la dans Mes amis pour '
        "l'inviter.",
      );
    }
    if (server.isBlockedBy(target.id, me.id)) {
      // Faux envoi : l'invitation reste « en attente » sans jamais arriver.
      final f = _Friendship(
        'fr_${++server._n}',
        me.id,
        target.id,
        server.clock(),
      )..status = 'declined';
      server._friendships.add(f);
      return SendResult.sent;
    }
    final existing = server._friendships.where(
      (f) =>
          (f.requester == me.id && f.addressee == target.id) ||
          (f.requester == target.id && f.addressee == me.id),
    );
    if (existing.isNotEmpty) {
      final f = existing.first;
      if (f.status == 'accepted') return SendResult.alreadyFriends;
      if (f.status == 'pending') {
        if (f.requester == target.id) {
          f.status = 'accepted';
          server._push(target.id, RequestAccepted(me.id));
          return SendResult.accepted;
        }
        return SendResult.alreadyPending;
      }
      return SendResult.sent; // refusée : l'auteur n'en sait rien
    }
    final f = _Friendship(
      'fr_${++server._n}',
      me.id,
      target.id,
      server.clock(),
    );
    server._friendships.add(f);
    server._push(target.id, RequestReceived(f.id));
    return SendResult.sent;
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    _count('cancelRequest');
    final me = _me;
    final f = server._friendships.firstWhere(
      (f) =>
          f.id == requestId && f.requester == me.id && f.status != 'accepted',
      orElse: () => throw const BusinessRuleException('not_found'),
    );
    server._friendships.remove(f);
    server._push(f.addressee, const RelationsChanged());
  }

  @override
  Future<void> respond(String requestId, bool accept) async {
    _count('respond');
    final me = _me;
    final f = server._friendships.firstWhere(
      (f) => f.id == requestId && f.addressee == me.id && f.status == 'pending',
      orElse: () => throw const BusinessRuleException('not_found'),
    );
    f.status = accept ? 'accepted' : 'declined';
    if (accept) {
      server._push(f.requester, RequestAccepted(me.id));
    } else {
      server._push(f.requester, const RelationsChanged());
    }
  }

  @override
  Future<void> removeFriend(String friendId) async {
    _count('removeFriend');
    final me = _me;
    server._friendships.removeWhere(
      (f) =>
          f.status == 'accepted' &&
          ((f.requester == me.id && f.addressee == friendId) ||
              (f.requester == friendId && f.addressee == me.id)),
    );
    server._push(friendId, const RelationsChanged());
  }

  @override
  Future<void> sendPoke(String toId, PokeKind kind) async {
    _count('sendPoke');
    final me = _me;
    if (!server.areFriends(me.id, toId)) {
      throw const BusinessRuleException(
        'Cette personne n\'est plus votre ami.',
      );
    }
    final now = server.clock();
    final recent = server._pokes.any(
      (p) =>
          p.sender == me.id &&
          p.recipient == toId &&
          now.difference(p.createdAt) < const Duration(minutes: 1),
    );
    if (recent) {
      throw const BusinessRuleException('Doucement : un message par minute.');
    }
    final p = _Poke('pk_${++server._n}', me.id, toId, kind, now);
    server._pokes.add(p);
    server._push(
      toId,
      PokeReceived(
        IncomingPoke(id: p.id, senderId: me.id, kind: kind, createdAt: now),
      ),
    );
  }

  @override
  Future<List<IncomingPoke>> unseenPokes() async {
    _count('unseenPokes');
    final me = _me;
    return [
      for (final p in server._pokes.where(
        (p) => p.recipient == me.id && !p.seen,
      ))
        IncomingPoke(
          id: p.id,
          senderId: p.sender,
          kind: p.kind,
          createdAt: p.createdAt,
        ),
    ];
  }

  @override
  Future<void> markPokesSeen(List<String> ids) async {
    _count('markPokesSeen');
    for (final p in server._pokes.where((p) => ids.contains(p.id))) {
      p.seen = true;
    }
  }

  @override
  Future<void> leave() async {
    _count('leave');
    final me = _me;
    final others = server._friendsOf(me.id).toList();
    server._pokes.removeWhere((p) => p.sender == me.id || p.recipient == me.id);
    server._messages.removeWhere(
      (m) => m.sender == me.id || m.recipient == me.id,
    );
    server._convs.removeWhere(
      (k, _) => k.startsWith('${me.id}|') || k.endsWith('|${me.id}'),
    );
    server._reads.removeWhere(
      (k, _) => k.startsWith('${me.id}|') || k.endsWith('|${me.id}'),
    );
    server._blocks.removeWhere((k) => k.startsWith('${me.id}|'));
    server._friendships.removeWhere(
      (f) => f.requester == me.id || f.addressee == me.id,
    );
    me.enabled = false;
    me.online = false;
    me.invisible = false;
    me.hideReceipts = false;
    me.hideTyping = false;
    me.pushPreview = true;
    me.lastSeen = null;
    for (final o in others) {
      server._push(o, const RelationsChanged());
    }
  }

  @override
  Future<void> deleteAccount() async {
    _count('deleteAccount');
    final me = _me;
    await leave();
    server._byEmail.remove(me.email);
    await signOut();
  }

  // ------------------------------------------------------------ Messagerie

  @override
  Future<String> sendMessage(String toId, MessageKind kind, String body) async {
    _count('sendMessage');
    final me = _me;
    if (body.trim().isEmpty)
      throw const BusinessRuleException('Écrivez un message.');
    if (kind == MessageKind.text && body.length > 1000) {
      throw const BusinessRuleException(
        'Message trop long (1 000 caractères au plus).',
      );
    }
    if (!server.areFriends(me.id, toId)) {
      throw const BusinessRuleException(
        'Cette personne n\'est plus votre ami.',
      );
    }
    final m = _Msg('m_${++server._n}', me.id, toId, kind, body, server.stamp());
    server._messages.add(m);
    server._conv(me.id, toId).archived = false;
    server._conv(toId, me.id).archived = false;
    server._push(
      toId,
      MessageEvent(messageId: m.id, peerId: me.id, mine: false, isNew: true),
    );
    server._push(
      me.id,
      MessageEvent(messageId: m.id, peerId: toId, mine: true, isNew: true),
    );
    return m.id;
  }

  @override
  Future<List<ChatMessage>> loadMessages(
    String friendId, {
    DateTime? before,
    int limit = 50,
  }) async {
    _count('loadMessages');
    final me = _me;
    if (!server.areFriends(me.id, friendId)) {
      throw const BusinessRuleException(
        'Cette personne n\'est plus votre ami.',
      );
    }
    final list =
        server._messages
            .where(
              (m) =>
                  ((m.sender == me.id && m.recipient == friendId) ||
                      (m.sender == friendId && m.recipient == me.id)) &&
                  server._visible(m, me.id, friendId) &&
                  (before == null || m.at.isBefore(before)),
            )
            .toList()
          ..sort((a, b) => b.at.compareTo(a.at));
    return [for (final m in list.take(limit)) server._toChat(m, me.id)];
  }

  @override
  Future<ChatMessage?> messageById(String id) async {
    _count('messageById');
    final me = _me;
    for (final m in server._messages) {
      if (m.id != id) continue;
      if (m.sender != me.id && m.recipient != me.id) return null;
      if (m.deletedFor.contains(me.id)) return null;
      return server._toChat(m, me.id);
    }
    return null;
  }

  @override
  Future<List<Conversation>> loadConversations({bool archived = false}) async {
    _count('loadConversations');
    final me = _me;
    final out = <Conversation>[];
    for (final fid in server._friendsOf(me.id)) {
      final conv = server._conv(me.id, fid);
      if (conv.archived != archived) continue;
      final msgs =
          server._messages
              .where(
                (m) =>
                    ((m.sender == me.id && m.recipient == fid) ||
                        (m.sender == fid && m.recipient == me.id)) &&
                    server._visible(m, me.id, fid),
              )
              .toList()
            ..sort((a, b) => b.at.compareTo(a.at));
      if (msgs.isEmpty) continue;
      final last = server._toChat(msgs.first, me.id);
      final other = server._acct(fid);
      out.add(
        Conversation(
          friendId: fid,
          friendName: other.name,
          avatarUrl: other.avatar,
          lastAt: last.createdAt,
          lastMine: last.mine,
          lastPreview: last.preview,
          unread: msgs
              .where(
                (m) =>
                    m.recipient == me.id &&
                    m.deletedAt == null &&
                    m.at.isAfter(conv.lastRead),
              )
              .length,
          muted: conv.muted,
          archived: conv.archived,
        ),
      );
    }
    out.sort((a, b) => b.lastAt.compareTo(a.lastAt));
    return out;
  }

  @override
  Future<ChatInfo> conversationInfo(String friendId) async {
    _count('conversationInfo');
    final me = _me;
    final other = server._acct(friendId);
    final conv = server._conv(me.id, friendId);
    final otherConv = server._conv(friendId, me.id);
    DateTime? read;
    if (!me.hideReceipts &&
        !other.hideReceipts &&
        !conv.hideReceipts &&
        !otherConv.hideReceipts) {
      read = server._reads[server._key(friendId, me.id)];
    }
    return ChatInfo(
      peerReadAt: read,
      muted: conv.muted,
      archived: conv.archived,
      hideReceipts: conv.hideReceipts,
      hideTyping: conv.hideTyping,
    );
  }

  @override
  Future<void> markRead(String friendId) async {
    _count('markRead');
    final me = _me;
    if (!server.areFriends(me.id, friendId)) {
      throw const BusinessRuleException(
        'Cette personne n\'est plus votre ami.',
      );
    }
    final now = server.stamp();
    server._conv(me.id, friendId).lastRead = now;
    if (!me.hideReceipts && !server._conv(me.id, friendId).hideReceipts) {
      server._reads[server._key(me.id, friendId)] = now;
      final other = server._acct(friendId);
      if (!other.hideReceipts &&
          !server._conv(friendId, me.id).hideReceipts) {
        server._push(friendId, ReadMarkChanged(me.id, now));
      }
    }
  }

  @override
  Future<void> setTyping(String friendId, bool typing) async {
    _count('setTyping');
    final me = _me;
    if (me.hideTyping || !server.areFriends(me.id, friendId)) return;
    if (server._conv(me.id, friendId).hideTyping) return;
    final other = server._acct(friendId);
    if (!other.hideTyping && !server._conv(friendId, me.id).hideTyping) {
      server._push(friendId, TypingChanged(me.id, typing));
    }
  }

  @override
  Future<void> deleteMessage(String messageId, {required bool forAll}) async {
    _count('deleteMessage');
    final me = _me;
    final m = server._messages.firstWhere(
      (m) => m.id == messageId && (m.sender == me.id || m.recipient == me.id),
      orElse: () => throw const BusinessRuleException('not_found'),
    );
    final peer = m.sender == me.id ? m.recipient : m.sender;
    if (forAll) {
      if (m.sender != me.id) {
        throw const BusinessRuleException(
          "Seul l'auteur peut supprimer un message pour tout le monde.",
        );
      }
      m.deletedAt ??= server.stamp();
      m.body = '';
      server._push(
        peer,
        MessageEvent(messageId: m.id, peerId: me.id, mine: false, isNew: false),
      );
    } else {
      m.deletedFor.add(me.id);
    }
  }

  @override
  Future<void> clearConversation(String friendId) async {
    _count('clearConversation');
    final me = _me;
    final conv = server._conv(me.id, friendId);
    conv.cleared = server.stamp();
    conv.lastRead = conv.cleared;
    conv.archived = false;
  }

  @override
  Future<void> setArchived(String friendId, bool archived) async {
    _count('setArchived');
    server._conv(_me.id, friendId).archived = archived;
  }

  @override
  Future<void> setMuted(String friendId, bool muted) async {
    _count('setMuted');
    server._conv(_me.id, friendId).muted = muted;
  }

  @override
  Future<void> setChatPrivacy(
    String friendId, {
    required bool hideReceipts,
    required bool hideTyping,
  }) async {
    _count('setChatPrivacy');
    final conv = server._conv(_me.id, friendId);
    conv.hideReceipts = hideReceipts;
    conv.hideTyping = hideTyping;
  }

  @override
  Future<Map<String, String>> friendEmailHashes() async {
    _count('friendEmailHashes');
    final me = _me;
    return {
      for (final a in server._byEmail.values)
        if (a.id == me.id || server.areFriends(me.id, a.id))
          a.id: sha256.convert(utf8.encode(a.email)).toString(),
    };
  }

  // ------------------------------------------- Blocage et signalements

  @override
  Future<void> blockUser(String userId) async {
    _count('blockUser');
    final me = _me;
    server._blocks.add(server._key(me.id, userId));
    server._friendships.removeWhere(
      (f) =>
          (f.requester == me.id && f.addressee == userId) ||
          (f.requester == userId && f.addressee == me.id),
    );
    server._reads.remove(server._key(me.id, userId));
    server._reads.remove(server._key(userId, me.id));
    // Pour l'autre, c'est comme un retrait d'ami : rien ne dit qui a bloqué.
    server._push(userId, const RelationsChanged());
  }

  @override
  Future<void> unblockUser(String userId) async {
    _count('unblockUser');
    server._blocks.remove(server._key(_me.id, userId));
  }

  @override
  Future<List<BlockedUser>> loadBlocks() async {
    _count('loadBlocks');
    final me = _me;
    return [
      for (final k in server._blocks.where((k) => k.startsWith('${me.id}|')))
        BlockedUser(
          id: k.split('|')[1],
          name: server._acct(k.split('|')[1]).name,
        ),
    ];
  }

  @override
  Future<void> reportConversation(
    String friendId,
    List<String> messageIds, {
    String? remark,
    bool alsoBlock = false,
  }) async {
    _count('reportConversation');
    final me = _me;
    if (messageIds.isEmpty) {
      throw const BusinessRuleException('Sélectionnez au moins un message.');
    }
    if (!server.areFriends(me.id, friendId)) {
      throw const BusinessRuleException(
        'Cette personne n\'est plus votre ami.',
      );
    }
    final other = server._acct(friendId);
    final picked =
        server._messages
            .where(
              (m) =>
                  messageIds.contains(m.id) &&
                  ((m.sender == me.id && m.recipient == friendId) ||
                      (m.sender == friendId && m.recipient == me.id)),
            )
            .toList()
          ..sort((a, b) => a.at.compareTo(b.at));
    if (picked.isEmpty) {
      throw const BusinessRuleException('Sélectionnez au moins un message.');
    }
    final recent = server._reports
        .where((r) => r.reporter == me.id && r.reported == friendId)
        .length;
    if (recent >= 3) {
      throw const BusinessRuleException('Doucement : trop de signalements.');
    }
    server._reports.add(
      _Report(
        id: 'rp_${++server._n}',
        reporter: me.id,
        reported: friendId,
        kind: 'discussion',
        remark: (remark == null || remark.trim().isEmpty)
            ? null
            : remark.trim(),
        at: server.stamp(),
        messages: [
          for (final m in picked)
            ReportedMessage(
              from: m.sender == me.id ? me.name : other.name,
              mine: m.sender == me.id,
              at: m.at,
              kind: m.kind,
              text: m.deletedAt == null ? m.body : null,
            ),
        ],
      ),
    );
    if (alsoBlock) {
      await blockUser(friendId);
    }
  }

  @override
  Future<void> reportPerson(String friendId, String remark) async {
    _count('reportPerson');
    final me = _me;
    if (remark.trim().length < 5) {
      throw const BusinessRuleException(
        'Décrivez le problème en 5 caractères au moins.',
      );
    }
    if (!server.areFriends(me.id, friendId)) {
      throw const BusinessRuleException(
        'Cette personne n\'est plus votre ami.',
      );
    }
    server._reports.add(
      _Report(
        id: 'rp_${++server._n}',
        reporter: me.id,
        reported: friendId,
        kind: 'personne',
        remark: remark.trim(),
        messages: const [],
        at: server.stamp(),
      ),
    );
  }

  void _requireAdmin() {
    if (!_me.isAdmin) {
      throw const BusinessRuleException(
        "Ce compte n'est pas reconnu comme administrateur.",
      );
    }
  }

  @override
  Future<List<ReportEntry>> adminLoadReports({bool? handled}) async {
    _count('adminLoadReports');
    _requireAdmin();
    return [
      for (final r in server._reports.reversed)
        if (handled == null || r.handled == handled)
          ReportEntry(
            id: r.id,
            isConversation: r.kind == 'discussion',
            handled: r.handled,
            createdAt: r.at,
            reporterName: server._acct(r.reporter).name,
            reportedName: server._acct(r.reported).name,
            remark: r.remark,
            messages: r.messages,
            handledAt: r.handledAt,
            handledNote: r.note,
          ),
    ];
  }

  @override
  Future<void> adminHandleReport(String reportId, {String? note}) async {
    _count('adminHandleReport');
    _requireAdmin();
    final r = server._reports.firstWhere(
      (r) => r.id == reportId,
      orElse: () => throw const BusinessRuleException('not_found'),
    );
    r.handled = true;
    r.handledAt = server.stamp();
    r.note = (note == null || note.trim().isEmpty) ? null : note.trim();
  }

  @override
  Future<int> adminNewReportsCount() async {
    _count('adminNewReportsCount');
    _requireAdmin();
    return server._reports.where((r) => !r.handled).length;
  }

  // ----------------------------------------------------------- Notifications

  @override
  Future<void> registerPushToken(String token) async {
    _count('registerPushToken');
    server.pushTokens[token] = _me.id;
  }

  @override
  Future<void> unregisterPushToken(String token) async {
    _count('unregisterPushToken');
    if (_uid != null && server.pushTokens[token] == _uid) {
      server.pushTokens.remove(token);
    }
  }

  // ------------------------------------------------------------ Temps réel

  @override
  Future<void> subscribe() async {
    _count('subscribe');
    _subscribed = true;
  }

  @override
  Future<void> unsubscribe() async {
    _subscribed = false;
  }
}
