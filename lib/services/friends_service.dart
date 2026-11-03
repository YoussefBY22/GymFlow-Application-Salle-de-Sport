import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/errors.dart';
import '../core/validators.dart';
import '../models/enums.dart';
import '../models/friends.dart';
import 'backend.dart';
import 'friends/friends_remote.dart';

/// État de la fonction Amis pour la personne connectée.
enum FriendsStatus {
  /// Supabase n'est pas configuré dans cette version de l'application.
  unavailable,

  /// Fonction désactivée (réglage par défaut) ou compte non éligible.
  off,

  /// Activée, connexion au serveur en cours.
  connecting,

  /// Connectée : amis, présence et messages en direct.
  connected,

  /// Activée, mais il faut ressaisir le mot de passe (session du serveur
  /// absente, par exemple après une entrée avec Google).
  needsPassword,

  /// Activée, mais le serveur est injoignable ou a refusé ([error]).
  error,
}

/// Fonction « Amis » : demandes d'ami par e-mail, présence en direct et
/// petits messages (« poke ») entre abonnés, via Supabase.
///
/// GymFlow garde ses comptes en local sur chaque téléphone : pour que deux
/// téléphones se retrouvent, l'abonné qui active la fonction obtient aussi
/// un compte sur le serveur (même e-mail, même mot de passe). C'est
/// **facultatif**, désactivé par défaut et interdit aux mineurs.
class FriendsService extends ChangeNotifier with WidgetsBindingObserver {
  FriendsService(
    this._b,
    this._remote, {
    this.heartbeatEvery = const Duration(seconds: 15),
    this.idleAfter = const Duration(minutes: 2),
  });

  final Backend _b;
  final FriendsRemote? _remote;

  /// Intervalle entre deux signaux de présence (réduit dans les tests).
  final Duration heartbeatEvery;

  /// Sans toucher l'écran pendant ce délai, on n'est plus « en ligne » : être
  /// en ligne veut dire utiliser l'application, pas la laisser ouverte.
  final Duration idleAfter;

  /// Route de l'écran, ouverte depuis les notifications.
  static const route = '/friends';

  List<Friend> _friends = const [];
  List<FriendRequest> _requests = const [];
  List<SentRequest> _sent = const [];
  bool _invisible = false;
  DateTime? _lastActivity;
  bool _idle = false;
  bool _appActive = true;
  Duration _serverOffset = Duration.zero;
  bool _connecting = false;
  bool _connected = false;
  bool _needsPassword = false;
  bool _observing = false;
  Object? _error;
  Timer? _timer;
  StreamSubscription<FriendsEvent>? _sub;

  /// Messages déjà affichés (un message ne s'affiche pas deux fois).
  final Set<String> _handled = {};

  // ---------------------------------------------------------------- État

  /// Supabase est-il configuré ?
  bool get available => _remote != null;

  List<Friend> get friends => _friends;
  List<FriendRequest> get requests => _requests;

  /// Invitations que j'ai envoyées et qui n'ont pas abouti.
  List<SentRequest> get sentRequests => _sent;

  /// Mode « Apparaître hors ligne » actif.
  bool get invisible => _invisible;
  Object? get error => _error;

  /// Nombre de demandes en attente (pastille du menu).
  int get pendingCount => _requests.length;

  bool get _enabledForMe {
    final me = _b.auth.currentUser;
    return me != null && me.isMember && me.isAdult && me.privacy.friends;
  }

  FriendsStatus get status {
    if (!available) return FriendsStatus.unavailable;
    if (!_enabledForMe) return FriendsStatus.off;
    if (_connected) return FriendsStatus.connected;
    if (_connecting) return FriendsStatus.connecting;
    if (_needsPassword) return FriendsStatus.needsPassword;
    if (_error != null) return FriendsStatus.error;
    return FriendsStatus.connecting;
  }

  /// Heure du serveur estimée : l'heure locale corrigée de l'écart mesuré.
  DateTime serverNow() => _b.now().add(_serverOffset);

  /// Un ami est-il en ligne maintenant ?
  bool isOnline(Friend f) => f.isOnline(serverNow());

  int get onlineCount => _friends.where(isOnline).length;

  FriendsRemote get _r =>
      _remote ??
      (throw const BusinessRuleException('Fonction Amis indisponible.'));

  // ------------------------------------------------------ Cycle de session

  /// Après un lancement de l'application avec une session déjà ouverte :
  /// reprend la fonction si elle est activée et si la session du serveur est
  /// toujours là pour ce même compte.
  Future<void> resume() async {
    if (!available || !_enabledForMe || _connected || _connecting) return;
    final me = _b.auth.currentUser!;
    _setConnecting();
    try {
      final hasSession = await _r.restore();
      if (hasSession && _sameAccount(me.email)) {
        await _goOnline();
      } else {
        _needsPassword = true;
        _connecting = false;
        notifyListeners();
      }
    } catch (e) {
      _fail(e);
    }
  }

  /// Après une connexion par mot de passe : le mot de passe est connu, donc
  /// la connexion au serveur est automatique.
  Future<void> onLogin(String? password) async {
    if (!available || !_enabledForMe) return;
    if (password == null) return resume();
    try {
      await _connect(password);
    } catch (_) {
      // L'erreur est conservée dans l'état ; l'écran Amis l'affiche.
    }
  }

  /// À la déconnexion : on passe hors ligne tout de suite et on ferme la
  /// session du serveur (le téléphone suivant ne doit pas en hériter).
  Future<void> onLogout() async {
    final remote = _remote;
    _stop();
    _friends = const [];
    _requests = const [];
    _sent = const [];
    _invisible = false;
    _handled.clear();
    _needsPassword = false;
    _error = null;
    notifyListeners();
    if (remote == null) return;
    try {
      await remote.goOffline();
      await remote.signOut();
    } catch (_) {
      // Hors connexion : la session locale du serveur sera remplacée à la
      // prochaine connexion.
    }
  }

  /// Le mot de passe GymFlow a changé : le compte du serveur suit.
  Future<void> onPasswordChanged(String newPassword) async {
    if (!_connected) return;
    try {
      await _r.updatePassword(newPassword);
    } catch (_) {
      // Rattrapé à la prochaine connexion (message explicatif).
    }
  }

  // ------------------------------------------------------------ Activation

  /// Active la fonction (consentement explicite) et crée / relie le compte
  /// du serveur. [password] est le mot de passe GymFlow : il est vérifié
  /// localement avant d'être envoyé, pour que les deux comptes restent
  /// identiques.
  Future<void> enable(String password) async {
    final me = _b.requireRole({UserRole.member});
    if (!available) {
      throw const BusinessRuleException(
        'La fonction Amis n\'est pas disponible dans cette version.',
      );
    }
    if (!me.isAdult) {
      throw const BusinessRuleException(
        'Les comptes de mineurs ne peuvent pas activer la fonction Amis.',
      );
    }
    _checkPassword(password);
    await _b.privacy.updateSettings(me.privacy.copyWith(friends: true));
    try {
      await _connect(password);
      // Android 13+ : autorisation d'afficher les notifications d'amis.
      await _b.notifier.requestPermission();
    } catch (e) {
      // Pas de demi-activation : si la connexion échoue, on revient en arrière.
      await _b.privacy.updateSettings(
        _b.auth.currentUser!.privacy.copyWith(friends: false),
      );
      _stop();
      _error = null;
      notifyListeners();
      rethrow;
    }
  }

  /// Ressaisie du mot de passe quand la fonction est activée mais pas connectée.
  Future<void> reconnect(String password) async {
    _b.requireRole({UserRole.member});
    _checkPassword(password);
    await _connect(password);
  }

  /// Désactive la fonction et **efface** ses données sur le serveur (amis,
  /// demandes, messages) : désactiver, c'est partir.
  Future<void> disable() async {
    final me = _b.requireRole({UserRole.member});
    final remote = _remote;
    _stop();
    if (remote != null && remote.userId != null) {
      try {
        await remote.leave();
      } catch (_) {
        // Hors connexion : la désactivation locale s'applique quand même ;
        // les données restantes sont invisibles (profil marqué inactif à la
        // prochaine connexion).
      }
      try {
        await remote.signOut();
      } catch (_) {}
    }
    _friends = const [];
    _requests = const [];
    _sent = const [];
    _invisible = false;
    _handled.clear();
    _needsPassword = false;
    _error = null;
    await _b.privacy.updateSettings(me.privacy.copyWith(friends: false));
    notifyListeners();
  }

  /// Suppression du compte GymFlow : on efface aussi côté serveur.
  Future<void> eraseRemoteData() async {
    final remote = _remote;
    if (remote == null || remote.userId == null) return;
    try {
      await remote.leave();
      await remote.signOut();
    } catch (_) {}
    _stop();
  }

  void _checkPassword(String password) {
    if (!_b.auth.checkPassword(password)) {
      throw const ValidationException('Mot de passe incorrect.');
    }
  }

  bool _sameAccount(String email) =>
      (_r.userEmail ?? '').toLowerCase() == email.toLowerCase();

  void _setConnecting() {
    _connecting = true;
    _error = null;
    notifyListeners();
  }

  Future<void> _connect(String password) async {
    final me = _b.requireRole({UserRole.member});
    _setConnecting();
    try {
      await _r.signIn(
        email: me.email,
        password: password,
        displayName: me.fullName,
      );
      await _goOnline();
    } catch (e) {
      _fail(e);
      rethrow;
    }
  }

  void _fail(Object e) {
    _connecting = false;
    _connected = false;
    _error = e;
    notifyListeners();
  }

  /// Profil à jour, premier signal de présence, listes, écoute en direct.
  Future<void> _goOnline() async {
    final me = _b.auth.currentUser!;
    final avatar = me.avatarPath;
    await _r.updateProfile(
      displayName: me.fullName,
      enabled: true,
      avatarUrl:
          avatar != null &&
              avatar.startsWith('https://') &&
              avatar.length <= 500
          ? avatar
          : null,
    );
    _invisible = await _r.loadInvisible();
    _lastActivity = _b.now();
    _idle = false;
    _appActive = true;
    await _beat();
    await refresh();
    await _r.subscribe();
    await _sub?.cancel();
    _sub = _r.events.listen(_onEvent);
    _connecting = false;
    _connected = true;
    _needsPassword = false;
    _error = null;
    _startTimer();
    _observe();
    notifyListeners();
    await _deliverUnseenPokes();
  }

  // ----------------------------------------------------------- Présence

  Future<void> _beat() async {
    final serverTime = await _r.heartbeat();
    _serverOffset = serverTime.difference(_b.now());
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(heartbeatEvery, (_) => unawaited(tick()));
  }

  /// Une tâche du minuteur : signal de présence, sauf si l'application est
  /// en arrière-plan ou si personne n'a touché l'écran depuis [idleAfter].
  /// Public pour les tests.
  Future<void> tick() async {
    if (!_connected || !_appActive) return;
    final last = _lastActivity;
    if (last != null && _b.now().difference(last) > idleAfter) {
      if (!_idle) {
        _idle = true;
        try {
          await _r.goOffline();
        } catch (_) {}
        notifyListeners();
      }
      return;
    }
    await beat();
  }

  /// Un signal de présence (public pour les tests).
  Future<void> beat() async {
    if (!_connected) return;
    try {
      await _beat();
      notifyListeners();
    } catch (_) {
      // Coupure passagère : le prochain signal rattrape.
    }
  }

  /// À appeler à chaque geste de la personne (touche, défilement, saisie) :
  /// c'est ce qui la garde « en ligne ».
  void noteActivity() {
    _lastActivity = _b.now();
    if (_idle && _connected && _appActive) {
      _idle = false;
      unawaited(beat());
    }
  }

  void _observe() {
    if (_observing) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } catch (_) {
      // Pas de moteur graphique (tests unitaires) : rien à observer.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_connected) return;
    if (state == AppLifecycleState.resumed) {
      _appActive = true;
      _idle = false;
      _lastActivity = _b.now();
      _startTimer();
      unawaited(() async {
        await beat();
        await refresh();
        await _deliverUnseenPokes();
      }());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // En arrière-plan : on n'est plus « en ligne » pour les amis, même si
      // le système laisse l'application tourner.
      _appActive = false;
      _timer?.cancel();
      unawaited(_r.goOffline().catchError((Object _) {}));
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(_remote?.unsubscribe());
    if (_observing) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
      _observing = false;
    }
    _connected = false;
    _connecting = false;
  }

  /// Arrête les minuteurs (tests, fermeture de l'application).
  void stop() => _stop();

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  // ------------------------------------------------------------- Listes

  /// Relit les amis et les demandes.
  Future<void> refresh() async {
    final snap = await _r.loadFriends();
    _serverOffset = snap.serverNow.difference(_b.now());
    _friends = snap.friends;
    _requests = await _r.loadRequests();
    _sent = await _r.loadSentRequests();
    notifyListeners();
  }

  // ------------------------------------------------------------- Actions

  /// Envoie une invitation. Si aucune personne n'a activé la fonction Amis
  /// avec cette adresse, le serveur répond « aucun compte avec cette
  /// adresse » (choix assumé, voir SECURITE_CONFIDENTIALITE.md).
  Future<SendResult> sendRequest(String email) async {
    final me = _b.requireRole({UserRole.member});
    final clean = email.trim().toLowerCase();
    final problem = Validators.email(clean);
    if (problem != null) throw ValidationException(problem);
    if (clean == me.email.toLowerCase()) {
      throw const BusinessRuleException(
        'C\'est votre propre adresse : saisissez celle d\'un ami.',
      );
    }
    final result = await _r.sendRequest(clean);
    // Si la personne nous avait déjà invité, c'est déjà accepté : la liste
    // d'amis et les invitations en attente sont relues dans tous les cas.
    await refresh();
    return result;
  }

  /// Annule une invitation que j'ai envoyée.
  Future<void> cancelRequest(SentRequest request) async {
    await _r.cancelRequest(request.id);
    await refresh();
  }

  /// Active ou coupe le mode « Apparaître hors ligne ».
  Future<void> setInvisible(bool value) async {
    await _r.setInvisible(value);
    _invisible = value;
    notifyListeners();
    // En quittant le mode invisible, on redevient visible tout de suite.
    if (!value) await beat();
  }

  Future<void> respond(FriendRequest request, bool accept) async {
    await _r.respond(request.id, accept);
    await refresh();
  }

  Future<void> remove(Friend friend) async {
    await _r.removeFriend(friend.id);
    await refresh();
  }

  Future<void> poke(Friend friend, [PokeKind kind = PokeKind.encourage]) async {
    await _r.sendPoke(friend.id, kind);
  }

  // ----------------------------------------------------- Événements en direct

  void _onEvent(FriendsEvent e) {
    unawaited(_handle(e).catchError((Object _) {}));
  }

  Future<void> _handle(FriendsEvent e) async {
    switch (e) {
      case PresenceChanged():
        final i = _friends.indexWhere((f) => f.id == e.userId);
        if (i < 0) return;
        final list = [..._friends];
        list[i] = e.lastSeen == null
            ? list[i].copyWith(online: e.online, clearLastSeen: true)
            : list[i].copyWith(online: e.online, lastSeen: e.lastSeen);
        _friends = list;
        notifyListeners();
      case RelationsChanged():
        await refresh();
      case RequestReceived():
        await refresh();
        for (final r in _requests) {
          if (r.id == e.requestId && _handled.add('req:${r.id}')) {
            await _alert(
              '${r.fromName} veut vous ajouter',
              'Ouvrez Mes amis pour accepter ou refuser la demande.',
            );
          }
        }
      case RequestAccepted():
        await refresh();
        for (final f in _friends) {
          if (f.id == e.friendId && _handled.add('acc:${f.id}')) {
            await _alert(
              '${f.name} a accepté',
              'Vous êtes maintenant amis : vous voyez quand il ou elle est en ligne.',
            );
          }
        }
      case PokeReceived():
        await _showPoke(e.poke);
    }
  }

  Future<void> _showPoke(IncomingPoke p) async {
    if (!_handled.add('poke:${p.id}')) return;
    var name = _nameOf(p.senderId);
    if (name == null) {
      await refresh();
      name = _nameOf(p.senderId);
    }
    final who = name ?? 'Un ami';
    await _alert(p.kind.title(who), p.kind.body(who));
    try {
      await _r.markPokesSeen([p.id]);
    } catch (_) {}
  }

  String? _nameOf(String id) {
    for (final f in _friends) {
      if (f.id == id) return f.name;
    }
    return null;
  }

  /// Messages reçus pendant que l'application était fermée.
  Future<void> _deliverUnseenPokes() async {
    try {
      final pokes = await _r.unseenPokes();
      for (final p in pokes.reversed) {
        await _showPoke(p);
      }
    } catch (_) {
      // Pas bloquant : ils seront relus à la prochaine ouverture.
    }
  }

  /// Notification dans l'application et sur le téléphone.
  Future<void> _alert(String title, String body) async {
    final me = _b.auth.currentUser;
    if (me == null) return;
    await _b.notifications.notify(
      me.id,
      NotificationType.friend,
      title,
      body,
      route: route,
    );
    try {
      await _b.notifier.show(
        (title.hashCode ^ body.hashCode) & 0x7fffffff,
        title,
        body,
      );
    } catch (_) {}
  }
}
