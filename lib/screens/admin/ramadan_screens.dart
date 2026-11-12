import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../models/ramadan.dart';
import '../../services/backend.dart';
import '../../services/ramadan_service.dart';
import '../../widgets/common.dart';
import '../../widgets/heatmap.dart';

/// « 09:00–15:00 et 19:00–minuit ».
String _ranges(List<OpenRange> r) => r
    .map(
      (x) =>
          '${Fmt.time(x.$1)}–'
          '${x.$2.hour == 0 && x.$2.minute == 0 ? 'minuit' : Fmt.time(x.$2)}',
    )
    .join(' et ');

/// Mode Ramadan (super admin) : période (pré-remplie par Aladhan, toujours
/// confirmée par l'admin), horaires, rupture du jeûne et cours signalés.
class RamadanAdminScreen extends StatefulWidget {
  const RamadanAdminScreen({super.key});

  @override
  State<RamadanAdminScreen> createState() => _RamadanAdminScreenState();
}

class _RamadanAdminScreenState extends State<RamadanAdminScreen> {
  DateTime? _start;
  DateTime? _end;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final p = Backend.I.ramadan.upcoming;
    if (p != null) unawaited(_prefetch(p));
  }

  /// Horaires de prière de la période (cache ; repli estimé hors ligne).
  Future<void> _prefetch(RamadanPeriod p) async {
    await Backend.I.aladhan.ensure(p.start, p.end);
    if (mounted) setState(() {});
  }

  Future<void> _prefill() async {
    setState(() => _busy = true);
    await runAction(context, () async {
      final p = await Backend.I.ramadan.prefill();
      _start = p.start;
      _end = p.end;
      unawaited(_prefetch(p));
    }, success: 'Dates proposées par Aladhan : à confirmer.');
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pick(bool start, RamadanPeriod p) async {
    final initial = (start ? _start : _end) ?? (start ? p.start : p.end);
    final d = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: initial.subtract(const Duration(days: 10)),
      lastDate: initial.add(const Duration(days: 10)),
    );
    if (d == null) return;
    setState(() => start ? _start = d : _end = d);
  }

  Future<void> _confirm(RamadanPeriod p) async {
    final start = _start ?? p.start;
    final end = _end ?? p.end;
    final ok = await confirm(
      context,
      title: 'Confirmer le Ramadan ${p.hijriYear} ?',
      message:
          'Du ${Fmt.date(start)} au ${Fmt.date(end)}. Confirmez seulement '
          'après l\'annonce officielle (observation du croissant).',
      confirmLabel: 'Confirmer',
    );
    if (!ok || !mounted) return;
    await runAction(
      context,
      () => Backend.I.ramadan.confirm(
        hijriYear: p.hijriYear,
        start: start,
        end: end,
      ),
      success: 'Période confirmée.',
    );
  }

  Future<void> _editHours() async {
    final b = Backend.I;
    final h = b.ramadan.hours;
    final v = await showDialog<List<int>>(
      context: context,
      builder: (_) => NumbersDialog(
        title: 'Horaires du Ramadan',
        fields: [
          ('Ouverture en journée (h)', 'rh_day_open', h.dayOpen),
          ('Fermeture en journée (h)', 'rh_day_close', h.dayClose),
          ('Réouverture après le Maghrib (min)', 'rh_offset', h.eveningOffset),
          ('Fermeture le soir (h, 24 = minuit)', 'rh_close', h.eveningClose),
          (
            'Créneau « après la rupture » (min)',
            'rh_iftar',
            h.afterIftarOffset,
          ),
          ('Créneau tardif (h)', 'rh_late', h.lateSlotHour),
        ],
      ),
    );
    if (v == null || !mounted) return;
    await runAction(
      context,
      () => b.ramadan.saveHours(
        RamadanHours(
          dayOpen: v[0],
          dayClose: v[1],
          eveningOffset: v[2],
          eveningClose: v[3],
          afterIftarOffset: v[4],
          lateSlotHour: v[5],
        ),
      ),
      success: 'Horaires enregistrés.',
    );
  }

  Future<void> _shift(RamadanConflict c) async {
    final b = Backend.I;
    final n =
        b.courseService.confirmedCount(c.course.id) +
        b.courseService.waitlistCount(c.course.id);
    final ok = await confirm(
      context,
      title: 'Décaler « ${c.course.title} » ?',
      message:
          '${Fmt.dateTime(c.course.startAt!)} → ${Fmt.dateTime(c.proposal!)}. '
          '${n == 0 ? 'Aucun inscrit pour le moment.' : '${Fmt.plural(n, 'inscrit')} prévenu(s) du nouvel horaire.'}',
      confirmLabel: 'Décaler',
    );
    if (!ok || !mounted) return;
    await runAction(
      context,
      () => b.ramadan.applyShift(c.course.id, c.proposal!),
      success: 'Cours décalé, inscrits prévenus.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mode Ramadan'),
        actions: [
          IconButton(
            key: const Key('ramadan_hours'),
            tooltip: 'Horaires du Ramadan',
            icon: const Icon(Icons.schedule),
            onPressed: _editHours,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: b.bus,
        builder: (context, _) {
          final r = b.ramadan;
          final next = r.upcoming;
          final past = r.periods.where((p) => p != next).toList().reversed;
          final h = r.hours;
          final conflicts = next != null && next.confirmed
              ? r.conflicts(next)
              : const <RamadanConflict>[];
          return ListView(
            padding: pagePadding(context, maxWidth: 760, bottom: Gap.xl),
            children: [
              GfCard(
                color: r.isActiveNow ? AppColors.gold : AppColors.cream,
                child: InfoRow(
                  Icons.nightlight_round,
                  r.isActiveNow
                      ? 'Le mode Ramadan est actif aujourd\'hui. Il se '
                            'désactive tout seul après la période.'
                      : 'Planning normal. Le mode Ramadan s\'active seul '
                            'pendant une période confirmée.',
                ),
              ),
              const SizedBox(height: Gap.m),
              Text('Prochain Ramadan', style: AppText.title(size: 18)),
              const SizedBox(height: Gap.s),
              if (next == null)
                const GfCard(
                  child: InfoRow(
                    Icons.event_note,
                    'Aucune période à venir. Pré-remplissez les dates avec '
                    'Aladhan, puis confirmez-les après l\'annonce officielle.',
                  ),
                )
              else
                GfCard(
                  key: const Key('ramadan_next'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Ramadan ${next.hijriYear}',
                              style: AppText.subtitle(),
                            ),
                          ),
                          Pill(
                            next.confirmed ? 'Confirmé' : 'À confirmer',
                            color: next.confirmed
                                ? AppColors.successSoft
                                : AppColors.gold,
                          ),
                        ],
                      ),
                      Text(next.source, style: AppText.label(size: 12)),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.event),
                        title: const Text('Premier jour'),
                        subtitle: Text(Fmt.day(_start ?? next.start)),
                        onTap: () => _pick(true, next),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.event_available),
                        title: const Text('Dernier jour'),
                        subtitle: Text(Fmt.day(_end ?? next.end)),
                        onTap: () => _pick(false, next),
                      ),
                      Text(
                        'En Tunisie, le début est annoncé par le Mufti selon '
                        'l\'observation du croissant : il peut différer d\'un '
                        'jour du calcul d\'Aladhan.',
                        style: AppText.label(size: 12),
                      ),
                      const SizedBox(height: Gap.s),
                      ElevatedButton.icon(
                        key: const Key('ramadan_confirm'),
                        onPressed: () => _confirm(next),
                        icon: const Icon(Icons.verified),
                        label: const Text('Confirmer les dates'),
                      ),
                      const Divider(),
                      _maghribRow(next.start, 'Premier jour'),
                    ],
                  ),
                ),
              const SizedBox(height: Gap.s),
              OutlinedButton.icon(
                key: const Key('ramadan_prefill'),
                onPressed: _busy ? null : _prefill,
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Pré-remplir avec Aladhan'),
              ),
              const SizedBox(height: Gap.m),
              Text(
                'Horaires pendant le Ramadan',
                style: AppText.title(size: 18),
              ),
              const SizedBox(height: Gap.s),
              GfCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InfoRow(
                      Icons.wb_sunny_outlined,
                      'Journée : ${h.dayOpen} h – ${h.dayClose} h '
                      '(intensité conseillée réduite).',
                    ),
                    InfoRow(
                      Icons.nights_stay_outlined,
                      'Soir : ${h.eveningOffset} min après le Maghrib, '
                      'jusqu\'à ${h.eveningClose == 24 ? 'minuit' : '${h.eveningClose % 24} h'}.',
                    ),
                    InfoRow(
                      Icons.view_agenda_outlined,
                      'Modèles : après la rupture du jeûne (Maghrib + '
                      '${h.afterIftarOffset} min) et créneau tardif '
                      '(${h.lateSlotHour} h).',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Gap.m),
              Text(
                'Cours à signaler (${conflicts.length})',
                style: AppText.title(size: 18),
              ),
              const SizedBox(height: Gap.xs),
              Text(
                'Rien n\'est déplacé sans votre validation ; les inscrits '
                'sont prévenus de tout changement.',
                style: AppText.label(size: 12),
              ),
              const SizedBox(height: Gap.s),
              if (next == null || !next.confirmed)
                Text(
                  'Confirmez la période pour vérifier le planning.',
                  style: AppText.label(),
                )
              else if (conflicts.isEmpty)
                Text('Aucun cours en conflit.', style: AppText.label()),
              for (final c in conflicts)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.s),
                  child: ConflictCard(
                    conflict: c,
                    onShift: c.proposal == null ? null : () => _shift(c),
                    onKeep: () => runAction(
                      context,
                      () => b.ramadan.keep(c.course.id),
                      success: 'Horaire conservé.',
                    ),
                  ),
                ),
              const SizedBox(height: Gap.m),
              OutlinedButton.icon(
                key: const Key('ramadan_preview'),
                onPressed: () =>
                    Navigator.pushNamed(context, Routes.ramadanPreview),
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Aperçu du mode Ramadan'),
              ),
              if (past.isNotEmpty) ...[
                const SizedBox(height: Gap.m),
                Text('Périodes enregistrées', style: AppText.title(size: 18)),
                for (final p in past)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.history),
                    title: Text(
                      'Ramadan ${p.hijriYear} : ${Fmt.date(p.start)} – '
                      '${Fmt.date(p.end)}',
                    ),
                    subtitle: Text(
                      '${p.confirmed ? 'Confirmé' : 'Non confirmé'} · ${p.source}',
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _maghribRow(DateTime day, String label) {
    final (m, src) = Backend.I.ramadan.maghrib(day);
    return InfoRow(
      Icons.wb_twilight,
      '$label : rupture du jeûne (Maghrib, Tunis) à ${Fmt.time(m)} · '
      '${src.label}',
    );
  }
}

/// Cours signalé : motifs et décalage proposé.
class ConflictCard extends StatelessWidget {
  const ConflictCard({
    super.key,
    required this.conflict,
    this.onShift,
    this.onKeep,
  });

  final RamadanConflict conflict;

  /// Absents en aperçu (lecture seule).
  final VoidCallback? onShift;
  final VoidCallback? onKeep;

  @override
  Widget build(BuildContext context) {
    final c = conflict;
    return GfCard(
      key: Key('conflict_${c.course.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.course.title, style: AppText.subtitle()),
          Text(
            '${Fmt.dateTime(c.course.startAt!)} · ${c.course.room}',
            style: AppText.label(),
          ),
          for (final r in c.reasons) InfoRow(Icons.warning_amber, r),
          Text(
            c.proposal == null
                ? 'Aucun créneau libre proposé : à replanifier.'
                : 'Proposé : ${Fmt.dateTime(c.proposal!)}',
            style: AppText.subtitle(size: 14, color: AppColors.success),
          ),
          if (onShift != null || onKeep != null) ...[
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.s,
              children: [
                if (onShift != null)
                  ElevatedButton(
                    key: Key('shift_${c.course.id}'),
                    onPressed: onShift,
                    child: Text('Décaler à ${Fmt.time(c.proposal!)}'),
                  ),
                if (onKeep != null)
                  TextButton(
                    key: Key('keep_${c.course.id}'),
                    onPressed: onKeep,
                    child: const Text('Garder l\'horaire'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Aperçu du mode Ramadan : « si le Ramadan commençait aujourd'hui ».
/// Bandeau toujours visible, AUCUNE donnée enregistrée, aucune
/// notification ni e-mail ; sortie en un clic.
class RamadanPreviewScreen extends StatefulWidget {
  const RamadanPreviewScreen({super.key});

  @override
  State<RamadanPreviewScreen> createState() => _RamadanPreviewScreenState();
}

class _RamadanPreviewScreenState extends State<RamadanPreviewScreen> {
  int _day = 0;

  @override
  void initState() {
    super.initState();
    Backend.I.ramadan.previewActive = true;
  }

  @override
  void dispose() {
    Backend.I.ramadan.previewActive = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final r = b.ramadan;
    final period = r.previewPeriod();
    final day = period.start.add(Duration(days: _day));
    final (m, src) = r.maghrib(day);
    final slots = r.slots(day);
    final courses = b.courses.where(
      (c) =>
          !c.cancelled &&
          c.startAt != null &&
          DateTime(c.startAt!.year, c.startAt!.month, c.startAt!.day) == day,
    )..sort((a, b) => a.startAt!.compareTo(b.startAt!));
    final conflicts = r.previewConflicts();
    final map = b.affluence.heatmap(ramadan: true);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aperçu du mode Ramadan'),
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          Material(
            key: const Key('preview_banner'),
            color: AppColors.gold,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.s, Gap.s),
              child: Row(
                children: [
                  const Icon(Icons.visibility, color: AppColors.navy),
                  const SizedBox(width: Gap.s),
                  Expanded(
                    child: Text(
                      'APERÇU : Ramadan simulé du ${Fmt.date(period.start)} '
                      'au ${Fmt.date(period.end)}. Rien n\'est enregistré, '
                      'aucune notification ni aucun e-mail.',
                      style: AppText.label(size: 12, color: AppColors.navy),
                    ),
                  ),
                  TextButton(
                    key: const Key('preview_exit'),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Quitter'),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: pagePadding(context, maxWidth: 760, bottom: Gap.xl),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var d = 0; d < 7; d++)
                        Padding(
                          padding: const EdgeInsets.only(right: Gap.xs),
                          child: ChoiceChip(
                            key: Key('preview_day_$d'),
                            label: Text(
                              Fmt.dayShort(period.start.add(Duration(days: d))),
                            ),
                            selected: _day == d,
                            onSelected: (_) => setState(() => _day = d),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Gap.s),
                GfCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(Fmt.day(day), style: AppText.subtitle()),
                      InfoRow(
                        Icons.wb_twilight,
                        'Rupture du jeûne (Maghrib) : ${Fmt.time(m)} · '
                        '${src.label}',
                      ),
                      InfoRow(
                        Icons.door_front_door_outlined,
                        'Ouvert : ${_ranges(r.openRanges(day, ramadan: true))}',
                      ),
                      for (final (label, at) in slots)
                        InfoRow(
                          Icons.view_agenda_outlined,
                          '$label : ${Fmt.time(at)}',
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Gap.s),
                Text('Cours de ce jour', style: AppText.title(size: 18)),
                if (courses.isEmpty)
                  Text('Aucun cours programmé.', style: AppText.label()),
                for (final c in courses)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(c.category.icon, color: AppColors.red),
                    title: Text('${Fmt.time(c.startAt!)} · ${c.title}'),
                    subtitle: r.reducedIntensity(c, ramadan: true)
                        ? const Text('Intensité conseillée réduite (à jeun)')
                        : null,
                  ),
                const SizedBox(height: Gap.m),
                Text(
                  'Cours qui seraient signalés (${conflicts.length})',
                  style: AppText.title(size: 18),
                ),
                const SizedBox(height: Gap.s),
                for (final c in conflicts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.s),
                    child: ConflictCard(conflict: c),
                  ),
                const SizedBox(height: Gap.m),
                Text(
                  'Affluence pendant le Ramadan',
                  style: AppText.title(size: 18),
                ),
                Text(
                  'Profil séparé, calculé sur les Ramadans passés.',
                  style: AppText.label(size: 12),
                ),
                const SizedBox(height: Gap.s),
                GfCard(
                  child: GfHeatmap(
                    firstHour: map.openHour,
                    lastHour: map.closeHour,
                    valueOf: map.at,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Saisie de plusieurs nombres entiers (les champs vivent avec le
/// dialogue).
class NumbersDialog extends StatefulWidget {
  const NumbersDialog({super.key, required this.title, required this.fields});
  final String title;
  final List<(String, String, int)> fields;

  @override
  State<NumbersDialog> createState() => _NumbersDialogState();
}

class _NumbersDialogState extends State<NumbersDialog> {
  late final _c = [
    for (final f in widget.fields) TextEditingController(text: '${f.$3}'),
  ];

  @override
  void dispose() {
    for (final c in _c) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _c.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.s),
                child: TextField(
                  key: Key(widget.fields[i].$2),
                  controller: _c[i],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: widget.fields[i].$1),
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
          key: const Key('numbers_save'),
          style: ElevatedButton.styleFrom(minimumSize: const Size(96, 44)),
          onPressed: () => Navigator.pop(context, [
            for (final c in _c) int.tryParse(c.text.trim()) ?? -1,
          ]),
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
