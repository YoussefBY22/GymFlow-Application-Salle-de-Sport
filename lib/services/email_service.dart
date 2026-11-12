import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/config.dart';
import '../core/formatters.dart';
import 'backend.dart';
import 'invoice_service.dart';

/// Envoi d'e-mails réels via l'API externe EmailJS (pas de serveur :
/// l'appel HTTP part directement de l'application, web ou mobile).
/// Les identifiants sont passés au lancement via secrets.json.
class EmailService {
  EmailService(this._b);
  final Backend _b;

  bool get enabled =>
      AppConfig.emailJsServiceId.isNotEmpty &&
      AppConfig.emailJsTemplateId.isNotEmpty &&
      AppConfig.emailJsPublicKey.isNotEmpty;

  bool get invoiceEnabled =>
      enabled && AppConfig.emailJsInvoiceTemplateId.isNotEmpty;

  /// EmailJS refuse les requêtes de plus de 50 Ko : le PDF n'est joint
  /// (pièce jointe variable du modèle) que s'il reste sous cette limite.
  static const maxAttachmentBytes = 36 * 1024;

  /// Envoie la facture : récapitulatif dans le corps du message, PDF joint
  /// s'il est assez léger.
  Future<bool> sendInvoice(InvoiceData d, Uint8List pdf) async {
    if (!invoiceEnabled) return false;
    final lines = d.order.lines
        .map((l) => '${l.quantity} × ${l.name} : ${Fmt.money(l.total)}')
        .join('\n');
    try {
      final res = await _b.httpClient
          .post(
            Uri.parse('https://api.emailjs.com/api/v1.0/email/send'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'service_id': AppConfig.emailJsServiceId,
              'template_id': AppConfig.emailJsInvoiceTemplateId,
              'user_id': AppConfig.emailJsPublicKey,
              'template_params': {
                'to_email': d.customerEmail,
                'name': d.customerName,
                'invoice_number': d.number,
                'lines': lines,
                'total': Fmt.money(d.total),
                if (pdf.length <= maxAttachmentBytes)
                  'invoice_pdf':
                      'data:application/pdf;base64,${base64Encode(pdf)}',
              },
            }),
          )
          .timeout(const Duration(seconds: 20));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  bool get messageEnabled =>
      enabled && AppConfig.emailJsMessageTemplateId.isNotEmpty;

  /// Envoie le message relu et validé par un coach. Renvoie `false` sans
  /// configuration ou en cas d'échec (le message reste dans l'application).
  Future<bool> sendCoachMessage({
    required String toEmail,
    required String name,
    required String coachName,
    required String message,
  }) async {
    if (!messageEnabled) return false;
    try {
      final res = await _b.httpClient
          .post(
            Uri.parse('https://api.emailjs.com/api/v1.0/email/send'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'service_id': AppConfig.emailJsServiceId,
              'template_id': AppConfig.emailJsMessageTemplateId,
              'user_id': AppConfig.emailJsPublicKey,
              'template_params': {
                'to_email': toEmail,
                'name': name,
                'coach': coachName,
                'message': message,
              },
            }),
          )
          .timeout(const Duration(seconds: 20));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Envoie le code de réinitialisation. Renvoie `false` si l'envoi a
  /// échoué (pas de configuration, quota atteint, réseau) : l'application
  /// revient alors à l'affichage du code à l'écran.
  Future<bool> sendResetCode(String email, String code) async {
    if (!enabled) return false;
    final user = _b.users.all
        .where((u) => u.email == email.trim().toLowerCase())
        .firstOrNull;
    try {
      final res = await _b.httpClient
          .post(
            Uri.parse('https://api.emailjs.com/api/v1.0/email/send'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'service_id': AppConfig.emailJsServiceId,
              'template_id': AppConfig.emailJsTemplateId,
              'user_id': AppConfig.emailJsPublicKey,
              'template_params': {
                'to_email': email.trim(),
                'name': user?.firstName ?? 'membre GymFlow',
                'code': code,
              },
            }),
          )
          .timeout(const Duration(seconds: 20));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
