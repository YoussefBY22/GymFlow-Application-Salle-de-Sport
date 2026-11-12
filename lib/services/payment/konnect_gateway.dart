import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/errors.dart';
import '../../models/shop.dart';
import 'payment_gateway.dart';

/// Konnect (passerelle de paiement tunisienne, montants en dinars) dans son
/// environnement de test (sandbox) uniquement.
///
/// Documentation officielle (docs.konnect.network) :
/// - `POST /payments/init-payment` avec l'en-tête `x-api-key` ; montant en
///   millimes pour le TND ; réponse `payUrl` et `paymentRef` ;
/// - `GET /payments/{paymentRef}` : `payment.status` vaut `completed` quand
///   le paiement a réussi (`pending` sinon). Seul ce statut fait foi.
///
/// Les adresses de retour (`successUrl`, `failUrl`) sont dépréciées et le
/// webhook demande un serveur : l'application revérifie donc toujours le
/// statut par l'API quand la page de paiement se ferme. Aucune donnée de
/// carte ne transite par l'application (saisie sur la page Konnect).
class KonnectGateway implements HostedPaymentGateway {
  KonnectGateway(this._client, this._apiKey, this._walletId);

  final http.Client _client;
  final String _apiKey;
  final String _walletId;

  /// Environnement de test uniquement (aucune adresse de production).
  static const String api = 'https://api.sandbox.konnect.network/api/v2';
  static const String method = 'konnect_sandbox';

  /// Durée de validité du lien de paiement, en minutes.
  static const int lifespan = 15;

  @override
  String get label => 'Konnect, paiement en dinars (bac à sable)';

  @override
  String get pageTitle => 'Paiement sécurisé Konnect';

  /// Pages de fin de la passerelle (succès ou échec).
  @override
  bool isFinished(String url) =>
      url.contains('payment-success') || url.contains('payment-failure');

  @override
  bool isCancelled(String url) => false;

  /// Dinars → millimes (unité attendue par Konnect pour le TND).
  static int millimes(double tnd) => (tnd * 1000).round();

  Map<String, String> get _headers => {
    'x-api-key': _apiKey,
    'Content-Type': 'application/json',
  };

  static String _error(http.Response res) {
    if (res.statusCode == 401 || res.statusCode == 403) {
      return 'Konnect : clé API refusée. Vérifiez KONNECT_API_KEY (sandbox).';
    }
    try {
      final j = jsonDecode(res.body);
      final m = j is Map
          ? (j['message'] ??
                (j['errors'] is List
                    ? (j['errors'] as List).firstOrNull
                    : null))
          : null;
      if (m != null) return 'Konnect : ${m is Map ? m['message'] ?? m : m}';
    } catch (_) {
      // Réponse non JSON.
    }
    return 'Konnect : erreur ${res.statusCode}.';
  }

  @override
  Future<HostedSession> createSession({
    required List<CartLine> lines,
    required String customerEmail,
    String customerName = '',
    double? total,
    double discount = 0,
    double stamp = 0,
  }) async {
    final amount =
        total ??
        lines.fold<double>(0, (s, l) => s + l.total) - discount + stamp;
    if (amount <= 0) throw const ValidationException('Montant invalide.');
    final name = customerName.trim().split(RegExp(r'\s+'));
    final body = {
      'receiverWalletId': _walletId,
      'token': 'TND',
      'amount': millimes(amount),
      'type': 'immediate',
      'description': lines.length == 1
          ? 'GymFlow : ${lines.first.quantity} × ${lines.first.product.name}'
          : 'GymFlow : commande de ${lines.length} articles',
      'acceptedPaymentMethods': ['wallet', 'bank_card', 'e-DINAR'],
      'lifespan': lifespan,
      'checkoutForm': false,
      'addPaymentFeesToAmount': false,
      if (name.first.isNotEmpty) 'firstName': name.first,
      if (name.length > 1) 'lastName': name.sublist(1).join(' '),
      if (customerEmail.isNotEmpty) 'email': customerEmail,
      'theme': 'light',
    };
    try {
      final res = await _client
          .post(
            Uri.parse('$api/payments/init-payment'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 && res.statusCode != 201) {
        throw BusinessRuleException(_error(res));
      }
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final ref = j['paymentRef'] as String?;
      final url = j['payUrl'] as String?;
      if (ref == null || url == null) {
        throw const BusinessRuleException('Konnect : réponse inattendue.');
      }
      return HostedSession(ref, url);
    } on AppException {
      rethrow;
    } catch (_) {
      throw const NetworkException();
    }
  }

  /// Statut du paiement auprès de Konnect (seule source de vérité).
  @override
  Future<PaymentResult> verify(String paymentRef) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{6,64}$').hasMatch(paymentRef)) {
      throw const ValidationException('Référence de paiement invalide.');
    }
    final http.Response res;
    try {
      res = await _client
          .get(Uri.parse('$api/payments/$paymentRef'), headers: _headers)
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw const NetworkException();
    }
    if (res.statusCode != 200) throw BusinessRuleException(_error(res));
    final Map<String, dynamic> payment;
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      payment = Map<String, dynamic>.from(j['payment'] as Map);
    } catch (_) {
      throw const BusinessRuleException('Konnect : réponse inattendue.');
    }
    final paid = payment['status'] == 'completed' && payment['token'] == 'TND';
    final millimesPaid = payment['amount'];
    return PaymentResult(
      success: paid,
      method: method,
      reference: paymentRef,
      message: paid ? 'Paiement Konnect accepté' : 'Paiement non finalisé',
      amount: paid && millimesPaid is num ? millimesPaid / 1000 : null,
    );
  }
}
