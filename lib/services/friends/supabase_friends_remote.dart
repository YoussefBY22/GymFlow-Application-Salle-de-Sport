import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors.dart';
import '../../models/chat.dart';
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
      return "Doucement : trop d'envois en peu de temps. Réessayez dans un "
          'instant.';
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
    if (m.contains('you_blocked')) {
      return 'Vous avez bloqué cette personne. Débloquez-la dans Mes amis pour '
          "l'inviter.";
    }
    if (m.contains('empty_message')) return 'Écrivez un message.';
    if (m.contains('too_long')) {
      return 'Message trop long (1 000 caractères au plus).';
    }
    if (m.contains('not_sender')) {
      return 'Seul l\'auteur peut supprimer un message pour tout le monde.';
    }
    if (m.contains('no_messages')) {
      return 'Sélectionnez au moins un message.';
    }
    if (m.contains('invalid_remark')) {
      return 'Décrivez le problème en 5 caractères au moins.';
    }
    if (m.contains('not_admin')) {
      return 'Ce compte n\'est pas reconnu comme administrateur.';
    }
    if (m.contains('no_account')) {
      return 'Aucun compte avec cette adresse. Votre ami doit avoir activé la '
          'fonction Amis.';
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

  @override
  Future<void> setInvisible(bool invisible) => _run(() async {
    final c = await _c();
    await c.rpc('set_invisible', params: {'p_on': invisible});
  });

  @override
  Future<ChatSettings> loadSettings() => _run(() async {
    final c = await _c();
    final rows = (await c.rpc('my_settings') as List).cast<Map>();
    if (rows.isEmpty) return const ChatSettings();
    final r = rows.first;
    return ChatSettings(
      invisible: r['invisible'] == true,
      hideReadReceipts: r['hide_read_receipts'] == true,
      hideTyping: r['hide_typing'] == true,
      pushPreview: r['push_preview'] != false,
      isAdmin: r['is_admin'] == true,
    );
  });

  @override
  Future<void> setChatSettings({
    required bool hideReadReceipts,
    required bool hideTyping,
    required bool pushPreview,
  }) => _run(() async {
    final c = await _c();
    await c.rpc(
      'set_chat_settings',
      params: {
        'p_hide_receipts': hideReadReceipts,
        'p_hide_typing': hideTyping,
        'p_push_preview': pushPreview,
      },
    );
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
          online: r['online'] == true,
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
  Future<SendResult> sendRequest(String email) => _run(() async {
    final c = await _c();
    final r = await c.rpc(
      'send_friend_request',
      params: {'p_email': email.trim()},
    );
    return SendResult.fromKey(r as String?);
  });

  @override
  Future<List<SentRequest>> loadSentRequests() => _run(() async {
    final c = await _c();
    final rows = (await c.rpc('my_sent_requests') as List).cast<Map>();
    return [
      for (final r in rows)
        SentRequest(
          id: r['id'] as String,
          toName: r['to_name'] as String,
          avatarUrl: r['avatar_url'] as String?,
          createdAt: DateTime.tryParse('${r['created_at']}') ?? DateTime.now(),
        ),
    ];
  });

  @override
  Future<void> cancelRequest(String requestId) => _run(() async {
    final c = await _c();
    await c.rpc('cancel_friend_request', params: {'p_id': requestId});
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

  // ------------------------------------------------------------ Messagerie

  static ChatMessage _message(Map r) => ChatMessage(
    id: r['id'] as String,
    peerId: r['peer'] as String,
    mine: r['mine'] == true,
    kind: MessageKind.fromKey(r['kind'] as String?),
    text: r['body'] as String?,
    createdAt: DateTime.tryParse('${r['created_at']}') ?? DateTime.now(),
    deleted: r['deleted'] == true,
  );

  @override
  Future<String> sendMessage(String toId, MessageKind kind, String body) =>
      _run(() async {
        final c = await _c();
        final r = await c.rpc(
          'send_message',
          params: {'p_to': toId, 'p_kind': kind.key, 'p_body': body},
        );
        return r as String;
      });

  @override
  Future<List<ChatMessage>> loadMessages(
    String friendId, {
    DateTime? before,
    int limit = 50,
  }) => _run(() async {
    final c = await _c();
    final rows =
        (await c.rpc(
                  'conversation_messages',
                  params: {
                    'p_friend': friendId,
                    'p_before': before?.toUtc().toIso8601String(),
                    'p_limit': limit,
                  },
                )
                as List)
            .cast<Map>();
    return [for (final r in rows) _message(r)];
  });

  @override
  Future<ChatMessage?> messageById(String id) => _run(() async {
    final c = await _c();
    final rows = (await c.rpc('message_by_id', params: {'p_id': id}) as List)
        .cast<Map>();
    return rows.isEmpty ? null : _message(rows.first);
  });

  @override
  Future<List<Conversation>> loadConversations({bool archived = false}) =>
      _run(() async {
        final c = await _c();
        final rows =
            (await c.rpc('my_conversations', params: {'p_archived': archived})
                    as List)
                .cast<Map>();
        return [
          for (final r in rows)
            Conversation(
              friendId: r['friend_id'] as String,
              friendName: r['friend_name'] as String,
              avatarUrl: r['avatar_url'] as String?,
              lastAt: DateTime.tryParse('${r['last_at']}') ?? DateTime.now(),
              lastMine: r['last_mine'] == true,
              lastPreview: ChatMessage(
                id: 'x',
                peerId: r['friend_id'] as String,
                mine: r['last_mine'] == true,
                kind: MessageKind.fromKey(r['last_kind'] as String?),
                text: r['last_body'] as String?,
                deleted: r['last_deleted'] == true,
                createdAt: DateTime.now(),
              ).preview,
              unread: (r['unread'] as num?)?.toInt() ?? 0,
              muted: r['muted'] == true,
              archived: r['archived'] == true,
            ),
        ];
      });

  @override
  Future<ChatInfo> conversationInfo(String friendId) => _run(() async {
    final c = await _c();
    final rows =
        (await c.rpc('conversation_info', params: {'p_friend': friendId})
                as List)
            .cast<Map>();
    if (rows.isEmpty) return const ChatInfo();
    final r = rows.first;
    return ChatInfo(
      peerReadAt: DateTime.tryParse('${r['peer_read_at']}'),
      muted: r['muted'] == true,
      archived: r['archived'] == true,
    );
  });

  @override
  Future<void> markRead(String friendId) => _run(() async {
    final c = await _c();
    await c.rpc('mark_read', params: {'p_friend': friendId});
  });

  @override
  Future<void> setTyping(String friendId, bool typing) => _run(() async {
    final c = await _c();
    await c.rpc('set_typing', params: {'p_friend': friendId, 'p_on': typing});
  });

  @override
  Future<void> deleteMessage(String messageId, {required bool forAll}) =>
      _run(() async {
        final c = await _c();
        await c.rpc(
          'delete_message',
          params: {'p_id': messageId, 'p_for_all': forAll},
        );
      });

  @override
  Future<void> clearConversation(String friendId) => _run(() async {
    final c = await _c();
    await c.rpc('clear_conversation', params: {'p_friend': friendId});
  });

  @override
  Future<void> setArchived(String friendId, bool archived) => _run(() async {
    final c = await _c();
    await c.rpc(
      'set_archived',
      params: {'p_friend': friendId, 'p_on': archived},
    );
  });

  @override
  Future<void> setMuted(String friendId, bool muted) => _run(() async {
    final c = await _c();
    await c.rpc('set_muted', params: {'p_friend': friendId, 'p_on': muted});
  });

  // ------------------------------------------- Blocage et signalements

  @override
  Future<void> blockUser(String userId) => _run(() async {
    final c = await _c();
    await c.rpc('block_user', params: {'p_user': userId});
  });

  @override
  Future<void> unblockUser(String userId) => _run(() async {
    final c = await _c();
    await c.rpc('unblock_user', params: {'p_user': userId});
  });

  @override
  Future<List<BlockedUser>> loadBlocks() => _run(() async {
    final c = await _c();
    final rows = (await c.rpc('my_blocks') as List).cast<Map>();
    return [
      for (final r in rows)
        BlockedUser(
          id: r['user_id'] as String,
          name: r['display_name'] as String,
          avatarUrl: r['avatar_url'] as String?,
        ),
    ];
  });

  @override
  Future<void> reportConversation(
    String friendId,
    List<String> messageIds, {
    String? remark,
    bool alsoBlock = false,
  }) => _run(() async {
    final c = await _c();
    await c.rpc(
      'report_conversation',
      params: {
        'p_friend': friendId,
        'p_message_ids': messageIds,
        'p_remark': remark,
        'p_also_block': alsoBlock,
      },
    );
  });

  @override
  Future<void> reportPerson(String friendId, String remark) => _run(() async {
    final c = await _c();
    await c.rpc(
      'report_person',
      params: {'p_friend': friendId, 'p_remark': remark},
    );
  });

  @override
  Future<List<ReportEntry>> adminLoadReports({bool? handled}) => _run(() async {
    final c = await _c();
    final rows =
        (await c.rpc(
                  'admin_list_reports',
                  params: {
                    'p_status': handled == null
                        ? null
                        : (handled ? 'handled' : 'new'),
                  },
                )
                as List)
            .cast<Map>();
    return [
      for (final r in rows)
        ReportEntry(
          id: r['id'] as String,
          isConversation: r['kind'] == 'discussion',
          handled: r['status'] == 'handled',
          createdAt: DateTime.tryParse('${r['created_at']}') ?? DateTime.now(),
          reporterName: r['reporter_name'] as String,
          reportedName: r['reported_name'] as String,
          remark: r['remark'] as String?,
          handledAt: DateTime.tryParse('${r['handled_at']}'),
          handledNote: r['handled_note'] as String?,
          messages: [
            for (final m in (r['messages'] as List? ?? const []))
              ReportedMessage(
                from: '${(m as Map)['from']}',
                mine: m['mine'] == true,
                at: DateTime.tryParse('${m['at']}') ?? DateTime.now(),
                kind: MessageKind.fromKey(m['kind'] as String?),
                text: m['text'] as String?,
              ),
          ],
        ),
    ];
  });

  @override
  Future<void> adminHandleReport(String reportId, {String? note}) =>
      _run(() async {
        final c = await _c();
        await c.rpc(
          'admin_handle_report',
          params: {'p_id': reportId, 'p_note': note},
        );
      });

  @override
  Future<int> adminNewReportsCount() => _run(() async {
    final c = await _c();
    final r = await c.rpc('admin_new_reports_count');
    return (r as num?)?.toInt() ?? 0;
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
            p.newRecord['online'] == true,
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
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'messages',
        callback: (p) {
          final r = p.newRecord;
          if (r.isEmpty) return;
          final mine = r['sender'] == me;
          _events.add(
            MessageEvent(
              messageId: '${r['id']}',
              peerId: '${mine ? r['recipient'] : r['sender']}',
              mine: mine,
              isNew: p.eventType == PostgresChangeEvent.insert,
            ),
          );
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'read_marks',
        callback: (p) {
          final r = p.newRecord;
          if (r.isEmpty || r['peer'] != me) return;
          final at = DateTime.tryParse('${r['read_at']}');
          if (at != null) _events.add(ReadMarkChanged('${r['reader']}', at));
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'typing_state',
        callback: (p) {
          final r = p.newRecord;
          if (r.isEmpty || r['peer_id'] != me) return;
          final until = DateTime.tryParse('${r['until']}');
          // `until` est une heure du serveur : on la compare à l'heure de
          // validation de la modification, du même serveur.
          final active = until != null && until.isAfter(p.commitTimestamp);
          _events.add(TypingChanged('${r['user_id']}', active));
        },
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
