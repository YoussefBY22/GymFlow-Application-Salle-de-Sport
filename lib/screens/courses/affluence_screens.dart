import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../models/gym_settings.dart';
import '../../services/affluence_service.dart';
import '../../services/backend.dart';
import '../../widgets/common.dart';
import '../../widgets/heatmap.dart';

Color crowdColor(Crowd c) => switch (c) {
  Crowd.calm => AppColors.successSoft,
  Crowd.moderate => AppColors.cream,
  Crowd.busy => AppColors.gold,
  Crowd.full => AppColors.redSoft,
};

/// Affluence : occupation actuelle, carte de chaleur, prévision d'un
/// créneau et créneaux conseillés (abonnés). Données agrégées seulement :
/// aucun nom n'est affiché ici.
class AffluenceScreen extends StatefulWidget {
  const AffluenceScreen({super.key});

  @override
  State<AffluenceScreen> createState() => _AffluenceScreenState();
}

class _AffluenceScreenState extends State<AffluenceScreen> {
  int _dayOffset = 0;
  int? _hour;

  Future<void> _settings() async {
    final b = Backend.I;
    final values = await showDialog<List<int>>(
      context: context,
      builder: (_) => _GymSettingsDialog(b.packs.settings),
    );
    if (values == null || !mounted) return;
    await runAction(
      context,
      () => b.gymEntry.saveSettings(
        capacity: values[0],
        stayMinutes: values[1],
        openHour: values[2],
        closeHour: values[3],
      ),
      success: 'Réglages enregistrés.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final me = b.auth.currentUser!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Affluence'),
        actions: [
          if (me.isAdmin)
            IconButton(
              key: const Key('gym_settings'),
              tooltip: 'Réglages de la salle',
              icon: const Icon(Icons.tune),
              onPressed: _settings,
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: b.bus,
        builder: (context, _) {
          final s = b.packs.settings;
          final now = b.now();
          // Profil séparé pendant le Ramadan (horaires et habitudes
          // différents) ; retour automatique au profil normal ensuite.
          final ramadan = b.ramadan.isActiveNow;
          final map = b.affluence.heatmap(ramadan: ramadan);
          final open = b.ramadan.openRanges(now);
          final cur = b.affluence.current();
          final hours = [for (var h = map.openHour; h < map.closeHour; h++) h];
          final day = DateTime(now.year, now.month, now.day + _dayOffset);
          final hour =
              _hour ??
              (_dayOffset == 0 && now.hour + 1 < s.closeHour
                  ? (now.hour + 1).clamp(s.openHour, s.closeHour - 1)
                  : 18.clamp(s.openHour, s.closeHour - 1));
          final f = b.affluence.forecast(
            DateTime(day.year, day.month, day.day, hour),
            map: map,
          );
          final suggestions = me.isMember
              ? b.affluence.suggestions(me.id)
              : const <SlotSuggestion>[];
          return ListView(
            padding: pagePadding(context, maxWidth: 760, bottom: Gap.xl),
            children: [
              GfCard(
                key: const Key('occupancy_now'),
                color: crowdColor(cur.crowd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.groups, color: AppColors.navy),
                        const SizedBox(width: Gap.s),
                        Expanded(
                          child: Text(
                            'En ce moment : ${cur.crowd.label.toLowerCase()}',
                            style: AppText.subtitle(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Gap.xs),
                    Text(
                      '${cur.expected.round()} / ${s.capacity} personnes '
                      '(estimation)',
                      key: const Key('occupancy_text'),
                      style: AppText.stat(size: 20),
                    ),
                    const SizedBox(height: Gap.xs),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: cur.rate.clamp(0, 1),
                        minHeight: 8,
                        color: AppColors.navy,
                        backgroundColor: AppColors.white,
                      ),
                    ),
                    const SizedBox(height: Gap.xs),
                    Text(
                      'Entrées scannées à l\'accueil et cours en cours. '
                      'Ouvert aujourd\'hui : ${open.map((r) => '${Fmt.time(r.$1)}–${r.$2.hour == 0 ? 'minuit' : Fmt.time(r.$2)}').join(' et ')}'
                      '${ramadan ? ' (horaires du Ramadan)' : ''}.',
                      style: AppText.label(size: 12),
                    ),
                  ],
                ),
              ),
              if (!me.isMember) ...[
                const SizedBox(height: Gap.s),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        key: const Key('open_checkin_scan'),
                        onPressed: () =>
                            Navigator.pushNamed(context, Routes.checkinScan),
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scanner les entrées'),
                      ),
                    ),
                  ],
                ),
              ],
              if (me.isMember) ...[
                const SizedBox(height: Gap.m),
                Text('Créneaux conseillés', style: AppText.title(size: 18)),
                Text(
                  'Les moments calmes proches de vos habitudes, sur les 7 '
                  'prochains jours.',
                  style: AppText.label(size: 12),
                ),
                const SizedBox(height: Gap.s),
                if (suggestions.isEmpty)
                  const GfCard(
                    child: InfoRow(
                      Icons.info_outline,
                      'Pas encore assez de données pour vous conseiller.',
                    ),
                  ),
                for (final (i, sg) in suggestions.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.s),
                    child: GfCard(
                      key: Key('suggestion_$i'),
                      onTap: sg.courseId == null
                          ? null
                          : () => Navigator.pushNamed(
                              context,
                              Routes.courseDetail,
                              arguments: sg.courseId,
                            ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_cap(Fmt.day(sg.forecast.start))} à '
                                  '${Fmt.time(sg.forecast.start)}',
                                  style: AppText.subtitle(size: 15),
                                ),
                                Text(
                                  AffluenceService.describe(sg.forecast),
                                  style: AppText.label(),
                                ),
                                Text(sg.reason, style: AppText.label(size: 12)),
                              ],
                            ),
                          ),
                          Pill(
                            sg.forecast.crowd.label,
                            color: crowdColor(sg.forecast.crowd),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: Gap.s),
                OutlinedButton.icon(
                  key: const Key('open_entry_qr'),
                  onPressed: () => Navigator.pushNamed(context, Routes.entryQr),
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('Mon QR d\'entrée'),
                ),
              ],
              const SizedBox(height: Gap.m),
              Text('Prévoir un créneau', style: AppText.title(size: 18)),
              const SizedBox(height: Gap.s),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var d = 0; d < 7; d++)
                      Padding(
                        padding: const EdgeInsets.only(right: Gap.xs),
                        child: ChoiceChip(
                          key: Key('forecast_day_$d'),
                          label: Text(
                            d == 0
                                ? 'Aujourd\'hui'
                                : Fmt.dayShort(now.add(Duration(days: d))),
                          ),
                          selected: _dayOffset == d,
                          onSelected: (_) => setState(() => _dayOffset = d),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Gap.s),
              DropdownButtonFormField<int>(
                key: const Key('forecast_hour'),
                initialValue: hour,
                decoration: const InputDecoration(labelText: 'Heure'),
                items: [
                  for (final h in hours)
                    DropdownMenuItem(
                      value: h,
                      child: Text('$h h – ${h + 1} h'),
                    ),
                ],
                onChanged: (h) => setState(() => _hour = h),
              ),
              const SizedBox(height: Gap.s),
              GfCard(
                color: crowdColor(f.crowd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${f.crowd.label} : ${AffluenceService.describe(f)}',
                      key: const Key('forecast_text'),
                      style: AppText.subtitle(size: 15),
                    ),
                    Text(
                      f.booked > 0
                          ? 'Dont ${Fmt.plural(f.booked, 'réservation')} '
                                'sur un cours de ce créneau.'
                          : 'Moyenne pondérée des 8 dernières semaines '
                                '(les plus récentes comptent davantage).',
                      style: AppText.label(size: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Gap.m),
              Text(
                ramadan
                    ? 'Fréquentation habituelle (profil Ramadan)'
                    : 'Fréquentation habituelle',
                style: AppText.title(size: 18),
              ),
              const SizedBox(height: Gap.s),
              GfCard(
                key: const Key('heatmap_card'),
                child: GfHeatmap(
                  firstHour: map.openHour,
                  lastHour: map.closeHour,
                  valueOf: map.at,
                  highlight: (now.weekday, now.hour),
                  onTap: (d, h) => showSnack(
                    context,
                    '${_cap(GfHeatmap.dayNames[d - 1])} $h h : ≈ '
                    '${Fmt.dec1(map.at(d, h))} personne(s) en moyenne.',
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// Réglages de la salle (admin) : les champs vivent avec le dialogue.
class _GymSettingsDialog extends StatefulWidget {
  const _GymSettingsDialog(this.settings);
  final GymSettings settings;

  @override
  State<_GymSettingsDialog> createState() => _GymSettingsDialogState();
}

class _GymSettingsDialogState extends State<_GymSettingsDialog> {
  late final _fields = [
    TextEditingController(text: '${widget.settings.capacity}'),
    TextEditingController(text: '${widget.settings.stayMinutes}'),
    TextEditingController(text: '${widget.settings.openHour}'),
    TextEditingController(text: '${widget.settings.closeHour}'),
  ];
  static const _labels = [
    ('Capacité (personnes)', 'set_capacity'),
    ('Sortie automatique (minutes)', 'set_stay'),
    ('Ouverture (heure)', 'set_open'),
    ('Fermeture (heure)', 'set_close'),
  ];

  @override
  void dispose() {
    for (final c in _fields) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Réglages de la salle'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _fields.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.s),
                child: TextField(
                  key: Key(_labels[i].$2),
                  controller: _fields[i],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: _labels[i].$1),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        ElevatedButton(
          key: const Key('set_save'),
          style: ElevatedButton.styleFrom(minimumSize: const Size(96, 44)),
          onPressed: () => Navigator.pop(context, [
            for (final c in _fields) int.tryParse(c.text.trim()) ?? -1,
          ]),
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

/// QR d'entrée personnel : régénéré chaque minute (une capture d'écran
/// partagée ne fonctionne pas).
class EntryQrScreen extends StatefulWidget {
  const EntryQrScreen({super.key});

  @override
  State<EntryQrScreen> createState() => _EntryQrScreenState();
}

class _EntryQrScreenState extends State<EntryQrScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final (code, until) = b.gymEntry.myEntryQr();
    final left = until.difference(b.now()).inSeconds.clamp(0, 60);
    final open = b.gymEntry.openFor(b.requireUser().id);
    return Scaffold(
      appBar: AppBar(title: const Text('Mon QR d\'entrée')),
      body: ListView(
        padding: pagePadding(context, maxWidth: 520),
        children: [
          Center(
            child: Container(
              key: const Key('entry_qr'),
              padding: const EdgeInsets.all(Gap.m),
              color: AppColors.white,
              child: QrImageView(data: code, size: 240),
            ),
          ),
          const SizedBox(height: Gap.s),
          Text(
            'Nouveau code dans $left s',
            key: const Key('entry_qr_timer'),
            textAlign: TextAlign.center,
            style: AppText.subtitle(),
          ),
          const SizedBox(height: Gap.m),
          GfCard(
            color: AppColors.cream,
            child: Column(
              children: [
                const InfoRow(
                  Icons.qr_code_scanner,
                  'Présentez ce code à l\'accueil en arrivant, et en partant '
                  'si vous le souhaitez.',
                ),
                InfoRow(
                  Icons.timer_outlined,
                  'Sans scan de sortie, vous êtes considéré comme parti après '
                  '${b.packs.settings.stayMinutes} minutes.',
                ),
                const InfoRow(
                  Icons.lock_outline,
                  'Le code change toutes les minutes : une capture d\'écran ne '
                  'fonctionne pas.',
                ),
              ],
            ),
          ),
          if (open != null) ...[
            const SizedBox(height: Gap.s),
            GfCard(
              color: AppColors.successSoft,
              child: InfoRow(
                Icons.check_circle,
                'Entrée enregistrée à ${Fmt.time(open.at)}.',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Accueil (admin ou coach) : scan des QR d'entrée ; un second scan
/// enregistre la sortie. Liste des personnes présentes.
class CheckInScanScreen extends StatefulWidget {
  const CheckInScanScreen({super.key, this.useCamera});

  /// Forcé dans les tests ; par défaut selon la plateforme.
  final bool? useCamera;

  bool get camera =>
      useCamera ??
      (kIsWeb ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  State<CheckInScanScreen> createState() => _CheckInScanScreenState();
}

class _CheckInScanScreenState extends State<CheckInScanScreen> {
  final _manual = TextEditingController();
  bool _busy = false;
  String? _last;

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  Future<void> _scan(String raw) async {
    // Une même image est détectée plusieurs fois par seconde.
    if (_busy || raw == _last) return;
    setState(() {
      _busy = true;
      _last = raw;
    });
    try {
      final r = await Backend.I.gymEntry.scan(raw);
      if (!mounted) return;
      await _result(
        ok: true,
        title: r.entered
            ? 'Entrée : ${r.member.fullName}'
            : 'Sortie : ${r.member.fullName}',
        message: r.entered
            ? 'Bonne séance ! Sortie automatique après '
                  '${Backend.I.packs.settings.stayMinutes} min sans scan.'
            : 'À bientôt !',
      );
    } catch (e) {
      if (!mounted) return;
      await _result(ok: false, title: 'Scan refusé', message: friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _result({
    required bool ok,
    required String title,
    required String message,
  }) => showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      icon: Icon(
        ok ? Icons.check_circle : Icons.error_outline,
        color: ok ? AppColors.success : AppColors.red,
        size: 48,
      ),
      title: Text(title, key: const Key('checkin_result')),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Scaffold(
      appBar: AppBar(title: const Text('Entrées à la salle')),
      body: ListenableBuilder(
        listenable: b.bus,
        builder: (context, _) {
          final present = b.gymEntry.present();
          return ListView(
            padding: pagePadding(context, maxWidth: 600),
            children: [
              if (widget.camera) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(Gap.radius),
                  child: SizedBox(
                    height: 300,
                    child: MobileScanner(
                      onDetect: (capture) {
                        final raw = capture.barcodes.firstOrNull?.rawValue;
                        if (raw != null) _scan(raw);
                      },
                      errorBuilder: (_, _) => const Center(
                        child: Padding(
                          padding: EdgeInsets.all(Gap.m),
                          child: Text(
                            'Caméra indisponible : autorisez-la ou saisissez '
                            'le code ci-dessous.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Gap.s),
                Text(
                  'Visez le QR affiché dans « Mon QR d\'entrée » de l\'abonné.',
                  textAlign: TextAlign.center,
                  style: AppText.label(),
                ),
                const SizedBox(height: Gap.m),
              ],
              TextField(
                key: const Key('checkin_manual'),
                controller: _manual,
                decoration: const InputDecoration(
                  hintText: 'Contenu du QR code (GFC1|…)',
                  prefixIcon: Icon(Icons.qr_code_2),
                ),
              ),
              const SizedBox(height: Gap.s),
              LoadingButton(
                key: const Key('checkin_submit'),
                label: 'Vérifier',
                icon: Icons.verified_outlined,
                loading: _busy,
                onPressed: () {
                  _last = null;
                  _scan(_manual.text);
                },
              ),
              const SizedBox(height: Gap.l),
              Text(
                'Présents (${present.length} / ${b.packs.settings.capacity})',
                key: const Key('present_count'),
                style: AppText.title(size: 18),
              ),
              const SizedBox(height: Gap.s),
              if (present.isEmpty)
                Text('Personne pour le moment.', style: AppText.label()),
              for (final (c, u) in present)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: GfAvatar(u),
                  title: Text(u.fullName),
                  subtitle: Text(
                    'Entrée à ${Fmt.time(c.at)} · ${c.source.label}',
                  ),
                  trailing: TextButton(
                    key: Key('exit_${u.id}'),
                    onPressed: () => runAction(
                      context,
                      () => b.gymEntry.manual(u.id),
                      success: 'Sortie enregistrée.',
                    ),
                    child: const Text('Sortie'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
