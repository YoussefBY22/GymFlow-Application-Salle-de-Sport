import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/app.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/course.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/models/session_pack.dart';
import 'package:gymflow/repositories/data_store.dart';
import 'package:gymflow/repositories/sqlite_data_store.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/payment/payment_gateway.dart';
import 'package:gymflow/services/session_pack_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

/// Carnets de séances et formules hebdomadaires (étape 1). Horloge de test :
/// mercredi 30 septembre 2026, 10 h. Démo : Hedi n'a plus d'abonnement et
/// possède un carnet de 5 (1 séance restante, expire le 11/10) et une
/// formule 2 cours par semaine (expire le 28/10).
const _hedi5 = 'pk_demo_hedi5';
const _hediWeek = 'pk_demo_hedi_week';

SessionPack _pack(Backend b, String id) => b.sessionPacks.byId(id)!;

Future<void> _onlyPacks(Backend b, String userId, Set<String> keep) async {
  for (final x in b.sessionPacks.where((x) => x.userId == userId)) {
    if (!keep.contains(x.id)) await b.sessionPacks.delete(x.id);
  }
}

Future<SessionPack> _give(
  Backend b,
  String userId, {
  String id = 'pk_test',
  PackKind kind = PackKind.credits,
  int quota = 5,
  int expiresInDays = 30,
  List<CourseCategory> categories = const [],
}) => b.sessionPacks.save(
  SessionPack(
    id: id,
    userId: userId,
    offerId: 'po_test',
    name: 'Carnet test',
    kind: kind,
    quota: quota,
    categories: categories,
    purchasedAt: b.now().subtract(const Duration(days: 1)),
    expiresAt: b.now().add(Duration(days: expiresInDays)),
  ),
);

PaymentResult _paid(double amount, [String ref = 'SIM-TEST-1']) =>
    PaymentResult(
      success: true,
      method: 'simulated',
      reference: ref,
      amount: amount,
    );

Matcher _rule(String text) => throwsA(
  isA<BusinessRuleException>().having((e) => e.message, 'm', contains(text)),
);

void main() {
  group('Modèle', () {
    test('le solde est calculé à partir de l\'historique', () {
      final t = DateTime(2026, 9, 1);
      PackMovement m(PackMoveKind k, String? r, {int count = 1}) =>
          PackMovement(kind: k, at: t, reservationId: r, count: count);
      var pack = SessionPack(
        id: 'x',
        userId: 'u',
        offerId: 'o',
        name: 'Carnet',
        kind: PackKind.credits,
        quota: 5,
        purchasedAt: t,
        expiresAt: DateTime(2026, 12),
        movements: [
          m(PackMoveKind.reserved, 'r1'),
          m(PackMoveKind.consumed, 'r1'),
          m(PackMoveKind.reserved, 'r2'),
          m(PackMoveKind.released, 'r2'),
          m(PackMoveKind.reserved, 'r3'),
        ],
      );
      expect(pack.consumedCount, 1);
      expect(pack.openCount, 1);
      expect(pack.isOpen('r3'), isTrue);
      expect(pack.remaining, 3);
      pack = pack.add(m(PackMoveKind.expired, null, count: 2));
      expect(pack.remaining, 1);
      // Aller-retour JSON sans perte.
      final back = SessionPack.fromJson(
        jsonDecode(jsonEncode(pack.toJson())) as Map<String, dynamic>,
      );
      expect(back.remaining, 1);
      expect(back.movements, hasLength(6));
    });

    test('anciennes données lisibles sans migration', () {
      final r = Reservation.fromJson({
        'id': 'r',
        'courseId': 'c',
        'userId': 'u',
      });
      expect(r.packId, isNull);
      expect(r.toJson().containsKey('packId'), isFalse);
      final s = SessionPack.fromJson({'id': 'p'});
      expect(s.remaining, 1);
      expect(s.categories, isEmpty);
      expect(GymSettings.fromJson(const {}).freeCancelHours, 12);
      expect(PackOffer.fromJson({'id': 'o'}).kind, PackKind.credits);
    });
  });

  group('Couverture', () {
    test('abonné actif : un cours inclus ne prend aucun crédit', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final r = await b.reservationService.book('c_s1');
      expect(r.packId, isNull);
      expect(b.sessionPacks.where((x) => x.userId == 'u_nour'), isEmpty);
    });

    test('abonné actif : cours hors abonnement refusé sans carnet', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      await expectLater(
        b.reservationService.book('c_s9'),
        throwsA(
          isA<BusinessRuleException>().having(
            (e) => e.message,
            'm',
            allOf(contains('pas inclus'), contains('Achetez un carnet')),
          ),
        ),
      );
    });

    test('abonné actif : cours hors abonnement payé par un crédit', () async {
      final b = await makeBackend();
      await _give(b, 'u_nour');
      await loginAs(b, 'nour@gymflow.tn');
      final r = await b.reservationService.book('c_s9');
      expect(r.packId, 'pk_test');
      expect(_pack(b, 'pk_test').isOpen(r.id), isTrue);
      expect(_pack(b, 'pk_test').remaining, 4);
    });

    test('sans abonnement : un cours inclus prend un crédit (FEFO)', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      expect(
        b.packs.needsCredit(b.requireUser(), b.courses.byId('c_s1')!),
        isTrue,
      );
      // Le carnet qui expire en premier (11/10) passe avant la formule
      // hebdomadaire (28/10).
      final r = await b.reservationService.book('c_s1');
      expect(r.packId, _hedi5);
      expect(_pack(b, _hedi5).remaining, 0);
      expect(_pack(b, _hediWeek).usedInWeek(DateTime(2026, 10, 1)), 0);
    });

    test('carnet choisi par l\'abonné plutôt que FEFO', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      final r = await b.reservationService.book('c_s1', packId: _hediWeek);
      expect(r.packId, _hediWeek);
      expect(_pack(b, _hedi5).remaining, 1);
      // Le carnet d'un autre abonné ne peut pas être choisi.
      await expectLater(
        b.reservationService.book('c_s2', packId: 'pk_demo_omar_zen'),
        throwsA(isA<NotFoundException>()),
      );
    });

    test('carnet expiré, ou qui expire avant le cours : refusé', () async {
      final b = await makeBackend();
      await _onlyPacks(b, 'u_hedi', {_hedi5});
      await loginAs(b, 'hedi@gymflow.tn');
      // Le carnet expire le 11/10 à 0 h : le cours du 11/10 à 19 h est après.
      await expectLater(
        b.reservationService.book('c_s11'),
        _rule('avant ce cours'),
      );
      await _onlyPacks(b, 'u_hedi', {});
      await _give(b, 'u_hedi', expiresInDays: -1);
      await expectLater(b.reservationService.book('c_s1'), _rule('a expiré'));
    });

    test('mauvaise catégorie : refusé', () async {
      final b = await makeBackend();
      await _onlyPacks(b, 'u_omar', {});
      await _give(
        b,
        'u_omar',
        expiresInDays: 60,
        categories: [CourseCategory.yoga, CourseCategory.pilates],
      );
      await loginAs(b, 'omar@gymflow.tn');
      // Carnet yoga et pilates ; la clinique est de la musculation hors
      // abonnement.
      await expectLater(
        b.reservationService.book('c_s9'),
        _rule('ne couvre pas'),
      );
    });

    test('plafond hebdomadaire : 2 cours par semaine', () async {
      final b = await makeBackend();
      await _onlyPacks(b, 'u_hedi', {_hediWeek});
      await loginAs(b, 'hedi@gymflow.tn');
      await b.reservationService.book('c_s2'); // jeudi 1er octobre
      await b.reservationService.book('c_s1'); // jeudi 1er octobre
      await expectLater(
        b.reservationService.book('c_s4'), // vendredi, même semaine
        _rule('Plafond atteint'),
      );
      // Semaine suivante (lundi 5 octobre) : de nouveau possible.
      final r = await b.reservationService.book('c_s7');
      expect(r.packId, _hediWeek);
      expect(_pack(b, _hediWeek).usedInWeek(DateTime(2026, 10, 1)), 2);
      expect(_pack(b, _hediWeek).usedInWeek(DateTime(2026, 10, 5)), 1);
    });

    test('un même crédit ne sert jamais deux fois', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      final r = await b.reservationService.book('c_s1');
      final c = b.courses.byId('c_s1')!;
      await expectLater(
        b.packs.reserve(r, c, _pack(b, _hediWeek)),
        _rule('déjà été utilisé'),
      );
      expect(await b.packs.settle(r.id, PackMoveKind.consumed), isTrue);
      // Déjà consommé : ni seconde consommation, ni remboursement.
      expect(await b.packs.settle(r.id, PackMoveKind.consumed), isFalse);
      expect(await b.packs.settle(r.id, PackMoveKind.refunded), isFalse);
      expect(_pack(b, _hedi5).consumedCount, 5);
      expect(_pack(b, _hedi5).remaining, 0);
    });
  });

  group('Coût en séances', () {
    test('cours existants à 1 séance ; coût validé de 1 à 5', () async {
      final b = await makeBackend();
      final old = Course.fromJson({
        'id': 'c_old',
        'title': 'Ancien cours',
        'coachId': 'u_amira',
        'priceIncluded': false,
        'price': 25,
      });
      expect(old.creditCost, 1);
      expect(b.courses.byId('c_s9')!.creditCost, 1);
      expect(b.courses.byId('c_s12')!.creditCost, 2); // démo premium
      await loginAs(b, 'admin@gymflow.tn');
      Future<Course> save(int cost) => b.courseService.save(
        title: 'Atelier premium',
        description: 'Petit groupe.',
        category: CourseCategory.strength,
        level: Level.advanced,
        coachId: 'u_mehdi',
        room: 'Plateau',
        capacity: 6,
        durationMin: 60,
        startAt: DateTime(2026, 10, 20, 18),
        priceIncluded: false,
        creditCost: cost,
      );
      await expectLater(save(0), throwsA(isA<ValidationException>()));
      await expectLater(save(6), throwsA(isA<ValidationException>()));
      expect((await save(3)).creditCost, 3);
    });

    test(
      'un cours à 2 séances réserve, libère et rembourse 2 séances',
      () async {
        final b = await makeBackend();
        await _give(b, 'u_nour', quota: 5);
        await loginAs(b, 'nour@gymflow.tn');
        final r = await b.reservationService.book('c_s12');
        expect(_pack(b, 'pk_test').costOf(r.id), 2);
        expect(_pack(b, 'pk_test').remaining, 3);
        await b.reservationService.cancel(r.id); // 6 jours avant : libéré
        expect(_pack(b, 'pk_test').stateOf(r.id), PackMoveKind.released);
        expect(_pack(b, 'pk_test').remaining, 5);
        final r2 = await b.reservationService.book('c_s12');
        await b.auth.logout();
        await loginAs(b, 'sarra@gymflow.tn');
        await b.courseService.cancel('c_s12', 'Salle indisponible');
        expect(_pack(b, 'pk_test').stateOf(r2.id), PackMoveKind.refunded);
        expect(_pack(b, 'pk_test').remaining, 5);
        expect(
          _pack(b, 'pk_test').movements.every((m) => m.count == 2),
          isTrue,
        );
      },
    );

    test('annulation tardive ou absence : 2 séances consommées', () async {
      final b = await makeBackend();
      await _give(b, 'u_nour', quota: 5);
      await loginAs(b, 'nour@gymflow.tn');
      final r = await b.reservationService.book('c_s12');
      setNow(DateTime(2026, 10, 6, 10)); // 8 h avant
      await b.reservationService.cancel(r.id);
      expect(_pack(b, 'pk_test').consumedCount, 2);
      expect(_pack(b, 'pk_test').remaining, 3);
    });

    test('1 séance restante : un cours à 2 séances est refusé', () async {
      final b = await makeBackend();
      await _onlyPacks(b, 'u_hedi', {_hedi5}); // 1 séance restante
      await loginAs(b, 'hedi@gymflow.tn');
      await expectLater(
        b.reservationService.book('c_s12'),
        _rule('ce cours en demande 2'),
      );
      expect(_pack(b, _hedi5).remaining, 1);
      // Un cours à 1 séance reste possible.
      final r = await b.reservationService.book('c_s1');
      expect(r.packId, _hedi5);
    });

    test('formule hebdomadaire : un cours à 2 séances compte pour 2', () async {
      final b = await makeBackend();
      await _onlyPacks(b, 'u_hedi', {_hediWeek}); // 2 cours par semaine
      await loginAs(b, 'hedi@gymflow.tn');
      await b.reservationService.book('c_s7'); // lundi 5/10
      await expectLater(
        b.reservationService.book('c_s12'), // mardi 6/10, 2 séances
        _rule('ce cours compte pour 2'),
      );
      await b.reservationService.cancel(
        b.reservationService.activeFor('c_s7', 'u_hedi')!.id,
      );
      await b.reservationService.book('c_s12');
      expect(_pack(b, _hediWeek).usedInWeek(DateTime(2026, 10, 6)), 2);
    });

    testWidgets('fiche et formulaire : coût affiché et modifiable', (
      tester,
    ) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'nour@gymflow.tn',
      );
      await go(tester, Routes.courseDetail, 'c_s12');
      expect(
        find.text('Hors abonnement : 2 séances de carnet'),
        findsOneWidget,
      );
      await b.auth.logout();
      await loginAs(b, 'admin@gymflow.tn');
      await go(tester, Routes.courseForm, 'c_s12');
      expect(find.byKey(const Key('course_credit_cost')), findsOneWidget);
      expect(find.text('2 séances'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Annulation et présence', () {
    test('annulation au moins 12 h avant : crédit libéré', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      final r = await b.reservationService.book('c_s2'); // dans 26 h 30
      expect(
        b.packs.cancelOutcome(r, b.courses.byId('c_s2')!),
        CancelOutcome.released,
      );
      await b.reservationService.cancel(r.id);
      expect(_pack(b, _hedi5).stateOf(r.id), PackMoveKind.released);
      expect(_pack(b, _hedi5).remaining, 1);
    });

    test('annulation tardive : crédit consommé', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      final r = await b.reservationService.book('c_s1');
      setNow(DateTime(2026, 10, 1, 8)); // 10 h avant
      expect(
        b.packs.cancelOutcome(r, b.courses.byId('c_s1')!),
        CancelOutcome.consumed,
      );
      await b.reservationService.cancel(r.id);
      expect(_pack(b, _hedi5).stateOf(r.id), PackMoveKind.consumed);
      expect(_pack(b, _hedi5).remaining, 0);
    });

    test('délai d\'annulation gratuite réglable par l\'admin', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      await expectLater(
        b.packs.saveSettings(freeCancelHours: 48),
        throwsA(isA<PermissionDeniedException>()),
      );
      await b.auth.logout();
      await loginAs(b, 'admin@gymflow.tn');
      await expectLater(
        b.packs.saveSettings(freeCancelHours: 0),
        throwsA(isA<ValidationException>()),
      );
      await b.packs.saveSettings(freeCancelHours: 48);
      expect(
        b.auditRepo.all.any((a) => a.action == 'Réglages des cours'),
        isTrue,
      );
      await b.auth.logout();
      await loginAs(b, 'hedi@gymflow.tn');
      final r = await b.reservationService.book('c_s2'); // dans 26 h 30 < 48 h
      await b.reservationService.cancel(r.id);
      expect(_pack(b, _hedi5).stateOf(r.id), PackMoveKind.consumed);
    });

    test('absence pointée : crédit consommé', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      final r = await b.reservationService.book('c_s1');
      await b.auth.logout();
      await loginAs(b, 'amira@gymflow.tn');
      setNow(DateTime(2026, 10, 1, 18, 5));
      await b.reservationService.markAttendance(r.id, false);
      expect(_pack(b, _hedi5).stateOf(r.id), PackMoveKind.consumed);
      // Correction du pointage : la séance n'est pas décomptée deux fois.
      await b.reservationService.markAttendance(r.id, true);
      expect(_pack(b, _hedi5).consumedCount, 5);
    });

    test('cours terminé sans pointage : consommé à la mise à jour', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      final r = await b.reservationService.book('c_s1');
      setNow(DateTime(2026, 10, 2, 9));
      await b.packs.sync('u_hedi');
      expect(_pack(b, _hedi5).stateOf(r.id), PackMoveKind.consumed);
    });

    test('cours annulé par le coach : crédit remboursé et prévenu', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      final r = await b.reservationService.book('c_s1');
      await b.auth.logout();
      await loginAs(b, 'amira@gymflow.tn');
      await b.courseService.cancel('c_s1', 'Coach malade');
      expect(_pack(b, _hedi5).stateOf(r.id), PackMoveKind.refunded);
      expect(_pack(b, _hedi5).remaining, 1);
      final n = b.notificationsRepo.where(
        (n) => n.userId == 'u_hedi' && n.title.contains('Cours annulé'),
      );
      expect(n.single.body, contains('recréditée'));
    });
  });

  group('Liste d\'attente', () {
    test('aucun crédit bloqué en attente ; réservé à la promotion', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      final w = await b.reservationService.book('c_s3', joinWaitlist: true);
      expect(w.status, ReservationStatus.waitlisted);
      expect(w.packId, isNull);
      expect(_pack(b, _hedi5).openCount, 0);
      expect(_pack(b, _hedi5).remaining, 1);
      await b.auth.logout();
      await loginAs(b, 'leila@gymflow.tn');
      await b.reservationService.cancel(
        b.reservationService.activeFor('c_s3', 'u_leila')!.id,
      );
      final promoted = b.reservations.byId(w.id)!;
      expect(promoted.status, ReservationStatus.confirmed);
      expect(promoted.packId, _hedi5);
      expect(_pack(b, _hedi5).isOpen(w.id), isTrue);
    });

    test('promotion sans crédit : rang conservé, place au suivant', () async {
      final b = await makeBackend();
      await _onlyPacks(b, 'u_hedi', {_hedi5});
      await loginAs(b, 'hedi@gymflow.tn');
      final w = await b.reservationService.book('c_s3', joinWaitlist: true);
      await b.reservationService.book('c_s1'); // dernière séance utilisée
      await b.auth.logout();
      await loginAs(b, 'nour@gymflow.tn');
      final nour = await b.reservationService.book('c_s3', joinWaitlist: true);
      await b.auth.logout();
      await loginAs(b, 'leila@gymflow.tn');
      await b.reservationService.cancel(
        b.reservationService.activeFor('c_s3', 'u_leila')!.id,
      );
      expect(b.reservations.byId(w.id)!.status, ReservationStatus.waitlisted);
      expect(b.reservationService.waitlistPosition(w), 1);
      expect(b.reservations.byId(nour.id)!.status, ReservationStatus.confirmed);
      expect(
        b.notificationsRepo.all.any(
          (n) =>
              n.userId == 'u_hedi' &&
              n.body.contains('vous n\'avez plus de crédit'),
        ),
        isTrue,
      );
      // Hedi achète un carnet : prioritaire au prochain désistement.
      await b.auth.logout();
      await loginAs(b, 'hedi@gymflow.tn');
      final bought = await b.packs.buy('po_unit', _paid(16));
      await b.auth.logout();
      await loginAs(b, 'ahmed@gymflow.tn');
      await b.reservationService.cancel(
        b.reservationService.activeFor('c_s3', 'u_ahmed')!.id,
      );
      final after = b.reservations.byId(w.id)!;
      expect(after.status, ReservationStatus.confirmed);
      expect(after.packId, bought.id);
    });

    test('sortie de la liste d\'attente au début du cours', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      final w = await b.reservationService.book('c_s3', joinWaitlist: true);
      setNow(DateTime(2026, 10, 2, 7, 31));
      expect(await b.reservationService.closeStartedWaitlists(), 1);
      expect(b.reservations.byId(w.id)!.status, ReservationStatus.cancelled);
      expect(_pack(b, _hedi5).remaining, 1);
    });
  });

  group('Alertes et expiration', () {
    test('alerte « il reste 1 séance », une seule fois', () async {
      final b = await makeBackend();
      await b.packs.sync('u_hedi');
      await b.packs.sync('u_hedi');
      final alerts = b.notificationsRepo.where(
        (n) => n.userId == 'u_hedi' && n.title.contains('Plus qu\'une séance'),
      );
      expect(alerts, hasLength(1));
      expect(alerts.single.type, NotificationType.pack);
    });

    test('alerte d\'expiration à 7 jours avec séances restantes', () async {
      final b = await makeBackend();
      await b.packs.sync('u_omar'); // carnet Zen : expire le 6/10, 5 séances
      await b.packs.sync('u_omar');
      final alerts = b.notificationsRepo.where(
        (n) => n.userId == 'u_omar' && n.title.contains('expire bientôt'),
      );
      expect(alerts, hasLength(1));
      expect(alerts.single.body, contains('5 séances'));
      // Hedi : formule expirant dans 28 jours, pas d'alerte d'expiration.
      await b.packs.sync('u_hedi');
      expect(
        b.notificationsRepo.all.any(
          (n) => n.userId == 'u_hedi' && n.title.contains('expire bientôt'),
        ),
        isFalse,
      );
    });

    test('à l\'expiration, les séances restantes sont perdues', () async {
      final b = await makeBackend();
      setNow(DateTime(2026, 10, 7));
      await b.packs.sync('u_omar');
      final zen = _pack(b, 'pk_demo_omar_zen');
      expect(zen.expiredCount, 5);
      expect(zen.remaining, 0);
      await b.packs.sync('u_omar');
      expect(_pack(b, 'pk_demo_omar_zen').movements, hasLength(1));
    });
  });

  group('Achat', () {
    test('carnet créé après paiement accepté, timbre compris', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final q = b.packs.quote('po_10');
      expect(q.total, 121); // 120 DT + timbre fiscal de 1 DT
      final pack = await b.packs.buy('po_10', _paid(121));
      expect(pack.userId, 'u_nour');
      expect(pack.remaining, 10);
      expect(pack.price, 121);
      expect(pack.paymentRef, 'SIM-TEST-1');
      // Valable 120 jours, jusqu'à la fin du dernier jour.
      expect(pack.expiresAt, DateTime(2026, 9, 30 + 121));
      expect(b.auditRepo.all.any((a) => a.action == 'Achat de carnet'), isTrue);
      // Aucune donnée de carte dans le carnet.
      expect(jsonEncode(pack.toJson()), isNot(contains('4242')));
    });

    test('paiement refusé, montant faux, paiement réutilisé : refus', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      await expectLater(
        b.packs.buy(
          'po_unit',
          const PaymentResult(success: false, method: 'x', reference: 'y'),
        ),
        _rule('non validé'),
      );
      await expectLater(
        b.packs.buy('po_unit', _paid(15)), // timbre oublié
        _rule('ne correspond pas'),
      );
      await b.packs.buy('po_unit', _paid(16));
      await expectLater(
        b.packs.buy('po_unit', _paid(16)),
        _rule('déjà été utilisé'),
      );
      expect(b.sessionPacks.where((x) => x.userId == 'u_nour'), hasLength(1));
    });

    test('paiement simulé de bout en bout', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final gateway = b.payment as SimulatedPaymentGateway;
      final q = b.packs.quote('po_5');
      final result = await gateway.charge(
        cardNumber: '4242 4242 4242 4242',
        expiry: '12/30',
        cvc: '123',
        amount: q.total,
        now: b.now(),
      );
      final pack = await b.packs.buy('po_5', result);
      expect(pack.paymentMethod, 'simulated');
      final r = await b.reservationService.book('c_s9');
      expect(r.packId, pack.id);
    });

    test('formule retirée : achat impossible', () async {
      final b = await makeBackend();
      await loginAs(b, 'admin@gymflow.tn');
      await b.packs.deleteOffer('po_10');
      await b.auth.logout();
      await loginAs(b, 'nour@gymflow.tn');
      expect(() => b.packs.quote('po_10'), _rule('plus en vente'));
      expect(b.packs.offers().map((o) => o.id), isNot(contains('po_10')));
    });
  });

  group('Formules (admin)', () {
    test('seul l\'admin gère les formules ; validations', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      await expectLater(
        b.packs.saveOffer(
          name: 'Pirate',
          kind: PackKind.credits,
          quota: 3,
          validityDays: 30,
          price: 1,
        ),
        throwsA(isA<PermissionDeniedException>()),
      );
      await b.auth.logout();
      await loginAs(b, 'admin@gymflow.tn');
      await expectLater(
        b.packs.saveOffer(
          name: 'Trop',
          kind: PackKind.weekly,
          quota: 8,
          validityDays: 30,
          price: 50,
        ),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        b.packs.saveOffer(
          name: 'Gratuit',
          kind: PackKind.credits,
          quota: 3,
          validityDays: 30,
          price: 0,
        ),
        throwsA(isA<ValidationException>()),
      );
      final o = await b.packs.saveOffer(
        name: 'Carnet Boxe 8',
        kind: PackKind.credits,
        quota: 8,
        validityDays: 90,
        price: 90,
        categories: [CourseCategory.boxing],
      );
      expect(b.packs.offers().any((x) => x.id == o.id), isTrue);
      expect(
        b.auditRepo.all.any((a) => a.action == 'Création de formule'),
        isTrue,
      );
    });

    test('formule vendue retirée de la vente, sinon supprimée', () async {
      final b = await makeBackend();
      await loginAs(b, 'admin@gymflow.tn');
      expect(await b.packs.deleteOffer('po_5'), isFalse); // vendue à Hedi
      expect(b.packOffers.byId('po_5')!.active, isFalse);
      expect(_pack(b, _hedi5).remaining, 1); // carnet vendu intact
      expect(
        b.packs.offers(includeInactive: true).any((o) => o.id == 'po_5'),
        isTrue,
      );
      expect(await b.packs.deleteOffer('po_10'), isTrue);
      expect(b.packOffers.byId('po_10'), isNull);
    });
  });

  group('Confidentialité', () {
    test('export et effacement : carnets exportés puis anonymisés', () async {
      final b = await makeBackend();
      await loginAs(b, 'hedi@gymflow.tn');
      final export = jsonDecode(b.privacy.exportMyData()) as Map;
      expect((export['carnets'] as List), hasLength(2));
      await b.privacy.eraseUser(b.requireUser());
      final kept = b.sessionPacks.byId(_hedi5)!;
      expect(kept.userId, startsWith('anonyme-'));
      expect(b.sessionPacks.where((x) => x.userId == 'u_hedi'), isEmpty);
    });
  });

  test('SQLite : une base v2 reçoit les tables des carnets', () async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('gymflow_v2_');
    final path = p.join(dir.path, 'v2.db');
    // Base créée par la version 2 : boutique, sans les tables des carnets.
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, _) async {
          for (final t in ['reservations', 'coupons', 'loyalty']) {
            await db.execute(
              'CREATE TABLE $t (id TEXT PRIMARY KEY, data TEXT NOT NULL, '
              'updated_at INTEGER NOT NULL)',
            );
          }
          await db.execute(
            'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.insert('reservations', {
            'id': 'r_1',
            'data': '{"id":"r_1","courseId":"c","userId":"u"}',
            'updated_at': 0,
          });
        },
      ),
    );
    await old.close();
    final store = SqliteDataStore(fileName: path, factory: databaseFactoryFfi);
    await store.open();
    final res = await store.loadAll(Collections.reservations);
    expect(Reservation.fromJson(res.single).packId, isNull);
    for (final c in [
      Collections.packOffers,
      Collections.sessionPacks,
      Collections.gymSettings,
    ]) {
      expect(await store.loadAll(c), isEmpty);
    }
    await store.put(
      Collections.sessionPacks,
      'pk',
      SessionPack(
        id: 'pk',
        userId: 'u',
        offerId: 'o',
        name: 'Carnet',
        kind: PackKind.credits,
        quota: 3,
        purchasedAt: DateTime(2026, 9),
        expiresAt: DateTime(2026, 12),
      ).toJson(),
    );
    final loaded = await store.loadAll(Collections.sessionPacks);
    expect(SessionPack.fromJson(loaded.single).remaining, 3);
  });

  group('Écrans', () {
    testWidgets('Mes carnets : solde, expiration et historique', (
      tester,
    ) async {
      await pumpApp(tester, route: Routes.home, loginEmail: 'hedi@gymflow.tn');
      await go(tester, Routes.myPacks);
      expect(find.text('Mes carnets'), findsWidgets);
      expect(
        tester.widget<Text>(find.byKey(const Key('pack_balance_$_hedi5'))).data,
        '1 séance sur 5',
      );
      expect(
        find.textContaining('Valable jusqu\'au 10/10/2026'),
        findsOneWidget,
      );
      await tapVisible(tester, find.byKey(const Key('pack_history_$_hedi5')));
      expect(find.textContaining('Consommé · Yoga Vinyasa'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fiche du cours : choix du carnet puis réservation', (
      tester,
    ) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'hedi@gymflow.tn',
      );
      await go(tester, Routes.courseDetail, 'c_s1');
      expect(find.byKey(const Key('pack_choice')), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('choose_$_hediWeek')));
      await tapVisible(tester, find.byKey(const Key('book_course')));
      final r = b.reservationService.activeFor('c_s1', 'u_hedi')!;
      expect(r.packId, _hediWeek);
      expect(find.textContaining('Séance prise sur'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sans carnet : refus expliqué, achat puis réservation', (
      tester,
    ) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'nour@gymflow.tn',
      );
      await go(tester, Routes.courseDetail, 'c_s9');
      expect(find.byKey(const Key('no_credit')), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('buy_pack')));
      await tapVisible(tester, find.byKey(const Key('buy_po_unit')));
      expect(find.textContaining('16,00'), findsWidgets);
      await tapVisible(tester, find.byKey(const Key('pack_pay')));
      await settle(tester);
      final pack = b.sessionPacks.where((x) => x.userId == 'u_nour').single;
      expect(pack.price, 16);
      // Retour aux carnets puis à la fiche : la réservation est possible.
      GymFlowApp.navigatorKey.currentState!.pop();
      await settle(tester, 5000); // fin du message de confirmation
      await tapVisible(tester, find.byKey(const Key('book_course')));
      expect(b.reservationService.activeFor('c_s9', 'u_nour')!.packId, pack.id);
      expect(tester.takeException(), isNull);
    });

    testWidgets('admin : formules, ventes et création', (tester) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'admin@gymflow.tn',
      );
      await go(tester, Routes.packOffers);
      expect(find.byKey(const Key('offer_po_5')), findsOneWidget);
      expect(find.textContaining('1 vente'), findsWidgets);
      await go(tester, Routes.packOfferForm);
      await tester.enterText(
        find.byKey(const Key('offer_name')),
        'Carnet Spinning 8',
      );
      await tester.enterText(find.byKey(const Key('offer_quota')), '8');
      await tester.enterText(find.byKey(const Key('offer_validity')), '60');
      await tester.enterText(find.byKey(const Key('offer_price')), '80');
      await tapVisible(tester, find.byKey(const Key('offer_save')));
      expect(
        b.packOffers.all.any((o) => o.name == 'Carnet Spinning 8'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
