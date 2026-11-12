import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/app.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/models/shop.dart';
import 'package:gymflow/screens/admin/pickup_scan_screen.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/invoice_service.dart';
import 'package:gymflow/services/payment/payment_gateway.dart';
import 'package:gymflow/services/pickup_qr_service.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

Future<ShopOrder> _buy(
  Backend b,
  Map<String, int> items, {
  String? code,
}) async {
  final lines = [
    for (final e in items.entries)
      CartLine(product: b.products.byId('pr_${e.key}')!, quantity: e.value),
  ];
  final q = b.couponLoyalty.quote(lines, code: code);
  final pay = await (b.payment as SimulatedPaymentGateway).charge(
    cardNumber: '4242424242424242',
    expiry: '12/30',
    cvc: '123',
    amount: q.total,
    now: b.now(),
  );
  return b.orderService.placeOrder(lines, pay, couponCode: code);
}

/// Remplace une partie du contenu du QR (sans re-signer).
String _tamper(String raw, int index, String value) {
  final parts = raw.split('|');
  parts[index] = value;
  return parts.join('|');
}

Matcher _rule(String text) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(text)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('QR code de retrait', () {
    test('comparaison en temps constant', () {
      bool eq(String a, String b) =>
          PickupQrService.constantTimeEquals(utf8.encode(a), utf8.encode(b));
      expect(eq('abc', 'abc'), isTrue);
      expect(eq('abc', 'abd'), isFalse);
      expect(eq('abc', 'ab'), isFalse);
      expect(eq('ab', 'abc'), isFalse);
      expect(eq('', ''), isTrue);
    });

    test('signature valide, faux QR refusés', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final o = await _buy(b, {'shaker': 1});
      final raw = b.pickup.generate(o.id);
      final parts = raw.split('|');
      expect(parts, hasLength(4));
      expect(parts[0], 'GF1');
      expect(parts[1], o.id);
      expect(
        PickupQrService.expiryOf(raw),
        testNow.add(PickupQrService.validity),
      );
      // Seul l'admin vérifie.
      expect(
        () => b.pickup.verify(raw),
        throwsA(isA<PermissionDeniedException>()),
      );
      await loginAs(b, 'admin@gymflow.tn');
      expect(b.pickup.verify(raw).id, o.id);
      // Autre commande, expiration repoussée, signature modifiée.
      expect(
        () => b.pickup.verify(_tamper(raw, 1, 'o_seed_1')),
        _rule('signature'),
      );
      expect(
        () =>
            b.pickup.verify(_tamper(raw, 2, '${int.parse(parts[2]) + 86400}')),
        _rule('signature'),
      );
      // Premier caractère changé (toujours différent de l'original).
      final flipped = parts[3].startsWith('A') ? 'B' : 'A';
      expect(
        () => b.pickup.verify(
          _tamper(raw, 3, '$flipped${parts[3].substring(1)}'),
        ),
        _rule('signature'),
      );
      expect(
        () => b.pickup.verify('https://exemple.tn'),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => b.pickup.verify(_tamper(raw, 0, 'GF2')),
        throwsA(isA<ValidationException>()),
      );
      // Signé avec une autre clé (autre installation) : refusé.
      final other = await makeBackend();
      await loginAs(other, 'admin@gymflow.tn');
      final foreign = other.pickup.generate('o_seed_6');
      expect(() => b.pickup.verify(foreign), _rule('signature'));
      // Expiré après 48 h.
      // (horloge de ce backend : setNow vise le dernier backend créé)
      b.clock = () => testNow.add(const Duration(hours: 49));
      expect(() => b.pickup.verify(raw), _rule('expiré'));
    });

    test('clé QR_HMAC_KEY partagée entre appareils', () async {
      final a = await makeBackend();
      final c = await makeBackend();
      await a.pickup.loadKey(configKey: 'cle-de-test-partagee');
      await c.pickup.loadKey(configKey: 'cle-de-test-partagee');
      expect(a.pickup.configured, isTrue);
      await loginAs(a, 'admin@gymflow.tn');
      await loginAs(c, 'admin@gymflow.tn');
      final raw = a.pickup.generate('o_seed_4');
      expect(c.pickup.verify(raw).id, 'o_seed_4');
    });

    test('clé locale générée une fois et conservée', () async {
      final b = await makeBackend();
      await loginAs(b, 'admin@gymflow.tn');
      expect(b.pickup.configured, isFalse);
      expect(await b.sessionStorage.read('qr_hmac_key'), isNotNull);
      final raw = b.pickup.generate('o_seed_4');
      await b.pickup.loadKey(); // relance de l'application
      expect(b.pickup.verify(raw).id, 'o_seed_4');
    });

    test('génération : propriétaire uniquement, pas après remise', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      // Commande d'un autre abonné.
      expect(
        () => b.pickup.generate('o_seed_1'),
        throwsA(isA<PermissionDeniedException>()),
      );
      await loginAs(b, 'ahmed@gymflow.tn');
      // o_seed_1 : déjà remise.
      expect(() => b.pickup.generate('o_seed_1'), _rule('déjà remise'));
    });

    test('retrait : préparée → remise, sinon refus', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final o = await _buy(b, {'shaker': 1});
      final raw = b.pickup.generate(o.id);
      await loginAs(b, 'admin@gymflow.tn');
      await expectLater(b.pickup.redeem(raw), _rule('pas encore préparée'));
      await b.orderService.advance(o.id);
      final done = await b.pickup.redeem(raw);
      expect(done.status, OrderStatus.delivered);
      await expectLater(b.pickup.redeem(raw), _rule('déjà remise'));
      expect(
        b.auditRepo.all.any((a) => a.action == 'Retrait par QR code'),
        isTrue,
      );
      expect(
        b.notificationsRepo.all.any(
          (n) =>
              n.userId == 'u_nour' && n.title == 'Commande ${o.number} remise',
        ),
        isTrue,
      );
    });
  });

  group('facture', () {
    test('TVA extraite, réduction, timbre : total = montant payé', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final o = await _buy(b, {'shaker': 2}, code: 'BIENVENUE10');
      final d = b.invoices.data(o.id);
      expect(d.number, o.number);
      expect(d.number, matches(RegExp(r'^GF-\d{4}-\d{4}$')));
      expect(d.subtotal, 36);
      expect(d.discount, 3.6);
      expect(d.netTtc, closeTo(32.4, 1e-9));
      // 32,4 / 1,19 = 27,23 HT ; TVA 5,17.
      expect(d.totalHt, 27.23);
      expect(d.vat, 5.17);
      expect(d.totalHt + d.vat, closeTo(d.netTtc, 1e-9));
      expect(d.stamp, 1);
      expect(d.total, closeTo(33.4, 1e-9));
      expect(d.total, o.total);
      expect(d.customerName, b.users.byId('u_nour')!.fullName);
      expect(b.invoices.fileName(o.id), 'Facture-${o.number}.pdf');
      // Ancienne commande sans timbre ni réduction.
      final old = InvoiceData.of(b.orders.byId('o_seed_6')!);
      expect(old.stamp, 0);
      expect(old.total, old.netTtc);
    });

    test('facture réservée au client et au super admin', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      expect(
        () => b.invoices.data('o_seed_1'),
        throwsA(isA<PermissionDeniedException>()),
      );
      await loginAs(b, 'admin@gymflow.tn');
      expect(b.invoices.data('o_seed_1').number, isNotEmpty);
    });

    test(
      'PDF généré (polices embarquées), sans envoi si non configuré',
      () async {
        final b = await makeBackend();
        await loginAs(b, 'nour@gymflow.tn');
        final o = await _buy(b, {'whey': 1, 'shaker': 1}, code: 'PROTEINE15');
        final pdf = await b.invoices.pdf(o.id);
        expect(ascii.decode(pdf.sublist(0, 5)), '%PDF-');
        expect(pdf.length, greaterThan(1000));
        // EmailJS non configuré dans les tests : pas d'appel réseau.
        expect(b.email.invoiceEnabled, isFalse);
        expect(await b.invoices.email(o.id), isFalse);
      },
    );
  });

  group('Écrans', () {
    testWidgets('reçu : QR de retrait et bouton facture', (tester) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'nour@gymflow.tn',
      );
      final o = await tester.runAsync(() => _buy(b, {'shaker': 1}));
      await go(tester, Routes.order, o!.id);
      await tester.scrollUntilVisible(
        find.byKey(const Key('pickup_qr')),
        300,
        scrollable: mainScrollable(tester),
      );
      expect(find.byKey(const Key('pickup_qr')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('invoice_pdf')),
        300,
        scrollable: mainScrollable(tester),
      );
      expect(find.byKey(const Key('invoice_pdf')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('admin : saisie du QR, commande remise', (tester) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'admin@gymflow.tn',
      );
      // o_seed_4 : commande préparée de Salma.
      final raw = b.pickup.generate('o_seed_4');
      GymFlowApp.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const PickupScanScreen(useCamera: false),
        ),
      );
      await settle(tester);
      await tester.enterText(find.byKey(const Key('scan_manual')), raw);
      await tester.tap(find.byKey(const Key('scan_submit')));
      await settle(tester);
      expect(find.textContaining('remise'), findsWidgets);
      expect(b.orders.byId('o_seed_4')!.status, OrderStatus.delivered);
      await tester.tap(find.text('OK'));
      await settle(tester);
      // Second passage : refusé.
      await tester.tap(find.byKey(const Key('scan_submit')));
      await settle(tester);
      expect(find.text('Retrait refusé'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
