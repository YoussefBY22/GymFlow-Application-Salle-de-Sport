import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/enums.dart';

/// Produit alimentaire adapté à la récupération musculaire,
/// issu de l'API Open Food Facts.
class RecoveryProduct {
  const RecoveryProduct({
    required this.name,
    required this.imageUrl,
    required this.kcal,
    required this.proteins,
    required this.nutriscore,
    required this.tip,
  });

  final String name;
  final String imageUrl;

  /// Calories pour 100 g (null si non renseigné).
  final double? kcal;

  /// Protéines pour 100 g (null si non renseigné).
  final double? proteins;

  /// Nutriscore (a–e) en minuscule, ou chaîne vide si inconnu.
  final String nutriscore;

  /// Conseil nutritionnel contextuel selon le groupe musculaire travaillé.
  final String tip;
}

/// Service de recommandation nutritionnelle post-entraînement.
///
/// Traduit le muscle travaillé en terme de recherche, interroge
/// Open Food Facts et retourne des produits de récupération adaptés.
///
/// Cache en mémoire par muscle avec TTL de 30 minutes.
/// Les erreurs réseau et d'API sont propagées afin que l'écran puisse
/// distinguer une indisponibilité d'une recherche sans résultat.
class NutritionRecoveryService {
  NutritionRecoveryService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  static const String _baseUrl =
      'https://world.openfoodfacts.org/api/v2/search';
  static const Duration _timeout = Duration(seconds: 10);
  static const Duration _cacheTtl = Duration(minutes: 30);

  /// Cache : muscle → (liste de produits, horodatage).
  final Map<Muscle, (List<RecoveryProduct>, DateTime)> _cache = {};

  // ──────────────────────────────────────────────────────────────────────────
  // Catégories v2 Open Food Facts associées au type de récupération.
  // ──────────────────────────────────────────────────────────────────────────

  static const Map<Muscle, String> _searchCategories = {
    Muscle.chest: 'proteins',
    Muscle.back: 'proteins',
    Muscle.shoulders: 'sports-nutrition',
    Muscle.biceps: 'proteins',
    Muscle.triceps: 'proteins',
    Muscle.quads: 'sports-nutrition',
    Muscle.hamstrings: 'sports-nutrition',
    Muscle.glutes: 'proteins',
    Muscle.calves: 'sports-nutrition',
    Muscle.abs: 'proteins',
    Muscle.fullBody: 'sports-nutrition',
    Muscle.cardio: 'sports-nutrition',
  };

  // ──────────────────────────────────────────────────────────────────────────
  // Conseils nutritionnels contextuels par muscle (en français)
  // ──────────────────────────────────────────────────────────────────────────

  /// Retourne un conseil nutritionnel contextuel pour le muscle travaillé.
  String recoveryTip(Muscle muscle) {
    return switch (muscle) {
      Muscle.chest =>
        '💪 Après un entraînement pectoraux, consommez 20–30 g de protéines '
            'dans les 30 minutes post-effort pour maximiser la synthèse musculaire.',
      Muscle.back =>
        '🔙 Le dos sollicite de nombreuses chaînes musculaires. '
            'Favorisez les protéines complètes (whey, œuf) et hydratez-vous bien.',
      Muscle.shoulders =>
        '🏋️ Les épaules récupèrent mieux avec un apport en acides aminés '
            'essentiels et une anti-inflammation naturelle (oméga-3, curcuma).',
      Muscle.biceps =>
        '💥 Après biceps, une whey isolat à absorption rapide favorise '
            'la reconstruction des fibres. Associez à une banane pour l\'énergie.',
      Muscle.triceps =>
        '🤜 Les triceps apprécient un shake protéiné post-séance, '
            'idéalement 25 g de whey avec quelques dattes pour l\'énergie.',
      Muscle.quads =>
        '🦵 Séance jambes = forte dépense glycogène. Rechargez avec '
            'des glucides complexes (riz, patate douce) et des protéines.',
      Muscle.hamstrings =>
        '🏃 Les ischio-jambiers sont sensibles aux courbatures. '
            'Collagène + vitamine C avant le coucher accélère la récupération.',
      Muscle.glutes =>
        '🍑 Après fessiers, un repas riche en protéines (150–200 g de poulet) '
            'et en glucides (riz complet) dans les 2h post-entraînement est idéal.',
      Muscle.calves =>
        '🦵 Les mollets sollicitent beaucoup le système nerveux. '
            'Magnésium et potassium (banane, eau minérale) réduisent les crampes.',
      Muscle.abs =>
        '🎯 Abdos et déficit calorique vont de pair. Misez sur les protéines '
            'maigres (blanc de poulet, skyr) pour récupérer sans excès calorique.',
      Muscle.fullBody =>
        '🌟 Entraînement complet = récupération complète. '
            'Priorisez un repas équilibré : ½ protéines, ¼ glucides, ¼ légumes.',
      Muscle.cardio =>
        '🏃 Après cardio, réhydratez-vous et rechargez le glycogène avec des '
            'glucides à index glycémique élevé (banane, dattes, jus de fruit).',
    };
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Méthode principale
  // ──────────────────────────────────────────────────────────────────────────

  /// Recherche des produits de récupération adaptés au [muscle] travaillé.
  ///
  /// Retourne une liste de [RecoveryProduct] (max 5).
  Future<List<RecoveryProduct>> searchRecoveryFoods(Muscle muscle) async {
    final cached = _cache[muscle];
    if (cached != null && DateTime.now().difference(cached.$2) < _cacheTtl) {
      return cached.$1;
    }

    final category = _searchCategories[muscle] ?? 'sports-nutrition';
    final tip = recoveryTip(muscle);

    var results = await _searchCategory(category, tip);

    if (results.isEmpty && category != 'sports-nutrition') {
      results = await _searchCategory('sports-nutrition', tip);
    }

    _cache[muscle] = (results, DateTime.now());
    return results;
  }

  Future<List<RecoveryProduct>> _searchCategory(
    String category,
    String tip,
  ) async {
    final uri = Uri.parse(_baseUrl).replace(
      queryParameters: {
        'categories_tags_en': category,
        'page_size': '5',
        'fields':
            'product_name,product_name_fr,nutriments,image_front_url,nutriscore_grade',
      },
    );
    final response = await _client
        .get(uri, headers: const {'User-Agent': 'GymFlow/2.0 (mobile app)'})
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw NutritionRecoveryException(
        'Les suggestions nutritionnelles sont momentanément indisponibles.',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['products'] is! List) {
      throw const FormatException(
        'Les suggestions nutritionnelles sont momentanément indisponibles.',
      );
    }
    return _parseProducts(decoded['products'] as List, tip);
  }

  List<RecoveryProduct> _parseProducts(List products, String tip) => products
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .where((p) {
        final name =
            (p['product_name_fr'] as String? ??
            p['product_name'] as String? ??
            '');
        return name.isNotEmpty;
      })
      .map((p) {
        final name =
            (p['product_name_fr'] as String? ??
            p['product_name'] as String? ??
            'Produit');
        final nutriments = p['nutriments'] is Map
            ? Map<String, dynamic>.from(p['nutriments'] as Map)
            : <String, dynamic>{};
        return RecoveryProduct(
          name: name,
          kcal: _asDouble(nutriments['energy-kcal_100g']),
          proteins: _asDouble(nutriments['proteins_100g']),
          nutriscore: (p['nutriscore_grade'] as String? ?? '').toLowerCase(),
          imageUrl: p['image_front_url'] as String? ?? '',
          tip: tip,
        );
      })
      .take(5)
      .toList();

  double? _asDouble(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value)
        : null;
    return parsed != null && parsed.isFinite && parsed >= 0 ? parsed : null;
  }

  /// Libère le client HTTP sous-jacent.
  void dispose() => _client.close();
}

class NutritionRecoveryException implements Exception {
  const NutritionRecoveryException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
