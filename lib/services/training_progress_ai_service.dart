import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../models/enums.dart';
import '../models/session_log.dart';

class ExerciseProgress {
  const ExerciseProgress({
    required this.name,
    required this.bestLoadKg,
    required this.estimatedOneRmKg,
    required this.previousOneRmKg,
  });

  final String name;
  final double bestLoadKg;
  final double estimatedOneRmKg;
  final double? previousOneRmKg;

  double? get changePercent {
    final previous = previousOneRmKg;
    if (previous == null || previous <= 0) return null;
    return (estimatedOneRmKg - previous) / previous * 100;
  }

  Map<String, Object?> toJson() => {
    'exercise': name,
    'best_load_kg': double.parse(bestLoadKg.toStringAsFixed(1)),
    'estimated_1rm_kg': double.parse(estimatedOneRmKg.toStringAsFixed(1)),
    'previous_period_estimated_1rm_kg': previousOneRmKg == null
        ? null
        : double.parse(previousOneRmKg!.toStringAsFixed(1)),
  };
}

/// Comparaison locale des 28 derniers jours avec les 28 jours précédents.
class TrainingProgressSummary {
  const TrainingProgressSummary({
    required this.recentSessions,
    required this.previousSessions,
    required this.recentMinutes,
    required this.previousMinutes,
    required this.recentVolumeKg,
    required this.previousVolumeKg,
    required this.recentPersonalRecords,
    required this.previousPersonalRecords,
    required this.exerciseProgress,
  });

  static const periodDays = 28;

  final int recentSessions;
  final int previousSessions;
  final int recentMinutes;
  final int previousMinutes;
  final double recentVolumeKg;
  final double previousVolumeKg;
  final int recentPersonalRecords;
  final int previousPersonalRecords;
  final List<ExerciseProgress> exerciseProgress;

  bool get hasRecentSessions => recentSessions > 0;

  static TrainingProgressSummary fromSessions(
    Iterable<SessionLog> sessions,
    DateTime now,
  ) {
    final start = now.subtract(const Duration(days: periodDays));
    final previousStart = now.subtract(const Duration(days: periodDays * 2));
    final recent = <SessionLog>[];
    final previous = <SessionLog>[];
    for (final session in sessions) {
      if (session.startedAt.isAfter(now)) continue;
      if (!session.startedAt.isBefore(start)) {
        recent.add(session);
      } else if (!session.startedAt.isBefore(previousStart)) {
        previous.add(session);
      }
    }

    Map<String, double> oneRmByExercise(Iterable<SessionLog> source) {
      final values = <String, double>{};
      for (final session in source) {
        for (final set in session.sets) {
          if (set.loadKg <= 0 || set.reps <= 0) continue;
          final oneRm = set.reps <= 1
              ? set.loadKg
              : set.loadKg * (1 + set.reps / 30);
          final current = values[set.exerciseId] ?? 0;
          if (oneRm > current) values[set.exerciseId] = oneRm;
        }
      }
      return values;
    }

    final recentRecords = oneRmByExercise(recent);
    final previousRecords = oneRmByExercise(previous);
    final names = <String, String>{};
    for (final session in recent) {
      for (final set in session.sets) {
        if (set.exerciseName.trim().isNotEmpty) {
          names[set.exerciseId] = set.exerciseName.trim();
        }
      }
    }
    final exerciseProgress =
        recentRecords.entries
            .map(
              (entry) => ExerciseProgress(
                name: names[entry.key] ?? 'Exercice',
                bestLoadKg: recent
                    .expand((session) => session.sets)
                    .where(
                      (set) =>
                          set.exerciseId == entry.key &&
                          set.loadKg > 0 &&
                          set.reps > 0,
                    )
                    .fold<double>(
                      0,
                      (best, set) => best > set.loadKg ? best : set.loadKg,
                    ),
                estimatedOneRmKg: entry.value,
                previousOneRmKg: previousRecords[entry.key],
              ),
            )
            .toList()
          ..sort((a, b) => b.estimatedOneRmKg.compareTo(a.estimatedOneRmKg));

    double volume(Iterable<SessionLog> source) =>
        source.fold<double>(0, (sum, session) => sum + session.totalVolume);
    int minutes(Iterable<SessionLog> source) => source.fold<int>(
      0,
      (sum, session) => sum + (session.durationSec / 60).round(),
    );
    int personalRecords(Iterable<SessionLog> source) =>
        source.fold<int>(0, (sum, session) => sum + session.prCount);

    return TrainingProgressSummary(
      recentSessions: recent.length,
      previousSessions: previous.length,
      recentMinutes: minutes(recent),
      previousMinutes: minutes(previous),
      recentVolumeKg: volume(recent),
      previousVolumeKg: volume(previous),
      recentPersonalRecords: personalRecords(recent),
      previousPersonalRecords: personalRecords(previous),
      exerciseProgress: exerciseProgress.take(8).toList(),
    );
  }

  Map<String, Object?> toJson() => {
    'period_days': periodDays,
    'recent_period': {
      'sessions': recentSessions,
      'training_minutes': recentMinutes,
      'volume_kg_reps': double.parse(recentVolumeKg.toStringAsFixed(1)),
      'personal_records': recentPersonalRecords,
    },
    'previous_period': {
      'sessions': previousSessions,
      'training_minutes': previousMinutes,
      'volume_kg_reps': double.parse(previousVolumeKg.toStringAsFixed(1)),
      'personal_records': previousPersonalRecords,
    },
    'exercises': exerciseProgress.map((item) => item.toJson()).toList(),
  };
}

class SuggestedExercise {
  const SuggestedExercise({
    required this.name,
    required this.muscle,
    required this.equipment,
    required this.difficulty,
    required this.instructions,
  });

  final String name;
  final String muscle;
  final String equipment;
  final String difficulty;
  final String instructions;
}

class TrainingProgressAiService {
  TrainingProgressAiService({
    http.Client? client,
    String? groqApiKey,
    String? apiNinjasKey,
  }) : _client = client ?? http.Client(),
       _groqApiKey = (groqApiKey ?? AppConfig.groqApiKey).trim(),
       _apiNinjasKey = (apiNinjasKey ?? AppConfig.apiNinjasKey).trim();

  final http.Client _client;
  final String _groqApiKey;
  final String _apiNinjasKey;

  static const _groqUrl = 'https://api.groq.com/openai/v1/chat/completions';
  static const _exerciseUrl = 'https://api.api-ninjas.com/v1/exercises';
  static const _timeout = Duration(seconds: 25);

  bool get groqConfigured => _groqApiKey.isNotEmpty;
  bool get exerciseApiConfigured => _apiNinjasKey.isNotEmpty;

  Future<String> createProgressReport({
    required TrainingProgressSummary summary,
    required String goal,
  }) async {
    if (!groqConfigured) {
      throw const TrainingProgressApiException(
        'Le bilan automatique est momentanément indisponible.',
      );
    }
    if (!summary.hasRecentSessions) {
      throw const TrainingProgressApiException(
        'Aucune séance terminée sur les 28 derniers jours.',
      );
    }

    final response = await _request(
      () => _client.post(
        Uri.parse(_groqUrl),
        headers: {
          'Authorization': 'Bearer $_groqApiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': AppConfig.groqModel,
          'temperature': 0.3,
          'max_tokens': 350,
          'messages': [
            {
              'role': 'system',
              'content':
                  'Tu es un assistant de suivi sportif. En français, rédige '
                  'un bilan concis en 3 à 5 points : évolution observée, '
                  'régularité, point positif et une prochaine étape prudente '
                  'adaptée à l’objectif. Base-toi strictement sur les nombres '
                  'fournis, indique quand la comparaison manque de données, '
                  'n’invente aucune mesure et ne donne aucun diagnostic ou '
                  'conseil médical. Ne demande jamais d’augmenter toutes les '
                  'charges à la fois.',
            },
            {
              'role': 'user',
              'content': jsonEncode({'goal': goal, 'data': summary.toJson()}),
            },
          ],
        }),
      ),
    );
    if (response.statusCode != 200) {
      throw TrainingProgressApiException(
        _errorMessage(response.statusCode),
        statusCode: response.statusCode,
      );
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final choices = decoded is Map ? decoded['choices'] : null;
    final message = choices is List && choices.isNotEmpty
        ? choices.first is Map
              ? (choices.first as Map)['message']
              : null
        : null;
    final text = message is Map ? message['content'] : null;
    if (text is! String || text.trim().isEmpty) {
      throw const FormatException('Le bilan n’a pas pu être généré.');
    }
    return text.trim();
  }

  Future<List<SuggestedExercise>> suggestExercises(Muscle muscle) async {
    if (!exerciseApiConfigured) {
      throw const TrainingProgressApiException(
        'Les suggestions ne sont pas disponibles pour le moment.',
      );
    }
    final query = _apiMuscle(muscle);
    if (query == null) return [];
    final response = await _request(
      () => _client.get(
        Uri.parse(_exerciseUrl).replace(queryParameters: {'muscle': query}),
        headers: {'X-Api-Key': _apiNinjasKey},
      ),
    );
    if (response.statusCode != 200) {
      throw TrainingProgressApiException(
        _errorMessage(response.statusCode),
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) {
      throw const FormatException('Les suggestions ne sont pas disponibles.');
    }
    return decoded
        .whereType<Map>()
        .take(3)
        .map(
          (item) => SuggestedExercise(
            name: _text(item['name']),
            muscle: _text(item['muscle']),
            equipment: _text(item['equipment']),
            difficulty: _text(item['difficulty']),
            instructions: _text(item['instructions']),
          ),
        )
        .where((exercise) => exercise.name.isNotEmpty)
        .toList();
  }

  String? _apiMuscle(Muscle muscle) => switch (muscle) {
    Muscle.chest => 'chest',
    Muscle.back => 'lats',
    Muscle.shoulders => 'shoulders',
    Muscle.biceps => 'biceps',
    Muscle.triceps => 'triceps',
    Muscle.quads => 'quadriceps',
    Muscle.hamstrings => 'hamstrings',
    Muscle.glutes => 'glutes',
    Muscle.calves => 'calves',
    Muscle.abs => 'abdominals',
    Muscle.fullBody || Muscle.cardio => null,
  };

  Future<http.Response> _request(Future<http.Response> Function() send) async {
    try {
      return await send().timeout(_timeout);
    } on TimeoutException {
      throw const TrainingProgressApiException(
        'Le service IA/exercices ne répond pas. Vérifiez la connexion puis réessayez.',
      );
    }
  }

  String _errorMessage(int statusCode) {
    if (statusCode == 429 || statusCode >= 500) {
      return 'Le service est très sollicité. Réessayez dans quelques instants.';
    }
    return 'Cette fonctionnalité est temporairement indisponible.';
  }

  String _text(Object? value) => value is String
      ? value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim()
      : '';

  void dispose() => _client.close();
}

class TrainingProgressApiException implements Exception {
  const TrainingProgressApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
