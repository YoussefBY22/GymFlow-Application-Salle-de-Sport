import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend.dart';

/// Lien avec le serveur « temps réel » : un salon partagé où chaque appareil
/// signale sa présence. Séparé du service pour pouvoir le remplacer dans les
/// tests.
abstract class PresenceTransport {
  /// Nombre d'abonnés présents dans le salon (les observateurs ne comptent pas).
  Stream<int> get members;

  /// Entre dans le salon. [member] : compté ; sinon simple observateur.
  Future<void> join({required String key, required bool member});

  /// Quitte le salon : la personne disparaît du compteur.
  Future<void> leave();
}

/// Présence sur Supabase Realtime : un salon public, sans compte ni donnée
/// personnelle. Seule une clé aléatoire (changée à chaque lancement) et le
/// rôle « abonné / observateur » y sont publiés.
class SupabasePresenceTransport implements PresenceTransport {
  SupabasePresenceTransport({required this.url, required this.anonKey});

  final String url;
  final String anonKey;

  static const room = 'gymflow-live';

  // Client à part : ni la session des amis ni ses canaux ne sont touchés.
  SupabaseClient? _client;
  RealtimeChannel? _channel;
  final StreamController<int> _members = StreamController<int>.broadcast();

  @override
  Stream<int> get members => _members.stream;

  @override
  Future<void> join({required String key, required bool member}) async {
    await leave();
    final client = _client ??= SupabaseClient(url, anonKey);
    final channel = client.channel(room, opts: RealtimeChannelConfig(key: key));
    channel.onPresenceSync((_) {
      var n = 0;
      for (final s in channel.presenceState()) {
        if (s.presences.any((p) => p.payload['role'] == 'member')) n++;
      }
      if (!_members.isClosed) _members.add(n);
    });
    _channel = channel;
    channel.subscribe((status, [error]) async {
      if (status == RealtimeSubscribeStatus.subscribed &&
          identical(_channel, channel)) {
        await channel.track({'role': member ? 'member' : 'observer'});
      }
    });
  }

  @override
  Future<void> leave() async {
    final channel = _channel;
    _channel = null;
    if (channel == null) return;
    try {
      // Désabonner le salon fait disparaître la personne du compteur en
      // quelques secondes (un simple « untrack » est plus lent).
      await _client?.removeChannel(channel);
    } catch (_) {}
  }
}

/// Compteur « connectés maintenant » du tableau de bord admin.
///
/// Contrairement à Google Analytics (fenêtre de 30 minutes), la personne
/// compte tant que l'application est ouverte à l'écran et disparaît dès
/// qu'elle se déconnecte, quitte l'application ou retire son consentement.
///
/// Règles :
/// - un abonné majeur qui a accepté la « mesure d'audience » est compté
///   pendant que l'application est au premier plan ;
/// - la salle et les coachs ne sont jamais comptés ; l'admin écoute le salon
///   seulement quand l'écran Statistiques est ouvert.
class LivePresenceService extends ChangeNotifier {
  LivePresenceService(this._b, this._transport) {
    _sub = _transport?.members.listen((n) {
      _members = n;
      _synced = true;
      notifyListeners();
    });
    _b.auth.addListener(refresh);
    _b.bus.addListener(refresh);
  }

  final Backend _b;
  final PresenceTransport? _transport;
  StreamSubscription<int>? _sub;

  _Mode _mode = _Mode.none;
  bool _foreground = true;
  bool _watching = false;
  bool _synced = false;
  int _members = 0;
  Future<void> _queue = Future.value();

  // Clé aléatoire de cette installation, renouvelée à chaque lancement.
  late final String _key = _randomKey();

  /// Le serveur temps réel est configuré.
  bool get available => _transport != null;

  /// Le salon a répondu au moins une fois : le chiffre est fiable.
  bool get synced => _synced;

  /// Abonnés connectés en ce moment.
  int get members => _members;

  /// L'admin ouvre (ou ferme) l'écran qui affiche le compteur.
  void watch(bool on) {
    if (_watching == on) return;
    _watching = on;
    if (!on) _synced = false;
    refresh();
  }

  /// L'application passe au premier plan (ou en arrière-plan).
  void setForeground(bool on) {
    if (_foreground == on) return;
    _foreground = on;
    refresh();
  }

  /// Réexamine qui doit être dans le salon (connexion, déconnexion,
  /// consentement, premier plan).
  void refresh() {
    if (_transport == null) return;
    _queue = _queue.then((_) => _apply()).catchError((Object _) {});
  }

  _Mode _wanted() {
    final me = _b.auth.currentUser;
    if (me == null || !_foreground) return _Mode.none;
    if (me.isMember) {
      return me.privacy.analytics && me.isAdult ? _Mode.member : _Mode.none;
    }
    return _watching ? _Mode.observer : _Mode.none;
  }

  Future<void> _apply() async {
    final transport = _transport;
    if (transport == null) return;
    final wanted = _wanted();
    if (wanted == _mode) return;
    _mode = wanted;
    try {
      if (wanted == _Mode.none) {
        await transport.leave();
        if (_members != 0) {
          _members = 0;
          notifyListeners();
        }
        return;
      }
      await transport.join(
        key: wanted == _Mode.member ? _key : 'obs-$_key',
        member: wanted == _Mode.member,
      );
    } catch (_) {
      // Pas de réseau : on réessaiera au prochain changement.
      _mode = _Mode.none;
    }
  }

  static String _randomKey() {
    final r = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(14, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Quitte le salon (fermeture de l'application, tests).
  Future<void> stop() async {
    _b.auth.removeListener(refresh);
    _b.bus.removeListener(refresh);
    await _queue;
    await _transport?.leave();
    _mode = _Mode.none;
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }
}

enum _Mode { none, member, observer }
