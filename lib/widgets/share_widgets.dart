import 'dart:async';

import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../models/chat.dart';
import '../models/friends.dart';
import '../services/backend.dart';
import '../services/friends_service.dart';
import 'common.dart';
import 'friend_avatar.dart';

const _weekdays = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];

IconData _iconOf(String type) => switch (type) {
  'session' => Icons.history,
  'workout' => Icons.fitness_center,
  'exercise' => Icons.sports_gymnastics,
  'program' => Icons.calendar_view_week,
  _ => Icons.share,
};

/// Choisit un ami puis lui envoie l'élément dans une discussion.
Future<void> shareWithFriend(
  BuildContext context,
  ShareCard Function() build,
) async {
  final b = Backend.I;
  if (b.friends.status != FriendsStatus.connected || b.friends.friends.isEmpty) {
    showSnack(
      context,
      b.friends.status != FriendsStatus.connected
          ? 'Activez la fonction Amis (menu « Mes amis ») pour partager.'
          : 'Ajoutez d\'abord un ami dans « Mes amis ».',
    );
    return;
  }
  final friend = await showModalBottomSheet<Friend>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Text('Envoyer à…', style: AppText.title(size: 18)),
          ),
          for (final f in b.friends.friends)
            ListTile(
              key: Key('share_to_${f.id}'),
              leading: FriendAvatar(name: f.name, url: f.avatarUrl),
              title: Text(f.name),
              onTap: () => Navigator.pop(ctx, f),
            ),
        ],
      ),
    ),
  );
  if (friend == null || !context.mounted) return;
  final card = build();
  await runAction(
    context,
    () => b.chat.send(friend.id, card.encode(), kind: MessageKind.share),
    success: '${card.typeLabel} envoyé à ${friend.name}.',
  );
}

/// Bouton « Envoyer à un ami » pour la barre d'une page de détail. Absent
/// quand la fonction Amis n'est pas disponible.
class ShareButton extends StatelessWidget {
  const ShareButton({super.key, required this.card, this.onDark = false});

  /// Construit l'élément à partager (appelé seulement à l'envoi).
  final ShareCard Function() card;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    if (!b.friends.available || !(b.auth.currentUser?.isMember ?? false)) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: const Key('share_button'),
      tooltip: 'Envoyer à un ami',
      color: onDark ? AppColors.white : AppColors.heading,
      onPressed: () => shareWithFriend(context, card),
      icon: const Icon(Icons.send_outlined),
    );
  }
}

/// Dans une discussion : choisir ce qu'on partage (séance, workout, exercice,
/// programme) puis l'envoyer à [friendId].
Future<void> showSharePicker(BuildContext context, String friendId) async {
  final b = Backend.I;
  final type = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Wrap(
        children: [
          Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Text('Partager…', style: AppText.title(size: 18)),
          ),
          for (final t in const [
            ('session', 'Une séance réalisée'),
            ('workout', 'Un workout'),
            ('exercise', 'Un exercice'),
            ('program', 'Un programme'),
          ])
            ListTile(
              key: Key('share_type_${t.$1}'),
              leading: Icon(_iconOf(t.$1), color: AppColors.heading),
              title: Text(t.$2),
              onTap: () => Navigator.pop(ctx, t.$1),
            ),
        ],
      ),
    ),
  );
  if (type == null || !context.mounted) return;

  final options = <(String id, String title, String subtitle, ShareCard Function())>[
    if (type == 'session')
      for (final s in b.share.mySessions())
        (
          s.id,
          s.title,
          '${Fmt.date(s.startedAt)} · ${s.durationSec ~/ 60} min',
          () => b.share.sessionCard(s),
        ),
    if (type == 'workout')
      for (final w in b.share.workouts())
        (w.id, w.name, w.level.label, () => b.share.workoutCard(w)),
    if (type == 'exercise')
      for (final e in b.share.exercises())
        (e.id, e.name, e.primaryMuscle.label, () => b.share.exerciseCard(e)),
    if (type == 'program')
      for (final p in b.share.programs())
        (p.id, p.name, '${p.weeks} semaines', () => b.share.programCard(p)),
  ];
  if (options.isEmpty) {
    showSnack(context, 'Rien à partager dans cette catégorie pour le moment.');
    return;
  }
  final picked = await showModalBottomSheet<ShareCard Function()>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        children: [
          Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Text('Choisir', style: AppText.title(size: 18)),
          ),
          for (final o in options)
            ListTile(
              key: Key('share_pick_${o.$1}'),
              leading: Icon(_iconOf(type), color: AppColors.heading),
              title: Text(o.$2, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(o.$3),
              onTap: () => Navigator.pop(ctx, o.$4),
            ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final card = picked();
  await runAction(
    context,
    () => b.chat.send(friendId, card.encode(), kind: MessageKind.share),
    success: '${card.typeLabel} envoyé.',
  );
}

/// Carte d'un élément partagé, dans une bulle de discussion.
class ShareCardBubble extends StatelessWidget {
  const ShareCardBubble({super.key, required this.card, required this.mine});

  final ShareCard card;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final fg = mine ? AppColors.white : AppColors.ink;
    final soft = mine ? AppColors.navyMuted : AppColors.inkSoft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_iconOf(card.type), size: 16, color: soft),
            const SizedBox(width: 6),
            Text(card.typeLabel.toUpperCase(), style: AppText.label(size: 11, color: soft)),
          ],
        ),
        const SizedBox(height: 4),
        Text(card.title, style: AppText.subtitle(size: 15, color: fg)),
        if (card.subtitle.isNotEmpty)
          Text(card.subtitle, style: AppText.label(size: 12, color: soft)),
        const SizedBox(height: Gap.s),
        Wrap(
          spacing: Gap.s,
          children: [
            OutlinedButton(
              key: const Key('share_view'),
              style: OutlinedButton.styleFrom(
                foregroundColor: fg,
                side: BorderSide(color: soft),
                minimumSize: const Size(0, 36),
              ),
              onPressed: () => showShareDetail(context, card, mine: mine),
              child: const Text('Voir'),
            ),
            if (!mine && Backend.I.share.canSave(card))
              ElevatedButton(
                key: const Key('share_save'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(0, 36)),
                onPressed: () => runAction(
                  context,
                  () async {
                    final msg = await Backend.I.share.save(card);
                    if (context.mounted) showSnack(context, msg);
                  },
                ),
                child: const Text('Enregistrer chez moi'),
              ),
          ],
        ),
      ],
    );
  }
}

/// Aperçu en lecture seule d'un élément partagé.
Future<void> showShareDetail(
  BuildContext context,
  ShareCard card, {
  required bool mine,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => ListView(
        key: const Key('share_detail'),
        controller: scroll,
        padding: const EdgeInsets.all(Gap.m),
        children: [
          Text(card.typeLabel.toUpperCase(), style: AppText.label(size: 12)),
          Text(card.title, style: AppText.title(size: 22)),
          if (card.subtitle.isNotEmpty)
            Text(card.subtitle, style: AppText.label()),
          const SizedBox(height: Gap.m),
          ..._detail(card),
          if (!mine && Backend.I.share.canSave(card)) ...[
            const SizedBox(height: Gap.m),
            ElevatedButton.icon(
              key: const Key('share_save_detail'),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Enregistrer chez moi'),
              onPressed: () => runAction(ctx, () async {
                final msg = await Backend.I.share.save(card);
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                  showSnack(context, msg);
                }
              }),
            ),
            const SizedBox(height: Gap.xs),
            Text(
              'Copie privée, sans photo ni vidéo.',
              style: AppText.label(size: 12),
            ),
          ],
        ],
      ),
    ),
  );
}

List<Widget> _detail(ShareCard c) {
  final d = c.data;
  switch (c.type) {
    case 'session':
      return _sessionDetail(d);
    case 'workout':
      return _workoutDetail(d);
    case 'exercise':
      return _exerciseDetail(d);
    case 'program':
      return _programDetail(d);
    default:
      return const [Text('Contenu non pris en charge.')];
  }
}

Widget _line(String text, {bool bold = false, double top = 4}) => Padding(
  padding: EdgeInsets.only(top: top),
  child: Text(
    text,
    style: bold ? AppText.subtitle(size: 15) : AppText.body(size: 14),
  ),
);

List<Widget> _sessionDetail(Map<String, dynamic> d) {
  final byExercise = <String, List<Map>>{};
  for (final s in (d['sets'] as List? ?? const [])) {
    final m = s as Map;
    byExercise.putIfAbsent('${m['n']}', () => []).add(m);
  }
  return [
    _line(
      '${(d['durationSec'] as num? ?? 0) ~/ 60} min · '
      '${d['exerciseCount'] ?? byExercise.length} exercices · '
      '${d['prCount'] ?? 0} record(s)',
    ),
    if (d['calories'] != null) _line('${d['calories']} kcal'),
    for (final e in byExercise.entries) ...[
      _line(e.key, bold: true, top: Gap.m),
      for (final s in e.value)
        _line(
          'Série ${s['i']} · ${s['d'] != null && (s['r'] ?? 0) <= 1 ? '${s['d']} s' : '${s['r']} reps'}'
          '${(s['k'] as num? ?? 0) > 0 ? ' · ${s['k']} kg' : ''}',
        ),
    ],
  ];
}

List<Widget> _items(Map<String, dynamic> w) {
  final exercises = (w['exercises'] as List? ?? const []);
  return [
    for (final raw in (w['items'] as List? ?? const []))
      Builder(
        builder: (_) {
          final i = raw as Map;
          final idx = (i['e'] as num?)?.toInt() ?? 0;
          final name = idx >= 0 && idx < exercises.length
              ? '${(exercises[idx] as Map)['name']}'
              : 'Exercice';
          final target = (i['reps'] as num?) != null && (i['reps'] as num) > 0
              ? '${i['reps']} reps'
              : '${i['dur']} s';
          return _line(
            '$name · ${i['sets']} × $target · repos ${i['rest']} s',
          );
        },
      ),
  ];
}

List<Widget> _workoutDetail(Map<String, dynamic> d) => [
  if ('${d['description'] ?? ''}'.isNotEmpty) _line('${d['description']}'),
  _line('Exercices', bold: true, top: Gap.m),
  ..._items(d),
];

List<Widget> _exerciseDetail(Map<String, dynamic> d) {
  final steps = (d['steps'] as List? ?? const []);
  final mistakes = (d['mistakes'] as List? ?? const []);
  return [
    if ('${d['description'] ?? ''}'.isNotEmpty) _line('${d['description']}'),
    if (steps.isNotEmpty) ...[
      _line('Étapes', bold: true, top: Gap.m),
      for (var i = 0; i < steps.length; i++) _line('${i + 1}. ${steps[i]}'),
    ],
    if (mistakes.isNotEmpty) ...[
      _line('Erreurs fréquentes', bold: true, top: Gap.m),
      for (final m in mistakes) _line('• $m'),
    ],
    if ('${d['breathing'] ?? ''}'.isNotEmpty) ...[
      _line('Respiration', bold: true, top: Gap.m),
      _line('${d['breathing']}'),
    ],
  ];
}

List<Widget> _programDetail(Map<String, dynamic> d) => [
  if ('${d['description'] ?? ''}'.isNotEmpty) _line('${d['description']}'),
  _line('${d['weeks']} semaines', top: Gap.s),
  for (final raw in (d['days'] as List? ?? const [])) ...[
    () {
      final day = raw as Map;
      final wd = ((day['weekday'] as num?)?.toInt() ?? 1).clamp(1, 7);
      final w = Map<String, dynamic>.from(day['workout'] as Map);
      return _line('${_weekdays[wd - 1]} · ${w['name']}', bold: true, top: Gap.m);
    }(),
    ..._items(Map<String, dynamic>.from((raw as Map)['workout'] as Map)),
  ],
];
