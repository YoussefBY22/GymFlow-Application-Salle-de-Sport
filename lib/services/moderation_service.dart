import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../models/chat.dart';
import 'backend.dart';
import 'friends/friends_remote.dart';

/// Signalements de la messagerie, côté **administrateur**.
///
/// Les signalements vivent sur Supabase (la base est partagée entre tous les
/// téléphones), alors que le compte administrateur de GymFlow est local. Pour
/// les lire, l'administrateur relie son compte à Supabase avec son mot de
/// passe ; la base décide ensuite si ce compte est bien administrateur (son
/// adresse figure dans `private.admin_emails`).
///
/// Seul l'administrateur voit les signalements : jamais la personne
/// signalée, jamais les blocages.
class ModerationService extends ChangeNotifier {
  ModerationService(this._b, this._remote);

  final Backend _b;
  final FriendsRemote? _remote;

  bool _connected = false;
  Object? _error;
  List<ReportEntry> _reports = const [];
  int _newCount = 0;

  bool get available => _remote != null;
  bool get connected => _connected;
  Object? get error => _error;
  List<ReportEntry> get reports => _reports;

  /// Signalements pas encore traités (pastille du tableau de bord).
  int get newCount => _newCount;

  FriendsRemote get _r =>
      _remote ?? (throw const BusinessRuleException('Service indisponible.'));

  /// Reprend une session déjà ouverte pour ce même compte administrateur.
  Future<void> resume() async {
    if (!available || _connected) return;
    final me = _b.auth.currentUser;
    if (me == null || !me.isAdmin) return;
    try {
      final hasSession = await _r.restore();
      if (hasSession &&
          (_r.userEmail ?? '').toLowerCase() == me.email.toLowerCase()) {
        await _verifyAdmin();
      }
    } catch (e) {
      _error = e;
      notifyListeners();
    }
  }

  /// Relie le compte administrateur à Supabase (mot de passe vérifié
  /// localement avant l'envoi).
  Future<void> connect(String password) async {
    final me = _b.requireRole(Backend.adminOnly);
    if (!available) {
      throw const BusinessRuleException(
        'Supabase n\'est pas configuré dans cette version.',
      );
    }
    if (!_b.auth.checkPassword(password)) {
      throw const ValidationException('Mot de passe incorrect.');
    }
    _error = null;
    try {
      final result = await _r.signIn(
        email: me.email,
        password: password,
        displayName: me.fullName,
        create: true,
      );
      if (result == RemoteSignIn.refused) {
        throw const BusinessRuleException(
          'Mot de passe refusé par le service de messagerie.',
        );
      }
      await _verifyAdmin();
    } catch (e) {
      _connected = false;
      _error = e;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _verifyAdmin() async {
    final settings = await _r.loadSettings();
    if (!settings.isAdmin) {
      _connected = false;
      throw const BusinessRuleException(
        'Ce compte n\'est pas reconnu comme administrateur par le service '
        'de messagerie.',
      );
    }
    _connected = true;
    _error = null;
    await refresh();
  }

  /// Relit les signalements et le compteur de nouveaux.
  Future<void> refresh() async {
    _b.requireRole(Backend.adminOnly);
    _reports = await _r.adminLoadReports();
    _newCount = await _r.adminNewReportsCount();
    notifyListeners();
  }

  /// Marque un signalement comme traité (note facultative).
  Future<void> handle(ReportEntry report, {String? note}) async {
    _b.requireRole(Backend.adminOnly);
    await _r.adminHandleReport(report.id, note: note);
    await refresh();
  }

  /// Déconnexion : on oublie tout.
  void reset() {
    _connected = false;
    _error = null;
    _reports = const [];
    _newCount = 0;
    notifyListeners();
  }
}
