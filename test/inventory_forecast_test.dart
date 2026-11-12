import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/models/shop.dart';
import 'package:gymflow/repositories/data_store.dart';
import 'package:gymflow/repositories/sqlite_data_store.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/inventory_forecast_service.dart';
import 'package:gymflow/services/payment/payment_gateway.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

typedef _S = InventoryForecastService;

Product _product({int stock = 10}) => Product(
  id: 'pr_test',
  name: 'Produit test',
  description: '',
  category: ProductCategory.accessories,
  price: 10,
  stock: stock,
  createdAt: testNow,
);

/// Commandes générées : [perDay] unités de [productId] chaque jour, de
/// [fromDaysAgo] jours avant l'horloge jusqu'à [toDaysAgo].
Future<void> _generate(
  Backend b,
  String productId, {
  required int fromDaysAgo,
  int toDaysAgo = 0,
  int perDay = 1,
}) async {
  final p = b.products.byId(productId)!;
  final now = b.now();
  await b.orders.saveAll([
    for (var d = fromDaysAgo; d >= toDaysAgo; d--)
      ShopOrder(
        id: 'o_gen_${productId}_$d',
        number: 'GF-GEN-$d',
        userId: 'u_rami',
        lines: [
          OrderLine(
            productId: p.id,
            name: p.name,
            unitPrice: p.effectivePrice,
            quantity: perDay,
          ),
        ],
        status: OrderStatus.delivered,
        paymentMethod: 'simulated',
        paymentRef: 'SIM-GEN',
        createdAt: DateTime(now.year, now.month, now.day - d, 9),
      ),
  ]);
}

Future<void> _clearOrders(Backend b) async {
  for (final o in b.orders.all) {
    await b.orders.delete(o.id);
  }
}

Future<ShopOrder> _buy(Backend b, String productId, [int qty = 1]) async {
  b.cart.clear();
  b.cart.add(b.products.byId(productId)!, qty);
  final pay = await (b.payment as SimulatedPaymentGateway).charge(
    cardNumber: '4242424242424242',
    expiry: '12/30',
    cvc: '123',
    amount: b.couponLoyalty.quote(b.cart.lines).total,
    now: b.now(),
  );
  return b.orderService.placeOrder(b.cart.lines, pay);
}

int _stockAlerts(Backend b, String productId) => b.notificationsRepo.all
    .where((n) => n.type == NotificationType.stock && n.refId == productId)
    .length;

void main() {
  group('calculs', () {
    test('EWMA initialisée sur 14 jours, écart-type', () {
      expect(_S.ewma([]), isEmpty);
      expect(_S.ewma(List.filled(20, 2)).last, closeTo(2, 1e-9));
      // 14 jours sans vente puis 10 ventes : 0,1 × 10 = 1.
      final s = _S.ewma([...List.filled(14, 0), 10]);
      expect(s.length, 15);
      expect(s.last, closeTo(1, 1e-9));
      expect(_S.ewma([4, 4], a: 0.5).last, closeTo(4, 1e-9));
      expect(_S.deviationOf([1, 2, 3, 4]), closeTo(1.2910, 1e-4));
      expect(_S.deviationOf([5]), 0);
    });

    test('classes ABC : 80 % / 95 %, sans vente = C', () {
      final c = _S.abcClasses({
        'p1': 500,
        'p2': 300,
        'p3': 100,
        'p4': 60,
        'p5': 40,
        'p6': 0,
      });
      expect(c['p1'], AbcClass.a);
      expect(c['p2'], AbcClass.a);
      expect(c['p3'], AbcClass.b);
      expect(c['p4'], AbcClass.b);
      expect(c['p5'], AbcClass.c);
      expect(c['p6'], AbcClass.c);
      // Un seul produit fait tout le CA : classe A.
      expect(_S.abcClasses({'x': 10, 'y': 0}), {
        'x': AbcClass.a,
        'y': AbcClass.c,
      });
    });

    test('stock de sécurité, seuil, quantité conseillée, statut', () {
      const settings = InventorySettings(leadTimeDays: 7, coverageDays: 14);
      StockForecast f(int stock, List<int> sales) => _S.compute(
        product: _product(stock: stock),
        sales: sales,
        settings: settings,
      );
      // Ventes régulières d'une unité par jour : pas d'incertitude.
      final steady = List.filled(60, 1);
      final a = f(10, steady);
      expect(a.dailyDemand, closeTo(1, 1e-9));
      expect(a.safetyStock, 0);
      expect(a.reorderPoint, closeTo(7, 1e-9));
      expect(a.suggestedQuantity, 11); // 1 × (7 + 14) − 10
      expect(a.daysToStockout, closeTo(10, 1e-9));
      expect(a.status, StockStatus.watch);
      expect(f(5, steady).status, StockStatus.reorder);
      expect(f(0, steady).status, StockStatus.outOfStock);
      expect(f(30, steady).status, StockStatus.ok);
      expect(f(30, steady).suggestedQuantity, 0);

      // Ventes irrégulières (0, 2, 0, 2…) : stock de sécurité z·σ·√L.
      final irregular = [for (var i = 0; i < 60; i++) i.isEven ? 0 : 2];
      final b = f(10, irregular);
      final sigma = _S.deviationOf(irregular);
      expect(b.safetyStock, closeTo(1.65 * sigma * 2.6458, 1e-3));
      expect(b.reorderPoint, closeTo(b.dailyDemand * 7 + b.safetyStock, 1e-9));

      // Plus de service visé → plus de stock de sécurité.
      final high = _S.compute(
        product: _product(),
        sales: irregular,
        settings: const InventorySettings(serviceLevel: 0.99),
      );
      expect(high.safetyStock, greaterThan(b.safetyStock));

      // Aucune vente : pas de date de rupture.
      expect(f(5, List.filled(60, 0)).daysToStockout, isNull);
    });
  });

  group('avec le backend (horloge fixe)', () {
    test('ventes journalières sur 60 jours, aujourd\'hui inclus', () async {
      final b = await makeBackend();
      await loginAs(b, 'admin@gymflow.tn');
      await _clearOrders(b);
      await _generate(b, 'pr_rope', fromDaysAgo: 70, perDay: 2);
      final sales = b.inventory.dailySales()['pr_rope']!;
      expect(sales.length, 60);
      expect(sales.every((v) => v == 2), isTrue);
      expect(b.inventory.dailySales(days: 7)['pr_rope']!.length, 7);
    });

    test('commandes générées : prévision, ABC et tri par urgence', () async {
      final b = await makeBackend();
      await loginAs(b, 'admin@gymflow.tn');
      await _clearOrders(b);
      // Corde : 1 / jour, stock 12 → 12 jours. Gants : 1 tous les jours
      // pendant 60 j mais 3 unités, stock 11 → moins de 4 jours.
      await _generate(b, 'pr_rope', fromDaysAgo: 59);
      await _generate(b, 'pr_gloves', fromDaysAgo: 59, perDay: 3);
      final list = b.inventory.forecast();
      // Rupture (BCAA, stock 0) en premier, puis gants, puis corde.
      expect(list.first.product.id, 'pr_bcaa');
      expect(list.first.status, StockStatus.outOfStock);
      expect(list[1].product.id, 'pr_gloves');
      expect(list[2].product.id, 'pr_rope');
      final rope = list[2];
      expect(rope.dailyDemand, closeTo(1, 1e-9));
      expect(rope.daysToStockout, closeTo(12, 1e-9));
      expect(rope.status, StockStatus.watch);
      expect(rope.suggestedQuantity, 9); // 21 − 12
      expect(list[1].status, StockStatus.reorder);
      // CA : gants 3 × 39 × 60 = 7 020 DT, corde 29 × 60 = 1 740 DT.
      expect(list[1].abc, AbcClass.a);
      expect(list[1].revenue, closeTo(7020, 1e-6));
      expect(rope.abc, AbcClass.b);
      expect(
        list.where((f) => f.revenue == 0).every((f) => f.abc == AbcClass.c),
        isTrue,
      );
      // Les produits archivés ne sont pas listés.
      await b.productService.delete('pr_rope');
      expect(
        b.inventory.forecast().map((f) => f.product.id),
        isNot(contains('pr_rope')),
      );
    });

    test('réglages : validation, rôle, persistance, effet', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      expect(
        () => b.inventory.saveSettings(leadTimeDays: 5, coverageDays: 10),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(
        () => b.inventory.forecast(),
        throwsA(isA<PermissionDeniedException>()),
      );
      await loginAs(b, 'admin@gymflow.tn');
      expect(b.inventory.settings.leadTimeDays, 7);
      for (final (lead, cov, level) in [
        (0, 14, 0.95),
        (61, 14, 0.95),
        (7, 0, 0.95),
        (7, 91, 0.95),
        (7, 14, 0.5),
      ]) {
        expect(
          () => b.inventory.saveSettings(
            leadTimeDays: lead,
            coverageDays: cov,
            serviceLevel: level,
          ),
          throwsA(isA<ValidationException>()),
        );
      }
      await _clearOrders(b);
      await _generate(b, 'pr_rope', fromDaysAgo: 59);
      double rop() => b.inventory.forProduct('pr_rope')!.reorderPoint;
      expect(rop(), closeTo(7, 1e-9));
      await b.inventory.saveSettings(
        leadTimeDays: 3,
        coverageDays: 30,
        serviceLevel: 0.98,
      );
      expect(rop(), closeTo(3, 1e-9));
      expect(b.inventory.forProduct('pr_rope')!.suggestedQuantity, 21);
      await b.reload();
      expect(b.inventory.settings.coverageDays, 30);
      expect(b.inventory.settings.serviceLevel, 0.98);
      expect(
        b.auditRepo.all.any(
          (a) => a.action == 'Réglages du réapprovisionnement',
        ),
        isTrue,
      );
    });

    test('alerte après commande : une par produit et par jour', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      // Isolat : ventes en hausse dans le jeu de démo, déjà sous le seuil.
      expect(_stockAlerts(b, 'pr_isolate'), 0);
      await _buy(b, 'pr_isolate');
      expect(_stockAlerts(b, 'pr_isolate'), 1);
      final n = b.notificationsRepo.all.firstWhere(
        (n) => n.type == NotificationType.stock,
      );
      expect(n.userId, 'u_admin');
      expect(n.title, startsWith('À réapprovisionner : '));
      expect(n.body, contains('Commande conseillée'));
      expect(n.route, Routes.restock);
      // L'abonnée n'est pas prévenue.
      expect(
        b.notificationsRepo.all.where(
          (x) => x.userId == 'u_nour' && x.type == NotificationType.stock,
        ),
        isEmpty,
      );
      await _buy(b, 'pr_isolate');
      expect(_stockAlerts(b, 'pr_isolate'), 1);
      setNow(testNow.add(const Duration(days: 1)));
      await _buy(b, 'pr_isolate');
      expect(_stockAlerts(b, 'pr_isolate'), 2);
      // Stock confortable : pas d'alerte.
      await _buy(b, 'pr_shaker');
      expect(_stockAlerts(b, 'pr_shaker'), 0);
      // Dernières unités vendues : alerte de rupture.
      final left = b.products.byId('pr_isolate')!.stock;
      setNow(testNow.add(const Duration(days: 2)));
      await _buy(b, 'pr_isolate', left);
      expect(
        b.notificationsRepo.all.where((n) => n.title.startsWith('Rupture')),
        hasLength(1),
      );
    });

    test('jeu de démo : isolat à commander, BCAA en rupture', () async {
      final b = await makeBackend();
      await loginAs(b, 'admin@gymflow.tn');
      final list = b.inventory.forecast();
      StockForecast of(String id) => list.firstWhere((f) => f.product.id == id);
      expect(list.first.product.id, 'pr_bcaa');
      expect(of('pr_isolate').status, StockStatus.reorder);
      expect(of('pr_isolate').abc, AbcClass.a);
      expect(of('pr_isolate').suggestedQuantity, greaterThan(0));
      expect(of('pr_roller').abc, AbcClass.c);
      expect(of('pr_towel').abc, AbcClass.c);
      expect(list.map((f) => f.abc).toSet(), AbcClass.values.toSet());
    });
  });

  test('SQLite : une base v1 reçoit la table des réglages', () async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('gymflow_v1_');
    final path = p.join(dir.path, 'v1.db');
    // Base créée par la version 1 : sans la table « settings ».
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE products (id TEXT PRIMARY KEY, data TEXT NOT NULL, '
            'updated_at INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.insert('products', {
            'id': 'pr_1',
            'data': '{"id":"pr_1"}',
            'updated_at': 0,
          });
        },
      ),
    );
    await old.close();
    final store = SqliteDataStore(fileName: path, factory: databaseFactoryFfi);
    await store.open();
    expect(await store.loadAll(Collections.products), hasLength(1));
    await store.put(
      Collections.settings,
      InventorySettings.id,
      const InventorySettings(leadTimeDays: 4).toJson(),
    );
    final loaded = await store.loadAll(Collections.settings);
    expect(InventorySettings.fromJson(loaded.single).leadTimeDays, 4);
    expect(InventorySettings.fromJson(const {}).coverageDays, 14);
  });

  group('Écran', () {
    testWidgets('liste par urgence, détail et réception du stock', (
      tester,
    ) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'admin@gymflow.tn',
      );
      await go(tester, Routes.restock);
      expect(find.text('Réapprovisionnement'), findsOneWidget);
      final bcaa = tester.getTopLeft(find.byKey(const Key('forecast_pr_bcaa')));
      final iso = tester.getTopLeft(
        find.byKey(const Key('forecast_pr_isolate')),
      );
      expect(bcaa.dy, lessThan(iso.dy));
      final before = b.products.byId('pr_isolate')!.stock;
      final qty = b.inventory.forProduct('pr_isolate')!.suggestedQuantity;
      await tester.tap(find.byKey(const Key('forecast_pr_isolate')));
      await settle(tester);
      expect(find.text('Ventes par jour et tendance lissée'), findsOneWidget);
      await tester.tap(find.byKey(const Key('receive_stock')));
      await settle(tester);
      expect(b.products.byId('pr_isolate')!.stock, before + qty);
      expect(tester.takeException(), isNull);
    });
  });
}
