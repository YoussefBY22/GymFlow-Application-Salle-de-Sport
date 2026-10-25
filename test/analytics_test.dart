// Niveau : unitaire et intégration (sans réseau). Mesure d'audience :
// compteurs anonymes locaux, envoi à Google Analytics (Measurement Protocol)
// seulement avec consentement, aucune donnée personnelle dans les envois.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/models/analytics.dart';
import 'package:gymflow/models/privacy.dart';
import 'package:gymflow/models/session_log.dart';
import 'package:gymflow/services/analytics_service.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/payment/payment_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';

/// Requêtes reçues par Google Analytics (les autres hôtes sont ignorés).
class _Spy {
  final List<http.Request> requests = [];
  Object? failWith;
  String debugBody = '{"validationMessages":[]}';

  late final MockClient client = MockClient((r) async {
    if (r.url.host == 'www.google-analytics.com') {
      requests.add(r);
      final failure = failWith;
      if (failure != null) throw failure;
      if (r.url.path.startsWith('/debug/')) {
        return http.Response(debugBody, 200);
      }
      return http.Response('', 204);
    }
    return http.Response('{}', 200);
  });

  List<http.Request> get collected =>
      requests.where((r) => r.url.path == '/mp/collect').toList();

  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  Map<String, dynamic> eventOf(http.Request r) =>
      (bodyOf(r)['events'] as List).single as Map<String, dynamic>;
}

Future<Backend> _backend(_Spy spy, {bool keys = true}) async {
  final b = await makeBackend(httpClient: spy.client);
  if (keys) {
    b.analytics.measurementId = 'G-TEST123';
    b.analytics.apiSecret = 'secret-de-test';
  }
  return b;
}

Future<void> _consent(Backend b, {bool on = true}) async {
  await b.privacy.updateSettings(
    b.auth.currentUser!.privacy.copyWith(analytics: on),
  );
}

Future<PaymentResult> _pay(Backend b, double amount) =>
    (b.payment as SimulatedPaymentGateway).charge(
      cardNumber: '4242424242424242',
      expiry: '12/30',
      cvc: '123',
      amount: amount,
      now: b.now(),
    );

void main() {
  group('Noms d\'événements', () {
    test(
      "tous respectent la règle de Google (lettres, chiffres, _, 40 max)",
      () {
        for (final n in AnalyticsEvents.all) {
          expect(AnalyticsEvents.isValidName(n), isTrue, reason: n);
        }
      },
    );

    test('les noms invalides sont refusés', () {
      for (final n in ['', '1abc', 'a b', 'très', 'a' * 41, 'a-b']) {
        expect(AnalyticsEvents.isValidName(n), isFalse, reason: n);
      }
    });

    test('chaque événement a un intitulé lisible, sans doublon', () {
      final labels = AnalyticsEvents.all.map(AnalyticsEvents.label).toList();
      for (final n in AnalyticsEvents.all) {
        expect(AnalyticsEvents.label(n), isNot(n), reason: n);
      }
      expect(labels.toSet().length, labels.length);
    });

    test('les noms standards de Google sont repris tels quels', () {
      expect(AnalyticsEvents.viewItem, 'view_item');
      expect(AnalyticsEvents.addToCart, 'add_to_cart');
      expect(AnalyticsEvents.purchase, 'purchase');
      expect(AnalyticsEvents.search, 'search');
      expect(AnalyticsEvents.login, 'login');
      expect(AnalyticsEvents.signUp, 'sign_up');
    });
  });

  group('Compteur anonyme', () {
    test('un compteur n\'enregistre ni compte ni appareil', () {
      final c = const AnalyticsCounter(
        day: '2026-09-30',
        name: 'view_item',
        key: 'pr_whey',
        label: 'Whey',
        count: 2,
      );
      final json = jsonEncode(c.toJson());
      expect(json, isNot(contains('user')));
      expect(
        c.toJson().keys,
        containsAll(['id', 'day', 'name', 'key', 'label', 'count', 'value']),
      );
    });

    test('add cumule les occurrences et les montants', () {
      final c = const AnalyticsCounter(
        day: 'd',
        name: 'n',
        key: 'k',
        label: 'L',
        count: 1,
        value: 10,
      ).add(by: 2, value: 5.5);
      expect(c.count, 3);
      expect(c.value, 15.5);
      expect(c.label, 'L');
    });

    test('toJson/fromJson conservent tout', () {
      final c = const AnalyticsCounter(
        day: '2026-09-30',
        name: 'purchase',
        key: '',
        label: 'Commandes',
        count: 4,
        value: 99.5,
      );
      final r = AnalyticsCounter.fromJson(c.toJson());
      expect(r.id, c.id);
      expect(r.count, 4);
      expect(r.value, 99.5);
    });
  });

  group('Identifiant envoyé à Google', () {
    test("c'est une empreinte stable, jamais l'identifiant du compte", () {
      final a = AnalyticsService.clientIdFor('u_ahmed');
      expect(a, AnalyticsService.clientIdFor('u_ahmed'));
      expect(a, isNot(AnalyticsService.clientIdFor('u_nour')));
      expect(a, isNot(contains('ahmed')));
      expect(a, matches(RegExp(r'^[0-9a-f]{10}\.[0-9a-f]{10}$')));
    });

    test('la charge utile a la forme attendue par Measurement Protocol', () {
      final p = AnalyticsService.buildPayload(
        clientId: 'abc.def',
        name: 'view_item',
        sessionId: '1700000000',
        deviceCategory: 'mobile',
        params: {'currency': 'TND'},
      );
      expect(p['client_id'], 'abc.def');
      expect((p['device'] as Map)['category'], 'mobile');
      final e = (p['events'] as List).single as Map;
      expect(e['name'], 'view_item');
      final params = e['params'] as Map;
      expect(params['engagement_time_msec'], isPositive);
      expect(params['session_id'], '1700000000');
      expect(params['currency'], 'TND');
    });
  });

  group('Mesure locale', () {
    test("l'ajout au panier, la vue et l'achat sont comptés", () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      await loginAs(b, 'ahmed@gymflow.tn');
      final whey = b.products.byId('pr_whey')!;
      b.analytics.viewItem(whey);
      b.analytics.viewItem(whey);
      b.cart.add(whey, 2);
      await b.analytics.idle();

      final s = b.analytics.summary();
      expect(s.views, 2);
      expect(s.carts, 2);
      final activity = s.products.single;
      expect(activity.name, whey.name);
      expect(activity.views, 2);
      expect(activity.carts, 2);
    });

    test(
      'une commande alimente les achats, le CA et le détail produit',
      () async {
        final spy = _Spy();
        final b = await _backend(spy, keys: false);
        await loginAs(b, 'nour@gymflow.tn');
        b.cart.add(b.products.byId('pr_shaker')!, 2);
        final lines = b.cart.lines;
        final order = await b.orderService.placeOrder(
          lines,
          await _pay(b, b.orderService.totalOf(lines)),
        );
        await b.analytics.idle();

        final s = b.analytics.summary();
        expect(s.orders, 1);
        expect(s.revenue, closeTo(order.total, 0.001));
        expect(s.purchasedUnits, 2);
        final p = s.products.firstWhere((p) => p.id == 'pr_shaker');
        expect(p.purchased, 2);
        expect(p.revenue, closeTo(order.total, 0.001));
      },
    );

    test('réservation, liste d\'attente et annulation sont comptées', () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      await loginAs(b, 'nour@gymflow.tn');
      final course = b.courses.byId('c_s1')!;
      b.analytics.viewCourse(course);
      final r = await b.reservationService.book('c_s1');
      await b.reservationService.cancel(r.id);
      await b.analytics.idle();

      final c = b.analytics.summary().courses.single;
      expect(c.title, course.title);
      expect(c.views, 1);
      expect(c.reservations, 1);
      expect(c.cancellations, 1);
    });

    test('connexions et inscriptions, par méthode', () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      await loginAs(b, 'ahmed@gymflow.tn');
      await b.auth.signInWithGoogle(
        email: 'nouveau.google@gmail.com',
        displayName: 'Nouveau Google',
      );
      await b.analytics.idle();
      final s = b.analytics.summary();
      expect(s.logins['password'], 1);
      expect(s.logins['google'], 1);
      expect(s.signups['google'], 1);
    });

    test("une séance terminée et une séance partagée sont comptées", () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      await loginAs(b, 'nour@gymflow.tn');
      final w = b.workouts.byId('w_fb_a')!;
      final res = await b.trainingLog.finishSession(
        workout: w,
        startedAt: testNow,
        durationSec: 1800,
        sets: [
          const SetLog(
            exerciseId: 'ex_goblet',
            exerciseName: 'Goblet',
            setIndex: 1,
            reps: 10,
            loadKg: 12,
          ),
        ],
      );
      b.analytics.workoutStart(w.name);
      await b.trainingLog.setShared(res.log.id, true);
      await b.analytics.idle();
      final s = b.analytics.summary();
      expect(s.total(AnalyticsEvents.workoutComplete), 1);
      expect(s.total(AnalyticsEvents.workoutStart), 1);
      expect(s.total(AnalyticsEvents.sessionShare), 1);
    });

    test(
      "seuls les abonnés sont mesurés (ni coach ni administrateur)",
      () async {
        final spy = _Spy();
        final b = await _backend(spy, keys: false);
        for (final email in ['admin@gymflow.tn', 'amira@gymflow.tn']) {
          await loginAs(b, email);
          b.analytics.viewItem(b.products.byId('pr_whey')!);
          b.analytics.search('whey', results: 1);
          await b.analytics.idle();
        }
        expect(b.analyticsRepo.all, isEmpty);
      },
    );

    test('sans session, rien n\'est enregistré et rien ne plante', () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      b.analytics.viewItem(b.products.byId('pr_whey')!);
      await b.analytics.idle();
      expect(b.analyticsRepo.all, isEmpty);
    });

    test('la synthèse ne garde que la période demandée', () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      await loginAs(b, 'ahmed@gymflow.tn');
      final whey = b.products.byId('pr_whey')!;
      setNow(testNow.subtract(const Duration(days: 20)));
      b.analytics.viewItem(whey);
      await b.analytics.idle();
      setNow(testNow);
      b.analytics.viewItem(whey);
      await b.analytics.idle();

      expect(b.analytics.summary(days: 7).views, 1);
      expect(b.analytics.summary(days: 30).views, 2);
      expect(b.analytics.summary(days: 7).perDay.length, 7);
    });

    test('la purge supprime les compteurs trop anciens', () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      await loginAs(b, 'ahmed@gymflow.tn');
      final whey = b.products.byId('pr_whey')!;
      setNow(testNow.subtract(const Duration(days: 400)));
      b.analytics.viewItem(whey);
      await b.analytics.idle();
      setNow(testNow);
      b.analytics.viewItem(whey);
      await b.analytics.idle();

      expect(await b.analytics.purgeOlderThan(keepDays: 180), 1);
      // Restent : la connexion et la consultation d'aujourd'hui.
      expect(b.analyticsRepo.all.map((c) => c.day).toSet(), {'2026-09-30'});
    });
  });

  group('Recherches', () {
    test('trop courtes : ignorées ; sinon normalisées', () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      await loginAs(b, 'ahmed@gymflow.tn');
      b.analytics.search('w', results: 3);
      b.analytics.search('   ', results: 3);
      b.analytics.search('  WHEY   Protéine ', results: 3);
      await b.analytics.idle();
      final s = b.analytics.summary();
      expect(s.searches, [('whey protéine', 1)]);
    });

    test('le terme est coupé à 30 caractères', () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      await loginAs(b, 'ahmed@gymflow.tn');
      b.analytics.search('x' * 80, results: 1);
      await b.analytics.idle();
      expect(b.analytics.summary().searches.single.$1.length, 30);
    });

    test('sans résultat : comptée à part', () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      await loginAs(b, 'ahmed@gymflow.tn');
      b.analytics.search('kettlebell', results: 0);
      b.analytics.search('whey', results: 4);
      await b.analytics.idle();
      final s = b.analytics.summary();
      expect(s.emptySearches, [('kettlebell', 1)]);
      expect(s.searches.length, 2);
    });
  });

  group('Envoi à Google Analytics', () {
    test("sans consentement, rien ne part", () async {
      final spy = _Spy();
      final b = await _backend(spy);
      await loginAs(b, 'ahmed@gymflow.tn');
      b.analytics.viewItem(b.products.byId('pr_whey')!);
      await b.analytics.idle();
      expect(spy.requests, isEmpty);
      // Le compteur local, lui, est tenu.
      expect(b.analytics.summary().views, 1);
    });

    test('sans clés, rien ne part même avec consentement', () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      await loginAs(b, 'ahmed@gymflow.tn');
      await _consent(b);
      expect(b.analytics.canSend, isFalse);
      b.analytics.viewItem(b.products.byId('pr_whey')!);
      await b.analytics.idle();
      expect(spy.requests, isEmpty);
    });

    test('avec consentement et clés : requête Measurement Protocol', () async {
      final spy = _Spy();
      final b = await _backend(spy);
      await loginAs(b, 'ahmed@gymflow.tn');
      await _consent(b);
      final whey = b.products.byId('pr_whey')!;
      b.analytics.viewItem(whey);
      await b.analytics.idle();

      final r = spy.collected.single;
      expect(r.url.queryParameters['measurement_id'], 'G-TEST123');
      expect(r.url.queryParameters['api_secret'], 'secret-de-test');
      // text/plain : pas de pré-requête CORS sur le web.
      expect(r.headers['Content-Type'], startsWith('text/plain'));
      final e = spy.eventOf(r);
      expect(e['name'], 'view_item');
      final params = e['params'] as Map;
      expect(params['currency'], 'TND');
      final item = (params['items'] as List).single as Map;
      expect(item['item_id'], 'pr_whey');
      expect(item['item_name'], whey.name);
      expect(item['quantity'], 1);
    });

    test("aucune donnée personnelle n'est transmise", () async {
      final spy = _Spy();
      final b = await _backend(spy);
      await loginAs(b, 'ahmed@gymflow.tn');
      await _consent(b);
      final me = b.auth.currentUser!;
      b.analytics.viewItem(b.products.byId('pr_whey')!);
      b.analytics.search('mon nom', results: 1);
      b.cart.add(b.products.byId('pr_shaker')!, 1);
      final lines = b.cart.lines;
      await b.orderService.placeOrder(
        lines,
        await _pay(b, b.orderService.totalOf(lines)),
      );
      await b.reservationService.book('c_s1');
      await b.auth.logout();
      await loginAs(b, 'ahmed@gymflow.tn');
      await b.analytics.idle();

      expect(spy.collected, isNotEmpty);
      for (final r in spy.collected) {
        final text = r.url.toString() + r.body;
        expect(text, isNot(contains(me.email)), reason: r.body);
        expect(text, isNot(contains(me.fullName)), reason: r.body);
        expect(text, isNot(contains(me.id)), reason: r.body);
        expect(
          AnalyticsEvents.isValidName(spy.eventOf(r)['name'] as String),
          isTrue,
        );
      }
    });

    test('un achat part en un seul événement purchase complet', () async {
      final spy = _Spy();
      final b = await _backend(spy);
      await loginAs(b, 'ahmed@gymflow.tn');
      await _consent(b);
      b.cart.add(b.products.byId('pr_shaker')!, 2);
      final lines = b.cart.lines;
      final order = await b.orderService.placeOrder(
        lines,
        await _pay(b, b.orderService.totalOf(lines)),
      );
      await b.analytics.idle();

      final events = spy.collected.map((r) => spy.eventOf(r)).toList();
      final names = events.map((e) => e['name']).toList();
      expect(names, containsAll(['add_to_cart', 'purchase']));
      expect(names, isNot(contains('purchase_item')));
      final purchase =
          events.firstWhere((e) => e['name'] == 'purchase')['params'] as Map;
      expect(purchase['transaction_id'], order.number);
      expect(purchase['currency'], 'TND');
      expect(purchase['value'], closeTo(order.total, 0.001));
      expect((purchase['items'] as List).single['quantity'], 2);
    });

    test("une recherche sans résultat n'est pas envoyée à Google", () async {
      final spy = _Spy();
      final b = await _backend(spy);
      await loginAs(b, 'ahmed@gymflow.tn');
      await _consent(b);
      b.analytics.search('kettlebell', results: 0);
      await b.analytics.idle();
      final names = spy.collected.map((r) => spy.eventOf(r)['name']).toList();
      expect(names, ['search']);
    });

    test("la question posée à l'assistant n'est jamais transmise", () async {
      final spy = _Spy();
      final b = await _backend(spy);
      await loginAs(b, 'ahmed@gymflow.tn');
      await _consent(b);
      b.analytics.chatQuestion();
      await b.analytics.idle();
      final e = spy.eventOf(spy.collected.single);
      expect(e['name'], 'chat_question');
      expect(
        (e['params'] as Map).keys,
        unorderedEquals(['engagement_time_msec', 'session_id']),
      );
    });

    test('retirer son consentement arrête les envois', () async {
      final spy = _Spy();
      final b = await _backend(spy);
      await loginAs(b, 'ahmed@gymflow.tn');
      await _consent(b);
      b.analytics.chatQuestion();
      await b.analytics.idle();
      expect(spy.collected.length, 1);
      await _consent(b, on: false);
      b.analytics.chatQuestion();
      await b.analytics.idle();
      expect(spy.collected.length, 1);
    });

    test(
      "une panne de Google ne casse rien et le local est conservé",
      () async {
        final spy = _Spy()..failWith = http.ClientException('hors ligne');
        final b = await _backend(spy);
        await loginAs(b, 'ahmed@gymflow.tn');
        await _consent(b);
        b.cart.add(b.products.byId('pr_shaker')!, 1);
        await b.analytics.idle();
        expect(b.cart.lines.length, 1);
        expect(b.analytics.summary().carts, 1);
      },
    );
  });

  group('Bouton de test (administrateur)', () {
    test("un abonné n'y a pas accès", () async {
      final spy = _Spy();
      final b = await _backend(spy);
      await loginAs(b, 'ahmed@gymflow.tn');
      expect(
        () => b.analytics.sendTest(),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('sans clés : message clair, rien d\'envoyé', () async {
      final spy = _Spy();
      final b = await _backend(spy, keys: false);
      await loginAs(b, 'admin@gymflow.tn');
      final r = await b.analytics.sendTest();
      expect(r.ok, isFalse);
      expect(r.message, contains('GA_MEASUREMENT_ID'));
      expect(spy.requests, isEmpty);
    });

    test("valide d'abord le format chez Google, puis envoie", () async {
      final spy = _Spy();
      final b = await _backend(spy);
      await loginAs(b, 'admin@gymflow.tn');
      final r = await b.analytics.sendTest();
      expect(r.ok, isTrue);
      expect(spy.requests.map((q) => q.url.path), [
        '/debug/mp/collect',
        '/mp/collect',
      ]);
      expect(spy.eventOf(spy.requests.last)['name'], 'gymflow_test');
    });

    test("un format refusé par Google n'est pas envoyé pour de bon", () async {
      final spy = _Spy()
        ..debugBody =
            '{"validationMessages":[{"fieldPath":"events","description":"mauvais"}]}';
      final b = await _backend(spy);
      await loginAs(b, 'admin@gymflow.tn');
      final r = await b.analytics.sendTest();
      expect(r.ok, isFalse);
      expect(r.message, contains('mauvais'));
      expect(spy.collected, isEmpty);
    });

    test('réseau coupé : message lisible', () async {
      final spy = _Spy()..failWith = http.ClientException('hors ligne');
      final b = await _backend(spy);
      await loginAs(b, 'admin@gymflow.tn');
      final r = await b.analytics.sendTest();
      expect(r.ok, isFalse);
      expect(r.message, contains('Google'));
    });
  });

  group('Consentement à la mesure d\'audience', () {
    test('désactivée par défaut, y compris sur un ancien compte', () async {
      expect(const PrivacySettings().analytics, isFalse);
      expect(PrivacySettings.fromJson(const {}).analytics, isFalse);
      final b = await makeBackend();
      await loginAs(b, 'ahmed@gymflow.tn');
      expect(b.auth.currentUser!.privacy.analytics, isFalse);
    });

    test('le choix est conservé et tracé dans l\'historique', () async {
      final b = await makeBackend();
      await loginAs(b, 'ahmed@gymflow.tn');
      await _consent(b);
      expect(b.auth.currentUser!.privacy.analytics, isTrue);
      expect(
        b.auth.currentUser!.consents.any(
          (c) => c.type == ConsentType.analytics && c.granted,
        ),
        isTrue,
      );
      await _consent(b, on: false);
      expect(b.auth.currentUser!.consents.last.type, ConsentType.analytics);
      expect(b.auth.currentUser!.consents.last.granted, isFalse);
    });

    test('un mineur ne peut pas l\'activer', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      await b.users.save(b.auth.currentUser!.copyWith(age: 16));
      await loginAs(b, 'nour@gymflow.tn');
      expect(() => _consent(b), throwsA(isA<BusinessRuleException>()));
    });
  });
}
