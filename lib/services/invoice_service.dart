import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/formatters.dart';
import '../models/shop.dart';
import 'backend.dart';

/// Montants d'une facture, calculés par le code à partir de la commande.
/// Les prix de la boutique sont TTC : la TVA est extraite du montant net.
class InvoiceData {
  const InvoiceData({
    required this.order,
    required this.customerName,
    required this.customerEmail,
    required this.totalHt,
    required this.vat,
  });

  final ShopOrder order;
  final String customerName;
  final String customerEmail;
  final double totalHt;
  final double vat;

  /// Numéro de facture = numéro de commande (GF-AAAA-NNNN).
  String get number => order.number;
  double get subtotal => order.subtotal;
  double get discount => order.discount;

  /// Montant TTC après réduction (base de la TVA).
  double get netTtc => order.netSales;
  double get stamp => order.stamp;

  /// Total de la facture = montant payé.
  double get total => order.total;

  static double _r2(double v) => (v * 100).roundToDouble() / 100;

  factory InvoiceData.of(ShopOrder o, {String name = '', String email = ''}) {
    final ht = _r2(o.netSales / (1 + AppConfig.vatRate));
    return InvoiceData(
      order: o,
      customerName: name,
      customerEmail: email,
      totalHt: ht,
      vat: _r2(o.netSales - ht),
    );
  }
}

/// Factures PDF des commandes : génération, téléchargement et envoi par
/// e-mail (EmailJS) quand il est configuré.
class InvoiceService {
  InvoiceService(this._b);
  final Backend _b;

  /// Données de la facture (client concerné ou super admin uniquement).
  InvoiceData data(String orderId) {
    final o =
        _b.orderService.byId(orderId) ?? (throw const NotFoundException());
    final u = _b.users.byId(o.userId);
    return InvoiceData.of(
      o,
      name: u?.fullName ?? 'Client GymFlow',
      email: u?.email ?? '',
    );
  }

  String fileName(String orderId) => 'Facture-${data(orderId).number}.pdf';

  /// PDF de la facture (polices Inter embarquées pour les accents).
  Future<Uint8List> pdf(String orderId) async {
    final d = data(orderId);
    final regular = pw.Font.ttf(
      await rootBundle.load('assets/google_fonts/Inter-Regular.ttf'),
    );
    final bold = pw.Font.ttf(
      await rootBundle.load('assets/google_fonts/Inter-Bold.ttf'),
    );
    const navy = PdfColor.fromInt(0xFF002855);
    final doc = pw.Document(
      title: 'Facture ${d.number}',
      author: AppConfig.gymName,
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
    );
    pw.Widget amount(String label, double v, {bool strong = false}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Row(
            children: [
              pw.Expanded(
                child: pw.Text(
                  label,
                  style: strong ? pw.TextStyle(font: bold, fontSize: 12) : null,
                ),
              ),
              pw.Text(
                Fmt.money(v),
                style: strong ? pw.TextStyle(font: bold, fontSize: 12) : null,
              ),
            ],
          ),
        );
    final o = d.order;
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        AppConfig.gymName,
                        style: pw.TextStyle(
                          font: bold,
                          fontSize: 18,
                          color: navy,
                        ),
                      ),
                      pw.Text(AppConfig.gymAddress),
                      if (AppConfig.gymTaxId.isNotEmpty)
                        pw.Text('Matricule fiscal : ${AppConfig.gymTaxId}'),
                    ],
                  ),
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(
                      'FACTURE',
                      style: pw.TextStyle(font: bold, fontSize: 18),
                    ),
                    pw.Text('N° ${d.number}'),
                    pw.Text('Date : ${Fmt.date(o.createdAt)}'),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 24),
            pw.Text('Client', style: pw.TextStyle(font: bold)),
            pw.Text(d.customerName),
            if (d.customerEmail.isNotEmpty) pw.Text(d.customerEmail),
            pw.SizedBox(height: 16),
            pw.TableHelper.fromTextArray(
              headers: ['Désignation', 'Qté', 'P.U. TTC', 'Total TTC'],
              data: [
                for (final l in o.lines)
                  [
                    l.name,
                    '${l.quantity}',
                    Fmt.money(l.unitPrice),
                    Fmt.money(l.total),
                  ],
              ],
              headerStyle: pw.TextStyle(font: bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: navy),
              cellAlignments: {
                1: pw.Alignment.center,
                2: pw.Alignment.centerRight,
                3: pw.Alignment.centerRight,
              },
              columnWidths: {
                0: const pw.FlexColumnWidth(4),
                1: const pw.FlexColumnWidth(1),
                2: const pw.FlexColumnWidth(2),
                3: const pw.FlexColumnWidth(2),
              },
            ),
            pw.SizedBox(height: 16),
            pw.Row(
              children: [
                pw.Spacer(),
                pw.SizedBox(
                  width: 260,
                  child: pw.Column(
                    children: [
                      amount('Sous-total TTC', d.subtotal),
                      if (d.discount > 0)
                        amount(
                          'Réduction${o.discountLabel == null ? '' : ' (${o.discountLabel})'}',
                          -d.discount,
                        ),
                      amount('Total HT', d.totalHt),
                      amount(
                        'TVA ${(AppConfig.vatRate * 100).round()} %',
                        d.vat,
                      ),
                      if (d.stamp > 0) amount('Timbre fiscal', d.stamp),
                      pw.Divider(),
                      amount('Total TTC payé', d.total, strong: true),
                    ],
                  ),
                ),
              ],
            ),
            pw.Spacer(),
            pw.Text(
              'Payée le ${Fmt.date(o.createdAt)} · ${_method(o.paymentMethod)} '
              '· réf. ${o.paymentRef}',
            ),
            pw.Text(
              'Montants en dinars tunisiens (DT). Prix TTC, TVA incluse.',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
          ],
        ),
      ),
    );
    return doc.save();
  }

  static String _method(String m) => switch (m) {
    'stripe_test' => 'Stripe (test)',
    _ => 'paiement test simulé',
  };

  /// Envoie la facture par e-mail si EmailJS est configuré ; `false` sinon
  /// (ou en cas d'échec : la facture reste téléchargeable).
  Future<bool> email(String orderId) async {
    if (!_b.email.invoiceEnabled) return false;
    final d = data(orderId);
    if (d.customerEmail.isEmpty) return false;
    return _b.email.sendInvoice(d, await pdf(orderId));
  }
}
