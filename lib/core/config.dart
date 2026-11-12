/// Configuration de l'application.
///
/// Aucune clé n'est écrite dans le code : la clé Stripe **de test** est
/// passée au lancement via `--dart-define-from-file=secrets.json`
/// (fichier ignoré par git, modèle dans `secrets.example.json`).
/// Sans clé, la boutique utilise la passerelle de paiement simulée.
/// Même principe pour les clés d'IA (`GEMINI_API_KEY`, `HF_TOKEN`).
class AppConfig {
  AppConfig._();

  static const String appName = 'GymFlow';

  /// Version affichée dans l'application.
  ///
  /// Doit rester identique à `version:` dans `pubspec.yaml` : un test
  /// (`test/version_test.dart`) compare les deux et échoue en cas d'oubli.
  /// Elle est visible sur l'écran de connexion et dans « À propos », pour
  /// qu'on sache d'un coup d'œil quelle version est installée.
  static const String appVersion = '3.3';
  static const String appVersionFull = '3.3.2';
  static const String gymName = 'GymFlow Club Lac 2';
  static const String gymAddress =
      'Rue du Lac Windermere, Les Berges du Lac 2, Tunis';

  static const String stripeTestSecretKey = String.fromEnvironment(
    'STRIPE_TEST_SECRET_KEY',
  );

  /// Stripe ne gère pas le dinar tunisien : conversion en euros à taux
  /// fixe pour le mode test uniquement (1 EUR ≈ 3,40 TND).
  static const double tndPerEur = 3.40;

  /// Seule une clé de TEST est acceptée (refus des clés live). Une vraie clé
  /// Stripe fait plus de 30 caractères : un texte d'exemple comme
  /// « sk_test_A_REMPLACER » n'active pas Stripe.
  static bool isStripeTestKey(String key) {
    final k = key.trim();
    return (k.startsWith('sk_test_') || k.startsWith('rk_test_')) &&
        k.length >= 30;
  }

  static bool get stripeEnabled => isStripeTestKey(stripeTestSecretKey);

  /// Assistant IA (API externe Google Gemini) : clé passée au lancement
  /// via secrets.json, jamais écrite dans le code.
  static const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

  /// Modèle rapide d'abord, second modèle en secours.
  static const List<String> geminiModels = [
    'gemini-flash-lite-latest',
    'gemini-3.5-flash-lite',
  ];

  /// E-mails réels (API externe EmailJS) : identifiants passés au
  /// lancement via secrets.json. Sans eux, aucun e-mail ne part et un
  /// message invite à passer par l'accueil de la salle.
  /// Servent au code de mot de passe oublié et à la confirmation de
  /// réservation (ticket QR).
  static const String emailJsServiceId = String.fromEnvironment(
    'EMAILJS_SERVICE_ID',
  );
  static const String emailJsTemplateId = String.fromEnvironment(
    'EMAILJS_TEMPLATE_ID',
  );
  static const String emailJsPublicKey = String.fromEnvironment(
    'EMAILJS_PUBLIC_KEY',
  );

  /// Connexion avec Google : identifiant du client **Web** de la console
  /// Google Cloud. Il sert aussi sur Android (`serverClientId`) ; le client
  /// Android, lui, est reconnu par le nom du paquet et l'empreinte de
  /// signature, sans rien à écrire ici. Ce n'est pas un secret : il est
  /// visible dans toute page web qui propose la connexion Google.
  /// Absent : le bouton « Continuer avec Google » n'est pas affiché.
  static const String googleClientId = String.fromEnvironment(
    'GOOGLE_CLIENT_ID',
  );

  static bool get googleSignInEnabled => googleClientId.trim().isNotEmpty;

  /// Google Analytics 4 : mesure d'audience (envoi des événements) et
  /// lecture des rapports (tableau de bord admin).
  ///
  /// - `GA_MEASUREMENT_ID` (« G-… ») et `GA_API_SECRET` servent à *envoyer*
  ///   des événements (Measurement Protocol). Le secret ne permet que
  ///   d'envoyer : même extrait de l'APK, il ne donne accès à aucune donnée.
  /// - `GA_PROPERTY_ID` (numérique) sert à *lire* les rapports. Aucune clé de
  ///   lecture n'est embarquée : l'administrateur se connecte avec son
  ///   compte Google, qui doit avoir accès à la propriété.
  /// Absents : rien n'est envoyé et l'onglet Google Analytics explique
  /// comment configurer.
  static const String gaMeasurementId = String.fromEnvironment(
    'GA_MEASUREMENT_ID',
  );
  static const String gaApiSecret = String.fromEnvironment('GA_API_SECRET');
  static const String gaPropertyId = String.fromEnvironment('GA_PROPERTY_ID');

  static bool get gaCanSend =>
      gaMeasurementId.trim().isNotEmpty && gaApiSecret.trim().isNotEmpty;
  static bool get gaCanRead => gaPropertyId.trim().isNotEmpty;

  /// Supabase (fonction « Amis » : comptes, présence et notifications en
  /// direct entre téléphones). L'URL et la clé « publishable » (anciennement
  /// « anon ») sont publiques par conception : la sécurité repose sur les
  /// règles d'accès de la base (voir `supabase/schema.sql`). Ne jamais mettre
  /// ici la clé `service_role` ni la clé « secret ».
  /// Absentes : la fonction Amis n'est pas proposée.
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
  );

  static bool get supabaseEnabled =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;

  /// Notifications push (Firebase Cloud Messaging) : quatre identifiants
  /// publics du projet Firebase, à copier dans `secrets.json`. Absents : pas
  /// de notification quand l'application est fermée (le reste fonctionne).
  static const String firebaseApiKey = String.fromEnvironment(
    'FIREBASE_API_KEY',
  );
  static const String firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const String firebaseSenderId = String.fromEnvironment(
    'FIREBASE_SENDER_ID',
  );
  static const String firebaseProjectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
  );

  static bool get firebaseEnabled =>
      firebaseApiKey.trim().isNotEmpty &&
      firebaseAppId.trim().isNotEmpty &&
      firebaseSenderId.trim().isNotEmpty &&
      firebaseProjectId.trim().isNotEmpty;

  /// Modèle EmailJS de la facture (facultatif : sans lui, pas d'envoi).
  static const String emailJsInvoiceTemplateId = String.fromEnvironment(
    'EMAILJS_INVOICE_TEMPLATE_ID',
  );

  /// Modèle EmailJS du message d'un coach à un abonné (facultatif : sans
  /// lui, le message n'est envoyé que dans l'application).
  static const String emailJsMessageTemplateId = String.fromEnvironment(
    'EMAILJS_MESSAGE_TEMPLATE_ID',
  );

  /// Clé HMAC des QR codes de retrait (même clé sur tous les appareils).
  /// Sans elle, une clé locale est générée (voir PickupQrService).
  static const String qrHmacKey = String.fromEnvironment('QR_HMAC_KEY');

  /// Matricule fiscal de la salle, imprimé sur les factures s'il est fourni.
  static const String gymTaxId = String.fromEnvironment('GYM_TAX_ID');

  static const String wgerBaseUrl = 'https://wger.de/api/v2';

  /// Clé RapidAPI utilisée pour récupérer les GIFs ExerciseDB.
  static const String exerciseDbApiKey = String.fromEnvironment(
    'EXERCISE_DB_API_KEY',
  );

  /// IA Groq (distincte de Gemini) pour le bilan de progression sportive.
  static const String groqApiKey = String.fromEnvironment('GROQ_API_KEY');
  static const String _groqModel = String.fromEnvironment('GROQ_MODEL');
  static String get groqModel =>
      _groqModel.trim().isEmpty ? 'openai/gpt-oss-120b' : _groqModel.trim();

  /// API Ninjas pour les suggestions d'exercices ciblées.
  static const String apiNinjasKey = String.fromEnvironment('API_NINJAS_KEY');

  /// Clé OpenRouteService (API distincte, réservée aux nouveaux parcours).
  static const String openRouteServiceApiKey = String.fromEnvironment(
    'OPENROUTESERVICE_API_KEY',
  );

  /// Jeton Hugging Face (analyse de sentiment des avis), passé comme la
  /// clé Stripe via `--dart-define-from-file=secrets.json`. Sans jeton,
  /// les avis sont analysés localement par mots-clés.
  static const String hfToken = String.fromEnvironment('HF_TOKEN');

  static bool get sentimentAiEnabled => hfToken.startsWith('hf_');

  /// Modèle multilingue déjà entraîné (5 classes, comprend le français).
  static const String sentimentModelUrl =
      'https://router.huggingface.co/hf-inference/models/'
      'tabularisai/multilingual-sentiment-analysis';
  static const Duration sentimentTimeout = Duration(seconds: 10);

  /// Modèle « flash » vérifié dans la liste `v1beta/models` et appelable
  /// gratuitement (octobre 2026). Remplaçable par `GEMINI_MODEL`.
  static const String defaultGeminiModel = 'gemini-3.7-flash';
  static const String _geminiModel = String.fromEnvironment('GEMINI_MODEL');
  static String get geminiModel =>
      _geminiModel.trim().isEmpty ? defaultGeminiModel : _geminiModel.trim();

  /// Modèle de secours essayé si le principal échoue (quota, surcharge…).
  static const String defaultGeminiFallbackModel = 'gemini-flash-latest';
  static const String _geminiFallbackModel = String.fromEnvironment(
    'GEMINI_FALLBACK_MODEL',
  );
  static String get geminiFallbackModel => _geminiFallbackModel.trim().isEmpty
      ? defaultGeminiFallbackModel
      : _geminiFallbackModel.trim();

  /// Pause avant l'unique nouvel essai sur 429 / 503 / délai dépassé.
  static const Duration geminiRetryDelay = Duration(milliseconds: 1500);

  /// Facultatif : tous les emails partent à cette adresse (comptes de démo
  /// @gymflow.tn fictifs).
  static const String emailJsDemoRecipient = String.fromEnvironment(
    'EMAILJS_DEMO_RECIPIENT',
  );
  static const String emailJsUrl =
      'https://api.emailjs.com/api/v1.0/email/send';
  static const Duration emailTimeout = Duration(seconds: 10);

  /// Délai minimal entre deux envois pour une même réservation.
  static const Duration emailResendDelay = Duration(minutes: 1);

  /// QR Code Server (image du ticket). 300 px : le texte du ticket
  /// (environ 150 caractères) reste net à l'écran.
  /// [data] est encodé avec `Uri.encodeComponent` (accents en UTF-8).
  static String qrImageUrl(String data) =>
      'https://api.qrserver.com/v1/create-qr-code/?size=300x300'
      '&data=${Uri.encodeComponent(data)}';

  static const String geminiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  /// Limites des fichiers uploadés.
  static const int maxImageBytes = 10 * 1024 * 1024;
  static const int maxVideoBytes = 100 * 1024 * 1024;
  static const List<String> imageExtensions = ['jpg', 'jpeg', 'png', 'webp'];
  static const List<String> videoExtensions = [
    'mp4',
    'mov',
    'webm',
    '3gp',
    'mkv',
  ];

  /// Timbre fiscal ajouté une fois par commande (jamais réduit), en DT.
  static const double fiscalStamp = 1.0;

  /// TVA incluse dans les prix de la boutique (taux normal tunisien).
  static const double vatRate = 0.19;

  /// Règles métier.
  static const int maxLoginAttempts = 5;
  static const Duration lockDuration = Duration(minutes: 15);
  static const Duration cancelDeadline = Duration(hours: 2);
  static const Duration resetCodeValidity = Duration(minutes: 15);
}
