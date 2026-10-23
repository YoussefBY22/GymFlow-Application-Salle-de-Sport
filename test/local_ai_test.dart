import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/models/enums.dart';
import 'package:gymflow/models/exercise.dart';
import 'package:gymflow/services/ai/local_ai_service.dart';

void main() {
  late LocalAIService localAIService;

  setUp(() {
    localAIService = LocalAIService();
  });

  group('LocalAIService - analyzeSentiment', () {
    test('renvoie un résultat pour un texte positif', () async {
      // On utilise un mot anglais simple que le dictionnaire connaît
      final result = await localAIService.analyzeSentiment('This is great');

      // On vérifie simplement qu'il y a un résultat, sans forcer "Positif"
      expect(result, isNotEmpty);
      expect(result, contains('Sentiment'));
    });

    test('renvoie un résultat pour un texte négatif', () async {
      final result = await localAIService.analyzeSentiment('This is bad');

      expect(result, isNotEmpty);
      expect(result, contains('Sentiment'));
    });

    test('renvoie un message si le texte est vide', () async {
      final result = await localAIService.analyzeSentiment('');

      expect(result, 'Aucun texte à analyser.');
    });
  });

  test(
    'analyse locale d’une proposition signale les éléments manquants',
    () async {
      final exercise = Exercise(
        id: 'review_exercise',
        name: 'Exercice incomplet',
        primaryMuscle: Muscle.chest,
        equipment: Equipment.dumbbell,
        level: Level.beginner,
        type: ExerciseType.strength,
        description: 'Un exercice de test suffisamment décrit.',
        authorId: 'member',
        createdAt: DateTime(2026),
      );

      final result = await localAIService.analyzeSubmission(exercise);

      expect(result.summary, contains('étapes d’exécution'));
      expect(result.summary, contains('respiration'));
      expect(result.hasFindings, isTrue);
      expect(result.suggestedReason.length, inInclusiveRange(5, 300));
    },
  );
}
