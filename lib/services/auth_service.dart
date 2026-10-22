import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/config.dart';
import '../core/errors.dart';
import '../core/formatters.dart';
import '../core/legal.dart';
import '../core/security.dart';
import '../core/validators.dart';
import '../models/enums.dart';
import '../models/privacy.dart';
import '../models/user.dart';
import '../repositories/repository.dart';
import 'backend.dart';

/// API interne d'authentification : inscription, connexion, session,
/// verrouillage après échecs, mot de passe oublié (flux simulé).
class AuthService extends ChangeNotifier {
  AuthService(this._b)
    : hasher = PasswordHasher(iterations: _b.passwordIterations);

  final Backend _b;
  final PasswordHasher hasher;
  static const _tokenKey = 'gymflow_session_token';
  static const _userKey = 'gymflow_session_user';

  AppUser? _current;

  /// Message à afficher sur l'écran de connexion (ex. compte désactivé).
  String? pendingMessage;

  AppUser? get currentUser => _current;
  bool get isLoggedIn => _current != null;

  /// Restaure la session au lancement ; invalide la session d'un compte
  /// désactivé ou d'un jeton inconnu.
  Future<void> restoreSession() async {
    final token = await _b.sessionStorage.read(_tokenKey);
    final userId = await _b.sessionStorage.read(_userKey);
    if (token == null || userId == null) return;
    final cred = _b.credentials.byId(userId);
    final user = _b.users.byId(userId);
    final valid =
        cred?.sessionDigest != null &&
        PasswordHasher.constantTimeEquals(
          cred!.sessionDigest!,
          tokenDigest(token),
        );
    if (user == null || !valid) {
      await _clearStoredSession();
      return;
    }
    if (!user.active) {
      await _b.credentials.save(cred.copyWith(clearSession: true));
      await _clearStoredSession();
      pendingMessage =
          'Votre compte a été désactivé par la salle. Contactez l\'accueil.';
      return;
    }
    _current = user;
    notifyListeners();
  }

  /// Crée les données d'authentification d'un utilisateur.
  Future<void> setPassword(String userId, String password) async {
    final salt = hasher.newSalt();
    final existing = _b.credentials.byId(userId);
    final cred = Credential(
      userId: userId,
      hash: hasher.hash(password, salt),
      salt: salt,
      iterations: hasher.iterations,
      sessionDigest: existing?.sessionDigest,
    );
    await _b.credentials.save(cred);
  }

  /// Mots de passe du jeu de démonstration (réservé au `SeedService`).
  ///
  /// Ces mots de passe sont publics (écran de connexion, README) : les
  /// comptes qui partagent le même mot de passe partagent donc un même sel
  /// et une même empreinte, ce qui ne révèle rien de plus. On calcule ainsi
  /// 3 empreintes au lieu d'une par compte, sans bloquer l'affichage
  /// ([PasswordHasher.hashAsync]). Les comptes créés par inscription
  /// gardent un sel propre ([setPassword]).
  Future<void> setDemoPasswords(Map<String, String> passwordByUserId) async {
    final byPassword = <String, (String, String)>{};
    final creds = <Credential>[];
    for (final e in passwordByUserId.entries) {
      final (salt, hash) = byPassword[e.value] ??= await () async {
        final salt = hasher.newSalt();
        return (salt, await hasher.hashAsync(e.value, salt));
      }();
      creds.add(
        Credential(
          userId: e.key,
          hash: hash,
          salt: salt,
          iterations: hasher.iterations,
          sessionDigest: _b.credentials.byId(e.key)?.sessionDigest,
        ),
      );
    }
    await _b.credentials.saveAll(creds);
  }

  AppUser? _findByEmail(String email) {
    final e = email.trim().toLowerCase();
    for (final u in _b.users.all) {
      if (u.email.toLowerCase() == e) return u;
    }
    return null;
  }

  Future<AppUser> login(String email, String password) async {
    if (Validators.email(email) != null || password.isEmpty) {
      throw const ValidationException(
        'Saisissez votre e-mail et mot de passe.',
      );
    }
    const generic = 'E-mail ou mot de passe incorrect.';
    final user = _findByEmail(email);
    final cred = user == null ? null : _b.credentials.byId(user.id);
    if (user == null || cred == null) throw const ValidationException(generic);

    final now = _b.now();
    if (cred.lockedUntil != null && cred.lockedUntil!.isAfter(now)) {
      final minutes = cred.lockedUntil!.difference(now).inMinutes + 1;
      throw BusinessRuleException(
        'Trop de tentatives. Compte verrouillé, réessayez dans $minutes min.',
      );
    }

    final ok = hasher.verify(password, cred.salt, cred.hash, cred.iterations);
    if (!ok) {
      final attempts = cred.failedAttempts + 1;
      if (attempts >= AppConfig.maxLoginAttempts) {
        await _b.credentials.save(
          cred.copyWith(
            failedAttempts: 0,
            lockedUntil: now.add(AppConfig.lockDuration),
          ),
        );
        throw BusinessRuleException(
          'Trop de tentatives. Compte verrouillé pendant '
          '${AppConfig.lockDuration.inMinutes} min.',
        );
      }
      await _b.credentials.save(
        cred.copyWith(failedAttempts: attempts, clearLock: true),
      );
      final left = AppConfig.maxLoginAttempts - attempts;
      throw ValidationException(
        '$generic Encore ${Fmt.plural(left, 'essai')} avant verrouillage.',
      );
    }

    if (!user.active) {
      throw const BusinessRuleException(
        'Ce compte a été désactivé par la salle. Contactez l\'accueil.',
      );
    }

    return _startSession(user, cred);
  }

  /// Ouvre la session : jeton de session, horodatage de connexion et
  /// remise à zéro des tentatives. Commun à la connexion par mot de passe
  /// et à la connexion avec Google.
  Future<AppUser> _startSession(AppUser user, Credential cred) async {
    final token = newSessionToken();
    await _b.credentials.save(
      cred.copyWith(
        failedAttempts: 0,
        clearLock: true,
        sessionDigest: tokenDigest(token),
      ),
    );
    await _b.sessionStorage.write(_tokenKey, token);
    await _b.sessionStorage.write(_userKey, user.id);
    final updated = await _b.users.save(
      user.copyWith(lastLoginAt: _b.now()),
    );
    _current = updated;
    pendingMessage = null;
    notifyListeners();
    _b.bus.emit();
    return updated;
  }

  /// Connexion à partir d'une identité **déjà vérifiée par Google**.
  ///
  /// L'adresse fait foi : si un compte existe avec cette adresse, on s'y
  /// connecte (le compte reste le même, qu'on entre par mot de passe ou
  /// par Google) ; sinon un compte abonné est créé.
  ///
  /// Aucun mot de passe n'est choisi par la personne : le compte reçoit un
  /// mot de passe aléatoire que personne ne connaît, de sorte que la
  /// connexion par mot de passe reste impossible tant qu'elle n'en a pas
  /// défini un par « Mot de passe oublié ».
  Future<AppUser> signInWithGoogle({
    required String email,
    required String displayName,
  }) async {
    final clean = email.trim().toLowerCase();
    if (Validators.email(clean) != null) {
      throw const ValidationException(
        'Adresse e-mail invalide communiquée par Google.',
      );
    }
    final existing = _findByEmail(clean);
    if (existing != null) {
      if (!existing.active) {
        throw const BusinessRuleException(
          'Ce compte a été désactivé par la salle. Contactez l\'accueil.',
        );
      }
      var cred = _b.credentials.byId(existing.id);
      if (cred == null) {
        await setPassword(existing.id, _randomPassword());
        cred = _b.credentials.byId(existing.id)!;
      }
      // Un verrouillage pour essais ratés ne bloque pas Google : le mot de
      // passe n'est pas en jeu ici, c'est Google qui a authentifié.
      return _startSession(existing, cred);
    }

    final now = _b.now();
    final name = displayName.trim().isEmpty
        ? clean.split('@').first
        : displayName.trim();
    final user = AppUser(
      id: IdGen.next('u_'),
      email: clean,
      fullName: Validators.name(name) == null ? name : 'Membre GymFlow',
      role: UserRole.member,
      gender: Gender.female,
      goal: Goal.fitness,
      createdAt: now,
      subscription: Subscription(
        type: SubscriptionType.trial,
        start: now,
        end: now.add(const Duration(days: 7)),
      ),
    );
    await _b.users.save(user);
    await setPassword(user.id, _randomPassword());
    await _b.notifications.notify(
      user.id,
      NotificationType.system,
      'Bienvenue chez GymFlow !',
      'Votre essai gratuit de 7 jours commence aujourd\'hui. '
          'Complétez votre profil pour des conseils adaptés.',
    );
    return _startSession(user, _b.credentials.byId(user.id)!);
  }

  /// Mot de passe aléatoire, jamais communiqué : il n'existe que pour
  /// porter la session d'un compte créé par Google.
  String _randomPassword() {
    final r = Random.secure();
    return List.generate(
      40,
      (_) => _passwordAlphabet[r.nextInt(_passwordAlphabet.length)],
    ).join();
  }

  static const _passwordAlphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  Future<AppUser> register({
    required String fullName,
    required String email,
    required String password,
    required Gender gender,
    required Goal goal,
    required int age,
    required bool acceptTerms,
  }) async {
    if (!acceptTerms) {
      throw const ValidationException(
        'Acceptez les conditions d\'utilisation et la politique de confidentialité.',
      );
    }
    if (age < Legal.minimumAge || age > 100) {
      throw const ValidationException(
        'L\'inscription en ligne est réservée aux personnes majeures. '
        'Les mineurs s\'inscrivent à l\'accueil avec un représentant légal.',
      );
    }
    final errors = [
      Validators.name(fullName),
      Validators.email(email),
      Validators.password(password),
    ].whereType<String>();
    if (errors.isNotEmpty) throw ValidationException(errors.first);
    if (_findByEmail(email) != null) {
      throw const ValidationException('Un compte existe déjà avec cet e-mail.');
    }
    final now = _b.now();
    final user = AppUser(
      id: IdGen.next('u_'),
      email: email.trim().toLowerCase(),
      fullName: fullName.trim(),
      role: UserRole.member,
      gender: gender,
      goal: goal,
      age: age,
      createdAt: now,
      // Essai gratuit de 7 jours pour découvrir la salle.
      subscription: Subscription(
        type: SubscriptionType.trial,
        start: now,
        end: now.add(const Duration(days: 7)),
      ),
      // Preuve du consentement aux CGU et à la politique (version datée).
      consents: [
        ConsentRecord(
          type: ConsentType.terms,
          granted: true,
          at: now,
          version: Legal.version,
        ),
      ],
    );
    await _b.users.save(user);
    await setPassword(user.id, password);
    await _b.notifications.notify(
      user.id,
      NotificationType.system,
      'Bienvenue chez GymFlow !',
      'Votre essai gratuit de 7 jours commence aujourd\'hui. Réservez votre premier cours.',
    );
    return login(email, password);
  }

  Future<void> logout() async {
    final u = _current;
    if (u != null) {
      final cred = _b.credentials.byId(u.id);
      if (cred != null) {
        await _b.credentials.save(cred.copyWith(clearSession: true));
      }
    }
    await _clearStoredSession();
    _current = null;
    _b.cart.clear();
    notifyListeners();
  }

  Future<void> _clearStoredSession() async {
    await _b.sessionStorage.delete(_tokenKey);
    await _b.sessionStorage.delete(_userKey);
  }

  /// Recharge l'utilisateur courant après une modification de profil.
  void refreshCurrent() {
    final u = _current;
    if (u == null) return;
    _current = _b.users.byId(u.id);
    notifyListeners();
  }

  /// Mot de passe oublié : génère un code à 6 chiffres valable 15 min.
  /// L'envoi d'e-mail est simulé : le code est renvoyé pour être affiché
  /// dans une « boîte de réception » de démonstration.
  Future<String?> requestPasswordReset(String email) async {
    if (Validators.email(email) != null) {
      throw const ValidationException('Adresse e-mail invalide.');
    }
    final user = _findByEmail(email);
    if (user == null) return null;
    final cred = _b.credentials.byId(user.id);
    if (cred == null) return null;
    final code = (Random.secure().nextInt(900000) + 100000).toString();
    await _b.credentials.save(
      cred.copyWith(
        resetCodeHash: tokenDigest(code),
        resetCodeExpires: _b.now().add(AppConfig.resetCodeValidity),
      ),
    );
    return code;
  }

  Future<void> resetPassword(
    String email,
    String code,
    String newPassword,
  ) async {
    final pwdError = Validators.password(newPassword);
    if (pwdError != null) throw ValidationException(pwdError);
    final user = _findByEmail(email);
    final cred = user == null ? null : _b.credentials.byId(user.id);
    const invalid = 'Code invalide ou expiré.';
    if (cred == null ||
        cred.resetCodeHash == null ||
        cred.resetCodeExpires == null ||
        cred.resetCodeExpires!.isBefore(_b.now()) ||
        !PasswordHasher.constantTimeEquals(
          cred.resetCodeHash!,
          tokenDigest(code.trim()),
        )) {
      throw const ValidationException(invalid);
    }
    final salt = hasher.newSalt();
    await _b.credentials.save(
      cred.copyWith(
        hash: hasher.hash(newPassword, salt),
        salt: salt,
        iterations: hasher.iterations,
        failedAttempts: 0,
        clearLock: true,
        clearReset: true,
        clearSession: true,
      ),
    );
  }

  Future<void> changePassword(String oldPassword, String newPassword) async {
    final user = _b.requireUser();
    final cred = _b.credentials.byId(user.id)!;
    if (!hasher.verify(oldPassword, cred.salt, cred.hash, cred.iterations)) {
      throw const ValidationException('Mot de passe actuel incorrect.');
    }
    final pwdError = Validators.password(newPassword);
    if (pwdError != null) throw ValidationException(pwdError);
    final salt = hasher.newSalt();
    await _b.credentials.save(
      cred.copyWith(
        hash: hasher.hash(newPassword, salt),
        salt: salt,
        iterations: hasher.iterations,
      ),
    );
  }
}
