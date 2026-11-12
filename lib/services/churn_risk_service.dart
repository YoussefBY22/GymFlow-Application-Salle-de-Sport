import 'dart:convert';

import '../core/errors.dart';
import '../core/formatters.dart';
import '../models/enums.dart';
import '../models/risk.dart';
import '../models/session_pack.dart';
import '../models/user.dart';
import '../repositories/repository.dart';
import 'backend.dart';
import 'gemini_client.dart';
import 'product_ai_service.dart';

/// Détection du risque de quitter la SALLE : un score EXPLICABLE de 0 à
/// 100.
///
/// Le score est la somme de six facteurs de risque, diminuée d'un facteur
/// protecteur (activité à domicile). Chacun vaut de 0 à son poids, de
/// façon linéaire entre un seuil « rien d'anormal » (0 point) et un seuil
/// « signal fort » (tous les points). Rien n'est appris ni caché : chaque
/// contribution est affichée avec son explication chiffrée.
///
/// Pourquoi ces poids ? (total = 100)
/// - 25 : baisse de fréquentation et 25 : jours sans venir. Ce sont les
///   signaux les plus directs et les plus fiables : on abandonne d'abord en
///   venant moins, puis en ne venant plus. Ils comptent pour moitié.
/// - 15 : annulations tardives et absences. Elles montrent un engagement
///   qui faiblit avant même la baisse des venues.
/// - 15 : fin d'abonnement ou de carnet sans renouvellement. C'est le
///   moment où l'abonné décide de rester ou de partir.
/// - 10 : notes de cours en baisse. Signal utile, mais rare (peu de notes).
/// - 10 : nouvel abonné peu actif. Les 30 premiers jours décident souvent
///   de la suite ; le poids est limité car l'historique est court.
/// - −10 (facteur protecteur) : séances enregistrées à domicile. La
///   personne vient moins à la salle mais reste active : le risque de
///   partir est un peu plus faible. Le poids est volontairement réduit,
///   car s'entraîner chez soi peut aussi annoncer un départ.
///
/// Une « venue » à la salle est comptée en JOURS distincts : présence
/// pointée à un cours ou entrée scannée à l'accueil (check-in QR). Les séances
/// enregistrées dans l'application ne sont PAS des venues : un jour sans
/// venue où une séance est enregistrée compte comme activité à domicile.
///
/// Aucune décision n'est prise automatiquement : le score est visible
/// seulement par les coachs et l'admin, qui choisissent d'agir.
class ChurnRiskService {
  ChurnRiskService(this._b);
  final Backend _b;

  // ------------------------------------------------ Poids (total 100)

  static const double weightDrop = 25;
  static const double weightAbsence = 25;
  static const double weightReliability = 15;
  static const double weightExpiry = 15;
  static const double weightRatings = 10;
  static const double weightNewcomer = 10;

  /// Facteur protecteur : retranché du score (jusqu'à 10 points).
  static const double weightHomeActivity = 10;

  /// Activité à domicile : réduction maximale à 2 séances par semaine.
  static const double homeTargetPerWeek = 2;

  // ------------------------------------------------ Fenêtres

  /// Période récente (3 semaines) comparée aux 8 semaines précédentes.
  static const int recentWeeks = 3;
  static const int baselineWeeks = 8;
  static const int historyWeeks = recentWeeks + baselineWeeks;

  // ------------------------------------------------ Seuils

  /// Baisse de fréquentation : 0 point jusqu'à -10 %, maximum à -60 %.
  static const double dropFrom = 0.10;
  static const double dropTo = 0.60;

  /// En dessous d'une demi-venue par semaine en temps normal, une baisse
  /// n'est pas mesurable.
  static const double minBaselinePerWeek = 0.5;

  /// Jours sans venir : 0 point jusqu'à 7 jours (une semaine normale),
  /// maximum à 30 jours.
  static const int absenceFrom = 7;
  static const int absenceTo = 30;

  /// Annulations tardives et absences : maximum pour une hausse de 40
  /// points du taux (par exemple de 10 % à 50 % des réservations), avec au
  /// moins 2 réservations récentes.
  static const double reliabilityTo = 0.40;
  static const int minRecentBookings = 2;

  /// Fin de couverture : 0 point à 14 jours ou plus, maximum à 3 jours ou
  /// moins (ou déjà terminée).
  static const int expiryFrom = 14;
  static const int expiryTo = 3;

  /// Notes : les 4 dernières semaines comparées aux précédentes ; 0 point
  /// pour une baisse de 0,3 étoile, maximum à 1,5 étoile.
  static const int ratingRecentDays = 28;
  static const double ratingDropFrom = 0.3;
  static const double ratingDropTo = 1.5;
  static const int minOldRatings = 2;

  /// Nouvel abonné : pendant 30 jours, on attend 2 venues par semaine.
  static const int newcomerDays = 30;
  static const double newcomerTargetPerWeek = 2;

  /// Niveaux : faible < 35 ≤ moyen < 60 ≤ élevé.
  static const int mediumFrom = 35;
  static const int highFrom = 60;

  /// Une action est « réussie » si l'abonné revient dans les 14 jours.
  static const Duration returnWindow = Duration(days: 14);

  /// Une séance d'essai offerte au plus tous les 30 jours par abonné.
  static const Duration trialCooldown = Duration(days: 30);

  static RiskLevel levelOf(int score) => score >= highFrom
      ? RiskLevel.high
      : score >= mediumFrom
      ? RiskLevel.medium
      : RiskLevel.low;

  /// Interpolation linéaire bornée entre 0 (à [from]) et 1 (à [to]).
  static double ramp(double v, double from, double to) {
    if (from == to) return v >= to ? 1 : 0;
    return ((v - from) / (to - from)).clamp(0.0, 1.0);
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Décalage en jours CALENDAIRES (sans effet du changement d'heure).
  static DateTime _plusDays(DateTime d, int n) =>
      DateTime(d.year, d.month, d.day + n);

  static String _pct(double v) => '${(v * 100).round()} %';

  /// « 0,3 venue par semaine », « 2,5 venues par semaine ».
  static String perWeek(double v) =>
      '${Fmt.dec1(v)} venue${v >= 2 ? 's' : ''} par semaine';

  // ------------------------------------------------ Venues

  /// Moments de venue à la salle jusqu'à maintenant : cours pointés
  /// présents et entrées scannées à l'accueil (les séances enregistrées
  /// n'en font pas partie).
  List<DateTime> visitTimes(String userId) {
    final now = _b.now();
    final times = <DateTime>[
      for (final r in _b.reservations.where(
        (r) =>
            r.userId == userId &&
            r.status == ReservationStatus.confirmed &&
            r.attended == true,
      ))
        ?_b.courses.byId(r.courseId)?.startAt,
      for (final c in _b.checkIns.where((c) => c.userId == userId)) c.at,
    ];
    return times.where((t) => !t.isAfter(now)).toList()..sort();
  }

  Set<DateTime> visitDays(String userId) =>
      visitTimes(userId).map(_day).toSet();

  int _visitsBetween(Set<DateTime> days, DateTime from, DateTime to) =>
      days.where((d) => !d.isBefore(from) && d.isBefore(to)).length;

  /// Jours de venue par semaine glissante (7 jours), de la plus ancienne à
  /// la plus récente ; la dernière se termine aujourd'hui.
  List<int> weeklyVisits(String userId, {int weeks = historyWeeks}) {
    final days = visitDays(userId);
    final end = _plusDays(_day(_b.now()), 1);
    return [
      for (var w = weeks; w >= 1; w--)
        _visitsBetween(
          days,
          _plusDays(end, -(7 * w)),
          _plusDays(end, -7 * (w - 1)),
        ),
    ];
  }

  // ------------------------------------------------ Score

  /// Calcul interne (sans contrôle d'accès) : utilisé par [assess], par
  /// l'export des données de l'abonné et par les tests.
  RiskAssessment compute(AppUser u) {
    final now = _b.now();
    final end = _plusDays(_day(now), 1);
    final recentStart = _plusDays(end, -(7 * recentWeeks));
    final historyStart = _plusDays(end, -(7 * historyWeeks));
    final created = _day(u.createdAt);
    final days = visitDays(u.id);
    final last = days.isEmpty
        ? null
        : days.reduce((a, b) => a.isAfter(b) ? a : b);
    final factors = [
      _drop(days, created, recentStart, historyStart),
      _absence(last, created, now),
      _reliability(u, recentStart, historyStart, now),
      _expiry(u, now),
      _ratings(u, historyStart, now),
      _newcomer(days, created, now),
      _homeActivity(u, days, recentStart, now),
    ];
    final score = factors
        .fold<double>(0, (s, f) => s + f.points)
        .round()
        .clamp(0, 100);
    return RiskAssessment(
      userId: u.id,
      score: score,
      level: levelOf(score),
      factors: factors,
      computedAt: now,
      weeklyVisits: weeklyVisits(u.id),
      lastVisit: last,
    );
  }

  RiskFactor _drop(
    Set<DateTime> days,
    DateTime created,
    DateTime recentStart,
    DateTime historyStart,
  ) {
    const label = 'Baisse de fréquentation';
    // Semaines de référence réellement disponibles (abonné récent).
    final baseStart = created.isAfter(historyStart) ? created : historyStart;
    final baseWeeks = recentStart.difference(baseStart).inDays / 7;
    if (baseWeeks < 2) {
      return const RiskFactor(
        key: 'drop',
        label: label,
        weight: weightDrop,
        points: 0,
        detail: 'Historique trop court pour mesurer une baisse.',
      );
    }
    final recent =
        _visitsBetween(
          days,
          recentStart,
          _plusDays(recentStart, 7 * recentWeeks),
        ) /
        recentWeeks;
    final base = _visitsBetween(days, baseStart, recentStart) / baseWeeks;
    if (base < minBaselinePerWeek) {
      return RiskFactor(
        key: 'drop',
        label: label,
        weight: weightDrop,
        points: 0,
        detail:
            'Fréquentation habituelle trop faible pour mesurer une baisse '
            '(${perWeek(base)}).',
      );
    }
    final drop = 1 - recent / base;
    return RiskFactor(
      key: 'drop',
      label: label,
      weight: weightDrop,
      points: weightDrop * ramp(drop, dropFrom, dropTo),
      detail:
          '${perWeek(recent)} sur les 3 dernières semaines, contre '
          '${Fmt.dec1(base)} avant'
          '${drop > 0 ? ' (−${_pct(drop)})' : ''}.',
    );
  }

  RiskFactor _absence(DateTime? last, DateTime created, DateTime now) {
    final since = last ?? created;
    final n = _day(now).difference(since).inDays;
    return RiskFactor(
      key: 'absence',
      label: 'Dernière venue',
      weight: weightAbsence,
      points:
          weightAbsence *
          ramp(n.toDouble(), absenceFrom.toDouble(), absenceTo.toDouble()),
      detail: last == null
          ? 'Aucune venue depuis l\'inscription, il y a '
                '${Fmt.plural(n, 'jour')}.'
          : n == 0
          ? 'Venu aujourd\'hui.'
          : 'Dernière venue il y a ${Fmt.plural(n, 'jour')} '
                '(${Fmt.date(last)}).',
    );
  }

  /// Taux d'annulations tardives et d'absences sur une période.
  (int, int) _problems(AppUser u, DateTime from, DateTime to, DateTime now) {
    final late = Duration(hours: _b.packs.settings.freeCancelHours);
    var problems = 0;
    var bookings = 0;
    for (final r in _b.reservations.where((r) => r.userId == u.id)) {
      final at = _b.courses.byId(r.courseId)?.startAt;
      if (at == null || at.isBefore(from) || !at.isBefore(to)) continue;
      if (at.isAfter(now)) continue;
      if (r.status == ReservationStatus.confirmed) {
        bookings++;
        if (r.attended == false) problems++;
      } else if (r.status == ReservationStatus.cancelled &&
          r.cancelledAt != null &&
          at.difference(r.cancelledAt!) < late) {
        bookings++;
        problems++;
      }
    }
    return (problems, bookings);
  }

  RiskFactor _reliability(
    AppUser u,
    DateTime recentStart,
    DateTime historyStart,
    DateTime now,
  ) {
    const label = 'Annulations tardives et absences';
    final (rp, rb) = _problems(
      u,
      recentStart,
      now.add(const Duration(minutes: 1)),
      now,
    );
    final (bp, bb) = _problems(u, historyStart, recentStart, now);
    if (rb < minRecentBookings) {
      return RiskFactor(
        key: 'reliability',
        label: label,
        weight: weightReliability,
        points: 0,
        detail: rb == 0
            ? 'Aucune réservation récente.'
            : 'Trop peu de réservations récentes pour conclure.',
      );
    }
    final recentRate = rp / rb;
    final baseRate = bb == 0 ? 0.0 : bp / bb;
    final increase = recentRate - baseRate;
    return RiskFactor(
      key: 'reliability',
      label: label,
      weight: weightReliability,
      points: weightReliability * ramp(increase, 0, reliabilityTo),
      detail:
          '${Fmt.plural(rp, 'annulation tardive ou absence', 'annulations tardives ou absences')} '
          'sur ${Fmt.plural(rb, 'réservation récente', 'réservations récentes')} '
          '(${_pct(recentRate)}), contre ${_pct(baseRate)} avant.',
    );
  }

  /// Fin de la couverture : abonnement, ou carnet encore utilisable.
  DateTime? coverageEnd(AppUser u) {
    final now = _b.now();
    DateTime? end = u.subscription.type == SubscriptionType.none
        ? null
        : u.subscription.end;
    for (final p in _b.packs.packsOf(u.id)) {
      if (p.isExpiredAt(now)) continue;
      if (p.kind == PackKind.credits && p.remaining == 0) continue;
      if (end == null || p.expiresAt.isAfter(end)) end = p.expiresAt;
    }
    return end;
  }

  RiskFactor _expiry(AppUser u, DateTime now) {
    const label = 'Fin d\'abonnement ou de carnet';
    final end = coverageEnd(u);
    if (end == null) {
      return const RiskFactor(
        key: 'expiry',
        label: label,
        weight: weightExpiry,
        points: weightExpiry,
        detail: 'Ni abonnement ni carnet en cours.',
      );
    }
    final daysLeft = end.difference(now).inHours / 24;
    return RiskFactor(
      key: 'expiry',
      label: label,
      weight: weightExpiry,
      points:
          weightExpiry *
          ramp(-daysLeft, -expiryFrom.toDouble(), -expiryTo.toDouble()),
      detail: daysLeft <= 0
          ? 'Abonnement et carnets terminés depuis le ${Fmt.date(end)}.'
          : 'Couvert jusqu\'au ${Fmt.date(end)} '
                '(${Fmt.plural(daysLeft.ceil(), 'jour')}), sans renouvellement.',
    );
  }

  RiskFactor _ratings(AppUser u, DateTime historyStart, DateTime now) {
    const label = 'Notes de cours en baisse';
    final split = _plusDays(_day(now), -ratingRecentDays);
    final recent = <int>[];
    final old = <int>[];
    for (final r in _b.reservations.where(
      (r) => r.userId == u.id && r.rating != null,
    )) {
      final at = _b.courses.byId(r.courseId)?.startAt;
      if (at == null || at.isBefore(historyStart) || at.isAfter(now)) continue;
      (at.isBefore(split) ? old : recent).add(r.rating!);
    }
    if (recent.isEmpty || old.length < minOldRatings) {
      return const RiskFactor(
        key: 'ratings',
        label: label,
        weight: weightRatings,
        points: 0,
        detail: 'Pas assez de notes pour comparer.',
      );
    }
    double avg(List<int> l) => l.reduce((a, b) => a + b) / l.length;
    final drop = avg(old) - avg(recent);
    return RiskFactor(
      key: 'ratings',
      label: label,
      weight: weightRatings,
      points: weightRatings * ramp(drop, ratingDropFrom, ratingDropTo),
      detail:
          'Moyenne récente ${Fmt.dec1(avg(recent))}/5 contre '
          '${Fmt.dec1(avg(old))}/5 avant.',
    );
  }

  RiskFactor _newcomer(Set<DateTime> days, DateTime created, DateTime now) {
    const label = 'Nouvel abonné peu actif';
    final age = _day(now).difference(created).inDays;
    if (age >= newcomerDays) {
      return const RiskFactor(
        key: 'newcomer',
        label: label,
        weight: weightNewcomer,
        points: 0,
        detail: 'Inscrit depuis plus de 30 jours.',
      );
    }
    final weeks = age / 7 < 1 ? 1.0 : age / 7;
    final rate = days.where((d) => !d.isBefore(created)).length / weeks;
    return RiskFactor(
      key: 'newcomer',
      label: label,
      weight: weightNewcomer,
      points: weightNewcomer * (1 - rate / newcomerTargetPerWeek).clamp(0, 1),
      detail:
          'Inscrit depuis ${Fmt.plural(age, 'jour')} : ${perWeek(rate)} '
          '(objectif : 2).',
    );
  }

  /// Séances enregistrées les jours sans venue à la salle, sur les 3
  /// dernières semaines : contribution NÉGATIVE (facteur protecteur).
  RiskFactor _homeActivity(
    AppUser u,
    Set<DateTime> visits,
    DateTime recentStart,
    DateTime now,
  ) {
    final homeDays = {
      for (final s in _b.sessions.where((s) => s.userId == u.id))
        if (!s.startedAt.isBefore(recentStart) && !s.startedAt.isAfter(now))
          _day(s.startedAt),
    }.difference(visits);
    final rate = homeDays.length / recentWeeks;
    return RiskFactor(
      key: 'home',
      label: 'Activité à domicile',
      weight: -weightHomeActivity,
      points: -weightHomeActivity * ramp(rate, 0, homeTargetPerWeek),
      detail: homeDays.isEmpty
          ? 'Aucune séance enregistrée hors de la salle ces 3 dernières '
                'semaines.'
          : '${Fmt.plural(homeDays.length, 'jour')} de séance hors de la '
                'salle ces 3 dernières semaines (${Fmt.dec1(rate)} par '
                'semaine) : la personne reste active.',
    );
  }

  // ------------------------------------------------ Accès

  /// Abonnés visibles : tous pour l'admin ; pour un coach, ceux qui ont
  /// suivi au moins un de ses cours sur les 11 dernières semaines.
  Set<String> visibleMemberIds(AppUser staff) {
    final members = {
      for (final u in _b.users.where((u) => u.isMember && u.active)) u.id,
    };
    if (staff.isAdmin) return members;
    final now = _b.now();
    final from = now.subtract(const Duration(days: 7 * historyWeeks));
    final seen = <String>{};
    for (final r in _b.reservations.where(
      (r) => r.status == ReservationStatus.confirmed && r.attended != false,
    )) {
      final c = _b.courses.byId(r.courseId);
      final at = c?.startAt;
      if (c == null || c.coachId != staff.id || at == null) continue;
      if (at.isBefore(from) || at.isAfter(now)) continue;
      seen.add(r.userId);
    }
    return seen.intersection(members);
  }

  AppUser _member(AppUser staff, String memberId) {
    final u = _b.users.byId(memberId) ?? (throw const NotFoundException());
    if (!visibleMemberIds(staff).contains(memberId)) {
      throw const PermissionDeniedException(
        'Cet abonné n\'a pas suivi vos cours récemment.',
      );
    }
    return u;
  }

  /// Évaluation d'un abonné (coach concerné ou admin).
  RiskAssessment assess(String memberId) {
    final me = _b.requireRole(Backend.staff);
    return compute(_member(me, memberId));
  }

  /// Abonnés visibles, du score le plus élevé au plus faible.
  List<RiskAssessment> ranking() {
    final me = _b.requireRole(Backend.staff);
    return [for (final id in visibleMemberIds(me)) compute(_b.users.byId(id)!)]
      ..sort((a, b) => b.score.compareTo(a.score));
  }

  // ------------------------------------------------ Message (IA)

  /// Message calculé : repli quand l'IA est absente ou non conforme.
  String templateMessage(AppUser u, RiskAssessment a) {
    final keys = a.active.map((f) => f.key).toSet();
    final reason = keys.contains('expiry')
        ? 'Votre formule arrive bientôt à son terme : passez nous voir, nous '
              'trouverons ensemble celle qui vous convient.'
        : keys.contains('newcomer')
        ? 'Les premières semaines sont les plus importantes : je peux vous '
              'aider à trouver les cours qui vous conviennent.'
        : 'Vous nous manquez ces derniers temps ! Un cours adapté à votre '
              'rythme vous attend.';
    return 'Bonjour ${u.firstName}, $reason Votre objectif '
        '« ${u.goal.label} » reste à portée de main. À très bientôt à la salle !';
  }

  bool _aiDown = false;
  bool get aiEnabled => _b.gemini.enabled && !_aiDown;

  /// Brouillon du message : rédigé par l'IA si possible, sinon calculé.
  /// Seuls le prénom, l'objectif et les libellés des facteurs sont envoyés.
  /// Le coach relit, modifie et envoie lui-même.
  Future<(String, bool)> draftMessage(String memberId) async {
    final me = _b.requireRole(Backend.staff);
    final u = _member(me, memberId);
    final a = compute(u);
    final fallback = templateMessage(u, a);
    if (!aiEnabled) return (fallback, false);
    final reply = await _b.gemini.generate(
      system:
          'Tu aides un coach d\'une salle de sport tunisienne à écrire un '
          'court message bienveillant à un abonné qui vient moins souvent. '
          '${ProductAiService.rules} Écris 2 ou 3 phrases (60 mots au plus) '
          'en vouvoyant, sans culpabiliser, sans chiffre, sans donnée de '
          'santé ni promesse commerciale ; commence par « Bonjour » suivi du '
          'prénom et termine par une invitation à revenir. '
          'Format : {"message": "..."}.',
      contents: GeminiClient.userMessage(
        jsonEncode({
          'prénom': u.firstName,
          'objectif': u.goal.label,
          'constats': [for (final f in a.active) f.label],
        }),
      ),
      temperature: 0.6,
      maxOutputTokens: 300,
      json: true,
      schema: GeminiClient.stringFields(['message']),
    );
    if (!reply.ok) {
      _aiDown = true;
      return (fallback, false);
    }
    final text = parseDraft(reply.text!, u.firstName);
    return text == null ? (fallback, false) : (text, true);
  }

  /// Valide le brouillon de l'IA : JSON attendu, longueur raisonnable,
  /// sans lien ni balise, aucun chiffre, et adressé au bon prénom.
  static String? parseDraft(String raw, String firstName) {
    final s = ProductAiService.cleanText(
      ProductAiService.decodeJson(raw)?['message'],
      min: 30,
      max: 600,
    );
    if (s == null || RegExp(r'\d').hasMatch(s)) return null;
    return s.contains(firstName) ? s : null;
  }

  // ------------------------------------------------ Actions

  Future<RiskAction> _record(
    AppUser me,
    AppUser member,
    RiskActionKind kind, {
    String text = '',
    bool emailSent = false,
    String? packId,
  }) async {
    final a = compute(member);
    final action = await _b.riskActions.save(
      RiskAction(
        id: IdGen.next('ra_'),
        memberId: member.id,
        actorId: me.id,
        kind: kind,
        at: _b.now(),
        score: a.score,
        level: a.level,
        factors: a.factors,
        text: text,
        emailSent: emailSent,
        packId: packId,
      ),
    );
    await _b.audit.log(
      'Accompagnement : ${kind.label}',
      '${member.fullName} (score ${a.score})',
      targetId: member.id,
    );
    _b.bus.emit();
    return action;
  }

  /// Envoie le message relu par le coach (notification, et e-mail si
  /// EmailJS est configuré).
  Future<RiskAction> sendMessage(String memberId, String text) async {
    final me = _b.requireRole(Backend.staff);
    final u = _member(me, memberId);
    final t = text.trim();
    if (t.length < 10 || t.length > 800) {
      throw const ValidationException('Message : de 10 à 800 caractères.');
    }
    await _b.notifications.notify(
      u.id,
      NotificationType.coach,
      'Message de ${me.firstName}',
      t,
    );
    final email = await _b.mailer.sendCoachMessage(
      toEmail: u.email,
      name: u.firstName,
      coachName: me.fullName,
      message: t,
    );
    return _record(me, u, RiskActionKind.message, text: t, emailSent: email);
  }

  /// Offre une séance d'essai (au plus une tous les 30 jours).
  Future<RiskAction> offerTrial(String memberId) async {
    final me = _b.requireRole(Backend.staff);
    final u = _member(me, memberId);
    final since = _b.now().subtract(trialCooldown);
    if (_b.riskActions.all.any(
      (a) =>
          a.memberId == u.id &&
          a.kind == RiskActionKind.trial &&
          a.at.isAfter(since),
    )) {
      throw const BusinessRuleException(
        'Une séance d\'essai a déjà été offerte ces 30 derniers jours.',
      );
    }
    final pack = await _b.packs.grantTrial(u.id);
    return _record(me, u, RiskActionKind.trial, packId: pack.id);
  }

  /// Enregistre l'appel du coach et sa note.
  Future<RiskAction> logCall(String memberId, String note) async {
    final me = _b.requireRole(Backend.staff);
    final u = _member(me, memberId);
    final t = note.trim();
    if (t.length < 3 || t.length > 500) {
      throw const ValidationException('Note d\'appel : de 3 à 500 caractères.');
    }
    return _record(me, u, RiskActionKind.call, text: t);
  }

  /// Résultat : revenu si une venue a lieu dans les 14 jours qui suivent.
  RiskOutcome outcomeOf(RiskAction a) {
    final until = a.at.add(returnWindow);
    final back = visitTimes(
      a.memberId,
    ).any((t) => t.isAfter(a.at) && !t.isAfter(until));
    if (back) return RiskOutcome.returned;
    return _b.now().isAfter(until)
        ? RiskOutcome.notReturned
        : RiskOutcome.pending;
  }

  /// Actions menées pour un abonné (récentes d'abord).
  List<RiskAction> actionsFor(String memberId) {
    final me = _b.requireRole(Backend.staff);
    _member(me, memberId);
    return _b.riskActions.where((a) => a.memberId == memberId)
      ..sort((x, y) => y.at.compareTo(x.at));
  }

  /// Efficacité par type d'action, sur les abonnés visibles :
  /// (actions, revenus, pas revenus).
  Map<RiskActionKind, (int, int, int)> effectiveness() {
    final me = _b.requireRole(Backend.staff);
    final visible = visibleMemberIds(me);
    final out = <RiskActionKind, (int, int, int)>{
      for (final k in RiskActionKind.values) k: (0, 0, 0),
    };
    for (final a in _b.riskActions.where((a) => visible.contains(a.memberId))) {
      final (n, ok, ko) = out[a.kind]!;
      final o = outcomeOf(a);
      out[a.kind] = (
        n + 1,
        ok + (o == RiskOutcome.returned ? 1 : 0),
        ko + (o == RiskOutcome.notReturned ? 1 : 0),
      );
    }
    return out;
  }
}
