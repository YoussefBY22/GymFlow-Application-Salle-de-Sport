import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/web_only.dart' as google;

/// Sur le web, Google impose son propre bouton : l'application n'a pas le
/// droit d'ouvrir la fenêtre de connexion elle-même. On le demande à la
/// taille large, en français, pour rester cohérent avec l'écran.
Widget? googleRenderedButton() => google.renderButton(
  configuration: google.GSIButtonConfiguration(
    theme: google.GSIButtonTheme.outline,
    size: google.GSIButtonSize.large,
    text: google.GSIButtonText.continueWith,
    shape: google.GSIButtonShape.rectangular,
    locale: 'fr',
    minimumWidth: 280,
  ),
);
