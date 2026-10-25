import 'json.dart';

/// Noms des événements mesurés.
///
/// Les noms standards de Google Analytics (`view_item`, `add_to_cart`,
/// `purchase`, `search`, `login`, `sign_up`) sont repris tels quels pour que
/// ses rapports e-commerce les reconnaissent. Les autres sont propres à
/// GymFlow. Règle de Google : lettres, chiffres et tiret bas, 40 caractères
/// au plus (un test le vérifie pour chaque nom).
class AnalyticsEvents {
  AnalyticsEvents._();

  // Boutique
  static const viewItem = 'view_item';
  static const addToCart = 'add_to_cart';
  static const purchase = 'purchase';

  /// Local seulement : une ligne d'une commande (quantité et montant), pour
  /// classer les produits. Google reçoit la commande entière via `purchase`.
  static const purchaseItem = 'purchase_item';

  // Cours
  static const courseView = 'course_view';
  static const courseReserve = 'course_reserve';
  static const courseWaitlist = 'course_waitlist';
  static const courseCancel = 'course_cancel';

  // Entraînement
  static const workoutStart = 'workout_start';
  static const workoutComplete = 'workout_complete';
  static const sessionShare = 'session_share';

  // Recherche
  static const search = 'search';

  /// Recherche qui n'a renvoyé aucun résultat : ce que les membres veulent
  /// et que la salle ne propose pas.
  static const searchEmpty = 'search_empty';

  // Compte
  static const login = 'login';
  static const signUp = 'sign_up';

  // Assistant IA : on compte les questions, jamais leur contenu.
  static const chatQuestion = 'chat_question';

  /// Événement envoyé par le bouton de test de l'administrateur.
  static const test = 'gymflow_test';

  static const all = [
    viewItem,
    addToCart,
    purchase,
    purchaseItem,
    courseView,
    courseReserve,
    courseWaitlist,
    courseCancel,
    workoutStart,
    workoutComplete,
    sessionShare,
    search,
    searchEmpty,
    login,
    signUp,
    chatQuestion,
    test,
  ];

  /// Un nom est-il accepté par Google Analytics ?
  static bool isValidName(String name) =>
      RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,39}$').hasMatch(name);

  /// Intitulé lisible d'un événement, pour le tableau de bord.
  static String label(String name) => switch (name) {
    viewItem => 'Produit consulté',
    addToCart => 'Ajout au panier',
    purchase => 'Achat (commande)',
    purchaseItem => 'Produit acheté',
    courseView => 'Cours consulté',
    courseReserve => 'Cours réservé',
    courseWaitlist => 'Liste d\'attente',
    courseCancel => 'Réservation annulée',
    workoutStart => 'Séance lancée',
    workoutComplete => 'Séance terminée',
    sessionShare => 'Séance partagée',
    search => 'Recherche',
    searchEmpty => 'Recherche sans résultat',
    login => 'Connexion',
    signUp => 'Inscription',
    chatQuestion => 'Question à l\'assistant',
    test => 'Événement de test',
    _ => name,
  };
}

/// Compteur agrégé d'un événement pour une journée.
///
/// **Anonyme par construction** : on ne stocke ni identifiant de compte, ni
/// appareil, ni horodatage précis, seulement « tel jour, tel événement, tel
/// élément, tant de fois ». Impossible d'en tirer le parcours d'une
/// personne. C'est aussi ce qui évite de stocker un journal brut qui
/// grossirait sans limite.
class AnalyticsCounter {
  const AnalyticsCounter({
    required this.day,
    required this.name,
    required this.key,
    required this.label,
    required this.count,
    this.value = 0,
  });

  /// Jour au format `aaaa-mm-jj`.
  final String day;

  /// Événement (voir [AnalyticsEvents]).
  final String name;

  /// Élément concerné (identifiant de produit, de cours, terme cherché,
  /// méthode de connexion…), ou chaîne vide.
  final String key;

  /// Nom lisible de l'élément au moment de la mesure (un produit supprimé
  /// reste lisible dans les statistiques).
  final String label;

  final int count;

  /// Somme des montants en TND (achats), sinon 0.
  final double value;

  String get id => '$day|$name|$key';

  /// Ajoute [by] occurrences (la quantité, pour un achat) et [value] TND.
  AnalyticsCounter add({String? label, double value = 0, int by = 1}) =>
      AnalyticsCounter(
        day: day,
        name: name,
        key: key,
        label: (label == null || label.isEmpty) ? this.label : label,
        count: count + by,
        value: this.value + value,
      );

  Json toJson() => {
    'id': id,
    'day': day,
    'name': name,
    'key': key,
    'label': label,
    'count': count,
    'value': value,
  };

  factory AnalyticsCounter.fromJson(Json j) => AnalyticsCounter(
    day: j['day'] as String,
    name: j['name'] as String,
    key: j['key'] as String? ?? '',
    label: j['label'] as String? ?? '',
    count: (j['count'] as num?)?.toInt() ?? 0,
    value: (j['value'] as num?)?.toDouble() ?? 0,
  );
}
