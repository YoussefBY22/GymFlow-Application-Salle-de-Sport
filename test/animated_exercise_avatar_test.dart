import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/widgets/animated_exercise_avatar.dart';

void main() {
  testWidgets('affiche un avatar animé adapté à un exercice de jambes', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AnimatedExerciseAvatar(name: 'Squat', muscle: Muscle.quads),
        ),
      ),
    );

    expect(find.text('Flexion des jambes'), findsOneWidget);
    expect(find.text('Animation illustrative'), findsOneWidget);
    expect(
      find.byKey(const Key('animated_exercise_avatar_painter')),
      findsOneWidget,
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const Key('animated_exercise_avatar_semantics')),
          )
          .getSemanticsData()
          .label,
      startsWith('Démonstration animée : Flexion des jambes'),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'utilise une animation de gainage pour les exercices abdominaux',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnimatedExerciseAvatar(
              name: 'Gainage frontal',
              muscle: Muscle.abs,
            ),
          ),
        ),
      );

      expect(find.text('Gainage'), findsOneWidget);
      expect(
        tester
            .getSemantics(
              find.byKey(const Key('animated_exercise_avatar_semantics')),
            )
            .getSemanticsData()
            .label,
        startsWith('Démonstration animée : Gainage'),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}
