// Niveau : intégration (sans réseau). Photo de profil Gravatar : on
// vérifie l'adresse appelée, la confidentialité de l'e-mail, et le
// comportement quand la personne n'a pas de photo.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/services/gravatar_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';

/// Réponse d'image minimale (un PNG d'un pixel suffit au contrôle).
http.Response _image() => http.Response.bytes(
  Uint8List.fromList(const [137, 80, 78, 71, 13, 10, 26, 10]),
  200,
  headers: {'content-type': 'image/png'},
);

void main() {
  group('Gravatar : adresse demandée', () {
    test('l\'e-mail n\'est jamais envoyé en clair', () {
      const email = 'ahmed@gymflow.tn';
      final url = GravatarService.urlFor(email);
      expect(url, startsWith(GravatarService.host));
      expect(url, isNot(contains('ahmed')));
      expect(url, isNot(contains('@')));
      expect(url, isNot(contains('gymflow.tn')));
    });

    test('l\'empreinte est celle attendue par Gravatar (MD5 normalisé)', () {
      // Même empreinte quelles que soient la casse et les espaces.
      final a = GravatarService.hashOf('Ahmed@GymFlow.TN');
      final b = GravatarService.hashOf('  ahmed@gymflow.tn  ');
      expect(a, b);
      expect(a, hasLength(32));
      expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('le paramètre d=404 est présent : sans lui on ne saurait pas '
        'distinguer une vraie photo d\'une image générique', () {
      expect(GravatarService.urlFor('x@y.tn'), contains('d=404'));
    });
  });

  group('Gravatar : récupération', () {
    test('une photo existante renvoie son adresse', () async {
      late Uri demandee;
      final b = await makeBackend(
        httpClient: MockClient((r) async {
          demandee = r.url;
          return _image();
        }),
      );
      final url = await b.gravatar.photoFor('ahmed@gymflow.tn');
      expect(url, isNotNull);
      expect(url, contains(GravatarService.hashOf('ahmed@gymflow.tn')));
      expect(demandee.host, 'www.gravatar.com');
    });

    test('sans photo (404), on garde les initiales', () async {
      final b = await makeBackend(
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      expect(await b.gravatar.photoFor('inconnu@gymflow.tn'), isNull);
    });

    test('une réponse qui n\'est pas une image est refusée', () async {
      final b = await makeBackend(
        httpClient: MockClient(
          (_) async => http.Response(
            '<html>erreur</html>',
            200,
            headers: {'content-type': 'text/html'},
          ),
        ),
      );
      expect(await b.gravatar.photoFor('ahmed@gymflow.tn'), isNull);
    });

    test('service injoignable : aucune erreur remontée', () async {
      final b = await makeBackend(
        httpClient: MockClient((_) async => throw Exception('pas de réseau')),
      );
      expect(await b.gravatar.photoFor('ahmed@gymflow.tn'), isNull);
    });

    test('adresse vide : aucun appel réseau', () async {
      var appels = 0;
      final b = await makeBackend(
        httpClient: MockClient((_) async {
          appels++;
          return _image();
        }),
      );
      expect(await b.gravatar.photoFor('   '), isNull);
      expect(appels, 0);
    });
  });
}
