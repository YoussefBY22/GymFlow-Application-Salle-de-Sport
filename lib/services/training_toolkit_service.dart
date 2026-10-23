import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class TrainingPlan {
  const TrainingPlan({
    required this.goal,
    required this.weeks,
    required this.sessionsPerWeek,
    required this.startDate,
  });

  final String goal;
  final int weeks;
  final int sessionsPerWeek;
  final DateTime startDate;

  String phaseForWeek(int week) {
    if (week == 1) return 'Adaptation';
    if (week == weeks) return 'Allègement';
    return 'Progression';
  }

  String guidanceForWeek(int week) => switch (phaseForWeek(week)) {
    'Adaptation' =>
      'Choisissez des charges confortables, soignez la technique et gardez '
          '2 à 3 répétitions en réserve (effort ressenti 6/10).',
    'Allègement' =>
      'Réduisez le nombre de séries d’environ 40 %, gardez une charge facile '
          'et privilégiez le sommeil et la récupération.',
    _ => switch (goal) {
      'Force' =>
        'Augmentez progressivement la charge (2 à 5 % au maximum si la '
            'technique reste maîtrisée), avec 3 à 5 répétitions par série.',
      'Endurance' =>
        'Augmentez légèrement le temps ou les répétitions, sans augmenter '
            'simultanément toutes les variables.',
      _ =>
        'Visez 8 à 12 répétitions et n’augmentez la charge que lorsque '
            'toutes les séries restent propres et confortables.',
    },
  };

  Map<String, Object> toJson() => {
    'goal': goal,
    'weeks': weeks,
    'sessionsPerWeek': sessionsPerWeek,
    'startDate': startDate.toIso8601String(),
  };

  factory TrainingPlan.fromJson(Map<String, dynamic> json) => TrainingPlan(
    goal: json['goal'] as String? ?? 'Forme générale',
    weeks: (json['weeks'] as num?)?.toInt() ?? 4,
    sessionsPerWeek: (json['sessionsPerWeek'] as num?)?.toInt() ?? 3,
    startDate:
        DateTime.tryParse(json['startDate'] as String? ?? '') ?? DateTime.now(),
  );
}

class TrainingCheckIn {
  const TrainingCheckIn({
    required this.sessionId,
    required this.sessionTitle,
    required this.date,
    required this.durationMinutes,
    required this.rpe,
    required this.fatigue,
  });

  final String sessionId;
  final String sessionTitle;
  final DateTime date;
  final int durationMinutes;
  final int rpe;
  final int fatigue;

  /// Charge session-RPE, en unités arbitraires (minutes × effort ressenti).
  int get load => durationMinutes * rpe;

  Map<String, Object> toJson() => {
    'sessionId': sessionId,
    'sessionTitle': sessionTitle,
    'date': date.toIso8601String(),
    'durationMinutes': durationMinutes,
    'rpe': rpe,
    'fatigue': fatigue,
  };

  factory TrainingCheckIn.fromJson(Map<String, dynamic> json) =>
      TrainingCheckIn(
        sessionId: json['sessionId'] as String? ?? '',
        sessionTitle: json['sessionTitle'] as String? ?? 'Séance',
        date:
            DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime(2000),
        durationMinutes: (json['durationMinutes'] as num?)?.toInt() ?? 0,
        rpe: (json['rpe'] as num?)?.toInt() ?? 0,
        fatigue: (json['fatigue'] as num?)?.toInt() ?? 0,
      );
}

class TrainingLoadAssessment {
  const TrainingLoadAssessment({
    required this.recentLoad,
    required this.baselineWeeklyLoad,
    required this.fatigueAverage,
    required this.ratedSessions,
  });

  final int recentLoad;
  final double? baselineWeeklyLoad;
  final double? fatigueAverage;
  final int ratedSessions;

  double? get ratio => baselineWeeklyLoad == null || baselineWeeklyLoad == 0
      ? null
      : recentLoad / baselineWeeklyLoad!;

  String get label {
    final currentRatio = ratio;
    if (currentRatio == null) return 'Données insuffisantes';
    if (currentRatio > 1.5) return 'Hausse importante';
    if (currentRatio > 1.3) return 'Charge en hausse';
    if (currentRatio >= 0.8) return 'Charge stable';
    return 'Charge en baisse';
  }

  String get advice {
    final currentRatio = ratio;
    if (currentRatio == null) {
      return 'Notez l’effort ressenti après plusieurs séances pour obtenir '
          'une comparaison personnelle.';
    }
    if (currentRatio > 1.5) {
      return 'Votre charge déclarée est nettement supérieure à votre '
          'référence récente. Envisagez une séance plus légère ou du repos.';
    }
    if (currentRatio > 1.3) {
      return 'La charge augmente. Gardez une progression graduelle et '
          'surveillez vos sensations.';
    }
    if (currentRatio >= 0.8) {
      return 'La charge est proche de votre référence récente. Continuez '
          'à ajuster selon votre forme.';
    }
    return 'La charge récente est plus faible que votre référence. Reprenez '
        'progressivement si vous vous sentez prêt.';
  }

  factory TrainingLoadAssessment.fromCheckIns(
    List<TrainingCheckIn> entries,
    DateTime now,
  ) {
    final recent = entries
        .where(
          (entry) =>
              !entry.date.isBefore(now.subtract(const Duration(days: 7))) &&
              !entry.date.isAfter(now),
        )
        .toList();
    final baseline = entries
        .where(
          (entry) =>
              entry.date.isBefore(now.subtract(const Duration(days: 7))) &&
              !entry.date.isBefore(now.subtract(const Duration(days: 28))) &&
              !entry.date.isAfter(now),
        )
        .toList();
    final baselineTotal = baseline.fold<int>(0, (sum, item) => sum + item.load);
    final fatigue = recent.isEmpty
        ? null
        : recent.fold<int>(0, (sum, item) => sum + item.fatigue) /
              recent.length;
    return TrainingLoadAssessment(
      recentLoad: recent.fold<int>(0, (sum, item) => sum + item.load),
      baselineWeeklyLoad: baseline.isEmpty ? null : baselineTotal / 3,
      fatigueAverage: fatigue,
      ratedSessions: recent.length,
    );
  }
}

class TrainingToolkitStore {
  TrainingToolkitStore(this.userId, {this._preferences});

  final String userId;
  final SharedPreferences? _preferences;

  String get _planKey => 'training_plan_v1_$userId';
  String get _checkInsKey => 'training_checkins_v1_$userId';

  Future<SharedPreferences> get _prefs async =>
      _preferences ?? await SharedPreferences.getInstance();

  Future<TrainingPlan?> loadPlan() async {
    final raw = (await _prefs).getString(_planKey);
    if (raw == null) return null;
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Planification locale illisible.');
    }
    return TrainingPlan.fromJson(json);
  }

  Future<void> savePlan(TrainingPlan plan) async {
    await (await _prefs).setString(_planKey, jsonEncode(plan.toJson()));
  }

  Future<List<TrainingCheckIn>> loadCheckIns() async {
    final raw = (await _prefs).getString(_checkInsKey);
    if (raw == null) return [];
    final json = jsonDecode(raw);
    if (json is! List) {
      throw const FormatException('Historique de charge local illisible.');
    }
    return json
        .whereType<Map<String, dynamic>>()
        .map(TrainingCheckIn.fromJson)
        .toList();
  }

  Future<void> saveCheckIn(TrainingCheckIn checkIn) async {
    final entries = await loadCheckIns();
    entries.removeWhere((entry) => entry.sessionId == checkIn.sessionId);
    entries.add(checkIn);
    entries.sort((a, b) => b.date.compareTo(a.date));
    final limited = entries.take(200).map((entry) => entry.toJson()).toList();
    await (await _prefs).setString(_checkInsKey, jsonEncode(limited));
  }
}
