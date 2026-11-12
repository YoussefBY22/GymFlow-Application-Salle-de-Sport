import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/routes.dart';
import 'core/theme.dart';
import 'services/backend.dart';
import 'services/theme_controller.dart';
import 'widgets/theme_toggle.dart';

void _noteActivity() {
  if (Backend.isReady) Backend.I.friends.noteActivity();
}

/// Racine de l'application (cours S01 : MaterialApp + arbre de widgets).
class GymFlowApp extends StatefulWidget {
  const GymFlowApp({super.key, this.initialRoute = Routes.splash});

  final String initialRoute;

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  State<GymFlowApp> createState() => _GymFlowAppState();
}

class _GymFlowAppState extends State<GymFlowApp> with WidgetsBindingObserver {
  final _theme = ThemeController.I;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Au premier plan l'abonné compte dans « connectés maintenant » ; dès qu'il
  /// quitte l'application (accueil, écran éteint, fermeture), il disparaît.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Backend.isReady) return;
    Backend.I.live.setForeground(state == AppLifecycleState.resumed);
  }

  /// Le téléphone passe en clair / sombre : on suit en mode « Automatique ».
  @override
  void didChangePlatformBrightness() => _theme.platformBrightnessChanged();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: _theme, builder: _buildApp);
  }

  Widget _buildApp(BuildContext context, Widget? _) {
    final initialRoute = widget.initialRoute;
    return MaterialApp(
      title: 'GymFlow',
      debugShowCheckedModeBanner: false,
      navigatorKey: GymFlowApp.navigatorKey,
      // Clair ou sombre (bleu nuit) : un seul thème, reconstruit au changement
      // (voir ThemeController).
      theme: _theme.isDark ? AppTheme.dark() : AppTheme.light(),
      themeMode: ThemeMode.light,
      // Ordinateur : carrousels, bannière et présentation se font glisser
      // aussi à la souris / au pavé tactile (pas seulement au doigt).
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      locale: const Locale('fr', 'FR'),
      supportedLocales: const [Locale('fr', 'FR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      initialRoute: initialRoute,
      // Une seule route initiale (sinon « /home » empilerait aussi « / »).
      onGenerateInitialRoutes: (name) => [
        Routes.onGenerateRoute(RouteSettings(name: name)),
      ],
      onGenerateRoute: Routes.onGenerateRoute,
      // Chaque geste (toucher, défilement, souris) garde la personne « en
      // ligne » pour ses amis ; sans geste pendant 2 minutes, elle ne l'est plus.
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _noteActivity(),
        onPointerMove: (_) => _noteActivity(),
        onPointerSignal: (_) => _noteActivity(),
        child: ThemeTransitionHost(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
