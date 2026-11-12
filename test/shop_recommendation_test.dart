import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/app.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/models/json.dart';
import 'package:gymflow/models/session_log.dart';
import 'package:gymflow/models/shop.dart';
import 'package:gymflow/screens/shop/shop_screens.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/gemini_client.dart';
import 'package:gymflow/services/shop_recommendation_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

http.Response _gemini(String text) => http.Response(
  jsonEncode({
    'candidates': [
      {
        'content': {
          'parts': [
            {'text': text},
          ],
        },
      },
    ],
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// Paniers fictifs : 20 commandes au total.
List<Set<String>> _baskets() => [
  for (var i = 0; i < 8; i++) {'whey', 'shaker'},
  for (var i = 0; i < 4; i++) {'iso', 'bottle'},
  for (var i = 0; i < 2; i++) {'whey', 'iso'},
  for (var i = 0; i < 6; i++) {'mat'},
];

Future<void> _order(Backend b, String userId, String productId, int daysAgo) {
  final p = b.products.byId(productId)!;
  return b.orders.save(
    ShopOrder(
      id: 'o_test_$productId',
      number: 'GF-TEST-$productId',
      userId: userId,
      lines: [
        OrderLine(
          productId: p.id,
          name: p.name,
          unitPrice: p.effectivePrice,
          quantity: 1,
        ),
      ],
      status: OrderStatus.delivered,
      paymentMethod: 'simulated',
      paymentRef: 'SIM-TEST',
      createdAt: b.now().subtract(Duration(days: daysAgo)),
    ),
  );
}

Future<void> _setGoal(Backend b, String userId, Goal goal) =>
    b.users.save(b.users.byId(userId)!.copyWith(goal: goal));

void main() {
  group('règles d\'association', () {
    test('paniers fictifs → paires, confiance et lift attendus', () {
      final rules = ShopRecommendationService.associationRules(_baskets());
      AssociationRule? rule(String a, String c) =>
          rules.where((r) => r.from == a && r.to == c).firstOrNull;

      // whey → shaker : 8 paniers sur 10 avec whey ; P(shaker) = 8/20.
      final ws = rule('whey', 'shaker')!;
      expect(ws.count, 8);
      expect(ws.support, closeTo(0.4, 1e-9));
      expect(ws.confidence, closeTo(0.8, 1e-9));
      expect(ws.lift, closeTo(2.0, 1e-9));
      // iso → bottle : 4/6, P(bottle) = 4/20 → lift 3,33.
      final ib = rule('iso', 'bottle')!;
      expect(ib.confidence, closeTo(4 / 6, 1e-9));
      expect(ib.lift, closeTo((4 / 6) / 0.2, 1e-9));
      expect(rule('bottle', 'iso')!.confidence, 1);
      // whey → iso : confiance 0,2 mais lift < 1 → écartée.
      expect(rule('whey', 'iso'), isNull);
      expect(rule('iso', 'whey'), isNull);
      // Le tapis n'est jamais acheté avec autre chose.
      expect(rules.any((r) => r.from == 'mat' || r.to == 'mat'), isFalse);
      // Tri par confiance décroissante.
      for (var i = 1; i < rules.length; i++) {
        expect(
          rules[i - 1].confidence,
          greaterThanOrEqualTo(rules[i].confidence),
        );
      }
    });

    test('seuil minimal de données et paire trop rare', () {
      expect(
        ShopRecommendationService.associationRules(_baskets().take(19)),
        isEmpty,
      );
      final rare = [
        {'a', 'b'},
        for (var i = 0; i < 19; i++) {'c'},
      ];
      expect(ShopRecommendationService.associationRules(rare), isEmpty);
    });

    test('jeu de démo : whey → shaker, gants → ceinture', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final whey = b.recommendations.boughtTogether('pr_whey');
      expect(whey.map((r) => r.product.id), contains('pr_shaker'));
      expect(whey.first.reason, contains('% des commandes'));
      final gloves = b.recommendations.boughtTogether('pr_gloves');
      expect(gloves.first.product.id, 'pr_belt');
      // Les produits en rupture ne sont jamais proposés.
      for (final p in b.products.all) {
        expect(
          b.recommendations.boughtTogether(p.id).map((r) => r.product.id),
          isNot(contains('pr_bcaa')),
        );
      }
    });
  });

  group('pour votre objectif', () {
    test('prise de masse → produits protéinés, au meilleur prix', () async {
      final b = await makeBackend();
      await _setGoal(b, 'u_nour', Goal.muscleGain);
      await loginAs(b, 'nour@gymflow.tn');
      final picks = b.recommendations.forGoal();
      expect(picks.map((r) => r.product.id).take(3), [
        'pr_whey',
        'pr_isolate',
        'pr_bar',
      ]);
      for (final r in picks.take(3)) {
        expect(r.product.nutrition!.proteins, greaterThanOrEqualTo(20));
        expect(r.reason, contains('le gramme de protéine'));
      }
      // Prix du gramme : 189 DT / 1 600 g = 0,118 DT.
      expect(picks.first.reason, contains('0,118 DT'));
      // Les vêtements ne servent pas cet objectif.
      expect(
        picks.where((r) => r.product.category == ProductCategory.clothing),
        isEmpty,
      );
    });

    test('exclusions : inactif, rupture, acheté récemment', () async {
      final b = await makeBackend();
      await _setGoal(b, 'u_nour', Goal.muscleGain);
      await loginAs(b, 'nour@gymflow.tn');
      await _order(b, 'u_nour', 'pr_whey', 5);
      await b.products.save(
        b.products.byId('pr_isolate')!.copyWith(active: false),
      );
      final ids = b.recommendations.forGoal(limit: 20).map((r) => r.product.id);
      expect(ids, isNot(contains('pr_whey')));
      expect(ids, isNot(contains('pr_isolate')));
      expect(ids, isNot(contains('pr_bcaa'))); // stock 0
      expect(ids.first, 'pr_bar');

      // Acheté il y a plus de 30 jours : de nouveau proposé.
      await _order(b, 'u_nour', 'pr_whey', 40);
      expect(
        b.recommendations.forGoal().map((r) => r.product.id),
        contains('pr_whey'),
      );

      // Les boissons restent proposées même après un achat récent.
      await _setGoal(b, 'u_nour', Goal.endurance);
      await _order(b, 'u_nour', 'pr_iso', 2);
      expect(b.recommendations.forGoal().first.product.id, 'pr_iso');
    });

    test('assiduité des 14 derniers jours dans la raison', () async {
      final b = await makeBackend();
      await _setGoal(b, 'u_nour', Goal.muscleGain);
      await loginAs(b, 'nour@gymflow.tn');
      expect(b.recommendations.recentSessions('u_nour'), 0);
      final model = b.sessions.all.first;
      for (var i = 1; i <= 4; i++) {
        await b.sessions.save(
          SessionLog.fromJson({
            ...model.toJson(),
            'id': 's_test_$i',
            'userId': 'u_nour',
            'startedAt': dateToJson(b.now().subtract(Duration(days: i * 3))),
          }),
        );
      }
      // La séance d'il y a 15 jours n'est pas comptée.
      await b.sessions.save(
        SessionLog.fromJson({
          ...model.toJson(),
          'id': 's_test_old',
          'userId': 'u_nour',
          'startedAt': dateToJson(b.now().subtract(const Duration(days: 15))),
        }),
      );
      expect(b.recommendations.recentSessions('u_nour'), 4);
      expect(
        b.recommendations.forGoal().first.reason,
        contains('4 séances ces 14 derniers jours'),
      );
    });

    test('perte de poids : jamais de produit riche en sucres', () async {
      final b = await makeBackend();
      await _setGoal(b, 'u_nour', Goal.weightLoss);
      await loginAs(b, 'nour@gymflow.tn');
      final picks = b.recommendations.forGoal(limit: 20);
      expect(picks, isNotEmpty);
      for (final r in picks) {
        expect(r.product.nutrition?.sugarLevel, isNot('élevé'));
      }
    });
  });

  group('reformulation par l\'IA', () {
    const reason = 'Présent dans 45 % des commandes, 2,3 fois plus souvent.';

    test('réponse validée : chiffres inchangés, sans lien ni balise', () {
      expect(
        ShopRecommendationService.parsePhrase(
          '{"phrase": "Choisi dans 45 % des commandes, 2,3 fois plus que la moyenne."}',
          reason,
        ),
        isNotNull,
      );
      // Chiffre inventé par l'IA.
      expect(
        ShopRecommendationService.parsePhrase(
          '{"phrase": "Choisi dans 90 % des commandes de nos abonnés."}',
          reason,
        ),
        isNull,
      );
      expect(
        ShopRecommendationService.parsePhrase(
          '{"phrase": "Voir https://exemple.tn pour 45 % de réduction."}',
          reason,
        ),
        isNull,
      );
      expect(
        ShopRecommendationService.parsePhrase('pas du JSON', reason),
        isNull,
      );
      // Accents abîmés : refusé, le texte calculé est utilisé à la place.
      expect(
        ShopRecommendationService.parsePhrase(
          '{"phrase": "Choisi dans 45 % des commandes, idÃ©al pour vous."}',
          reason,
        ),
        isNull,
      );
    });

    test('sans clé, en erreur ou réponse invalide : texte calculé', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final r = ShopRecommendation(
        product: b.products.byId('pr_whey')!,
        reason: reason,
        score: 1,
      );
      b.gemini = GeminiClient(
        MockClient((_) async => _gemini('{}')),
        apiKey: '',
      );
      expect(await b.recommendations.explain(r), reason);

      b.gemini = GeminiClient(
        MockClient(
          (_) async => _gemini('{"phrase": "Acheté par 99 % des sportifs !"}'),
        ),
        apiKey: 'test',
      );
      expect(await b.recommendations.explain(r), reason);

      var calls = 0;
      b.gemini = GeminiClient(
        MockClient((_) async {
          calls++;
          return _gemini(
            '{"phrase": "Souvent pris ensemble : 45 % des commandes, 2,3 fois plus que la moyenne."}',
          );
        }),
        apiKey: 'test',
      );
      final phrase = await b.recommendations.explain(r);
      expect(phrase, startsWith('Souvent pris ensemble'));
      // Mise en cache : pas de second appel.
      expect(await b.recommendations.explain(r), phrase);
      expect(calls, 1);
    });

    test('après une erreur, l\'IA n\'est plus appelée', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      var calls = 0;
      b.gemini = GeminiClient(
        MockClient((_) async {
          calls++;
          return http.Response('quota', 429);
        }),
        apiKey: 'test',
      );
      final r = ShopRecommendation(
        product: b.products.byId('pr_bar')!,
        reason: reason,
        score: 1,
      );
      expect(await b.recommendations.explain(r), reason);
      expect(await b.recommendations.explain(r), reason);
      expect(calls, 1);
      expect(b.recommendations.aiEnabled, isFalse);
    });
  });

  test('jeu de démo : 110 commandes déterministes sur 90 jours', () async {
    final a = await makeBackend();
    final hist = a.orders.where((o) => o.id.startsWith('o_hist_'));
    expect(hist.length, 110);
    final first = hist.firstWhere((o) => o.id == 'o_hist_1');
    for (final o in hist) {
      final days = testNow.difference(o.createdAt).inDays;
      expect(days, inInclusiveRange(0, 90));
      expect(o.userId, isNot('u_nour'));
    }
    expect(hist.map((o) => o.status).toSet(), OrderStatus.values.toSet());
    // Rouleau et serviette ne sont jamais vendus (classe C).
    final sold = {
      for (final o in hist)
        for (final l in o.lines) l.productId,
    };
    expect(sold, isNot(contains('pr_roller')));
    expect(sold, isNot(contains('pr_towel')));
    // Numéros uniques.
    final numbers = a.orders.all.map((o) => o.number).toList();
    expect(numbers.toSet().length, numbers.length);

    final b = await makeBackend();
    final same = b.orders.byId('o_hist_1')!;
    expect(same.toJson(), first.toJson());
  });

  group('Écrans', () {
    testWidgets('accueil boutique : « Pour votre objectif » avec raison', (
      tester,
    ) async {
      await pumpApp(tester, route: Routes.home, loginEmail: 'rami@gymflow.tn');
      GymFlowApp.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const ShopScreen()),
      );
      await settle(tester);
      expect(find.byKey(const Key('goal_picks')), findsOneWidget);
      expect(find.text('Pour votre objectif : prise de masse'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fiche produit : « Souvent achetés ensemble »', (tester) async {
      await pumpApp(tester, route: Routes.home, loginEmail: 'ahmed@gymflow.tn');
      await go(tester, Routes.product, 'pr_gloves');
      final strip = find.byKey(const Key('bought_together'));
      await tester.scrollUntilVisible(
        strip,
        300,
        scrollable: mainScrollable(tester),
      );
      expect(strip, findsOneWidget);
      expect(
        find.descendant(
          of: strip,
          matching: find.text('Ceinture de musculation'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('% des commandes'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
