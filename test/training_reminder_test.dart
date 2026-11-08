import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/models/session_log.dart';
import 'package:gymflow/models/user.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/training_log_service.dart';
import 'package:gymflow/services/platform/platform_services.dart';

import 'helpers.dart';

void main() {
  group('Rappel d’entraînement', () {
    late Backend backend;
    late RecordingNotifier notifier;

    setUp(() async {
      backend = await makeBackend();
      notifier = backend.notifier as RecordingNotifier;
      await loginAs(backend, 'ahmed@gymflow.tn');
    });

    Future<void> activateMember({int weeklyGoal = 3}) async {
      final user = backend.auth.currentUser!;
      for (final session in backend.sessions.where(
        (session) => session.userId == user.id,
      )) {
        await backend.sessions.delete(session.id);
      }
      await backend.users.save(
        user.copyWith(
          weeklyGoal: weeklyGoal,
          subscription: Subscription(
            type: SubscriptionType.monthly,
            start: testNow,
            end: testNow.add(const Duration(days: 30)),
          ),
        ),
      );
    }

    test('programme le rappel selon l’objectif hebdomadaire', () async {
      await activateMember(weeklyGoal: 3);

      await backend.trainingLog.scheduleInactivityReminder();

      expect(
        notifier.scheduled[TrainingLogService.inactivityReminderId(
          backend.auth.currentUser!.id,
        )],
        testNow.add(const Duration(days: 3)),
      );
    });

    test('repart de la dernière séance', () async {
      await activateMember(weeklyGoal: 2);
      final user = backend.auth.currentUser!;
      final lastSession = testNow.subtract(const Duration(days: 1));
      await backend.sessions.save(
        SessionLog(
          id: 'recent-session',
          userId: user.id,
          workoutId: 'workout',
          title: 'Séance',
          startedAt: lastSession,
          durationSec: 3600,
          sets: const [],
        ),
      );

      await backend.trainingLog.scheduleInactivityReminder();

      expect(
        notifier.scheduled[TrainingLogService.inactivityReminderId(user.id)],
        lastSession.add(const Duration(days: 4, hours: 1)),
      );
    });

    test('reprogramme le rappel après une séance terminée', () async {
      await activateMember(weeklyGoal: 3);
      final workout = backend.library.workouts().first;

      await backend.trainingLog.finishSession(
        workout: workout,
        startedAt: testNow,
        durationSec: 3600,
        sets: const [
          SetLog(
            exerciseId: 'exercise-1',
            exerciseName: 'Exercice',
            setIndex: 1,
            reps: 8,
            loadKg: 20,
          ),
        ],
      );

      expect(
        notifier.scheduled[TrainingLogService.inactivityReminderId(
          backend.auth.currentUser!.id,
        )],
        testNow.add(const Duration(days: 3, hours: 1)),
      );
    });

    test('annule le rappel si l’abonnement est inactif', () async {
      await activateMember();
      final user = backend.auth.currentUser!;
      await backend.trainingLog.scheduleInactivityReminder();
      final reminderId = TrainingLogService.inactivityReminderId(user.id);
      await backend.users.save(user.copyWith(subscription: Subscription.none));

      await backend.trainingLog.scheduleInactivityReminder();

      expect(notifier.scheduled, isNot(contains(reminderId)));
    });
  });
}
