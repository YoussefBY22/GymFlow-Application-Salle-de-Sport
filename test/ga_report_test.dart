// Niveau : unitaire (sans réseau). Lecture des rapports Google Analytics 4 :
// analyse des réponses, requêtes envoyées, erreurs lisibles, droits.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/ga_report_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';

Map<String, dynamic> _table({
  List<String> dims = const [],
  List<String> metrics = const [],
  List<List<Object>> rows = const [],
}) => {
  'dimensionHeaders': [
    for (final d in dims) {'name': d},
  ],
  'metricHeaders': [
    for (final m in metrics) {'name': m, 'type': 'TYPE_INTEGER'},
  ],
  'rows': [
    for (final r in rows)
      {
        'dimensionValues': [
          for (final v in r.take(dims.length)) {'value': '$v'},
        ],
        'metricValues': [
          for (final v in r.skip(dims.length)) {'value': '$v'},
        ],
      },
  ],
};

/// Réponses simulées de l'API selon les métriques demandées.
http.Response _api(http.Request r) {
  final body = jsonDecode(r.body) as Map<String, dynamic>;
  final metrics = [
    for (final m in body['metrics'] as List) (m as Map)['name'] as String,
  ];
  final dims = [
    for (final d in (body['dimensions'] as List? ?? const []))
      (d as Map)['name'] as String,
  ];
  Map<String, dynamic> t;
  if (r.url.path.endsWith(':runRealtimeReport')) {
    t = dims.isEmpty
        ? _table(
            metrics: metrics,
            rows: [
              [3],
            ],
          )
        : _table(
            dims: dims,
            metrics: metrics,
            rows: [
              ['view_item', 12],
              ['add_to_cart', 4],
            ],
          );
  } else if (metrics.contains('itemsViewed')) {
    t = _table(
      dims: dims,
      metrics: metrics,
      rows: [
        ['Whey Isolate', 40, 12, 5, 250.5],
        ['(not set)', 1, 0, 0, 0],
        ['Shaker', 20, 3, 2, 30],
      ],
    );
  } else if (dims.contains('eventName')) {
    t = _table(
      dims: dims,
      metrics: metrics,
      rows: [
        ['view_item', 60, 8],
        ['purchase', 7, 5],
      ],
    );
  } else if (dims.contains('date')) {
    t = _table(
      dims: dims,
      metrics: metrics,
      rows: [
        ['20260929', 4, 30],
        ['20260930', 6, 41],
      ],
    );
  } else if (dims.contains('deviceCategory')) {
    t = _table(
      dims: dims,
      metrics: metrics,
      rows: [
        ['mobile', 9],
        ['desktop', 2],
      ],
    );
  } else {
    t = _table(
      metrics: metrics,
      rows: [
        [11, 4, 15, 71],
      ],
    );
  }
  return http.Response(jsonEncode(t), 200);
}

Future<Backend> _backend(
  http.Response Function(http.Request) handler, {
  List<http.Request>? seen,
  bool authorized = true,
}) async {
  final b = await makeBackend(
    httpClient: MockClient((r) async {
      if (r.url.host == 'analyticsdata.googleapis.com') {
        seen?.add(r);
        return handler(r);
      }
      return http.Response('{}', 200);
    }),
  );
  b.gaReport.propertyId = '123456789';
  b.gaReport.authorizer = ({bool prompt = false}) async =>
      authorized ? {'Authorization': 'Bearer jeton-de-test'} : null;
  return b;
}

void main() {
  group('Analyse des réponses', () {
    test('un tableau est lu avec ses dimensions et ses métriques', () {
      final t = GaTable.fromJson(
        _table(
          dims: ['eventName'],
          metrics: ['eventCount', 'totalUsers'],
          rows: [
            ['view_item', 60, 8],
            ['purchase', 7, 5],
          ],
        ),
      );
      expect(t.dimensionNames, ['eventName']);
      expect(t.metricNames, ['eventCount', 'totalUsers']);
      expect(t.rows.length, 2);
      expect(t.rows.first.dims, ['view_item']);
      expect(t.metric(t.rows.first, 'eventCount'), 60);
      expect(t.metric(t.rows.first, 'inconnue'), 0);
      expect(t.sum('eventCount'), 67);
    });

    test('une réponse vide ou partielle ne plante pas', () {
      final t = GaTable.fromJson(const {});
      expect(t.rows, isEmpty);
      expect(t.sum('x'), 0);
      final r = GaReport.fromTables(
        days: 7,
        overview: t,
        events: t,
        items: t,
        daily: t,
        devices: t,
      );
      expect(r.isEmpty, isTrue);
      expect(r.activeUsers, 0);
    });

    test('les valeurs non numériques valent zéro', () {
      final t = GaTable.fromJson({
        'metricHeaders': [
          {'name': 'a'},
        ],
        'rows': [
          {
            'metricValues': [
              {'value': 'abc'},
            ],
          },
        ],
      });
      expect(t.rows.single.metrics, [0]);
    });

    test('les dates de Google sont remises en forme', () {
      expect(GaReport.formatDate('20260930'), '2026-09-30');
      expect(GaReport.formatDate('abc'), 'abc');
    });
  });

  group('Rapport', () {
    test('toutes les rubriques sont remplies', () async {
      final seen = <http.Request>[];
      final b = await _backend(_api, seen: seen);
      await loginAs(b, 'admin@gymflow.tn');
      final r = await b.gaReport.report(days: 14);

      expect(r.days, 14);
      expect(r.activeUsers, 11);
      expect(r.newUsers, 4);
      expect(r.sessions, 15);
      expect(r.eventCount, 71);
      expect(r.count('view_item'), 60);
      expect(r.events.first.users, 8);
      expect(r.daily.map((d) => d.$1), ['2026-09-29', '2026-09-30']);
      expect(r.daily.last.$2, 6);
      expect(r.devices, [('mobile', 9), ('desktop', 2)]);
      // Les produits « (not set) » sont écartés.
      expect(r.items.map((i) => i.name), ['Whey Isolate', 'Shaker']);
      expect(r.items.first.viewed, 40);
      expect(r.items.first.purchased, 5);
      expect(r.items.first.revenue, 250.5);
      expect(r.isEmpty, isFalse);
    });

    test('les requêtes visent la bonne propriété avec le jeton', () async {
      final seen = <http.Request>[];
      final b = await _backend(_api, seen: seen);
      await loginAs(b, 'admin@gymflow.tn');
      await b.gaReport.report(days: 7);

      expect(seen.length, 5);
      for (final q in seen) {
        expect(
          q.url.toString(),
          'https://analyticsdata.googleapis.com/v1beta/properties/123456789:runReport',
        );
        expect(q.headers['Authorization'], 'Bearer jeton-de-test');
        final body = jsonDecode(q.body) as Map<String, dynamic>;
        expect((body['dateRanges'] as List).single, {
          'startDate': '6daysAgo',
          'endDate': 'today',
        });
      }
    });

    test('le temps réel utilise les 30 dernières minutes', () async {
      final seen = <http.Request>[];
      final b = await _backend(_api, seen: seen);
      await loginAs(b, 'admin@gymflow.tn');
      final rt = await b.gaReport.realtime();
      expect(rt.activeUsers, 3);
      expect(rt.events.map((e) => e.name), ['view_item', 'add_to_cart']);
      expect(rt.events.first.count, 12);
      for (final q in seen) {
        expect(q.url.path, endsWith(':runRealtimeReport'));
        final body = jsonDecode(q.body) as Map<String, dynamic>;
        expect((body['minuteRanges'] as List).single, {
          'startMinutesAgo': 29,
          'endMinutesAgo': 0,
        });
        expect(body.containsKey('dateRanges'), isFalse);
      }
    });
  });

  group('Droits et configuration', () {
    test("un abonné ne peut ni lire ni se connecter", () async {
      final b = await _backend(_api);
      await loginAs(b, 'ahmed@gymflow.tn');
      expect(
        () => b.gaReport.report(),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(
        () => b.gaReport.realtime(),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(
        () => b.gaReport.connect(),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(
        () => b.gaReport.isConnected(),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test("sans identifiant de propriété : message clair", () async {
      final b = await _backend(_api);
      await loginAs(b, 'admin@gymflow.tn');
      b.gaReport.propertyId = '  ';
      expect(b.gaReport.configured, isFalse);
      expect(await b.gaReport.isConnected(), isFalse);
      await expectLater(
        b.gaReport.report(),
        throwsA(
          isA<BusinessRuleException>().having(
            (e) => e.message,
            'message',
            contains('GA_PROPERTY_ID'),
          ),
        ),
      );
    });

    test("connexion : refusée par la personne → pas connecté", () async {
      final b = await _backend(_api, authorized: false);
      await loginAs(b, 'admin@gymflow.tn');
      expect(await b.gaReport.isConnected(), isFalse);
      expect(await b.gaReport.connect(), isFalse);
      await expectLater(
        b.gaReport.report(),
        throwsA(
          isA<BusinessRuleException>().having(
            (e) => e.message,
            'message',
            contains('Connectez-vous'),
          ),
        ),
      );
    });

    test("connexion réussie", () async {
      final b = await _backend(_api);
      await loginAs(b, 'admin@gymflow.tn');
      expect(await b.gaReport.isConnected(), isTrue);
      expect(await b.gaReport.connect(), isTrue);
    });

    test("une erreur de l'autorisation n'est pas une connexion", () async {
      final b = await _backend(_api);
      await loginAs(b, 'admin@gymflow.tn');
      b.gaReport.authorizer = ({bool prompt = false}) async =>
          throw const BusinessRuleException('Connexion annulée.');
      expect(await b.gaReport.isConnected(), isFalse);
    });
  });

  group('Erreurs de Google', () {
    Future<String> messageFor(int status, [String body = '{}']) async {
      final b = await _backend((_) => http.Response(body, status));
      await loginAs(b, 'admin@gymflow.tn');
      try {
        await b.gaReport.report();
      } on AppException catch (e) {
        return e.message;
      }
      return '';
    }

    test('401 : autorisation expirée', () async {
      expect(await messageFor(401), contains('expiré'));
    });

    test('403 : accès ou API désactivée', () async {
      final m = await messageFor(403);
      expect(m, contains('Google Analytics Data API'));
    });

    test('404 : propriété introuvable', () async {
      expect(await messageFor(404), contains('GA_PROPERTY_ID'));
    });

    test('429 : quota atteint', () async {
      expect(await messageFor(429), contains('Quota'));
    });

    test('400 : le détail de Google est repris', () async {
      final m = await messageFor(
        400,
        '{"error":{"message":"Field itemsViewed is not valid"}}',
      );
      expect(m, contains('itemsViewed'));
    });

    test('500 : code affiché, aucun détail technique brut', () async {
      final m = await messageFor(500, '<html>boom</html>');
      expect(m, contains('500'));
      expect(m, isNot(contains('<html>')));
    });

    test('réseau coupé : message lisible', () async {
      final b = await makeBackend(
        httpClient: MockClient((_) async => throw http.ClientException('x')),
      );
      b.gaReport.propertyId = '1';
      b.gaReport.authorizer = ({bool prompt = false}) async => {
        'Authorization': 'Bearer t',
      };
      await loginAs(b, 'admin@gymflow.tn');
      await expectLater(
        b.gaReport.report(),
        throwsA(
          isA<BusinessRuleException>().having(
            (e) => e.message,
            'message',
            contains('Impossible de joindre'),
          ),
        ),
      );
    });

    test('réponse illisible : message lisible', () async {
      final b = await _backend((_) => http.Response('pas du json', 200));
      await loginAs(b, 'admin@gymflow.tn');
      await expectLater(
        b.gaReport.report(),
        throwsA(
          isA<BusinessRuleException>().having(
            (e) => e.message,
            'message',
            contains('inattendue'),
          ),
        ),
      );
    });
  });
}
