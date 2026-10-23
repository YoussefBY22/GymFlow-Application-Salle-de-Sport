import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../models/session_log.dart';
import '../../services/backend.dart';
import '../../services/outdoor_route_service.dart';
import '../../services/training_toolkit_service.dart';

class TrainingToolsScreen extends StatefulWidget {
  const TrainingToolsScreen({super.key});

  @override
  State<TrainingToolsScreen> createState() => _TrainingToolsScreenState();
}

class _TrainingToolsScreenState extends State<TrainingToolsScreen>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this);
  late final _store = TrainingToolkitStore(Backend.I.requireUser().id);
  final _routes = OutdoorRouteService();
  final _latitude = TextEditingController(text: '36.8347');
  final _longitude = TextEditingController(text: '10.2407');
  final _distance = TextEditingController(text: '5');
  bool _loading = true;
  bool _findingPlaces = false;
  String? _error;
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
        _error = 'Impossible de lire les données locales : $error';
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
        _error = 'Recherche OpenStreetMap impossible : $error';
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
      setState(() => _error = 'Calcul du parcours impossible : $error');
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
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Ouverture de Maps impossible : $error');
      }
    }
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
        setState(() => _error = 'Impossible d’enregistrer le cycle : $error');
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
        setState(
          () => _error = 'Impossible d’enregistrer le ressenti : $error',
        );
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
                    children: [_buildRoutes(), _buildPlan(), _buildRecovery()],
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
        Text('Espaces trouvés (${_places.length})', style: AppText.title(size: 17)),
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
          subtitle: const Text('Durée estimée par l’API'),
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
      const SizedBox(height: Gap.m),
      Text(
        'Les lieux viennent d’OpenStreetMap. Le calcul piéton et le dénivelé '
        'utilisent OpenRouteService. Vérifiez le parcours et les conditions '
        'sur place avant de partir.',
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
                Text(
                  assessment.label,
                  style: AppText.title(size: 17),
                ),
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
