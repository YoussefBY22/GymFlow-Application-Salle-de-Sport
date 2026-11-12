import 'enums.dart';
import 'json.dart';

enum CheckInSource {
  qr('QR code'),
  manual('Saisie manuelle');

  const CheckInSource(this.label);
  final String label;
}

/// Entrée d'un abonné à la salle, scannée à l'accueil.
class CheckIn {
  const CheckIn({
    required this.id,
    required this.userId,
    required this.at,
    required this.byId,
    this.exitAt,
    this.source = CheckInSource.qr,
  });

  final String id;
  final String userId;
  final DateTime at;

  /// Membre de l'accueil (admin ou coach) qui a scanné.
  final String byId;

  /// Sortie scannée ; sinon sortie automatique après la durée réglée.
  final DateTime? exitAt;
  final CheckInSource source;

  /// Fin de présence : sortie scannée, ou entrée + [stay].
  DateTime endAt(Duration stay) {
    final auto = at.add(stay);
    final e = exitAt;
    return e != null && e.isBefore(auto) ? e : auto;
  }

  bool isPresentAt(DateTime t, Duration stay) =>
      !t.isBefore(at) && t.isBefore(endAt(stay));

  CheckIn copyWith({DateTime? exitAt}) => CheckIn(
    id: id,
    userId: userId,
    at: at,
    byId: byId,
    exitAt: exitAt ?? this.exitAt,
    source: source,
  );

  Json toJson() => {
    'id': id,
    'userId': userId,
    'at': dateToJson(at),
    'byId': byId,
    'exitAt': dateToJson(exitAt),
    'source': source.name,
  };

  factory CheckIn.fromJson(Json j) => CheckIn(
    id: j['id'] as String,
    userId: j['userId'] as String? ?? '',
    at: dateOr(j['at'], DateTime(2026)),
    byId: j['byId'] as String? ?? '',
    exitAt: dateFromJson(j['exitAt']),
    source: enumFrom(CheckInSource.values, j['source'], CheckInSource.qr),
  );
}
