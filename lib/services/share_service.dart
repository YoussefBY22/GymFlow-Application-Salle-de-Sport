import '../core/errors.dart';
import '../core/formatters.dart';
import '../core/search.dart';
import '../models/chat.dart';
import '../models/enums.dart';
import '../models/exercise.dart';
import '../models/session_log.dart';
import '../models/workout.dart';
import 'backend.dart';

/// Partage d'une séance, d'un workout, d'un exercice ou d'un programme dans
/// une discussion.
///
/// Ce qui voyage est un **instantané en texte** (jamais d'image ni de vidéo),
/// chiffré comme un message : le destinataire peut le lire même si
/// l'élément n'existe pas sur son téléphone. Il peut aussi l'**enregistrer
/// chez lui** : une copie **privée**, sans les photos ni les vidéos.
class ShareService {
  ShareService(this._b);
  final Backend _b;

  /// Plafond de séries conservées dans une séance partagée (le message reste
  /// très en dessous de la taille maximale acceptée par le serveur).
  static const maxSessionSets = 150;

  // ------------------------------------------------------------- Création

  ShareCard sessionCard(SessionLog s) {
    final sets = s.sets.take(maxSessionSets).toList();
    return ShareCard(
      type: 'session',
      title: s.title,
      subtitle:
          '${Fmt.date(s.startedAt)} · ${s.durationSec ~/ 60} min · '
          '${Fmt.dec1(s.totalVolume / 1000)} t',
      data: {
        'startedAt': s.startedAt.toIso8601String(),
        'durationSec': s.durationSec,
        'exerciseCount': s.exerciseCount,
        'prCount': s.prCount,
        'volume': s.totalVolume,
        if (s.caloriesBurned != null) 'calories': s.caloriesBurned,
        if (s.averageHeartRate != null) 'avgHr': s.averageHeartRate,
        'sets': [
          for (final x in sets)
            {
              'n': x.exerciseName,
              'i': x.setIndex,
              'r': x.reps,
              'k': x.loadKg,
              if (x.durationSec != null) 'd': x.durationSec,
            },
        ],
      },
    );
  }

  Map<String, dynamic> _exerciseData(Exercise e) => {
    'name': e.name,
    'muscle': e.primaryMuscle.name,
    'equipment': e.equipment.name,
    'level': e.level.name,
    'type': e.type.name,
    'description': e.description,
    'secondary': [for (final m in e.secondaryMuscles) m.name],
    'steps': e.steps,
    'mistakes': e.mistakes,
    'breathing': e.breathing,
  };

  Map<String, dynamic> _workoutData(Workout w) {
    final resolved = _b.workoutService.resolve(w);
    final exercises = <Map<String, dynamic>>[];
    final index = <String, int>{};
    final items = <Map<String, dynamic>>[];
    for (final (item, ex) in resolved) {
      final i = index.putIfAbsent(ex.id, () {
        exercises.add(_exerciseData(ex));
        return exercises.length - 1;
      });
      items.add({
        'e': i,
        'sets': item.sets,
        'reps': item.reps,
        'dur': item.durationSec,
        'rest': item.restSec,
        if (item.tempo.isNotEmpty) 'tempo': item.tempo,
        if (item.suggestedLoad.isNotEmpty) 'load': item.suggestedLoad,
        if (item.notes.isNotEmpty) 'notes': item.notes,
      });
    }
    return {
      'name': w.name,
      'description': w.description,
      'level': w.level.name,
      'goal': w.goal.name,
      'focus': w.focus,
      'exercises': exercises,
      'items': items,
    };
  }

  ShareCard workoutCard(Workout w) {
    final data = _workoutData(w);
    return ShareCard(
      type: 'workout',
      title: w.name,
      subtitle: '${(data['items'] as List).length} exercices · ${w.level.label}',
      data: data,
    );
  }

  ShareCard exerciseCard(Exercise e) => ShareCard(
    type: 'exercise',
    title: e.name,
    subtitle: '${e.primaryMuscle.label} · ${e.equipment.label}',
    data: _exerciseData(e),
  );

  ShareCard programCard(Program p) {
    final days = <Map<String, dynamic>>[];
    for (final d in p.days) {
      final w = _b.workoutService.workoutById(d.workoutId);
      if (w != null) days.add({'weekday': d.weekday, 'workout': _workoutData(w)});
    }
    return ShareCard(
      type: 'program',
      title: p.name,
      subtitle: '${p.weeks} semaines · ${days.length} jours/semaine',
      data: {
        'description': p.description,
        'level': p.level.name,
        'goal': p.goal.name,
        'weeks': p.weeks,
        'equipment': p.equipment,
        'days': days,
      },
    );
  }

  // ----------------------------------------------- Ce qu'on peut partager

  List<SessionLog> mySessions({int limit = 30}) {
    final me = _b.requireUser();
    return _b.trainingLog.historyOf(me.id).take(limit).toList();
  }

  List<Workout> workouts() => _b.library.workouts();
  List<Exercise> exercises() => _b.library.exercises();
  List<Program> programs() => _b.library.programs();

  // --------------------------------------------------------- Enregistrer

  Exercise? _findExercise(String name) {
    final me = _b.requireUser();
    final key = Search.normalize(name);
    for (final e in _b.exercises.all) {
      if (_b.library.canSee(me, e) && Search.normalize(e.name) == key) return e;
    }
    return null;
  }

  Muscle _muscle(Object? v) => enumFrom(Muscle.values, v, Muscle.fullBody);
  Equipment _equipment(Object? v) =>
      enumFrom(Equipment.values, v, Equipment.bodyweight);
  Level _level(Object? v) => enumFrom(Level.values, v, Level.beginner);
  ExerciseType _type(Object? v) =>
      enumFrom(ExerciseType.values, v, ExerciseType.strength);
  Goal _goal(Object? v) => enumFrom(Goal.values, v, Goal.fitness);

  List<String> _strings(Object? v) => [
    for (final x in (v as List? ?? const [])) '$x',
  ];

  /// Retrouve l'exercice sur ce téléphone (même nom) ou en crée une copie
  /// privée à partir de l'instantané.
  Future<Exercise> _ensureExercise(Map<String, dynamic> d) async {
    final name = '${d['name'] ?? ''}'.trim();
    final existing = _findExercise(name);
    if (existing != null) return existing;
    var description = '${d['description'] ?? ''}'.trim();
    if (description.length < 10) {
      description = 'Exercice reçu d\'un ami : $name.';
    }
    return _b.exerciseService.create(
      name: name,
      primaryMuscle: _muscle(d['muscle']),
      secondaryMuscles: [
        for (final m in _strings(d['secondary'])) _muscle(m),
      ],
      equipment: _equipment(d['equipment']),
      level: _level(d['level']),
      type: _type(d['type']),
      description: description,
      steps: _strings(d['steps']),
      mistakes: _strings(d['mistakes']),
      breathing: '${d['breathing'] ?? ''}',
    );
  }

  Future<Workout> _saveWorkoutFrom(Map<String, dynamic> d) async {
    final exercises = <Exercise>[];
    for (final e in (d['exercises'] as List? ?? const [])) {
      exercises.add(await _ensureExercise(Map<String, dynamic>.from(e as Map)));
    }
    final items = <WorkoutItem>[];
    for (final raw in (d['items'] as List? ?? const [])) {
      final i = Map<String, dynamic>.from(raw as Map);
      final idx = (i['e'] as num?)?.toInt() ?? -1;
      if (idx < 0 || idx >= exercises.length) continue;
      items.add(
        WorkoutItem(
          exerciseId: exercises[idx].id,
          sets: ((i['sets'] as num?)?.toInt() ?? 3).clamp(1, 10),
          reps: (i['reps'] as num?)?.toInt(),
          durationSec: (i['dur'] as num?)?.toInt(),
          restSec: ((i['rest'] as num?)?.toInt() ?? 60).clamp(0, 600),
          tempo: '${i['tempo'] ?? ''}',
          suggestedLoad: '${i['load'] ?? ''}',
          notes: '${i['notes'] ?? ''}',
        ),
      );
    }
    if (items.isEmpty) {
      throw const BusinessRuleException(
        'Ce workout ne contient aucun exercice lisible.',
      );
    }
    var name = '${d['name'] ?? 'Workout reçu'}'.trim();
    if (name.length < 3) name = 'Workout reçu';
    if (name.length > 80) name = name.substring(0, 80);
    return _b.workoutService.saveWorkout(
      name: name,
      description: '${d['description'] ?? ''}',
      level: _level(d['level']),
      goal: _goal(d['goal']),
      items: items,
      focus: '${d['focus'] ?? ''}',
    );
  }

  /// Enregistre l'élément partagé **chez moi**, en copie privée (sans photo
  /// ni vidéo). Une séance partagée est un résumé : elle ne s'enregistre pas.
  Future<String> save(ShareCard card) async {
    _b.requireUser();
    switch (card.type) {
      case 'exercise':
        final e = await _ensureExercise(card.data);
        return 'Exercice « ${e.name} » enregistré dans vos exercices.';
      case 'workout':
        final w = await _saveWorkoutFrom(card.data);
        return 'Workout « ${w.name} » enregistré dans vos workouts.';
      case 'program':
        final days = <ProgramDay>[];
        for (final raw in (card.data['days'] as List? ?? const [])) {
          final d = Map<String, dynamic>.from(raw as Map);
          final w = await _saveWorkoutFrom(
            Map<String, dynamic>.from(d['workout'] as Map),
          );
          days.add(
            ProgramDay(
              weekday: ((d['weekday'] as num?)?.toInt() ?? 1).clamp(1, 7),
              workoutId: w.id,
            ),
          );
        }
        if (days.isEmpty) {
          throw const BusinessRuleException(
            'Ce programme ne contient aucun workout lisible.',
          );
        }
        var name = card.title.trim();
        if (name.length < 3) name = 'Programme reçu';
        if (name.length > 80) name = name.substring(0, 80);
        final p = await _b.workoutService.saveProgram(
          name: name,
          description: '${card.data['description'] ?? ''}',
          level: _level(card.data['level']),
          goal: _goal(card.data['goal']),
          weeks: ((card.data['weeks'] as num?)?.toInt() ?? 4).clamp(1, 52),
          days: days,
          equipment: '${card.data['equipment'] ?? ''}',
        );
        return 'Programme « ${p.name} » enregistré dans vos programmes.';
      default:
        throw const BusinessRuleException(
          'Une séance partagée est un résumé : elle ne peut pas être enregistrée.',
        );
    }
  }

  /// Un élément partagé peut-il être enregistré ?
  bool canSave(ShareCard card) => card.type != 'session';
}
