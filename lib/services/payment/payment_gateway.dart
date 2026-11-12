import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../models/shop.dart';

/// Résultat d'un paiement. Aucune donnée de carte n'est conservée :
/// seulement la méthode et une référence de transaction.
class PaymentResult {
  const PaymentResult({
    required this.success,
    required this.method,
    required this.reference,
    this.message = '',
    this.amount,
  });

  final bool success;
  final String method;
  final String reference;
  final String message;

  /// Montant encaissé en DT, quand la passerelle le confirme : comparé au
  /// total de la commande avant de l'enregistrer.
  final double? amount;
}

/// Passerelle de paiement (API externe). Deux implémentations : Stripe
/// Checkout en mode test (vraie page de paiement Stripe, carte de test), ou
/// passerelle simulée hors-ligne quand aucune clé Stripe n'est fournie.
abstract class PaymentGateway {
  String get label;

  /// Stripe test si une clé de test valable est fournie, sinon passerelle
  /// simulée.
  factory PaymentGateway.fromConfig(http.Client client) =>
      select(client, stripeKey: AppConfig.stripeTestSecretKey);

  static PaymentGateway select(http.Client client, {String stripeKey = ''}) {
    if (AppConfig.isStripeTestKey(stripeKey)) {
      return StripeCheckoutGateway(client, stripeKey.trim());
    }
    return SimulatedPaymentGateway();
  }
}

/// Page de paiement hébergée par la passerelle.
class HostedSession {
  const HostedSession(this.id, this.url);

  /// Référence de la passerelle (identifiant de la session Stripe).
  final String id;
  final String url;
}

/// Passerelle à page hébergée : l'application crée la session, ouvre la
/// page dans un WebView, puis revérifie le statut auprès de l'API.
abstract class HostedPaymentGateway implements PaymentGateway {
  String get pageTitle;

  /// [total] : montant à payer en DT (réductions et timbre compris).
  Future<HostedSession> createSession({
    required List<CartLine> lines,
    required String customerEmail,
    String customerName = '',
    double? total,
    double discount = 0,
    double stamp = 0,
  });

  Future<PaymentResult> verify(String sessionId);

  /// Adresse indiquant la fin du paiement (succès ou échec) : la page se
  /// ferme et le statut est vérifié.
  bool isFinished(String url);

  /// Adresse d'abandon explicite par le client.
  bool isCancelled(String url);
}

/// Passerelle simulée : écran carte, validation Luhn, cartes de test Stripe.
class SimulatedPaymentGateway implements PaymentGateway {
  SimulatedPaymentGateway({this.latency = const Duration(milliseconds: 900)});

  final Duration latency;

  @override
  String get label => 'Paiement sécurisé (mode test simulé)';

  static const String successCard = '4242424242424242';
  static const String declinedCard = '4000000000000002';
  static const String insufficientCard = '4000000000009995';

  /// Algorithme de Luhn (contrôle du numéro de carte).
  static bool luhnValid(String digits) {
    final n = digits.replaceAll(RegExp(r'\s'), '');
    if (n.length < 12 || n.length > 19 || !RegExp(r'^\d+$').hasMatch(n)) {
      return false;
    }
    var sum = 0;
    var alternate = false;
    for (var i = n.length - 1; i >= 0; i--) {
      var d = int.parse(n[i]);
      if (alternate) {
        d *= 2;
        if (d > 9) d -= 9;
      }
      sum += d;
      alternate = !alternate;
    }
    return sum % 10 == 0;
  }

  static String? validateExpiry(String mmYY, DateTime now) {
    final m = RegExp(r'^(\d{2})/(\d{2})$').firstMatch(mmYY.trim());
    if (m == null) return 'Format MM/AA attendu.';
    final month = int.parse(m.group(1)!);
    final year = 2000 + int.parse(m.group(2)!);
    if (month < 1 || month > 12) return 'Mois invalide.';
    final endOfMonth = DateTime(year, month + 1);
    if (!endOfMonth.isAfter(now)) return 'Carte expirée.';
    return null;
  }

  Future<PaymentResult> charge({
    required String cardNumber,
    required String expiry,
    required String cvc,
    required double amount,
    required DateTime now,
  }) async {
    final number = cardNumber.replaceAll(RegExp(r'\s'), '');
    if (!luhnValid(number)) {
      throw const ValidationException('Numéro de carte invalide.');
    }
    final expError = validateExpiry(expiry, now);
    if (expError != null) throw ValidationException(expError);
    if (!RegExp(r'^\d{3,4}$').hasMatch(cvc.trim())) {
      throw const ValidationException('CVC invalide (3 ou 4 chiffres).');
    }
    if (amount <= 0) throw const ValidationException('Montant invalide.');
    await Future<void>.delayed(latency);
    switch (number) {
      case successCard:
        final ref =
            'SIM-${now.millisecondsSinceEpoch.toRadixString(36).toUpperCase()}'
            '-${Random().nextInt(9999).toString().padLeft(4, '0')}';
        return PaymentResult(
          success: true,
          method: 'simulated',
          reference: ref,
          message: 'Paiement accepté (carte •••• ${number.substring(12)})',
          amount: amount,
        );
      case declinedCard:
        throw const BusinessRuleException('Paiement refusé par la banque.');
      case insufficientCard:
        throw const BusinessRuleException('Fonds insuffisants.');
      default:
        throw const BusinessRuleException(
          'Mode test : utilisez une carte de test (4242 4242 4242 4242).',
        );
    }
  }
}

/// Session Stripe Checkout créée pour le paiement.
typedef StripeSession = HostedSession;

/// Stripe Checkout (mode test) : création de session via l'API REST,
/// page de paiement ouverte dans un WebView, puis vérification du statut.
class StripeCheckoutGateway implements HostedPaymentGateway {
  StripeCheckoutGateway(this._client, this._secretKey)
    : assert(
        _secretKey.startsWith('sk_test_') || _secretKey.startsWith('rk_test_'),
        'Clé de TEST uniquement',
      );

  final http.Client _client;
  final String _secretKey;

  static const String successUrl = 'https://gymflow.app/paiement/succes';
  static const String cancelUrl = 'https://gymflow.app/paiement/annule';
  static const String _api = 'https://api.stripe.com/v1';

  @override
  String get label => 'Stripe Checkout (mode test)';

  @override
  String get pageTitle => 'Paiement sécurisé Stripe';

  @override
  bool isFinished(String url) => url.startsWith(successUrl);

  @override
  bool isCancelled(String url) => url.startsWith(cancelUrl);

  /// Montant en centimes d'euro (Stripe ne gère pas le TND).
  static int eurCents(double tnd) => (tnd / AppConfig.tndPerEur * 100).round();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $_secretKey',
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  /// Avec une réduction, la commande est envoyée en une seule ligne au
  /// montant net ; le timbre fiscal est toujours une ligne à part.
  @override
  Future<StripeSession> createSession({
    required List<CartLine> lines,
    required String customerEmail,
    String customerName = '',
    double? total,
    double discount = 0,
    double stamp = 0,
  }) async {
    final body = <String, String>{
      'mode': 'payment',
      'success_url': '$successUrl?session_id={CHECKOUT_SESSION_ID}',
      'cancel_url': cancelUrl,
      'customer_email': customerEmail,
      'locale': 'fr',
    };
    final items = <(String, int, double)>[
      if (discount > 0)
        (
          'Commande GymFlow (réduction incluse)',
          1,
          lines.fold<double>(0, (s, l) => s + l.total) - discount,
        )
      else
        for (final l in lines)
          (l.product.name, l.quantity, l.product.effectivePrice),
      if (stamp > 0) ('Timbre fiscal', 1, stamp),
    ];
    for (var i = 0; i < items.length; i++) {
      final (name, quantity, unit) = items[i];
      body['line_items[$i][quantity]'] = '$quantity';
      body['line_items[$i][price_data][currency]'] = 'eur';
      body['line_items[$i][price_data][unit_amount]'] = '${eurCents(unit)}';
      body['line_items[$i][price_data][product_data][name]'] = name;
    }
    try {
      final res = await _client
          .post(
            Uri.parse('$_api/checkout/sessions'),
            headers: _headers,
            body: body,
          )
          .timeout(const Duration(seconds: 20));
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        throw BusinessRuleException(
          'Stripe : ${(json['error'] as Map?)?['message'] ?? 'erreur ${res.statusCode}'}',
        );
      }
      return StripeSession(json['id'] as String, json['url'] as String);
    } on AppException {
      rethrow;
    } catch (_) {
      throw const NetworkException();
    }
  }

  /// Revérifie côté Stripe que la session est bien payée.
  @override
  Future<PaymentResult> verify(String sessionId) async {
    try {
      final res = await _client
          .get(
            Uri.parse('$_api/checkout/sessions/$sessionId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 20));
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final paid = res.statusCode == 200 && json['payment_status'] == 'paid';
      return PaymentResult(
        success: paid,
        method: 'stripe_test',
        reference: (json['payment_intent'] as String?) ?? sessionId,
        message: paid ? 'Paiement Stripe accepté' : 'Paiement non finalisé',
      );
    } catch (_) {
      throw const NetworkException();
    }
  }
}
