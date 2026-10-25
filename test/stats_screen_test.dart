// Niveau : widget (sans réseau). Écran Statistiques de l'administrateur :
// accès réservé, deux onglets distincts, onglet Google Analytics clairement
// étiqueté et ses différents états.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/analytics.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/services/backend.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'widget_helpers.dart';

Future<void> _seed(Backend b) async {
  Future<void> add(
    String name,
    String key,
    String label,
    int n, [
    double v = 0,
  ]) => b.analyticsRepo.save(
    AnalyticsCounter(
      day: '2026-09-30',
      name: name,
      key: key,
      label: label,
      count: n,
      value: v,
    ),
  );
  await add(AnalyticsEvents.viewItem, 'pr_whey', 'Whey Isolate', 7);
  await add(AnalyticsEvents.addToCart, 'pr_whey', 'Whey Isolate', 3);
  await add(AnalyticsEvents.purchaseItem, 'pr_whey', 'Whey Isolate', 2, 90);
  await add(AnalyticsEvents.purchase, '', 'Commandes', 1, 90);
  await add(AnalyticsEvents.search, 'kettlebell', 'kettlebell', 4);
  await add(AnalyticsEvents.searchEmpty, 'kettlebell', 'kettlebell', 4);
  await add(AnalyticsEvents.login, 'password', 'password', 5);
}

/// Simule l'API de rapports Google Analytics.
http.Response _gaApi(http.Request r) {
  final body = jsonDecode(r.body) as Map<String, dynamic>;
  final metrics = [for (final m in body['metrics'] as List) (m as Map)['name']];
  final dims = [
    for (final d in (body['dimensions'] as List? ?? const []))
      (d as Map)['name'],
  ];
  final List<List<Object>> rows;
  if (dims.isEmpty) {
    rows = r.url.path.endsWith(':runRealtimeReport')
        ? [
            [3],
          ]
        : [
            [11, 4, 15, 71],
          ];
  } else if (dims.first == 'eventName') {
    rows = [
      ['view_item', 60, 8],
    ];
  } else if (dims.first == 'deviceCategory') {
    rows = [
      ['mobile', 9],
    ];
  } else {
    rows = [];
  }
  return http.Response(
    jsonEncode({
      'dimensionHeaders': [
        for (final d in dims) {'name': d},
      ],
      'metricHeaders': [
        for (final m in metrics) {'name': m},
      ],
      'rows': [
        for (final row in rows)
          {
            'dimensionValues': [
              for (final v in row.take(dims.length)) {'value': '$v'},
            ],
            'metricValues': [
              for (final v in row.skip(dims.length)) {'value': '$v'},
            ],
          },
      ],
    }),
    200,
  );
}

void main() {
  test('la route est réservée au super admin', () {
    expect(Routes.rolesFor(Routes.adminStats), {UserRole.superAdmin});
  });

  testWidgets('un abonné ne peut pas ouvrir les statistiques', (tester) async {
    await pumpApp(tester, route: Routes.home, loginEmail: 'nour@gymflow.tn');
    await go(tester, Routes.adminStats);
    expect(find.text('Accès réservé'), findsOneWidget);
    expect(find.byKey(const Key('stats_tab_local')), findsNothing);
  });

  testWidgets('le tableau de bord admin a un bouton Statistiques', (
    tester,
  ) async {
    await pumpApp(tester, route: Routes.home, loginEmail: 'admin@gymflow.tn');
    expect(find.byKey(const Key('admin_stats_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('admin_stats_button')));
    await settle(tester);
    expect(find.byKey(const Key('stats_tab_local')), findsOneWidget);
    expect(find.byKey(const Key('stats_tab_ga')), findsOneWidget);
  });

  testWidgets('onglet GymFlow : source indiquée, chiffres et recherches', (
    tester,
  ) async {
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'admin@gymflow.tn',
    );
    await _seed(b);
    await go(tester, Routes.adminStats);

    expect(find.textContaining('Source : GymFlow'), findsOneWidget);
    expect(find.textContaining('Source : Google Analytics'), findsNothing);
    expect(find.text('Produits consultés'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('Recherches sans résultat'),
      300,
      scrollable: mainScrollable(tester),
    );
    expect(find.text('Recherches sans résultat'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Achats réels (toutes les commandes)'),
      300,
      scrollable: mainScrollable(tester),
    );
    expect(find.text('Achats réels (toutes les commandes)'), findsOneWidget);
  });

  testWidgets('onglet GymFlow vide : message explicatif', (tester) async {
    await pumpApp(tester, route: Routes.home, loginEmail: 'admin@gymflow.tn');
    await go(tester, Routes.adminStats);
    expect(find.textContaining('Pas encore de mesure'), findsOneWidget);
  });

  testWidgets('onglet Google Analytics non configuré : étapes à suivre', (
    tester,
  ) async {
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'admin@gymflow.tn',
    );
    b.gaReport.propertyId = '';
    await go(tester, Routes.adminStats);
    await tester.tap(find.byKey(const Key('stats_tab_ga')));
    await settle(tester);

    expect(find.byKey(const Key('ga_banner')), findsOneWidget);
    expect(find.text('Source : Google Analytics 4'), findsOneWidget);
    expect(
      find.textContaining('Ces chiffres viennent de Google'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('ga_setup')), findsOneWidget);
    // Les sources restent séparées : pas de bandeau GymFlow dans cet onglet.
    expect(find.textContaining('Source : GymFlow'), findsNothing);
  });

  testWidgets('configuré mais non connecté : bouton de connexion Google', (
    tester,
  ) async {
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'admin@gymflow.tn',
    );
    b.analytics.measurementId = 'G-TEST';
    b.analytics.apiSecret = 'secret';
    b.gaReport.propertyId = '123456789';
    b.gaReport.authorizer = ({bool prompt = false}) async => null;
    await go(tester, Routes.adminStats);
    await tester.tap(find.byKey(const Key('stats_tab_ga')));
    await settle(tester);
    expect(find.byKey(const Key('ga_connect_button')), findsOneWidget);
    expect(find.byKey(const Key('ga_setup')), findsNothing);
  });

  testWidgets('connecté : rapport Google, étiqueté comme tel', (tester) async {
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'admin@gymflow.tn',
      httpClient: MockClient((r) async {
        if (r.url.host != 'analyticsdata.googleapis.com') {
          return http.Response('{}', 200);
        }
        return _gaApi(r);
      }),
    );
    b.analytics.measurementId = 'G-TEST';
    b.analytics.apiSecret = 'secret';
    b.gaReport.propertyId = '123456789';
    b.gaReport.authorizer = ({bool prompt = false}) async => {
      'Authorization': 'Bearer t',
    };
    await go(tester, Routes.adminStats);
    await tester.tap(find.byKey(const Key('stats_tab_ga')));
    await settle(tester, 1500);

    expect(find.text('Source : Google Analytics 4'), findsOneWidget);
    expect(find.text('Utilisateurs actifs'), findsOneWidget);
    expect(find.text('71'), findsOneWidget); // événements du rapport
    expect(find.byKey(const Key('ga_refresh')), findsOneWidget);
    expect(find.byKey(const Key('ga_test')), findsOneWidget);
  });
}
