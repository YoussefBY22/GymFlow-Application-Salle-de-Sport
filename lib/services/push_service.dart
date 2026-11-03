import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'friends/friends_remote.dart';
import 'push/push_gateway.dart';

/// État des notifications quand l'application est fermée.
enum PushStatus {
  /// Clés Firebase absentes (ou plateforme sans push, comme le web).
  unavailable,

  /// Pas encore activées (fonction Amis éteinte ou pas connectée).
  off,

  /// Ce téléphone est enregistré : les notifications arrivent même
  /// l'application fermée.
  enabled,

  /// La personne a refusé les notifications dans le téléphone.
  denied,

  /// Échec d'enregistrement (réseau, clés…).
  error,
}

/// Notifications **push** (application fermée) de la fonction Amis.
///
/// Le téléphone s'enregistre auprès de Supabase avec son jeton Firebase.
/// Ensuite c'est la base qui décide d'envoyer une notification (seulement si
/// la personne n'utilise pas l'application, voir `supabase/005_*.sql`) via la
/// fonction `notify`. Application ouverte, rien n'est envoyé : le temps réel
/// s'en charge.
class PushService extends ChangeNotifier {
  PushService(this._b, this._remote, this._gateway);

  final Backend _b;
  final FriendsRemote? _remote;
  final PushGateway? _gateway;

  /// Ouvre une page quand on touche une notification (branché par
  /// `main.dart` sur le navigateur de l'application).
  void Function(String route, String? ref)? onOpen;

  PushStatus _status = PushStatus.off;
  String? _token;
  StreamSubscription<String>? _refreshSub;
  StreamSubscription<PushOpen>? _openSub;
  bool _initialHandled = false;

  bool get available => (_gateway?.configured ?? false) && _remote != null;

  PushStatus get status => available ? _status : PushStatus.unavailable;

  /// Pages qu'une notification peut ouvrir (rien d'autre n'est suivi).
  static const allowedRoutes = {'/chat', '/friends'};

  /// Enregistre ce téléphone pour les notifications. Sans effet si la
  /// configuration manque ; ne lève jamais d'erreur.
  Future<void> start() async {
    final gateway = _gateway;
    final remote = _remote;
    if (!available || gateway == null || remote == null) return;
    try {
      final permission = await gateway.requestPermission();
      if (permission == PushPermission.denied) {
        _status = PushStatus.denied;
        notifyListeners();
        return;
      }
      final token = await gateway.token();
      if (token == null || token.isEmpty) {
        _status = PushStatus.error;
        notifyListeners();
        return;
      }
      await remote.registerPushToken(token);
      _token = token;
      _status = PushStatus.enabled;
      await _refreshSub?.cancel();
      _refreshSub = gateway.tokenRefresh.listen((t) async {
        try {
          await remote.registerPushToken(t);
          _token = t;
        } catch (_) {
          // Réessayé au prochain démarrage.
        }
      });
      await _openSub?.cancel();
      _openSub = gateway.opened.listen(_handleOpen);
      if (!_initialHandled) {
        _initialHandled = true;
        final first = await gateway.initialOpen();
        if (first != null) _handleOpen(first);
      }
      notifyListeners();
    } catch (_) {
      _status = PushStatus.error;
      notifyListeners();
    }
  }

  /// Arrête l'écoute. Avec [forget], ce téléphone est aussi retiré du
  /// serveur (déconnexion, désactivation) : la personne suivante qui se
  /// connecte sur ce téléphone ne reçoit pas ses notifications.
  Future<void> stop({bool forget = false}) async {
    await _refreshSub?.cancel();
    _refreshSub = null;
    await _openSub?.cancel();
    _openSub = null;
    final token = _token;
    _token = null;
    if (forget) {
      try {
        if (token != null) await _remote?.unregisterPushToken(token);
      } catch (_) {
        // Hors connexion : le jeton sera remplacé à la prochaine connexion.
      }
      try {
        await _gateway?.deleteToken();
      } catch (_) {}
    }
    _status = PushStatus.off;
    notifyListeners();
  }

  void _handleOpen(PushOpen o) {
    if (_b.auth.currentUser == null) return;
    if (!allowedRoutes.contains(o.route)) return;
    onOpen?.call(o.route, o.ref);
  }

  @override
  void dispose() {
    unawaited(_refreshSub?.cancel());
    unawaited(_openSub?.cancel());
    super.dispose();
  }
}
