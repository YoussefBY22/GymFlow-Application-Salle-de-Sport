import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../models/enums.dart';

/// Modèle représentant un exercice avec son GIF animé,
/// retourné par l'API ExerciseDB (RapidAPI).
class ExerciseGif {
  const ExerciseGif({
    required this.id,
    required this.name,
    required this.gifUrl,
    required this.bodyPart,
    required this.target,
    required this.equipment,
  });

  final String id;
  final String name;
  final String gifUrl;
  final String bodyPart;
  final String target;
  final String equipment;

  factory ExerciseGif.fromJson(Map<String, dynamic> json) => ExerciseGif(
    id: '${json['id'] ?? ''}',
    name: json['name'] as String? ?? '',
    gifUrl: json['gifUrl'] as String? ?? '',
    bodyPart: json['bodyPart'] as String? ?? '',
    target: json['target'] as String? ?? '',
    equipment: json['equipment'] as String? ?? '',
  );
}

/// Service d'accès à l'API ExerciseDB via RapidAPI.
///
/// Permet de récupérer des GIFs animés de démonstration pour un exercice
/// donné. Une clé RapidAPI peut être fournie via `EXERCISE_DB_API_KEY`.
///
/// Cache en mémoire partagé entre fiches pour limiter les appels réseau.
class ExerciseDbService {
  ExerciseDbService({http.Client? client, String? apiKey})
    : _client = client ?? http.Client(),
      _apiKey = apiKey ?? AppConfig.exerciseDbApiKey,
      _cache = client == null ? _sharedCache : {};

  final http.Client _client;
  final String _apiKey;
  final Map<String, (List<ExerciseGif>, DateTime)> _cache;

  static const String _baseUrl = 'https://exercisedb.p.rapidapi.com';
  static const Duration _timeout = Duration(seconds: 8);
  static const Duration _cacheTtl = Duration(hours: 12);
  static const Map<Muscle, String> _targets = {
    Muscle.chest: 'pectorals',
    Muscle.back: 'lats',
    Muscle.shoulders: 'delts',
    Muscle.biceps: 'biceps',
    Muscle.triceps: 'triceps',
    Muscle.quads: 'quads',
    Muscle.hamstrings: 'hamstrings',
    Muscle.glutes: 'gluteus maximus',
    Muscle.calves: 'calves',
    Muscle.abs: 'abs',
    Muscle.cardio: 'cardiovascular system',
  };

  /// Cache : nom normalisé → (liste de GIFs, horodatage).
  static final Map<String, (List<ExerciseGif>, DateTime)> _sharedCache = {};

  bool get isConfigured => _apiKey.trim().isNotEmpty;

  /// Recherche des GIFs animés pour un exercice par son nom en anglais.
  ///
  /// Retourne au maximum 3 résultats. Une clé absente retourne une liste vide;
  /// les erreurs réseau et d'API sont propagées afin que l'écran les signale.
  Future<List<ExerciseGif>> searchByName(String name) async {
    final normalized = name.toLowerCase().trim();
    if (normalized.isEmpty || !isConfigured) return [];
    return _request('name/${Uri.encodeComponent(normalized)}', normalized);
  }

  /// Fournit des exercices animés du même muscle si le nom n'existe pas dans
  /// le catalogue ExerciseDB (par exemple lorsque le nom local est en français).
  Future<List<ExerciseGif>> searchByTarget(Muscle muscle) async {
    if (!isConfigured) return [];
    final target = _targets[muscle];
    if (target == null) return [];
    return _request(
      'target/${Uri.encodeComponent(target)}',
      'target:${muscle.name}',
    );
  }

  Future<List<ExerciseGif>> _request(String endpoint, String cacheKey) async {
    final key = _apiKey.trim();
    _cache.removeWhere(
      (_, entry) => DateTime.now().difference(entry.$2) >= _cacheTtl,
    );
    final cached = _cache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.$2) < _cacheTtl) {
      return cached.$1;
    }
    if (_cache.length >= 200) {
      final oldestKey = _cache.entries
          .reduce((a, b) => a.value.$2.isBefore(b.value.$2) ? a : b)
          .key;
      _cache.remove(oldestKey);
    }

    final uri = Uri.parse('$_baseUrl/exercises/$endpoint?limit=3');
    final response = await _client
        .get(
          uri,
          headers: {
            'X-RapidAPI-Key': key,
            'X-RapidAPI-Host': 'exercisedb.p.rapidapi.com',
          },
        )
        .timeout(_timeout);
    if (response.statusCode == 404) return [];
    if (response.statusCode == 401) {
      throw const ExerciseDbException(
        'La démonstration animée est momentanément indisponible.',
        statusCode: 401,
      );
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw ExerciseDbException(
        'La démonstration animée est momentanément indisponible.',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode != 200) {
      throw ExerciseDbException(
        'La démonstration animée est momentanément indisponible.',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    if (body is! List) {
      throw const FormatException('Réponse ExerciseDB invalide.');
    }
    final results = body
        .whereType<Map>()
        .map((item) => ExerciseGif.fromJson(Map<String, dynamic>.from(item)))
        .where((gif) => gif.gifUrl.startsWith('https://'))
        .toList();
    _cache[cacheKey] = (results, DateTime.now());
    return results;
  }

  /// Libère le client HTTP sous-jacent.
  void dispose() => _client.close();
}

class ExerciseDbException implements Exception {
  const ExerciseDbException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
