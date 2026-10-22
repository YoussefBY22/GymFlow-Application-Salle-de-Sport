import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/config.dart';
import '../core/errors.dart';

/// Identité renvoyée par Google après une connexion réussie.
///
/// Volontairement réduite au strict nécessaire : l'application ne demande
/// que le nom et l'adresse e-mail, aucune donnée sensible (Gmail, Drive,
/// agenda, contacts). C'est pour cette raison que Google n'impose aucune
/// procédure de validation à ce projet.
class GoogleIdentity {
  const GoogleIdentity({required this.email, required this.displayName});
  final String email;
  final String displayName;
}

/// Connexion « Continuer avec Google » (API externe Google Identity).
///
/// Deux façons de se connecter selon la plateforme :
/// - **Android** : l'application ouvre elle-même la fenêtre Google
///   ([signIn]). Le client Android est reconnu par le nom du paquet et
///   l'empreinte de signature.
/// - **Web** : Google impose son propre bouton, que l'application doit
///   afficher ([needsRenderedButton]). Le résultat arrive alors par le
///   flux d'événements, d'où l'écoute mise en place dès l'initialisation.
///
/// Aucun mot de passe ne transite par l'application : c'est Google qui
/// authentifie, et il ne nous renvoie que l'identité.
class GoogleAuthService {
  GoogleAuthService({GoogleSignIn? client, this.clientId})
    : _client = client ?? GoogleSignIn.instance;

  final GoogleSignIn _client;

  /// Identifiant du client Web (injectable pour les tests).
  final String? clientId;

  String get _id => clientId ?? AppConfig.googleClientId;

  bool get enabled => _id.trim().isNotEmpty;

  bool _ready = false;

  /// Identités reçues de Google, quelle que soit la plateforme.
  final StreamController<GoogleIdentity> _identities =
      StreamController<GoogleIdentity>.broadcast();
  Stream<GoogleIdentity> get identities => _identities.stream;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;

  /// Sur le web, Google n'autorise pas l'application à ouvrir elle-même la
  /// fenêtre de connexion : il faut afficher le bouton fourni par Google.
  bool get needsRenderedButton => !_client.supportsAuthenticate();

  /// Prépare la connexion Google. Sans effet si elle est déjà prête ou si
  /// l'identifiant n'est pas configuré.
  Future<void> ensureInitialized() async {
    if (_ready || !enabled) return;
    await _client.initialize(
      // Le web attend `clientId` ; Android attend `serverClientId`. On
      // fournit les deux : c'est le même identifiant de client Web.
      clientId: _id,
      serverClientId: _id,
    );
    _events = _client.authenticationEvents.listen(
      (event) {
        if (event is GoogleSignInAuthenticationEventSignIn) {
          final user = event.user;
          final email = user.email.trim();
          if (email.isEmpty) return;
          _identities.add(
            GoogleIdentity(
              email: email,
              displayName: (user.displayName ?? '').trim(),
            ),
          );
        }
      },
      // Une erreur du flux ne doit jamais faire tomber l'application :
      // l'utilisateur garde la connexion par e-mail et mot de passe.
      onError: (Object e) => debugPrint('[Google] $e'),
    );
    _ready = true;
  }

  /// Ouvre la fenêtre Google (Android). À ne pas appeler sur le web, où
  /// [needsRenderedButton] vaut `true`.
  ///
  /// Renvoie `null` si la personne a fermé la fenêtre sans choisir de
  /// compte : ce n'est pas une erreur, il n'y a rien à signaler.
  Future<GoogleIdentity?> signIn() async {
    if (!enabled) {
      throw const BusinessRuleException(
        'La connexion avec Google n\'est pas disponible.',
      );
    }
    await ensureInitialized();
    try {
      final account = await _client.authenticate();
      final email = account.email.trim();
      if (email.isEmpty) {
        throw const BusinessRuleException(
          'Google n\'a pas communiqué d\'adresse e-mail.',
        );
      }
      return GoogleIdentity(
        email: email,
        displayName: (account.displayName ?? '').trim(),
      );
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      throw BusinessRuleException(_message(e));
    }
  }

  /// Ferme la session Google, sans toucher au compte GymFlow.
  Future<void> signOut() async {
    if (!_ready) return;
    try {
      await _client.signOut();
    } catch (_) {
      // Déconnexion locale déjà faite : rien de bloquant.
    }
  }

  Future<void> dispose() async {
    await _events?.cancel();
    await _identities.close();
  }

  /// Message lisible, sans détail technique ni identifiant.
  static String _message(GoogleSignInException e) => switch (e.code) {
    GoogleSignInExceptionCode.canceled => 'Connexion annulée.',
    GoogleSignInExceptionCode.interrupted =>
      'La connexion avec Google a été interrompue. Réessayez.',
    GoogleSignInExceptionCode.clientConfigurationError ||
    GoogleSignInExceptionCode.providerConfigurationError =>
      'La connexion avec Google n\'est pas disponible pour le moment.',
    GoogleSignInExceptionCode.uiUnavailable =>
      'Impossible d\'ouvrir la fenêtre Google. Réessayez.',
    _ => 'La connexion avec Google a échoué. Réessayez, ou connectez-vous '
        'avec votre e-mail et votre mot de passe.',
  };
}
