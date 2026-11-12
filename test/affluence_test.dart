import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/checkin.dart';
import 'package:gymflow/models/course.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/models/gym_settings.dart';
import 'package:gymflow/models/user.dart';
import 'package:gymflow/repositories/data_store.dart';
import 'package:gymflow/repositories/sqlite_data_store.dart';
import 'package:gymflow/screens/courses/affluence_screens.dart';
import 'package:gymflow/services/affluence_service.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/checkin_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

/// Affluence et check-in (étape 3). Horloge : mercredi 30 septembre 2026,
/// 10 h. Lundi précédent : 28/09 (semaine la plus récente).
var _n = 0;

Future<CheckIn> _in(Backend b, String userId, DateTime at, {DateTime? exit}) =>
    b.checkIns.save(
      CheckIn(
        id: 'ci_t${_n++}',
        userId: userId,
        at: at,
        byId: 'u_admin',
        exitAt: exit,
      ),
    );

Future<AppUser> _user(Backend b, [String? id]) => b.users.save(
  AppUser(
    id: id ?? 'u_a${_n++}',
    email: 'a$_n@test.tn',
    fullName: 'Test Affluence',
    role: UserRole.member,
    createdAt: DateTime(2026),
  ),
);

Future<Course> _course(
  Backend b,
  DateTime at, {
  int minutes = 60,
  String coach = 'u_amira',
}) => b.courses.save(
  Course(
    id: 'c_a${_n++}',
    title: 'Cours affluence',
    description: '',
    category: CourseCategory.yoga,
    level: Level.beginner,
    coachId: coach,
    room: 'Studio',
    capacity: 20,
    durationMin: minutes,
    createdAt: DateTime(2026),
    startAt: at,
  ),
);

Future<void> _attend(Backend b, Course c, String userId, {bool? attended}) =>
    b.reservations.save(
      Reservation(
        id: 'r_a${_n++}',
        courseId: c.id,
        userId: userId,
        status: ReservationStatus.confirmed,
        createdAt: DateTime(2026),
        attended: attended,
      ),
    );

/// Somme des poids des 8 semaines (0,85⁰ … 0,85⁷).
final _weights = [for (var i = 0; i < 8; i++) math.pow(0.85, i).toDouble()];
final _sumW = _weights.reduce((a, b) => a + b);

void main() {
  group('Modèle et stockage', () {
    test('réglages et entrées : anciennes données lisibles', () {
      const s = GymSettings();
      expect(s.capacity, 40);
      expect(s.stayMinutes, 90);
      final old = GymSettings.fromJson({'freeCancelHours': 24});
      expect(old.freeCancelHours, 24);
      expect(old.openHour, 6);
      expect(old.closeHour, 22);
      final c = CheckIn.fromJson({'id': 'x', 'userId': 'u'});
      expect(c.source, CheckInSource.qr);
      expect(c.exitAt, isNull);
      // Sortie scannée avant la sortie automatique : elle fait foi.
      final at = DateTime(2026, 9, 1, 18);
      final scanned = CheckIn(
        id: 'a',
        userId: 'u',
        at: at,
        byId: 'b',
        exitAt: at.add(const Duration(minutes: 40)),
      );
      expect(
        scanned.endAt(const Duration(minutes: 90)),
        at.add(const Duration(minutes: 40)),
      );
      expect(
        CheckIn(
          id: 'b',
          userId: 'u',
          at: at,
          byId: 'b',
        ).endAt(const Duration(minutes: 90)),
        at.add(const Duration(minutes: 90)),
      );
    });

    test('SQLite : une base v4 reçoit la table des entrées', () async {
      sqfliteFfiInit();
      final dir = Directory.systemTemp.createTempSync('gymflow_v4_');
      final path = p.join(dir.path, 'v4.db');
      final old = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE gym_settings (id TEXT PRIMARY KEY, '
              'data TEXT NOT NULL, updated_at INTEGER NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
            );
            await db.insert('gym_settings', {
              'id': 'gym',
              'data': '{"id":"gym","freeCancelHours":12}',
              'updated_at': 0,
            });
          },
        ),
      );
      await old.close();
      final store = SqliteDataStore(
        fileName: path,
        factory: databaseFactoryFfi,
      );
      await store.open();
      final gs = await store.loadAll(Collections.gymSettings);
      expect(GymSettings.fromJson(gs.single).capacity, 40);
      expect(await store.loadAll(Collections.checkIns), isEmpty);
      final c = CheckIn(
        id: 'ci',
        userId: 'u',
        at: DateTime(2026, 9, 1, 18),
        byId: 'u_admin',
      );
      await store.put(Collections.checkIns, c.id, c.toJson());
      expect(
        CheckIn.fromJson(
          (await store.loadAll(Collections.checkIns)).single,
        ).userId,
        'u',
      );
    });
  });

  group('Check-in par QR', () {
    Future<(Backend, String)> qrOf(String email) async {
      final b = await makeBackend();
      await loginAs(b, email);
      final (code, _) = b.checkInService.myEntryQr();
      await b.auth.logout();
      await loginAs(b, 'admin@gymflow.tn');
      return (b, code);
    }

    test('entrée puis sortie ; un seul check-in en cours', () async {
      final (b, code) = await qrOf('leila@gymflow.tn');
      final first = await b.checkInService.scan(code);
      expect(first.entered, isTrue);
      expect(first.member.id, 'u_leila');
      expect(first.checkIn.source, CheckInSource.qr);
      expect(b.checkInService.openFor('u_leila'), isNotNull);
      // Second scan : sortie, pas un second check-in.
      setNow(DateTime(2026, 9, 30, 10, 0, 30));
      final second = await b.checkInService.scan(code);
      expect(second.entered, isFalse);
      expect(second.checkIn.exitAt, isNotNull);
      expect(b.checkIns.where((c) => c.userId == 'u_leila'), hasLength(1));
      expect(b.checkInService.openFor('u_leila'), isNull);
    });

    test('le QR change toutes les 60 s (10 s de tolérance)', () async {
      final (b, code) = await qrOf('leila@gymflow.tn');
      final parts = code.split('|');
      expect(parts.first, CheckInService.version);
      expect(parts[1], 'u_leila');
      // 10 h 01 min 05 s : fenêtre suivante, encore dans la tolérance.
      setNow(DateTime(2026, 9, 30, 10, 1, 5));
      b.checkInService.verify(code);
      // 10 h 01 min 15 s : capture d'écran trop ancienne.
      setNow(DateTime(2026, 9, 30, 10, 1, 15));
      expect(
        () => b.checkInService.verify(code),
        throwsA(
          isA<BusinessRuleException>().having(
            (e) => e.message,
            'm',
            contains('expiré'),
          ),
        ),
      );
    });

    test('QR falsifié ou étranger : refusé', () async {
      final (b, code) = await qrOf('leila@gymflow.tn');
      final forged = code.replaceFirst('u_leila', 'u_ines');
      expect(
        () => b.checkInService.verify(forged),
        throwsA(isA<BusinessRuleException>()),
      );
      expect(
        () => b.checkInService.verify('GF1|o_1|123|abc'),
        throwsA(isA<ValidationException>()),
      );
      // Signature en temps constant, même longueur différente.
      expect(
        () => b.checkInService.verify('${code}x'),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('scan réservé à l\'accueil (admin ou coach)', () async {
      final b = await makeBackend();
      await loginAs(b, 'leila@gymflow.tn');
      final (code, _) = b.checkInService.myEntryQr();
      await expectLater(
        b.checkInService.scan(code),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(Routes.rolesFor(Routes.checkinScan), {
        UserRole.superAdmin,
        UserRole.coach,
      });
      expect(Routes.rolesFor(Routes.entryQr), {UserRole.member});
      await b.auth.logout();
      await loginAs(b, 'amira@gymflow.tn');
      expect((await b.checkInService.scan(code)).entered, isTrue);
      // Un coach n'a pas de QR d'entrée.
      expect(
        () => b.checkInService.myEntryQr(),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('sortie automatique après la durée réglée', () async {
      final (b, code) = await qrOf('leila@gymflow.tn');
      await b.checkInService.scan(code);
      setNow(DateTime(2026, 9, 30, 11, 29));
      expect(b.checkInService.openFor('u_leila'), isNotNull);
      setNow(DateTime(2026, 9, 30, 11, 31));
      expect(b.checkInService.openFor('u_leila'), isNull);
      await b.checkInService.saveSettings(
        capacity: 30,
        stayMinutes: 120,
        openHour: 6,
        closeHour: 22,
      );
      expect(b.checkInService.openFor('u_leila'), isNotNull);
    });

    test('compte désactivé et réglages invalides : refusés', () async {
      final b = await makeBackend();
      await loginAs(b, 'admin@gymflow.tn');
      await expectLater(
        b.checkInService.manual('u_walid'),
        throwsA(isA<BusinessRuleException>()),
      );
      await expectLater(
        b.checkInService.saveSettings(
          capacity: 0,
          stayMinutes: 90,
          openHour: 6,
          closeHour: 22,
        ),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        b.checkInService.saveSettings(
          capacity: 30,
          stayMinutes: 90,
          openHour: 20,
          closeHour: 22,
        ),
        throwsA(isA<ValidationException>()),
      );
      await b.auth.logout();
      await loginAs(b, 'amira@gymflow.tn');
      await expectLater(
        b.checkInService.saveSettings(
          capacity: 30,
          stayMinutes: 90,
          openHour: 6,
          closeHour: 22,
        ),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('une entrée compte comme venue pour le risque d\'abandon', () async {
      final (b, code) = await qrOf('mariem@gymflow.tn');
      final before = b.churnRisk.compute(b.users.byId('u_mariem')!);
      await b.checkInService.scan(code);
      final after = b.churnRisk.compute(b.users.byId('u_mariem')!);
      expect(after.lastVisit, DateTime(2026, 9, 30));
      expect(after.score, lessThan(before.score));
    });
  });

  group('Affluence', () {
    test(
      'occupation actuelle : entrées et cours en cours, sans doublon',
      () async {
        final b = await makeBackend(seed: false);
        final now = DateTime(2026, 9, 30, 10);
        final a = await _user(b);
        final c = await _user(b);
        final d = await _user(b);
        await _in(b, a.id, now.subtract(const Duration(minutes: 30)));
        // Sortie scannée : plus présent.
        await _in(
          b,
          c.id,
          now.subtract(const Duration(minutes: 50)),
          exit: now.subtract(const Duration(minutes: 5)),
        );
        // Parti automatiquement (entrée il y a 2 h).
        await _in(b, d.id, now.subtract(const Duration(hours: 2)));
        final course = await _course(b, DateTime(2026, 9, 30, 9, 30));
        await _attend(b, course, a.id); // déjà comptée (entrée)
        await _attend(b, course, c.id);
        expect(b.affluence.occupancyAt(now), 2);
        final cur = b.affluence.current();
        expect(cur.expected, 2);
        expect(cur.capacity, 40);
        expect(cur.crowd, Crowd.calm);
      },
    );

    test('carte de chaleur : moyenne pondérée par semaine', () async {
      final b = await makeBackend(seed: false);
      final users = [for (var i = 0; i < 3; i++) await _user(b)];
      // Lundi 28/09 (semaine 0) : 1 personne à 18 h.
      await _in(b, users[0].id, DateTime(2026, 9, 28, 18, 10));
      // Lundi 21/09 (semaine 1, poids 0,85) : 3 personnes.
      for (final u in users) {
        await _in(b, u.id, DateTime(2026, 9, 21, 18, 5));
      }
      final m = b.affluence.heatmap();
      expect(
        m.freeAt(DateTime.monday, 18),
        closeTo((1 + 0.85 * 3) / _sumW, 1e-9),
      );
      expect(m.at(DateTime.tuesday, 18), 0);
      expect(m.openHour, 6);
      expect(m.closeHour, 22);
      // Présence de 90 min à partir de 18 h 10 : comptée de 18 h à 19 h 40.
      expect(m.freeAt(DateTime.monday, 19), greaterThan(0));
      expect(m.freeAt(DateTime.monday, 20), 0);
    });

    test(
      'pondération : une semaine récente pèse plus qu\'une ancienne',
      () async {
        final b = await makeBackend(seed: false);
        final u = await _user(b);
        await _in(b, u.id, DateTime(2026, 9, 29, 12)); // mardi, semaine 0
        await _in(b, u.id, DateTime(2026, 8, 13, 7)); // jeudi, semaine 6
        final m = b.affluence.heatmap();
        expect(
          m.freeAt(DateTime.tuesday, 12),
          closeTo(_weights[0] / _sumW, 1e-9),
        );
        expect(
          m.freeAt(DateTime.thursday, 7),
          closeTo(_weights[6] / _sumW, 1e-9),
        );
        expect(
          m.freeAt(DateTime.tuesday, 12),
          greaterThan(m.freeAt(DateTime.thursday, 7)),
        );
        // Au-delà de 8 semaines : ignoré.
        await _in(b, u.id, DateTime(2026, 7, 1, 7));
        expect(b.affluence.heatmap().freeAt(DateTime.wednesday, 7), 0);
      },
    );

    test(
      'cours pointés : comptés à part, une seule fois par personne',
      () async {
        final b = await makeBackend(seed: false);
        final u = await _user(b);
        final v = await _user(b);
        final c = await _course(b, DateTime(2026, 9, 28, 18));
        await _attend(b, c, u.id, attended: true);
        await _attend(b, c, v.id, attended: false); // absent : non compté
        await _in(b, u.id, DateTime(2026, 9, 28, 17, 50));
        final m = b.affluence.heatmap();
        expect(m.courseAt(DateTime.monday, 18), closeTo(1 / _sumW, 1e-9));
        expect(m.freeAt(DateTime.monday, 18), 0);
        expect(m.freeAt(DateTime.monday, 17), closeTo(1 / _sumW, 1e-9));
      },
    );

    test('prévision : historique pondéré + réservations déjà faites', () async {
      final b = await makeBackend(seed: false);
      final users = [for (var i = 0; i < 4; i++) await _user(b)];
      await _in(b, users[0].id, DateTime(2026, 9, 28, 18, 5));
      final next = await _course(b, DateTime(2026, 10, 5, 18));
      for (final u in users.skip(1)) {
        await _attend(b, next, u.id);
      }
      final f = b.affluence.forecast(DateTime(2026, 10, 5, 18, 30));
      expect(f.start, DateTime(2026, 10, 5, 18));
      expect(f.booked, 3);
      expect(f.expected, closeTo(1 / _sumW + 3, 1e-9));
      expect(f.crowd, Crowd.calm);
      expect(Crowd.of(0.34), Crowd.calm);
      expect(Crowd.of(0.35), Crowd.moderate);
      expect(Crowd.of(0.6), Crowd.busy);
      expect(Crowd.of(0.85), Crowd.full);
      expect(AffluenceService.describe(f), contains('% de la capacité'));
    });

    test('créneaux conseillés : calmes, habituels, sans conflit', () async {
      final b = await makeBackend(seed: false);
      final me = await _user(b, 'u_me');
      final crowd = [for (var i = 0; i < 6; i++) await _user(b)];
      // Habitude : vers 18 h (3 venues).
      for (final d in [7, 14, 21]) {
        await _in(b, me.id, DateTime(2026, 9, 30 - d, 18, 15));
      }
      // 18 h très fréquenté tous les jours ; 17 h et 19 h calmes.
      for (var d = 1; d <= 7; d++) {
        for (final u in crowd) {
          await _in(
            b,
            u.id,
            DateTime(2026, 9, 30 - d, 18, 0),
            exit: DateTime(2026, 9, 30 - d, 18, 55),
          );
        }
      }
      // Cours déjà réservé jeudi 17 h : ce créneau est écarté.
      final mine = await _course(b, DateTime(2026, 10, 1, 17));
      await _attend(b, mine, me.id);
      final s = b.affluence.suggestions(me.id);
      expect(s, hasLength(3));
      for (final x in s) {
        expect([17, 19], contains(x.forecast.start.hour));
        expect(x.forecast.start.isAfter(DateTime(2026, 9, 30, 10)), isTrue);
        expect(x.reason, contains('18 h'));
        expect(x.forecast.start == DateTime(2026, 10, 1, 17), isFalse);
      }
      // Un seul créneau par jour.
      expect(
        s
            .map(
              (x) => DateTime(
                x.forecast.start.year,
                x.forecast.start.month,
                x.forecast.start.day,
              ),
            )
            .toSet(),
        hasLength(3),
      );
      // Sans habitude : créneaux calmes de la journée.
      final fresh = await _user(b);
      expect(b.affluence.suggestions(fresh.id), hasLength(3));
    });

    test('démo : la carte montre des pics et des creux', () async {
      final b = await makeBackend();
      final m = b.affluence.heatmap();
      expect(m.max, greaterThan(b.packs.settings.capacity * 0.6));
      expect(m.at(DateTime.saturday, 16), lessThan(1));
      expect(b.affluence.suggestions('u_leila'), isNotEmpty);
    });
  });

  group('Confidentialité', () {
    test('export et effacement des entrées', () async {
      final b = await makeBackend();
      await loginAs(b, 'leila@gymflow.tn');
      final (code, _) = b.checkInService.myEntryQr();
      await b.auth.logout();
      await loginAs(b, 'admin@gymflow.tn');
      await b.checkInService.scan(code);
      await b.auth.logout();
      await loginAs(b, 'leila@gymflow.tn');
      final export = jsonDecode(b.privacy.exportMyData()) as Map;
      expect((export['entrees_salle'] as List), hasLength(1));
      await b.privacy.eraseUser(b.requireUser());
      expect(b.checkIns.where((c) => c.userId == 'u_leila'), isEmpty);
    });
  });

  group('Écrans', () {
    testWidgets('affluence à 360 dp : sans débordement, carte et conseils', (
      tester,
    ) async {
      await pumpApp(tester, route: Routes.home, loginEmail: 'leila@gymflow.tn');
      await go(tester, Routes.affluence);
      expect(find.byKey(const Key('occupancy_now')), findsOneWidget);
      expect(find.byKey(const Key('suggestion_0')), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('heat_1_19')));
      expect(find.textContaining('Lundi 19 h'), findsOneWidget);
      // Toutes les cases tiennent dans la largeur du téléphone.
      final last = tester.getRect(find.byKey(const Key('heat_7_21')));
      expect(last.right, lessThanOrEqualTo(360));
      await tapVisible(tester, find.byKey(const Key('forecast_day_5')));
      expect(find.byKey(const Key('forecast_text')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('QR d\'entrée puis scan à l\'accueil', (tester) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'ines@gymflow.tn',
      );
      await go(tester, Routes.entryQr);
      expect(find.byKey(const Key('entry_qr')), findsOneWidget);
      expect(find.textContaining('Nouveau code dans'), findsOneWidget);
      final (code, _) = b.checkInService.myEntryQr();
      await b.auth.logout();
      await loginAs(b, 'sarra@gymflow.tn');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        const MaterialApp(home: CheckInScanScreen(useCamera: false)),
      );
      await settle(tester);
      await tester.enterText(find.byKey(const Key('checkin_manual')), code);
      await tapVisible(tester, find.byKey(const Key('checkin_submit')));
      expect(
        tester.widget<Text>(find.byKey(const Key('checkin_result'))).data,
        startsWith('Entrée : '),
      );
      expect(b.checkInService.openFor('u_ines'), isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('admin : réglage de la capacité', (tester) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'admin@gymflow.tn',
      );
      await go(tester, Routes.affluence);
      await tester.tap(find.byKey(const Key('gym_settings')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('set_capacity')), '35');
      await tester.tap(find.byKey(const Key('set_save')));
      await settle(tester);
      expect(b.packs.settings.capacity, 35);
      expect(tester.takeException(), isNull);
    });
  });
}
