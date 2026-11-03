import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors.dart';
import '../../models/friends.dart';
import 'friends_remote.dart';

/// Fonction Amis sur **Supabase** (Postgres + Auth + Realtime).
///
/// Les règles d'accès sont dans la base (`supabase/schema.sql`) : cette
/// classe ne fait que parler au serveur avec la clé publique de l'application.
class SupabaseFriendsRemote implements FriendsRemote {
  SupabaseFriendsRemote({
    required this.url,
    required this.anonKey,
    SupabaseClient? client,
  }) : _client = client; // ignore: prefer_initializing_formals

  final String url;
  final String anonKey;
  SupabaseClient? _client;
  RealtimeChannel? _channel;
  final StreamController<FriendsEvent> _events =
      StreamController<FriendsEvent>.broadcast();

  /// Le client n'est créé qu'à la première utilisation : sans la fonction
  /// Amis, l'application ne contacte jamais Supabase.
  Future<SupabaseClient> _c() async {
    final existing = _client;
    if (existing != null) return existing;
    try {
      await Supabase.initialize(url: url, publishableKey: anonKey);
    } catch (_) {
      // Déjà initialisé (rechargement à chaud, second appel) : on le réutilise.
    }
    return _client = Supabase.instance.client;
  }

  @override
  String? get userId => _client?.auth.currentUser?.id;

  @override
  String? get userEmail => _client?.auth.currentUser?.email;

  @override
  Stream<FriendsEvent> get events => _events.stream;

  // ------------------------------------------------------------- Erreurs

  /// Traduit les erreurs techniques en messages lisibles, sans détail
  /// interne ni jeton.
  Future<T> _run<T>(Future<T> Function() action) async {
    try {
      return await action().timeout(const Duration(seconds: 20));
    } on AppException {
      rethrow;
    } on TimeoutException {
      throw const BusinessRuleException(
        'Le service Amis ne répond pas. Réessayez dans un instant.',
      );
    } on PostgrestException catch (e) {
      throw BusinessRuleException(_postgrestMessage(e));
    } on AuthException catch (e) {
      throw BusinessRuleException(_authMessage(e));
    } catch (_) {
      throw const BusinessRuleException(
        'Impossible de joindre le service Amis. Vérifiez la connexion.',
      );
    }
  }

  static String _postgrestMessage(PostgrestException e) {
    final m = e.message;
    if (m.contains('rate_limited')) {
      return 'Doucement : vous avez déjà envoyé un message à cet ami il y a '
          'moins d\'une minute.';
    }
    if (m.contains('daily_limit')) {
      return "Limite de messages atteinte pour aujourd'hui. Réessayez demain.";
    }
    if (m.contains('not_friends')) {
      return 'Cette personne n\'est plus votre ami.';
    }
    if (m.contains('friends_disabled')) {
      return 'La fonction Amis doit être activée des deux côtés.';
    }
    if (m.contains('invalid_email')) return 'Adresse e-mail invalide.';
    if (m.contains('not_found')) return 'Demande introuvable.';
    if (m.contains('not_authenticated')) {
      return 'Session Amis expirée. Reconnectez-vous à la fonction Amis.';
    }
    if (e.code == '42501') {
      return 'Accès refusé par le service Amis.';
    }
    return 'Le service Amis a répondu une erreur (${e.code ?? 'inconnue'}).';
  }

  static String _authMessage(AuthException e) {
    switch (e.code) {
      case 'invalid_credentials':
        return 'Mot de passe refusé par le service Amis. Si vous avez changé '
            'de mot de passe GymFlow, reconnectez-vous avec l\'ancien.';
      case 'over_request_rate_limit':
      case 'over_email_send_rate_limit':
        return 'Trop de tentatives. Réessayez dans quelques minutes.';
      case 'email_not_confirmed':
        return 'Le service Amis exige la confirmation de l\'e-mail '
            '(désactivez « Confirm email » dans Supabase).';
      case 'weak_password':
        return 'Mot de passe trop faible pour le service Amis.';
    }
    return 'Connexion au service Amis refusée.';
  }

  // ------------------------------------------------------------- Compte

  @override
  Future<bool> restore() => _run(() async {
    final c = await _c();
    return c.auth.currentSession != null && c.auth.currentUser != null;
  });

  @override
  Future<void> signIn({
    required String email,
    required String password,
    required String displayName,
  }) => _run(() async {
    final c = await _c();
    final current = c.auth.currentUser;
    if (current != null &&
        (current.email ?? '').toLowerCase() != email.toLowerCase()) {
      await c.auth.signOut();
    }
    try {
      await c.auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      if (e.code != 'invalid_credentials') rethrow;
      // Compte inconnu du serveur : on le crée. (Supabase répond de la même
      // façon pour un mot de passe faux ; on le distingue juste après.)
      final res = await c.auth.signUp(
        email: email,
        password: password,
        data: {'display_name': displayName},
      );
      if (res.session != null) return;
      final alreadyExists = res.user?.identities?.isEmpty ?? false;
      throw BusinessRuleException(
        alreadyExists
            ? 'Un compte Amis existe déjà pour cette adresse avec un autre '
                  'mot de passe. Utilisez celui de la première connexion.'
            : 'Le service Amis exige la confirmation de l\'e-mail '
                  '(désactivez « Confirm email » dans Supabase).',
      );
    }
  });

  @override
  Future<void> signOut() => _run(() async {
    final c = _client;
    if (c == null) return;
    await _unsubscribe(c);
    await c.auth.signOut();
  });

  @override
  Future<void> updatePassword(String password) => _run(() async {
    final c = await _c();
    if (c.auth.currentUser == null) return;
    await c.auth.updateUser(UserAttributes(password: password));
  });

  @override
  Future<void> updateProfile({
    required String displayName,
    required bool enabled,
    String? avatarUrl,
  }) => _run(() async {
    final c = await _c();
    final me = c.auth.currentUser?.id;
    if (me == null) throw const NotAuthenticatedException();
    await c
        .from('profiles')
        .update({
          'display_name': displayName,
          'avatar_url': avatarUrl,
          'friends_enabled': enabled,
        })
        .eq('id', me);
  });

  // ------------------------------------------------------------ Présence

  @override
  Future<DateTime> heartbeat() => _run(() async {
    final c = await _c();
    final r = await c.rpc('heartbeat');
    return DateTime.parse(r as String);
  });

  @override
  Future<void> goOffline() => _run(() async {
    final c = _client;
    if (c == null || c.auth.currentUser == null) return;
    await c.rpc('go_offline');
  });

  // --------------------------------------------------------------- Amis

  /// Le serveur écrit `1970-01-01` pour « hors ligne ».
  static DateTime? _seen(Object? v) {
    if (v == null) return null;
    final d = DateTime.tryParse('$v');
    if (d == null || d.year <= 1971) return null;
    return d;
  }

  @override
  Future<FriendsSnapshot> loadFriends() => _run(() async {
    final c = await _c();
    final rows = (await c.rpc('my_friends') as List).cast<Map>();
    DateTime? serverNow;
    final friends = <Friend>[];
    for (final r in rows) {
      serverNow ??= DateTime.tryParse('${r['server_now']}');
      friends.add(
        Friend(
          id: r['id'] as String,
          name: r['display_name'] as String,
          avatarUrl: r['avatar_url'] as String?,
          lastSeen: _seen(r['last_seen']),
          since: DateTime.tryParse('${r['since']}') ?? DateTime.now(),
        ),
      );
    }
    return FriendsSnapshot(
      friends: friends,
      serverNow: serverNow ?? DateTime.now().toUtc(),
    );
  });

  @override
  Future<List<FriendRequest>> loadRequests() => _run(() async {
    final c = await _c();
    final rows = (await c.rpc('my_pending_requests') as List).cast<Map>();
    return [
      for (final r in rows)
        FriendRequest(
          id: r['id'] as String,
          fromName: r['from_name'] as String,
          avatarUrl: r['avatar_url'] as String?,
          createdAt: DateTime.tryParse('${r['created_at']}') ?? DateTime.now(),
        ),
    ];
  });

  @override
  Future<void> sendRequest(String email) => _run(() async {
    final c = await _c();
    await c.rpc('send_friend_request', params: {'p_email': email.trim()});
  });

  @override
  Future<void> respond(String requestId, bool accept) => _run(() async {
    final c = await _c();
    await c.rpc(
      'respond_friend_request',
      params: {'p_id': requestId, 'p_accept': accept},
    );
  });

  @override
  Future<void> removeFriend(String friendId) => _run(() async {
    final c = await _c();
    final me = c.auth.currentUser?.id;
    if (me == null) throw const NotAuthenticatedException();
    await c
        .from('friendships')
        .delete()
        .eq('status', 'accepted')
        .or(
          'and(requester.eq.$me,addressee.eq.$friendId),'
          'and(requester.eq.$friendId,addressee.eq.$me)',
        );
  });

  @override
  Future<void> leave() => _run(() async {
    final c = _client;
    if (c == null || c.auth.currentUser == null) return;
    await c.rpc('leave_friends');
  });

  // -------------------------------------------------------------- Pokes

  @override
  Future<void> sendPoke(String toId, PokeKind kind) => _run(() async {
    final c = await _c();
    await c.rpc('send_poke', params: {'p_to': toId, 'p_kind': kind.key});
  });

  static IncomingPoke _poke(Map r) => IncomingPoke(
    id: r['id'] as String,
    senderId: r['sender'] as String,
    kind: PokeKind.fromKey(r['kind'] as String?),
    createdAt: DateTime.tryParse('${r['created_at']}') ?? DateTime.now(),
  );

  @override
  Future<List<IncomingPoke>> unseenPokes() => _run(() async {
    final c = await _c();
    final me = c.auth.currentUser?.id;
    if (me == null) return const <IncomingPoke>[];
    final rows = await c
        .from('pokes')
        .select('id,sender,kind,created_at')
        .eq('recipient', me)
        .isFilter('seen_at', null)
        .order('created_at', ascending: false)
        .limit(10);
    return [for (final r in rows) _poke(r)];
  });

  @override
  Future<void> markPokesSeen(List<String> ids) => _run(() async {
    if (ids.isEmpty) return;
    final c = await _c();
    await c
        .from('pokes')
        .update({'seen_at': DateTime.now().toUtc().toIso8601String()})
        .inFilter('id', ids);
  });

  // ------------------------------------------------------------ Temps réel

  @override
  Future<void> subscribe() => _run(() async {
    final c = await _c();
    final me = c.auth.currentUser?.id;
    if (me == null) return;
    await _unsubscribe(c);
    final channel = c.channel('amis-$me');
    channel
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'profiles',
        callback: (p) => _events.add(
          PresenceChanged(
            '${p.newRecord['id']}',
            _seen(p.newRecord['last_seen']),
          ),
        ),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'friendships',
        callback: (p) => _events.add(_relation(p, me)),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'pokes',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'recipient',
          value: me,
        ),
        callback: (p) => _events.add(PokeReceived(_poke(p.newRecord))),
      )
      ..subscribe();
    _channel = channel;
  });

  static FriendsEvent _relation(PostgresChangePayload p, String me) {
    final r = p.newRecord;
    final status = r['status'];
    if (p.eventType == PostgresChangeEvent.insert &&
        status == 'pending' &&
        r['addressee'] == me) {
      return RequestReceived('${r['id']}');
    }
    if (p.eventType == PostgresChangeEvent.update &&
        status == 'accepted' &&
        r['requester'] == me) {
      return RequestAccepted('${r['addressee']}');
    }
    return const RelationsChanged();
  }

  @override
  Future<void> unsubscribe() async {
    final c = _client;
    if (c != null) await _unsubscribe(c);
  }

  Future<void> _unsubscribe(SupabaseClient c) async {
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try {
        await c.removeChannel(ch);
      } catch (_) {
        // Canal déjà fermé : rien à faire.
      }
    }
  }
}
