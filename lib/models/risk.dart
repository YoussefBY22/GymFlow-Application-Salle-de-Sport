import 'enums.dart';
import 'json.dart';

/// Niveau de risque d'abandon et action conseillée.
enum RiskLevel {
  low('Faible', RiskActionKind.message),
  medium('Moyen', RiskActionKind.trial),
  high('Élevé', RiskActionKind.call);

  const RiskLevel(this.label, this.suggested);
  final String label;

  /// Action proposée au coach pour ce niveau.
  final RiskActionKind suggested;
}

/// Action d'accompagnement menée par un coach ou l'admin.
enum RiskActionKind {
  message('Message personnalisé'),
  trial('Séance d\'essai offerte'),
  call('Appel du coach');

  const RiskActionKind(this.label);
  final String label;
}

/// Résultat d'une action, calculé à partir des venues qui suivent.
enum RiskOutcome {
  pending('En attente'),
  returned('Revenu'),
  notReturned('Pas revenu');

  const RiskOutcome(this.label);
  final String label;
}

/// Un facteur du score : sa contribution (0 à [weight] points) et une
/// explication chiffrée lisible.
class RiskFactor {
  const RiskFactor({
    required this.key,
    required this.label,
    required this.weight,
    required this.points,
    required this.detail,
  });

  final String key;
  final String label;

  /// Points maximum du facteur.
  final double weight;

  /// Contribution au score (0 à [weight]).
  final double points;
  final String detail;

  double get share => weight == 0 ? 0 : points / weight;

  Json toJson() => {
    'key': key,
    'label': label,
    'weight': weight,
    'points': points,
    'detail': detail,
  };

  factory RiskFactor.fromJson(Json j) => RiskFactor(
    key: j['key'] as String? ?? '',
    label: j['label'] as String? ?? '',
    weight: toDouble(j['weight']),
    points: toDouble(j['points']),
    detail: j['detail'] as String? ?? '',
  );
}

/// Évaluation d'un abonné (calculée à la demande, jamais stockée).
class RiskAssessment {
  const RiskAssessment({
    required this.userId,
    required this.score,
    required this.level,
    required this.factors,
    required this.computedAt,
    required this.weeklyVisits,
    this.lastVisit,
  });

  final String userId;

  /// Score de 0 à 100 : somme des contributions des facteurs.
  final int score;
  final RiskLevel level;
  final List<RiskFactor> factors;
  final DateTime computedAt;

  /// Jours de venue par semaine, de la plus ancienne à la plus récente.
  final List<int> weeklyVisits;
  final DateTime? lastVisit;

  /// Facteurs qui comptent, du plus lourd au plus léger.
  List<RiskFactor> get active =>
      factors.where((f) => f.points > 0).toList()
        ..sort((a, b) => b.points.compareTo(a.points));
}

/// Action d'accompagnement enregistrée (suivi de l'efficacité).
class RiskAction {
  const RiskAction({
    required this.id,
    required this.memberId,
    required this.actorId,
    required this.kind,
    required this.at,
    required this.score,
    required this.level,
    this.factors = const [],
    this.text = '',
    this.emailSent = false,
    this.packId,
  });

  final String id;
  final String memberId;
  final String actorId;
  final RiskActionKind kind;
  final DateTime at;

  /// Score et facteurs au moment de l'action.
  final int score;
  final RiskLevel level;
  final List<RiskFactor> factors;

  /// Message envoyé, ou note de l'appel.
  final String text;
  final bool emailSent;

  /// Carnet offert (séance d'essai).
  final String? packId;

  Json toJson() => {
    'id': id,
    'memberId': memberId,
    'actorId': actorId,
    'kind': kind.name,
    'at': dateToJson(at),
    'score': score,
    'level': level.name,
    'factors': factors.map((f) => f.toJson()).toList(),
    'text': text,
    'emailSent': emailSent,
    'packId': packId,
  };

  factory RiskAction.fromJson(Json j) => RiskAction(
    id: j['id'] as String,
    memberId: j['memberId'] as String? ?? '',
    actorId: j['actorId'] as String? ?? '',
    kind: enumFrom(RiskActionKind.values, j['kind'], RiskActionKind.message),
    at: dateOr(j['at'], DateTime(2026)),
    score: toInt(j['score']),
    level: enumFrom(RiskLevel.values, j['level'], RiskLevel.low),
    factors: jsonList(j['factors']).map(RiskFactor.fromJson).toList(),
    text: j['text'] as String? ?? '',
    emailSent: j['emailSent'] as bool? ?? false,
    packId: j['packId'] as String?,
  );
}
