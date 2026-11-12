import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/core/legal.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/course.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/models/risk.dart';
import 'package:gymflow/models/session_log.dart';
import 'package:gymflow/models/session_pack.dart';
import 'package:gymflow/models/user.dart';
import 'package:gymflow/repositories/data_store.dart';
import 'package:gymflow/repositories/sqlite_data_store.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/churn_risk_service.dart';
import 'package:gymflow/services/gemini_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

/// Risque d'abandon (étape 2). Horloge : mercredi 30 septembre 2026, 10 h.
DateTime _ago(int days, [int hour = 18]) => DateTime(2026, 9, 30 - days, hour);

var _n = 0;

/// Abonné de test isolé (aucune donnée de démo).
Future<AppUser> _member(
  Backend b, {
  int createdDaysAgo = 200,
  int? subEndsInDays = 60,
}) => b.users.save(
  AppUser(
    id: 'u_t${_n++}',
    email: 't$_n@test.tn',
    fullName: 'Test Risque',
    role: UserRole.member,
    goal: Goal.endurance,
    createdAt: _ago(createdDaysAgo, 9),
    subscription: subEndsInDays == null
        ? Subscription.none
        : Subscription(
            type: SubscriptionType.monthly,
            start: _ago(10),
            end: DateTime(2026, 9, 30 + subEndsInDays),
          ),
  ),
);

/// Cours passé (coach Amira) et réservation de l'abonné.
Future<Reservation> _book(
  Backend b,
  String userId,
  DateTime at, {
  bool? attended = true,
  int? rating,
  ReservationStatus status = ReservationStatus.confirmed,
  DateTime? cancelledAt,
}) async {
  final c = await b.courses.save(
    Course(
      id: 'c_t${_n++}',
      title: 'Cours test',
      description: '',
      category: CourseCategory.yoga,
      level: Level.beginner,
      coachId: 'u_amira',
      room: 'Studio Zen',
      capacity: 20,
      durationMin: 60,
      createdAt: at.subtract(const Duration(days: 30)),
      startAt: at,
    ),
  );
  return b.reservations.save(
    Reservation(
      id: 'r_t${_n++}',
      courseId: c.id,
      userId: userId,
      status: status,
      createdAt: at.subtract(const Duration(days: 2)),
      attended: status == ReservationStatus.confirmed ? attended : null,
      rating: rating,
      cancelledAt: cancelledAt,
    ),
  );
}

/// Venues régulières : [perWeek] par semaine entre [fromDays] et [toDays]
/// jours avant aujourd'hui.
Future<void> _regular(
  Backend b,
  String userId,
  int fromDays,
  int toDays, {
  int perWeek = 2,
}) async {
  for (var d = fromDays; d > toDays; d -= 7) {
    for (var k = 0; k < perWeek; k++) {
      final day = d - 1 - k * 3;
      if (day > toDays) await _book(b, userId, _ago(day));
    }
  }
}

/// Séance enregistrée dans l'application (salle ou domicile).
Future<void> _session(Backend b, String userId, DateTime at) => b.sessions.save(
  SessionLog(
    id: 's_t${_n++}',
    userId: userId,
    workoutId: null,
    title: 'Séance libre',
    startedAt: at,
    durationSec: 2400,
    sets: const [],
  ),
);

double _pts(RiskAssessment a, String key) =>
    a.factors.firstWhere((f) => f.key == key).points;

void main() {
  group('Facteurs (chacun isolément)', () {
    test('baisse de fréquentation', () async {
      final b = await makeBackend(seed: false);
      final stopped = await _member(b);
      await _regular(b, stopped.id, 77, 21); // 2 par semaine, puis rien
      expect(_pts(b.churnRisk.compute(stopped), 'drop'), 25);
      final steady = await _member(b);
      await _regular(b, steady.id, 77, 0);
      expect(_pts(b.churnRisk.compute(steady), 'drop'), 0);
      final half = await _member(b);
      await _regular(b, half.id, 77, 21);
      await _regular(b, half.id, 21, 0, perWeek: 1); // -50 %
      expect(_pts(b.churnRisk.compute(half), 'drop'), closeTo(20, 0.01));
      // Historique trop court : pas de mesure.
      final fresh = await _member(b, createdDaysAgo: 30);
      expect(_pts(b.churnRisk.compute(fresh), 'drop'), 0);
    });

    test('jours depuis la dernière venue', () async {
      final b = await makeBackend(seed: false);
      Future<double> after(int days) async {
        final u = await _member(b);
        await _book(b, u.id, _ago(days, 9));
        return _pts(b.churnRisk.compute(u), 'absence');
      }

      expect(await after(7), 0);
      expect(await after(30), 25);
      expect(await after(40), 25);
      expect(await after(18), closeTo(25 * 11 / 23, 0.01));
    });

    test('annulations tardives et absences en hausse', () async {
      final b = await makeBackend(seed: false);
      final u = await _member(b);
      await _book(b, u.id, _ago(5), attended: false);
      await _book(
        b,
        u.id,
        _ago(10),
        status: ReservationStatus.cancelled,
        cancelledAt: _ago(10, 15), // 3 h avant : tardive
      );
      expect(_pts(b.churnRisk.compute(u), 'reliability'), 15);

      final v = await _member(b);
      await _book(b, v.id, _ago(3));
      await _book(b, v.id, _ago(6));
      await _book(b, v.id, _ago(9));
      await _book(b, v.id, _ago(12), attended: false); // 25 %
      // Annulation tôt et cours annulé par la salle : non comptés.
      await _book(
        b,
        v.id,
        _ago(14),
        status: ReservationStatus.cancelled,
        cancelledAt: _ago(16),
      );
      await _book(b, v.id, _ago(15), status: ReservationStatus.cancelled);
      expect(
        _pts(b.churnRisk.compute(v), 'reliability'),
        closeTo(15 * 0.25 / 0.40, 0.01),
      );
      // Moins de 2 réservations récentes : pas de conclusion.
      final w = await _member(b);
      await _book(b, w.id, _ago(3), attended: false);
      expect(_pts(b.churnRisk.compute(w), 'reliability'), 0);
    });

    test('fin d\'abonnement ou de carnet sans renouvellement', () async {
      final b = await makeBackend(seed: false);
      expect(
        _pts(
          b.churnRisk.compute(await _member(b, subEndsInDays: 30)),
          'expiry',
        ),
        0,
      );
      expect(
        _pts(b.churnRisk.compute(await _member(b, subEndsInDays: 3)), 'expiry'),
        15,
      );
      final none = await _member(b, subEndsInDays: null);
      expect(_pts(b.churnRisk.compute(none), 'expiry'), 15);
      // Un carnet valable 40 jours prolonge la couverture.
      final renewed = await _member(b, subEndsInDays: 3);
      await b.sessionPacks.save(
        SessionPack(
          id: 'pk_renew',
          userId: renewed.id,
          offerId: 'po_10',
          name: 'Carnet 10 séances',
          kind: PackKind.credits,
          quota: 10,
          purchasedAt: _ago(1),
          expiresAt: DateTime(2026, 11, 9),
        ),
      );
      expect(_pts(b.churnRisk.compute(renewed), 'expiry'), 0);
    });

    test('notes de cours en baisse', () async {
      final b = await makeBackend(seed: false);
      final u = await _member(b);
      await _book(b, u.id, _ago(50), rating: 5);
      await _book(b, u.id, _ago(40), rating: 5);
      await _book(b, u.id, _ago(5), rating: 3);
      expect(_pts(b.churnRisk.compute(u), 'ratings'), 10);
      final few = await _member(b);
      await _book(b, few.id, _ago(50), rating: 5);
      await _book(b, few.id, _ago(5), rating: 1);
      expect(_pts(b.churnRisk.compute(few), 'ratings'), 0);
    });

    test('une séance enregistrée n\'est pas une venue à la salle', () async {
      final b = await makeBackend(seed: false);
      final u = await _member(b);
      await _session(b, u.id, _ago(1, 9));
      expect(b.churnRisk.visitTimes(u.id), isEmpty);
      final a = b.churnRisk.compute(u);
      expect(a.lastVisit, isNull);
      expect(a.weeklyVisits.every((v) => v == 0), isTrue);
      await _book(b, u.id, _ago(2));
      expect(b.churnRisk.visitTimes(u.id), hasLength(1));
    });

    test('activité à domicile : facteur protecteur', () async {
      final b = await makeBackend(seed: false);
      final none = await _member(b);
      expect(_pts(b.churnRisk.compute(none), 'home'), 0);
      // 6 jours de séance en 3 semaines (2 par semaine) : -10 points.
      final active = await _member(b);
      for (final d in [1, 4, 8, 11, 15, 18]) {
        await _session(b, active.id, _ago(d, 7));
      }
      final a = b.churnRisk.compute(active);
      expect(_pts(a, 'home'), -10);
      expect(a.factors.firstWhere((f) => f.key == 'home').weight, -10);
      // 3 jours : -5 points ; une séance le jour d'un cours pointé ne
      // compte pas (elle a eu lieu à la salle).
      final half = await _member(b);
      for (final d in [2, 9, 16]) {
        await _session(b, half.id, _ago(d, 7));
      }
      await _session(b, half.id, _ago(5, 19));
      await _book(b, half.id, _ago(5));
      expect(_pts(b.churnRisk.compute(half), 'home'), closeTo(-5, 0.01));
      // Séances anciennes (plus de 3 semaines) : sans effet.
      final old = await _member(b);
      await _session(b, old.id, _ago(30, 7));
      expect(_pts(b.churnRisk.compute(old), 'home'), 0);
    });

    test('le facteur protecteur baisse le score, sans passer sous 0', () async {
      final b = await makeBackend(seed: false);
      Future<AppUser> drifting() async {
        final u = await _member(b, subEndsInDays: 5);
        await _regular(b, u.id, 77, 21);
        return u;
      }

      final gymOnly = await drifting();
      final atHome = await drifting();
      for (final d in [1, 4, 8, 11, 15, 18]) {
        await _session(b, atHome.id, _ago(d, 7));
      }
      final s1 = b.churnRisk.compute(gymOnly).score;
      final s2 = b.churnRisk.compute(atHome).score;
      expect(s2, s1 - 10);
      final calm = await _member(b);
      for (final d in [1, 4, 8, 11, 15, 18]) {
        await _session(b, calm.id, _ago(d, 7));
      }
      await _book(b, calm.id, _ago(1));
      expect(b.churnRisk.compute(calm).score, 0);
    });

    test('nouvel abonné peu actif', () async {
      final b = await makeBackend(seed: false);
      final idle = await _member(b, createdDaysAgo: 14);
      expect(_pts(b.churnRisk.compute(idle), 'newcomer'), 10);
      final active = await _member(b, createdDaysAgo: 14);
      for (final d in [1, 4, 8, 11]) {
        await _book(b, active.id, _ago(d));
      }
      expect(_pts(b.churnRisk.compute(active), 'newcomer'), 0);
      final old = await _member(b, createdDaysAgo: 40);
      expect(_pts(b.churnRisk.compute(old), 'newcomer'), 0);
    });
  });

  group('Score et niveaux', () {
    test('poids : total de 100, interpolation bornée', () {
      expect(
        ChurnRiskService.weightDrop +
            ChurnRiskService.weightAbsence +
            ChurnRiskService.weightReliability +
            ChurnRiskService.weightExpiry +
            ChurnRiskService.weightRatings +
            ChurnRiskService.weightNewcomer,
        100,
      );
      // Facteur protecteur, retranché du score.
      expect(ChurnRiskService.weightHomeActivity, 10);
      expect(ChurnRiskService.ramp(0.05, 0.1, 0.6), 0);
      expect(ChurnRiskService.ramp(0.35, 0.1, 0.6), closeTo(0.5, 1e-9));
      expect(ChurnRiskService.ramp(2, 0.1, 0.6), 1);
    });

    test('niveaux : faible < 35 ≤ moyen < 60 ≤ élevé', () {
      expect(ChurnRiskService.levelOf(0), RiskLevel.low);
      expect(ChurnRiskService.levelOf(34), RiskLevel.low);
      expect(ChurnRiskService.levelOf(35), RiskLevel.medium);
      expect(ChurnRiskService.levelOf(59), RiskLevel.medium);
      expect(ChurnRiskService.levelOf(60), RiskLevel.high);
      expect(RiskLevel.low.suggested, RiskActionKind.message);
      expect(RiskLevel.medium.suggested, RiskActionKind.trial);
      expect(RiskLevel.high.suggested, RiskActionKind.call);
    });

    test('score total = somme arrondie des contributions', () async {
      final b = await makeBackend(seed: false);
      final u = await _member(b, subEndsInDays: 3);
      await _regular(b, u.id, 77, 21);
      await _book(b, u.id, _ago(5), attended: false);
      await _book(b, u.id, _ago(8), attended: false);
      final a = b.churnRisk.compute(u);
      final sum = a.factors.fold<double>(0, (s, f) => s + f.points);
      expect(a.score, sum.round());
      expect(a.level, RiskLevel.high);
      expect(a.weeklyVisits, hasLength(11));
      expect(a.active.first.points, greaterThanOrEqualTo(a.active.last.points));
    });

    test('démo : Yassine élevé, Mariem moyen, Leila faible', () async {
      final b = await makeBackend();
      Future<RiskAssessment> of(String id) async =>
          b.churnRisk.compute(b.users.byId(id)!);
      expect((await of('u_yassine')).level, RiskLevel.high);
      expect((await of('u_mariem')).level, RiskLevel.medium);
      expect((await of('u_leila')).level, RiskLevel.low);
    });

    test(
      'abonné revenu : le score baisse et l\'action est « revenu »',
      () async {
        final b = await makeBackend();
        // Même journée : seule la venue change (les fenêtres de calcul
        // ne glissent pas entre les deux mesures).
        setNow(DateTime(2026, 10, 3, 9));
        final before = b.churnRisk.compute(b.users.byId('u_yassine')!);
        await loginAs(b, 'sarra@gymflow.tn');
        final call = await b.churnRisk.logCall(
          'u_yassine',
          'Rappel : il revient cette semaine.',
        );
        expect(b.churnRisk.outcomeOf(call), RiskOutcome.pending);
        setNow(DateTime(2026, 10, 3, 12));
        await _book(b, 'u_yassine', DateTime(2026, 10, 3, 10));
        final after = b.churnRisk.compute(b.users.byId('u_yassine')!);
        expect(_pts(before, 'absence'), greaterThan(0));
        expect(_pts(after, 'absence'), 0);
        expect(after.score, lessThan(before.score));
        expect(b.churnRisk.outcomeOf(call), RiskOutcome.returned);
      },
    );
  });

  group('Droits d\'accès', () {
    test('jamais visible par un abonné', () async {
      final b = await makeBackend();
      await loginAs(b, 'yassine@gymflow.tn');
      expect(
        () => b.churnRisk.ranking(),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(
        () => b.churnRisk.assess('u_yassine'),
        throwsA(isA<PermissionDeniedException>()),
      );
      await expectLater(
        b.churnRisk.sendMessage('u_leila', 'Bonjour, revenez nous voir !'),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(Routes.rolesFor(Routes.risk), isNot(contains(UserRole.member)));
      expect(
        Routes.rolesFor(Routes.riskMember),
        isNot(contains(UserRole.member)),
      );
    });

    test('coach : seulement les abonnés de ses cours ; admin : tous', () async {
      final b = await makeBackend();
      await loginAs(b, 'mehdi@gymflow.tn');
      final mehdi = b.churnRisk.ranking().map((a) => a.userId).toSet();
      expect(mehdi, contains('u_ahmed'));
      expect(mehdi, isNot(contains('u_mariem')));
      expect(
        () => b.churnRisk.assess('u_mariem'),
        throwsA(isA<PermissionDeniedException>()),
      );
      await b.auth.logout();
      await loginAs(b, 'amira@gymflow.tn');
      expect(b.churnRisk.assess('u_mariem').level, RiskLevel.medium);
      await b.auth.logout();
      await loginAs(b, 'admin@gymflow.tn');
      final all = b.churnRisk.ranking();
      // Tous les abonnés actifs (Walid, désactivé, est exclu).
      expect(
        all,
        hasLength(b.users.where((u) => u.isMember && u.active).length),
      );
      expect(all.any((a) => a.userId == 'u_walid'), isFalse);
      expect(all.first.userId, 'u_yassine'); // trié par score
      for (var i = 1; i < all.length; i++) {
        expect(all[i - 1].score, greaterThanOrEqualTo(all[i].score));
      }
    });
  });

  group('Actions et suivi', () {
    test('message : notification à l\'abonné et action enregistrée', () async {
      final b = await makeBackend();
      await loginAs(b, 'amira@gymflow.tn');
      await expectLater(
        b.churnRisk.sendMessage('u_mariem', 'Court'),
        throwsA(isA<ValidationException>()),
      );
      final a = await b.churnRisk.sendMessage(
        'u_mariem',
        'Bonjour Mariem, le Pilates du samedi vous attend !',
      );
      expect(a.kind, RiskActionKind.message);
      expect(a.level, RiskLevel.medium);
      expect(a.factors, hasLength(7));
      expect(a.emailSent, isFalse); // EmailJS non configuré dans les tests
      final n = b.notificationsRepo.where(
        (n) => n.userId == 'u_mariem' && n.type == NotificationType.coach,
      );
      expect(n.single.title, 'Message de Amira');
      expect(
        b.auditRepo.all.any((x) => x.action.startsWith('Accompagnement')),
        isTrue,
      );
    });

    test('séance d\'essai : carnet offert, une fois par 30 jours', () async {
      final b = await makeBackend();
      await loginAs(b, 'amira@gymflow.tn');
      final a = await b.churnRisk.offerTrial('u_mariem');
      final pack = b.sessionPacks.byId(a.packId)!;
      expect(pack.userId, 'u_mariem');
      expect(pack.remaining, 1);
      expect(pack.price, 0);
      await expectLater(
        b.churnRisk.offerTrial('u_mariem'),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('appel : note obligatoire', () async {
      final b = await makeBackend();
      await loginAs(b, 'sarra@gymflow.tn');
      await expectLater(
        b.churnRisk.logCall('u_yassine', ''),
        throwsA(isA<ValidationException>()),
      );
      final a = await b.churnRisk.logCall('u_yassine', 'Répondeur, rappeler.');
      expect(b.churnRisk.actionsFor('u_yassine').first.id, a.id);
    });

    test('efficacité : revenus, pas revenus, en attente', () async {
      final b = await makeBackend();
      await loginAs(b, 'admin@gymflow.tn');
      final e = b.churnRisk.effectiveness();
      expect(e[RiskActionKind.message], (2, 1, 0)); // Hedi revenu, Mariem ?
      expect(e[RiskActionKind.call], (1, 0, 1)); // Yassine pas revenu
      expect(e[RiskActionKind.trial], (0, 0, 0));
    });
  });

  group('Message rédigé par l\'IA', () {
    Future<(Backend, List<http.Request>)> withAi(String reply) async {
      final b = await makeBackend();
      final sent = <http.Request>[];
      b.gemini = GeminiClient(
        MockClient((r) async {
          sent.add(r);
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': reply},
                    ],
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
        apiKey: 'cle-de-test',
      );
      await loginAs(b, 'sarra@gymflow.tn');
      return (b, sent);
    }

    test('sans clé : brouillon calculé', () async {
      final b = await makeBackend();
      await loginAs(b, 'sarra@gymflow.tn');
      final (text, ai) = await b.churnRisk.draftMessage('u_yassine');
      expect(ai, isFalse);
      expect(text, startsWith('Bonjour Yassine'));
      expect(text, contains('Perte de poids'));
    });

    test('réponse valide : utilisée ; seules 3 données envoyées', () async {
      final (b, sent) = await withAi(
        jsonEncode({
          'message':
              'Bonjour Yassine, votre place vous attend au cours de votre '
              'choix : revenez quand vous voulez, nous serons ravis de vous '
              'revoir.',
        }),
      );
      final (text, ai) = await b.churnRisk.draftMessage('u_yassine');
      expect(ai, isTrue);
      expect(text, startsWith('Bonjour Yassine'));
      final body = jsonDecode(sent.single.body) as Map<String, dynamic>;
      final user = ((body['contents'] as List).single as Map)['parts'] as List;
      final data = jsonDecode((user.single as Map)['text'] as String) as Map;
      expect(data.keys.toSet(), {'prénom', 'objectif', 'constats'});
      expect(sent.single.body, isNot(contains('yassine@gymflow.tn')));
      expect(sent.single.body, isNot(contains('Trabelsi')));
    });

    test('réponse non conforme (chiffre, mauvais prénom) : repli', () async {
      expect(
        ChurnRiskService.parseDraft(
          '{"message": "Bonjour Yassine, revenez 3 fois par semaine !"}',
          'Yassine',
        ),
        isNull,
      );
      expect(
        ChurnRiskService.parseDraft(
          '{"message": "Bonjour Karim, nous serions ravis de vous revoir."}',
          'Yassine',
        ),
        isNull,
      );
      expect(ChurnRiskService.parseDraft('pas du JSON', 'Yassine'), isNull);
      final (b, _) = await withAi('{"message": "https://pirate.example"}');
      final (text, ai) = await b.churnRisk.draftMessage('u_yassine');
      expect(ai, isFalse);
      expect(text, startsWith('Bonjour Yassine'));
    });
  });

  group('Confidentialité', () {
    test('export : score, facteurs et date ; effacement des actions', () async {
      final b = await makeBackend();
      await loginAs(b, 'yassine@gymflow.tn');
      final export = jsonDecode(b.privacy.exportMyData()) as Map;
      final r = export['indicateur_assiduite'] as Map;
      expect(r['score'], greaterThanOrEqualTo(60));
      expect(r['niveau'], 'Élevé');
      expect(r['calcule_le'], startsWith('2026-09-30'));
      expect((r['facteurs'] as List), hasLength(7));
      expect((r['actions'] as List), hasLength(1));
      await b.privacy.eraseUser(b.requireUser());
      expect(b.riskActions.where((a) => a.memberId == 'u_yassine'), isEmpty);
    });

    test('politique : indicateur expliqué, aucune décision automatique', () {
      final text = Legal.privacyPolicy.map((s) => s.$2).join(' ');
      expect(text, contains('indicateur d\'assiduité'));
      expect(text, contains('aucune décision n\'est prise'));
    });

    test('annulation par l\'abonné datée (annulations tardives)', () async {
      final b = await makeBackend();
      await loginAs(b, 'nour@gymflow.tn');
      final r = await b.reservationService.book('c_s1');
      await b.reservationService.cancel(r.id);
      expect(b.reservations.byId(r.id)!.cancelledAt, testNow);
    });
  });

  test('SQLite : une base v3 reçoit la table du suivi', () async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('gymflow_v3_');
    final path = p.join(dir.path, 'v3.db');
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE session_packs (id TEXT PRIMARY KEY, '
            'data TEXT NOT NULL, updated_at INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.insert('session_packs', {
            'id': 'pk',
            'data': '{"id":"pk"}',
            'updated_at': 0,
          });
        },
      ),
    );
    await old.close();
    final store = SqliteDataStore(fileName: path, factory: databaseFactoryFfi);
    await store.open();
    expect(await store.loadAll(Collections.sessionPacks), hasLength(1));
    expect(await store.loadAll(Collections.riskActions), isEmpty);
    final a = RiskAction(
      id: 'ra',
      memberId: 'u',
      actorId: 'c',
      kind: RiskActionKind.call,
      at: DateTime(2026, 9, 1),
      score: 70,
      level: RiskLevel.high,
    );
    await store.put(Collections.riskActions, a.id, a.toJson());
    final back = RiskAction.fromJson(
      (await store.loadAll(Collections.riskActions)).single,
    );
    expect(back.level, RiskLevel.high);
    expect(RiskAction.fromJson({'id': 'x'}).kind, RiskActionKind.message);
  });

  group('Écrans', () {
    testWidgets('liste triée, détail des facteurs et envoi d\'un message', (
      tester,
    ) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'amira@gymflow.tn',
      );
      await go(tester, Routes.risk);
      expect(find.text('Abonnés à risque'), findsWidgets);
      final y = tester.getTopLeft(find.byKey(const Key('risk_u_yassine')));
      final m = tester.getTopLeft(find.byKey(const Key('risk_u_mariem')));
      expect(y.dy, lessThan(m.dy));
      await tapVisible(tester, find.byKey(const Key('risk_u_mariem')));
      expect(find.byKey(const Key('factor_newcomer')), findsOneWidget);
      expect(find.textContaining('risque moyen'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('risk_do_message')));
      expect(find.textContaining('préparé par l\'application'), findsOneWidget);
      await tester.tap(find.byKey(const Key('send_message')));
      await settle(tester);
      expect(
        b.notificationsRepo.all.any(
          (n) => n.userId == 'u_mariem' && n.type == NotificationType.coach,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('un abonné ne peut pas ouvrir l\'écran', (tester) async {
      await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'yassine@gymflow.tn',
      );
      await go(tester, Routes.risk);
      expect(find.text('Accès réservé'), findsOneWidget);
      expect(find.byKey(const Key('risk_u_yassine')), findsNothing);
    });
  });
}
