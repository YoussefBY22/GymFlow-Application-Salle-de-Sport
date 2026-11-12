import '../core/errors.dart';
import '../core/formatters.dart';
import '../models/course.dart';
import '../models/enums.dart';
import '../models/ramadan.dart';
import 'aladhan_api.dart';
import 'backend.dart';

/// Plage d'ouverture d'une journée.
typedef OpenRange = (DateTime, DateTime);

/// Cours programmé qui pose problème pendant le Ramadan, avec un décalage
/// proposé (jamais appliqué sans la validation de l'admin).
class RamadanConflict {
  const RamadanConflict(this.course, this.reasons, this.proposal);
  final Course course;
  final List<String> reasons;

  /// Nouveau début proposé, ou `null` si aucun créneau ne convient.
  final DateTime? proposal;
}

/// Mode Ramadan : période confirmée par l'admin, horaires spécifiques,
/// modèles de créneaux, signalement des cours en conflit et aperçu.
///
/// Tout est calculé à partir de la date : hors période, rien ne change
/// (retour automatique au planning normal, sans tâche à lancer).
class RamadanService {
  RamadanService(this._b);
  final Backend _b;

  /// Fenêtre de la rupture du jeûne : 30 min avant le Maghrib (préparer le
  /// repas) à 45 min après (repas).
  static const iftarBefore = Duration(minutes: 30);
  static const iftarAfter = Duration(minutes: 45);

  /// Effort intense déconseillé en journée pendant le jeûne.
  static const intense = {
    CourseCategory.hiit,
    CourseCategory.boxing,
    CourseCategory.spinning,
    CourseCategory.strength,
  };

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Décalage en jours CALENDAIRES (sans effet du changement d'heure).
  static DateTime _plusDays(DateTime d, int n) =>
      DateTime(d.year, d.month, d.day + n);

  RamadanHours get hours => _b.packs.settings.ramadanHours;
  List<RamadanPeriod> get periods => _b.packs.settings.ramadanPeriods;

  // ------------------------------------------------ Période

  /// Période confirmée contenant [t] (les propositions ne comptent pas).
  RamadanPeriod? periodOf(DateTime t) =>
      periods.where((p) => p.confirmed && p.contains(t)).firstOrNull;

  bool isRamadan(DateTime t) => periodOf(t) != null;

  bool get isActiveNow => isRamadan(_b.now());

  /// Prochaine période (en cours ou à venir), confirmée ou non.
  RamadanPeriod? get upcoming {
    final today = _day(_b.now());
    final list = periods.where((p) => !p.end.isBefore(today)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return list.firstOrNull;
  }

  /// Pré-remplit la prochaine période avec Aladhan (non confirmée).
  Future<RamadanPeriod> prefill() async {
    _b.requireRole(Backend.adminOnly);
    _guardPreview();
    final today = _day(_b.now());
    final y = AladhanApi.hijriYearOf(today);
    for (final year in [y, y + 1]) {
      final dates = await _b.aladhan.ramadanDates(year);
      if (dates == null) {
        throw const NetworkException(
          'Aladhan injoignable : saisissez les dates du Ramadan vous-même.',
        );
      }
      if (dates.$2.isBefore(today)) continue;
      final existing = periods.where((p) => p.hijriYear == year).firstOrNull;
      if (existing != null && existing.confirmed) return existing;
      final p = RamadanPeriod(
        hijriYear: year,
        start: dates.$1,
        end: dates.$2,
        source: 'Aladhan (calcul astronomique) : à confirmer',
      );
      await _savePeriods([...periods.where((x) => x.hijriYear != year), p]);
      return p;
    }
    throw const BusinessRuleException('Aucun Ramadan à venir trouvé.');
  }

  /// Confirmation (ou saisie) des dates par l'admin, après l'annonce
  /// officielle. Seule une période confirmée active le mode Ramadan.
  Future<RamadanPeriod> confirm({
    required int hijriYear,
    required DateTime start,
    required DateTime end,
  }) async {
    _b.requireRole(Backend.adminOnly);
    _guardPreview();
    final days = _day(end).difference(_day(start)).inDays + 1;
    if (days < 29 || days > 30) {
      throw const ValidationException(
        'Le Ramadan dure 29 ou 30 jours : vérifiez les dates.',
      );
    }
    final old = periods.where((p) => p.hijriYear == hijriYear).firstOrNull;
    final p = RamadanPeriod(
      hijriYear: hijriYear,
      start: _day(start),
      end: _day(end),
      confirmed: true,
      source:
          old != null &&
              (_day(old.start) != _day(start) || _day(old.end) != _day(end))
          ? 'Dates corrigées par l\'admin (annonce officielle)'
          : (old?.source.replaceAll(' : à confirmer', '') ??
                'Saisie de l\'admin'),
      kept: old?.kept ?? const [],
    );
    await _savePeriods([...periods.where((x) => x.hijriYear != hijriYear), p]);
    await _b.audit.log(
      'Ramadan confirmé',
      '$hijriYear : du ${Fmt.date(p.start)} au ${Fmt.date(p.end)}',
    );
    return p;
  }

  Future<void> saveHours(RamadanHours h) async {
    _b.requireRole(Backend.adminOnly);
    _guardPreview();
    if (h.dayOpen < 0 ||
        h.dayClose <= h.dayOpen ||
        h.eveningOffset < 0 ||
        h.eveningOffset > 180 ||
        h.eveningClose < 20 ||
        h.eveningClose > 26 ||
        h.lateSlotHour < 18 ||
        h.lateSlotHour >= h.eveningClose) {
      throw const ValidationException('Horaires du Ramadan incohérents.');
    }
    await _b.gymSettings.save(_b.packs.settings.copyWith(ramadanHours: h));
    await _b.audit.log('Horaires du Ramadan', 'Mise à jour');
    _b.bus.emit();
  }

  Future<void> _savePeriods(List<RamadanPeriod> list) async {
    list.sort((a, b) => a.start.compareTo(b.start));
    await _b.gymSettings.save(_b.packs.settings.copyWith(ramadanPeriods: list));
    _b.bus.emit();
  }

  // ------------------------------------------------ Horaires

  (DateTime, MaghribSource) maghrib(DateTime day) => _b.aladhan.maghrib(day);

  /// Plages d'ouverture d'un jour : horaires normaux, ou pendant le
  /// Ramadan journée + soirée après la rupture du jeûne.
  List<OpenRange> openRanges(DateTime day, {bool? ramadan}) {
    final d = _day(day);
    final s = _b.packs.settings;
    if (!(ramadan ?? isRamadan(d))) {
      return [
        (
          d.add(Duration(hours: s.openHour)),
          d.add(Duration(hours: s.closeHour)),
        ),
      ];
    }
    final h = hours;
    final (m, _) = maghrib(d);
    return [
      (d.add(Duration(hours: h.dayOpen)), d.add(Duration(hours: h.dayClose))),
      (
        m.add(Duration(minutes: h.eveningOffset)),
        d.add(Duration(hours: h.eveningClose)),
      ),
    ];
  }

  bool fits(DateTime start, DateTime end, {bool? ramadan}) => openRanges(
    start,
    ramadan: ramadan,
  ).any((r) => !start.isBefore(r.$1) && !end.isAfter(r.$2));

  /// Modèles de créneaux du jour : après la rupture du jeûne, tardif.
  List<(String, DateTime)> slots(DateTime day) {
    final d = _day(day);
    final (m, _) = maghrib(d);
    final raw = m.add(Duration(minutes: hours.afterIftarOffset));
    // Arrondi au quart d'heure supérieur, plus lisible pour un planning.
    final q = (raw.minute / 15).ceil() * 15;
    return [
      (
        'Après la rupture du jeûne',
        DateTime(
          raw.year,
          raw.month,
          raw.day,
          raw.hour,
        ).add(Duration(minutes: q)),
      ),
      ('Créneau tardif', d.add(Duration(hours: hours.lateSlotHour))),
    ];
  }

  /// Cours en journée pendant le jeûne : intensité conseillée réduite.
  bool reducedIntensity(Course c, {bool? ramadan}) {
    final s = c.startAt;
    if (s == null || !(ramadan ?? isRamadan(s))) return false;
    return s.isBefore(maghrib(s).$1);
  }

  // ------------------------------------------------ Conflits

  /// Raisons pour lesquelles [c] pose problème un jour de Ramadan.
  List<String> reasonsFor(Course c, {DateTime? at}) {
    final start = at ?? c.startAt!;
    final end = start.add(Duration(minutes: c.durationMin));
    final (m, _) = maghrib(start);
    final reasons = <String>[];
    if (!fits(start, end, ramadan: true)) {
      reasons.add('Hors des horaires d\'ouverture du Ramadan.');
    }
    if (start.isBefore(m.add(iftarAfter)) &&
        end.isAfter(m.subtract(iftarBefore))) {
      reasons.add('Pendant la rupture du jeûne (Maghrib à ${Fmt.time(m)}).');
    }
    if (intense.contains(c.category) && start.isBefore(m)) {
      reasons.add('Effort intense en journée, pendant le jeûne.');
    }
    return reasons;
  }

  /// Cours programmés de la période qui posent problème, avec un décalage
  /// proposé. LECTURE SEULE : rien n'est modifié ici.
  List<RamadanConflict> conflicts(RamadanPeriod p) {
    final now = _b.now();
    final list = <RamadanConflict>[];
    for (final c in _b.courses.where(
      (c) =>
          !c.cancelled &&
          c.startAt != null &&
          c.startAt!.isAfter(now) &&
          p.contains(c.startAt!) &&
          !p.kept.contains(c.id),
    )) {
      final reasons = reasonsFor(c);
      if (reasons.isEmpty) continue;
      list.add(RamadanConflict(c, reasons, _propose(c)));
    }
    return list..sort((a, b) => a.course.startAt!.compareTo(b.course.startAt!));
  }

  /// Premier modèle de créneau du même jour sans problème et sans
  /// chevauchement avec un autre cours du coach ou de la salle.
  DateTime? _propose(Course c) {
    for (final (_, start) in slots(c.startAt!)) {
      if (!start.isAfter(_b.now())) continue;
      if (reasonsFor(c, at: start).isNotEmpty) continue;
      final end = start.add(Duration(minutes: c.durationMin));
      final clash = _b.courses.all.any(
        (o) =>
            o.id != c.id &&
            !o.cancelled &&
            o.startAt != null &&
            (o.coachId == c.coachId || o.room == c.room) &&
            o.startAt!.isBefore(end) &&
            o.endAt!.isAfter(start),
      );
      if (!clash) return start;
    }
    return null;
  }

  /// Décale un cours APRÈS validation de l'admin. Passe par
  /// CourseService.save, qui prévient les inscrits du nouvel horaire.
  Future<Course> applyShift(String courseId, DateTime start) async {
    _b.requireRole(Backend.adminOnly);
    _guardPreview();
    final c = _b.courses.byId(courseId) ?? (throw const NotFoundException());
    if (!isRamadan(start)) {
      throw const BusinessRuleException(
        'Le nouvel horaire n\'est pas dans une période de Ramadan confirmée.',
      );
    }
    final reasons = reasonsFor(c, at: start);
    if (reasons.isNotEmpty) throw BusinessRuleException(reasons.first);
    final moved = await _b.courseService.save(
      id: c.id,
      title: c.title,
      description: c.description,
      category: c.category,
      level: c.level,
      coachId: c.coachId,
      room: c.room,
      capacity: c.capacity,
      durationMin: c.durationMin,
      startAt: start,
      priceIncluded: c.priceIncluded,
      creditCost: c.creditCost,
      imageUrl: c.imageUrl,
    );
    await _b.audit.log(
      'Ramadan : cours décalé',
      '${c.title} : ${Fmt.dateTime(c.startAt!)} → ${Fmt.dateTime(start)}',
      targetId: c.id,
    );
    return moved;
  }

  /// L'admin garde l'horaire : le cours n'est plus signalé.
  Future<void> keep(String courseId) async {
    _b.requireRole(Backend.adminOnly);
    _guardPreview();
    final c = _b.courses.byId(courseId) ?? (throw const NotFoundException());
    final p =
        periodOf(c.startAt ?? _b.now()) ??
        (throw const BusinessRuleException('Cours hors du Ramadan.'));
    await _savePeriods([
      for (final x in periods)
        x.hijriYear == p.hijriYear ? x.copyWith(kept: [...x.kept, c.id]) : x,
    ]);
    await _b.audit.log('Ramadan : horaire conservé', c.title, targetId: c.id);
  }

  // ------------------------------------------------ Aperçu

  /// Aperçu en cours : AUCUNE modification n'est acceptée.
  bool previewActive = false;

  void _guardPreview() {
    if (previewActive) {
      throw const BusinessRuleException(
        'Aperçu du mode Ramadan en cours : aucune modification n\'est '
        'enregistrée. Quittez l\'aperçu pour agir.',
      );
    }
  }

  /// Période simulée « si le Ramadan commençait aujourd'hui » (30 jours),
  /// jamais enregistrée : elle permet de voir les horaires, les créneaux,
  /// l'intensité réduite et les conflits du planning actuel.
  RamadanPeriod previewPeriod() {
    _b.requireRole(Backend.adminOnly);
    final today = _day(_b.now());
    return RamadanPeriod(
      hijriYear: 0,
      start: today,
      end: _plusDays(today, 29),
      confirmed: true,
      source: 'Aperçu (simulation)',
    );
  }

  /// Conflits du planning actuel dans la période simulée (lecture seule).
  List<RamadanConflict> previewConflicts() {
    final p = previewPeriod();
    final now = _b.now();
    return [
      for (final c in _b.courses.where(
        (c) =>
            !c.cancelled &&
            c.startAt != null &&
            c.startAt!.isAfter(now) &&
            p.contains(c.startAt!),
      ))
        if (reasonsFor(c) case final r when r.isNotEmpty)
          RamadanConflict(c, r, _propose(c)),
    ]..sort((a, b) => a.course.startAt!.compareTo(b.course.startAt!));
  }
}
