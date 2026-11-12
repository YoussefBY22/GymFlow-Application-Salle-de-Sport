import 'dart:math' as math;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/formatters.dart';
import '../models/enums.dart';
import '../models/loyalty.dart';
import '../models/shop.dart';
import '../repositories/repository.dart';
import 'backend.dart';

/// Détail du montant à payer : sous-total, réductions, timbre fiscal.
class CheckoutQuote {
  const CheckoutQuote({
    required this.subtotal,
    required this.stamp,
    this.coupon,
    this.eligibleAmount = 0,
    this.couponDiscount = 0,
    this.pointsUsed = 0,
    this.pointsDiscount = 0,
  });

  final double subtotal;
  final Coupon? coupon;

  /// Part du panier concernée par le code (catégorie, hors promotions).
  final double eligibleAmount;
  final double couponDiscount;
  final int pointsUsed;
  final double pointsDiscount;
  final double stamp;

  double get discount => couponDiscount + pointsDiscount;

  /// Montant payé (le timbre n'est jamais réduit).
  double get total => subtotal - discount + stamp;

  /// Points gagnés : 1 par dinar réellement dépensé, hors timbre.
  int get pointsToEarn =>
      (subtotal - discount).floor() * CouponLoyaltyService.pointsPerDinar;

  String? get label {
    final parts = [
      if (coupon != null) 'Code ${coupon!.code} (${coupon!.shortValue})',
      if (pointsUsed > 0) '$pointsUsed points',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// Fidélité liée à l'assiduité et codes promo. Toutes les règles sont
/// vérifiées ici ; l'utilisation d'un code et des points n'est enregistrée
/// qu'après un paiement accepté (dans `OrderService.placeOrder`).
class CouponLoyaltyService {
  CouponLoyaltyService(this._b);
  final Backend _b;

  static const pointsPerDinar = 1;
  static const pointsPerSession = 10;

  /// Les points s'utilisent par tranches : 100 points = 5 DT.
  static const pointsBlock = 100;
  static const blockValue = 5.0;

  static double pointsValue(int points) => points ~/ pointsBlock * blockValue;

  static double _r2(double v) => (v * 100).roundToDouble() / 100;

  // ------------------------------------------------ Fidélité

  LoyaltyAccount accountOf(String userId) =>
      _b.loyalty.byId(userId) ?? LoyaltyAccount(userId: userId);

  /// Séances terminées pas encore créditées.
  List<String> _uncreditedSessions(String userId) {
    final account = accountOf(userId);
    final now = _b.now();
    return [
      for (final s in _b.sessions.where(
        (s) => s.userId == userId && !s.startedAt.isAfter(now),
      ))
        if (!account.credited(LoyaltyKind.session, s.id)) s.id,
    ];
  }

  /// Solde, séances non encore enregistrées comprises (10 points chacune).
  int balanceOf(String userId) =>
      accountOf(userId).balance +
      _uncreditedSessions(userId).length * pointsPerSession;

  int myBalance() => balanceOf(_b.requireUser().id);

  /// Points utilisables pour un montant à payer (tranches de 100, sans
  /// dépasser le montant).
  int maxRedeemable(String userId, double payable) {
    final byBalance = balanceOf(userId) ~/ pointsBlock;
    final byAmount = (payable / blockValue).floor();
    return math.max(0, math.min(byBalance, byAmount)) * pointsBlock;
  }

  /// Enregistre les séances terminées non créditées (une seule fois par
  /// séance : la séance sert de référence).
  Future<LoyaltyAccount> syncSessions(String userId) async {
    final pending = _uncreditedSessions(userId);
    final account = accountOf(userId);
    if (pending.isEmpty) return account;
    final byId = {for (final s in _b.sessions.all) s.id: s};
    return _b.loyalty.save(
      account.add([
        for (final id in pending)
          LoyaltyEntry(
            kind: LoyaltyKind.session,
            points: pointsPerSession,
            refId: id,
            at: byId[id]!.endedAt,
          ),
      ]),
    );
  }

  /// Historique des points de l'utilisateur connecté (récent d'abord).
  Future<List<LoyaltyEntry>> myHistory() async {
    final me = _b.requireUser();
    final a = await syncSessions(me.id);
    return [...a.entries]..sort((x, y) => y.at.compareTo(x.at));
  }

  // ------------------------------------------------ Devis

  Coupon? byCode(String code) {
    final c = code.trim().toUpperCase();
    return _b.coupons.where((x) => x.code == c).firstOrNull;
  }

  /// Montant à payer pour [lines], avec un code promo et des points
  /// facultatifs. Lève une exception si une règle n'est pas respectée.
  CheckoutQuote quote(List<CartLine> lines, {String? code, int points = 0}) {
    final me = _b.requireUser();
    final fresh = [
      for (final l in lines)
        (_b.products.byId(l.product.id) ?? l.product, l.quantity),
    ];
    final subtotal = _r2(
      fresh.fold(0.0, (s, e) => s + e.$1.effectivePrice * e.$2),
    );
    Coupon? coupon;
    var eligible = 0.0;
    var couponDiscount = 0.0;
    if (code != null && code.trim().isNotEmpty) {
      coupon =
          byCode(code) ??
          (throw const ValidationException('Code promo inconnu.'));
      eligible = _r2(_checkCoupon(coupon, me.id, subtotal, fresh));
      couponDiscount = _r2(
        math.min(
          eligible,
          coupon.type == DiscountType.percent
              ? eligible * coupon.value / 100
              : coupon.value,
        ),
      );
    }
    if (points < 0 || points % pointsBlock != 0) {
      throw const ValidationException(
        'Les points s\'utilisent par tranches de 100 (100 points = 5 DT).',
      );
    }
    if (points > 0) {
      final balance = balanceOf(me.id);
      if (points > balance) {
        throw BusinessRuleException(
          'Solde insuffisant : vous avez $balance points.',
        );
      }
      final max = maxRedeemable(me.id, subtotal - couponDiscount);
      if (points > max) {
        throw BusinessRuleException(
          'Pour ce panier, vous pouvez utiliser au plus $max points.',
        );
      }
    }
    return CheckoutQuote(
      subtotal: subtotal,
      stamp: lines.isEmpty ? 0 : AppConfig.fiscalStamp,
      coupon: coupon,
      eligibleAmount: eligible,
      couponDiscount: couponDiscount,
      pointsUsed: points,
      pointsDiscount: pointsValue(points),
    );
  }

  /// Vérifie les règles du code et renvoie le montant éligible.
  double _checkCoupon(
    Coupon c,
    String userId,
    double subtotal,
    List<(Product, int)> lines,
  ) {
    final now = _b.now();
    if (!c.active) {
      throw const BusinessRuleException('Ce code promo n\'est plus actif.');
    }
    if (c.startsAt != null && now.isBefore(c.startsAt!)) {
      throw BusinessRuleException(
        'Ce code promo est valable à partir du ${Fmt.date(c.startsAt!)}.',
      );
    }
    if (c.expiresAt != null && now.isAfter(c.expiresAt!)) {
      throw const BusinessRuleException('Ce code promo a expiré.');
    }
    if (c.exhausted) {
      throw const BusinessRuleException(
        'Ce code promo a atteint son nombre maximal d\'utilisations.',
      );
    }
    final perUser = c.maxUsesPerUser;
    if (perUser != null && c.usesBy(userId) >= perUser) {
      throw const BusinessRuleException(
        'Vous avez déjà utilisé ce code promo.',
      );
    }
    if (subtotal < c.minAmount) {
      throw BusinessRuleException(
        'Ce code nécessite un panier d\'au moins ${Fmt.money(c.minAmount)}.',
      );
    }
    final inCategory = lines.where(
      (l) => c.category == null || l.$1.category == c.category,
    );
    if (inCategory.isEmpty) {
      throw BusinessRuleException(
        'Ce code ne concerne que la catégorie « ${c.category!.label} ».',
      );
    }
    // Pas de cumul avec un prix promotionnel.
    final eligible = inCategory
        .where((l) => !l.$1.onPromo)
        .fold(0.0, (s, l) => s + l.$1.effectivePrice * l.$2);
    if (eligible <= 0) {
      throw const BusinessRuleException(
        'Ce code ne se cumule pas avec les produits déjà en promotion.',
      );
    }
    return eligible;
  }

  // ------------------------------------------------ Après paiement

  /// Enregistre l'utilisation du code, débite les points utilisés et
  /// crédite les points gagnés. Appelée uniquement après paiement accepté.
  Future<void> applyAfterPayment(ShopOrder order, CheckoutQuote q) async {
    final c = q.coupon;
    if (c != null) {
      final fresh = _b.coupons.byId(c.id) ?? c;
      await _b.coupons.save(
        fresh.copyWith(
          uses: [
            ...fresh.uses,
            CouponUse(
              userId: order.userId,
              orderId: order.id,
              amount: q.couponDiscount,
              at: order.createdAt,
            ),
          ],
        ),
      );
    }
    final account = await syncSessions(order.userId);
    await _b.loyalty.save(
      account.add([
        if (q.pointsUsed > 0)
          LoyaltyEntry(
            kind: LoyaltyKind.redeem,
            points: -q.pointsUsed,
            refId: order.id,
            at: order.createdAt,
          ),
        if (q.pointsToEarn > 0)
          LoyaltyEntry(
            kind: LoyaltyKind.purchase,
            points: q.pointsToEarn,
            refId: order.id,
            at: order.createdAt,
          ),
      ]),
    );
  }

  // ------------------------------------------------ Super admin

  List<Coupon> all() {
    _b.requireRole(Backend.adminOnly);
    return _b.coupons.all.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// « Actif », « Expiré », « Épuisé », « Programmé » ou « Désactivé ».
  String statusOf(Coupon c) {
    final now = _b.now();
    if (!c.active) return 'Désactivé';
    if (c.expiresAt != null && now.isAfter(c.expiresAt!)) return 'Expiré';
    if (c.exhausted) return 'Épuisé';
    if (c.startsAt != null && now.isBefore(c.startsAt!)) return 'Programmé';
    return 'Actif';
  }

  Future<Coupon> saveCoupon({
    String? id,
    required String code,
    required String label,
    required DiscountType type,
    required double value,
    double minAmount = 0,
    int? maxUses,
    int? maxUsesPerUser = 1,
    ProductCategory? category,
    DateTime? startsAt,
    DateTime? expiresAt,
    bool active = true,
  }) async {
    _b.requireRole(Backend.adminOnly);
    final c = code.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9_-]{3,20}$').hasMatch(c)) {
      throw const ValidationException(
        'Code : 3 à 20 lettres, chiffres, « - » ou « _ », sans espace.',
      );
    }
    final existing = id == null
        ? null
        : (_b.coupons.byId(id) ?? (throw const NotFoundException()));
    if (_b.coupons.all.any((x) => x.code == c && x.id != id)) {
      throw const ValidationException('Ce code existe déjà.');
    }
    final l = label.trim();
    if (l.length < 3 || l.length > 60) {
      throw const ValidationException('Libellé : 3 à 60 caractères.');
    }
    if (type == DiscountType.percent && (value < 1 || value > 90)) {
      throw const ValidationException('Pourcentage : entre 1 et 90 %.');
    }
    if (type == DiscountType.fixed && (value <= 0 || value > 1000)) {
      throw const ValidationException('Montant : entre 0,1 et 1 000 DT.');
    }
    if (minAmount < 0) {
      throw const ValidationException('Montant minimum invalide.');
    }
    if ((maxUses != null && maxUses < 1) ||
        (maxUsesPerUser != null && maxUsesPerUser < 1)) {
      throw const ValidationException(
        'Nombre d\'utilisations : au moins 1 (ou illimité).',
      );
    }
    if (startsAt != null && expiresAt != null && !expiresAt.isAfter(startsAt)) {
      throw const ValidationException(
        'La date d\'expiration doit suivre la date de début.',
      );
    }
    final coupon = Coupon(
      id: existing?.id ?? IdGen.next('cp_'),
      code: c,
      label: l,
      type: type,
      value: value,
      createdAt: existing?.createdAt ?? _b.now(),
      active: active,
      startsAt: startsAt,
      expiresAt: expiresAt,
      maxUses: maxUses,
      maxUsesPerUser: maxUsesPerUser,
      minAmount: minAmount,
      category: category,
      uses: existing?.uses ?? const [],
    );
    await _b.coupons.save(coupon);
    await _b.audit.log(
      existing == null
          ? 'Création de code promo'
          : 'Modification de code promo',
      '$c (${coupon.shortValue})',
      targetId: coupon.id,
    );
    _b.bus.emit();
    return coupon;
  }

  /// Supprime un code jamais utilisé ; sinon il est désactivé (l'historique
  /// des réductions accordées est conservé).
  Future<void> deleteCoupon(String id) async {
    _b.requireRole(Backend.adminOnly);
    final c = _b.coupons.byId(id) ?? (throw const NotFoundException());
    if (c.uses.isEmpty) {
      await _b.coupons.delete(id);
      await _b.audit.log('Suppression de code promo', c.code, targetId: id);
    } else {
      await _b.coupons.save(c.copyWith(active: false));
      await _b.audit.log('Désactivation de code promo', c.code, targetId: id);
    }
    _b.bus.emit();
  }
}
