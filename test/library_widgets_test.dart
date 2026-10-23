import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/app.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/content.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/models/prefs.dart';
import 'package:gymflow/screens/shell/main_shell.dart';
import 'package:gymflow/services/library_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

/// Interface de la bibliothèque : filtres en feuille, mémorisés, favoris
/// animés, file de validation, filtres des cours.
void main() {
  Future<void> openWorkouts(WidgetTester tester) async {
    MainShell.tab.value = 1;
    await settle(tester);
    await tester.tap(find.text('Workouts'));
    await settle(tester);
  }

  testWidgets(
    'filtre « Débutant » via la feuille, retrouvé après reconnexion',
    (tester) async {
      final b = await pumpApp(
        tester,
        route: Routes.home,
        loginEmail: 'nour@gymflow.tn',
      );
      await b.privacy.completeIntro();
      await openWorkouts(tester);
      final workoutsTab = find.byKey(const ValueKey('filters_workout'));
      await tester.tap(
        find.descendant(
          of: workoutsTab,
          matching: find.byKey(const Key('filters_button')),
        ),
      );
      await settle(tester);
      expect(find.text('Durée'), findsOneWidget);
      final all = b.library.workouts().length;
      expect(find.text('Voir $all résultats'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('opt_level_beginner')));
      await settle(tester, 400);
      // Aperçu en direct du nombre de résultats.
      final beginners = b.library
          .workouts(
            filters: {
              LibraryFilters.level: {Level.beginner.name},
            },
          )
          .length;
      expect(beginners, lessThan(all));
      expect(find.text('Voir $beginners résultats'), findsOneWidget);
      await tester.tap(find.byKey(const Key('filters_apply')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('active_level_beginner')),
        findsOneWidget,
      );
      expect(find.text('Push Day'), findsNothing);
      expect(
        b.library
            .savedFilters(LibraryFilters.workoutsList)
            .of(LibraryFilters.level),
        {Level.beginner.name},
      );

      // Déconnexion puis reconnexion : le filtre est toujours là.
      await b.auth.logout();
      await loginAs(b, 'nour@gymflow.tn');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const GymFlowApp(initialRoute: Routes.home));
      await settle(tester);
      await openWorkouts(tester);
      expect(
        find.byKey(const ValueKey('active_level_beginner')),
        findsOneWidget,
      );

      // « Tout effacer » retire le filtre.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('filters_workout')),
          matching: find.byKey(const Key('filters_clear')),
        ),
      );
      await settle(tester);
      expect(b.library.savedFilters(LibraryFilters.workoutsList), isEmpty);
    },
  );

  testWidgets('mettre en favori le 3e workout le fait remonter en tête', (
    tester,
  ) async {
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'nour@gymflow.tn',
    );
    await b.privacy.completeIntro();
    await openWorkouts(tester);
    final third = b.library.workouts()[2];
    final card = find.ancestor(
      of: find.text(third.name),
      matching: find.byType(GestureDetector),
    );
    expect(card, findsWidgets);
    final fav = find.descendant(
      of: find.ancestor(
        of: find.text(third.name),
        matching: find.byKey(ValueKey(third.id)),
      ),
      matching: find.byTooltip('Ajouter aux favoris'),
    );
    await tester.tap(fav.first);
    // Animation en cours : pas d'erreur, puis la carte est en tête.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await settle(tester, 1500);
    expect(b.library.workouts().first.id, third.id);
    final firstCardTop = tester.getTopLeft(find.byKey(ValueKey(third.id)));
    final otherTop = tester.getTopLeft(
      find.byKey(ValueKey(b.library.workouts()[1].id)),
    );
    expect(firstCardTop.dy, lessThan(otherTop.dy));
  });

  testWidgets('un coach publie une proposition depuis la file', (tester) async {
    final b = await pumpApp(
      tester,
      route: Routes.review,
      loginEmail: 'sarra@gymflow.tn',
    );
    expect(find.text('Bras d\'acier'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('approve_w_rami_arms')));
    await settle(tester);
    expect(b.workouts.byId('w_rami_arms')!.publication.isPublished, isTrue);
    expect(find.text('Rien à valider'), findsOneWidget);
  });

  testWidgets(
    'analyse locale remplit un motif et refuse une proposition sur mobile',
    (tester) async {
      final b = await pumpApp(
        tester,
        route: Routes.review,
        loginEmail: 'sarra@gymflow.tn',
      );
      final source = b.exercises.byId('ex_goblet')!;
      final proposal = source.copyWith(
        id: 'ex_review_missing_steps',
        name: 'Exercice incomplet',
        steps: const [],
        breathing: '',
        media: const [],
        authorId: 'u_nour',
        publication: Publication(
          status: ContentStatus.pending,
          submittedAt: testNow,
        ),
      );
      await b.exercises.save(proposal);
      b.bus.emit();
      await settle(tester);

      final card = find.byKey(const ValueKey('review_ex_review_missing_steps'));
      await tapVisible(
        tester,
        find.descendant(of: card, matching: find.text('Refuser')),
      );
      await settle(tester);
      await tester.tap(find.text('Analyser'));
      await settle(tester);

      expect(find.textContaining('étapes d’exécution'), findsOneWidget);
      expect(find.textContaining('respiration'), findsOneWidget);
      await tester.tap(find.byKey(const Key('use_local_review_reason')));
      await settle(tester);
      final reasonField = tester.widget<TextFormField>(
        find.byKey(const ValueKey('review_reason_ex_review_missing_steps')),
      );
      expect(
        reasonField.controller!.text,
        contains('Merci pour votre proposition'),
      );
      await tester.tap(find.text('Envoyer le refus'));
      await settle(tester);

      expect(
        b.exercises.byId(proposal.id)!.publication.status,
        ContentStatus.rejected,
      );
      expect(
        b.exercises.byId(proposal.id)!.publication.note,
        contains('étapes d’exécution'),
      );
    },
  );

  testWidgets('Gemini génère un motif à partir du contenu proposé', (
    tester,
  ) async {
    http.Request? geminiRequest;
    final client = MockClient((request) async {
      geminiRequest = request;
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Merci de préciser les temps de repos.'},
                ],
              },
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await pumpApp(
      tester,
      route: Routes.review,
      loginEmail: 'sarra@gymflow.tn',
      httpClient: client,
      geminiApiKey: 'test-gemini-key',
    );

    final card = find.byKey(const ValueKey('review_w_rami_arms'));
    await tapVisible(
      tester,
      find.descendant(of: card, matching: find.text('Refuser')),
    );
    await settle(tester);
    await tester.tap(find.text('Générer'));
    await settle(tester);

    expect(geminiRequest!.headers['x-goog-api-key'], 'test-gemini-key');
    final payload = jsonDecode(geminiRequest!.body) as Map<String, dynamic>;
    expect(jsonEncode(payload['contents']), contains("Bras d'acier"));
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('review_reason_w_rami_arms')),
          )
          .controller!
          .text,
      'Merci de préciser les temps de repos.',
    );
  });

  testWidgets('cours : filtre par jour via des tuiles datées', (tester) async {
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'nour@gymflow.tn',
    );
    await b.privacy.completeIntro();
    MainShell.tab.value = 2;
    await settle(tester);
    await tester.tap(find.byKey(const Key('filters_button')).first);
    await settle(tester);
    expect(find.text('Jour de la semaine'), findsOneWidget);
    expect(find.text('Quand ?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('opt_weekday_4')));
    await settle(tester, 300);
    await tester.tap(find.byKey(const Key('filters_apply')));
    await settle(tester);
    expect(find.byKey(const ValueKey('active_weekday_4')), findsOneWidget);
    final shown = b.courseService.search(
      filters: {
        'weekday': {'4'},
      },
    );
    expect(shown.every((c) => c.startAt!.weekday == 4), isTrue);
    expect(b.library.savedFilters('courses').of('weekday'), {'4'});
  });
}
