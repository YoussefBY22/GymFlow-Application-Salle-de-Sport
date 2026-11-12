// Niveau : unitaire (sans réseau). Choix de la passerelle de paiement : tout
// paiement passe par Stripe dès qu'une vraie clé de test est fournie.
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/services/payment/payment_gateway.dart';
import 'package:http/http.dart' as http;

void main() {
  final client = http.Client();
  final real = 'sk_test_${'A' * 60}';

  test('vraie clé de test Stripe : Stripe Checkout', () {
    final g = PaymentGateway.select(client, stripeKey: real);
    expect(g, isA<StripeCheckoutGateway>());
    expect(g, isA<HostedPaymentGateway>());
  });

  test('clé restreinte de test (rk_test_) acceptée', () {
    final g = PaymentGateway.select(client, stripeKey: 'rk_test_${'B' * 60}');
    expect(g, isA<StripeCheckoutGateway>());
  });

  test('sans clé, texte d\'exemple ou clé live : passerelle simulée', () {
    expect(PaymentGateway.select(client), isA<SimulatedPaymentGateway>());
    expect(
      PaymentGateway.select(client, stripeKey: 'sk_test_A_REMPLACER'),
      isA<SimulatedPaymentGateway>(),
    );
    expect(
      PaymentGateway.select(client, stripeKey: 'sk_live_${'C' * 60}'),
      isA<SimulatedPaymentGateway>(),
    );
  });
}
