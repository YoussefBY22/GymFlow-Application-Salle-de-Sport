import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/services/nutrition_recovery_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('NutritionRecoveryService', () {
    test(
      'utilise la recherche Open Food Facts v2 et lit les nutriments',
      () async {
        http.Request? request;
        final service = NutritionRecoveryService(
          client: MockClient((r) async {
            request = r;
            return http.Response(
              jsonEncode({
                'products': [
                  {
                    'product_name': 'Protein powder',
                    'product_name_fr': 'Poudre protéinée',
                    'image_front_url': 'https://example.test/product.jpg',
                    'nutriscore_grade': 'b',
                    'nutriments': {
                      'energy-kcal_100g': 400,
                      'proteins_100g': 80,
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );

        final products = await service.searchRecoveryFoods(Muscle.chest);

        expect(request!.url.path, '/api/v2/search');
        expect(request!.url.queryParameters['categories_tags_en'], 'proteins');
        expect(request!.url.queryParameters['page_size'], '5');
        expect(products.single.name, 'Poudre protéinée');
        expect(products.single.proteins, 80);
        expect(products.single.kcal, 400);
        expect(products.single.nutriscore, 'b');
        service.dispose();
      },
    );

    test('essaie la catégorie sport si la catégorie ciblée est vide', () async {
      final categories = <String>[];
      final service = NutritionRecoveryService(
        client: MockClient((request) async {
          final category = request.url.queryParameters['categories_tags_en']!;
          categories.add(category);
          return http.Response(
            jsonEncode({
              'products': category == 'proteins'
                  ? []
                  : [
                      {
                        'product_name': 'Recovery drink',
                        'nutriments': {'proteins_100g': 10},
                      },
                    ],
            }),
            200,
          );
        }),
      );

      final products = await service.searchRecoveryFoods(Muscle.chest);

      expect(categories, ['proteins', 'sports-nutrition']);
      expect(products.single.name, 'Recovery drink');
      service.dispose();
    });

    test('signale le statut HTTP d’Open Food Facts', () async {
      final service = NutritionRecoveryService(
        client: MockClient((_) async => http.Response('', 503)),
      );

      await expectLater(
        service.searchRecoveryFoods(Muscle.chest),
        throwsA(
          isA<NutritionRecoveryException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having(
                (error) => error.message,
                'message',
                contains('indisponibles'),
              ),
        ),
      );
      service.dispose();
    });
  });
}
