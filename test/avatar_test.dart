// Niveau : unitaire et intégration (sans réseau). Avatars : initiales du
// nom par défaut, galerie de choix, migration des anciens avatars, et
// absence d'appel réseau au moment de l'inscription.
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/services/avatar_service.dart';
import 'package:gymflow/services/seed/seed_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';

void main() {
  group('AvatarService : initiales du nom', () {
    test('l\'avatar par défaut est construit à partir du NOM', () {
      final url = AvatarService.forNewAccount('Ahmed Gharbi');
      expect(url, contains('/initials/'));
      expect(url, contains('seed=Ahmed+Gharbi'));
    });

    test('deux personnes différentes ont des avatars différents', () {
      expect(
        AvatarService.forNewAccount('Ahmed Gharbi'),
        isNot(AvatarService.forNewAccount('Leila Mansour')),
      );
    });

    test('la même personne a toujours le même avatar', () {
      expect(
        AvatarService.forNewAccount('Ahmed Gharbi'),
        AvatarService.forNewAccount('Ahmed Gharbi'),
      );
    });

    test('espaces superflus et majuscules ne changent pas la couleur', () {
      expect(
        AvatarService.colorFor('  Ahmed   Gharbi '),
        AvatarService.colorFor('ahmed gharbi'),
      );
    });

    test('la couleur vient toujours de la palette', () {
      for (final nom in ['Ahmed', 'Leila Mansour', 'Youssef Ben Youssef', 'é']) {
        expect(AvatarService.palette, contains(AvatarService.colorFor(nom)));
      }
    });

    test('un nom vide ne produit pas une URL cassée', () {
      expect(AvatarService.forNewAccount('   '), contains('seed=gymflow'));
    });

    test('les caractères spéciaux d\'un nom sont encodés', () {
      final url = AvatarService.forNewAccount('Aïcha B+C');
      expect(url, isNot(contains(' ')));
      expect(url, contains('seed='));
    });

    test('le texte des initiales est blanc : la palette reste lisible', () {
      expect(AvatarService.forNewAccount('Ahmed'), contains('textColor=ffffff'));
    });
  });

  group('AvatarService : galerie', () {
    test('la galerie propose une centaine de choix', () {
      final total = AvatarService.sections('Ahmed Gharbi')
          .fold<int>(0, (n, s) => n + s.urls.length);
      expect(total, AvatarService.galleryCount);
      expect(total, greaterThanOrEqualTo(100));
    });

    test('la première section ce sont les initiales, une par couleur', () {
      final s = AvatarService.sections('Ahmed Gharbi').first;
      expect(s.title, 'Mes initiales');
      expect(s.urls.length, AvatarService.palette.length);
      for (final c in AvatarService.palette) {
        expect(s.urls.any((u) => u.contains('backgroundColor=$c')), isTrue);
      }
    });

    test('chaque style illustré a ses variantes, sans doublon', () {
      final sections = AvatarService.sections('Ahmed Gharbi').skip(1);
      expect(sections.length, AvatarService.styles.length);
      for (final s in sections) {
        expect(s.urls.length, AvatarService.variantsPerStyle);
        expect(s.urls.toSet().length, s.urls.length,
            reason: '${s.title} : aucune proposition en double');
      }
    });

    test('toute la galerie dépend du nom de la personne', () {
      final a = AvatarService.sections('Ahmed Gharbi');
      final b = AvatarService.sections('Leila Mansour');
      // Les initiales dépendent du nom ; les dessins aussi (graine).
      for (var i = 0; i < a.length; i++) {
        expect(a[i].urls.first, isNot(b[i].urls.first));
      }
    });

    test('toutes les propositions sont des avatars générés', () {
      for (final s in AvatarService.sections('Ahmed')) {
        for (final u in s.urls) {
          expect(AvatarService.isGenerated(u), isTrue);
        }
      }
      expect(AvatarService.isGenerated('/data/photos/moi.jpg'), isFalse);
      expect(AvatarService.isGenerated(null), isFalse);
    });
  });

  group('Avatar attribué à la création du compte', () {
    test('une inscription reçoit ses initiales, sans appel réseau', () async {
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
      expect(u.avatarPath, AvatarService.forNewAccount('Nouvelle Membre'));
      expect(u.avatarPath, contains('/initials/'));
      expect(
        appels,
        0,
        reason: 'l\'URL est calculée, l\'image n\'est chargée qu\'à l\'affichage',
      );
    });

    test('l\'avatar ne dépend plus de l\'adresse e-mail', () async {
      final b = await makeBackend();
      final u = await b.auth.register(
        fullName: 'Sana Trabelsi',
        email: 'adresse.secrete@gymflow.tn',
        password: 'Membre2026!',
        gender: Gender.female,
        goal: Goal.fitness,
        age: 30,
        acceptTerms: true,
      );
      expect(u.avatarPath, isNot(contains('secrete')));
      expect(u.avatarPath, isNot(contains('gymflow.tn')));
    });

    test('une première connexion Google reçoit les initiales de son nom',
        () async {
      final b = await makeBackend();
      final u = await b.auth.signInWithGoogle(
        email: 'nouveau.google@gmail.com',
        displayName: 'Nouveau Google',
      );
      expect(u.avatarPath, AvatarService.forNewAccount('Nouveau Google'));
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

  group('Migration des anciens avatars', () {
    test("l'ancien avatar « pouces » devient les initiales du nom", () async {
      final b = await makeBackend();
      final ahmed = b.users.all.firstWhere((u) => u.email == 'ahmed@gymflow.tn');
      await b.users.save(
        ahmed.copyWith(
          avatarPath:
              'https://api.dicebear.com/9.x/thumbs/png?seed=ahmed%40gymflow.tn&size=256',
        ),
      );
      await b.store.setMeta('avatar_initials', '0'); // migration à rejouer
      await SeedService(b).upgrade();
      final apres = b.users.byId(ahmed.id)!;
      expect(apres.avatarPath, AvatarService.forNewAccount(ahmed.fullName));
    });

    test("une photo envoyée par la personne n'est jamais touchée", () async {
      final b = await makeBackend();
      final ahmed = b.users.all.firstWhere((u) => u.email == 'ahmed@gymflow.tn');
      await b.users.save(ahmed.copyWith(avatarPath: '/data/photos/moi.jpg'));
      await b.store.setMeta('avatar_initials', '0');
      await SeedService(b).upgrade();
      expect(b.users.byId(ahmed.id)!.avatarPath, '/data/photos/moi.jpg');
    });

    test("un avatar d'un autre style n'est pas touché", () async {
      final b = await makeBackend();
      final ahmed = b.users.all.firstWhere((u) => u.email == 'ahmed@gymflow.tn');
      final choisi = AvatarService.illustrated(
        ahmed.fullName,
        style: 'lorelei',
        variant: 3,
      );
      await b.users.save(ahmed.copyWith(avatarPath: choisi));
      await b.store.setMeta('avatar_initials', '0');
      await SeedService(b).upgrade();
      expect(b.users.byId(ahmed.id)!.avatarPath, choisi);
    });

    test("elle ne s'exécute qu'une fois", () async {
      final b = await makeBackend();
      await SeedService(b).upgrade();
      final ahmed = b.users.all.firstWhere((u) => u.email == 'ahmed@gymflow.tn');
      // Après la première exécution, un choix « Pouces » n'est plus remplacé.
      final choisi = AvatarService.illustrated(ahmed.fullName, style: 'thumbs');
      await b.users.save(ahmed.copyWith(avatarPath: choisi));
      await SeedService(b).upgrade();
      expect(b.users.byId(ahmed.id)!.avatarPath, choisi);
    });
  });
}
