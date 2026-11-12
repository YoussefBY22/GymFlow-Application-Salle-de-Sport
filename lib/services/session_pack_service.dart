import '../core/config.dart';
import '../core/errors.dart';
import '../core/formatters.dart';
import '../models/course.dart';
import '../models/enums.dart';
import '../models/session_pack.dart';
import '../models/shop.dart';
import '../models/user.dart';
import '../repositories/repository.dart';
import 'backend.dart';
import 'payment/payment_gateway.dart';

/// Montant à payer pour une formule (le timbre fiscal n'est jamais réduit).
class PackQuote {
  const PackQuote({required this.offer, required this.stamp});

  final PackOffer offer;
  final double stamp;

  double get price => offer.price;
  double get total => price + stamp;
}

/// Effet d'une annulation par l'abonné sur son crédit.
enum CancelOutcome { released, consumed }

/// Carnets de séances et formules hebdomadaires.
///
/// Règles (toutes ici, appelées par `ReservationService` et
/// `CourseService`) :
/// - abonné actif : cours inclus gratuits, les autres prennent un crédit ;
///   sans abonnement actif, TOUS les cours prennent un crédit ;
/// - le crédit est RÉSERVÉ à la confirmation, sur le carnet qui expire en
///   premier (FEFO), puis CONSOMMÉ (présence, absence, annulation tardive,
///   cours terminé), LIBÉRÉ (annulation assez tôt) ou REMBOURSÉ (cours
///   annulé par la salle) ;
/// - un crédit ne change d'état que s'il est encore réservé : il ne peut
///   donc jamais servir, ni être rendu, deux fois ;
/// - aucun crédit n'est bloqué en liste d'attente.
class SessionPackService {
  SessionPackService(this._b);
  final Backend _b;

  /// Alertes envoyées une seule fois par carnet.
  static const alertLast = 'last';
  static const alertExpiry = 'expiry';
  static const expiryWarning = Duration(days: 7);

  // ------------------------------------------------ Réglages

  GymSettings get settings =>
      _b.gymSettings.byId(GymSettings.id) ?? const GymSettings();

  Future<GymSettings> saveSettings({required int freeCancelHours}) async {
    _b.requireRole(Backend.adminOnly);
    if (freeCancelHours < 1 || freeCancelHours > 72) {
      throw const ValidationException(
        'Délai d\'annulation gratuite : entre 1 et 72 heures.',
      );
    }
    final s = await _b.gymSettings.save(
      settings.copyWith(freeCancelHours: freeCancelHours),
    );
    await _b.audit.log(
      'Réglages des cours',
      'Annulation gratuite jusqu\'à $freeCancelHours h avant le cours',
    );
    _b.bus.emit();
    return s;
  }

  // ------------------------------------------------ Formules

  /// Formules : en vente pour tous, toutes (même retirées) pour l'admin.
  List<PackOffer> offers({bool includeInactive = false}) {
    final me = _b.requireUser();
    return _b.packOffers.where(
      (o) => o.active || (includeInactive && me.isAdmin),
    )..sort((a, b) {
      final k = a.kind.index.compareTo(b.kind.index);
      return k != 0 ? k : a.price.compareTo(b.price);
    });
  }

  int soldCount(String offerId) =>
      _b.sessionPacks.where((p) => p.offerId == offerId).length;

  Future<PackOffer> saveOffer({
    String? id,
    required String name,
    required PackKind kind,
    required int quota,
    required int validityDays,
    required double price,
    List<CourseCategory> categories = const [],
    bool active = true,
  }) async {
    _b.requireRole(Backend.adminOnly);
    if (name.trim().length < 3) {
      throw const ValidationException('Nom : 3 caractères minimum.');
    }
    if (quota < 1 || quota > (kind == PackKind.weekly ? 7 : 100)) {
      throw ValidationException(
        kind == PackKind.weekly
            ? 'Cours par semaine : de 1 à 7.'
            : 'Nombre de séances : de 1 à 100.',
      );
    }
    if (validityDays < 1 || validityDays > 730) {
      throw const ValidationException('Validité : de 1 à 730 jours.');
    }
    if (price < 0.5 || price > 5000) {
      throw const ValidationException('Prix : entre 0,5 et 5 000 TND.');
    }
    final existing = id == null ? null : _b.packOffers.byId(id);
    if (id != null && existing == null) throw const NotFoundException();
    final o = PackOffer(
      id: id ?? IdGen.next('po_'),
      name: name.trim(),
      kind: kind,
      quota: quota,
      validityDays: validityDays,
      price: price,
      categories: categories.toSet().toList(),
      active: active,
      createdAt: existing?.createdAt ?? _b.now(),
    );
    await _b.packOffers.save(o);
    await _b.audit.log(
      existing == null ? 'Création de formule' : 'Modification de formule',
      '${o.name} · ${o.quotaLabel} · ${Fmt.money(o.price)}',
      targetId: o.id,
    );
    _b.bus.emit();
    return o;
  }

  /// Supprime une formule jamais vendue ; sinon, la retire de la vente
  /// (les carnets déjà vendus restent valables).
  Future<bool> deleteOffer(String id) async {
    _b.requireRole(Backend.adminOnly);
    final o = _b.packOffers.byId(id) ?? (throw const NotFoundException());
    final sold = soldCount(id) > 0;
    if (sold) {
      await _b.packOffers.save(o.copyWith(active: false));
    } else {
      await _b.packOffers.delete(id);
    }
    await _b.audit.log(
      sold ? 'Formule retirée de la vente' : 'Suppression de formule',
      o.name,
      targetId: id,
    );
    _b.bus.emit();
    return !sold;
  }

  // ------------------------------------------------ Couverture

  /// Vrai si la réservation de [c] par [u] prend un crédit.
  bool needsCredit(AppUser u, Course c) {
    final at = c.startAt ?? _b.now();
    if (!u.subscription.isActiveAt(at)) return true;
    return !c.priceIncluded;
  }

  /// Carnets de l'abonné, celui qui expire en premier d'abord (FEFO).
  List<SessionPack> packsOf(String userId) =>
      _b.sessionPacks.where((p) => p.userId == userId && userId.isNotEmpty)
        ..sort((a, b) {
          final e = a.expiresAt.compareTo(b.expiresAt);
          return e != 0 ? e : a.purchasedAt.compareTo(b.purchasedAt);
        });

  List<SessionPack> myPacks() => packsOf(_b.requireUser().id);

  /// Motif de refus d'un carnet pour [c], avec sa priorité (la plus
  /// élevée est la plus utile à afficher), ou `null` s'il convient.
  (int, String)? _refusal(SessionPack p, Course c) {
    final now = _b.now();
    final start = c.startAt ?? now;
    if (p.isExpiredAt(now)) {
      return (
        0,
        'Votre carnet « ${p.name} » a expiré le ${Fmt.date(p.expiresAt)}.',
      );
    }
    if (!start.isBefore(p.expiresAt)) {
      return (
        1,
        'Votre carnet « ${p.name} » expire le ${Fmt.date(p.expiresAt)}, '
            'avant ce cours.',
      );
    }
    if (!p.covers(c.category)) {
      return (
        2,
        'Votre carnet « ${p.name} » ne couvre pas les cours de '
            '${c.category.label} (${p.categoriesLabel}).',
      );
    }
    final cost = c.creditCost;
    if (p.kind == PackKind.credits && p.remaining <= 0) {
      return (3, 'Votre carnet « ${p.name} » est épuisé.');
    }
    if (p.kind == PackKind.credits && p.remaining < cost) {
      return (
        3,
        'Il ne reste que ${Fmt.plural(p.remaining, 'séance')} sur '
            '« ${p.name} » : ce cours en demande $cost.',
      );
    }
    if (p.kind == PackKind.weekly && p.usedInWeek(start) + cost > p.quota) {
      return (
        4,
        'Plafond atteint : ${p.quota} cours par semaine avec « ${p.name} » '
            '(semaine du ${Fmt.date(SessionPack.weekStart(start))}'
            '${cost > 1 ? ' ; ce cours compte pour $cost' : ''}).',
      );
    }
    return null;
  }

  String? refusalOf(SessionPack p, Course c) => _refusal(p, c)?.$2;

  /// Carnets utilisables pour [c], dans l'ordre FEFO.
  List<SessionPack> eligiblePacks(String userId, Course c) => [
    for (final p in packsOf(userId))
      if (_refusal(p, c) == null) p,
  ];

  static const _buyHint =
      'Achetez un carnet ou une séance à l\'unité dans « Mes carnets ».';

  /// Message expliquant pourquoi aucun carnet ne convient.
  String missingCreditMessage(AppUser u, Course c) {
    final packs = packsOf(u.id);
    if (packs.isEmpty) {
      return u.subscription.isActiveAt(c.startAt ?? _b.now())
          ? 'Ce cours n\'est pas inclus dans l\'abonnement : il se réserve '
                'avec un carnet. $_buyHint'
          : 'Sans abonnement actif, chaque cours se réserve avec un '
                'carnet. $_buyHint';
    }
    (int, String)? best;
    for (final p in packs) {
      final r = _refusal(p, c);
      if (r != null && (best == null || r.$1 > best.$1)) best = r;
    }
    return '${best?.$2 ?? 'Aucun carnet valide.'} $_buyHint';
  }

  /// Carnet à utiliser : celui choisi par l'abonné (vérifié), sinon le
  /// premier en FEFO. Lève une exception claire si aucun ne convient.
  SessionPack pickPack(AppUser u, Course c, {String? packId}) {
    if (packId != null) {
      final p = _b.sessionPacks.byId(packId);
      if (p == null || p.userId != u.id) throw const NotFoundException();
      final r = refusalOf(p, c);
      if (r != null) throw BusinessRuleException(r);
      return p;
    }
    final ok = eligiblePacks(u.id, c);
    if (ok.isEmpty) throw BusinessRuleException(missingCreditMessage(u, c));
    return ok.first;
  }

  // ------------------------------------------------ Mouvements

  SessionPack? _holding(String reservationId) =>
      _b.sessionPacks.where((p) => p.isOpen(reservationId)).firstOrNull;

  /// Réserve un crédit pour une réservation confirmée.
  Future<SessionPack> reserve(Reservation r, Course c, SessionPack pack) async {
    final fresh = _b.sessionPacks.byId(pack.id) ?? pack;
    if (_holding(r.id) != null || fresh.stateOf(r.id) != null) {
      throw const BusinessRuleException(
        'Un crédit a déjà été utilisé pour cette réservation.',
      );
    }
    final why = refusalOf(fresh, c);
    if (why != null) throw BusinessRuleException(why);
    final saved = await _b.sessionPacks.save(
      fresh.add(
        PackMovement(
          kind: PackMoveKind.reserved,
          at: _b.now(),
          reservationId: r.id,
          courseAt: c.startAt,
          count: c.creditCost,
        ),
      ),
    );
    await _checkAlerts(saved);
    return saved;
  }

  /// Consomme, libère ou rembourse le crédit réservé pour [reservationId],
  /// pour le même nombre de séances que celui réservé.
  /// Sans effet si aucun crédit n'est réservé (déjà réglé) : un crédit ne
  /// peut pas être consommé ou rendu deux fois.
  Future<bool> settle(String reservationId, PackMoveKind kind) async {
    assert(kind != PackMoveKind.reserved && kind != PackMoveKind.expired);
    final p = _holding(reservationId);
    if (p == null) return false;
    await _b.sessionPacks.save(
      p.add(
        PackMovement(
          kind: kind,
          at: _b.now(),
          reservationId: reservationId,
          count: p.costOf(reservationId),
        ),
      ),
    );
    return true;
  }

  /// Ce que deviendrait le crédit si l'abonné annulait maintenant.
  CancelOutcome? cancelOutcome(Reservation r, Course c) {
    if (r.status != ReservationStatus.confirmed || _holding(r.id) == null) {
      return null;
    }
    final start = c.startAt;
    if (start == null) return CancelOutcome.released;
    final early =
        start.difference(_b.now()) >= Duration(hours: settings.freeCancelHours);
    return early ? CancelOutcome.released : CancelOutcome.consumed;
  }

  /// Mise à jour paresseuse des carnets d'un abonné : crédits des cours
  /// terminés sans pointage consommés, des cours annulés remboursés,
  /// séances restantes d'un carnet expiré, puis alertes.
  Future<void> sync(String userId) async {
    final now = _b.now();
    for (final p in packsOf(userId)) {
      for (final e in p.states.entries) {
        if (e.value != PackMoveKind.reserved) continue;
        final r = _b.reservations.byId(e.key);
        final c = r == null ? null : _b.courses.byId(r.courseId);
        if (c == null || c.cancelled) {
          await settle(e.key, PackMoveKind.refunded);
        } else if (c.statusAt(now) == CourseStatus.done) {
          await settle(e.key, PackMoveKind.consumed);
        }
      }
      var fresh = _b.sessionPacks.byId(p.id)!;
      if (fresh.kind == PackKind.credits &&
          fresh.isExpiredAt(now) &&
          fresh.remaining > 0) {
        fresh = await _b.sessionPacks.save(
          fresh.add(
            PackMovement(
              kind: PackMoveKind.expired,
              at: fresh.expiresAt,
              count: fresh.remaining,
            ),
          ),
        );
      }
      await _checkAlerts(fresh);
    }
  }

  Future<void> _checkAlerts(SessionPack p) async {
    final now = _b.now();
    if (p.userId.isEmpty || p.isExpiredAt(now)) return;
    final sent = [...p.alerts];
    if (p.kind == PackKind.credits &&
        p.remaining == 1 &&
        !sent.contains(alertLast)) {
      sent.add(alertLast);
      await _b.notifications.notify(
        p.userId,
        NotificationType.pack,
        'Plus qu\'une séance sur votre carnet',
        '« ${p.name} » : il vous reste 1 séance, valable jusqu\'au '
            '${Fmt.date(p.expiresAt.subtract(const Duration(minutes: 1)))}.',
        route: '/packs',
        refId: p.id,
      );
    }
    final left = p.kind == PackKind.credits ? p.remaining : p.quota;
    if (p.expiresAt.difference(now) <= expiryWarning &&
        left > 0 &&
        !sent.contains(alertExpiry)) {
      sent.add(alertExpiry);
      await _b.notifications.notify(
        p.userId,
        NotificationType.pack,
        'Votre carnet expire bientôt',
        p.kind == PackKind.credits
            ? '« ${p.name} » expire le ${Fmt.date(p.expiresAt)} : il vous '
                  'reste ${Fmt.plural(left, 'séance')} à utiliser.'
            : '« ${p.name} » expire le ${Fmt.date(p.expiresAt)}.',
        route: '/packs',
        refId: p.id,
      );
    }
    if (sent.length != p.alerts.length) {
      await _b.sessionPacks.save(
        (_b.sessionPacks.byId(p.id) ?? p).copyWith(alerts: sent),
      );
    }
  }

  /// Séance d'essai offerte (action d'accompagnement) : carnet gratuit
  /// d'une séance, valable [trialDays] jours, sans paiement.
  static const trialDays = 14;

  Future<SessionPack> grantTrial(String memberId) async {
    _b.requireRole(Backend.staff);
    final now = _b.now();
    final pack = await _b.sessionPacks.save(
      SessionPack(
        id: IdGen.next('pk_'),
        userId: memberId,
        offerId: trialOfferId,
        name: 'Séance d\'essai offerte',
        kind: PackKind.credits,
        quota: 1,
        purchasedAt: now,
        expiresAt: DateTime(now.year, now.month, now.day + trialDays + 1),
        paymentMethod: 'offert',
      ),
    );
    await _b.notifications.notify(
      memberId,
      NotificationType.pack,
      'Une séance vous est offerte',
      'Votre coach vous offre une séance, valable jusqu\'au '
          '${Fmt.date(pack.expiresAt.subtract(const Duration(minutes: 1)))} '
          'sur le cours de votre choix.',
      route: '/packs',
      refId: pack.id,
    );
    return pack;
  }

  static const trialOfferId = 'trial';

  // ------------------------------------------------ Achat

  PackQuote quote(String offerId) {
    final o = _b.packOffers.byId(offerId);
    if (o == null || !o.active) {
      throw const BusinessRuleException('Cette formule n\'est plus en vente.');
    }
    return PackQuote(offer: o, stamp: AppConfig.fiscalStamp);
  }

  /// Ligne envoyée à la passerelle de paiement (formule + prix), sans
  /// créer de produit dans la boutique.
  List<CartLine> paymentLines(PackQuote q) => [
    CartLine(
      product: Product(
        id: 'pack_${q.offer.id}',
        name: 'Carnet GymFlow : ${q.offer.name}',
        description: q.offer.quotaLabel,
        category: ProductCategory.accessories,
        price: q.price,
        stock: 1,
        createdAt: _b.now(),
      ),
      quantity: 1,
    ),
  ];

  /// Enregistre le carnet APRÈS un paiement accepté, dont le montant est
  /// comparé au total (prix + timbre fiscal).
  Future<SessionPack> buy(String offerId, PaymentResult payment) async {
    final me = _b.requireRole({UserRole.member});
    if (!payment.success) {
      throw const BusinessRuleException('Paiement non validé.');
    }
    final q = quote(offerId);
    final paid = payment.amount;
    if (paid != null && (paid - q.total).abs() > 0.005) {
      throw const BusinessRuleException(
        'Le montant payé ne correspond pas au prix de la formule.',
      );
    }
    if (payment.reference.isNotEmpty &&
        _b.sessionPacks
            .where((p) => p.paymentRef == payment.reference)
            .isNotEmpty) {
      throw const BusinessRuleException('Ce paiement a déjà été utilisé.');
    }
    final now = _b.now();
    final o = q.offer;
    final pack = await _b.sessionPacks.save(
      SessionPack(
        id: IdGen.next('pk_'),
        userId: me.id,
        offerId: o.id,
        name: o.name,
        kind: o.kind,
        quota: o.quota,
        categories: o.categories,
        purchasedAt: now,
        // Valable jusqu'à la fin du dernier jour.
        expiresAt: DateTime(now.year, now.month, now.day + o.validityDays + 1),
        price: q.total,
        paymentMethod: payment.method,
        paymentRef: payment.reference,
      ),
    );
    await _b.notifications.notify(
      me.id,
      NotificationType.pack,
      'Carnet acheté : ${o.name}',
      '${o.quotaLabel} · valable jusqu\'au '
          '${Fmt.date(pack.expiresAt.subtract(const Duration(minutes: 1)))}.',
      route: '/packs',
      refId: pack.id,
    );
    await _b.audit.log(
      'Achat de carnet',
      '${o.name} · ${Fmt.money(q.total)}',
      targetId: pack.id,
    );
    _b.bus.emit();
    return pack;
  }
}
