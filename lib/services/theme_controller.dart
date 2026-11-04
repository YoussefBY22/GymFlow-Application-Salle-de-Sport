import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme.dart';

/// Choix d'apparence de la personne (réglage Paramètres → Apparence).
enum AppearanceMode {
  system('Automatique'),
  light('Clair'),
  dark('Sombre');

  const AppearanceMode(this.label);
  final String label;
}

/// Mode clair / sombre de l'application.
///
/// Le choix est gardé sur l'appareil (pas dans le compte : un téléphone sombre
/// le reste pour tous les comptes). En « Automatique », l'application suit le
/// réglage du téléphone.
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController I = ThemeController._();

  static const _key = 'appearance_mode';

  /// Fondu circulaire au changement de mode (désactivé dans les tests).
  static bool animated = true;

  AppearanceMode _mode = AppearanceMode.system;
  bool _systemDark = false;

  /// Capture de l'écran actuel puis révélation circulaire (branchés par
  /// [ThemeTransitionHost]).
  Future<ui.Image?> Function()? captureHost;
  void Function(ui.Image image, Offset origin)? revealHost;

  AppearanceMode get mode => _mode;

  bool get isDark => switch (_mode) {
    AppearanceMode.dark => true,
    AppearanceMode.light => false,
    AppearanceMode.system => _systemDark,
  };

  /// Lit le choix gardé, avant le premier affichage.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      _mode = AppearanceMode.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => AppearanceMode.system,
      );
    } catch (_) {
      _mode = AppearanceMode.system;
    }
    _systemDark = _platformDark();
    _apply();
  }

  /// Retour à l'état de départ (tests).
  void reset() {
    _mode = AppearanceMode.system;
    _systemDark = false;
    captureHost = null;
    revealHost = null;
    _apply();
  }

  static bool _platformDark() =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
      Brightness.dark;

  /// Le téléphone vient de passer en clair / sombre.
  void platformBrightnessChanged() {
    final dark = _platformDark();
    if (dark == _systemDark) return;
    _systemDark = dark;
    if (_mode == AppearanceMode.system) {
      _apply();
      notifyListeners();
      _rebuildAll();
    }
  }

  /// Change le mode. [origin] (centre du bouton touché) donne le point de
  /// départ du fondu circulaire.
  Future<void> setMode(AppearanceMode next, {Offset? origin}) async {
    if (next == _mode) return;
    final before = isDark;
    _mode = next;
    unawaited(_save());
    if (isDark == before) {
      notifyListeners();
      return;
    }
    await _transition(before, origin);
  }

  /// Bouton soleil / lune : bascule entre clair et sombre.
  Future<void> toggle({Offset? origin}) async {
    final before = isDark;
    _mode = before ? AppearanceMode.light : AppearanceMode.dark;
    unawaited(_save());
    await _transition(before, origin);
  }

  Future<void> _transition(bool wasDark, Offset? origin) async {
    ui.Image? old;
    if (animated && origin != null) {
      try {
        old = await captureHost?.call();
      } catch (_) {
        old = null;
      }
    }
    _apply();
    notifyListeners();
    _rebuildAll();
    if (old != null && origin != null) revealHost?.call(old, origin);
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, _mode.name);
    } catch (_) {
      // Pas de stockage : le choix vaut pour cette session seulement.
    }
  }

  void _apply() {
    final dark = isDark;
    AppColors.palette = dark ? AppPalette.night : AppPalette.light;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.surface,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
      ),
    );
  }

  /// Les écrans qui lisent les couleurs directement (sans passer par le
  /// thème) ou qui sont « const » ne se redessineraient pas tout seuls :
  /// on force une reconstruction de tout l'arbre, sans perdre les états.
  void _rebuildAll() {
    void visit(Element e) {
      e.markNeedsBuild();
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
  }
}
