import 'json.dart';
import 'ramadan.dart';

/// Réglages des cours et de la salle (un seul document, modifié par
/// l'admin). Tous les champs sont facultatifs dans le JSON.
class GymSettings {
  const GymSettings({
    this.freeCancelHours = 12,
    this.capacity = 40,
    this.stayMinutes = 90,
    this.openHour = 6,
    this.closeHour = 22,
    this.ramadanHours = const RamadanHours(),
    this.ramadanPeriods = const [],
  });

  static const id = 'gym';

  /// Annulation au moins ce nombre d'heures avant le cours : le crédit du
  /// carnet est rendu ; plus tard, il est décompté.
  final int freeCancelHours;

  /// Personnes accueillies en même temps dans la salle.
  final int capacity;

  /// Sortie automatique après cette durée si aucune sortie n'est scannée.
  final int stayMinutes;

  /// Horaires d'ouverture : de [openHour] h à [closeHour] h.
  final int openHour;
  final int closeHour;

  /// Horaires et modèles de créneaux du Ramadan.
  final RamadanHours ramadanHours;

  /// Périodes du Ramadan (proposées ou confirmées), une par année hégirienne.
  final List<RamadanPeriod> ramadanPeriods;

  GymSettings copyWith({
    int? freeCancelHours,
    int? capacity,
    int? stayMinutes,
    int? openHour,
    int? closeHour,
    RamadanHours? ramadanHours,
    List<RamadanPeriod>? ramadanPeriods,
  }) => GymSettings(
    freeCancelHours: freeCancelHours ?? this.freeCancelHours,
    capacity: capacity ?? this.capacity,
    stayMinutes: stayMinutes ?? this.stayMinutes,
    openHour: openHour ?? this.openHour,
    closeHour: closeHour ?? this.closeHour,
    ramadanHours: ramadanHours ?? this.ramadanHours,
    ramadanPeriods: ramadanPeriods ?? this.ramadanPeriods,
  );

  Json toJson() => {
    'id': id,
    'freeCancelHours': freeCancelHours,
    'capacity': capacity,
    'stayMinutes': stayMinutes,
    'openHour': openHour,
    'closeHour': closeHour,
    'ramadanHours': ramadanHours.toJson(),
    'ramadanPeriods': ramadanPeriods.map((p) => p.toJson()).toList(),
  };

  factory GymSettings.fromJson(Json j) => GymSettings(
    freeCancelHours: toInt(j['freeCancelHours'], 12),
    capacity: toInt(j['capacity'], 40),
    stayMinutes: toInt(j['stayMinutes'], 90),
    openHour: toInt(j['openHour'], 6),
    closeHour: toInt(j['closeHour'], 22),
    ramadanHours: RamadanHours.fromJson(
      j['ramadanHours'] == null
          ? null
          : Map<String, dynamic>.from(j['ramadanHours'] as Map),
    ),
    ramadanPeriods: jsonList(
      j['ramadanPeriods'],
    ).map(RamadanPeriod.fromJson).toList(),
  );
}
