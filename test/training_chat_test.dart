import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/screens/shell/main_shell.dart';
import 'package:gymflow/services/gemini_client.dart';
import 'package:gymflow/services/training_chat_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

http.Response _answer(String text) => http.Response(
  jsonEncode({
    'candidates': [
      {
        'content': {
          'parts': [
            {'text': text},
          ],
        },
      },
    ],
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('Chat sport dédié', () {
    test('répond avec une consigne prudente distincte', () async {
      final backend = await makeBackend();
      late Map<String, dynamic> request;
      backend.gemini = GeminiClient(
        MockClient((r) async {
          request = jsonDecode(r.body) as Map<String, dynamic>;
          return _answer('Commencez progressivement et hydratez-vous.');
        }),
        apiKey: 'training-chat-test',
      );
      final chat = TrainingChatService(backend);

      final answer = await chat.ask('Comment récupérer après le sport ?', [
        const TrainingChatMessage(true, 'Je débute'),
        const TrainingChatMessage(false, 'Bienvenue.'),
      ]);

      final system = jsonEncode(request['systemInstruction']);
      expect(answer, contains('hydratez-vous'));
      expect(system, contains('Tu es le coach virtuel de sport'));
      expect(system, contains('ne prétends pas'));
      expect(system, contains('professionnel de santé'));
      expect(jsonEncode(request['contents']), contains('Je débute'));
      expect(backend.assistant.enabled, isTrue);
    });

    testWidgets('affiche l’accès aux abonnés et aux coachs uniquement', (
      tester,
    ) async {
      await pumpApp(tester, route: Routes.home, loginEmail: 'ahmed@gymflow.tn');
      MainShell.tab.value = 1;
      await settle(tester);

      expect(find.byKey(const Key('training_coach_chat')), findsOneWidget);
      await tester.tap(find.byKey(const Key('training_coach_chat')));
      await settle(tester);
      expect(find.text('Coach sport et bien-être'), findsWidgets);
      expect(
        find.byKey(const Key('training_chat_unavailable')),
        findsOneWidget,
      );
    });

    testWidgets('un coach a accès au chat depuis Entraînement', (tester) async {
      await pumpApp(tester, route: Routes.home, loginEmail: 'amira@gymflow.tn');
      MainShell.tab.value = 1;
      await settle(tester);

      expect(find.byKey(const Key('training_coach_chat')), findsOneWidget);
    });

    testWidgets('un administrateur ne voit pas le chat réservé', (
      tester,
    ) async {
      await pumpApp(tester, route: Routes.home, loginEmail: 'admin@gymflow.tn');
      MainShell.tab.value = 1;
      await settle(tester);

      expect(find.byKey(const Key('training_coach_chat')), findsNothing);
    });
  });
}
