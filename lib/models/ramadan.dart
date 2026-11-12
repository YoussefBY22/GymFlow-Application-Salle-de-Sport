import 'json.dart';

/// Période du Ramadan. Elle peut être pré-remplie par l'API Aladhan
/// (calcul astronomique), mais elle n'est ACTIVE qu'une fois confirmée par
/// l'admin : en Tunisie, le début officiel est annoncé par le Mufti selon
/// l'observation du croissant (en 2026 : Aladhan proposait le 18/02, le
/// Ramadan a commencé le 19/02).
class RamadanPeriod {
  const RamadanPeriod({
    required this.hijriYear,
    required this.start,
    required this.end,
    this.confirmed = false,
    this.source = '',
    this.kept = const [],
  });

  final int hijriYear;

  /// Premier et dernier jour de jeûne (inclus).
  final DateTime start;
  final DateTime end;
  final bool confirmed;

  /// Origine des dates (« Aladhan », « saisie de l'admin »…).
  final String source;

  /// Cours signalés que l'admin a choisi de garder à leur horaire.
  final List<String> kept;

  static DateTime _d(DateTime t) => DateTime(t.year, t.month, t.day);

  bool contains(DateTime t) {
    final d = _d(t);
    return !d.isBefore(_d(start)) && !d.isAfter(_d(end));
  }

  /// Nombre de jours (calcul en UTC : sans effet du changement d'heure).
  int get days =>
      DateTime.utc(
        end.year,
        end.month,
        end.day,
      ).difference(DateTime.utc(start.year, start.month, start.day)).inDays +
      1;

  RamadanPeriod copyWith({
    DateTime? start,
    DateTime? end,
    bool? confirmed,
    String? source,
    List<String>? kept,
  }) => RamadanPeriod(
    hijriYear: hijriYear,
    start: start ?? this.start,
    end: end ?? this.end,
    confirmed: confirmed ?? this.confirmed,
    source: source ?? this.source,
    kept: kept ?? this.kept,
  );

  Json toJson() => {
    'hijriYear': hijriYear,
    'start': dateToJson(start),
    'end': dateToJson(end),
    'confirmed': confirmed,
    'source': source,
    'kept': kept,
  };

  factory RamadanPeriod.fromJson(Json j) => RamadanPeriod(
    hijriYear: toInt(j['hijriYear']),
    start: dateOr(j['start'], DateTime(2026)),
    end: dateOr(j['end'], DateTime(2026)),
    confirmed: j['confirmed'] as bool? ?? false,
    source: j['source'] as String? ?? '',
    kept: stringList(j['kept']),
  );
}

/// Horaires et modèles de créneaux du Ramadan.
class RamadanHours {
  const RamadanHours({
    this.dayOpen = 9,
    this.dayClose = 15,
    this.eveningOffset = 30,
    this.eveningClose = 24,
    this.afterIftarOffset = 75,
    this.lateSlotHour = 22,
  });

  /// Ouverture de journée : de [dayOpen] h à [dayClose] h.
  final int dayOpen;
  final int dayClose;

  /// Réouverture [eveningOffset] minutes après la rupture du jeûne
  /// (Maghrib), jusqu'à [eveningClose] h (24 = minuit, 25 = 1 h).
  final int eveningOffset;
  final int eveningClose;

  /// Modèle « après la rupture du jeûne » : Maghrib + [afterIftarOffset].
  final int afterIftarOffset;

  /// Modèle « créneau tardif » : à [lateSlotHour] h.
  final int lateSlotHour;

  Json toJson() => {
    'dayOpen': dayOpen,
    'dayClose': dayClose,
    'eveningOffset': eveningOffset,
    'eveningClose': eveningClose,
    'afterIftarOffset': afterIftarOffset,
    'lateSlotHour': lateSlotHour,
  };

  factory RamadanHours.fromJson(Json? j) {
    if (j == null) return const RamadanHours();
    return RamadanHours(
      dayOpen: toInt(j['dayOpen'], 9),
      dayClose: toInt(j['dayClose'], 15),
      eveningOffset: toInt(j['eveningOffset'], 30),
      eveningClose: toInt(j['eveningClose'], 24),
      afterIftarOffset: toInt(j['afterIftarOffset'], 75),
      lateSlotHour: toInt(j['lateSlotHour'], 22),
    );
  }
}

/// Heure du Maghrib à Tunis pour un jour (cache de l'API Aladhan).
class PrayerDay {
  const PrayerDay({
    required this.id,
    required this.maghribMinutes,
    required this.fetchedAt,
  });

  /// « AAAA-MM-JJ ».
  final String id;

  /// Minutes depuis minuit (heure de Tunis).
  final int maghribMinutes;
  final DateTime fetchedAt;

  static String idOf(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Json toJson() => {
    'id': id,
    'maghribMinutes': maghribMinutes,
    'fetchedAt': dateToJson(fetchedAt),
  };

  factory PrayerDay.fromJson(Json j) => PrayerDay(
    id: j['id'] as String,
    maghribMinutes: toInt(j['maghribMinutes']),
    fetchedAt: dateOr(j['fetchedAt'], DateTime(2026)),
  );
}
