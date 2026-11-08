import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../core/config.dart';

class OutdoorRouteException implements Exception {
  const OutdoorRouteException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;
}

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

  static const _placeCacheTtl = Duration(minutes: 5);
  static final Map<String, (List<OutdoorPlace>, DateTime)> _placeCache = {};

  bool get enabled => AppConfig.openRouteServiceApiKey.trim().isNotEmpty;

  Future<List<OutdoorPlace>> findPlaces({
    required double latitude,
    required double longitude,
    required double radiusMeters,
  }) async {
    final cacheKey =
        '${latitude.toStringAsFixed(4)}:${longitude.toStringAsFixed(4)}:'
        '${radiusMeters.round()}';
    final cached = _placeCache[cacheKey];
    if (cached != null &&
        DateTime.now().difference(cached.$2) < _placeCacheTtl) {
      return cached.$1;
    }

    try {
      final places = await _findPlacesWithNominatim(
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters,
      );
      if (places.isNotEmpty) {
        _placeCache[cacheKey] = (places, DateTime.now());
        return places;
      }
    } on Exception {
      // Try another public map-data endpoint if this search is unavailable.
    }

    try {
      final places = await _findPlacesWithOverpass(
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters,
      );
      _placeCache[cacheKey] = (places, DateTime.now());
      return places;
    } on Exception {
      throw const OutdoorRouteException(
        'La recherche est temporairement indisponible. Réessayez dans quelques instants.',
      );
    }
  }

  Future<List<OutdoorPlace>> _findPlacesWithNominatim({
    required double latitude,
    required double longitude,
    required double radiusMeters,
  }) async {
    final latDelta = radiusMeters / 111320;
    final lonDelta =
        radiusMeters /
        (111320 * math.cos(latitude * math.pi / 180).abs().clamp(0.01, 1));
    final viewbox = [
      longitude - lonDelta,
      latitude + latDelta,
      longitude + lonDelta,
      latitude - latDelta,
    ].join(',');

    final parks = await _nominatimSearch(
      {
        'q': 'park',
        'viewbox': viewbox,
        'bounded': '1',
        'format': 'jsonv2',
        'limit': '30',
      },
      latitude,
      longitude,
      radiusMeters,
    );
    if (parks.isNotEmpty) return parks;

    await Future<void>.delayed(const Duration(seconds: 1));
    return _nominatimSearch(
      {
        'amenity': 'sports_centre',
        'viewbox': viewbox,
        'bounded': '1',
        'format': 'jsonv2',
        'limit': '30',
      },
      latitude,
      longitude,
      radiusMeters,
    );
  }

  Future<List<OutdoorPlace>> _nominatimSearch(
    Map<String, String> parameters,
    double latitude,
    double longitude,
    double radiusMeters,
  ) async {
    final response = await _client
        .get(
          Uri.https('nominatim.openstreetmap.org', '/search', parameters),
          headers: const {
            'User-Agent': 'GymFlow/2.0 (mobile fitness application)',
            'Accept-Language': 'fr',
          },
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw OutdoorRouteException(
        'La recherche est temporairement indisponible.',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) {
      throw const OutdoorRouteException(
        'La recherche est temporairement indisponible.',
      );
    }
    final places = <OutdoorPlace>[];
    for (final item in decoded.whereType<Map>()) {
      final lat = double.tryParse('${item['lat']}');
      final lon = double.tryParse('${item['lon']}');
      final id = item['place_id'];
      if (lat == null || lon == null || id is! num) continue;
      if (_distanceMeters(latitude, longitude, lat, lon) > radiusMeters) {
        continue;
      }
      final category = item['category'] as String? ?? '';
      final type = item['type'] as String? ?? '';
      places.add(
        OutdoorPlace(
          id: id.toInt(),
          name: (item['name'] as String?)?.trim().isNotEmpty == true
              ? (item['name'] as String).trim()
              : 'Espace sportif',
          latitude: lat,
          longitude: lon,
          type: category == 'leisure' && type == 'park' ? 'park' : type,
        ),
      );
    }
    places.sort(
      (a, b) => _distanceMeters(latitude, longitude, a.latitude, a.longitude)
          .compareTo(
            _distanceMeters(latitude, longitude, b.latitude, b.longitude),
          ),
    );
    return places;
  }

  double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusMeters = 6371000.0;
    final latDelta = (lat2 - lat1) * math.pi / 180;
    final lonDelta = (lon2 - lon1) * math.pi / 180;
    final a =
        math.pow(math.sin(latDelta / 2), 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.pow(math.sin(lonDelta / 2), 2);
    return earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  Future<List<OutdoorPlace>> _findPlacesWithOverpass({
    required double latitude,
    required double longitude,
    required double radiusMeters,
  }) async {
    final query =
        '[out:json][timeout:8];'
        '(node["leisure"="park"](around:$radiusMeters,$latitude,$longitude);'
        'way["leisure"="park"](around:$radiusMeters,$latitude,$longitude);'
        'relation["leisure"="park"](around:$radiusMeters,$latitude,$longitude);'
        'node["leisure"="pitch"](around:$radiusMeters,$latitude,$longitude);'
        'way["leisure"="pitch"](around:$radiusMeters,$latitude,$longitude););'
        'out center tags 30;';
    Object? lastError;
    for (final host in ['overpass-api.de', 'overpass.kumi.systems']) {
      try {
        final response = await _client
            .post(
              Uri.https(host, '/api/interpreter'),
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'User-Agent': 'GymFlow/2.0',
              },
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 6));
        if (response.statusCode != 200) {
          lastError = OutdoorRouteException(
            'Recherche temporairement indisponible.',
            statusCode: response.statusCode,
          );
          continue;
        }
        return _parsePlaces(response);
      } on OutdoorRouteException catch (error) {
        lastError = error;
      } on Exception catch (error) {
        lastError = error;
      }
    }
    if (lastError is OutdoorRouteException && lastError.statusCode == 429) {
      throw const OutdoorRouteException(
        'La recherche est très sollicitée. Réessayez dans quelques instants.',
        statusCode: 429,
      );
    }
    throw const OutdoorRouteException('La recherche a échoué.');
  }

  List<OutdoorPlace> _parsePlaces(http.Response response) {
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map || body['elements'] is! List) {
      throw const OutdoorRouteException(
        'La recherche est momentanément indisponible.',
      );
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
      throw const OutdoorRouteException(
        'Le calcul détaillé du trajet est momentanément indisponible.',
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
      throw OutdoorRouteException(
        response.statusCode == 429
            ? 'Le calcul du trajet est très sollicité. Réessayez plus tard.'
            : 'Le calcul détaillé du trajet est momentanément indisponible.',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map<String, dynamic>) {
      throw const OutdoorRouteException(
        'Le calcul détaillé du trajet est momentanément indisponible.',
      );
    }
    return WalkingRoute.fromOpenRouteService(body);
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
