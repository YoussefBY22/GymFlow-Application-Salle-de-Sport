import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../core/config.dart';

/// Autorisation d'afficher les notifications.
enum PushPermission { granted, denied }

/// Notification touchée : page à ouvrir (et, pour une discussion,
/// l'identifiant de l'ami).
class PushOpen {
  const PushOpen(this.route, this.ref);
  final String route;
  final String? ref;
}

/// Accès aux notifications push du téléphone (Firebase Cloud Messaging).
///
/// Une interface pour tester la logique sans Firebase (voir
/// `test/push_test.dart`) : `PushService` ne connaît que ce contrat.
abstract class PushGateway {
  /// Les clés Firebase sont-elles configurées et la plateforme gérée ?
  bool get configured;

  Future<PushPermission> requestPermission();

  /// Jeton de ce téléphone (`null` s'il n'est pas disponible).
  Future<String?> token();

  /// Nouveau jeton (Firebase peut en changer).
  Stream<String> get tokenRefresh;

  /// Notification touchée pendant que l'application tournait en arrière-plan.
  Stream<PushOpen> get opened;

  /// Notification qui a lancé l'application (elle était fermée).
  Future<PushOpen?> initialOpen();

  /// Oublie ce téléphone (déconnexion, désactivation de la fonction).
  Future<void> deleteToken();
}

/// Firebase Cloud Messaging, configuré par les clés de `secrets.json`
/// (`FIREBASE_*`) : ni `google-services.json` ni plugin Gradle à ajouter.
class FirebasePushGateway implements PushGateway {
  FirebasePushGateway();

  bool _ready = false;

  @override
  bool get configured => !kIsWeb && AppConfig.firebaseEnabled;

  /// Initialise Firebase une seule fois ; `false` si impossible.
  Future<bool> _ensure() async {
    if (_ready) return true;
    if (!configured) return false;
    try {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: AppConfig.firebaseApiKey.trim(),
          appId: AppConfig.firebaseAppId.trim(),
          messagingSenderId: AppConfig.firebaseSenderId.trim(),
          projectId: AppConfig.firebaseProjectId.trim(),
        ),
      );
    } catch (e) {
      // Déjà initialisé : on continue ; sinon les clés sont mauvaises.
      if (Firebase.apps.isEmpty) {
        debugPrint('[Push] Firebase indisponible : ${e.runtimeType}');
        return false;
      }
    }
    _ready = true;
    return true;
  }

  static PushOpen? _open(RemoteMessage m) {
    final route = m.data['route'];
    if (route is! String || route.isEmpty) return null;
    final ref = m.data['ref'];
    return PushOpen(route, ref is String && ref.isNotEmpty ? ref : null);
  }

  @override
  Future<PushPermission> requestPermission() async {
    if (!await _ensure()) return PushPermission.denied;
    final s = await FirebaseMessaging.instance.requestPermission();
    return s.authorizationStatus == AuthorizationStatus.denied
        ? PushPermission.denied
        : PushPermission.granted;
  }

  @override
  Future<String?> token() async {
    if (!await _ensure()) return null;
    return FirebaseMessaging.instance.getToken();
  }

  @override
  Stream<String> get tokenRefresh async* {
    if (!await _ensure()) return;
    yield* FirebaseMessaging.instance.onTokenRefresh;
  }

  @override
  Stream<PushOpen> get opened async* {
    if (!await _ensure()) return;
    await for (final m in FirebaseMessaging.onMessageOpenedApp) {
      final o = _open(m);
      if (o != null) yield o;
    }
  }

  @override
  Future<PushOpen?> initialOpen() async {
    if (!await _ensure()) return null;
    final m = await FirebaseMessaging.instance.getInitialMessage();
    return m == null ? null : _open(m);
  }

  @override
  Future<void> deleteToken() async {
    if (!await _ensure()) return;
    await FirebaseMessaging.instance.deleteToken();
  }
}
