import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/services/ai/cloud_ai_service.dart';
import 'package:gymflow/services/exercise_db_service.dart';

void main() {
  group('ExerciseDB', () {
    test('recherche un GIF par nom avec les en-têtes RapidAPI', () async {
      http.Request? request;
      final service = ExerciseDbService(
        apiKey: 'rapidapi-test-key',
        client: MockClient((r) async {
          request = r;
          return http.Response(
            jsonEncode([
              {
                'id': 'ex-1',
                'name': 'crunch',
                'gifUrl': 'https://example.test/crunch.gif',
                'bodyPart': 'waist',
                'target': 'abs',
                'equipment': 'body weight',
              },
            ]),
            200,
          );
        }),
      );

      final gifs = await service.searchByName('Crunch');

      expect(request!.url.path, '/exercises/name/crunch');
      expect(request!.headers['X-RapidAPI-Key'], 'rapidapi-test-key');
      expect(gifs.single.gifUrl, 'https://example.test/crunch.gif');
      service.dispose();
    });

    test('une correspondance absente permet le repli vers le muscle', () async {
      var requests = 0;
      final service = ExerciseDbService(
        apiKey: 'rapidapi-test-key',
        client: MockClient((request) async {
          requests++;
          if (request.url.path.contains('/name/')) {
            return http.Response('', 404);
          }
          return http.Response(
            jsonEncode([
              {
                'id': 'ex-abs',
                'name': 'crunch',
                'gifUrl': 'https://example.test/abs.gif',
              },
            ]),
            200,
          );
        }),
      );

      expect(await service.searchByName('crunch'), isEmpty);
      final gifs = await service.searchByTarget(Muscle.abs);

      expect(requests, 2);
      expect(gifs.single.gifUrl, 'https://example.test/abs.gif');
      service.dispose();
    });

    test('signale clairement une clé refusée par RapidAPI', () async {
      final service = ExerciseDbService(
        apiKey: 'rapidapi-test-key',
        client: MockClient((_) async => http.Response('', 403)),
      );

      await expectLater(
        service.searchByTarget(Muscle.abs),
        throwsA(
          isA<ExerciseDbException>()
              .having((error) => error.statusCode, 'statusCode', 403)
              .having((error) => error.message, 'message', isNotEmpty),
        ),
      );
      service.dispose();
    });
  });

  group('Gemini pour les refus de propositions', () {
    test('envoie la clé dans les en-têtes et extrait le brouillon', () async {
      http.Request? request;
      final service = CloudAIService(
        apiKey: 'gemini-test-key',
        client: MockClient((r) async {
          request = r;
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Merci de préciser les étapes.'},
                    ],
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final text = await service.generateText(
        system: 'Rédige un motif poli.',
        prompt: 'Exercice Crunch',
      );
      final body = jsonDecode(request!.body) as Map<String, dynamic>;

      expect(
        request!.url.path,
        contains('/models/gemini-3.8-flash:generateContent'),
      );
      expect(request!.headers['x-goog-api-key'], 'gemini-test-key');
      expect(body['contents'], isNotEmpty);
      expect(text, 'Merci de préciser les étapes.');
    });

    test('essaie un autre modèle si le premier est indisponible', () async {
      final requestedModels = <String>[];
      final service = CloudAIService(
        apiKey: 'gemini-test-key',
        client: MockClient((request) async {
          requestedModels.add(request.url.path);
          if (requestedModels.length == 1) {
            return http.Response(
              jsonEncode({
                'error': {'message': 'Model not found'},
              }),
              404,
            );
          }
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Merci de compléter votre exercice.'},
                    ],
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final result = await service.generateText(
        system: 'Rédige un motif.',
        prompt: 'Exercice',
      );

      expect(requestedModels, hasLength(2));
      expect(result, 'Merci de compléter votre exercice.');
    });

    test('expose le message retourné par Gemini en cas de refus', () async {
      final service = CloudAIService(
        apiKey: 'gemini-test-key',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'message': 'API key not valid'},
            }),
            403,
          ),
        ),
      );

      await expectLater(
        service.generateText(system: 'Consigne', prompt: 'Proposition'),
        throwsA(
          isA<CloudAIException>()
              .having((error) => error.statusCode, 'statusCode', 403)
              .having(
                (error) => error.message,
                'message',
                contains('API key not valid'),
              ),
        ),
      );
    });
  });
}
