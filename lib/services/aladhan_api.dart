import 'dart:convert';
import 'dart:math' as math;

import '../models/ramadan.dart';
import 'backend.dart';

/// Origine d'une heure de Maghrib.
enum MaghribSource {
  api('Aladhan'),
  estimate('Estimation hors ligne');

  const MaghribSource(this.label);
  final String label;
}

/// API externe Aladhan (gratuite, sans clé), vérifiée sur ses réponses
/// réelles :
/// - `GET /v1/calendarByCity/{année}/{mois}?city=Tunis&country=Tunisia&method=18`
///   → `data[]`, un jour par élément : `timings.Maghrib` = « 17:45 (CET) »,
///   `date.gregorian.date` = « JJ-MM-AAAA » (méthode 18 = Tunisie, Fajr et
///   Isha à 18°) ;
/// - `GET /v1/hToGCalendar/9/{année hégirienne}` → `data[]`, un élément par
///   jour du mois de Ramadan : `gregorian.date`, `hijri.date`.
///
/// Les horaires d'un mois sont mis en cache (collection `prayer_times`) :
/// ils ne changent pas, une seule requête suffit. Hors ligne, sans cache,
/// l'heure est ESTIMÉE par le calcul du coucher du soleil à Tunis (le
/// Maghrib de la méthode tunisienne correspond au coucher du soleil).
class AladhanApi {
  AladhanApi(this._b);
  final Backend _b;

  static const base = 'https://api.aladhan.com/v1';
  static const city = 'Tunis';
  static const country = 'Tunisia';
  static const method = 18;

  /// Tunis : latitude, longitude, fuseau (UTC+1 toute l'année).
  static const latitude = 36.8065;
  static const longitude = 10.1815;
  static const utcOffsetMinutes = 60;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// « 17:45 (CET) » → 1065 minutes.
  static int? parseTime(Object? v) {
    final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch('${v ?? ''}');
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    final min = int.parse(m.group(2)!);
    if (h > 23 || min > 59) return null;
    return h * 60 + min;
  }

  /// « 18-02-2026 » → 18/02/2026.
  static DateTime? parseDate(Object? v) {
    final m = RegExp(r'^(\d{2})-(\d{2})-(\d{4})$').firstMatch('${v ?? ''}');
    if (m == null) return null;
    return DateTime(
      int.parse(m.group(3)!),
      int.parse(m.group(2)!),
      int.parse(m.group(1)!),
    );
  }

  Future<List<dynamic>?> _getList(String url) async {
    try {
      final res = await _b.httpClient
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      final data = j is Map ? j['data'] : null;
      return data is List ? data : null;
    } catch (_) {
      return null;
    }
  }

  /// Met en cache le Maghrib de chaque jour du mois. Renvoie le nombre de
  /// jours enregistrés (0 hors ligne ou réponse inattendue).
  Future<int> fetchMonth(int year, int month) async {
    final data = await _getList(
      '$base/calendarByCity/$year/$month?city=$city&country=$country'
      '&method=$method',
    );
    if (data == null) return 0;
    final now = _b.now();
    final days = <PrayerDay>[];
    for (final e in data) {
      if (e is! Map) continue;
      final d = parseDate((e['date'] as Map?)?['gregorian']?['date']);
      final t = parseTime((e['timings'] as Map?)?['Maghrib']);
      if (d == null || t == null || d.month != month) continue;
      days.add(
        PrayerDay(id: PrayerDay.idOf(d), maghribMinutes: t, fetchedAt: now),
      );
    }
    await _b.prayerTimes.saveAll(days);
    return days.length;
  }

  /// Récupère (si besoin) les mois couvrant [from]–[to]. Les mois déjà en
  /// cache ne sont pas redemandés.
  Future<void> ensure(DateTime from, DateTime to) async {
    var m = DateTime(from.year, from.month);
    final last = DateTime(to.year, to.month);
    while (!m.isAfter(last)) {
      final prefix = PrayerDay.idOf(m).substring(0, 8);
      if (!_b.prayerTimes.all.any((p) => p.id.startsWith(prefix))) {
        await fetchMonth(m.year, m.month);
      }
      m = DateTime(m.year, m.month + 1);
    }
  }

  /// Maghrib d'un jour : cache de l'API, sinon estimation.
  (DateTime, MaghribSource) maghrib(DateTime day) {
    final d = _day(day);
    final cached = _b.prayerTimes.byId(PrayerDay.idOf(d));
    final minutes = cached?.maghribMinutes ?? estimateMinutes(d);
    return (
      d.add(Duration(minutes: minutes)),
      cached == null ? MaghribSource.estimate : MaghribSource.api,
    );
  }

  /// Coucher du soleil à Tunis (minutes depuis minuit, heure locale), par
  /// les formules simplifiées de la NOAA (précision de l'ordre de la
  /// minute) : repli hors ligne.
  static int estimateMinutes(DateTime day) {
    final n = day.difference(DateTime(day.year)).inDays + 1;
    final g = 2 * math.pi / 365 * (n - 1);
    final eqTime =
        229.18 *
        (0.000075 +
            0.001868 * math.cos(g) -
            0.032077 * math.sin(g) -
            0.014615 * math.cos(2 * g) -
            0.040849 * math.sin(2 * g));
    final decl =
        0.006918 -
        0.399912 * math.cos(g) +
        0.070257 * math.sin(g) -
        0.006758 * math.cos(2 * g) +
        0.000907 * math.sin(2 * g) -
        0.002697 * math.cos(3 * g) +
        0.00148 * math.sin(3 * g);
    final lat = latitude * math.pi / 180;
    final ha = math.acos(
      math.cos(90.833 * math.pi / 180) / (math.cos(lat) * math.cos(decl)) -
          math.tan(lat) * math.tan(decl),
    );
    final sunsetUtc = 720 - 4 * (longitude - ha * 180 / math.pi) - eqTime;
    return (sunsetUtc + utcOffsetMinutes).round();
  }

  /// Dates du Ramadan [hijriYear] selon le calendrier d'Aladhan, ou
  /// `null` hors ligne. Ce n'est qu'une PROPOSITION à confirmer.
  Future<(DateTime, DateTime)?> ramadanDates(int hijriYear) async {
    final data = await _getList('$base/hToGCalendar/9/$hijriYear');
    if (data == null || data.isEmpty) return null;
    DateTime? dateOf(Object? e) =>
        e is Map ? parseDate((e['gregorian'] as Map?)?['date']) : null;
    final first = dateOf(data.first);
    final last = dateOf(data.last);
    if (first == null || last == null || last.isBefore(first)) return null;
    return (first, last);
  }

  /// Année hégirienne approximative d'une date (pour choisir le prochain
  /// Ramadan) : l'année hégirienne est 32/33 de l'année solaire.
  static int hijriYearOf(DateTime d) =>
      ((d.year - 622 + (d.month - 1) / 12) * 33 / 32).floor();
}
