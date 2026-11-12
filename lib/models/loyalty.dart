import 'enums.dart';
import 'json.dart';

enum DiscountType {
  percent('Pourcentage'),
  fixed('Montant fixe');

  const DiscountType(this.label);
  final String label;
}

/// Utilisation d'un code promo, enregistrée après paiement accepté.
class CouponUse {
  const CouponUse({
    required this.userId,
    required this.orderId,
    required this.amount,
    required this.at,
  });

  final String userId;
  final String orderId;

  /// Réduction accordée sur la commande.
  final double amount;
  final DateTime at;

  Json toJson() => {
    'userId': userId,
    'orderId': orderId,
    'amount': amount,
    'at': dateToJson(at),
  };

  factory CouponUse.fromJson(Json j) => CouponUse(
    userId: j['userId'] as String,
    orderId: j['orderId'] as String? ?? '',
    amount: toDouble(j['amount']),
    at: dateOr(j['at'], DateTime(2026)),
  );
}

/// Code promo créé par le super admin.
class Coupon {
  const Coupon({
    required this.id,
    required this.code,
    required this.label,
    required this.type,
    required this.value,
    required this.createdAt,
    this.active = true,
    this.startsAt,
    this.expiresAt,
    this.maxUses,
    this.maxUsesPerUser = 1,
    this.minAmount = 0,
    this.category,
    this.uses = const [],
  });

  final String id;

  /// En majuscules (« BIENVENUE10 »).
  final String code;
  final String label;
  final DiscountType type;

  /// Pourcentage (1 à 90) ou montant en DT.
  final double value;
  final bool active;
  final DateTime createdAt;
  final DateTime? startsAt;
  final DateTime? expiresAt;

  /// Utilisations maximales au total ; null = sans limite.
  final int? maxUses;

  /// Utilisations maximales par personne ; null = sans limite.
  final int? maxUsesPerUser;

  /// Montant minimum du panier (sous-total), en DT.
  final double minAmount;

  /// Catégorie ciblée ; null = tout le catalogue.
  final ProductCategory? category;
  final List<CouponUse> uses;

  int usesBy(String userId) => uses.where((u) => u.userId == userId).length;

  bool get exhausted => maxUses != null && uses.length >= maxUses!;

  /// « -10 % » ou « -5,00 TND » (montant formaté par l'appelant).
  String get shortValue => type == DiscountType.percent
      ? '-${value % 1 == 0 ? value.toInt() : value} %'
      : '-${value.toStringAsFixed(value % 1 == 0 ? 0 : 2)} DT';

  Coupon copyWith({bool? active, List<CouponUse>? uses}) => Coupon(
    id: id,
    code: code,
    label: label,
    type: type,
    value: value,
    createdAt: createdAt,
    active: active ?? this.active,
    startsAt: startsAt,
    expiresAt: expiresAt,
    maxUses: maxUses,
    maxUsesPerUser: maxUsesPerUser,
    minAmount: minAmount,
    category: category,
    uses: uses ?? this.uses,
  );

  Json toJson() => {
    'id': id,
    'code': code,
    'label': label,
    'type': type.name,
    'value': value,
    'active': active,
    'createdAt': dateToJson(createdAt),
    'startsAt': dateToJson(startsAt),
    'expiresAt': dateToJson(expiresAt),
    'maxUses': maxUses,
    'maxUsesPerUser': maxUsesPerUser,
    'minAmount': minAmount,
    'category': category?.name,
    'uses': uses.map((u) => u.toJson()).toList(),
  };

  factory Coupon.fromJson(Json j) => Coupon(
    id: j['id'] as String,
    code: (j['code'] as String).toUpperCase(),
    label: j['label'] as String? ?? '',
    type: enumFrom(DiscountType.values, j['type'], DiscountType.percent),
    value: toDouble(j['value']),
    active: j['active'] as bool? ?? true,
    createdAt: dateOr(j['createdAt'], DateTime(2026)),
    startsAt: dateFromJson(j['startsAt']),
    expiresAt: dateFromJson(j['expiresAt']),
    maxUses: toIntOrNull(j['maxUses']),
    maxUsesPerUser: j.containsKey('maxUsesPerUser')
        ? toIntOrNull(j['maxUsesPerUser'])
        : 1,
    minAmount: toDouble(j['minAmount']),
    category: j['category'] == null
        ? null
        : enumFrom(
            ProductCategory.values,
            j['category'],
            ProductCategory.accessories,
          ),
    uses: jsonList(j['uses']).map(CouponUse.fromJson).toList(),
  );
}

enum LoyaltyKind {
  purchase('Achat'),
  session('Séance terminée'),
  redeem('Points utilisés');

  const LoyaltyKind(this.label);
  final String label;
}

/// Mouvement de points (positif : gain, négatif : utilisation).
class LoyaltyEntry {
  const LoyaltyEntry({
    required this.kind,
    required this.points,
    required this.refId,
    required this.at,
  });

  final LoyaltyKind kind;
  final int points;

  /// Commande ou séance à l'origine du mouvement.
  final String refId;
  final DateTime at;

  Json toJson() => {
    'kind': kind.name,
    'points': points,
    'refId': refId,
    'at': dateToJson(at),
  };

  factory LoyaltyEntry.fromJson(Json j) => LoyaltyEntry(
    kind: enumFrom(LoyaltyKind.values, j['kind'], LoyaltyKind.purchase),
    points: toInt(j['points']),
    refId: j['refId'] as String? ?? '',
    at: dateOr(j['at'], DateTime(2026)),
  );
}

/// Compte de fidélité d'un abonné (identifiant = celui de l'utilisateur).
class LoyaltyAccount {
  const LoyaltyAccount({required this.userId, this.entries = const []});

  final String userId;
  final List<LoyaltyEntry> entries;

  int get balance => entries.fold(0, (s, e) => s + e.points);

  bool credited(LoyaltyKind kind, String refId) =>
      entries.any((e) => e.kind == kind && e.refId == refId);

  LoyaltyAccount add(Iterable<LoyaltyEntry> more) =>
      LoyaltyAccount(userId: userId, entries: [...entries, ...more]);

  Json toJson() => {
    'id': userId,
    'entries': entries.map((e) => e.toJson()).toList(),
  };

  factory LoyaltyAccount.fromJson(Json j) => LoyaltyAccount(
    userId: j['id'] as String,
    entries: jsonList(j['entries']).map(LoyaltyEntry.fromJson).toList(),
  );
}
