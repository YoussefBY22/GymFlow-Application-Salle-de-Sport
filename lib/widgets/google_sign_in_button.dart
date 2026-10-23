import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/backend.dart';
import '../services/google_auth_service.dart';
import 'google/google_button_io.dart'
    if (dart.library.js_interop) 'google/google_button_web.dart';
import 'google/google_g_logo.dart';

/// Bouton « Continuer avec Google ».
///
/// Deux apparences selon la plateforme, imposées par Google :
/// - **Android** : notre bouton, aux couleurs de l'application, qui ouvre
///   la fenêtre Google.
/// - **Web** : le bouton officiel de Google, que nous n'avons pas le droit
///   de remplacer. Le résultat y arrive par le flux d'identités.
///
/// Rien ne s'affiche si la connexion Google n'est pas configurée : pas de
/// bouton mort à l'écran.
class GoogleSignInButton extends StatefulWidget {
  const GoogleSignInButton({super.key, required this.onSignedIn});

  /// Appelé avec l'identité vérifiée par Google.
  final Future<void> Function(GoogleIdentity identity) onSignedIn;

  @override
  State<GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<GoogleSignInButton> {
  GoogleAuthService get _google => Backend.I.googleAuth;
  StreamSubscription<GoogleIdentity>? _sub;
  bool _busy = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    if (_google.enabled) _prepare();
  }

  Future<void> _prepare() async {
    try {
      await _google.ensureInitialized();
      _sub = _google.identities.listen(_handle);
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      // Connexion Google indisponible : l'écran reste utilisable avec
      // l'e-mail et le mot de passe.
    }
  }

  Future<void> _handle(GoogleIdentity identity) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onSignedIn(identity);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _press() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final identity = await _google.signIn();
      // `null` : fenêtre fermée sans choisir de compte, rien à signaler.
      if (identity != null) await widget.onSignedIn(identity);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_google.enabled || !_ready) return const SizedBox.shrink();
    final separator = Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.s),
          child: Text('ou', style: AppText.label(size: 12)),
        ),
        const Expanded(child: Divider()),
      ],
    );
    final button = _google.needsRenderedButton
        ? (googleRenderedButton() ?? const SizedBox.shrink())
        : OutlinedButton.icon(
            key: const Key('google_sign_in'),
            onPressed: _busy ? null : _press,
            icon: const GoogleGLogo(size: 20),
            label: const Text('Continuer avec Google'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: AppColors.navy,
              side: const BorderSide(color: AppColors.navy),
            ),
          );
    return Column(
      children: [
        const SizedBox(height: Gap.m),
        separator,
        const SizedBox(height: Gap.m),
        // Sur le web, le bouton de Google a sa propre largeur : on le
        // centre plutôt que de l'étirer.
        Opacity(
          opacity: _busy ? 0.6 : 1,
          child: IgnorePointer(ignoring: _busy, child: Center(child: button)),
        ),
      ],
    );
  }
}
