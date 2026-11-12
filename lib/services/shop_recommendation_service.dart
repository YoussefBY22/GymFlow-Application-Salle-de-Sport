import 'dart:convert';

import '../core/formatters.dart';
import '../models/enums.dart';
import '../models/shop.dart';
import 'backend.dart';
import 'gemini_client.dart';
import 'product_ai_service.dart';

/// Règle d'association « qui achète A achète aussi B », calculée sur les
/// paniers passés (une commande = un panier).
class AssociationRule {
  const AssociationRule({
    required this.from,
    required this.to,
    required this.count,
    required this.support,
    required this.confidence,
    required this.lift,
  });

  final String from;
  final String to;

  /// Nombre de paniers contenant A et B.
  final int count;

  /// Part des paniers contenant A et B.
  final double support;

  /// P(B | A) : part des paniers contenant A qui contiennent aussi B.
  final double confidence;

  /// Confiance / P(B) : > 1 si B est acheté avec A plus souvent qu'en
  /// moyenne.
  final double lift;
}

/// Produit recommandé et raison calculée par le code (affichée telle
/// quelle, ou reformulée par l'IA sans changer le fond).
class ShopRecommendation {
  const ShopRecommendation({
    required this.product,
    required this.reason,
    required this.score,
  });

  final Product product;
  final String reason;
  final double score;
}

/// Recommandations de la boutique : « Souvent achetés ensemble » (règles
/// d'association) et « Pour votre objectif » (objectif, assiduité et
/// valeurs nutritionnelles). Le code calcule et décide ; Gemini ne fait,
/// en option, que reformuler la raison.
class ShopRecommendationService {
  ShopRecommendationService(this._b);
  final Backend _b;

  /// En dessous de ce nombre de commandes, aucune association n'est
  /// proposée : les pourcentages ne seraient pas significatifs.
  static const minBaskets = 20;
  static const minPairCount = 2;
  static const minConfidence = 0.2;

  /// Produits « protéinés » : au moins 20 g de protéines pour 100 g.
  static const proteinRich = 20.0;
  static const activityWindow = Duration(days: 14);
  static const recentPurchase = Duration(days: 30);

  // ------------------------------------------------ Achetés ensemble

  /// Règles A → B retenues : seuil minimal de paniers, paire vue au moins
  /// [minPairCount] fois, confiance ≥ [minConfidence] et lift > 1.
  static List<AssociationRule> associationRules(Iterable<Set<String>> baskets) {
    final list = baskets.where((s) => s.isNotEmpty).toList();
    final n = list.length;
    if (n < minBaskets) return const [];
    final single = <String, int>{};
    final pairs = <String, int>{};
    for (final basket in list) {
      final ids = basket.toList()..sort();
      for (final a in ids) {
        single[a] = (single[a] ?? 0) + 1;
      }
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          final k = '${ids[i]}|${ids[j]}';
          pairs[k] = (pairs[k] ?? 0) + 1;
        }
      }
    }
    final rules = <AssociationRule>[];
    for (final e in pairs.entries) {
      if (e.value < minPairCount) continue;
      final [a, b] = e.key.split('|');
      for (final (from, to) in [(a, b), (b, a)]) {
        final confidence = e.value / single[from]!;
        final lift = confidence / (single[to]! / n);
        if (confidence < minConfidence || lift <= 1) continue;
        rules.add(
          AssociationRule(
            from: from,
            to: to,
            count: e.value,
            support: e.value / n,
            confidence: confidence,
            lift: lift,
          ),
        );
      }
    }
    return rules..sort((x, y) {
      final c = y.confidence.compareTo(x.confidence);
      return c != 0 ? c : y.lift.compareTo(x.lift);
    });
  }

  /// « Souvent achetés ensemble » pour la fiche produit.
  List<ShopRecommendation> boughtTogether(String productId, {int limit = 4}) {
    _b.requireUser();
    final baskets = _b.orders.all.map(
      (o) => o.lines.map((l) => l.productId).toSet(),
    );
    final result = <ShopRecommendation>[];
    for (final r in associationRules(baskets)) {
      if (r.from != productId) continue;
      final p = _b.products.byId(r.to);
      if (p == null || !p.active || !p.inStock) continue;
      final pct = (r.confidence * 100).round();
      result.add(
        ShopRecommendation(
          product: p,
          score: r.confidence * r.lift,
          reason:
              'Présent dans $pct % des commandes contenant ce produit, '
              '${Fmt.dec1(r.lift)} fois plus souvent qu\'en moyenne.',
        ),
      );
      if (result.length == limit) break;
    }
    return result;
  }

  // ------------------------------------------------ Pour votre objectif

  /// Séances terminées par l'abonné ces 14 derniers jours.
  int recentSessions(String userId) {
    final now = _b.now();
    final since = now.subtract(activityWindow);
    return _b.sessions
        .where(
          (s) =>
              s.userId == userId &&
              !s.startedAt.isBefore(since) &&
              !s.startedAt.isAfter(now),
        )
        .length;
  }

  /// Sélection selon l'objectif de l'abonné, sans les produits inactifs,
  /// en rupture ou achetés depuis moins de 30 jours (sauf boissons).
  List<ShopRecommendation> forGoal({int limit = 6}) {
    final me = _b.requireUser();
    final now = _b.now();
    final sessions = recentSessions(me.id);
    final bought = {
      for (final o in _b.orders.where(
        (o) =>
            o.userId == me.id &&
            o.createdAt.isAfter(now.subtract(recentPurchase)),
      ))
        for (final l in o.lines) l.productId,
    };
    final candidates = _b.products.where(
      (p) =>
          p.active &&
          p.inStock &&
          (p.category == ProductCategory.drinks || !bought.contains(p.id)),
    );
    // Meilleur prix du gramme de protéine du catalogue (référence).
    final prices = candidates
        .where(_isProteinRich)
        .map((p) => p.pricePerProteinGram)
        .whereType<double>();
    final bestPrice = prices.isEmpty
        ? null
        : prices.reduce((a, b) => a < b ? a : b);
    final result = <ShopRecommendation>[];
    for (final p in candidates) {
      final r = _score(p, me.goal, sessions, bestPrice);
      if (r != null) result.add(r);
    }
    result.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.product.name.compareTo(b.product.name);
    });
    return result.take(limit).toList();
  }

  static bool _isProteinRich(Product p) =>
      (p.nutrition?.proteins ?? 0) >= proteinRich;

  /// Score et raison d'un produit pour un objectif ; null s'il ne convient
  /// pas. Toutes les valeurs citées viennent des calculs du code.
  ShopRecommendation? _score(
    Product p,
    Goal goal,
    int sessions,
    double? bestPrice,
  ) {
    final n = p.nutrition;
    final protein = _isProteinRich(p);
    final sugar = n?.sugarLevel;
    final perGram = p.pricePerProteinGram;
    String proteinFacts() {
      final base = '${_g(n!.proteins!)} g de protéines pour 100 g';
      return perGram == null
          ? base
          : '$base, ${_dt(perGram)} DT le gramme de protéine';
    }

    double valueBonus() =>
        perGram == null || bestPrice == null ? 0 : 2 * bestPrice / perGram;

    double score;
    String reason;
    switch (goal) {
      case Goal.muscleGain:
        if (protein) {
          score = 4 + valueBonus() - (sugar == 'élevé' ? 1 : 0);
          reason =
              'Riche en protéines (${proteinFacts()}) : adapté à la prise de '
              'masse.';
        } else if (p.category == ProductCategory.supplements) {
          score = 2.5;
          reason =
              'Complément souvent choisi pour la force et la prise de masse.';
        } else if (p.category == ProductCategory.accessories) {
          score = 1;
          reason = 'Accessoire utile pour les séances de musculation.';
        } else {
          return null;
        }
      case Goal.weightLoss:
        if (sugar == 'élevé') return null;
        if (protein && sugar == 'faible') {
          score = 3.5 + valueBonus() / 2;
          reason =
              'Faible en sucres (${_g(n!.sugars!)} g pour 100 g) et riche en '
              'protéines : une collation adaptée à la perte de poids.';
        } else if (p.category == ProductCategory.accessories) {
          score = 2.5;
          reason = 'Accessoire pour bouger plus, à la salle comme à la maison.';
        } else if (p.category == ProductCategory.drinks) {
          score = 1.5;
          reason = sugar == null
              ? 'Pour rester hydraté pendant l\'effort.'
              : 'Pour rester hydraté pendant l\'effort (sucres : niveau '
                    '$sugar).';
        } else {
          return null;
        }
      case Goal.endurance:
        if (p.category == ProductCategory.drinks) {
          score = 4;
          reason = 'Réhydratation pendant les efforts longs.';
        } else if (p.category == ProductCategory.accessories) {
          score = 2;
          reason = 'Accessoire pour le cardio et l\'endurance.';
        } else if (protein) {
          score = 1.5 + valueBonus() / 2;
          reason = 'Pour la récupération après l\'effort (${proteinFacts()}).';
        } else {
          return null;
        }
      case Goal.fitness:
        if (p.category == ProductCategory.accessories) {
          score = 2.5;
          reason = 'Accessoire polyvalent pour garder la forme.';
        } else if (p.category == ProductCategory.drinks) {
          score = 1.5;
          reason = 'Pour rester hydraté pendant les séances.';
        } else if (protein && sugar != 'élevé') {
          score = 1.5 + valueBonus() / 2;
          reason = 'Une source de protéines pratique (${proteinFacts()}).';
        } else if (p.category == ProductCategory.clothing) {
          score = 1;
          reason = 'Une tenue confortable pour vos séances.';
        } else {
          return null;
        }
    }
    // Assiduité des 14 derniers jours.
    final recovery = protein || p.category == ProductCategory.drinks;
    if (sessions >= 3 && recovery) {
      score += 1;
      reason +=
          ' Avec $sessions séances ces 14 derniers jours, la récupération '
          'compte.';
    } else if (sessions == 0 && p.category == ProductCategory.accessories) {
      score += 0.5;
      reason += ' Idéal pour reprendre l\'entraînement.';
    }
    if (p.onPromo) score += 0.3;
    return ShopRecommendation(product: p, reason: reason, score: score);
  }

  static String _g(double v) => v == v.roundToDouble()
      ? '${v.toInt()}'
      : v.toStringAsFixed(1).replaceAll('.', ',');

  static String _dt(double v) => v.toStringAsFixed(3).replaceAll('.', ',');

  // ------------------------------------------------ Reformulation (IA)

  final Map<String, String> _phrased = {};

  /// Désactivée pour la session après une erreur (quota, réseau).
  bool _aiDown = false;

  bool get aiEnabled => _b.gemini.enabled && !_aiDown;

  /// Raison reformulée en une phrase par Gemini ; en cas d'absence de clé,
  /// d'erreur ou de réponse non conforme, la raison calculée est renvoyée.
  /// Seules les données du produit et l'objectif sont envoyés.
  Future<String> explain(ShopRecommendation r, {Goal? goal}) async {
    final key = '${r.product.id}|${r.reason}';
    final cached = _phrased[key];
    if (cached != null) return cached;
    if (!aiEnabled) return r.reason;
    final reply = await _b.gemini.generate(
      system:
          'Tu présentes une recommandation de la boutique d\'une salle de '
          'sport tunisienne. ${ProductAiService.rules} Reformule la raison '
          'fournie en une seule phrase de 25 mots au plus, chaleureuse et '
          'sobre, en gardant exactement les mêmes chiffres et sans ajouter '
          'aucune information. Format : {"phrase": "..."}.',
      contents: GeminiClient.userMessage(
        jsonEncode({
          'produit': r.product.name,
          'catégorie': r.product.category.label,
          'objectif': ?goal?.label,
          'raison calculée': r.reason,
        }),
      ),
      temperature: 0.4,
      maxOutputTokens: 200,
      json: true,
      schema: GeminiClient.stringFields(['phrase']),
    );
    if (!reply.ok) {
      _aiDown = true;
      return r.reason;
    }
    final phrase = parsePhrase(reply.text!, r.reason);
    if (phrase == null) return r.reason;
    return _phrased[key] = phrase;
  }

  /// Valide la phrase de l'IA : JSON attendu, longueur raisonnable, sans
  /// lien ni balise, et aucun nombre absent de la raison calculée.
  static String? parsePhrase(String raw, String reason) {
    final s = ProductAiService.cleanText(
      ProductAiService.decodeJson(raw)?['phrase'],
      min: 15,
      max: 220,
    );
    if (s == null) return null;
    final allowed = _numbers(reason);
    return _numbers(s).every(allowed.contains) ? s : null;
  }

  static Set<String> _numbers(String t) =>
      RegExp(r'\d+(?:[.,]\d+)?').allMatches(t).map((m) => m[0]!).toSet();
}
