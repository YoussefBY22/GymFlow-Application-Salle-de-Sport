import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/models/session_log.dart';
import 'package:gymflow/core/config.dart';
import 'package:gymflow/screens/shell/main_shell.dart';
import 'package:gymflow/services/training_progress_ai_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'widget_helpers.dart';

void main() {
  final now = DateTime(2026, 10, 30, 12);

  SessionLog session({
    required String id,
    required DateTime date,
    required double load,
    int reps = 8,
    int prCount = 0,
  }) => SessionLog(
    id: id,
    userId: 'private-user-id',
    workoutId: 'private-workout-id',
    title: 'Private workout title',
    startedAt: date,
    durationSec: 2700,
    sets: [
      SetLog(
        exerciseId: 'exercise-1',
        exerciseName: 'Développé couché',
        setIndex: 1,
        reps: reps,
        loadKg: load,
      ),
    ],
    prCount: prCount,
  );

  group('Bilan IA de progression', () {
    testWidgets('nouvel onglet affiche le besoin de séances et de clés', (
      tester,
    ) async {
      await pumpApp(tester, route: Routes.home, loginEmail: 'nour@gymflow.tn');
      MainShell.tab.value = 1;
      await settle(tester);
      await tester.tap(find.byTooltip('Outils avancés d’entraînement'));
      await settle(tester);
      final tab = find.text('Bilan IA');
      await tester.ensureVisible(tab);
      await tester.tap(tab);
      await settle(tester);

      expect(find.byKey(const Key('training_ai_progress')), findsOneWidget);
      expect(find.text('Pas encore de séance récente'), findsOneWidget);
      expect(find.text('Générer mon bilan IA'), findsOneWidget);
    });

    test(
      'compare séances récentes et précédentes sans inclure les futures',
      () {
        final summary = TrainingProgressSummary.fromSessions([
          session(
            id: 'recent-1',
            date: now.subtract(const Duration(days: 3)),
            load: 60,
            prCount: 1,
          ),
          session(
            id: 'recent-2',
            date: now.subtract(const Duration(days: 14)),
            load: 55,
          ),
          session(
            id: 'previous',
            date: now.subtract(const Duration(days: 40)),
            load: 50,
            prCount: 1,
          ),
          session(
            id: 'future',
            date: now.add(const Duration(days: 1)),
            load: 90,
          ),
        ], now);

        expect(summary.recentSessions, 2);
        expect(summary.previousSessions, 1);
        expect(summary.recentMinutes, 90);
        expect(summary.previousMinutes, 45);
        expect(summary.recentVolumeKg, 920);
        expect(summary.previousVolumeKg, 400);
        expect(summary.recentPersonalRecords, 1);
        expect(summary.exerciseProgress.single.bestLoadKg, 60);
        expect(
          summary.exerciseProgress.single.previousOneRmKg,
          closeTo(63.33, 0.01),
        );
        expect(summary.toJson(), containsPair('period_days', 28));
      },
    );

    test(
      'envoie uniquement les métriques et objectif au service Groq',
      () async {
        http.Request? request;
        final service = TrainingProgressAiService(
          groqApiKey: 'groq-test-key',
          apiNinjasKey: '',
          client: MockClient((r) async {
            request = r;
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'Votre régularité progresse.'},
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
        final summary = TrainingProgressSummary.fromSessions([
          session(
            id: 'recent',
            date: now.subtract(const Duration(days: 2)),
            load: 60,
          ),
        ], now);

        final report = await service.createProgressReport(
          summary: summary,
          goal: 'Force',
        );
        final payload = jsonDecode(request!.body) as Map<String, dynamic>;
        final messages = payload['messages'] as List;

        expect(request!.url.host, 'api.groq.com');
        expect(payload['model'], AppConfig.groqModel);
        expect(request!.headers['authorization'], 'Bearer groq-test-key');
        expect(messages.last['content'], contains('"goal":"Force"'));
        expect(messages.last['content'], isNot(contains('private-user-id')));
        expect(report, 'Votre régularité progresse.');
        service.dispose();
      },
    );

    test(
      'API Ninjas reçoit uniquement le muscle et renvoie des exercices',
      () async {
        http.Request? request;
        final service = TrainingProgressAiService(
          groqApiKey: '',
          apiNinjasKey: 'ninjas-test-key',
          client: MockClient((r) async {
            request = r;
            return http.Response(
              jsonEncode([
                {
                  'name': 'Dumbbell Bench Press',
                  'muscle': 'chest',
                  'equipment': 'dumbbell',
                  'difficulty': 'beginner',
                  'instructions': 'Press the dumbbells upward.',
                },
              ]),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );

        final exercises = await service.suggestExercises(Muscle.chest);

        expect(request!.url.host, 'api.api-ninjas.com');
        expect(request!.url.queryParameters['muscle'], 'chest');
        expect(request!.headers['X-Api-Key'], 'ninjas-test-key');
        expect(exercises.single.name, 'Dumbbell Bench Press');
        service.dispose();
      },
    );

    test('erreur Groq explicite si la clé manque', () async {
      final service = TrainingProgressAiService(
        groqApiKey: '',
        apiNinjasKey: '',
        client: MockClient((_) async => http.Response('', 500)),
      );
      final summary = TrainingProgressSummary.fromSessions([
        session(
          id: 'recent',
          date: now.subtract(const Duration(days: 2)),
          load: 60,
        ),
      ], now);

      await expectLater(
        service.createProgressReport(summary: summary, goal: 'Force'),
        throwsA(
          isA<TrainingProgressApiException>().having(
            (error) => error.message,
            'message',
            contains('indisponible'),
          ),
        ),
      );
      service.dispose();
    });
  });
}
