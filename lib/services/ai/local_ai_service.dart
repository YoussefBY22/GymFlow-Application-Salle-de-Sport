import 'package:sentiment_dart/sentiment_dart.dart';

import '../../models/content.dart';
import '../../models/exercise.dart';
import '../../models/workout.dart';

class SubmissionAnalysis {
  const SubmissionAnalysis({required this.findings});

  final List<String> findings;

  bool get hasFindings => findings.isNotEmpty;

  String get summary => findings.isEmpty
      ? 'Aucun manque évident détecté par les vérifications locales. '
            'Vérifiez tout de même le contenu et les médias avant publication.'
      : 'Points à vérifier (${findings.length}) :\n'
            '${findings.map((finding) => '• $finding').join('\n')}';

  String get suggestedReason {
    if (findings.isEmpty) return '';
    final detail = findings.take(2).join('; ');
    const prefix =
        'Merci pour votre proposition. Avant sa publication, '
        'merci de compléter ou vérifier : ';
    final available = 300 - prefix.length - 1;
    final truncated = detail.length > available
        ? '${detail.substring(0, available - 1)}…'
        : detail;
    return '$prefix$truncated.';
  }
}

class LocalAIService {
  /// Contrôles de complétude simples, exécutés sur le téléphone et sans réseau.
  /// Ils signalent des points à vérifier, jamais une décision automatique.
  Future<SubmissionAnalysis> analyzeSubmission(
    LibraryItem item, {
    Set<String> exerciseIds = const {},
    Set<String> workoutIds = const {},
  }) {
    final findings = <String>[];
    if (item.name.trim().length < 3) {
      findings.add('Le nom est trop court pour identifier le contenu.');
    }

    switch (item) {
      case Exercise exercise:
        if (exercise.description.trim().length < 10) {
          findings.add('La description est trop courte.');
        }
        if (exercise.steps.isEmpty) {
          findings.add('Ajoutez les étapes d’exécution de l’exercice.');
        }
        if (exercise.breathing.trim().isEmpty) {
          findings.add('Précisez les consignes de respiration.');
        }
        if (exercise.media.isEmpty) {
          findings.add(
            'Aucun média de démonstration n’est joint (facultatif).',
          );
        }
      case Workout workout:
        if (workout.description.trim().length < 10) {
          findings.add('La description du workout est trop courte.');
        }
        if (workout.items.isEmpty) {
          findings.add('Le workout ne contient aucun exercice.');
        }
        for (final item in workout.items) {
          if (exerciseIds.isNotEmpty &&
              !exerciseIds.contains(item.exerciseId)) {
            findings.add('Un exercice référencé est introuvable.');
            break;
          }
        }
        if (workout.items.any((item) => item.sets < 1 || item.sets > 10)) {
          findings.add(
            'Vérifiez le nombre de séries (repère local : 1 à 10 par exercice).',
          );
        }
        if (workout.items.any(
          (item) => item.reps != null && item.reps! > 100,
        )) {
          findings.add('Vérifiez les objectifs de répétitions très élevés.');
        }
      case Program program:
        if (program.description.trim().length < 10) {
          findings.add('La description du programme est trop courte.');
        }
        if (program.weeks < 1 || program.weeks > 52) {
          findings.add('Vérifiez la durée du programme (1 à 52 semaines).');
        }
        if (program.days.isEmpty) {
          findings.add('Le programme ne contient aucune séance planifiée.');
        }
        if (program.days.map((day) => day.weekday).toSet().length !=
            program.days.length) {
          findings.add('Plusieurs séances sont assignées au même jour.');
        }
        if (program.days.any((day) => !workoutIds.contains(day.workoutId))) {
          findings.add('Une séance référencée est introuvable.');
        }
      default:
        findings.add('Type de contenu non reconnu par les vérifications.');
    }

    return Future.value(SubmissionAnalysis(findings: findings));
  }

  /// Analyse le sentiment d'un texte EN LOCAL (sans API, fonctionne sur Desktop)
  Future<String> analyzeSentiment(String text) async {
    if (text.trim().isEmpty) {
      return "Aucun texte à analyser.";
    }

    try {
      // Utilisation de la méthode statique directement (sans 'new Sentiment()')
      final sentiment = Sentiment.analysis(text);

      if (sentiment.score > 0) {
        return "Sentiment : Positif (Score: ${sentiment.score})";
      } else if (sentiment.score < 0) {
        return "Sentiment : Négatif (Score: ${sentiment.score})";
      } else {
        return "Sentiment : Neutre (Score: ${sentiment.score})";
      }
    } catch (e) {
      return "Erreur lors de l'analyse locale : $e";
    }
  }

  void dispose() {}
}
