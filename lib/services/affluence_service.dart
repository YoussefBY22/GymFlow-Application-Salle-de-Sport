import 'dart:math' as math;

import '../core/formatters.dart';
import '../models/enums.dart';
import 'backend.dart';

/// Niveau d'affluence par rapport à la capacité de la salle.
enum Crowd {
  calm('Calme'),
  moderate('Modéré'),
  busy('Chargé'),
  full('Très chargé');

  const Crowd(this.label);
  final String label;

  /// Moins de 35 % de la capacité : calme ; 60 % : modéré ; 85 % : chargé.
  static Crowd of(double rate) => rate < 0.35
      ? calm
      : rate < 0.60
      ? moderate
      : rate < 0.85
      ? busy
      : full;
}

/// Présence d'une personne sur un intervalle (entrée scannée ou cours).
class _Presence {
  const _Presence(this.userId, this.start, this.end, {required this.course});
  final String userId;
  final DateTime start;
  final DateTime end;
  final bool course;

  bool overlaps(DateTime from, DateTime to) =>
      start.isBefore(to) && end.isAfter(from);
}

/// Carte de chaleur jour × heure : nombre moyen de personnes présentes
/// (pondéré), séparé entre accès libre (check-in) et cours.
class Heatmap {
  const Heatmap({
    required this.openHour,
    required this.closeHour,
    required this.free,
    required this.course,
  });

  final int openHour;
  final int closeHour;

  /// Clé : jour (1 = lundi … 7) × 100 + heure.
  final Map<int, double> free;
  final Map<int, double> course;

  static int key(int weekday, int hour) => weekday * 100 + hour;

  double freeAt(int weekday, int hour) => free[key(weekday, hour)] ?? 0;
  double courseAt(int weekday, int hour) => course[key(weekday, hour)] ?? 0;
  double at(int weekday, int hour) =>
      freeAt(weekday, hour) + courseAt(weekday, hour);

  double get max {
    var m = 0.0;
    for (var d = 1; d <= 7; d++) {
      for (var h = openHour; h < closeHour; h++) {
        m = math.max(m, at(d, h));
      }
    }
    return m;
  }
}

/// Prévision pour un créneau d'une heure.
class SlotForecast {
  const SlotForecast({
    required this.start,
    required this.expected,
    required this.booked,
    required this.capacity,
  });

  final DateTime start;

  /// Personnes attendues (historique pondéré + réservations).
  final double expected;

  /// Réservations confirmées sur un cours de ce créneau.
  final int booked;
  final int capacity;

  double get rate => capacity == 0 ? 0 : expected / capacity;
  Crowd get crowd => Crowd.of(rate);
}

/// Créneau conseillé à un abonné.
class SlotSuggestion {
  const SlotSuggestion(this.forecast, this.reason, {this.courseId});
  final SlotForecast forecast;
  final String reason;
  final String? courseId;
}

/// Affluence en temps réel, carte de chaleur, prévision et créneaux
/// conseillés.
///
/// Sources : entrées scannées à l'accueil (présence de l'entrée à la
/// sortie, ou sortie automatique) et présences pointées aux cours. Les
/// séances enregistrées dans l'application ne sont pas comptées (elles
/// peuvent avoir lieu à domicile).
class AffluenceService {
  AffluenceService(this._b);
  final Backend _b;

  /// Carte calculée sur les 8 dernières semaines.
  static const int weeks = 8;

  /// Pondération : une semaine plus ancienne compte 0,85 fois la suivante
  /// (la semaine dernière pèse 1, il y a 4 semaines environ 0,5, il y a 8
  /// semaines 0,32). Les habitudes récentes priment, sans oublier le passé.
  static const double decay = 0.85;

  /// Heures habituelles : au moins 2 venues à la même heure en 8 semaines.
  static const int minHabit = 2;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Décalage en jours CALENDAIRES (sans effet du changement d'heure).
  static DateTime _plusDays(DateTime d, int n) =>
      DateTime(d.year, d.month, d.day + n);

  Duration get _stay => Duration(minutes: _b.packs.settings.stayMinutes);

  /// Présences (entrées et cours pointés) commençant dans [from, to).
  List<_Presence> _presences(DateTime from, DateTime to, {String? userId}) {
    final stay = _stay;
    final list = <_Presence>[
      for (final c in _b.checkIns.where(
        (c) =>
            (userId == null || c.userId == userId) &&
            !c.at.isBefore(from) &&
            c.at.isBefore(to),
      ))
        _Presence(c.userId, c.at, c.endAt(stay), course: false),
    ];
    for (final r in _b.reservations.where(
      (r) =>
          (userId == null || r.userId == userId) &&
          r.status == ReservationStatus.confirmed &&
          r.attended == true,
    )) {
      final c = _b.courses.byId(r.courseId);
      final s = c?.startAt;
      if (s == null || s.isBefore(from) || !s.isBefore(to)) continue;
      list.add(_Presence(r.userId, s, c!.endAt!, course: true));
    }
    return list;
  }

  /// Personnes présentes à l'instant [t] (sans doublon) : entrées en
  /// cours, et inscrits confirmés des cours en cours (le pointage peut
  /// venir après le début).
  int occupancyAt(DateTime t) {
    final stay = _stay;
    final people = <String>{
      for (final c in _b.checkIns.where((c) => c.isPresentAt(t, stay)))
        c.userId,
    };
    for (final r in _b.reservations.where(
      (r) => r.status == ReservationStatus.confirmed && r.attended != false,
    )) {
      final c = _b.courses.byId(r.courseId);
      final s = c?.startAt;
      if (c == null || c.cancelled || s == null) continue;
      if (!t.isBefore(s) && t.isBefore(c.endAt!)) people.add(r.userId);
    }
    return people.length;
  }

  /// Occupation actuelle estimée.
  SlotForecast current() {
    final now = _b.now();
    return SlotForecast(
      start: now,
      expected: occupancyAt(now).toDouble(),
      booked: 0,
      capacity: _b.packs.settings.capacity,
    );
  }

  /// Jours servant au profil : profil normal = les [weeks] dernières
  /// semaines HORS Ramadan ; profil Ramadan = les jours des Ramadans
  /// passés confirmés (au plus [weeks] semaines, les plus récents d'abord).
  List<DateTime> profileDays({required bool ramadan}) {
    final today = _day(_b.now());
    if (!ramadan) {
      return [
        for (var d = 1; d <= 7 * weeks; d++)
          if (!_b.ramadan.isRamadan(_plusDays(today, -d))) _plusDays(today, -d),
      ];
    }
    final days = <DateTime>[];
    for (final p in _b.ramadan.periods.where((p) => p.confirmed)) {
      for (
        var d = _day(p.start);
        !d.isAfter(_day(p.end));
        d = _plusDays(d, 1)
      ) {
        if (d.isBefore(today)) days.add(d);
      }
    }
    days.sort((a, b) => b.compareTo(a));
    return days.take(7 * weeks).toList();
  }

  /// Carte de chaleur pondérée. Le poids d'un jour dépend de son
  /// ancienneté par rapport au jour le plus récent du profil : 0,85 par
  /// semaine. Le profil Ramadan couvre aussi les heures du soir.
  Heatmap heatmap({bool ramadan = false}) {
    final s = _b.packs.settings;
    final days = profileDays(ramadan: ramadan);
    final rh = s.ramadanHours;
    final open = ramadan ? math.min(rh.dayOpen, s.openHour) : s.openHour;
    final close = ramadan
        ? math.min(24, math.max(rh.eveningClose, s.closeHour))
        : s.closeHour;
    if (days.isEmpty) {
      return Heatmap(
        openHour: open,
        closeHour: close,
        free: const {},
        course: const {},
      );
    }
    final latest = days.first;
    final byDay = <DateTime, List<_Presence>>{};
    for (final p in _presences(days.last, _plusDays(latest, 1))) {
      byDay.putIfAbsent(_day(p.start), () => []).add(p);
    }
    final free = <int, double>{};
    final course = <int, double>{};
    final weightOf = <int, double>{};
    for (final day in days) {
      final w = math.pow(decay, latest.difference(day).inDays ~/ 7).toDouble();
      weightOf[day.weekday] = (weightOf[day.weekday] ?? 0) + w;
      final ps = byDay[day] ?? const <_Presence>[];
      for (var h = open; h < close; h++) {
        final a = DateTime(day.year, day.month, day.day, h);
        final b = a.add(const Duration(hours: 1));
        final inCourse = <String>{};
        final inFree = <String>{};
        for (final p in ps) {
          if (!p.overlaps(a, b)) continue;
          (p.course ? inCourse : inFree).add(p.userId);
        }
        inFree.removeAll(inCourse);
        final k = Heatmap.key(day.weekday, h);
        free[k] = (free[k] ?? 0) + w * inFree.length;
        course[k] = (course[k] ?? 0) + w * inCourse.length;
      }
    }
    // Moyenne pondérée par jour de la semaine.
    for (final m in [free, course]) {
      m.updateAll((k, v) {
        final total = weightOf[k ~/ 100] ?? 0;
        return total == 0 ? 0 : v / total;
      });
    }
    return Heatmap(
      openHour: open,
      closeHour: close,
      free: free,
      course: course,
    );
  }

  /// Réservations confirmées sur les cours qui chevauchent le créneau.
  int bookedIn(DateTime from, DateTime to) {
    final people = <String>{};
    for (final c in _b.courses.where(
      (c) =>
          !c.cancelled &&
          c.startAt != null &&
          c.startAt!.isBefore(to) &&
          c.endAt!.isAfter(from),
    )) {
      for (final r in _b.reservations.where(
        (r) => r.courseId == c.id && r.status == ReservationStatus.confirmed,
      )) {
        people.add(r.userId);
      }
    }
    return people.length;
  }

  /// Prévision d'un créneau d'une heure : accès libre selon l'historique
  /// pondéré des mêmes créneaux, plus la part « cours » estimée par le
  /// plus grand de l'historique et des réservations déjà faites.
  SlotForecast forecast(DateTime start, {Heatmap? map}) {
    final m = map ?? heatmap(ramadan: _b.ramadan.isRamadan(start));
    final slot = DateTime(start.year, start.month, start.day, start.hour);
    final booked = bookedIn(slot, slot.add(const Duration(hours: 1)));
    final hist = m.courseAt(slot.weekday, slot.hour);
    return SlotForecast(
      start: slot,
      expected: m.freeAt(slot.weekday, slot.hour) + math.max(hist, booked),
      booked: booked,
      capacity: _b.packs.settings.capacity,
    );
  }

  /// Créneaux calmes conseillés à l'abonné sur les 7 prochains jours,
  /// compatibles avec ses heures habituelles et les cours qu'il suit.
  List<SlotSuggestion> suggestions(String userId, {int count = 3}) {
    final s = _b.packs.settings;
    final now = _b.now();
    final today = _day(now);
    final maps = {
      false: heatmap(),
      if (_b.ramadan.periods.any((p) => p.confirmed))
        true: heatmap(ramadan: true),
    };
    final past = _presences(
      _plusDays(today, -(7 * weeks)),
      now,
      userId: userId,
    );
    final hourCount = <int, int>{};
    for (final p in past) {
      hourCount[p.start.hour] = (hourCount[p.start.hour] ?? 0) + 1;
    }
    final habits = hourCount.entries.where((e) => e.value >= minHabit).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final hours = <int, String>{};
    for (final e in habits) {
      for (final h in [e.key, e.key - 1, e.key + 1]) {
        if (h >= s.openHour && h < s.closeHour - 1) {
          hours.putIfAbsent(
            h,
            () => 'Proche de vos habitudes (vers ${e.key} h).',
          );
        }
      }
    }
    if (hours.isEmpty) {
      for (var h = s.openHour + 1; h < s.closeHour - 1; h++) {
        hours[h] = 'Créneau calme d\'après la fréquentation.';
      }
    }
    // Créneaux déjà pris par ses cours : écartés.
    final mine = [
      for (final r in _b.reservations.where(
        (r) => r.userId == userId && r.status == ReservationStatus.confirmed,
      ))
        ?_b.courses.byId(r.courseId),
    ].where((c) => c.startAt != null && c.startAt!.isAfter(now)).toList();
    bool busy(DateTime a) {
      final b = a.add(const Duration(hours: 1));
      return mine.any((c) => c.startAt!.isBefore(b) && c.endAt!.isAfter(a));
    }

    final candidates = <SlotSuggestion>[];
    for (var d = 0; d < 7; d++) {
      final day = _plusDays(today, d);
      for (final e in hours.entries) {
        final start = DateTime(day.year, day.month, day.day, e.key);
        if (!start.isAfter(now) || busy(start)) continue;
        // Pendant le Ramadan : seulement aux heures d'ouverture du jour.
        final ram = _b.ramadan.isRamadan(start);
        if (!_b.ramadan.fits(start, start.add(const Duration(hours: 1)))) {
          continue;
        }
        candidates.add(
          SlotSuggestion(
            forecast(start, map: maps[ram] ?? maps[false]),
            e.value,
          ),
        );
      }
    }
    // Cours à venir des catégories qu'il suit.
    final followed = {
      for (final r in _b.reservations.where(
        (r) =>
            r.userId == userId &&
            r.status == ReservationStatus.confirmed &&
            r.attended == true,
      ))
        ?_b.courses.byId(r.courseId)?.category,
    };
    for (final c in _b.courses.where(
      (c) =>
          !c.cancelled &&
          followed.contains(c.category) &&
          c.startAt != null &&
          c.startAt!.isAfter(now) &&
          c.startAt!.isBefore(_plusDays(today, 7)),
    )) {
      if (mine.any((m) => m.id == c.id)) continue;
      candidates.add(
        SlotSuggestion(
          forecast(c.startAt!),
          'Cours « ${c.title} » (${c.category.label}, que vous suivez).',
          courseId: c.id,
        ),
      );
    }
    candidates.sort((a, b) {
      final r = a.forecast.expected.compareTo(b.forecast.expected);
      return r != 0 ? r : a.forecast.start.compareTo(b.forecast.start);
    });
    // Un créneau par jour au plus, pour varier les propositions.
    final days = <DateTime>{};
    final out = <SlotSuggestion>[];
    for (final c in candidates) {
      if (out.length == count) break;
      if (days.add(_day(c.forecast.start))) out.add(c);
    }
    return out..sort((a, b) => a.forecast.start.compareTo(b.forecast.start));
  }

  /// « ≈ 12 personnes (30 % de la capacité) ».
  static String describe(SlotForecast f) =>
      '≈ ${Fmt.plural(f.expected.round(), 'personne')} '
      '(${(f.rate * 100).round()} % de la capacité)';
}
