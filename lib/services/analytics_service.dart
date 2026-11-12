import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../models/analytics.dart';
import '../models/course.dart';
import '../models/shop.dart';
import 'backend.dart';

/// Mesure d'audience de GymFlow.
///
/// Chaque événement est enregistré à **deux endroits**, avec deux niveaux de
/// garantie différents :
///
/// 1. **Dans l'application** : un compteur agrégé et anonyme par jour (voir
///    [AnalyticsCounter]). Aucun identifiant de compte, aucun appareil :
///    impossible de reconstituer le parcours d'une personne. Alimente
///    l'onglet « GymFlow » des statistiques, instantanément.
/// 2. **Chez Google Analytics 4** (API Measurement Protocol), seulement si
///    la personne a activé « Mesure d'audience » dans ses réglages de
///    confidentialité **et** que les clés sont configurées. L'identifiant
///    envoyé est une empreinte du compte, jamais le compte lui-même ; ni
///    nom, ni e-mail, ni contenu de message n'est transmis.
///
/// Seuls les **abonnés** sont mesurés : les actions d'un coach ou de
/// l'administrateur (créer un produit, valider un contenu) ne sont pas du
/// comportement d'usage et fausseraient les chiffres.
///
/// Aucune méthode ne lève d'erreur et aucune n'attend le réseau : mesurer ne
/// doit jamais ralentir ni casser l'application.
class AnalyticsService {
  AnalyticsService(this._b);
  final Backend _b;

  /// Clés de Google Analytics (remplaçables dans les tests).
  String measurementId = AppConfig.gaMeasurementId;
  String apiSecret = AppConfig.gaApiSecret;

  static const _collect = 'https://www.google-analytics.com/mp/collect';
  static const _debug = 'https://www.google-analytics.com/debug/mp/collect';

  bool get canSend =>
      measurementId.trim().isNotEmpty && apiSecret.trim().isNotEmpty;

  /// Session de l'application : l'heure de la première mesure, en secondes.
  late final String sessionId = (_b.now().millisecondsSinceEpoch ~/ 1000)
      .toString();

  // ----------------------------------------------------------- Boutique

  void viewItem(Product p) => _emit(
    AnalyticsEvents.viewItem,
    key: p.id,
    label: p.name,
    google: _itemParams([_item(p)], value: p.effectivePrice),
  );

  void addToCart(Product p, int quantity) => _emit(
    AnalyticsEvents.addToCart,
    key: p.id,
    label: p.name,
    by: quantity,
    google: _itemParams([
      _item(p, quantity: quantity),
    ], value: p.effectivePrice * quantity),
  );

  /// Commande payée : une mesure par ligne en local (pour classer les
  /// produits), une seule `purchase` complète chez Google.
  void purchase(ShopOrder o) {
    for (final l in o.lines) {
      _emit(
        AnalyticsEvents.purchaseItem,
        key: l.productId,
        label: l.name,
        by: l.quantity,
        value: l.total,
        toGoogle: false,
      );
    }
    _emit(
      AnalyticsEvents.purchase,
      key: '',
      label: 'Commandes',
      // Chiffre d'affaires hors timbre fiscal (taxe reversée à l'État),
      // comme le tableau de bord ; le timbre part à Google dans `tax`.
      value: o.netSales,
      google: {
        'transaction_id': o.number,
        'currency': 'TND',
        'value': _money(o.netSales),
        if (o.stamp > 0) 'tax': _money(o.stamp),
        'items': [
          for (final l in o.lines)
            {
              'item_id': l.productId,
              'item_name': _cut(l.name),
              'price': _money(l.unitPrice),
              'quantity': l.quantity,
            },
        ],
      },
    );
  }

  // -------------------------------------------------------------- Cours

  void viewCourse(Course c) => _emit(
    AnalyticsEvents.courseView,
    key: c.id,
    label: c.title,
    google: _courseParams(c),
  );

  void reserveCourse(Course c, {required bool waitlisted}) => _emit(
    waitlisted ? AnalyticsEvents.courseWaitlist : AnalyticsEvents.courseReserve,
    key: c.id,
    label: c.title,
    google: _courseParams(c),
  );

  void cancelReservation(Course c) => _emit(
    AnalyticsEvents.courseCancel,
    key: c.id,
    label: c.title,
    google: _courseParams(c),
  );

  // ------------------------------------------------------- Entraînement

  void workoutStart(String name) => _emit(
    AnalyticsEvents.workoutStart,
    key: _norm(name),
    label: name,
    google: {'workout_name': _cut(name)},
  );

  void workoutComplete(String name) => _emit(
    AnalyticsEvents.workoutComplete,
    key: _norm(name),
    label: name,
    google: {'workout_name': _cut(name)},
  );

  void shareSession() => _emit(AnalyticsEvents.sessionShare);

  // ---------------------------------------------------------- Recherche

  /// Mesure une recherche. Le terme est normalisé et raccourci : il peut
  /// contenir ce que la personne a tapé, donc on n'en garde que 30
  /// caractères, et rien du tout en dessous de deux lettres.
  void search(String term, {required int results}) {
    final t = _norm(term);
    if (t.length < 2) return;
    _emit(AnalyticsEvents.search, key: t, label: t, google: {'search_term': t});
    if (results == 0) {
      _emit(AnalyticsEvents.searchEmpty, key: t, label: t, toGoogle: false);
    }
  }

  // ------------------------------------------------------------- Compte

  /// [method] : `password` ou `google`.
  void login(String method) => _emit(
    AnalyticsEvents.login,
    key: method,
    label: method,
    google: {'method': method},
  );

  void signUp(String method) => _emit(
    AnalyticsEvents.signUp,
    key: method,
    label: method,
    google: {'method': method},
  );

  /// On compte les questions posées à l'assistant ; leur contenu n'est
  /// jamais enregistré ni envoyé.
  void chatQuestion() => _emit(AnalyticsEvents.chatQuestion);

  // ------------------------------------------------- Envoi vers Google

  /// Empreinte stable et non réversible du compte, utilisée comme
  /// identifiant anonyme chez Google. Google ne voit jamais l'identifiant
  /// réel, et ne peut pas le retrouver.
  static String clientIdFor(String userId) {
    final h = sha256.convert(utf8.encode('gymflow-ga|$userId')).toString();
    return '${h.substring(0, 10)}.${h.substring(10, 20)}';
  }

  /// Corps d'une requête Measurement Protocol (testé tel quel contre le
  /// point de validation de Google).
  static Map<String, Object?> buildPayload({
    required String clientId,
    required String name,
    required String sessionId,
    required String deviceCategory,
    Map<String, Object?> params = const {},
  }) => {
    'client_id': clientId,
    'device': {'category': deviceCategory},
    'events': [
      {
        'name': name,
        'params': {
          // Sans durée d'engagement, Google ne compte pas la personne comme
          // utilisateur actif.
          'engagement_time_msec': 100,
          'session_id': sessionId,
          ...params,
        },
      },
    ],
  };

  String get _deviceCategory => kIsWeb ? 'desktop' : 'mobile';

  Future<void> _send(String name, Map<String, Object?> params) async {
    final me = _b.auth.currentUser;
    if (!canSend || me == null || !me.isMember || !me.privacy.analytics) return;
    await _post(
      _collect,
      clientId: clientIdFor(me.id),
      name: name,
      params: params,
    );
  }

  Future<http.Response> _post(
    String base, {
    required String clientId,
    required String name,
    Map<String, Object?> params = const {},
  }) {
    final uri = Uri.parse(
      '$base?measurement_id=${Uri.encodeQueryComponent(measurementId.trim())}'
      '&api_secret=${Uri.encodeQueryComponent(apiSecret.trim())}',
    );
    // `text/plain` : requête « simple » pour un navigateur, donc sans
    // pré-requête CORS (que Google refuse pour du JSON déclaré). Le corps
    // reste du JSON, lu normalement par Google.
    return _b.httpClient
        .post(
          uri,
          headers: const {'Content-Type': 'text/plain;charset=UTF-8'},
          body: jsonEncode(
            buildPayload(
              clientId: clientId,
              name: name,
              sessionId: sessionId,
              deviceCategory: _deviceCategory,
              params: params,
            ),
          ),
        )
        .timeout(const Duration(seconds: 8));
  }

  /// Bouton de test de l'administrateur : valide le format auprès de
  /// Google, puis envoie un événement `gymflow_test`. Ne contient aucune
  /// donnée personnelle ; l'administrateur le déclenche lui-même, ce qui
  /// tient lieu de consentement pour ce seul événement.
  Future<AnalyticsTestResult> sendTest() async {
    _b.requireRole(Backend.adminOnly);
    if (!canSend) {
      return const AnalyticsTestResult(
        ok: false,
        message:
            'Clés absentes : ajoutez GA_MEASUREMENT_ID et GA_API_SECRET dans '
            'secrets.json, puis relancez l\'application.',
      );
    }
    final me = _b.requireUser();
    try {
      final check = await _post(
        _debug,
        clientId: clientIdFor(me.id),
        name: AnalyticsEvents.test,
      );
      final messages = _validationMessages(check.body);
      if (messages.isNotEmpty) {
        return AnalyticsTestResult(
          ok: false,
          message: 'Google refuse le format : ${messages.join(' ; ')}',
        );
      }
      final sent = await _post(
        _collect,
        clientId: clientIdFor(me.id),
        name: AnalyticsEvents.test,
      );
      final ok = sent.statusCode >= 200 && sent.statusCode < 300;
      return AnalyticsTestResult(
        ok: ok,
        message: ok
            ? 'Événement de test envoyé. Actualisez « En direct » : il doit '
                  'apparaître sous quelques secondes.'
            : 'Google a répondu ${sent.statusCode}.',
      );
    } catch (_) {
      return const AnalyticsTestResult(
        ok: false,
        message: 'Impossible de joindre Google. Vérifiez la connexion.',
      );
    }
  }

  static List<String> _validationMessages(String body) {
    try {
      final j = jsonDecode(body);
      final list = (j is Map ? j['validationMessages'] : null) as List? ?? [];
      return [
        for (final m in list.whereType<Map>())
          '${m['fieldPath'] ?? ''} ${m['description'] ?? ''}'.trim(),
      ];
    } catch (_) {
      return const [];
    }
  }

  // ------------------------------------------------ Enregistrement local

  /// Enregistre l'événement (compteur local) puis, si la personne y a
  /// consenti, l'envoie à Google. Jamais bloquant, jamais en erreur.
  void _emit(
    String name, {
    String key = '',
    String label = '',
    int by = 1,
    double value = 0,
    Map<String, Object?> google = const {},
    bool toGoogle = true,
  }) {
    final task = () async {
      try {
        await _record(name, key: key, label: label, by: by, value: value);
        if (toGoogle) await _send(name, google);
      } catch (e) {
        // Mesurer ne doit jamais faire échouer ce que la personne fait.
        if (kDebugMode) debugPrint('[Analytics] $name : $e');
      }
    }();
    _pending.add(task);
    unawaited(task.whenComplete(() => _pending.remove(task)));
  }

  final Set<Future<void>> _pending = {};

  /// Attend la fin des mesures en cours (les tests ; l'application, elle,
  /// n'attend jamais).
  Future<void> idle() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  Future<void> _record(
    String name, {
    required String key,
    required String label,
    required int by,
    required double value,
  }) async {
    final me = _b.auth.currentUser;
    if (me == null || !me.isMember) return;
    final day = dayOf(_b.now());
    final id = '$day|$name|$key';
    final current =
        _b.analyticsRepo.byId(id) ??
        AnalyticsCounter(
          day: day,
          name: name,
          key: key,
          label: label,
          count: 0,
        );
    await _b.analyticsRepo.save(
      current.add(label: label, value: value, by: by),
    );
  }

  /// Supprime les compteurs de plus de [keepDays] jours : les statistiques
  /// restent légères, et rien n'est conservé plus longtemps que nécessaire.
  Future<int> purgeOlderThan({int keepDays = 180}) async {
    final limit = dayOf(_b.now().subtract(Duration(days: keepDays)));
    final old = _b.analyticsRepo.where((c) => c.day.compareTo(limit) < 0);
    for (final c in old) {
      await _b.analyticsRepo.delete(c.id);
    }
    return old.length;
  }

  // ------------------------------------------------------ Lecture locale

  /// Synthèse des [days] derniers jours, calculée sur les compteurs.
  LocalAnalytics summary({int days = 14}) {
    final now = _b.now();
    final from = dayOf(now.subtract(Duration(days: days - 1)));
    final rows = _b.analyticsRepo.where((c) => c.day.compareTo(from) >= 0);

    final totals = <String, int>{};
    final perDay = <String, int>{
      for (var i = days - 1; i >= 0; i--)
        dayOf(now.subtract(Duration(days: i))): 0,
    };
    final products = <String, _Acc>{};
    final courses = <String, _Acc>{};
    final searches = <String, int>{};
    final emptySearches = <String, int>{};
    final logins = <String, int>{};
    final signups = <String, int>{};
    var revenue = 0.0;
    var orders = 0;

    for (final c in rows) {
      totals.update(c.name, (n) => n + c.count, ifAbsent: () => c.count);
      // Le détail par produit est l'affaire des lignes ; la commande
      // entière ne compte qu'une fois dans l'activité du jour.
      if (c.name != AnalyticsEvents.purchaseItem &&
          c.name != AnalyticsEvents.test) {
        perDay.update(c.day, (n) => n + c.count, ifAbsent: () => c.count);
      }
      switch (c.name) {
        case AnalyticsEvents.viewItem:
          products.putIfAbsent(c.key, () => _Acc(c.label)).views += c.count;
        case AnalyticsEvents.addToCart:
          products.putIfAbsent(c.key, () => _Acc(c.label)).carts += c.count;
        case AnalyticsEvents.purchaseItem:
          final a = products.putIfAbsent(c.key, () => _Acc(c.label));
          a.purchased += c.count;
          a.revenue += c.value;
        case AnalyticsEvents.purchase:
          orders += c.count;
          revenue += c.value;
        case AnalyticsEvents.courseView:
          courses.putIfAbsent(c.key, () => _Acc(c.label)).views += c.count;
        case AnalyticsEvents.courseReserve:
          courses.putIfAbsent(c.key, () => _Acc(c.label)).purchased += c.count;
        case AnalyticsEvents.courseWaitlist:
          courses.putIfAbsent(c.key, () => _Acc(c.label)).carts += c.count;
        case AnalyticsEvents.courseCancel:
          courses.putIfAbsent(c.key, () => _Acc(c.label)).revenue += c.count;
        case AnalyticsEvents.search:
          searches.update(c.key, (n) => n + c.count, ifAbsent: () => c.count);
        case AnalyticsEvents.searchEmpty:
          emptySearches.update(
            c.key,
            (n) => n + c.count,
            ifAbsent: () => c.count,
          );
        case AnalyticsEvents.login:
          logins.update(c.key, (n) => n + c.count, ifAbsent: () => c.count);
        case AnalyticsEvents.signUp:
          signups.update(c.key, (n) => n + c.count, ifAbsent: () => c.count);
      }
    }

    List<(String, int)> ranked(Map<String, int> m) =>
        (m.entries.map((e) => (e.key, e.value)).toList()
          ..sort((a, b) => b.$2.compareTo(a.$2)));

    return LocalAnalytics(
      days: days,
      totals: totals,
      perDay: [for (final e in perDay.entries) (e.key, e.value)],
      products: [
        for (final e in products.entries)
          ProductActivity(
            id: e.key,
            name: e.value.label,
            views: e.value.views,
            carts: e.value.carts,
            purchased: e.value.purchased,
            revenue: e.value.revenue,
          ),
      ]..sort(ProductActivity.byInterest),
      courses: [
        for (final e in courses.entries)
          CourseActivity(
            id: e.key,
            title: e.value.label,
            views: e.value.views,
            reservations: e.value.purchased,
            waitlisted: e.value.carts,
            cancellations: e.value.revenue.round(),
          ),
      ]..sort((a, b) => b.views.compareTo(a.views)),
      searches: ranked(searches),
      emptySearches: ranked(emptySearches),
      logins: logins,
      signups: signups,
      orders: orders,
      revenue: revenue,
    );
  }

  // ------------------------------------------------------------ Outils

  static String dayOf(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Terme normalisé : minuscules, espaces simplifiés, 30 caractères au plus.
  static String _norm(String s) {
    final t = s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > 30 ? t.substring(0, 30) : t;
  }

  /// Google limite les valeurs de paramètres à 100 caractères.
  static String _cut(String s) => s.length > 100 ? s.substring(0, 100) : s;

  /// Montant arrondi à 3 décimales (le millime), sans bruit de virgule
  /// flottante.
  static double _money(double v) => (v * 1000).round() / 1000;

  Map<String, Object?> _item(Product p, {int quantity = 1}) => {
    'item_id': p.id,
    'item_name': _cut(p.name),
    'item_category': p.category.label,
    'price': _money(p.effectivePrice),
    'quantity': quantity,
  };

  Map<String, Object?> _itemParams(
    List<Map<String, Object?>> items, {
    required double value,
  }) => {'currency': 'TND', 'value': _money(value), 'items': items};

  Map<String, Object?> _courseParams(Course c) => {
    'course_id': c.id,
    'course_name': _cut(c.title),
    'course_category': c.category.label,
  };
}

/// Résultat du bouton de test de l'administrateur.
class AnalyticsTestResult {
  const AnalyticsTestResult({required this.ok, required this.message});
  final bool ok;
  final String message;
}

/// Cumul interne pendant le calcul de la synthèse.
class _Acc {
  _Acc(this.label);
  final String label;
  int views = 0;
  int carts = 0;
  int purchased = 0;
  double revenue = 0;
}

/// Activité d'un produit : vues, ajouts au panier, unités achetées.
class ProductActivity {
  const ProductActivity({
    required this.id,
    required this.name,
    required this.views,
    required this.carts,
    required this.purchased,
    required this.revenue,
  });

  final String id;
  final String name;
  final int views;
  final int carts;
  final int purchased;
  final double revenue;

  /// Part des vues qui finissent en achat, ou null sans vue.
  double? get conversion => views == 0 ? null : purchased / views;

  /// Du plus regardé au moins regardé, puis du plus acheté.
  static int byInterest(ProductActivity a, ProductActivity b) {
    final v = b.views.compareTo(a.views);
    return v != 0 ? v : b.purchased.compareTo(a.purchased);
  }
}

/// Activité d'un cours : vues, réservations, liste d'attente, annulations.
class CourseActivity {
  const CourseActivity({
    required this.id,
    required this.title,
    required this.views,
    required this.reservations,
    required this.waitlisted,
    required this.cancellations,
  });

  final String id;
  final String title;
  final int views;
  final int reservations;
  final int waitlisted;
  final int cancellations;
}

/// Synthèse locale affichée dans l'onglet « GymFlow » des statistiques.
class LocalAnalytics {
  const LocalAnalytics({
    required this.days,
    required this.totals,
    required this.perDay,
    required this.products,
    required this.courses,
    required this.searches,
    required this.emptySearches,
    required this.logins,
    required this.signups,
    required this.orders,
    required this.revenue,
  });

  final int days;
  final Map<String, int> totals;
  final List<(String day, int events)> perDay;
  final List<ProductActivity> products;
  final List<CourseActivity> courses;
  final List<(String term, int count)> searches;
  final List<(String term, int count)> emptySearches;
  final Map<String, int> logins;
  final Map<String, int> signups;
  final int orders;
  final double revenue;

  int total(String event) => totals[event] ?? 0;

  /// Parcours d'achat : produits vus, mis au panier, achetés (en unités).
  int get views => total(AnalyticsEvents.viewItem);
  int get carts => total(AnalyticsEvents.addToCart);
  int get purchasedUnits => total(AnalyticsEvents.purchaseItem);

  bool get isEmpty => totals.isEmpty;
}
