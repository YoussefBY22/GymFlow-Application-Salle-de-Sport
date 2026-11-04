import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'contrast.dart';

/// Couleurs « de rôle » : fonds, cartes, textes et bordures. Elles changent
/// avec le mode clair / sombre ; les couleurs de marque (marine, rouge, or,
/// blanc) restent fixes dans [AppColors].
class AppPalette {
  const AppPalette({
    required this.dark,
    required this.background,
    required this.surface,
    required this.cream,
    required this.ink,
    required this.inkSoft,
    required this.heading,
    required this.outline,
    required this.divider,
    required this.skeleton,
    required this.successSoft,
    required this.redSoft,
    required this.redText,
    required this.successText,
  });

  final bool dark;

  /// Fond d'écran.
  final Color background;

  /// Cartes, boîtes de dialogue, barre du bas (blanc en mode clair).
  final Color surface;

  /// Cartes « chaudes » (crème en mode clair).
  final Color cream;

  /// Texte principal et secondaire.
  final Color ink;
  final Color inkSoft;

  /// Titres, icônes et contours qui étaient en marine : clairs en mode sombre.
  final Color heading;

  final Color outline;
  final Color divider;
  final Color skeleton;
  final Color successSoft;
  final Color redSoft;

  /// Rouge et vert quand ils servent de texte ou d'icône sur un fond neutre.
  final Color redText;
  final Color successText;

  static const light = AppPalette(
    dark: false,
    background: Color(0xFFF5F5F0),
    surface: Color(0xFFFFFFFF),
    cream: Color(0xFFFFF4E0),
    ink: Color(0xFF1F2937),
    inkSoft: Color(0xFF4B5563),
    heading: Color(0xFF002855),
    outline: Color(0xFF6B7280),
    divider: Color(0xFFE5E3DC),
    skeleton: Color(0xFFE7E5DE),
    successSoft: Color(0xFFDCFCE7),
    redSoft: Color(0xFFFDE8EC),
    redText: Color(0xFFBA0C2F),
    successText: Color(0xFF166534),
  );

  /// Bleu nuit : tous les textes ont un contraste d'au moins 4,5:1.
  static const night = AppPalette(
    dark: true,
    background: Color(0xFF0A1220),
    surface: Color(0xFF121D33),
    cream: Color(0xFF1B2943),
    ink: Color(0xFFE6ECF5),
    inkSoft: Color(0xFFAAB6C9),
    heading: Color(0xFFE3ECFA),
    outline: Color(0xFF8795AE),
    divider: Color(0xFF27354F),
    skeleton: Color(0xFF1D2A45),
    successSoft: Color(0xFF12331F),
    redSoft: Color(0xFF3A1620),
    redText: Color(0xFFFF7A93),
    successText: Color(0xFF4ADE80),
  );
}

/// Palette du design system GymFlow, en mode clair ou sombre (bleu nuit).
class AppColors {
  AppColors._();

  // Couleurs de marque : identiques dans les deux modes.
  static const Color navy = Color(0xFF002855); // Primary
  static const Color red = Color(0xFFBA0C2F); // Action / énergie
  static const Color gold = Color(0xFFFFCF70); // Badges, records, étoiles
  static const Color white = Color(0xFFFFFFFF);

  /// Crème clair fixe : texte secondaire sur fond marine (ne suit pas le mode).
  static const Color creamText = Color(0xFFFFF4E0);
  static const Color navyMuted = Color(
    0xFFB9C3D1,
  ); // Texte secondaire sur marine
  static const Color success = Color(0xFF166534); // Vert foncé (texte blanc)
  static const Color overlay = Color(0xCC00101F); // Voile sombre sur photo

  /// Couleurs de catégories (graphiques, avatars) — toutes lisibles avec du blanc.
  static const List<Color> accents = [
    navy,
    red,
    Color(0xFF0F5E9C),
    Color(0xFF7A1F5C),
    Color(0xFF166534),
    Color(0xFF8A4B08),
  ];

  /// Palette en cours (changée par le thème choisi dans Paramètres).
  static AppPalette palette = AppPalette.light;

  static bool get isDark => palette.dark;

  // Couleurs de rôle : suivent le mode clair / sombre.
  static Color get background => palette.background;
  static Color get surface => palette.surface;
  static Color get cream => palette.cream;
  static Color get ink => palette.ink;
  static Color get inkSoft => palette.inkSoft;
  static Color get heading => palette.heading;
  static Color get outline => palette.outline;
  static Color get divider => palette.divider;
  static Color get skeleton => palette.skeleton;
  static Color get successSoft => palette.successSoft;
  static Color get redSoft => palette.redSoft;
  static Color get redText => palette.redText;
  static Color get successText => palette.successText;

  /// Couleur de texte, d'icône ou de graphique : la marine devient claire en
  /// mode sombre (sinon elle serait invisible sur le fond nuit).
  static Color fg(Color c) => c == navy ? heading : c;
}

/// Retourne la couleur de texte/icône lisible sur [background] :
/// blanc sur les fonds foncés (marine, rouge…), marine sur les fonds clairs.
/// Règle de lisibilité : jamais foncé sur foncé, jamais clair sur clair.
Color onColor(Color background) {
  if (background == AppColors.gold) return AppColors.navy;
  if (background == AppColors.navy || background == AppColors.red) {
    return AppColors.white;
  }
  final withWhite = contrastRatio(background, AppColors.white);
  final withNavy = contrastRatio(background, AppColors.navy);
  return withWhite >= withNavy ? AppColors.white : AppColors.navy;
}

/// Espacements (grille de 8 px) et rayons.
class Gap {
  Gap._();
  static const double xs = 4;
  static const double s = 8;
  static const double m = 16;
  static const double l = 24;
  static const double xl = 32;
  static const double radius = 16;
}

/// Styles de texte : Poppins pour titres et gros chiffres, Inter pour le texte.
/// Sans couleur précise, la couleur suit le mode clair / sombre.
class AppText {
  AppText._();

  static TextStyle display({Color? color, double size = 34}) =>
      GoogleFonts.poppins(
        fontSize: size,
        fontWeight: FontWeight.w800,
        color: color ?? AppColors.heading,
        height: 1.1,
      );

  static TextStyle title({Color? color, double size = 20}) =>
      GoogleFonts.poppins(
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: color ?? AppColors.heading,
        height: 1.2,
      );

  static TextStyle subtitle({Color? color, double size = 16}) =>
      GoogleFonts.poppins(
        fontSize: size,
        fontWeight: FontWeight.w600,
        color: color ?? AppColors.heading,
      );

  static TextStyle body({Color? color, double size = 15}) => GoogleFonts.inter(
    fontSize: size,
    color: color ?? AppColors.ink,
    height: 1.4,
  );

  static TextStyle label({Color? color, double size = 13}) => GoogleFonts.inter(
    fontSize: size,
    fontWeight: FontWeight.w500,
    color: color ?? AppColors.inkSoft,
  );

  static TextStyle stat({Color? color, double size = 22}) =>
      GoogleFonts.poppins(
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: color ?? AppColors.heading,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

/// Thèmes Material de l'application : clair et sombre (bleu nuit).
class AppTheme {
  AppTheme._();

  static ThemeData light() => _build(AppPalette.light);

  static ThemeData dark() => _build(AppPalette.night);

  /// Construit le thème d'une palette. Les styles de texte lisent la palette
  /// en cours : on la change le temps de la construction, puis on la rétablit.
  static ThemeData _build(AppPalette p) {
    final previous = AppColors.palette;
    AppColors.palette = p;
    try {
      return _theme(p);
    } finally {
      AppColors.palette = previous;
    }
  }

  static ThemeData _theme(AppPalette p) {
    final scheme = ColorScheme(
      brightness: p.dark ? Brightness.dark : Brightness.light,
      primary: p.heading,
      onPrimary: p.dark ? AppColors.navy : AppColors.white,
      secondary: AppColors.red,
      onSecondary: AppColors.white,
      tertiary: AppColors.gold,
      onTertiary: AppColors.navy,
      error: p.redText,
      onError: p.dark ? AppColors.navy : AppColors.white,
      surface: p.surface,
      onSurface: p.ink,
      onSurfaceVariant: p.inkSoft,
      surfaceContainerHighest: p.cream,
      outline: p.outline,
      outlineVariant: p.divider,
    );
    final textTheme = GoogleFonts.interTextTheme().apply(
      bodyColor: p.ink,
      displayColor: p.heading,
    );
    // Mode sombre : pas de voile de couleur sur les surfaces surélevées.
    final Color? tint = p.dark ? Colors.transparent : null;
    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Gap.radius),
    );
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: c, width: w),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.background,
      textTheme: textTheme.copyWith(
        headlineMedium: AppText.title(size: 26),
        titleLarge: AppText.title(),
        titleMedium: AppText.subtitle(),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.navy,
        foregroundColor: AppColors.white,
        elevation: 0,
        scrolledUnderElevation: p.dark ? 0 : null,
        surfaceTintColor: tint,
        centerTitle: false,
        titleTextStyle: AppText.title(color: AppColors.white, size: 19),
        iconTheme: const IconThemeData(color: AppColors.white),
        actionsIconTheme: const IconThemeData(color: AppColors.white),
      ),
      cardTheme: CardThemeData(
        color: p.surface,
        surfaceTintColor: tint,
        elevation: p.dark ? 0 : 1.5,
        shadowColor: const Color(0x22002855),
        shape: p.dark
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Gap.radius),
                side: BorderSide(color: p.divider),
              )
            : rounded,
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.red,
          foregroundColor: AppColors.white,
          disabledBackgroundColor: p.divider,
          disabledForegroundColor: p.inkSoft,
          minimumSize: const Size(64, 52),
          shape: rounded,
          textStyle: AppText.subtitle(color: AppColors.white, size: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.heading,
          minimumSize: const Size(64, 52),
          side: BorderSide(color: p.heading, width: 1.5),
          shape: rounded,
          textStyle: AppText.subtitle(size: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.heading,
          minimumSize: const Size(48, 48),
          textStyle: AppText.subtitle(size: 14),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.red,
        foregroundColor: AppColors.white,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        labelStyle: AppText.label(),
        floatingLabelStyle: AppText.label(color: p.heading),
        hintStyle: AppText.body(color: p.inkSoft),
        helperStyle: AppText.label(),
        errorStyle: AppText.label(color: p.redText, size: 12),
        prefixIconColor: p.inkSoft,
        suffixIconColor: p.inkSoft,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: border(p.outline),
        enabledBorder: border(p.outline),
        focusedBorder: border(p.heading, 2),
        errorBorder: border(p.redText),
        focusedErrorBorder: border(p.redText, 2),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: p.surface,
        selectedItemColor: p.redText,
        unselectedItemColor: p.inkSoft,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: AppText.label(color: p.redText, size: 11),
        unselectedLabelStyle: AppText.label(size: 11),
        elevation: 8,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: AppColors.white,
        unselectedLabelColor: AppColors.navyMuted,
        indicatorColor: AppColors.gold,
        indicatorSize: TabBarIndicatorSize.label,
        labelPadding: const EdgeInsets.symmetric(horizontal: 10),
        labelStyle: AppText.subtitle(color: AppColors.white, size: 13),
        unselectedLabelStyle: AppText.subtitle(
          color: AppColors.navyMuted,
          size: 13,
        ),
        dividerColor: Colors.transparent,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: tint,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.dark ? p.cream : AppColors.navy,
        contentTextStyle: AppText.body(
          color: p.dark ? p.ink : AppColors.white,
        ),
        actionTextColor: AppColors.gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: tint,
        titleTextStyle: AppText.title(size: 18),
        contentTextStyle: AppText.body(),
        shape: rounded,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: tint,
        showDragHandle: true,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.redText,
        linearTrackColor: p.divider,
      ),
      dividerTheme: DividerThemeData(color: p.divider),
      listTileTheme: ListTileThemeData(
        iconColor: p.heading,
        textColor: p.ink,
        titleTextStyle: AppText.body(color: p.ink),
        subtitleTextStyle: AppText.label(),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? AppColors.white : p.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? AppColors.success : p.divider,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? AppColors.success : p.surface,
        ),
        checkColor: const WidgetStatePropertyAll(AppColors.white),
        side: BorderSide(color: p.outline, width: 1.5),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.surface,
        surfaceTintColor: tint,
        textStyle: AppText.body(),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
