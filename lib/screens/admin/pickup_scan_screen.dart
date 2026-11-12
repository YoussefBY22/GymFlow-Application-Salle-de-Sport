import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../services/backend.dart';
import '../../widgets/common.dart';

/// Retrait à l'accueil (super admin) : scan du QR code du client, contrôle
/// de la signature puis commande passée à « remise ».
class PickupScanScreen extends StatefulWidget {
  const PickupScanScreen({super.key, this.useCamera});

  /// Forcé dans les tests ; par défaut selon la plateforme.
  final bool? useCamera;

  /// Caméra disponible : Android, iOS et web (sinon saisie manuelle).
  bool get camera =>
      useCamera ??
      (kIsWeb ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  State<PickupScanScreen> createState() => _PickupScanScreenState();
}

class _PickupScanScreenState extends State<PickupScanScreen> {
  final _manual = TextEditingController();
  bool _busy = false;
  String? _last;

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  Future<void> _redeem(String raw) async {
    // Une même image est détectée plusieurs fois par seconde.
    if (_busy || raw == _last) return;
    setState(() {
      _busy = true;
      _last = raw;
    });
    try {
      final o = await Backend.I.pickup.redeem(raw);
      if (!mounted) return;
      await _result(
        ok: true,
        title: 'Commande ${o.number} remise',
        message:
            '${o.itemCount} article(s) · ${Fmt.money(o.total)}. Le client est '
            'prévenu.',
      );
    } catch (e) {
      if (!mounted) return;
      await _result(
        ok: false,
        title: 'Retrait refusé',
        message: friendlyError(e),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _result({
    required bool ok,
    required String title,
    required String message,
  }) => showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      icon: Icon(
        ok ? Icons.check_circle : Icons.error_outline,
        color: ok ? AppColors.successText : AppColors.redText,
        size: 48,
      ),
      title: Text(title, key: const Key('scan_result')),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Retrait d\'une commande')),
      body: ListView(
        padding: pagePadding(context, maxWidth: 600),
        children: [
          if (widget.camera) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(Gap.radius),
              child: SizedBox(
                height: 320,
                child: MobileScanner(
                  onDetect: (capture) {
                    final raw = capture.barcodes.firstOrNull?.rawValue;
                    if (raw != null) _redeem(raw);
                  },
                  errorBuilder: (_, _) => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(Gap.m),
                      child: Text(
                        'Caméra indisponible : autorisez-la ou saisissez le '
                        'code ci-dessous.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Gap.s),
            Text(
              'Visez le QR code affiché dans « Mes commandes » du client.',
              textAlign: TextAlign.center,
              style: AppText.label(),
            ),
            const SizedBox(height: Gap.l),
          ],
          Text('Saisie manuelle', style: AppText.subtitle(size: 15)),
          const SizedBox(height: Gap.s),
          TextField(
            key: const Key('scan_manual'),
            controller: _manual,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Contenu du QR code (GF1|…)',
              prefixIcon: Icon(Icons.qr_code_2),
            ),
          ),
          const SizedBox(height: Gap.s),
          LoadingButton(
            key: const Key('scan_submit'),
            label: 'Vérifier et remettre',
            icon: Icons.verified_outlined,
            loading: _busy,
            onPressed: () {
              _last = null;
              _redeem(_manual.text.trim());
            },
          ),
        ],
      ),
    );
  }
}
