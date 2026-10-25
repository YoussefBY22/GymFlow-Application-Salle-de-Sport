import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/errors.dart';
import 'backend.dart';

/// Fournit les en-têtes d'autorisation (injectable pour les tests).
typedef GaAuthorizer = Future<Map<String, String>?> Function({bool prompt});

/// Lecture des rapports **Google Analytics 4** (API Google Analytics Data).
///
/// Réservé à l'administrateur. Il se connecte avec son compte Google :
/// l'application reçoit un jeton de lecture court, qui ne donne accès qu'aux
/// propriétés Analytics que ce compte peut déjà consulter. Aucune clé de
/// lecture n'est embarquée dans l'application.
///
/// Les chiffres affichés ici viennent **de Google**, pas de la base de
/// GymFlow : ils peuvent être en retard de quelques heures et ne couvrent
/// que les membres qui ont accepté la mesure d'audience.
class GaReportService {
  GaReportService(this._b, {this.authorizer, String? propertyId})
    : propertyId = propertyId ?? AppConfig.gaPropertyId;

  final Backend _b;

  /// Remplace la demande d'autorisation Google (tests).
  GaAuthorizer? authorizer;

  /// Identifiant numérique de la propriété (remplaçable dans les tests).
  String propertyId;

  static const _base = 'https://analyticsdata.googleapis.com/v1beta';

  bool get configured => propertyId.trim().isNotEmpty;

  Future<Map<String, String>?> _headers({required bool prompt}) {
    final custom = authorizer;
    if (custom != null) return custom(prompt: prompt);
    return _b.googleAuth.analyticsHeaders(prompt: prompt);
  }

  /// L'administrateur a-t-il déjà autorisé la lecture (sans fenêtre) ?
  Future<bool> isConnected() async {
    _b.requireRole(Backend.adminOnly);
    if (!configured) return false;
    try {
      return await _headers(prompt: false) != null;
    } catch (_) {
      return false;
    }
  }

  /// Ouvre la fenêtre d'autorisation Google (à appeler depuis un clic).
  /// Renvoie `false` si la personne a refermé la fenêtre.
  Future<bool> connect() async {
    _b.requireRole(Backend.adminOnly);
    _requireConfigured();
    return await _headers(prompt: true) != null;
  }

  void _requireConfigured() {
    if (!configured) {
      throw const BusinessRuleException(
        "GA_PROPERTY_ID est absent de secrets.json : Google Analytics n'est "
        'pas configuré.',
      );
    }
  }

  // ----------------------------------------------------------- Rapports

  /// Rapport des [days] derniers jours (aujourd'hui compris).
  Future<GaReport> report({int days = 14}) async {
    _b.requireRole(Backend.adminOnly);
    _requireConfigured();
    final range = [
      {'startDate': '${days - 1}daysAgo', 'endDate': 'today'},
    ];
    Map<String, Object?> byMetricDesc(String m) => {
      'metric': {'metricName': m},
      'desc': true,
    };
    final results = await Future.wait([
      _run('runReport', {
        'dateRanges': range,
        'metrics': _names([
          'activeUsers',
          'newUsers',
          'sessions',
          'eventCount',
        ]),
      }),
      _run('runReport', {
        'dateRanges': range,
        'dimensions': _names(['eventName']),
        'metrics': _names(['eventCount', 'totalUsers']),
        'orderBys': [byMetricDesc('eventCount')],
        'limit': 50,
      }),
      _run('runReport', {
        'dateRanges': range,
        'dimensions': _names(['itemName']),
        'metrics': _names([
          'itemsViewed',
          'itemsAddedToCart',
          'itemsPurchased',
          'itemRevenue',
        ]),
        'orderBys': [byMetricDesc('itemsViewed')],
        'limit': 20,
      }),
      _run('runReport', {
        'dateRanges': range,
        'dimensions': _names(['date']),
        'metrics': _names(['activeUsers', 'eventCount']),
        'orderBys': [
          {
            'dimension': {'dimensionName': 'date'},
          },
        ],
      }),
      _run('runReport', {
        'dateRanges': range,
        'dimensions': _names(['deviceCategory']),
        'metrics': _names(['activeUsers']),
        'orderBys': [byMetricDesc('activeUsers')],
      }),
    ]);
    return GaReport.fromTables(
      days: days,
      overview: results[0],
      events: results[1],
      items: results[2],
      daily: results[3],
      devices: results[4],
    );
  }

  /// Activité des 30 dernières minutes.
  Future<GaRealtime> realtime() async {
    _b.requireRole(Backend.adminOnly);
    _requireConfigured();
    final minutes = [
      {'startMinutesAgo': 29, 'endMinutesAgo': 0},
    ];
    final results = await Future.wait([
      _run('runRealtimeReport', {
        'minuteRanges': minutes,
        'metrics': _names(['activeUsers']),
      }),
      _run('runRealtimeReport', {
        'minuteRanges': minutes,
        'dimensions': _names(['eventName']),
        'metrics': _names(['eventCount']),
        'orderBys': [
          {
            'metric': {'metricName': 'eventCount'},
            'desc': true,
          },
        ],
        'limit': 15,
      }),
    ]);
    return GaRealtime.fromTables(users: results[0], events: results[1]);
  }

  static List<Map<String, String>> _names(List<String> names) => [
    for (final n in names) {'name': n},
  ];

  Future<GaTable> _run(String method, Map<String, Object?> body) async {
    final headers = await _headers(prompt: false);
    if (headers == null) {
      throw const BusinessRuleException(
        'Connectez-vous avec Google pour lire les rapports.',
      );
    }
    final uri = Uri.parse(
      '$_base/properties/${Uri.encodeComponent(propertyId.trim())}:$method',
    );
    final http.Response r;
    try {
      r = await _b.httpClient
          .post(
            uri,
            headers: {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const BusinessRuleException(
        'Google Analytics ne répond pas. Réessayez dans un instant.',
      );
    } catch (_) {
      throw const BusinessRuleException(
        'Impossible de joindre Google Analytics. Vérifiez la connexion.',
      );
    }
    if (r.statusCode != 200) throw errorFor(r.statusCode, r.body);
    try {
      return GaTable.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
    } catch (_) {
      throw const BusinessRuleException(
        'Réponse inattendue de Google Analytics.',
      );
    }
  }

  /// Message lisible pour une réponse d'erreur de l'API.
  static AppException errorFor(int status, String body) {
    var detail = '';
    try {
      final j = jsonDecode(body);
      final err = j is Map ? j['error'] : null;
      detail = err is Map ? (err['message'] ?? '').toString() : '';
    } catch (_) {
      // Corps illisible : le code HTTP suffit.
    }
    final suffix = detail.isEmpty ? '' : ' : $detail';
    return BusinessRuleException(switch (status) {
      401 => "L'autorisation Google a expiré. Reconnectez-vous.",
      403 =>
        'Accès refusé par Google. Vérifiez que ce compte a accès à la '
            'propriété Analytics, et que « Google Analytics Data API » est '
            'activée dans le projet Google Cloud.',
      404 =>
        'Propriété Google Analytics introuvable : vérifiez GA_PROPERTY_ID.',
      429 => 'Quota Google Analytics atteint. Réessayez dans quelques minutes.',
      400 => 'Google a refusé la requête$suffix.',
      _ => 'Google Analytics a répondu $status$suffix.',
    });
  }
}

/// Une ligne d'un rapport : valeurs des dimensions puis des métriques.
class GaRow {
  const GaRow(this.dims, this.metrics);
  final List<String> dims;
  final List<double> metrics;
}

/// Tableau renvoyé par l'API (`runReport` / `runRealtimeReport`).
class GaTable {
  const GaTable({
    required this.dimensionNames,
    required this.metricNames,
    required this.rows,
  });

  final List<String> dimensionNames;
  final List<String> metricNames;
  final List<GaRow> rows;

  factory GaTable.fromJson(Map<String, dynamic> j) {
    List<String> names(String key) => [
      for (final h in (j[key] as List? ?? const []).whereType<Map>())
        h['name'].toString(),
    ];
    List<String> values(Object? list) => [
      for (final v in (list as List? ?? const []).whereType<Map>())
        (v['value'] ?? '').toString(),
    ];
    return GaTable(
      dimensionNames: names('dimensionHeaders'),
      metricNames: names('metricHeaders'),
      rows: [
        for (final r in (j['rows'] as List? ?? const []).whereType<Map>())
          GaRow(values(r['dimensionValues']), [
            for (final v in values(r['metricValues'])) double.tryParse(v) ?? 0,
          ]),
      ],
    );
  }

  /// Valeur d'une métrique par son nom dans la ligne [row].
  double metric(GaRow row, String name) {
    final i = metricNames.indexOf(name);
    return i < 0 || i >= row.metrics.length ? 0 : row.metrics[i];
  }

  /// Total d'une métrique sur toutes les lignes.
  double sum(String name) => rows.fold(0, (s, r) => s + metric(r, name));
}

/// Produit tel que Google Analytics le voit.
class GaItem {
  const GaItem({
    required this.name,
    required this.viewed,
    required this.addedToCart,
    required this.purchased,
    required this.revenue,
  });
  final String name;
  final int viewed;
  final int addedToCart;
  final int purchased;
  final double revenue;
}

/// Compteur d'un événement vu par Google Analytics.
class GaEvent {
  const GaEvent(this.name, this.count, this.users);
  final String name;
  final int count;
  final int users;
}

/// Rapport Google Analytics sur une période.
class GaReport {
  const GaReport({
    required this.days,
    required this.activeUsers,
    required this.newUsers,
    required this.sessions,
    required this.eventCount,
    required this.events,
    required this.items,
    required this.daily,
    required this.devices,
  });

  final int days;
  final int activeUsers;
  final int newUsers;
  final int sessions;
  final int eventCount;
  final List<GaEvent> events;
  final List<GaItem> items;

  /// (jour `aaaa-mm-jj`, utilisateurs actifs, événements)
  final List<(String, int, int)> daily;

  /// (catégorie d'appareil, utilisateurs actifs)
  final List<(String, int)> devices;

  /// Un événement peut mettre plusieurs heures à apparaître dans les
  /// rapports : un rapport vide ne veut pas dire que l'envoi échoue.
  bool get isEmpty => eventCount == 0 && events.isEmpty;

  int count(String event) =>
      events.where((e) => e.name == event).fold(0, (s, e) => s + e.count);

  factory GaReport.fromTables({
    required int days,
    required GaTable overview,
    required GaTable events,
    required GaTable items,
    required GaTable daily,
    required GaTable devices,
  }) {
    final o = overview.rows.isEmpty ? null : overview.rows.first;
    int m(String n) => o == null ? 0 : overview.metric(o, n).round();
    String first(GaRow r) => r.dims.isEmpty ? '' : r.dims.first;
    return GaReport(
      days: days,
      activeUsers: m('activeUsers'),
      newUsers: m('newUsers'),
      sessions: m('sessions'),
      eventCount: m('eventCount'),
      events: [
        for (final r in events.rows)
          GaEvent(
            first(r),
            events.metric(r, 'eventCount').round(),
            events.metric(r, 'totalUsers').round(),
          ),
      ],
      items: [
        for (final r in items.rows)
          if (first(r).isNotEmpty && first(r) != '(not set)')
            GaItem(
              name: first(r),
              viewed: items.metric(r, 'itemsViewed').round(),
              addedToCart: items.metric(r, 'itemsAddedToCart').round(),
              purchased: items.metric(r, 'itemsPurchased').round(),
              revenue: items.metric(r, 'itemRevenue'),
            ),
      ],
      daily: [
        for (final r in daily.rows)
          (
            formatDate(first(r)),
            daily.metric(r, 'activeUsers').round(),
            daily.metric(r, 'eventCount').round(),
          ),
      ],
      devices: [
        for (final r in devices.rows)
          (first(r), devices.metric(r, 'activeUsers').round()),
      ],
    );
  }

  /// `20261025` → `2026-10-25`.
  static String formatDate(String d) => d.length == 8
      ? '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6)}'
      : d;
}

/// Activité des 30 dernières minutes.
class GaRealtime {
  const GaRealtime({required this.activeUsers, required this.events});
  final int activeUsers;
  final List<GaEvent> events;

  factory GaRealtime.fromTables({
    required GaTable users,
    required GaTable events,
  }) => GaRealtime(
    activeUsers: users.sum('activeUsers').round(),
    events: [
      for (final r in events.rows)
        GaEvent(
          r.dims.isEmpty ? '' : r.dims.first,
          events.metric(r, 'eventCount').round(),
          0,
        ),
    ],
  );
}
