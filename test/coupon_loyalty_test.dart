import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/core/formatters.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/models/json.dart';
import 'package:gymflow/models/loyalty.dart';
import 'package:gymflow/models/session_log.dart';
import 'package:gymflow/models/shop.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/coupon_loyalty_service.dart';
import 'package:gymflow/services/payment/payment_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

List<CartLine> _lines(Backend b, Map<String, int> items) => [
  for (final e in items.entries)
    CartLine(product: b.products.byId('pr_${e.key}')!, quantity: e.value),
];

Future<PaymentResult> _pay(
  Backend b,
  double amount, [
  String card = '4242424242424242',
]) => (b.payment as SimulatedPaymentGateway).charge(
  cardNumber: card,
  expiry: '12/30',
  cvc: '123',
  amount: amount,
  now: b.now(),
);

/// Achat complet : devis, paiement du montant exact, commande.
Future<ShopOrder> _buy(
  Backend b,
  Map<String, int> items, {
  String? code,
  int points = 0,
}) async {
  final lines = _lines(b, items);
  final q = b.couponLoyalty.quote(lines, code: code, points: points);
  final pay = await _pay(b, q.total);
  return b.orderService.placeOrder(
    lines,
    pay,
    couponCode: code,
    points: points,
  );
}

Matcher _rule(String text) => throwsA(
  isA<BusinessRuleException>().having(
    (e) => e.message,
    'message',
    contains(text),
  ),
);

Future<Coupon> _coupon(
  Backend b,
  String code, {
  DiscountType type = DiscountType.percent,
  double value = 10,
  double minAmount = 0,
  int? maxUses,
  int? perUser = 1,
  ProductCategory? category,
  DateTime? startsAt,
  DateTime? expiresAt,
  bool active = true,
}) async {
  final me = b.auth.currentUser;
  await loginAs(b, 'admin@gymflow.tn');
  final c = await b.couponLoyalty.saveCoupon(
    code: code,
    label: 'Code de test',
    type: type,
    value: value,
    minAmount: minAmount,
    maxUses: maxUses,
    maxUsesPerUser: perUser,
    category: category,
    startsAt: startsAt,
    expiresAt: expiresAt,
    active: active,
  );
  if (me != null) await loginAs(b, me.email);
  return c;
}

void main() {
  group('modèles', () {
    test('anciennes commandes : mêmes totaux, sans migration', () {
      final j = {
        'id': 'o1',
        'number': 'GF-2026-0001',
        'userId': 'u1',
        'lines': [
          {'productId': 'p', 'name': 'P', 'unitPrice': 20, 'quantity': 2},
        ],
        'status': 'paid',
        'createdAt': dateToJson(testNow),
      };
      final o = ShopOrder.fromJson(j);
      expect(o.discount, 0);
      expect(o.stamp, 0);
      expect(o.total, 40);
      expect(o.netSales, 40);
      final copy = ShopOrder.fromJson(
        jsonDecode(jsonEncode({...j, 'discount': 5, 'stamp': 1}))
            as Map<String, dynamic>,
      );
      expect(copy.subtotal, 40);
      expect(copy.total, 36);
      expect(copy.anonymized('anonyme-1').total, 36);
      expect(copy.copyWith(status: OrderStatus.delivered).stamp, 1);
      // Code sans « par personne » enregistré : 1 par défaut.
      final c = Coupon.fromJson({'id': 'c', 'code': 'abc', 'value': 5});
      expect(c.code, 'ABC');
      expect(c.maxUsesPerUser, 1);
      expect(LoyaltyAccount.fromJson({'id': 'u1'}).balance, 0);
    });
  });

  group('règles des codes promo', () {
    test('devis sans réduction : sous-total + timbre', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final q = b.couponLoyalty.quote(_lines(b, {'shaker': 2}));
      expect(q.subtotal, 36);
      expect(q.stamp, 1);
      expect(q.total, 37);
      expect(q.pointsToEarn, 36);
      expect(q.label, isNull);
    });

    test('code inconnu, inactif, expiré, pas encore valable', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final lines = _lines(b, {'whey': 1});
      expect(
        () => b.couponLoyalty.quote(lines, code: 'NIMPORTE'),
        throwsA(isA<ValidationException>()),
      );
      // RENTREE5 : expiré il y a 10 jours (jeu de démo).
      expect(
        () => b.couponLoyalty.quote(lines, code: 'rentree5'),
        _rule('expiré'),
      );
      await _coupon(
        b,
        'PLUSTARD',
        startsAt: testNow.add(const Duration(days: 3)),
      );
      expect(
        () => b.couponLoyalty.quote(lines, code: 'PLUSTARD'),
        _rule('valable à partir du'),
      );
      await _coupon(b, 'ARRET', active: false);
      expect(
        () => b.couponLoyalty.quote(lines, code: 'ARRET'),
        _rule('plus actif'),
      );
      // Expire en fin de journée : encore valable le jour même.
      await _coupon(
        b,
        'AUJOURDHUI',
        expiresAt: testNow.add(const Duration(hours: 1)),
      );
      expect(
        b.couponLoyalty.quote(lines, code: 'AUJOURDHUI').couponDiscount,
        18.9,
      );
      setNow(testNow.add(const Duration(hours: 2)));
      expect(
        () => b.couponLoyalty.quote(lines, code: 'AUJOURDHUI'),
        _rule('expiré'),
      );
    });

    test('montant minimum', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      // BIENVENUE10 : 10 % dès 30 DT.
      expect(
        () => b.couponLoyalty.quote(
          _lines(b, {'shaker': 1}),
          code: 'BIENVENUE10',
        ),
        _rule('au moins'),
      );
      final q = b.couponLoyalty.quote(
        _lines(b, {'shaker': 2}),
        code: 'bienvenue10',
      );
      expect(q.couponDiscount, 3.6);
      expect(q.total, 36 - 3.6 + 1);
      expect(q.label, 'Code BIENVENUE10 (-10 %)');
    });

    test('catégorie ciblée et pas de cumul avec une promotion', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      // PROTEINE15 : compléments uniquement.
      expect(
        () =>
            b.couponLoyalty.quote(_lines(b, {'shaker': 1}), code: 'PROTEINE15'),
        _rule('catégorie « Compléments »'),
      );
      // Isolat déjà en promo (129 au lieu de 149) : pas de cumul.
      expect(
        () => b.couponLoyalty.quote(
          _lines(b, {'isolate': 1}),
          code: 'PROTEINE15',
        ),
        _rule('déjà en promotion'),
      );
      // Seule la whey (189 DT) est éligible.
      final q = b.couponLoyalty.quote(
        _lines(b, {'whey': 1, 'isolate': 1, 'shaker': 1}),
        code: 'PROTEINE15',
      );
      expect(q.eligibleAmount, 189);
      expect(q.couponDiscount, 28.35);
      expect(q.subtotal, 189 + 129 + 18);
    });

    test('réduction jamais supérieure au montant éligible', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      await _coupon(b, 'CINQUANTE', type: DiscountType.fixed, value: 50);
      final q = b.couponLoyalty.quote(
        _lines(b, {'shaker': 1}),
        code: 'CINQUANTE',
      );
      expect(q.couponDiscount, 18);
      // Le timbre reste dû.
      expect(q.total, 1);
      // Montant fixe inférieur au panier : appliqué tel quel.
      expect(
        b.couponLoyalty
            .quote(_lines(b, {'whey': 1}), code: 'CINQUANTE')
            .couponDiscount,
        50,
      );
    });

    test('déjà utilisé par la personne, puis épuisé', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      await _coupon(b, 'UNIQUE', maxUses: 2);
      final order = await _buy(b, {'shaker': 2}, code: 'UNIQUE');
      expect(order.couponCode, 'UNIQUE');
      expect(
        b.coupons.all.firstWhere((c) => c.code == 'UNIQUE').uses.single.orderId,
        order.id,
      );
      expect(
        () => b.couponLoyalty.quote(_lines(b, {'shaker': 2}), code: 'UNIQUE'),
        _rule('déjà utilisé'),
      );
      await loginAs(b, 'rami@gymflow.tn');
      await _buy(b, {'shaker': 1}, code: 'UNIQUE');
      await loginAs(b, 'leila@gymflow.tn');
      expect(
        () => b.couponLoyalty.quote(_lines(b, {'shaker': 1}), code: 'UNIQUE'),
        _rule('nombre maximal'),
      );
      // Sans limite par personne : réutilisable.
      await _coupon(b, 'ALAVOLONTE', perUser: null);
      await _buy(b, {'shaker': 1}, code: 'ALAVOLONTE');
      await _buy(b, {'shaker': 1}, code: 'ALAVOLONTE');
      expect(
        b.couponLoyalty
            .quote(_lines(b, {'shaker': 1}), code: 'ALAVOLONTE')
            .couponDiscount,
        1.8,
      );
    });

    test('utilisation enregistrée seulement après paiement accepté', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final lines = _lines(b, {'shaker': 2});
      final q = b.couponLoyalty.quote(lines, code: 'BIENVENUE10');
      // Devis seul : rien d'enregistré.
      expect(b.coupons.byId('cp_bienvenue')!.uses, isEmpty);
      // Carte refusée : pas de commande, code intact.
      await expectLater(
        _pay(b, q.total, '4000000000000002'),
        throwsA(isA<BusinessRuleException>()),
      );
      expect(b.coupons.byId('cp_bienvenue')!.uses, isEmpty);
      // Paiement non validé.
      await expectLater(
        b.orderService.placeOrder(
          lines,
          const PaymentResult(
            success: false,
            method: 'simulated',
            reference: '',
          ),
          couponCode: 'BIENVENUE10',
        ),
        throwsA(isA<BusinessRuleException>()),
      );
      // Montant payé différent du total (sans la réduction appliquée).
      final wrong = await _pay(b, 36);
      await expectLater(
        b.orderService.placeOrder(lines, wrong, couponCode: 'BIENVENUE10'),
        _rule('ne correspond pas'),
      );
      expect(b.coupons.byId('cp_bienvenue')!.uses, isEmpty);
      expect(b.orderService.mine(), isEmpty);
      // Paiement exact : commande et utilisation enregistrées.
      final ok = await _pay(b, q.total);
      final order = await b.orderService.placeOrder(
        lines,
        ok,
        couponCode: 'BIENVENUE10',
      );
      expect(order.discount, 3.6);
      expect(order.stamp, 1);
      expect(order.total, q.total);
      expect(order.discountLabel, 'Code BIENVENUE10 (-10 %)');
      expect(b.coupons.byId('cp_bienvenue')!.uses.single.amount, 3.6);
    });
  });

  group('points de fidélité', () {
    test('10 points par séance, crédités une seule fois', () async {
      final b = await makeBackend();
      await loginAs(b, 'ahmed@gymflow.tn');
      final sessions = b.sessions.where((s) => s.userId == 'u_ahmed').length;
      expect(sessions, greaterThan(10));
      expect(b.couponLoyalty.myBalance(), sessions * 10);
      await b.couponLoyalty.syncSessions('u_ahmed');
      await b.couponLoyalty.syncSessions('u_ahmed');
      expect(b.loyalty.byId('u_ahmed')!.entries.length, sessions);
      expect(b.couponLoyalty.myBalance(), sessions * 10);
      final model = b.sessions.where((s) => s.userId == 'u_ahmed').first;
      await b.sessions.save(
        SessionLog.fromJson({...model.toJson(), 'id': 's_new'}),
      );
      expect(b.couponLoyalty.myBalance(), sessions * 10 + 10);
      expect((await b.couponLoyalty.myHistory()).length, sessions + 1);
    });

    test('1 point par dinar dépensé, hors timbre et réduction', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      expect(b.couponLoyalty.myBalance(), 0);
      final o = await _buy(b, {'shaker': 2}, code: 'BIENVENUE10');
      // 36 − 3,6 = 32,4 DT → 32 points.
      expect(o.pointsEarned, 32);
      expect(b.couponLoyalty.myBalance(), 32);
    });

    test('100 points = 5 DT : tranches, solde et plafond', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final shaker = _lines(b, {'shaker': 1});
      expect(
        () => b.couponLoyalty.quote(shaker, points: 100),
        _rule('Solde insuffisant'),
      );
      expect(
        () => b.couponLoyalty.quote(shaker, points: 150),
        throwsA(isA<ValidationException>()),
      );
      await loginAs(b, 'ahmed@gymflow.tn');
      await b.loyalty.save(
        LoyaltyAccount(
          userId: 'u_ahmed',
          entries: [
            LoyaltyEntry(
              kind: LoyaltyKind.purchase,
              points: 500,
              refId: 'o_test',
              at: testNow,
            ),
          ],
        ),
      );
      expect(b.couponLoyalty.myBalance(), greaterThanOrEqualTo(500));
      // Shaker à 18 DT : au plus 3 tranches (15 DT).
      expect(b.couponLoyalty.maxRedeemable('u_ahmed', 18), 300);
      expect(
        () => b.couponLoyalty.quote(shaker, points: 400),
        _rule('au plus 300 points'),
      );
      final q = b.couponLoyalty.quote(shaker, points: 300);
      expect(q.pointsDiscount, 15);
      expect(q.total, 18 - 15 + 1);
      expect(CouponLoyaltyService.pointsValue(250), 10);
    });

    test('débit et crédit après paiement, cumul avec un code', () async {
      final b = await makeBackend();
      await loginAs(b, 'ahmed@gymflow.tn');
      final before = b.couponLoyalty.myBalance();
      final o = await _buy(b, {'whey': 1}, code: 'PROTEINE15', points: 200);
      // 189 − 28,35 − 10 = 150,65 → 150 points gagnés.
      expect(o.discount, closeTo(38.35, 1e-9));
      expect(o.total, closeTo(151.65, 1e-9));
      expect(o.pointsUsed, 200);
      expect(o.pointsEarned, 150);
      expect(o.discountLabel, 'Code PROTEINE15 (-15 %) · 200 points');
      expect(b.couponLoyalty.myBalance(), before - 200 + 150);
      final history = b.loyalty.byId('u_ahmed')!.entries;
      expect(
        history.where((e) => e.refId == o.id).map((e) => e.points),
        containsAll([-200, 150]),
      );
    });

    test('CA : réductions déduites, timbre exclu', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final before = b.orderService.revenue();
      await _buy(b, {'shaker': 2}, code: 'BIENVENUE10');
      expect(b.orderService.revenue(), closeTo(before + 32.4, 1e-9));
    });
  });

  group('administration des codes', () {
    test('rôle, validations, suppression ou désactivation', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      expect(
        () => b.couponLoyalty.all(),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(
        () => b.couponLoyalty.saveCoupon(
          code: 'PIRATE',
          label: 'Pirate',
          type: DiscountType.percent,
          value: 90,
        ),
        throwsA(isA<PermissionDeniedException>()),
      );
      await loginAs(b, 'admin@gymflow.tn');
      expect(b.couponLoyalty.all().length, 3);
      Future<void> invalid({
        String code = 'NOUVEAU',
        DiscountType type = DiscountType.percent,
        double value = 10,
        int? maxUses,
        DateTime? startsAt,
        DateTime? expiresAt,
      }) => expectLater(
        b.couponLoyalty.saveCoupon(
          code: code,
          label: 'Libellé',
          type: type,
          value: value,
          maxUses: maxUses,
          startsAt: startsAt,
          expiresAt: expiresAt,
        ),
        throwsA(isA<ValidationException>()),
      );
      await invalid(code: 'AB');
      await invalid(code: 'AVEC ESPACE');
      await invalid(code: 'bienvenue10'); // déjà pris
      await invalid(value: 95);
      await invalid(type: DiscountType.fixed, value: 0);
      await invalid(maxUses: 0);
      await invalid(startsAt: testNow, expiresAt: testNow);
      expect(b.couponLoyalty.statusOf(b.coupons.byId('cp_rentree')!), 'Expiré');
      expect(
        b.couponLoyalty.statusOf(b.coupons.byId('cp_bienvenue')!),
        'Actif',
      );

      // Jamais utilisé : supprimé.
      await b.couponLoyalty.deleteCoupon('cp_rentree');
      expect(b.coupons.byId('cp_rentree'), isNull);
      // Utilisé : désactivé, historique conservé.
      await loginAs(b, 'nour@gymflow.tn');
      await _buy(b, {'shaker': 2}, code: 'BIENVENUE10');
      await loginAs(b, 'admin@gymflow.tn');
      await b.couponLoyalty.deleteCoupon('cp_bienvenue');
      final c = b.coupons.byId('cp_bienvenue')!;
      expect(c.active, isFalse);
      expect(c.uses, hasLength(1));
      expect(b.couponLoyalty.statusOf(c), 'Désactivé');
      expect(
        b.auditRepo.all.map((a) => a.action),
        containsAll([
          'Suppression de code promo',
          'Désactivation de code promo',
        ]),
      );
    });
  });

  test('Stripe : une ligne au montant net et le timbre à part', () async {
    late Map<String, String> sent;
    final gateway = StripeCheckoutGateway(
      MockClient((r) async {
        sent = Uri.splitQueryString(r.body);
        return http.Response(
          jsonEncode({'id': 'cs_1', 'url': 'https://x'}),
          200,
        );
      }),
      'sk_test_x',
    );
    final b = await makeBackend();
    final lines = _lines(b, {'shaker': 2});
    await gateway.createSession(
      lines: lines,
      customerEmail: 'a@b.tn',
      discount: 3.6,
      stamp: 1,
    );
    expect(sent['line_items[0][quantity]'], '1');
    expect(
      sent['line_items[0][price_data][unit_amount]'],
      '${StripeCheckoutGateway.eurCents(32.4)}',
    );
    expect(
      sent['line_items[1][price_data][product_data][name]'],
      'Timbre fiscal',
    );
    expect(sent.containsKey('line_items[2][quantity]'), isFalse);
    // Sans réduction : lignes du panier + timbre.
    await gateway.createSession(
      lines: lines,
      customerEmail: 'a@b.tn',
      stamp: 1,
    );
    expect(sent['line_items[0][quantity]'], '2');
    expect(
      sent['line_items[1][price_data][product_data][name]'],
      'Timbre fiscal',
    );
  });

  group('Écrans', () {
    testWidgets('panier : code promo, points et total', (tester) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'ahmed@gymflow.tn',
      );
      b.cart.add(b.products.byId('pr_shaker')!, 2);
      await go(tester, Routes.cart);
      expect(find.byKey(const Key('cart_total')), findsOneWidget);
      expect(find.text(Fmt.money(37)), findsWidgets);
      await tester.scrollUntilVisible(
        find.byKey(const Key('coupon_field')),
        300,
        scrollable: mainScrollable(tester),
      );
      await tester.enterText(
        find.byKey(const Key('coupon_field')),
        'bienvenue10',
      );
      await tester.tap(find.byKey(const Key('coupon_apply')));
      await settle(tester);
      expect(b.cart.discount.code, 'BIENVENUE10');
      expect(
        tester.widget<Text>(find.byKey(const Key('cart_total'))).data,
        Fmt.money(36 - 3.6 + 1),
      );
      await tester.ensureVisible(find.byKey(const Key('points_more')));
      await tester.tap(find.byKey(const Key('points_more')));
      await settle(tester);
      expect(b.cart.discount.points, 100);
      expect(
        tester.widget<Text>(find.byKey(const Key('cart_total'))).data,
        Fmt.money(36 - 3.6 - 5 + 1),
      );
      // Code refusé : message, pas de changement.
      expect(tester.takeException(), isNull);
      b.cart.clear();
      expect(b.cart.discount.code, isNull);
    });

    testWidgets('admin : création d\'un code', (tester) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'admin@gymflow.tn',
      );
      await go(tester, Routes.coupons);
      expect(find.byKey(const Key('coupon_BIENVENUE10')), findsOneWidget);
      await go(tester, Routes.couponForm);
      await tester.enterText(find.byKey(const Key('coupon_code')), 'ete20');
      await tester.enterText(
        find.byKey(const Key('coupon_label')),
        'Soldes d\'été',
      );
      await tester.enterText(find.byKey(const Key('coupon_value')), '20');
      await tester.scrollUntilVisible(
        find.byKey(const Key('coupon_save')),
        300,
        scrollable: mainScrollable(tester),
      );
      await tester.tap(find.byKey(const Key('coupon_save')));
      await settle(tester);
      final c = b.couponLoyalty.byCode('ETE20')!;
      expect(c.value, 20);
      expect(c.maxUsesPerUser, 1);
      expect(find.byKey(const Key('coupon_ETE20')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
