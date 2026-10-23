import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';

class OutdoorPlace {
  const OutdoorPlace({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.type,
  });

  final int id;
  final String name;
  final double latitude;
  final double longitude;
  final String type;
}

class WalkingRoute {
  const WalkingRoute({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.elevationGainMeters,
    required this.elevationLossMeters,
    required this.instructions,
  });

  final double distanceMeters;
  final double durationSeconds;
  final double elevationGainMeters;
  final double elevationLossMeters;
  final List<String> instructions;

  factory WalkingRoute.fromOpenRouteService(Map<String, dynamic> json) {
    final features = json['features'];
    if (features is! List || features.isEmpty || features.first is! Map) {
      throw const FormatException('Aucun itinéraire piéton reçu.');
    }
    final feature = Map<String, dynamic>.from(features.first as Map);
    final properties = feature['properties'];
    final geometry = feature['geometry'];
    if (properties is! Map || geometry is! Map) {
      throw const FormatException('Réponse d’itinéraire incomplète.');
    }
    final summary = (properties['summary'] as Map?)?.cast<String, dynamic>();
    final segments = properties['segments'];
    if (summary == null || segments is! List) {
      throw const FormatException('Résumé de l’itinéraire manquant.');
    }
    final instructions = <String>[];
    for (final segment in segments.whereType<Map>()) {
      final steps = segment['steps'];
      if (steps is! List) continue;
      for (final step in steps.whereType<Map>()) {
        final instruction = step['instruction'];
        if (instruction is String && instruction.trim().isNotEmpty) {
          instructions.add(instruction.trim());
        }
      }
    }
    final coordinates = geometry['coordinates'];
    final elevations = <double>[];
    if (coordinates is List) {
      for (final point in coordinates.whereType<List>()) {
        if (point.length >= 3 && point[2] is num) {
          elevations.add((point[2] as num).toDouble());
        }
      }
    }
    var gain = 0.0;
    var loss = 0.0;
    for (var i = 1; i < elevations.length; i++) {
      final delta = elevations[i] - elevations[i - 1];
      if (delta > 0) gain += delta;
      if (delta < 0) loss -= delta;
    }
    return WalkingRoute(
      distanceMeters: (summary['distance'] as num).toDouble(),
      durationSeconds: (summary['duration'] as num).toDouble(),
      elevationGainMeters: gain,
      elevationLossMeters: loss,
      instructions: instructions,
    );
  }
}

class OutdoorRouteService {
  OutdoorRouteService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  bool get enabled => AppConfig.openRouteServiceApiKey.trim().isNotEmpty;

  Future<List<OutdoorPlace>> findPlaces({
    required double latitude,
    required double longitude,
    required double radiusMeters,
  }) async {
    final query =
        '[out:json][timeout:20];'
        '(node["leisure"="park"](around:$radiusMeters,$latitude,$longitude);'
        'way["leisure"="park"](around:$radiusMeters,$latitude,$longitude);'
        'relation["leisure"="park"](around:$radiusMeters,$latitude,$longitude);'
        'node["leisure"="pitch"](around:$radiusMeters,$latitude,$longitude);'
        'way["leisure"="pitch"](around:$radiusMeters,$latitude,$longitude););'
        'out center tags 30;';
    final response = await _client
        .post(
          Uri.https('overpass-api.de', '/api/interpreter'),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': 'GymFlow/1.0 training route search',
          },
          body: {'data': query},
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw Exception('OpenStreetMap Overpass (${response.statusCode}).');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map || body['elements'] is! List) {
      throw const FormatException('Réponse OpenStreetMap illisible.');
    }
    final places = <OutdoorPlace>[];
    for (final element in (body['elements'] as List).whereType<Map>()) {
      final tags = element['tags'];
      if (tags is! Map) continue;
      final center = element['center'];
      final lat = element['lat'] ?? (center is Map ? center['lat'] : null);
      final lon = element['lon'] ?? (center is Map ? center['lon'] : null);
      if (lat is! num || lon is! num) continue;
      final id = element['id'];
      if (id is! num) continue;
      places.add(
        OutdoorPlace(
          id: id.toInt(),
          name: tags['name'] as String? ?? 'Espace sportif sans nom',
          latitude: lat.toDouble(),
          longitude: lon.toDouble(),
          type: tags['leisure'] as String? ?? 'park',
        ),
      );
    }
    return places;
  }

  Future<WalkingRoute> walkingRoute({
    required double startLatitude,
    required double startLongitude,
    required double endLatitude,
    required double endLongitude,
  }) async {
    if (!enabled) {
      throw StateError(
        'Ajoutez OPENROUTESERVICE_API_KEY dans secrets.json puis relancez '
        'l’application.',
      );
    }
    final response = await _client
        .post(
          Uri.https(
            'api.openrouteservice.org',
            '/v2/directions/foot-walking/geojson',
          ),
          headers: {
            'Authorization': AppConfig.openRouteServiceApiKey,
            'Content-Type': 'application/json',
            'Accept': 'application/geo+json, application/json',
          },
          body: jsonEncode({
            'coordinates': [
              [startLongitude, startLatitude],
              [endLongitude, endLatitude],
            ],
            'elevation': true,
            'instructions': true,
            'language': 'fr',
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('OpenRouteService (${response.statusCode}).');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map<String, dynamic>) {
      throw const FormatException('Réponse OpenRouteService illisible.');
    }
    return WalkingRoute.fromOpenRouteService(body);
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
