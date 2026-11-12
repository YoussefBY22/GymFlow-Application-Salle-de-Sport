import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/gym_settings.dart';
import 'package:gymflow/models/ramadan.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/repositories/data_store.dart';
import 'package:gymflow/repositories/sqlite_data_store.dart';
import 'package:gymflow/services/aladhan_api.dart';
import 'package:gymflow/services/backend.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

/// Mode Ramadan (étape 4). Horloge : mercredi 30 septembre 2026, 10 h.
/// Cours de démo : yoga jeudi 1/10 à 18 h (c_s1), HIIT jeudi 1/10 à
/// 12 h 30 (c_s2), Pilates dimanche 4/10 à 10 h (c_s6), Zumba samedi 3/10
/// à 19 h (c_s5).

/// Faux serveur Aladhan : enregistre les requêtes.
class _FakeAladhan {
  final requests = <Uri>[];
  bool offline = false;

  late final client = MockClient((r) async {
    requests.add(r.url);
    if (offline) throw http.ClientException('hors ligne');
    if (r.url.path.contains('/calendarByCity/2026/2')) {
      return http.Response(
        jsonEncode({
          'code': 200,
          'data': [
            {
              'timings': {'Maghrib': '18:02 (CET)'},
              'date': {
                'gregorian': {'date': '17-02-2026'},
              },
            },
            {
              'timings': {'Maghrib': '18:03 (CET)'},
              'date': {
                'gregorian': {'date': '18-02-2026'},
              },
            },
          ],
        }),
        200,
      );
    }
    if (r.url.path.endsWith('/hToGCalendar/9/1448')) {
      return http.Response(
        jsonEncode({
          'code': 200,
          'data': [
            {
              'gregorian': {'date': '08-02-2027'},
              'hijri': {'date': '01-09-1448'},
            },
            {
              'gregorian': {'date': '08-03-2027'},
              'hijri': {'date': '29-09-1448'},
            },
          ],
        }),
        200,
      );
    }
    return http.Response('{"code":404}', 404);
  });
}

/// Période confirmée du 1er au 29 octobre 2026 (couvre les cours de démo).
Future<void> _octoberRamadan(Backend b) async {
  await loginAs(b, 'admin@gymflow.tn');
  await b.ramadan.confirm(
    hijriYear: 1999,
    start: DateTime(2026, 10, 1),
    end: DateTime(2026, 10, 29),
  );
}

void main() {
  group('Modèle et stockage', () {
    test('anciens réglages lisibles ; période : limites incluses', () {
      final s = GymSettings.fromJson({'capacity': 30});
      expect(s.ramadanPeriods, isEmpty);
      expect(s.ramadanHours.dayOpen, 9);
      expect(s.ramadanHours.eveningClose, 24);
      final p = RamadanPeriod(
        hijriYear: 1447,
        start: DateTime(2026, 2, 19),
        end: DateTime(2026, 3, 19),
        confirmed: true,
      );
      expect(p.days, 29);
      expect(p.contains(DateTime(2026, 2, 19)), isTrue);
      expect(p.contains(DateTime(2026, 3, 19, 23, 59)), isTrue);
      expect(p.contains(DateTime(2026, 3, 20)), isFalse);
      expect(p.contains(DateTime(2026, 2, 18, 23, 59)), isFalse);
      final back = GymSettings.fromJson(
        jsonDecode(
              jsonEncode(
                const GymSettings().copyWith(ramadanPeriods: [p]).toJson(),
              ),
            )
            as Map<String, dynamic>,
      );
      expect(back.ramadanPeriods.single.confirmed, isTrue);
    });

    test('SQLite : une base v5 reçoit le cache des horaires', () async {
      sqfliteFfiInit();
      final dir = Directory.systemTemp.createTempSync('gymflow_v5_');
      final path = p.join(dir.path, 'v5.db');
      final old = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 5,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE checkins (id TEXT PRIMARY KEY, '
              'data TEXT NOT NULL, updated_at INTEGER NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
            );
            await db.insert('checkins', {
              'id': 'ci',
              'data': '{"id":"ci","userId":"u"}',
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
      expect(await store.loadAll(Collections.checkIns), hasLength(1));
      expect(await store.loadAll(Collections.prayerTimes), isEmpty);
      final d = PrayerDay(
        id: '2026-02-18',
        maghribMinutes: 1083,
        fetchedAt: DateTime(2026, 2, 1),
      );
      await store.put(Collections.prayerTimes, d.id, d.toJson());
      expect(
        PrayerDay.fromJson(
          (await store.loadAll(Collections.prayerTimes)).single,
        ).maghribMinutes,
        1083,
      );
    });
  });

  group('Période', () {
    test(
      'seule une période confirmée active le mode ; retour automatique',
      () async {
        final b = await makeBackend();
        // Démo : Ramadan 2026 confirmé (date du Mufti, pas celle d'Aladhan).
        final demo = b.ramadan.periods.single;
        expect(demo.start, DateTime(2026, 2, 19));
        expect(demo.confirmed, isTrue);
        expect(b.ramadan.isRamadan(DateTime(2026, 2, 18, 20)), isFalse);
        expect(b.ramadan.isRamadan(DateTime(2026, 2, 19, 5)), isTrue);
        expect(b.ramadan.isActiveNow, isFalse); // 30 septembre
        await _octoberRamadan(b);
        setNow(DateTime(2026, 10, 29, 23, 30));
        expect(b.ramadan.isActiveNow, isTrue);
        setNow(DateTime(2026, 10, 30, 0, 1));
        expect(b.ramadan.isActiveNow, isFalse);
        expect(b.ramadan.openRanges(b.now()).single.$1.hour, 6);
      },
    );

    test('pré-remplissage Aladhan : proposition à confirmer', () async {
      final fake = _FakeAladhan();
      final b = await makeBackend(httpClient: fake.client);
      await loginAs(b, 'admin@gymflow.tn');
      final prop = await b.ramadan.prefill();
      expect(
        fake.requests.single.toString(),
        'https://api.aladhan.com/v1/hToGCalendar/9/1448',
      );
      expect(prop.start, DateTime(2027, 2, 8));
      expect(prop.end, DateTime(2027, 3, 8));
      expect(prop.confirmed, isFalse);
      expect(b.ramadan.upcoming?.hijriYear, 1448);
      // Non confirmée : le mode Ramadan reste inactif.
      expect(b.ramadan.isRamadan(DateTime(2027, 2, 10)), isFalse);
      // L'admin corrige d'un jour (annonce officielle) puis confirme.
      final ok = await b.ramadan.confirm(
        hijriYear: 1448,
        start: DateTime(2027, 2, 9),
        end: DateTime(2027, 3, 9),
      );
      expect(ok.source, contains('corrigées'));
      expect(b.ramadan.isRamadan(DateTime(2027, 2, 10)), isTrue);
      expect(b.ramadan.isRamadan(DateTime(2027, 2, 8, 12)), isFalse);
    });

    test('hors ligne, durée invalide, droits : refus', () async {
      final fake = _FakeAladhan()..offline = true;
      final b = await makeBackend(httpClient: fake.client);
      await loginAs(b, 'admin@gymflow.tn');
      await expectLater(
        b.ramadan.prefill(),
        throwsA(
          isA<NetworkException>().having(
            (e) => e.message,
            'm',
            contains('saisissez les dates'),
          ),
        ),
      );
      await expectLater(
        b.ramadan.confirm(
          hijriYear: 1448,
          start: DateTime(2027, 2, 8),
          end: DateTime(2027, 2, 20),
        ),
        throwsA(isA<ValidationException>()),
      );
      await b.auth.logout();
      await loginAs(b, 'amira@gymflow.tn');
      await expectLater(
        b.ramadan.confirm(
          hijriYear: 1448,
          start: DateTime(2027, 2, 8),
          end: DateTime(2027, 3, 8),
        ),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(Routes.rolesFor(Routes.ramadanAdmin), {UserRole.superAdmin});
      expect(Routes.rolesFor(Routes.ramadanPreview), {UserRole.superAdmin});
    });
  });

  group('Horaires et Maghrib', () {
    test('API : « 18:03 (CET) » lu, mis en cache, pas redemandé', () async {
      final fake = _FakeAladhan();
      final b = await makeBackend(httpClient: fake.client);
      await b.aladhan.ensure(DateTime(2026, 2, 17), DateTime(2026, 2, 18));
      expect(
        fake.requests.single.toString(),
        'https://api.aladhan.com/v1/calendarByCity/2026/2'
        '?city=Tunis&country=Tunisia&method=18',
      );
      final (m, src) = b.aladhan.maghrib(DateTime(2026, 2, 18));
      expect(m, DateTime(2026, 2, 18, 18, 3));
      expect(src, MaghribSource.api);
      // Le mois est en cache : aucune nouvelle requête.
      fake.offline = true;
      await b.aladhan.ensure(DateTime(2026, 2, 17), DateTime(2026, 2, 18));
      expect(fake.requests, hasLength(1));
      expect(b.aladhan.maghrib(DateTime(2026, 2, 17)).$1.minute, 2);
    });

    test('hors ligne sans cache : estimation proche de l\'API', () async {
      final fake = _FakeAladhan()..offline = true;
      final b = await makeBackend(httpClient: fake.client);
      expect(await b.aladhan.fetchMonth(2026, 2), 0);
      final (m, src) = b.aladhan.maghrib(DateTime(2026, 2, 18));
      expect(src, MaghribSource.estimate);
      // Aladhan : 18:03 ce jour-là.
      final api = DateTime(2026, 2, 18, 18, 3);
      expect(m.difference(api).inMinutes.abs(), lessThanOrEqualTo(5));
      expect(AladhanApi.parseTime('17:45 (CET)'), 17 * 60 + 45);
      expect(AladhanApi.parseTime('25:99'), isNull);
      expect(AladhanApi.parseDate('08-02-2027'), DateTime(2027, 2, 8));
      expect(AladhanApi.parseDate('2027-02-08'), isNull);
      expect(AladhanApi.hijriYearOf(DateTime(2026, 2, 1)), 1447);
      expect(AladhanApi.hijriYearOf(DateTime(2026, 11, 12)), 1448);
    });

    test(
      'réponse inattendue : rien en cache, repli sur l\'estimation',
      () async {
        final b = await makeBackend(
          httpClient: MockClient((_) async => http.Response('<html>', 200)),
        );
        expect(await b.aladhan.fetchMonth(2026, 2), 0);
        expect(b.prayerTimes.isEmpty, isTrue);
        expect(
          b.aladhan.maghrib(DateTime(2026, 2, 18)).$2,
          MaghribSource.estimate,
        );
      },
    );

    test('horaires du Ramadan : journée et soir après la rupture', () async {
      final b = await makeBackend();
      await _octoberRamadan(b);
      final day = DateTime(2026, 10, 1);
      final (m, _) = b.ramadan.maghrib(day);
      final r = b.ramadan.openRanges(day);
      expect(r, hasLength(2));
      expect(r[0], (DateTime(2026, 10, 1, 9), DateTime(2026, 10, 1, 15)));
      expect(r[1].$1, m.add(const Duration(minutes: 30)));
      expect(r[1].$2, DateTime(2026, 10, 2));
      final slots = b.ramadan.slots(day);
      expect(slots.first.$1, 'Après la rupture du jeûne');
      expect(
        slots.first.$2.isAfter(m.add(const Duration(minutes: 74))),
        isTrue,
      );
      expect(slots.first.$2.minute % 15, 0);
      expect(slots.last.$2, DateTime(2026, 10, 1, 22));
      // Jour normal : une seule plage.
      expect(b.ramadan.openRanges(DateTime(2026, 11, 2)), [
        (DateTime(2026, 11, 2, 6), DateTime(2026, 11, 2, 22)),
      ]);
    });

    test('intensité réduite pour les cours en journée', () async {
      final b = await makeBackend();
      expect(b.ramadan.reducedIntensity(b.courses.byId('c_s6')!), isFalse);
      await _octoberRamadan(b);
      expect(b.ramadan.reducedIntensity(b.courses.byId('c_s6')!), isTrue);
      expect(b.ramadan.reducedIntensity(b.courses.byId('c_s5')!), isFalse);
    });
  });

  group('Conflits', () {
    test('signalés avec un décalage proposé, rien n\'est modifié', () async {
      final b = await makeBackend();
      await _octoberRamadan(b);
      final before = jsonEncode([for (final c in b.courses.all) c.toJson()]);
      final notifs = b.notificationsRepo.count;
      final list = b.ramadan.conflicts(b.ramadan.upcoming!);
      final byId = {for (final c in list) c.course.id: c};
      final yoga = byId['c_s1']!;
      expect(yoga.reasons, hasLength(2));
      expect(yoga.reasons.join(), contains('rupture du jeûne'));
      expect(yoga.reasons.join(), contains('Hors des horaires'));
      expect(yoga.proposal, isNotNull);
      expect(b.ramadan.reasonsFor(yoga.course, at: yoga.proposal), isEmpty);
      final hiit = byId['c_s2']!;
      expect(hiit.reasons.single, contains('Effort intense'));
      expect(byId.containsKey('c_s6'), isFalse); // Pilates 10 h : ouvert
      expect(byId.containsKey('c_s5'), isFalse); // Zumba 19 h : après l'iftar
      // Aucune modification ni notification sans validation.
      expect(jsonEncode([for (final c in b.courses.all) c.toJson()]), before);
      expect(b.notificationsRepo.count, notifs);
    });

    test('décalage validé par l\'admin : inscrits prévenus', () async {
      final b = await makeBackend();
      await _octoberRamadan(b);
      final c = b.ramadan
          .conflicts(b.ramadan.upcoming!)
          .firstWhere((x) => x.course.id == 'c_s1');
      // Horaire refusé s'il pose encore problème.
      await expectLater(
        b.ramadan.applyShift('c_s1', DateTime(2026, 10, 1, 18, 15)),
        throwsA(isA<BusinessRuleException>()),
      );
      final moved = await b.ramadan.applyShift('c_s1', c.proposal!);
      expect(moved.startAt, c.proposal);
      for (final uid in ['u_leila', 'u_ines']) {
        expect(
          b.notificationsRepo.all.any(
            (n) => n.userId == uid && n.title.contains('Horaire modifié'),
          ),
          isTrue,
        );
      }
      expect(
        b.auditRepo.all.any((a) => a.action == 'Ramadan : cours décalé'),
        isTrue,
      );
      expect(
        b.ramadan
            .conflicts(b.ramadan.upcoming!)
            .any((x) => x.course.id == 'c_s1'),
        isFalse,
      );
    });

    test('garder l\'horaire ; un coach ne peut ni décaler ni garder', () async {
      final b = await makeBackend();
      await _octoberRamadan(b);
      await b.ramadan.keep('c_s2');
      expect(
        b.ramadan
            .conflicts(b.ramadan.upcoming!)
            .any((x) => x.course.id == 'c_s2'),
        isFalse,
      );
      await b.auth.logout();
      await loginAs(b, 'sarra@gymflow.tn');
      await expectLater(
        b.ramadan.applyShift('c_s1', DateTime(2026, 10, 1, 19, 30)),
        throwsA(isA<PermissionDeniedException>()),
      );
      await expectLater(
        b.ramadan.keep('c_s1'),
        throwsA(isA<PermissionDeniedException>()),
      );
    });
  });

  group('Aperçu', () {
    test('simulation sans aucune écriture', () async {
      final b = await makeBackend();
      await loginAs(b, 'admin@gymflow.tn');
      final settings = jsonEncode(b.packs.settings.toJson());
      final courses = jsonEncode([for (final c in b.courses.all) c.toJson()]);
      final notifs = b.notificationsRepo.count;
      b.ramadan.previewActive = true;
      final period = b.ramadan.previewPeriod();
      expect(period.start, DateTime(2026, 9, 30));
      expect(period.days, 30);
      final conflicts = b.ramadan.previewConflicts();
      expect(conflicts.map((c) => c.course.id), containsAll(['c_s1', 'c_s2']));
      await expectLater(
        b.ramadan.applyShift('c_s1', conflicts.first.proposal!),
        throwsA(
          isA<BusinessRuleException>().having(
            (e) => e.message,
            'm',
            contains('Aperçu'),
          ),
        ),
      );
      await expectLater(
        b.ramadan.keep('c_s2'),
        throwsA(isA<BusinessRuleException>()),
      );
      await expectLater(
        b.ramadan.confirm(
          hijriYear: 1448,
          start: DateTime(2027, 2, 8),
          end: DateTime(2027, 3, 8),
        ),
        throwsA(isA<BusinessRuleException>()),
      );
      expect(jsonEncode(b.packs.settings.toJson()), settings);
      expect(jsonEncode([for (final c in b.courses.all) c.toJson()]), courses);
      expect(b.notificationsRepo.count, notifs);
      expect(b.ramadan.isActiveNow, isFalse);
      b.ramadan.previewActive = false;
      await b.ramadan.keep('c_s2').catchError((_) {});
    });
  });

  group('Affluence', () {
    test('profil Ramadan séparé du profil normal', () async {
      final b = await makeBackend();
      final ram = b.affluence.profileDays(ramadan: true);
      expect(ram, hasLength(29));
      expect(ram.every((d) => b.ramadan.isRamadan(d)), isTrue);
      final normal = b.affluence.profileDays(ramadan: false);
      expect(normal.any((d) => b.ramadan.isRamadan(d)), isFalse);
      final m = b.affluence.heatmap(ramadan: true);
      // Pendant le Ramadan : creux avant la rupture, pic après.
      expect(
        m.at(DateTime.monday, 20),
        greaterThan(m.at(DateTime.monday, 17) + 5),
      );
      expect(m.closeHour, 24);
      final n = b.affluence.heatmap();
      expect(n.closeHour, 22);
      expect(n.at(DateTime.monday, 19), greaterThan(n.at(DateTime.monday, 21)));
    });

    test('pendant le Ramadan : prévision et conseils adaptés', () async {
      final b = await makeBackend();
      await _octoberRamadan(b);
      // Lundi 5/10 à 20 h (Ramadan) : profil Ramadan + réservation de la
      // boxe de 19 h 30.
      final f = b.affluence.forecast(DateTime(2026, 10, 5, 20));
      final ramMap = b.affluence.heatmap(ramadan: true);
      expect(f.booked, 1);
      expect(
        f.expected,
        closeTo(
          ramMap.freeAt(DateTime.monday, 20) +
              math.max(ramMap.courseAt(DateTime.monday, 20), 1),
          1e-9,
        ),
      );
      // 17 h un lundi : du monde en temps normal, personne avant la
      // rupture du jeûne pendant le Ramadan.
      expect(b.affluence.heatmap().at(DateTime.monday, 17), greaterThan(1));
      expect(b.affluence.forecast(DateTime(2026, 10, 5, 17)).expected, 0);
      for (final s in b.affluence.suggestions('u_leila')) {
        expect(
          b.ramadan.fits(
                s.forecast.start,
                s.forecast.start.add(const Duration(hours: 1)),
              ) ||
              s.courseId != null,
          isTrue,
        );
      }
    });
  });

  group('Écrans', () {
    testWidgets('admin : conflits puis décalage validé', (tester) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'admin@gymflow.tn',
      );
      await b.ramadan.confirm(
        hijriYear: 1999,
        start: DateTime(2026, 10, 1),
        end: DateTime(2026, 10, 29),
      );
      await go(tester, Routes.ramadanAdmin);
      expect(find.byKey(const Key('ramadan_next')), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('shift_c_s1')));
      await tester.tap(find.text('Décaler').last);
      await settle(tester);
      expect(find.byKey(const Key('conflict_c_s1')), findsNothing);
      expect(b.courses.byId('c_s1')!.startAt!.hour, greaterThanOrEqualTo(19));
      expect(tester.takeException(), isNull);
    });

    testWidgets('aperçu : bandeau visible, sortie en un clic', (tester) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'admin@gymflow.tn',
      );
      final notifs = b.notificationsRepo.count;
      await go(tester, Routes.ramadanPreview);
      expect(b.ramadan.previewActive, isTrue);
      expect(find.byKey(const Key('preview_banner')), findsOneWidget);
      expect(find.textContaining('Rien n\'est enregistré'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('preview_day_1')));
      // Le bandeau reste visible après défilement.
      await tester.drag(mainScrollable(tester), const Offset(0, -600));
      await settle(tester);
      expect(
        find.byKey(const Key('preview_banner')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('preview_exit')));
      await settle(tester);
      expect(b.ramadan.previewActive, isFalse);
      expect(find.byKey(const Key('preview_banner')), findsNothing);
      expect(b.notificationsRepo.count, notifs);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fiche d\'un cours en journée : intensité réduite', (
      tester,
    ) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'admin@gymflow.tn',
      );
      await b.ramadan.confirm(
        hijriYear: 1999,
        start: DateTime(2026, 10, 1),
        end: DateTime(2026, 10, 29),
      );
      await go(tester, Routes.courseDetail, 'c_s6');
      expect(find.byKey(const Key('ramadan_intensity')), findsOneWidget);
      await go(tester, Routes.courseDetail, 'c_s5');
      expect(find.byKey(const Key('ramadan_intensity')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
