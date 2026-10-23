// Niveau : unitaire et intégration (sans réseau). Avatars illustrés :
// attribution automatique à la création d'un compte, galerie de choix, et
// absence d'appel réseau au moment de l'inscription.
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/services/avatar_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';

void main() {
  group('AvatarService : construction des URL', () {
    test('la même graine donne toujours le même dessin', () {
      expect(
        AvatarService.url(seed: 'ahmed@gymflow.tn'),
        AvatarService.url(seed: 'ahmed@gymflow.tn'),
      );
    });

    test('deux personnes différentes ont des avatars différents', () {
      expect(
        AvatarService.url(seed: 'ahmed@gymflow.tn'),
        isNot(AvatarService.url(seed: 'leila@gymflow.tn')),
      );
    });

    test('les caractères spéciaux d\'une adresse sont encodés', () {
      final url = AvatarService.url(seed: 'a b+c@gymflow.tn');
      expect(url, isNot(contains(' ')));
      expect(url, contains('seed='));
    });

    test('une graine vide ne produit pas une URL cassée', () {
      expect(AvatarService.url(seed: '   '), contains('seed=gymflow'));
    });

    test('la galerie propose chaque style, sans doublon', () {
      final g = AvatarService.gallery('ahmed@gymflow.tn');
      expect(g.length, AvatarService.styles.length * 2);
      expect(g.toSet().length, g.length, reason: 'aucune proposition en double');
      for (final style in AvatarService.styles) {
        expect(g.any((u) => u.contains('/${style.id}/')), isTrue);
      }
    });

    test('un avatar généré se distingue d\'une photo envoyée', () {
      expect(AvatarService.isGenerated(AvatarService.url(seed: 'x')), isTrue);
      expect(AvatarService.isGenerated('/data/photos/moi.jpg'), isFalse);
      expect(AvatarService.isGenerated(null), isFalse);
    });
  });

  group('Avatar attribué à la création du compte', () {
    test('une inscription reçoit un avatar, sans appel réseau', () async {
      var appels = 0;
      final b = await makeBackend(
        httpClient: MockClient((_) async {
          appels++;
          return http.Response('{}', 200);
        }),
      );
      final u = await b.auth.register(
        fullName: 'Nouvelle Membre',
        email: 'nouvelle@gymflow.tn',
        password: 'Membre2026!',
        gender: Gender.female,
        goal: Goal.fitness,
        age: 27,
        acceptTerms: true,
      );
      expect(u.avatarPath, isNotNull);
      expect(AvatarService.isGenerated(u.avatarPath), isTrue);
      expect(
        appels,
        0,
        reason: 'l\'URL est calculée, l\'image n\'est chargée qu\'à l\'affichage',
      );
    });

    test('une première connexion Google reçoit aussi un avatar', () async {
      final b = await makeBackend();
      final u = await b.auth.signInWithGoogle(
        email: 'nouveau.google@gmail.com',
        displayName: 'Nouveau Google',
      );
      expect(AvatarService.isGenerated(u.avatarPath), isTrue);
    });

    test('un compte existant garde sa photo quand il entre par Google',
        () async {
      final b = await makeBackend();
      final avant = b.users.all.firstWhere((u) => u.email == 'ahmed@gymflow.tn');
      final apres = await b.auth.signInWithGoogle(
        email: 'ahmed@gymflow.tn',
        displayName: 'Ahmed',
      );
      expect(apres.avatarPath, avant.avatarPath);
    });
  });
}
