import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/contrast.dart';
import 'package:gymflow/core/theme.dart';

/// Règle de lisibilité : toutes les paires texte/fond utilisées dans
/// l'application respectent WCAG AA (≥ 4,5:1), en mode clair comme en mode
/// sombre (bleu nuit).
void main() {
  // Paires de couleurs de marque, identiques dans les deux modes.
  const brandPairs = <(Color, Color, String)>[
    (AppColors.navy, AppColors.white, 'AppBar, cartes marine'),
    (AppColors.navy, AppColors.creamText, 'sous-titres sur marine'),
    (AppColors.navy, AppColors.gold, 'chrono, minuteur, action SnackBar'),
    (AppColors.navy, AppColors.navyMuted, 'onglets non sélectionnés'),
    (AppColors.red, AppColors.white, 'boutons principaux, badges'),
    (AppColors.gold, AppColors.navy, 'badges dorés, records'),
    (AppColors.success, AppColors.white, 'pastilles de succès'),
  ];

  for (final (bg, fg, label) in brandPairs) {
    test('contraste ≥ 4,5 : $label', () {
      expect(
        contrastRatio(bg, fg),
        greaterThanOrEqualTo(wcagAA),
        reason: label,
      );
    });
  }

  for (final p in [AppPalette.light, AppPalette.night]) {
    final mode = p.dark ? 'sombre' : 'clair';
    // (fond, texte, contexte)
    final pairs = <(Color, Color, String)>[
      (p.cream, p.heading, 'cartes crème'),
      (p.cream, p.ink, 'texte sur crème'),
      (p.cream, p.inkSoft, 'texte secondaire sur crème'),
      (p.cream, p.redText, 'prix / alertes sur crème'),
      (p.cream, p.successText, 'succès sur crème'),
      (p.background, p.heading, 'titres sur fond'),
      (p.background, p.ink, 'texte sur fond'),
      (p.background, p.inkSoft, 'texte secondaire sur fond'),
      (p.background, p.redText, 'alertes sur fond'),
      (p.surface, p.heading, 'titres sur cartes'),
      (p.surface, p.ink, 'texte sur cartes'),
      (p.surface, p.inkSoft, 'hints, labels, onglets inactifs'),
      (p.surface, p.redText, 'prix, onglet actif, erreurs'),
      (p.surface, p.successText, 'textes de succès'),
      (p.successSoft, p.successText, 'série validée'),
      (p.redSoft, p.redText, 'bannières d\'erreur'),
      (p.redSoft, p.ink, 'texte sur bannière d\'erreur'),
      (p.inkSoft, p.surface, 'pastille « archivé »'),
    ];
    for (final (bg, fg, label) in pairs) {
      test('mode $mode, contraste ≥ 4,5 : $label', () {
        expect(
          contrastRatio(bg, fg),
          greaterThanOrEqualTo(wcagAA),
          reason: label,
        );
      });
    }

    test('mode $mode : éléments graphiques (bordures, icônes) ≥ 3:1', () {
      expect(
        contrastRatio(p.surface, p.outline),
        greaterThanOrEqualTo(wcagAALarge),
      );
      expect(
        contrastRatio(p.background, p.outline),
        greaterThanOrEqualTo(wcagAALarge),
      );
    });
  }

  test('toutes les couleurs d\'accent portent du texte blanc lisible', () {
    for (final c in AppColors.accents) {
      expect(contrastRatio(c, onColor(c)), greaterThanOrEqualTo(wcagAA));
    }
  });

  test('onColor : blanc sur foncé, marine sur clair', () {
    expect(onColor(AppColors.navy), AppColors.white);
    expect(onColor(AppColors.red), AppColors.white);
    expect(onColor(AppColors.gold), AppColors.navy);
    expect(onColor(AppPalette.light.cream), AppColors.navy);
    expect(onColor(AppPalette.light.surface), AppColors.navy);
    expect(onColor(AppPalette.light.background), AppColors.navy);
    expect(onColor(AppColors.success), AppColors.white);
    // Mode sombre : les surfaces nuit portent du texte blanc.
    expect(onColor(AppPalette.night.surface), AppColors.white);
    expect(onColor(AppPalette.night.background), AppColors.white);
  });

  test('ratio de référence : noir sur blanc = 21', () {
    expect(
      contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
      closeTo(21, 0.01),
    );
  });
}
