import 'enums.dart';
import 'json.dart';

export 'gym_settings.dart';

/// Type de formule : carnet de N séances, ou abonnement limité à N cours
/// par semaine (du lundi au dimanche de la semaine du cours).
enum PackKind {
  credits('Carnet de séances'),
  weekly('Formule hebdomadaire');

  const PackKind(this.label);
  final String label;
}

/// Mouvement d'un crédit. Pour une réservation, seul le DERNIER mouvement
/// compte : `reserved` bloque le crédit, `consumed` le décompte,
/// `released` et `refunded` le rendent.
enum PackMoveKind {
  reserved('Réservé'),
  consumed('Consommé'),
  released('Libéré'),
  refunded('Remboursé'),
  expired('Expiré');

  const PackMoveKind(this.label);
  final String label;
}

/// Formule vendue par la salle (créée par le super admin).
class PackOffer {
  const PackOffer({
    required this.id,
    required this.name,
    required this.kind,
    required this.quota,
    required this.validityDays,
    required this.price,
    required this.createdAt,
    this.categories = const [],
    this.active = true,
  });

  final String id;
  final String name;
  final PackKind kind;

  /// Séances du carnet, ou cours par semaine.
  final int quota;
  final int validityDays;
  final double price;

  /// Catégories autorisées ; vide = toutes.
  final List<CourseCategory> categories;
  final bool active;
  final DateTime createdAt;

  String get quotaLabel => kind == PackKind.credits
      ? '$quota séance${quota > 1 ? 's' : ''}'
      : '$quota cours par semaine';

  String get categoriesLabel => categories.isEmpty
      ? 'Tous les cours'
      : categories.map((c) => c.label).join(', ');

  PackOffer copyWith({bool? active}) => PackOffer(
    id: id,
    name: name,
    kind: kind,
    quota: quota,
    validityDays: validityDays,
    price: price,
    createdAt: createdAt,
    categories: categories,
    active: active ?? this.active,
  );

  Json toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'quota': quota,
    'validityDays': validityDays,
    'price': price,
    'categories': categories.map((c) => c.name).toList(),
    'active': active,
    'createdAt': dateToJson(createdAt),
  };

  factory PackOffer.fromJson(Json j) => PackOffer(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    kind: enumFrom(PackKind.values, j['kind'], PackKind.credits),
    quota: toInt(j['quota'], 1),
    validityDays: toInt(j['validityDays'], 30),
    price: toDouble(j['price']),
    categories: _categories(j['categories']),
    active: j['active'] as bool? ?? true,
    createdAt: dateOr(j['createdAt'], DateTime(2026)),
  );
}

List<CourseCategory> _categories(Object? v) => [
  for (final n in stringList(v))
    for (final c in CourseCategory.values)
      if (c.name == n) c,
];

/// Mouvement de l'historique d'un carnet.
class PackMovement {
  const PackMovement({
    required this.kind,
    required this.at,
    this.reservationId,
    this.courseAt,
    this.count = 1,
  });

  final PackMoveKind kind;
  final DateTime at;

  /// Réservation concernée (absente pour une expiration).
  final String? reservationId;

  /// Début du cours : sert au plafond hebdomadaire.
  final DateTime? courseAt;

  /// Nombre de séances : le coût du cours (1 à 5), répété à l'identique
  /// par le mouvement qui consomme, libère ou rembourse ; pour une
  /// expiration, les séances perdues.
  final int count;

  Json toJson() => {
    'kind': kind.name,
    'at': dateToJson(at),
    'reservationId': reservationId,
    'courseAt': dateToJson(courseAt),
    'count': count,
  };

  factory PackMovement.fromJson(Json j) => PackMovement(
    kind: enumFrom(PackMoveKind.values, j['kind'], PackMoveKind.consumed),
    at: dateOr(j['at'], DateTime(2026)),
    reservationId: j['reservationId'] as String?,
    courseAt: dateFromJson(j['courseAt']),
    count: toInt(j['count'], 1),
  );
}

/// Carnet (ou formule hebdomadaire) acheté par un abonné. Les conditions
/// de la formule sont copiées à l'achat : modifier la formule ensuite ne
/// change pas les carnets déjà vendus. Le solde est TOUJOURS calculé à
/// partir de l'historique des mouvements.
class SessionPack {
  const SessionPack({
    required this.id,
    required this.userId,
    required this.offerId,
    required this.name,
    required this.kind,
    required this.quota,
    required this.purchasedAt,
    required this.expiresAt,
    this.categories = const [],
    this.price = 0,
    this.paymentMethod = '',
    this.paymentRef = '',
    this.movements = const [],
    this.alerts = const [],
  });

  final String id;

  /// Vide après effacement du compte (trace comptable anonymisée).
  final String userId;
  final String offerId;
  final String name;
  final PackKind kind;
  final int quota;
  final List<CourseCategory> categories;
  final DateTime purchasedAt;

  /// Fin de validité (exclue) : un cours doit commencer avant.
  final DateTime expiresAt;

  /// Montant payé (timbre compris), méthode et référence du paiement :
  /// aucune donnée de carte.
  final double price;
  final String paymentMethod;
  final String paymentRef;
  final List<PackMovement> movements;

  /// Alertes déjà envoyées (« last », « expiry ») : une seule fois chacune.
  final List<String> alerts;

  /// Dernier mouvement de chaque réservation.
  Map<String, PackMoveKind> get states => {
    for (final m in movements)
      if (m.reservationId != null) m.reservationId!: m.kind,
  };

  /// Début du cours de chaque réservation (premier mouvement « réservé »).
  Map<String, DateTime> get _courseDates => {
    for (final m in movements.reversed)
      if (m.reservationId != null && m.courseAt != null)
        m.reservationId!: m.courseAt!,
  };

  /// Séances engagées par chaque réservation (coût du cours au moment de
  /// la réservation : modifier le cours ensuite ne change rien).
  Map<String, int> get costs => {
    for (final m in movements)
      if (m.reservationId != null && m.kind == PackMoveKind.reserved)
        m.reservationId!: m.count,
  };

  int costOf(String reservationId) => costs[reservationId] ?? 1;

  PackMoveKind? stateOf(String reservationId) => states[reservationId];

  /// Crédit bloqué pour cette réservation (ni consommé, ni rendu).
  bool isOpen(String reservationId) =>
      stateOf(reservationId) == PackMoveKind.reserved;

  /// Séances (pondérées par le coût) dont la réservation est dans l'état [k].
  int _count(PackMoveKind k) {
    final c = costs;
    var n = 0;
    states.forEach((rid, st) {
      if (st == k) n += c[rid] ?? 1;
    });
    return n;
  }

  int get openCount => _count(PackMoveKind.reserved);
  int get consumedCount => _count(PackMoveKind.consumed);
  int get expiredCount => movements
      .where((m) => m.kind == PackMoveKind.expired)
      .fold(0, (s, m) => s + m.count);

  /// Séances encore disponibles (carnet uniquement).
  int get remaining => kind == PackKind.weekly
      ? 0
      : (quota - openCount - consumedCount - expiredCount).clamp(0, quota);

  static DateTime weekStart(DateTime d) =>
      DateTime(d.year, d.month, d.day - (d.weekday - 1));

  /// Séances réservées ou consommées la semaine de [day] (formule
  /// hebdomadaire) : un cours à 2 séances compte pour 2 cours.
  int usedInWeek(DateTime day) {
    final start = weekStart(day);
    final end = DateTime(start.year, start.month, start.day + 7);
    final s = states;
    final c = costs;
    var n = 0;
    _courseDates.forEach((rid, at) {
      final st = s[rid];
      if (st != PackMoveKind.reserved && st != PackMoveKind.consumed) return;
      if (!at.isBefore(start) && at.isBefore(end)) n += c[rid] ?? 1;
    });
    return n;
  }

  bool covers(CourseCategory c) => categories.isEmpty || categories.contains(c);

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  String get categoriesLabel => categories.isEmpty
      ? 'Tous les cours'
      : categories.map((c) => c.label).join(', ');

  SessionPack copyWith({
    String? userId,
    List<PackMovement>? movements,
    List<String>? alerts,
  }) => SessionPack(
    id: id,
    userId: userId ?? this.userId,
    offerId: offerId,
    name: name,
    kind: kind,
    quota: quota,
    purchasedAt: purchasedAt,
    expiresAt: expiresAt,
    categories: categories,
    price: price,
    paymentMethod: paymentMethod,
    paymentRef: paymentRef,
    movements: movements ?? this.movements,
    alerts: alerts ?? this.alerts,
  );

  SessionPack add(PackMovement m) => copyWith(movements: [...movements, m]);

  Json toJson() => {
    'id': id,
    'userId': userId,
    'offerId': offerId,
    'name': name,
    'kind': kind.name,
    'quota': quota,
    'categories': categories.map((c) => c.name).toList(),
    'purchasedAt': dateToJson(purchasedAt),
    'expiresAt': dateToJson(expiresAt),
    'price': price,
    'paymentMethod': paymentMethod,
    'paymentRef': paymentRef,
    'movements': movements.map((m) => m.toJson()).toList(),
    'alerts': alerts,
  };

  factory SessionPack.fromJson(Json j) => SessionPack(
    id: j['id'] as String,
    userId: j['userId'] as String? ?? '',
    offerId: j['offerId'] as String? ?? '',
    name: j['name'] as String? ?? 'Carnet',
    kind: enumFrom(PackKind.values, j['kind'], PackKind.credits),
    quota: toInt(j['quota'], 1),
    categories: _categories(j['categories']),
    purchasedAt: dateOr(j['purchasedAt'], DateTime(2026)),
    expiresAt: dateOr(j['expiresAt'], DateTime(2026)),
    price: toDouble(j['price']),
    paymentMethod: j['paymentMethod'] as String? ?? '',
    paymentRef: j['paymentRef'] as String? ?? '',
    movements: jsonList(j['movements']).map(PackMovement.fromJson).toList(),
    alerts: stringList(j['alerts']),
  );
}
