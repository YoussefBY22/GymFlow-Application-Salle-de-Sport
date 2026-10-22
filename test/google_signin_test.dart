// Niveau : intégration (sans réseau ni fenêtre Google). On ne teste pas
// Google lui-même, mais ce que l'application fait d'une identité qu'il a
// vérifiée : quel compte est ouvert, lequel est créé, et ce qui reste
// interdit.
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/models/enums.dart';

import 'helpers.dart';

void main() {
  group('Connexion Google : compte existant', () {
    test('la même adresse ouvre le compte existant, sans doublon', () async {
      final b = await makeBackend();
      final avant = b.users.count;
      final u = await b.auth.signInWithGoogle(
        email: 'ahmed@gymflow.tn',
        displayName: 'Ahmed Gharbi',
      );
      expect(u.email, 'ahmed@gymflow.tn');
      expect(b.users.count, avant, reason: 'aucun compte en double');
      expect(b.auth.currentUser?.id, u.id, reason: 'la session est ouverte');
    });

    test('l\'adresse est comparée sans tenir compte de la casse', () async {
      final b = await makeBackend();
      final avant = b.users.count;
      final u = await b.auth.signInWithGoogle(
        email: '  AHMED@GymFlow.TN ',
        displayName: 'Ahmed',
      );
      expect(u.email, 'ahmed@gymflow.tn');
      expect(b.users.count, avant);
    });

    test('un compte désactivé reste refusé', () async {
      final b = await makeBackend();
      await expectLater(
        b.auth.signInWithGoogle(
          email: 'walid@gymflow.tn',
          displayName: 'Walid',
        ),
        throwsA(isA<BusinessRuleException>()),
      );
      expect(b.auth.currentUser, isNull);
    });

    test('le rôle existant est conservé, Google ne rétrograde personne',
        () async {
      final b = await makeBackend();
      final u = await b.auth.signInWithGoogle(
        email: 'admin@gymflow.tn',
        displayName: 'Admin',
      );
      expect(u.role, UserRole.superAdmin);
    });
  });

  group('Connexion Google : premier passage', () {
    test('un compte abonné est créé avec un essai de 7 jours', () async {
      final b = await makeBackend();
      final avant = b.users.count;
      final u = await b.auth.signInWithGoogle(
        email: 'nouveau.membre@gmail.com',
        displayName: 'Nouveau Membre',
      );
      expect(b.users.count, avant + 1);
      expect(u.role, UserRole.member);
      expect(u.fullName, 'Nouveau Membre');
      expect(u.subscription.type, SubscriptionType.trial);
      expect(u.subscription.isActiveAt(b.now()), isTrue);
      expect(b.auth.currentUser?.id, u.id);
    });

    test('sans nom fourni, la partie avant @ sert de nom', () async {
      final b = await makeBackend();
      final u = await b.auth.signInWithGoogle(
        email: 'sanspseudo@gmail.com',
        displayName: '   ',
      );
      expect(u.fullName, 'sanspseudo');
    });

    test('une adresse invalide est refusée', () async {
      final b = await makeBackend();
      await expectLater(
        b.auth.signInWithGoogle(email: 'pas-une-adresse', displayName: 'X'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('le nouveau compte reçoit le message de bienvenue', () async {
      final b = await makeBackend();
      final u = await b.auth.signInWithGoogle(
        email: 'bienvenue@gmail.com',
        displayName: 'Test',
      );
      // La session du nouveau compte est ouverte : `mine()` renvoie ses
      // notifications.
      final notifs = b.notifications.mine();
      expect(notifs, isNotEmpty);
      expect(notifs.first.title, contains('Bienvenue'));
      expect(u.id, isNotEmpty);
    });
  });

  group('Connexion Google : sécurité', () {
    test('le compte créé n\'a pas de mot de passe devinable', () async {
      final b = await makeBackend();
      await b.auth.signInWithGoogle(
        email: 'sanspass@gmail.com',
        displayName: 'Sans Pass',
      );
      await b.auth.logout();
      // Aucun mot de passe courant ne doit ouvrir ce compte.
      for (final essai in [
        '',
        'password',
        'Membre2026!',
        'sanspass@gmail.com',
        'Sans Pass',
      ]) {
        await expectLater(
          b.auth.login('sanspass@gmail.com', essai),
          throwsA(isA<AppException>()),
          reason: 'le mot de passe « $essai » ne doit pas fonctionner',
        );
      }
    });

    test('deux comptes Google ont des empreintes différentes', () async {
      final b = await makeBackend();
      final a = await b.auth.signInWithGoogle(
        email: 'a@gmail.com',
        displayName: 'A',
      );
      await b.auth.logout();
      final c = await b.auth.signInWithGoogle(
        email: 'c@gmail.com',
        displayName: 'C',
      );
      final credA = b.credentials.byId(a.id)!;
      final credC = b.credentials.byId(c.id)!;
      expect(credA.hash, isNot(credC.hash));
      expect(credA.salt, isNot(credC.salt));
    });

    test('la connexion par mot de passe du compte existant marche encore',
        () async {
      final b = await makeBackend();
      // Entrer par Google ne doit pas casser l'entrée par mot de passe.
      await b.auth.signInWithGoogle(
        email: 'ahmed@gymflow.tn',
        displayName: 'Ahmed',
      );
      await b.auth.logout();
      final u = await b.auth.login('ahmed@gymflow.tn', 'Membre2026!');
      expect(u.email, 'ahmed@gymflow.tn');
    });
  });
}
