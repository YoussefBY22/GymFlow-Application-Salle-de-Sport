import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/models/shop.dart';
import 'package:gymflow/services/payment/payment_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';

const _key = 'cle_test_konnect';
const _wallet = 'wallet_sandbox_1';
const _ref = '5f9498735289e405fc7c18ac';

/// Faux serveur Konnect (sandbox) : enregistre les requêtes reçues.
class _FakeKonnect {
  final requests = <http.Request>[];
  String status = 'completed';
  int? paidMillimes;
  int initStatus = 200;

  late final client = MockClient((r) async {
    requests.add(r);
    if (r.headers['x-api-key'] != _key) {
      return http.Response('{"message":"Unauthorized"}', 401);
    }
    if (r.method == 'POST' && r.url.path.endsWith('/payments/init-payment')) {
      if (initStatus != 200) {
        return http.Response(
          jsonEncode({'message': 'amount must be a positive number'}),
          initStatus,
        );
      }
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      paidMillimes ??= body['amount'] as int;
      return http.Response(
        jsonEncode({
          'payUrl':
              'https://gateway.sandbox.konnect.network/pay?payment_ref=$_ref',
          'paymentRef': _ref,
        }),
        200,
      );
    }
    if (r.method == 'GET' && r.url.path.endsWith('/payments/$_ref')) {
      return http.Response(
        jsonEncode({
          'payment': {
            'id': _ref,
            'status': status,
            'amount': paidMillimes,
            'token': 'TND',
            'transactions': [],
          },
        }),
        200,
      );
    }
    return http.Response('{"message":"Not found"}', 404);
  });

  KonnectGateway gateway([String key = _key]) =>
      KonnectGateway(client, key, _wallet);
}

void main() {
  test('sélection : Konnect, sinon Stripe test, sinon simulée', () {
    final c = MockClient((_) async => http.Response('', 200));
    expect(
      PaymentGateway.select(
        c,
        konnectApiKey: 'k',
        konnectWalletId: 'w',
        stripeKey: 'sk_test_x',
      ),
      isA<KonnectGateway>(),
    );
    // Clé sans portefeuille : Konnect inutilisable.
    expect(
      PaymentGateway.select(c, konnectApiKey: 'k', stripeKey: 'sk_test_x'),
      isA<StripeCheckoutGateway>(),
    );
    // Clé Stripe réelle refusée.
    expect(
      PaymentGateway.select(c, stripeKey: 'sk_live_x'),
      isA<SimulatedPaymentGateway>(),
    );
    expect(PaymentGateway.select(c), isA<SimulatedPaymentGateway>());
    // Sans secrets.json (tests) : passerelle simulée.
    expect(PaymentGateway.fromConfig(c), isA<SimulatedPaymentGateway>());
  });

  test(
    'création du paiement : sandbox, millimes, aucune donnée de carte',
    () async {
      final k = _FakeKonnect();
      final b = await makeBackend();
      final lines = [
        CartLine(product: b.products.byId('pr_shaker')!, quantity: 2),
      ];
      final s = await k.gateway().createSession(
        lines: lines,
        customerEmail: 'nour@gymflow.tn',
        customerName: 'Nour Ben Ali',
        total: 33.4,
      );
      expect(s.id, _ref);
      expect(s.url, startsWith('https://'));
      final r = k.requests.single;
      expect(r.method, 'POST');
      expect(
        r.url.toString(),
        'https://api.sandbox.konnect.network/api/v2/payments/init-payment',
      );
      expect(r.headers['x-api-key'], _key);
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(body['receiverWalletId'], _wallet);
      expect(body['token'], 'TND');
      expect(body['amount'], 33400); // 33,400 DT en millimes
      expect(body['type'], 'immediate');
      expect(body['firstName'], 'Nour');
      expect(body['lastName'], 'Ben Ali');
      expect(body['email'], 'nour@gymflow.tn');
      expect(body['description'], contains('Shaker'));
      // Champs dépréciés non utilisés ; aucune donnée de carte envoyée.
      expect(body.keys, isNot(contains('successUrl')));
      expect(
        body.keys.any(
          (k) =>
              k.toLowerCase().contains('card') && k != 'acceptedPaymentMethods',
        ),
        isFalse,
      );
      expect(KonnectGateway.millimes(0.1 + 0.2), 300);
    },
  );

  test('erreurs : clé refusée, requête invalide, réseau', () async {
    final k = _FakeKonnect();
    final b = await makeBackend();
    final lines = [
      CartLine(product: b.products.byId('pr_shaker')!, quantity: 1),
    ];
    await expectLater(
      k
          .gateway('mauvaise')
          .createSession(lines: lines, customerEmail: '', total: 19),
      throwsA(
        isA<BusinessRuleException>().having(
          (e) => e.message,
          'm',
          contains('clé API refusée'),
        ),
      ),
    );
    k.initStatus = 400;
    await expectLater(
      k.gateway().createSession(lines: lines, customerEmail: '', total: 19),
      throwsA(
        isA<BusinessRuleException>().having(
          (e) => e.message,
          'm',
          contains('positive'),
        ),
      ),
    );
    final offline = KonnectGateway(
      MockClient((_) async => throw http.ClientException('hors ligne')),
      _key,
      _wallet,
    );
    await expectLater(
      offline.createSession(lines: lines, customerEmail: '', total: 19),
      throwsA(isA<NetworkException>()),
    );
    await expectLater(offline.verify(_ref), throwsA(isA<NetworkException>()));
    await expectLater(
      k.gateway().createSession(lines: lines, customerEmail: '', total: 0),
      throwsA(isA<ValidationException>()),
    );
  });

  test('vérification : seul payment.status « completed » fait foi', () async {
    final k = _FakeKonnect()..paidMillimes = 37000;
    final g = k.gateway();
    final ok = await g.verify(_ref);
    expect(ok.success, isTrue);
    expect(ok.method, 'konnect_sandbox');
    expect(ok.reference, _ref);
    expect(ok.amount, 37);
    final get = k.requests.last;
    expect(get.method, 'GET');
    expect(
      get.url.toString(),
      'https://api.sandbox.konnect.network/api/v2/payments/$_ref',
    );
    expect(get.headers['x-api-key'], _key);
    k.status = 'pending';
    final pending = await g.verify(_ref);
    expect(pending.success, isFalse);
    expect(pending.amount, isNull);
    // Référence suspecte : refusée sans appel réseau.
    final before = k.requests.length;
    await expectLater(
      g.verify('../admin'),
      throwsA(isA<ValidationException>()),
    );
    expect(k.requests.length, before);
    expect(
      g.isFinished('https://dev.konnect.network/gateway/payment-success'),
      isTrue,
    );
    expect(
      g.isFinished('https://gateway.sandbox.konnect.network/pay'),
      isFalse,
    );
  });

  test('parcours complet : commande payée par Konnect', () async {
    final k = _FakeKonnect();
    final b = await makeBackend();
    await loginAs(b, 'nour@gymflow.tn');
    final lines = [
      CartLine(product: b.products.byId('pr_shaker')!, quantity: 2),
    ];
    final q = b.couponLoyalty.quote(lines, code: 'BIENVENUE10');
    final g = k.gateway();
    final s = await g.createSession(
      lines: lines,
      customerEmail: 'nour@gymflow.tn',
      total: q.total,
      discount: q.discount,
      stamp: q.stamp,
    );
    final result = await g.verify(s.id);
    final order = await b.orderService.placeOrder(
      lines,
      result,
      couponCode: 'BIENVENUE10',
    );
    expect(order.paymentMethod, 'konnect_sandbox');
    expect(order.paymentRef, _ref);
    expect(order.total, closeTo(33.4, 1e-9));
    // Seules la méthode et la référence sont conservées.
    final json = jsonEncode(order.toJson());
    expect(json, isNot(contains('card')));
    expect(json, isNot(contains('4242')));
  });

  test('montant Konnect différent du total : commande refusée', () async {
    final k = _FakeKonnect()..paidMillimes = 1000; // 1 DT seulement
    final b = await makeBackend();
    await loginAs(b, 'nour@gymflow.tn');
    final lines = [
      CartLine(product: b.products.byId('pr_shaker')!, quantity: 2),
    ];
    final result = await k.gateway().verify(_ref);
    expect(result.success, isTrue);
    await expectLater(
      b.orderService.placeOrder(lines, result),
      throwsA(
        isA<BusinessRuleException>().having(
          (e) => e.message,
          'm',
          contains('ne correspond pas'),
        ),
      ),
    );
    expect(b.orderService.mine(), isEmpty);
  });
}
