import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/core/theme.dart';
import 'package:gymflow/services/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_helpers.dart';

/// Mode clair / sombre : contrôleur, persistance, bouton soleil / lune et
/// réglage Apparence.
void main() {
  final theme = ThemeController.I;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController.animated = false;
    theme.reset();
  });
  tearDown(theme.reset);

  group('contrôleur', () {
    test('par défaut : automatique, clair quand le téléphone est clair', () {
      expect(theme.mode, AppearanceMode.system);
      expect(theme.isDark, isFalse);
      expect(AppColors.palette.dark, isFalse);
    });

    test('mode sombre : la palette de rôle passe en bleu nuit', () async {
      await theme.setMode(AppearanceMode.dark);
      expect(theme.isDark, isTrue);
      expect(AppColors.isDark, isTrue);
      expect(AppColors.background, AppPalette.night.background);
      expect(AppColors.surface, AppPalette.night.surface);
      // Les couleurs de marque ne bougent pas.
      expect(AppColors.navy, const Color(0xFF002855));
      expect(AppColors.red, const Color(0xFFBA0C2F));
      await theme.setMode(AppearanceMode.light);
      expect(AppColors.isDark, isFalse);
      expect(AppColors.background, AppPalette.light.background);
    });

    test('toggle : bascule entre clair et sombre', () async {
      await theme.toggle();
      expect(theme.isDark, isTrue);
      expect(theme.mode, AppearanceMode.dark);
      await theme.toggle();
      expect(theme.isDark, isFalse);
      expect(theme.mode, AppearanceMode.light);
    });

    test('le choix est gardé sur l\'appareil', () async {
      await theme.setMode(AppearanceMode.dark);
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('appearance_mode'), 'dark');

      theme.reset();
      expect(theme.isDark, isFalse);
      await theme.load();
      expect(theme.mode, AppearanceMode.dark);
      expect(AppColors.isDark, isTrue);
    });

    test('valeur enregistrée inconnue : retour à automatique', () async {
      SharedPreferences.setMockInitialValues({'appearance_mode': 'violet'});
      await theme.load();
      expect(theme.mode, AppearanceMode.system);
    });
  });

  group('thèmes Material', () {
    test('sombre et clair ont le bon fond et la bonne luminosité', () {
      final dark = AppTheme.dark();
      final light = AppTheme.light();
      expect(dark.brightness, Brightness.dark);
      expect(dark.scaffoldBackgroundColor, AppPalette.night.background);
      expect(light.brightness, Brightness.light);
      expect(light.scaffoldBackgroundColor, AppPalette.light.background);
      // La barre du haut reste marine dans les deux modes.
      expect(dark.appBarTheme.backgroundColor, AppColors.navy);
      expect(light.appBarTheme.backgroundColor, AppColors.navy);
    });

    test('construire un thème ne change pas la palette en cours', () {
      expect(AppColors.isDark, isFalse);
      AppTheme.dark();
      expect(AppColors.isDark, isFalse);
    });

    test('couleur de texte : la marine devient claire en mode sombre', () async {
      expect(AppColors.fg(AppColors.navy), AppColors.navy);
      await theme.setMode(AppearanceMode.dark);
      expect(AppColors.fg(AppColors.navy), AppPalette.night.heading);
      expect(AppColors.fg(AppColors.red), AppColors.red);
    });
  });

  group('écrans', () {
    testWidgets('bouton soleil / lune sur l\'accueil', (tester) async {
      await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'ahmed@gymflow.tn',
      );
      final button = find.byKey(const Key('theme_toggle'));
      expect(button, findsOneWidget);
      expect(find.byIcon(Icons.wb_sunny_rounded), findsOneWidget);

      await tester.tap(button);
      await settle(tester, 800);
      expect(theme.isDark, isTrue);
      expect(find.byIcon(Icons.nightlight_round), findsOneWidget);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor ??
            Theme.of(tester.element(find.byType(Scaffold).first))
                .scaffoldBackgroundColor,
        AppPalette.night.background,
      );

      await tester.tap(button);
      await settle(tester, 800);
      expect(theme.isDark, isFalse);
      expect(find.byIcon(Icons.wb_sunny_rounded), findsOneWidget);
    });

    testWidgets('Paramètres : réglage Apparence', (tester) async {
      await pumpApp(
        tester,
        route: Routes.settings,
        loginEmail: 'ahmed@gymflow.tn',
      );
      expect(find.byKey(const Key('settings_appearance')), findsOneWidget);
      await tester.tap(find.text('Sombre'));
      await settle(tester, 800);
      expect(theme.mode, AppearanceMode.dark);
      expect(AppColors.isDark, isTrue);

      await tester.tap(find.text('Clair'));
      await settle(tester, 800);
      expect(theme.mode, AppearanceMode.light);
      expect(AppColors.isDark, isFalse);

      await tester.tap(find.text('Auto'));
      await settle(tester, 800);
      expect(theme.mode, AppearanceMode.system);
    });
  });
}
