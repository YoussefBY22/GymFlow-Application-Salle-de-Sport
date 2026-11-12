/// Configuration de l'application.
///
/// Aucune clé n'est écrite dans le code : la clé Stripe **de test** est
/// passée au lancement via `--dart-define-from-file=secrets.json`
/// (fichier ignoré par git, modèle dans `secrets.example.json`).
/// Sans clé, la boutique utilise la passerelle de paiement simulée.
class AppConfig {
  AppConfig._();

  static const String appName = 'GymFlow';
  static const String gymName = 'GymFlow Club Lac 2';
  static const String gymAddress =
      'Rue du Lac Windermere, Les Berges du Lac 2, Tunis';

  static const String stripeTestSecretKey = String.fromEnvironment(
    'STRIPE_TEST_SECRET_KEY',
  );

  /// Stripe ne gère pas le dinar tunisien : conversion en euros à taux
  /// fixe pour le mode test uniquement (1 EUR ≈ 3,40 TND).
  static const double tndPerEur = 3.40;

  /// Konnect (passerelle tunisienne, en dinars), environnement de test
  /// (sandbox) uniquement : clé API et identifiant du portefeuille
  /// receveur, créés sur dashboard.sandbox.konnect.network.
  static const String konnectApiKey = String.fromEnvironment('KONNECT_API_KEY');
  static const String konnectWalletId = String.fromEnvironment(
    'KONNECT_WALLET_ID',
  );

  /// Seule une clé de TEST est acceptée (refus des clés live).
  static bool get stripeEnabled => stripeTestSecretKey.startsWith('sk_test_');

  /// Assistant IA (API externe Google Gemini) : clé passée au lancement
  /// via secrets.json, jamais écrite dans le code.
  static const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

  /// Modèle rapide d'abord, second modèle en secours.
  static const List<String> geminiModels = [
    'gemini-flash-lite-latest',
    'gemini-3.5-flash-lite',
  ];

  /// E-mails réels (API externe EmailJS) : identifiants passés au
  /// lancement via secrets.json. Sans eux, l'e-mail reste simulé.
  static const String emailJsServiceId = String.fromEnvironment(
    'EMAILJS_SERVICE_ID',
  );
  static const String emailJsTemplateId = String.fromEnvironment(
    'EMAILJS_TEMPLATE_ID',
  );
  static const String emailJsPublicKey = String.fromEnvironment(
    'EMAILJS_PUBLIC_KEY',
  );

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
