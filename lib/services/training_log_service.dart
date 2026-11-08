import '../core/errors.dart';
import '../models/enums.dart';
import '../models/privacy.dart';
import '../models/session_log.dart';
import '../models/workout.dart';
import '../repositories/repository.dart';
import 'backend.dart';

/// Résultat de fin de séance : la séance enregistrée et les records battus.
class SessionResult {
  const SessionResult(this.log, this.records);
  final SessionLog log;
  final List<PersonalRecord> records;
}

/// API interne de l'historique des séances et du fil d'activités.
///
/// Confidentialité : une séance est **privée** à sa création. Elle n'apparaît
/// sur le fil du club que si son auteur la partage explicitement.
class TrainingLogService {
  TrainingLogService(this._b);
  final Backend _b;

  static int inactivityReminderId(String userId) =>
      userId.codeUnits.fold(5381, (hash, unit) => ((hash << 5) + hash) ^ unit) &
      0x7fffffff;

  /// Enregistre une séance terminée depuis le lecteur de séance (privée).
  Future<SessionResult> finishSession({
    required Workout workout,
    required DateTime startedAt,
    required int durationSec,
    required List<SetLog> sets,
    String note = '',
    int? caloriesBurned,
    int? averageHeartRate,
    int? maxHeartRate,
    int? stepCount,
    String? smartwatchDevice,
  }) async {
    final me = _b.requireUser();
    if (sets.isEmpty) {
      throw const BusinessRuleException(
        'Validez au moins une série pour enregistrer la séance.',
      );
    }
    if (durationSec <= 0) {
      throw const ValidationException('Durée de séance invalide.');
    }
    final records = _b.progress.detectRecords(me.id, sets, startedAt);
    final log = SessionLog(
      id: IdGen.next('s_'),
      userId: me.id,
      workoutId: workout.id,
      title: workout.name,
      startedAt: startedAt,
      durationSec: durationSec,
      sets: sets,
      exerciseCount: sets.map((s) => s.exerciseId).toSet().length,
      prCount: records.length,
      note: note.trim(),
      caloriesBurned: caloriesBurned,
      averageHeartRate: averageHeartRate,
      maxHeartRate: maxHeartRate,
      stepCount: stepCount,
      smartwatchDevice: smartwatchDevice,
    );
    await _b.sessions.save(log);
    await scheduleInactivityReminder();
    _b.bus.emit();
    return SessionResult(log, records);
  }

  /// Planifie un rappel de reprise selon l’objectif hebdomadaire du membre.
  Future<void> scheduleInactivityReminder() async {
    final current = _b.auth.currentUser;
    if (current == null) return;

    final user = _b.users.byId(current.id) ?? current;
    final reminderId = inactivityReminderId(user.id);
    final now = _b.now();
    if (!user.active ||
        user.role != UserRole.member ||
        !user.subscription.isActiveAt(now)) {
      await _b.notifier.cancel(reminderId);
      return;
    }

    final sessions = _b.sessions.where(
      (session) => session.userId == user.id && !session.startedAt.isAfter(now),
    )..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final baseline = sessions.isNotEmpty
        ? sessions.first.endedAt
        : (user.subscription.start ?? user.createdAt);
    final intervalDays = (7 / user.weeklyGoal.clamp(1, 7)).ceil();
    final interval = Duration(days: intervalDays);
    final elapsed = now.difference(baseline);
    final elapsedIntervals = elapsed.isNegative
        ? 0
        : elapsed.inMicroseconds ~/ interval.inMicroseconds;
    final reminderAt = baseline.add(interval * (elapsedIntervals + 1));

    if (user.subscription.end != null &&
        !reminderAt.isBefore(user.subscription.end!)) {
      await _b.notifier.cancel(reminderId);
      return;
    }

    await _b.notifier.schedule(
      reminderId,
      'Petit rappel d’entraînement',
      'Il est temps de reprendre votre entraînement. '
          'Votre objectif est de ${user.weeklyGoal} séance(s) par semaine.',
      reminderAt,
    );
  }

  /// Publie ou retire une séance du fil du club (auteur uniquement).
  /// Chaque décision est tracée dans l'historique des consentements.
  Future<SessionLog> setShared(String sessionId, bool shared) async {
    final me = _b.requireUser();
    final s = _b.sessions.byId(sessionId) ?? (throw const NotFoundException());
    if (s.userId != me.id) throw const PermissionDeniedException();
    if (s.shared == shared) return s;
    final updated = await _b.sessions.save(
      s.copyWith(
        shared: shared,
        sharedAt: shared ? _b.now() : null,
        // Retirer une séance efface aussi les « Bravo » reçus.
        kudos: shared ? s.kudos : const [],
      ),
    );
    await _b.privacy.recordConsent(ConsentType.shareSession, shared);
    _b.bus.emit();
    return updated;
  }

  /// Historique : la personne elle-même ou la salle (super admin).
  List<SessionLog> historyOf(String userId) {
    final me = _b.requireUser();
    if (me.id != userId && !me.isAdmin) throw const PermissionDeniedException();
    return _b.sessions.where((s) => s.userId == userId)
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }

  /// Séance consultable : la sienne, une séance partagée, ou la salle.
  SessionLog? byId(String id) {
    final me = _b.requireUser();
    final s = _b.sessions.byId(id);
    if (s == null) return null;
    if (s.userId == me.id || me.isAdmin) return s;
    if (s.shared && (_b.users.byId(s.userId)?.active ?? false)) return s;
    return null;
  }

  /// Séances partagées d'un membre (profil public).
  List<SessionLog> sharedSessionsOf(String userId) =>
      _b.sessions.where((s) => s.userId == userId && s.shared)
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

  /// Fil de l'accueil : ses propres séances (privées comprises, vues par
  /// soi seul) et, si on le souhaite, les séances **partagées** des autres.
  List<SessionLog> feed({int limit = 30, bool includeOthers = true}) {
    final me = _b.requireUser();
    final all =
        _b.sessions.where((s) {
          if (s.userId == me.id) return true;
          if (!includeOthers || !s.shared) return false;
          return _b.users.byId(s.userId)?.active ?? false;
        })..sort(
          (a, b) =>
              (b.sharedAt ?? b.startedAt).compareTo(a.sharedAt ?? a.startedAt),
        );
    return all.take(limit).toList();
  }

  /// « Bravo » (kudos) sur une séance partagée : ajoute ou retire le sien.
  Future<SessionLog> toggleKudos(String sessionId) async {
    final me = _b.requireUser();
    final s = _b.sessions.byId(sessionId) ?? (throw const NotFoundException());
    if (s.userId == me.id) {
      throw const BusinessRuleException(
        'Vous ne pouvez pas vous féliciter vous-même… mais bravo quand même !',
      );
    }
    if (!s.shared) {
      throw const PermissionDeniedException(
        'Cette séance n\'est pas partagée.',
      );
    }
    final kudos = [...s.kudos];
    final adding = !kudos.remove(me.id);
    if (adding) kudos.add(me.id);
    final updated = await _b.sessions.save(s.copyWith(kudos: kudos));
    if (adding) {
      await _b.notifications.notify(
        s.userId,
        NotificationType.kudos,
        '${me.firstName} vous dit Bravo !',
        'Pour votre séance « ${s.title} ».',
        refId: s.id,
      );
    }
    _b.bus.emit();
    return updated;
  }
}
