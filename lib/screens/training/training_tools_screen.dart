import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../models/enums.dart';
import '../../models/session_log.dart';
import '../../services/backend.dart';
import '../../services/outdoor_route_service.dart';
import '../../services/training_progress_ai_service.dart';
import '../../services/training_toolkit_service.dart';

class TrainingToolsScreen extends StatefulWidget {
  const TrainingToolsScreen({super.key});

  @override
  State<TrainingToolsScreen> createState() => _TrainingToolsScreenState();
}

class _TrainingToolsScreenState extends State<TrainingToolsScreen>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 4, vsync: this);
  late final _store = TrainingToolkitStore(Backend.I.requireUser().id);
  final _routes = OutdoorRouteService();
  final _progressAi = TrainingProgressAiService();
  final _latitude = TextEditingController(text: '36.8347');
  final _longitude = TextEditingController(text: '10.2407');
  final _distance = TextEditingController(text: '5');
  bool _loading = true;
  bool _findingPlaces = false;
  bool _generatingProgress = false;
  String? _error;
  String? _progressReport;
  String? _progressError;
  String? _suggestionError;
  List<SuggestedExercise> _suggestedExercises = [];
  TrainingPlan? _plan;
  List<TrainingCheckIn> _checkIns = [];
  List<OutdoorPlace> _places = [];
  WalkingRoute? _route;
  OutdoorPlace? _selectedPlace;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _routes.dispose();
    _progressAi.dispose();
    _latitude.dispose();
    _longitude.dispose();
    _distance.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final plan = await _store.loadPlan();
      final checkIns = await _store.loadCheckIns();
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _checkIns = checkIns;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Certaines données n’ont pas pu être chargées. Réessayez.';
        _loading = false;
      });
    }
  }

  double? _number(TextEditingController controller) =>
      double.tryParse(controller.text.trim().replaceAll(',', '.'));

  Future<void> _findPlaces() async {
    final lat = _number(_latitude);
    final lon = _number(_longitude);
    final km = _number(_distance);
    if (lat == null ||
        lon == null ||
        km == null ||
        lat < -90 ||
        lat > 90 ||
        lon < -180 ||
        lon > 180 ||
        km < 1 ||
        km > 20) {
      setState(
        () => _error =
            'Coordonnées invalides. Latitude : -90 à 90, longitude : '
            '-180 à 180, distance cible : 1 à 20 km.',
      );
      return;
    }
    setState(() {
      _findingPlaces = true;
      _error = null;
      _places = [];
      _route = null;
      _selectedPlace = null;
    });
    try {
      final places = await _routes.findPlaces(
        latitude: lat,
        longitude: lon,
        radiusMeters: math.min(km * 500, 10000),
      );
      if (!mounted) return;
      setState(() {
        _places = places;
        _findingPlaces = false;
        if (places.isEmpty) {
          _error =
              'Aucun parc ou espace sportif trouvé dans cette zone. '
              'Essayez un autre point de départ ou une distance supérieure.';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _findingPlaces = false;
        _error = error is OutdoorRouteException
            ? error.message
            : 'La recherche a échoué. Vérifiez votre connexion puis réessayez.';
      });
    }
  }

  Future<void> _routeTo(OutdoorPlace place) async {
    final lat = _number(_latitude);
    final lon = _number(_longitude);
    if (lat == null ||
        lon == null ||
        lat < -90 ||
        lat > 90 ||
        lon < -180 ||
        lon > 180) {
      setState(() => _error = 'Coordonnées de départ invalides.');
      return;
    }
    setState(() {
      _selectedPlace = place;
      _route = null;
      _error = null;
    });
    try {
      final route = await _routes.walkingRoute(
        startLatitude: lat,
        startLongitude: lon,
        endLatitude: place.latitude,
        endLongitude: place.longitude,
      );
      if (!mounted) return;
      setState(() => _route = route);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is OutdoorRouteException
            ? error.message
            : 'Le trajet détaillé est indisponible. Vous pouvez l’ouvrir dans Maps.',
      );
    }
  }

  Future<void> _openMap() async {
    final place = _selectedPlace;
    if (place == null) return;
    final uri = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'origin': '${_latitude.text},${_longitude.text}',
      'destination': '${place.latitude},${place.longitude}',
      'travelmode': 'walking',
    });
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
          mounted) {
        setState(() => _error = 'Impossible d’ouvrir l’application de cartes.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Impossible d’ouvrir l’application de cartes.');
      }
    }
  }

  Muscle? _latestTrainedMuscle(List<SessionLog> sessions) {
    final ordered = [...sessions]
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    for (final session in ordered) {
      for (final set in session.sets.reversed) {
        final exercise = Backend.I.exerciseService.byId(set.exerciseId);
        if (exercise != null &&
            exercise.primaryMuscle != Muscle.fullBody &&
            exercise.primaryMuscle != Muscle.cardio) {
          return exercise.primaryMuscle;
        }
      }
    }
    return null;
  }

  Future<void> _generateProgressReport() async {
    final backend = Backend.I;
    final user = backend.requireUser();
    final sessions = backend.trainingLog.historyOf(user.id);
    final summary = TrainingProgressSummary.fromSessions(
      sessions,
      backend.now(),
    );
    if (!summary.hasRecentSessions) {
      setState(() {
        _progressReport = null;
        _progressError =
            'Terminez une séance pour obtenir un bilan de progression.';
        _suggestedExercises = [];
        _suggestionError = null;
      });
      return;
    }

    setState(() {
      _generatingProgress = true;
      _progressReport = null;
      _progressError = null;
      _suggestionError = null;
      _suggestedExercises = [];
    });

    try {
      final report = await _progressAi.createProgressReport(
        summary: summary,
        goal: user.goal.label,
      );
      if (!mounted) return;
      setState(() => _progressReport = report);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _progressError = error is TrainingProgressApiException
            ? error.message
            : 'Le bilan n’a pas pu être généré. Réessayez dans quelques instants.',
      );
    }

    final muscle = _latestTrainedMuscle(sessions);
    if (muscle == null) {
      if (mounted) {
        setState(
          () => _suggestionError =
              'Aucun groupe musculaire identifiable dans vos séances récentes.',
        );
      }
    } else {
      try {
        final suggestions = await _progressAi.suggestExercises(muscle);
        if (mounted) {
          setState(() => _suggestedExercises = suggestions);
        }
      } catch (error) {
        if (mounted) {
          setState(
            () => _suggestionError = error is TrainingProgressApiException
                ? error.message
                : 'Les suggestions ne sont pas disponibles pour le moment.',
          );
        }
      }
    }
    if (mounted) setState(() => _generatingProgress = false);
  }

  Future<void> _savePlan({
    required String goal,
    required int weeks,
    required int days,
  }) async {
    final plan = TrainingPlan(
      goal: goal,
      weeks: weeks,
      sessionsPerWeek: days,
      startDate: DateUtils.dateOnly(DateTime.now()),
    );
    try {
      await _store.savePlan(plan);
      if (mounted) setState(() => _plan = plan);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Le cycle n’a pas pu être enregistré.');
      }
    }
  }

  Future<void> _showPlanDialog() async {
    var goal = _plan?.goal ?? 'Forme générale';
    var weeks = _plan?.weeks ?? 4;
    var days = _plan?.sessionsPerWeek ?? 3;
    final result = await showDialog<(String, int, int)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Planifier un cycle'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: goal,
                decoration: const InputDecoration(labelText: 'Objectif'),
                items: const [
                  DropdownMenuItem(
                    value: 'Forme générale',
                    child: Text('Forme générale'),
                  ),
                  DropdownMenuItem(value: 'Force', child: Text('Force')),
                  DropdownMenuItem(
                    value: 'Endurance',
                    child: Text('Endurance'),
                  ),
                ],
                onChanged: (value) => update(() => goal = value ?? goal),
              ),
              DropdownButtonFormField<int>(
                initialValue: weeks,
                decoration: const InputDecoration(labelText: 'Durée du cycle'),
                items: [
                  for (final value in [4, 6, 8])
                    DropdownMenuItem(
                      value: value,
                      child: Text('$value semaines'),
                    ),
                ],
                onChanged: (value) => update(() => weeks = value ?? weeks),
              ),
              DropdownButtonFormField<int>(
                initialValue: days,
                decoration: const InputDecoration(
                  labelText: 'Séances par semaine',
                ),
                items: [
                  for (final value in [2, 3, 4, 5, 6])
                    DropdownMenuItem(
                      value: value,
                      child: Text('$value séances'),
                    ),
                ],
                onChanged: (value) => update(() => days = value ?? days),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, (goal, weeks, days)),
              child: const Text('Créer le cycle'),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      await _savePlan(goal: result.$1, weeks: result.$2, days: result.$3);
    }
  }

  Future<void> _checkIn(SessionLog session) async {
    var rpe = 6;
    var fatigue = 3;
    final result = await showDialog<(int, int)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Ressenti · ${session.title}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Effort ressenti : $rpe/10'),
              Slider(
                value: rpe.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                label: '$rpe',
                onChanged: (value) => update(() => rpe = value.round()),
              ),
              Text('Fatigue ressentie : $fatigue/10'),
              Slider(
                value: fatigue.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                label: '$fatigue',
                onChanged: (value) => update(() => fatigue = value.round()),
              ),
              Text(
                '1 = très facile / aucune fatigue · 10 = effort maximal / '
                'fatigue élevée',
                style: AppText.body(size: 12, color: AppColors.inkSoft),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, (rpe, fatigue)),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final entry = TrainingCheckIn(
      sessionId: session.id,
      sessionTitle: session.title,
      date: session.endedAt,
      durationMinutes: math.max(1, (session.durationSec / 60).round()).toInt(),
      rpe: result.$1,
      fatigue: result.$2,
    );
    try {
      await _store.saveCheckIn(entry);
      final updated = await _store.loadCheckIns();
      if (mounted) setState(() => _checkIns = updated);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Le ressenti n’a pas pu être enregistré.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Outils d’entraînement'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.directions_walk), text: 'Parcours'),
            Tab(icon: Icon(Icons.calendar_month), text: 'Planification'),
            Tab(icon: Icon(Icons.monitor_heart_outlined), text: 'Récupération'),
            Tab(icon: Icon(Icons.auto_awesome), text: 'Bilan IA'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (error != null)
                  MaterialBanner(
                    content: Text(error),
                    leading: const Icon(Icons.info_outline),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _error = null),
                        child: const Text('Fermer'),
                      ),
                    ],
                  ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _buildRoutes(),
                      _buildPlan(),
                      _buildRecovery(),
                      _buildProgressAnalysis(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildRoutes() => ListView(
    padding: const EdgeInsets.all(Gap.m),
    children: [
      const Text(
        'Trouvez un parc ou un espace sportif près de votre départ, puis '
        'calculez un itinéraire piéton avec son dénivelé.',
      ),
      const SizedBox(height: Gap.m),
      TextField(
        controller: _latitude,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        decoration: const InputDecoration(
          labelText: 'Latitude de départ',
          helperText: 'Par défaut : club GymFlow Lac 2',
        ),
      ),
      const SizedBox(height: Gap.m),
      TextField(
        controller: _longitude,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        decoration: const InputDecoration(labelText: 'Longitude de départ'),
      ),
      const SizedBox(height: Gap.m),
      TextField(
        controller: _distance,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          labelText: 'Distance cible approximative (km)',
          helperText:
              'Détermine le rayon de recherche, pas la distance finale.',
          // Sans cela, l'explication était coupée en plein milieu.
          helperMaxLines: 3,
        ),
      ),
      const SizedBox(height: Gap.l),
      FilledButton.icon(
        onPressed: _findingPlaces ? null : _findPlaces,
        icon: _findingPlaces
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.search),
        label: const Text('Rechercher les espaces'),
      ),
      if (_places.isNotEmpty) ...[
        const SizedBox(height: Gap.l),
        Text(
          'Espaces trouvés (${_places.length})',
          style: AppText.title(size: 17),
        ),
        const SizedBox(height: Gap.s),
        for (final place in _places)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              place.type == 'park' ? Icons.park_outlined : Icons.sports,
            ),
            title: Text(place.name),
            subtitle: Text(place.type == 'park' ? 'Parc' : 'Espace sportif'),
            trailing: Icon(
              _selectedPlace?.id == place.id
                  ? Icons.check_circle
                  : Icons.directions,
            ),
            onTap: () => _routeTo(place),
          ),
      ],
      if (_route case final route?) ...[
        const Divider(height: 28),
        Text(
          'Parcours vers ${_selectedPlace?.name}',
          style: AppText.title(size: 17),
        ),
        ListTile(
          leading: const Icon(Icons.straighten),
          title: Text('${(route.distanceMeters / 1000).toStringAsFixed(2)} km'),
          subtitle: const Text('Distance réelle sur le réseau piéton'),
        ),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: Text(_formatDuration(route.durationSeconds)),
          subtitle: const Text('Durée estimée du parcours'),
        ),
        ListTile(
          leading: const Icon(Icons.terrain),
          title: Text(
            '+${route.elevationGainMeters.round()} m / '
            '-${route.elevationLossMeters.round()} m',
          ),
          subtitle: const Text('Dénivelé cumulé positif / négatif'),
        ),
        if (route.instructions.isNotEmpty)
          ExpansionTile(
            title: const Text('Instructions piétonnes'),
            children: [
              for (var i = 0; i < route.instructions.length; i++)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 14,
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  title: Text(route.instructions[i]),
                ),
            ],
          ),
        OutlinedButton.icon(
          onPressed: _openMap,
          icon: const Icon(Icons.map_outlined),
          label: const Text('Ouvrir le trajet dans Maps'),
        ),
      ],
      if (_selectedPlace != null && _route == null)
        OutlinedButton.icon(
          onPressed: _openMap,
          icon: const Icon(Icons.map_outlined),
          label: const Text('Ouvrir l’itinéraire dans Maps'),
        ),
      const SizedBox(height: Gap.m),
      Text(
        'Données cartographiques © OpenStreetMap contributors. '
        'Vérifiez le parcours et les conditions sur place avant de partir.',
        style: AppText.body(size: 12, color: AppColors.inkSoft),
      ),
    ],
  );

  Widget _buildPlan() => ListView(
    padding: const EdgeInsets.all(Gap.m),
    children: [
      const Text(
        'Programmation par cycles : alternance entre adaptation, progression '
        'et allègement afin de structurer vos semaines.',
      ),
      const SizedBox(height: Gap.m),
      FilledButton.icon(
        onPressed: _showPlanDialog,
        icon: const Icon(Icons.add_task),
        label: Text(_plan == null ? 'Créer un cycle' : 'Modifier le cycle'),
      ),
      if (_plan case final plan?) ...[
        const SizedBox(height: Gap.m),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${plan.goal} · ${plan.weeks} semaines',
                  style: AppText.title(size: 17),
                ),
                Text('${plan.sessionsPerWeek} séances par semaine'),
                Text('Début : ${_formatDate(plan.startDate)}'),
              ],
            ),
          ),
        ),
        for (var week = 1; week <= plan.weeks; week++)
          Card(
            margin: const EdgeInsets.only(bottom: Gap.s),
            child: ListTile(
              leading: CircleAvatar(child: Text('$week')),
              title: Text('Semaine $week · ${plan.phaseForWeek(week)}'),
              subtitle: Text(plan.guidanceForWeek(week)),
            ),
          ),
        const SizedBox(height: Gap.s),
        Text(
          'Ce planning est un guide indicatif : adaptez-le à votre expérience, '
          'à votre matériel et à vos sensations. Il ne modifie aucun workout '
          'existant.',
          style: AppText.body(size: 12, color: AppColors.inkSoft),
        ),
      ],
    ],
  );

  Widget _buildRecovery() {
    final user = Backend.I.requireUser();
    final sessions = Backend.I.trainingLog.historyOf(user.id);
    final checkedIds = _checkIns.map((entry) => entry.sessionId).toSet();
    final pending = sessions
        .where((session) => !checkedIds.contains(session.id))
        .take(8)
        .toList();
    final assessment = TrainingLoadAssessment.fromCheckIns(
      _checkIns,
      DateTime.now(),
    );
    final maximumDailyLoad = _checkIns
        .where(
          (entry) => !entry.date.isBefore(
            DateTime.now().subtract(const Duration(days: 7)),
          ),
        )
        .fold<int>(0, (max, entry) => max > entry.load ? max : entry.load);
    return ListView(
      padding: const EdgeInsets.all(Gap.m),
      children: [
        const Text(
          'Après une séance, indiquez l’effort et la fatigue ressentis. '
          'L’indicateur session-RPE suit la charge déclarée, sans diagnostic.',
        ),
        const SizedBox(height: Gap.m),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(assessment.label, style: AppText.title(size: 17)),
                const SizedBox(height: Gap.xs),
                Text(assessment.advice),
                if (assessment.ratio != null) ...[
                  const SizedBox(height: Gap.s),
                  Text(
                    'Charge 7 jours : ${assessment.recentLoad} UA · '
                    'ratio indicatif : ${assessment.ratio!.toStringAsFixed(2)}',
                  ),
                ],
                if (assessment.fatigueAverage != null)
                  Text(
                    'Fatigue moyenne déclarée (7 jours) : '
                    '${assessment.fatigueAverage!.toStringAsFixed(1)}/10',
                  ),
                if (maximumDailyLoad > 0) ...[
                  const SizedBox(height: Gap.m),
                  for (var offset = 6; offset >= 0; offset--)
                    _dailyLoadBar(offset, maximumDailyLoad),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.m),
        Text('Séances à évaluer', style: AppText.title(size: 17)),
        const SizedBox(height: Gap.s),
        if (pending.isEmpty)
          const ListTile(
            leading: Icon(Icons.check_circle_outline),
            title: Text('Toutes les séances récentes ont un ressenti.'),
          ),
        for (final session in pending)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.fitness_center),
            title: Text(session.title),
            subtitle: Text(
              '${_formatDate(session.endedAt)} · '
              '${(session.durationSec / 60).round()} min',
            ),
            trailing: IconButton(
              tooltip: 'Saisir le ressenti',
              onPressed: () => _checkIn(session),
              icon: const Icon(Icons.add_comment_outlined),
            ),
          ),
        const SizedBox(height: Gap.m),
        Text(
          'UA = unités arbitraires (durée en minutes × effort perçu /10). '
          'Le ratio compare les 7 derniers jours aux 21 jours précédents. '
          'Ces repères ne remplacent pas l’avis d’un professionnel de santé ; '
          'arrêtez en cas de douleur ou de malaise.',
          style: AppText.body(size: 12, color: AppColors.inkSoft),
        ),
      ],
    );
  }

  Widget _buildProgressAnalysis() {
    final backend = Backend.I;
    final user = backend.requireUser();
    final sessions = backend.trainingLog.historyOf(user.id);
    final summary = TrainingProgressSummary.fromSessions(
      sessions,
      backend.now(),
    );
    final muscle = _latestTrainedMuscle(sessions);
    return ListView(
      key: const Key('training_ai_progress'),
      padding: const EdgeInsets.all(Gap.m),
      children: [
        Text('Votre progression récente', style: AppText.title(size: 20)),
        const SizedBox(height: Gap.xs),
        Text(
          'Comparaison des 28 derniers jours avec les 28 jours précédents.',
          style: AppText.body(size: 14),
        ),
        const SizedBox(height: Gap.m),
        if (!summary.hasRecentSessions)
          const Card(
            child: ListTile(
              leading: Icon(Icons.fitness_center),
              title: Text('Pas encore de séance récente'),
              subtitle: Text(
                'Terminez une séance enregistrée pour pouvoir générer votre bilan.',
              ),
            ),
          )
        else ...[
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: Gap.s,
            crossAxisSpacing: Gap.s,
            childAspectRatio: 1.65,
            children: [
              _ProgressMetric(
                icon: Icons.event_available,
                label: 'Séances',
                recent: summary.recentSessions,
                previous: summary.previousSessions,
              ),
              _ProgressMetric(
                icon: Icons.timer_outlined,
                label: 'Minutes actives',
                recent: summary.recentMinutes,
                previous: summary.previousMinutes,
              ),
              _ProgressMetric(
                icon: Icons.fitness_center,
                label: 'Volume (kg × reps)',
                recent: summary.recentVolumeKg,
                previous: summary.previousVolumeKg,
                decimals: 0,
              ),
              _ProgressMetric(
                icon: Icons.emoji_events_outlined,
                label: 'Records',
                recent: summary.recentPersonalRecords,
                previous: summary.previousPersonalRecords,
              ),
            ],
          ),
          if (summary.exerciseProgress.isNotEmpty) ...[
            const SizedBox(height: Gap.m),
            Text('Charges par exercice', style: AppText.title(size: 17)),
            for (final exercise in summary.exerciseProgress.take(4))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.fitness_center),
                title: Text(exercise.name),
                subtitle: Text(
                  'Meilleure charge : ${exercise.bestLoadKg.toStringAsFixed(1)} kg · '
                  '1RM estimé : ${exercise.estimatedOneRmKg.toStringAsFixed(1)} kg'
                  '${exercise.changePercent == null ? '' : ' · ${exercise.changePercent! >= 0 ? '+' : ''}${exercise.changePercent!.toStringAsFixed(1)} % vs période précédente'}',
                ),
              ),
          ],
        ],
        const SizedBox(height: Gap.m),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(Gap.m),
            child: Text(
              'Confidentialité : la génération du bilan et des suggestions '
              'transmet uniquement les données d’entraînement nécessaires à '
              'des services externes. Aucun nom de compte ni e-mail n’est envoyé.',
            ),
          ),
        ),
        const SizedBox(height: Gap.s),
        FilledButton.icon(
          key: const Key('generate_training_ai_report'),
          onPressed: _generatingProgress || !summary.hasRecentSessions
              ? null
              : _generateProgressReport,
          icon: _generatingProgress
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome),
          label: Text(
            _generatingProgress ? 'Analyse en cours…' : 'Générer mon bilan IA',
          ),
        ),
        if (_progressError != null) ...[
          const SizedBox(height: Gap.s),
          Card(
            color: AppColors.redSoft,
            child: Padding(
              padding: const EdgeInsets.all(Gap.m),
              child: Text(_progressError!),
            ),
          ),
        ],
        if (_progressReport != null) ...[
          const SizedBox(height: Gap.m),
          Text('Bilan IA', style: AppText.title(size: 18)),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.m),
              child: SelectableText(_progressReport!),
            ),
          ),
        ],
        if (_generatingProgress) ...[
          const SizedBox(height: Gap.s),
          const LinearProgressIndicator(),
          const SizedBox(height: Gap.xs),
          const Text('Analyse de vos tendances et recherche d’exercices…'),
        ],
        if (muscle != null) ...[
          const SizedBox(height: Gap.m),
          Text(
            'Exercices suggérés pour ${muscle.label.toLowerCase()}',
            style: AppText.title(size: 18),
          ),
          if (_suggestionError != null) ...[
            const SizedBox(height: Gap.xs),
            Text(
              _suggestionError!,
              style: AppText.body(size: 13, color: AppColors.inkSoft),
            ),
          ],
          for (final exercise in _suggestedExercises)
            Card(
              child: ListTile(
                leading: const Icon(Icons.sports_gymnastics),
                title: Text(exercise.name),
                subtitle: Text(
                  [
                    if (exercise.equipment.isNotEmpty) exercise.equipment,
                    if (exercise.difficulty.isNotEmpty) exercise.difficulty,
                    if (exercise.instructions.isNotEmpty) exercise.instructions,
                  ].join(' · '),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          if (_suggestedExercises.isEmpty &&
              _suggestionError == null &&
              !_generatingProgress)
            const Text('Générez le bilan pour voir des exercices suggérés.'),
        ],
        const SizedBox(height: Gap.m),
        Text(
          'Bilan indicatif basé sur les séances enregistrées. Les estimations '
          'ne remplacent pas un avis médical ou celui d’un coach.',
          style: AppText.body(size: 12, color: AppColors.inkSoft),
        ),
      ],
    );
  }

  Widget _dailyLoadBar(int dayOffset, int maximum) {
    final day = DateUtils.dateOnly(
      DateTime.now().subtract(Duration(days: dayOffset)),
    );
    final load = _checkIns
        .where((entry) => DateUtils.isSameDay(entry.date, day))
        .fold<int>(0, (sum, entry) => sum + entry.load);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(_weekday(day))),
          Expanded(
            child: LinearProgressIndicator(
              value: maximum == 0 ? 0 : load / maximum,
              minHeight: 8,
            ),
          ),
          SizedBox(
            width: 58,
            child: Text('$load UA', textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }

  static String _weekday(DateTime date) {
    const days = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];
    return '${days[date.weekday - 1]} ${date.day}/${date.month}';
  }

  static String _formatDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';

  static String _formatDuration(double seconds) {
    final minutes = (seconds / 60).round();
    return '${minutes ~/ 60} h ${minutes % 60} min';
  }
}

class _ProgressMetric extends StatelessWidget {
  const _ProgressMetric({
    required this.icon,
    required this.label,
    required this.recent,
    required this.previous,
    this.decimals = 0,
  });

  final IconData icon;
  final String label;
  final num recent;
  final num previous;
  final int decimals;

  String _format(num value) => decimals == 0
      ? value.round().toString()
      : value.toStringAsFixed(decimals);

  String get _change {
    if (previous == 0) {
      return recent == 0 ? 'Stable' : 'Pas de référence précédente';
    }
    final delta = (recent - previous) / previous * 100;
    return '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(0)} %';
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(Gap.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: AppColors.navy, size: 20),
          const SizedBox(height: 4),
          Text(_format(recent), style: AppText.title(size: 18)),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.label(size: 11),
          ),
          Text(
            '$_change vs période précédente (${_format(previous)})',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.label(size: 10, color: AppColors.inkSoft),
          ),
        ],
      ),
    ),
  );
}
