import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../core/config.dart';
import '../core/errors.dart';
import '../core/formatters.dart';
import '../models/enums.dart';
import '../models/shop.dart';
import 'backend.dart';

/// QR code de retrait d'une commande : `GF1|idCommande|expiration|signature`
/// où la signature est un HMAC-SHA256 du reste. Un QR fabriqué ou modifié
/// (autre commande, expiration repoussée) est refusé.
class PickupQrService {
  PickupQrService(this._b);
  final Backend _b;

  static const version = 'GF1';
  static const validity = Duration(hours: 48);
  static const _storageKey = 'qr_hmac_key';

  List<int>? _key;

  /// Vrai si la clé vient de secrets.json (QR_HMAC_KEY).
  bool configured = false;

  /// Charge la clé de signature. Priorité à QR_HMAC_KEY (secrets.json),
  /// identique sur tous les appareils. Sinon, clé aléatoire générée au
  /// premier lancement et gardée dans le stockage sécurisé : ce repli ne
  /// fonctionne que parce que les données de l'application sont locales à
  /// un seul appareil (le QR est généré et vérifié sur le même appareil).
  Future<void> loadKey({String configKey = AppConfig.qrHmacKey}) async {
    if (configKey.isNotEmpty) {
      _key = utf8.encode(configKey);
      configured = true;
      return;
    }
    final stored = await _b.sessionStorage.read(_storageKey);
    if (stored != null && stored.isNotEmpty) {
      _key = base64Url.decode(stored);
      return;
    }
    final r = Random.secure();
    final key = List<int>.generate(32, (_) => r.nextInt(256));
    await _b.sessionStorage.write(_storageKey, base64Url.encode(key));
    _key = key;
  }

  List<int> get _secret =>
      _key ?? (throw StateError('Clé de signature des QR non chargée.'));

  String _sign(String payload) => base64Url
      .encode(Hmac(sha256, _secret).convert(utf8.encode(payload)).bytes)
      .replaceAll('=', '');

  /// Signature HMAC-SHA256 d'un contenu, avec la même clé : réutilisée par
  /// le QR d'entrée à la salle (CheckInService).
  String signPayload(String payload) => _sign(payload);

  /// Comparaison en temps constant (pas d'arrêt au premier écart), pour ne
  /// rien révéler de la signature attendue.
  static bool constantTimeEquals(List<int> a, List<int> b) {
    var diff = a.length ^ b.length;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ (i < b.length ? b[i] : 0);
    }
    return diff == 0;
  }

  /// Contenu du QR pour le client (ou l'admin) ; valable [validity].
  String generate(String orderId) {
    final o =
        _b.orderService.byId(orderId) ?? (throw const NotFoundException());
    if (o.status == OrderStatus.delivered) {
      throw const BusinessRuleException('Commande déjà remise.');
    }
    final exp = _b.now().add(validity).millisecondsSinceEpoch ~/ 1000;
    final payload = '$version|${o.id}|$exp';
    return '$payload|${_sign(payload)}';
  }

  /// Date de fin de validité inscrite dans un QR.
  static DateTime? expiryOf(String raw) {
    final parts = raw.split('|');
    final exp = parts.length == 4 ? int.tryParse(parts[2]) : null;
    return exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp * 1000);
  }

  /// Vérifie format, signature et validité ; renvoie la commande.
  ShopOrder verify(String raw) {
    _b.requireRole(Backend.adminOnly);
    final parts = raw.trim().split('|');
    if (parts.length != 4 || parts[0] != version) {
      throw const ValidationException('Ce QR code n\'est pas un QR GymFlow.');
    }
    final payload = parts.take(3).join('|');
    final ok = constantTimeEquals(
      utf8.encode(_sign(payload)),
      utf8.encode(parts[3]),
    );
    if (!ok) {
      throw const BusinessRuleException(
        'QR code invalide : signature incorrecte.',
      );
    }
    final exp = int.tryParse(parts[2]);
    if (exp == null || _b.now().millisecondsSinceEpoch ~/ 1000 > exp) {
      throw const BusinessRuleException(
        'QR code expiré : le client doit rouvrir sa commande.',
      );
    }
    return _b.orders.byId(parts[1]) ??
        (throw const NotFoundException('Commande introuvable.'));
  }

  /// Retrait à l'accueil : QR vérifié puis commande « préparée » passée à
  /// « remise » (OrderService.advance prévient le client).
  Future<ShopOrder> redeem(String raw) async {
    final o = verify(raw);
    switch (o.status) {
      case OrderStatus.paid:
        throw BusinessRuleException(
          'Commande ${o.number} pas encore préparée : préparez-la avant la '
          'remise.',
        );
      case OrderStatus.delivered:
        throw BusinessRuleException('Commande ${o.number} déjà remise.');
      case OrderStatus.prepared:
        final done = await _b.orderService.advance(o.id);
        await _b.audit.log(
          'Retrait par QR code',
          '${o.number} · ${Fmt.money(o.total)}',
          targetId: o.id,
        );
        return done;
    }
  }
}
