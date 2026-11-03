// Faux serveur de la fonction Amis, pour tester toute la logique sans réseau.
//
// Il reproduit les règles de `supabase/schema.sql` : un compte par e-mail,
// demandes qui ne révèlent rien, amitié acceptée des deux côtés, présence à
// l'heure du serveur, un message par heure et par ami. Plusieurs « téléphones »
// (un `FakeFriendsRemote` chacun) se parlent à travers le même serveur.
import 'dart:async';

import 'package:gymflow/core/errors.dart';
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
  DateTime? lastSeen;
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

class FakeFriendsServer {
  FakeFriendsServer({DateTime Function()? clock})
    : clock = clock ?? (() => DateTime.utc(2026, 11, 3, 10));

  /// Horloge du serveur (indépendante de celle des téléphones).
  DateTime Function() clock;

  final Map<String, _Account> _byEmail = {};
  final List<_Friendship> _friendships = [];
  final List<_Poke> _pokes = [];
  final Map<String, FakeFriendsRemote> _remotes = {};
  int _n = 0;

  /// Panne simulée : toute requête échoue avec ce message.
  String? failWith;

  int get accountCount => _byEmail.length;
  int get friendshipCount => _friendships.length;
  int get pokeCount => _pokes.length;

  bool accountExists(String email) =>
      _byEmail.containsKey(email.trim().toLowerCase());

  bool isEnabled(String email) =>
      _byEmail[email.trim().toLowerCase()]?.enabled ?? false;

  String? lastSeenOf(String email) =>
      _byEmail[email.trim().toLowerCase()]?.lastSeen?.toIso8601String();

  String passwordOf(String email) =>
      _byEmail[email.trim().toLowerCase()]!.password;

  FakeFriendsRemote phone() => FakeFriendsRemote(this);

  _Account _acct(String id) => _byEmail.values.firstWhere((a) => a.id == id);

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

  Iterable<String> _friendsOf(String id) => _friendships
      .where(
        (f) =>
            f.status == 'accepted' && (f.requester == id || f.addressee == id),
      )
      .map((f) => f.requester == id ? f.addressee : f.requester);

  void _presence(_Account a) {
    for (final f in _friendsOf(a.id)) {
      _push(f, PresenceChanged(a.id, a.lastSeen));
    }
  }
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
  Future<void> signIn({
    required String email,
    required String password,
    required String displayName,
  }) async {
    _count('signIn');
    final key = email.trim().toLowerCase();
    var a = server._byEmail[key];
    if (a == null) {
      a = _Account('sb_${++server._n}', key, password, displayName);
      server._byEmail[key] = a;
    } else if (a.password != password) {
      throw const BusinessRuleException(
        'Mot de passe refusé par le service Amis.',
      );
    }
    _uid = a.id;
    server._remotes[a.id] = this;
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

  @override
  Future<DateTime> heartbeat() async {
    _count('heartbeat');
    final a = _me;
    if (a.enabled) {
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
    a.lastSeen = null;
    server._presence(a);
  }

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
  Future<void> sendRequest(String email) async {
    _count('sendRequest');
    final me = _me;
    if (!me.enabled) throw const BusinessRuleException('friends_disabled');
    final target = server._byEmail[email.trim().toLowerCase()];
    // Comme le serveur réel : même réponse que l'adresse existe ou non.
    if (target == null || !target.enabled || target.id == me.id) return;
    final reverse = server._friendships.where(
      (f) =>
          f.requester == target.id &&
          f.addressee == me.id &&
          f.status == 'pending',
    );
    if (reverse.isNotEmpty) {
      reverse.first.status = 'accepted';
      server._push(target.id, RequestAccepted(me.id));
      return;
    }
    final exists = server._friendships.any(
      (f) =>
          (f.requester == me.id && f.addressee == target.id) ||
          (f.requester == target.id && f.addressee == me.id),
    );
    if (exists) return;
    final f = _Friendship(
      'fr_${++server._n}',
      me.id,
      target.id,
      server.clock(),
    );
    server._friendships.add(f);
    server._push(target.id, RequestReceived(f.id));
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
    if (accept) server._push(f.requester, RequestAccepted(me.id));
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
          now.difference(p.createdAt) < const Duration(hours: 1),
    );
    if (recent) {
      throw const BusinessRuleException('Doucement : un message par heure.');
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
    server._friendships.removeWhere(
      (f) => f.requester == me.id || f.addressee == me.id,
    );
    me.enabled = false;
    me.lastSeen = null;
    for (final o in others) {
      server._push(o, const RelationsChanged());
    }
  }

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
