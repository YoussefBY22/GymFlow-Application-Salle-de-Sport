import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../models/content.dart';
import '../../models/exercise.dart';
import '../../models/workout.dart';
import '../../services/backend.dart';
import '../../services/ai/local_ai_service.dart';
import '../../services/gemini_client.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';

/// File de validation (coachs et admin) : contenus proposés par les
/// abonnés, à accepter (publiés pour tous) ou refuser avec un motif.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  static String routeOf(ContentKind k) => switch (k) {
    ContentKind.exercise => Routes.exercise,
    ContentKind.workout => Routes.workout,
    ContentKind.program => Routes.program,
  };

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  final LocalAIService _localAI = LocalAIService();
  String? _cloudResult;
  bool _isGeneratingReason = false;
  SubmissionAnalysis? _localAnalysis;
  String? _reasonError;

  /// Contenu du champ « Motif communiqué à l'auteur ». Un contrôleur est
  /// nécessaire : `initialValue` n'est lu qu'au premier affichage, donc le
  /// motif rédigé par l'IA n'apparaissait pas dans le champ.
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    _localAI.dispose();
    super.dispose();
  }

  Future<void> _generateReasonWithAI(
    LibraryItem item,
    BuildContext dialogContext,
    StateSetter setStateDialog,
  ) async {
    final b = Backend.I;
    if (!b.gemini.enabled) {
      if (dialogContext.mounted) {
        setStateDialog(
          () => _cloudResult =
              'Gemini n’est pas configuré. Lancez l’application avec '
              '--dart-define-from-file=secrets.json. L’analyse locale reste '
              'disponible sans clé ni connexion.',
        );
      }
      return;
    }
    if (!dialogContext.mounted) return;
    setStateDialog(() {
      _isGeneratingReason = true;
      _cloudResult = null;
    });
    try {
      final reply = await b.gemini.generate(
        system:
            'Tu aides un coach à relire des propositions d’exercices sportifs. '
            'Rédige en français un brouillon poli et concis (maximum 3 phrases) '
            'demandant des corrections concrètes avant publication. Appuie-toi '
            'uniquement sur le contenu fourni, ne prétends pas qu’un risque '
            'médical est prouvé, n’invente aucun défaut et ne décide pas à la '
            'place du coach. Retourne uniquement le texte du brouillon.',
        contents: GeminiClient.userMessage(
          'Type : ${item.kind.label}\n'
          'Nom : ${item.name}\n'
          'Contenu à relire :\n${_submissionContext(item, b)}',
        ),
        temperature: 0.2,
        maxOutputTokens: 180,
      );
      if (!mounted || !dialogContext.mounted) return;
      setStateDialog(() {
        _isGeneratingReason = false;
        if (reply.text != null) {
          final generated = reply.text!.trim();
          _cloudResult = generated;
          _reason.text = generated.length > 300
              ? generated.substring(0, 300)
              : generated;
          _reasonError = null;
        } else {
          _cloudResult = reply.error ?? 'Gemini n’a pas généré de réponse.';
        }
      });
    } catch (error) {
      if (!mounted || !dialogContext.mounted) return;
      setStateDialog(() {
        _isGeneratingReason = false;
        _cloudResult = 'Échec de la génération Gemini : $error';
      });
    }
  }

  Future<void> _analyzeSubmission(
    LibraryItem item,
    StateSetter setStateDialog,
  ) async {
    final b = Backend.I;
    final result = await _localAI.analyzeSubmission(
      item,
      exerciseIds: b.exercises.all.map((exercise) => exercise.id).toSet(),
      workoutIds: b.workouts.all.map((workout) => workout.id).toSet(),
    );
    if (!mounted) return;
    setStateDialog(() => _localAnalysis = result);
  }

  static String _submissionContext(LibraryItem item, Backend backend) =>
      switch (item) {
        final Exercise exercise =>
          'Description : ${exercise.description}\n'
              'Muscle : ${exercise.primaryMuscle.label}\n'
              'Matériel : ${exercise.equipment.label}\n'
              'Niveau : ${exercise.level.label}\n'
              'Étapes : ${exercise.steps.join(' | ')}\n'
              'Respiration : ${exercise.breathing}\n'
              'Erreurs fréquentes : ${exercise.mistakes.join(' | ')}\n'
              'Démonstrations jointes : ${exercise.media.length}',
        final Workout workout =>
          'Description : ${workout.description}\n'
              'Objectif : ${workout.goal.label}\n'
              'Niveau : ${workout.level.label}\n'
              'Exercices : ${workout.items.map((item) {
                final exercise = backend.exercises.byId(item.exerciseId);
                return '${exercise?.name ?? 'Exercice introuvable'} : '
                    '${item.sets} séries, ${item.target}, '
                    'repos ${item.restSec}s, ${item.notes}';
              }).join(' | ')}',
        final Program program =>
          'Description : ${program.description}\n'
              'Objectif : ${program.goal.label}\n'
              'Niveau : ${program.level.label}\n'
              'Durée : ${program.weeks} semaines\n'
              'Matériel : ${program.equipment}\n'
              'Séances : ${program.days.map((day) {
                final workout = backend.workouts.byId(day.workoutId);
                return 'jour ${day.weekday} : '
                    '${workout?.name ?? 'Workout introuvable'}';
              }).join(' | ')}',
        _ => 'Aucun détail supplémentaire.',
      };

  Future<void> _reject(BuildContext context, LibraryItem x) async {
    _cloudResult = null;
    _localAnalysis = null;
    _reasonError = null;
    _isGeneratingReason = false;
    _reason.clear();

    final reason = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: Text('Refuser « ${x.name} »'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Card(
                      color: Colors.blue.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.cloud,
                                  color: Colors.blue,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    'Gemini · brouillon de refus',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: _isGeneratingReason
                                      ? null
                                      : () async {
                                          await _generateReasonWithAI(
                                            x,
                                            context,
                                            setStateDialog,
                                          );
                                        },
                                  child: const Text('Générer'),
                                ),
                              ],
                            ),
                            if (_isGeneratingReason)
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: LinearProgressIndicator(),
                              ),
                            if (_cloudResult != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Text(
                                  _cloudResult!,
                                  style: const TextStyle(
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    Card(
                      color: Colors.green.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.phone_android,
                                  color: Colors.green,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    'Analyse locale du contenu',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    await _analyzeSubmission(x, setStateDialog);
                                  },
                                  child: const Text('Analyser'),
                                ),
                              ],
                            ),
                            if (_localAnalysis != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _localAnalysis!.summary,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (_localAnalysis!.hasFindings)
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton(
                                          key: const Key(
                                            'use_local_review_reason',
                                          ),
                                          onPressed: () => setStateDialog(() {
                                            _reason.text =
                                                _localAnalysis!.suggestedReason;
                                            _reasonError = null;
                                          }),
                                          child: const Text(
                                            'Utiliser comme motif',
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // --- CHAMP DE SAISIE DU MOTIF ---
                    const Text("Motif communiqué à l'auteur :"),
                    const SizedBox(height: 8),
                    TextFormField(
                      key: ValueKey('review_reason_${x.id}'),
                      controller: _reason,
                      maxLines: 3,
                      maxLength: 300,
                      decoration: const InputDecoration(
                        hintText: 'Ex. ajoutez une étape, précisez le repos…',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (_) =>
                          setStateDialog(() => _reasonError = null),
                    ),
                    if (_reasonError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _reasonError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Annuler"),
                ),
                ElevatedButton(
                  onPressed: () {
                    final value = _reason.text.trim();
                    if (value.length < 5) {
                      setStateDialog(
                        () => _reasonError =
                            'Le motif doit contenir au moins 5 caractères.',
                      );
                      return;
                    }
                    Navigator.pop(context, value);
                  },
                  child: const Text("Envoyer le refus"),
                ),
              ],
            );
          },
        );
      },
    );

    if (reason == null || !context.mounted) return;

    // Appel à votre logique métier existante (INCHANGÉE)
    await runAction(
      context,
      () => Backend.I.library.reject(x.kind, x.id, reason),
      success: 'Refus envoyé à l\'auteur.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Scaffold(
      appBar: AppBar(title: const Text('Propositions à valider')),
      body: ListenableBuilder(
        listenable: b.bus,
        builder: (context, _) {
          final queue = b.library.reviewQueue();
          if (queue.isEmpty) {
            return const EmptyState(
              icon: Icons.fact_check_outlined,
              title: 'Rien à valider',
              message:
                  'Les exercices, workouts et programmes proposés par les '
                  'membres apparaîtront ici.',
            );
          }
          return ListView(
            padding: pagePadding(context, maxWidth: 900),
            children: [
              GfCard(
                color: AppColors.cream,
                child: InfoRow(
                  Icons.info_outline,
                  'Vérifiez la sécurité des consignes (charges, amplitude, '
                  'repos) et la qualité des médias avant de publier. '
                  'Un refus doit toujours être motivé.',
                ),
              ),
              const SizedBox(height: Gap.m),
              for (var i = 0; i < queue.length; i++)
                FadeSlideIn(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: Gap.s),
                    child: _ReviewCard(
                      item: queue[i],
                      onReject: () => _reject(context, queue[i]),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// --- LE WIDGET _ReviewCard RESTE TOTALEMENT INCHANGÉ ---
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.item, required this.onReject});
  final LibraryItem item;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final x = item;
    final deps = b.library
        .dependenciesOf(x)
        .where((d) => d.publication.isPending)
        .toList();
    return GfCard(
      key: ValueKey('review_${x.id}'),
      onTap: () => Navigator.pushNamed(
        context,
        ReviewScreen.routeOf(x.kind),
        arguments: x.id,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.navy,
                child: Icon(x.kind.icon, color: AppColors.white, size: 20),
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(x.name, style: AppText.subtitle()),
                    if (x.altName != null)
                      Text(
                        x.altName!,
                        style: AppText.label(
                          size: 12,
                        ).copyWith(fontStyle: FontStyle.italic),
                      ),
                    Text(
                      '${x.kind.label} · ${b.library.authorLabel(x)}'
                      '${x.publication.submittedAt == null ? '' : ' · ${Fmt.relative(x.publication.submittedAt!, now: b.now())}'}',
                      style: AppText.label(size: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: AppColors.heading),
            ],
          ),
          if (deps.isNotEmpty) ...[
            const SizedBox(height: Gap.s),
            InfoRow(
              Icons.link,
              'Publié avec : ${deps.map((d) => '${d.kind.lower} « ${d.name} »').join(', ')}',
            ),
          ],
          const SizedBox(height: Gap.s),
          Wrap(
            spacing: Gap.s,
            runSpacing: Gap.s,
            alignment: WrapAlignment.end,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.redText),
                onPressed: onReject,
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Refuser'),
              ),
              ElevatedButton.icon(
                key: ValueKey('approve_${x.id}'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: AppColors.white,
                ),
                onPressed: () => runAction(
                  context,
                  () => b.library.approve(x.kind, x.id),
                  success: '« ${x.name} » est publié.',
                ),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Publier'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
