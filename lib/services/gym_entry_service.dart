import 'dart:convert';

import '../core/errors.dart';
import '../models/checkin.dart';
import '../models/enums.dart';
import '../models/session_pack.dart';
import '../models/user.dart';
import '../repositories/repository.dart';
import 'backend.dart';
import 'pickup_qr_service.dart';

/// Résultat d'un scan à l'accueil.
class ScanResult {
  const ScanResult(this.checkIn, this.member, {required this.entered});
  final CheckIn checkIn;
  final AppUser member;

  /// Vrai pour une entrée, faux pour une sortie.
  final bool entered;
}

/// Check-in par QR personnel.
///
/// QR : `GFC1|idAbonné|fenêtre|signature`, où la fenêtre est le numéro de
/// la minute (secondes depuis 1970 / 60) et la signature un HMAC-SHA256
/// calculé avec la clé du QR de retrait (PickupQrService, réutilisée).
/// Le QR change toutes les 60 secondes : une capture d'écran partagée
/// devient inutilisable. La fenêtre précédente reste acceptée pendant les
/// [grace] premières secondes de la suivante (temps de présenter le
/// téléphone), soit au plus 70 secondes de validité.
class GymEntryService {
  GymEntryService(this._b);
  final Backend _b;

  static const version = 'GFC1';
  static const windowSeconds = 60;
  static const grace = 10;

  GymSettings get settings => _b.packs.settings;
  Duration get stay => Duration(minutes: settings.stayMinutes);

  static int windowOf(DateTime t) =>
      t.millisecondsSinceEpoch ~/ 1000 ~/ windowSeconds;

  /// QR d'entrée de l'abonné connecté et fin de sa fenêtre.
  (String, DateTime) myEntryQr() {
    final me = _b.requireRole({UserRole.member});
    final w = windowOf(_b.now());
    final payload = '$version|${me.id}|$w';
    return (
      '$payload|${_b.pickup.signPayload(payload)}',
      DateTime.fromMillisecondsSinceEpoch((w + 1) * windowSeconds * 1000),
    );
  }

  /// Vérifie le QR (format, signature en temps constant, fenêtre).
  AppUser verify(String raw) {
    _b.requireRole(Backend.staff);
    final parts = raw.trim().split('|');
    if (parts.length != 4 || parts[0] != version) {
      throw const ValidationException(
        'Ce QR code n\'est pas un QR d\'entrée GymFlow.',
      );
    }
    final payload = parts.take(3).join('|');
    final ok = PickupQrService.constantTimeEquals(
      utf8.encode(_b.pickup.signPayload(payload)),
      utf8.encode(parts[3]),
    );
    if (!ok) {
      throw const BusinessRuleException(
        'QR code invalide : signature incorrecte.',
      );
    }
    final w = int.tryParse(parts[2]);
    final now = _b.now();
    final cur = windowOf(now);
    final intoWindow = (now.millisecondsSinceEpoch ~/ 1000) % windowSeconds;
    final fresh = w == cur || (w == cur - 1 && intoWindow < grace);
    if (!fresh) {
      throw const BusinessRuleException(
        'QR code expiré : il change toutes les minutes. Demandez à '
        'l\'abonné d\'afficher le code actuel.',
      );
    }
    final u = _b.users.byId(parts[1]);
    if (u == null || !u.isMember) {
      throw const NotFoundException('Abonné introuvable.');
    }
    if (!u.active) {
      throw const BusinessRuleException('Ce compte est désactivé.');
    }
    return u;
  }

  /// Droit d'entrer : abonnement en cours, ou carnet non expiré qui a encore
  /// des séances (formule hebdomadaire : valable jusqu'à sa date de fin).
  bool mayEnter(AppUser u) {
    final now = _b.now();
    if (u.subscription.isActiveAt(now)) return true;
    return _b.packs
        .packsOf(u.id)
        .any(
          (p) =>
              !p.isExpiredAt(now) &&
              (p.kind != PackKind.credits || p.remaining > 0),
        );
  }

  /// Check-in en cours de l'abonné (un seul à la fois).
  CheckIn? openFor(String userId) {
    final now = _b.now();
    return _b.checkIns
        .where((c) => c.userId == userId && c.isPresentAt(now, stay))
        .firstOrNull;
  }

  /// Scan à l'accueil : entrée si l'abonné n'est pas présent, sinon
  /// sortie.
  Future<ScanResult> scan(String raw) async {
    final u = verify(raw);
    return _toggle(u, CheckInSource.qr);
  }

  /// Entrée sans QR (téléphone oublié), par l'accueil.
  Future<ScanResult> manual(String userId) async {
    _b.requireRole(Backend.staff);
    final u = _b.users.byId(userId) ?? (throw const NotFoundException());
    if (!u.isMember || !u.active) {
      throw const BusinessRuleException('Abonné inactif ou introuvable.');
    }
    return _toggle(u, CheckInSource.manual);
  }

  Future<ScanResult> _toggle(AppUser u, CheckInSource source) async {
    final me = _b.requireRole(Backend.staff);
    final now = _b.now();
    final open = openFor(u.id);
    if (open != null) {
      final out = await _b.checkIns.save(open.copyWith(exitAt: now));
      _b.bus.emit();
      return ScanResult(out, u, entered: false);
    }
    // Une sortie reste toujours possible ; une entrée exige un abonnement
    // en cours ou un carnet encore valable.
    if (!mayEnter(u)) {
      throw BusinessRuleException(
        "Accès refusé : l'abonnement de ${u.fullName} est expiré ou arrêté, "
        "et aucun carnet n'est valable.",
      );
    }
    final c = await _b.checkIns.save(
      CheckIn(
        id: IdGen.next('ci_'),
        userId: u.id,
        at: now,
        byId: me.id,
        source: source,
      ),
    );
    _b.bus.emit();
    return ScanResult(c, u, entered: true);
  }

  /// Personnes présentes (accueil uniquement : noms visibles).
  List<(CheckIn, AppUser)> present() {
    _b.requireRole(Backend.staff);
    final now = _b.now();
    return [
      for (final c in _b.checkIns.where((c) => c.isPresentAt(now, stay)))
        if (_b.users.byId(c.userId) case final u?) (c, u),
    ]..sort((a, b) => b.$1.at.compareTo(a.$1.at));
  }

  /// Réglages de la salle (admin).
  Future<GymSettings> saveSettings({
    required int capacity,
    required int stayMinutes,
    required int openHour,
    required int closeHour,
  }) async {
    _b.requireRole(Backend.adminOnly);
    if (capacity < 1 || capacity > 1000) {
      throw const ValidationException('Capacité : de 1 à 1 000 personnes.');
    }
    if (stayMinutes < 30 || stayMinutes > 300) {
      throw const ValidationException(
        'Sortie automatique : de 30 à 300 minutes.',
      );
    }
    if (openHour < 0 || closeHour > 24 || closeHour - openHour < 4) {
      throw const ValidationException(
        'Horaires : ouverture avant fermeture, au moins 4 heures.',
      );
    }
    final s = await _b.gymSettings.save(
      settings.copyWith(
        capacity: capacity,
        stayMinutes: stayMinutes,
        openHour: openHour,
        closeHour: closeHour,
      ),
    );
    await _b.audit.log(
      'Réglages de la salle',
      'Capacité $capacity · sortie auto $stayMinutes min · '
          '${openHour}h–${closeHour}h',
    );
    _b.bus.emit();
    return s;
  }
}
