import 'dart:math' as math;

import '../core/errors.dart';
import '../models/enums.dart';
import '../models/shop.dart';
import 'backend.dart';

/// Classe ABC d'un produit selon sa part du chiffre d'affaires.
enum AbcClass {
  a('A', 'Fait l\'essentiel du chiffre d\'affaires'),
  b('B', 'Ventes intermédiaires'),
  c('C', 'Ventes faibles ou nulles');

  const AbcClass(this.label, this.description);
  final String label;
  final String description;
}

/// Situation du stock, de la plus urgente à la plus confortable.
enum StockStatus {
  outOfStock('Rupture'),
  reorder('À commander'),
  watch('À surveiller'),
  ok('Suffisant');

  const StockStatus(this.label);
  final String label;
}

/// Prévision calculée pour un produit (jamais enregistrée).
class StockForecast {
  const StockForecast({
    required this.product,
    required this.abc,
    required this.sales,
    required this.smoothed,
    required this.dailyDemand,
    required this.deviation,
    required this.safetyStock,
    required this.reorderPoint,
    required this.suggestedQuantity,
    required this.daysToStockout,
    required this.status,
    required this.revenue,
  });

  final Product product;
  final AbcClass abc;

  /// Unités vendues par jour, du plus ancien à aujourd'hui.
  final List<int> sales;

  /// Série lissée (EWMA), même longueur que [sales].
  final List<double> smoothed;

  /// Ventes journalières prévues (dernière valeur lissée).
  final double dailyDemand;

  /// Écart-type des ventes journalières.
  final double deviation;
  final double safetyStock;
  final double reorderPoint;
  final int suggestedQuantity;

  /// Jours avant rupture au rythme actuel ; null sans vente récente.
  final double? daysToStockout;
  final StockStatus status;

  /// Chiffre d'affaires de la période ABC.
  final double revenue;
}

/// Prévision des ruptures de stock (super admin) : ventes journalières
/// lissées, stock de sécurité, seuil de réapprovisionnement, quantité
/// conseillée et analyse ABC. Tout est calculé par le code.
class InventoryForecastService {
  InventoryForecastService(this._b);
  final Backend _b;

  /// Jours de ventes analysés pour la prévision.
  static const historyDays = 60;

  /// Période de l'analyse ABC.
  static const abcDays = 90;

  /// Poids de la vente du jour dans le lissage (EWMA) : 0,1 convient aux
  /// ventes lentes et irrégulières d'une petite boutique (environ
  /// 19 jours de mémoire effective).
  static const alpha = 0.1;

  /// En dessous, le produit est considéré sans vente récente.
  static const minDemand = 0.01;

  /// Coefficient z de la loi normale pour chaque niveau de service (%).
  static const zScores = {90: 1.28, 95: 1.65, 98: 2.05, 99: 2.33};

  static double? zFor(double serviceLevel) =>
      zScores[(serviceLevel * 100).round()];

  InventorySettings get settings =>
      _b.inventorySettings.byId(InventorySettings.id) ??
      const InventorySettings();

  Future<InventorySettings> saveSettings({
    required int leadTimeDays,
    required int coverageDays,
    double serviceLevel = 0.95,
  }) async {
    _b.requireRole(Backend.adminOnly);
    if (leadTimeDays < 1 || leadTimeDays > 60) {
      throw const ValidationException(
        'Délai fournisseur : entre 1 et 60 jours.',
      );
    }
    if (coverageDays < 1 || coverageDays > 90) {
      throw const ValidationException('Couverture : entre 1 et 90 jours.');
    }
    if (zFor(serviceLevel) == null) {
      throw const ValidationException(
        'Niveau de service : 90, 95, 98 ou 99 %.',
      );
    }
    final s = await _b.inventorySettings.save(
      InventorySettings(
        leadTimeDays: leadTimeDays,
        coverageDays: coverageDays,
        serviceLevel: serviceLevel,
      ),
    );
    await _b.audit.log(
      'Réglages du réapprovisionnement',
      'Délai $leadTimeDays j · couverture $coverageDays j · service '
          '${(serviceLevel * 100).round()} %',
    );
    _b.bus.emit();
    return s;
  }

  // ------------------------------------------------ Calculs

  /// Moyenne mobile exponentielle, initialisée sur la moyenne des
  /// 14 premiers jours.
  static List<double> ewma(List<num> values, {double a = alpha}) {
    if (values.isEmpty) return const [];
    final head = values.take(14);
    var s = head.fold<double>(0, (t, v) => t + v) / head.length;
    return [for (final v in values) s = a * v + (1 - a) * s];
  }

  /// Écart-type (échantillon) des ventes journalières.
  static double deviationOf(List<num> values) {
    if (values.length < 2) return 0;
    final mean = values.fold<double>(0, (t, v) => t + v) / values.length;
    final sq = values.fold<double>(0, (t, v) => t + (v - mean) * (v - mean));
    return math.sqrt(sq / (values.length - 1));
  }

  /// Classes ABC : produits triés par CA décroissant ; A jusqu'à 80 % du
  /// CA cumulé, B jusqu'à 95 %, C au-delà (et tout produit sans vente).
  static Map<String, AbcClass> abcClasses(Map<String, double> revenue) {
    final total = revenue.values.fold<double>(0, (t, v) => t + v);
    final sorted = revenue.entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    final result = <String, AbcClass>{};
    var cumulated = 0.0;
    for (final e in sorted) {
      if (total <= 0 || e.value <= 0) {
        result[e.key] = AbcClass.c;
        continue;
      }
      // Classe d'après la part cumulée AVANT le produit : le premier
      // produit est toujours A, même s'il dépasse seul 80 %.
      final before = cumulated / total;
      cumulated += e.value;
      result[e.key] = before < 0.8
          ? AbcClass.a
          : (before < 0.95 ? AbcClass.b : AbcClass.c);
    }
    return result;
  }

  /// Prévision d'un produit à partir de ses ventes journalières.
  static StockForecast compute({
    required Product product,
    required List<int> sales,
    required InventorySettings settings,
    AbcClass abc = AbcClass.c,
    double revenue = 0,
  }) {
    final smoothed = ewma(sales);
    final demand = smoothed.isEmpty ? 0.0 : smoothed.last;
    final sigma = deviationOf(sales);
    final lead = settings.leadTimeDays;
    final z = zFor(settings.serviceLevel) ?? 1.65;
    final safety = z * sigma * math.sqrt(lead);
    final reorderPoint = demand * lead + safety;
    final target = demand * (lead + settings.coverageDays) + safety;
    final suggested = math.max(0, (target - product.stock).ceil());
    final days = demand < minDemand ? null : product.stock / demand;
    final status = product.stock <= 0
        ? StockStatus.outOfStock
        : product.stock <= reorderPoint
        ? StockStatus.reorder
        : days != null && days <= lead + settings.coverageDays
        ? StockStatus.watch
        : StockStatus.ok;
    return StockForecast(
      product: product,
      abc: abc,
      sales: sales,
      smoothed: smoothed,
      dailyDemand: demand,
      deviation: sigma,
      safetyStock: safety,
      reorderPoint: reorderPoint,
      suggestedQuantity: suggested,
      daysToStockout: days,
      status: status,
      revenue: revenue,
    );
  }

  /// Unités vendues par produit et par jour sur [days] jours (dernier
  /// élément = aujourd'hui).
  Map<String, List<int>> dailySales({int days = historyDays}) {
    final now = _b.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(Duration(days: days - 1));
    final result = <String, List<int>>{};
    for (final o in _b.orders.all) {
      final d = DateTime(o.createdAt.year, o.createdAt.month, o.createdAt.day);
      // Différence en jours calendaires (insensible au changement d'heure).
      final i = DateTime.utc(
        d.year,
        d.month,
        d.day,
      ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
      if (i < 0 || i >= days) continue;
      for (final l in o.lines) {
        (result[l.productId] ??= List.filled(days, 0))[i] += l.quantity;
      }
    }
    return result;
  }

  Map<String, double> _revenue() {
    final since = _b.now().subtract(const Duration(days: abcDays));
    final result = <String, double>{};
    for (final o in _b.orders.where((o) => o.createdAt.isAfter(since))) {
      for (final l in o.lines) {
        result[l.productId] = (result[l.productId] ?? 0) + l.total;
      }
    }
    return result;
  }

  /// Prévisions des produits actifs, de la plus urgente à la moins
  /// urgente (jours avant rupture croissants).
  List<StockForecast> forecast() {
    _b.requireRole(Backend.adminOnly);
    return _forecasts(_b.products.where((p) => p.active));
  }

  StockForecast? forProduct(String productId) {
    _b.requireRole(Backend.adminOnly);
    final p = _b.products.byId(productId);
    return p == null ? null : _forecasts([p]).first;
  }

  List<StockForecast> _forecasts(Iterable<Product> products) {
    final sales = dailySales();
    final revenue = _revenue();
    final classes = abcClasses({
      for (final p in _b.products.where((p) => p.active))
        p.id: revenue[p.id] ?? 0,
    });
    final s = settings;
    return [
      for (final p in products)
        compute(
          product: p,
          sales: sales[p.id] ?? List.filled(historyDays, 0),
          settings: s,
          abc: classes[p.id] ?? AbcClass.c,
          revenue: revenue[p.id] ?? 0,
        ),
    ]..sort(compareUrgency);
  }

  /// Rupture d'abord, puis jours avant rupture croissants (sans vente
  /// récente en dernier), puis classe ABC.
  static int compareUrgency(StockForecast x, StockForecast y) {
    final s = x.status.index.compareTo(y.status.index);
    if (s != 0 &&
        (x.status == StockStatus.outOfStock ||
            y.status == StockStatus.outOfStock)) {
      return s;
    }
    final dx = x.daysToStockout ?? double.infinity;
    final dy = y.daysToStockout ?? double.infinity;
    final d = dx.compareTo(dy);
    if (d != 0) return d;
    final c = x.abc.index.compareTo(y.abc.index);
    return c != 0 ? c : x.product.name.compareTo(y.product.name);
  }

  // ------------------------------------------------ Alertes

  /// Prévient les super admins quand un produit vendu passe sous son seuil
  /// de réapprovisionnement (une alerte par produit et par jour). Appelée
  /// après chaque commande, quel que soit le rôle de l'acheteur.
  Future<List<String>> alertIfNeeded(Iterable<String> productIds) async {
    final ids = productIds.toSet();
    final products = _b.products.where((p) => p.active && ids.contains(p.id));
    if (products.isEmpty) return const [];
    final admins = _b.users.where((u) => u.isAdmin && u.active);
    final now = _b.now();
    final alerted = <String>[];
    for (final f in _forecasts(products)) {
      if (f.status != StockStatus.outOfStock &&
          f.status != StockStatus.reorder) {
        continue;
      }
      final p = f.product;
      final sameDay = _b.notificationsRepo.all.any(
        (n) =>
            n.type == NotificationType.stock &&
            n.refId == p.id &&
            n.createdAt.year == now.year &&
            n.createdAt.month == now.month &&
            n.createdAt.day == now.day,
      );
      if (sameDay) continue;
      final days = f.daysToStockout;
      final body = f.status == StockStatus.outOfStock
          ? 'Produit en rupture. Commande conseillée : '
                '${f.suggestedQuantity} unité(s).'
          : 'Reste ${p.stock} unité(s)'
                '${days == null ? '' : ', rupture estimée dans ${days.floor()} j'}'
                '. Commande conseillée : ${f.suggestedQuantity} unité(s).';
      for (final a in admins) {
        await _b.notifications.notify(
          a.id,
          NotificationType.stock,
          f.status == StockStatus.outOfStock
              ? 'Rupture : ${p.name}'
              : 'À réapprovisionner : ${p.name}',
          body,
          route: '/admin/restock',
          refId: p.id,
        );
      }
      alerted.add(p.id);
    }
    return alerted;
  }
}
