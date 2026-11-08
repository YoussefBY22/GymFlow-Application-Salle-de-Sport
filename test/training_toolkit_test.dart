import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gymflow/services/outdoor_route_service.dart';
import 'package:gymflow/services/training_toolkit_service.dart';

void main() {
  group('Planification périodisée', () {
    test('cycle 4 semaines alterne adaptation, progression et allègement', () {
      final plan = TrainingPlan(
        goal: 'Force',
        weeks: 4,
        sessionsPerWeek: 3,
        startDate: DateTime(2026, 10, 1),
      );

      expect(plan.phaseForWeek(1), 'Adaptation');
      expect(plan.phaseForWeek(2), 'Progression');
      expect(plan.phaseForWeek(3), 'Progression');
      expect(plan.phaseForWeek(4), 'Allègement');
      expect(plan.guidanceForWeek(2), contains('2 à 5 %'));
      expect(plan.guidanceForWeek(4), contains('40 %'));
    });
  });

  group('Suivi de charge et récupération', () {
    final now = DateTime(2026, 10, 22, 12);

    TrainingCheckIn entry(int daysAgo, int minutes, int rpe, int fatigue) =>
        TrainingCheckIn(
          sessionId: 's_$daysAgo',
          sessionTitle: 'Séance',
          date: now.subtract(Duration(days: daysAgo)),
          durationMinutes: minutes,
          rpe: rpe,
          fatigue: fatigue,
        );

    test('charge session-RPE = durée × effort ressenti', () {
      expect(entry(1, 45, 7, 4).load, 315);
    });

    test('compare charge récente aux trois semaines de référence', () {
      final assessment = TrainingLoadAssessment.fromCheckIns([
        entry(1, 40, 6, 3),
        entry(3, 40, 6, 3),
        entry(5, 40, 6, 3),
        entry(10, 40, 6, 3),
        entry(17, 40, 6, 3),
        entry(24, 40, 6, 3),
      ], now);

      expect(assessment.recentLoad, 720);
      expect(assessment.baselineWeeklyLoad, 240);
      expect(assessment.ratio, 3);
      expect(assessment.label, 'Hausse importante');
      expect(assessment.fatigueAverage, 3);
    });

    test('absence de référence ne fabrique pas de ratio', () {
      final assessment = TrainingLoadAssessment.fromCheckIns([
        entry(1, 30, 5, 2),
      ], now);

      expect(assessment.ratio, isNull);
      expect(assessment.label, 'Données insuffisantes');
    });
  });

  test('analyse distance, dénivelé et instructions ORS', () {
    final route = WalkingRoute.fromOpenRouteService({
      'features': [
        {
          'properties': {
            'summary': {'distance': 2450, 'duration': 1800},
            'segments': [
              {
                'steps': [
                  {'instruction': 'Continuer tout droit'},
                  {'instruction': 'Tourner à gauche'},
                ],
              },
            ],
          },
          'geometry': {
            'coordinates': [
              [10.1, 36.8, 5],
              [10.2, 36.9, 12],
              [10.3, 37.0, 8],
            ],
          },
        },
      ],
    });

    expect(route.distanceMeters, 2450);
    expect(route.durationSeconds, 1800);
    expect(route.elevationGainMeters, 7);
    expect(route.elevationLossMeters, 4);
    expect(route.instructions, ['Continuer tout droit', 'Tourner à gauche']);
  });

  test(
    'recherche les lieux sur un serveur de secours si le premier échoue',
    () async {
      final hosts = <String>[];
      final service = OutdoorRouteService(
        client: MockClient((request) async {
          hosts.add(request.url.host);
          if (request.url.host != 'overpass.kumi.systems') {
            return http.Response('', 503);
          }
          return http.Response(
            jsonEncode({
              'elements': [
                {
                  'id': 42,
                  'lat': 36.8,
                  'lon': 10.2,
                  'tags': {'name': 'Parc de test', 'leisure': 'park'},
                },
              ],
            }),
            200,
          );
        }),
      );

      final places = await service.findPlaces(
        latitude: 36.8,
        longitude: 10.2,
        radiusMeters: 2500,
      );

      expect(hosts, [
        'nominatim.openstreetmap.org',
        'overpass-api.de',
        'overpass.kumi.systems',
      ]);
      expect(places.single.name, 'Parc de test');
      service.dispose();
    },
  );

  test(
    'recherche les parcs autour du départ avec les données cartographiques',
    () async {
      http.Request? request;
      final service = OutdoorRouteService(
        client: MockClient((r) async {
          request = r;
          return http.Response(
            jsonEncode([
              {
                'place_id': 123,
                'lat': '36.8350',
                'lon': '10.2410',
                'category': 'leisure',
                'type': 'park',
                'name': 'Parc proche',
              },
            ]),
            200,
          );
        }),
      );

      final places = await service.findPlaces(
        latitude: 36.8347,
        longitude: 10.2407,
        radiusMeters: 1000,
      );

      expect(request!.url.host, 'nominatim.openstreetmap.org');
      expect(request!.url.queryParameters['q'], 'park');
      expect(request!.url.queryParameters['bounded'], '1');
      expect(request!.headers['User-Agent'], contains('GymFlow'));
      expect(places.single.name, 'Parc proche');
      expect(places.single.type, 'park');
      service.dispose();
    },
  );
}
