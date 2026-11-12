import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../models/risk.dart';
import '../../services/backend.dart';
import '../../services/session_pack_service.dart';
import '../../widgets/animations.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';
import '../../widgets/pickers.dart';

Color riskColor(RiskLevel l) => switch (l) {
  RiskLevel.high => AppColors.redSoft,
  RiskLevel.medium => AppColors.gold,
  RiskLevel.low => AppColors.successSoft,
};

IconData riskActionIcon(RiskActionKind k) => switch (k) {
  RiskActionKind.message => Icons.mail_outline,
  RiskActionKind.trial => Icons.card_giftcard,
  RiskActionKind.call => Icons.phone_in_talk,
};

/// « Abonnés à risque » (coachs et admin) : liste triée par score et
/// efficacité des actions menées. Jamais visible par les abonnés.
class RiskListScreen extends StatelessWidget {
  const RiskListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Scaffold(
      appBar: AppBar(title: const Text('Abonnés à risque')),
      body: ListenableBuilder(
        listenable: b.bus,
        builder: (context, _) {
          final list = b.churnRisk.ranking();
          final eff = b.churnRisk.effectiveness();
          int count(RiskLevel l) => list.where((a) => a.level == l).length;
          return ListView(
            padding: pagePadding(context, maxWidth: 900, bottom: Gap.xl),
            children: [
              Row(
                children: [
                  for (final l in RiskLevel.values.reversed)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: Gap.xs),
                        child: GfCard(
                          color: riskColor(l),
                          padding: const EdgeInsets.all(Gap.s),
                          child: Column(
                            children: [
                              Text(
                                '${count(l)}',
                                key: Key('risk_count_${l.name}'),
                                style: AppText.stat(),
                              ),
                              Text(l.label, style: AppText.label()),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Gap.s),
              _Effectiveness(eff),
              const SizedBox(height: Gap.s),
              Text(
                'Score de 0 à 100, calculé à partir des venues, réservations '
                'et notes. Aucune décision automatique : vous choisissez '
                'l\'action.',
                style: AppText.label(size: 12),
              ),
              const SizedBox(height: Gap.s),
              if (list.isEmpty)
                const EmptyState(
                  icon: Icons.people_outline,
                  title: 'Aucun abonné à suivre',
                  message:
                      'Les abonnés qui ont suivi vos cours ces 11 dernières '
                      'semaines apparaîtront ici.',
                ),
              for (final (i, a) in list.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.s),
                  child: FadeSlideIn(index: i, child: _RiskTile(a)),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Effectiveness extends StatelessWidget {
  const _Effectiveness(this.eff);
  final Map<RiskActionKind, (int, int, int)> eff;

  @override
  Widget build(BuildContext context) {
    return GfCard(
      key: const Key('risk_effectiveness'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Efficacité des actions', style: AppText.subtitle()),
          Text(
            'Revenu = au moins une venue dans les 14 jours suivants.',
            style: AppText.label(size: 12),
          ),
          for (final e in eff.entries)
            InfoRow(
              riskActionIcon(e.key),
              '${e.key.label} : ${Fmt.plural(e.value.$1, 'action')}'
              '${e.value.$2 + e.value.$3 == 0 ? '' : ' · ${e.value.$2} revenu(s) sur ${e.value.$2 + e.value.$3} '
                        '(${(e.value.$2 * 100 / (e.value.$2 + e.value.$3)).round()} %)'}',
            ),
        ],
      ),
    );
  }
}

class _RiskTile extends StatelessWidget {
  const _RiskTile(this.a);
  final RiskAssessment a;

  @override
  Widget build(BuildContext context) {
    final u = Backend.I.users.byId(a.userId);
    final top = a.active.firstOrNull;
    return GfCard(
      key: Key('risk_${a.userId}'),
      onTap: () =>
          Navigator.pushNamed(context, Routes.riskMember, arguments: a.userId),
      child: Row(
        children: [
          GfAvatar(u),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(u?.fullName ?? '', style: AppText.subtitle()),
                Text(
                  top == null ? 'Aucun signal' : top.label,
                  style: AppText.label(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${a.score}', style: AppText.stat(size: 20)),
              Pill(a.level.label, color: riskColor(a.level)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Détail d'un abonné : facteurs, fréquentation, actions et suivi.
class RiskDetailScreen extends StatefulWidget {
  const RiskDetailScreen({super.key, required this.memberId});
  final String memberId;

  @override
  State<RiskDetailScreen> createState() => _RiskDetailScreenState();
}

class _RiskDetailScreenState extends State<RiskDetailScreen> {
  bool _busy = false;

  Future<void> _run(RiskActionKind kind) async {
    final b = Backend.I;
    switch (kind) {
      case RiskActionKind.message:
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => _MessageSheet(memberId: widget.memberId),
        );
      case RiskActionKind.trial:
        final ok = await confirm(
          context,
          title: 'Offrir une séance d\'essai ?',
          message:
              'Un carnet gratuit d\'une séance, valable '
              '${SessionPackService.trialDays} jours, sera '
              'ajouté et l\'abonné sera prévenu.',
          confirmLabel: 'Offrir',
        );
        if (!ok || !mounted) return;
        setState(() => _busy = true);
        await runAction(
          context,
          () => b.churnRisk.offerTrial(widget.memberId),
          success: 'Séance offerte.',
        );
        if (mounted) setState(() => _busy = false);
      case RiskActionKind.call:
        final note = await askText(
          context,
          title: 'Appel du coach',
          label: 'Note de l\'appel',
          hint: 'Ex. reprend la semaine prochaine, horaires du matin',
        );
        if (note == null || !mounted) return;
        await runAction(
          context,
          () => b.churnRisk.logCall(widget.memberId, note),
          success: 'Appel enregistré.',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return ListenableBuilder(
      listenable: b.bus,
      builder: (context, _) {
        final u = b.users.byId(widget.memberId);
        final RiskAssessment a;
        try {
          a = b.churnRisk.assess(widget.memberId);
        } on AppException catch (e) {
          return Scaffold(
            appBar: AppBar(),
            body: EmptyState(
              icon: Icons.lock_outline,
              title: 'Accès réservé',
              message: e.message,
            ),
          );
        }
        final actions = b.churnRisk.actionsFor(widget.memberId);
        final now = b.now();
        final suggested = a.level.suggested;
        return Scaffold(
          appBar: AppBar(title: Text(u?.fullName ?? 'Abonné')),
          body: ListView(
            padding: pagePadding(context, maxWidth: 900, bottom: Gap.xl),
            children: [
              GfCard(
                color: riskColor(a.level),
                child: Row(
                  children: [
                    GfAvatar(u, radius: 26),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${a.score}/100 · risque ${a.level.label.toLowerCase()}',
                            key: const Key('risk_score'),
                            style: AppText.title(size: 18),
                          ),
                          Text(
                            'Objectif : ${u?.goal.label ?? ''} · calculé le '
                            '${Fmt.dateTime(a.computedAt)}',
                            style: AppText.label(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Gap.m),
              Text('Facteurs', style: AppText.title(size: 18)),
              const SizedBox(height: Gap.s),
              for (final f in a.factors) _FactorRow(f),
              const SizedBox(height: Gap.m),
              Text(
                'Fréquentation (jours de venue par semaine)',
                style: AppText.title(size: 18),
              ),
              const SizedBox(height: Gap.s),
              GfCard(
                child: GfBarChart(
                  height: 180,
                  bars: [
                    for (final (i, v) in a.weeklyVisits.indexed)
                      (
                        Fmt.dayShort(
                          now.subtract(
                            Duration(days: 7 * (a.weeklyVisits.length - i) - 1),
                          ),
                        ),
                        v.toDouble(),
                      ),
                  ],
                  valueLabel: (v) => v.toStringAsFixed(0),
                ),
              ),
              const SizedBox(height: Gap.m),
              Text('Agir', style: AppText.title(size: 18)),
              const SizedBox(height: Gap.s),
              LoadingButton(
                key: const Key('risk_suggested'),
                label: 'Conseillé : ${suggested.label}',
                icon: riskActionIcon(suggested),
                loading: _busy,
                onPressed: () => _run(suggested),
              ),
              const SizedBox(height: Gap.s),
              Wrap(
                spacing: Gap.s,
                runSpacing: Gap.s,
                children: [
                  for (final k in RiskActionKind.values)
                    if (k != suggested)
                      OutlinedButton.icon(
                        key: Key('risk_do_${k.name}'),
                        onPressed: _busy ? null : () => _run(k),
                        icon: Icon(riskActionIcon(k)),
                        label: Text(k.label),
                      ),
                ],
              ),
              const SizedBox(height: Gap.m),
              Text('Suivi des actions', style: AppText.title(size: 18)),
              const SizedBox(height: Gap.s),
              if (actions.isEmpty)
                Text('Aucune action pour le moment.', style: AppText.label()),
              for (final x in actions) _ActionRow(x),
            ],
          ),
        );
      },
    );
  }
}

class _FactorRow extends StatelessWidget {
  const _FactorRow(this.f);
  final RiskFactor f;

  @override
  Widget build(BuildContext context) {
    // Facteur protecteur : il diminue le score.
    final protective = f.weight < 0;
    return Padding(
      key: Key('factor_${f.key}'),
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: GfCard(
        padding: const EdgeInsets.all(Gap.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(f.label, style: AppText.subtitle(size: 14)),
                ),
                Text(
                  protective
                      ? '−${(-f.points).round()} pts (max −${(-f.weight).round()})'
                      : '${f.points.round()} / ${f.weight.round()} pts',
                  style: AppText.subtitle(
                    size: 14,
                    color: f.points > 0
                        ? AppColors.red
                        : f.points < 0
                        ? AppColors.success
                        : AppColors.inkSoft,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: f.share,
                minHeight: 6,
                color: protective ? AppColors.success : AppColors.red,
                backgroundColor: AppColors.divider,
              ),
            ),
            const SizedBox(height: Gap.xs),
            Text(f.detail, style: AppText.label(size: 12)),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow(this.x);
  final RiskAction x;

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final outcome = b.churnRisk.outcomeOf(x);
    final actor = b.users.byId(x.actorId)?.fullName ?? 'Salle';
    return ListTile(
      key: Key('action_${x.id}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(riskActionIcon(x.kind), color: AppColors.navy),
      title: Text(
        '${x.kind.label} · ${Fmt.date(x.at)}',
        style: AppText.body(size: 14),
      ),
      subtitle: Text(
        '$actor · score ${x.score}'
        '${x.text.isEmpty ? '' : '\n${x.text}'}'
        '${x.emailSent ? '\nE-mail envoyé' : ''}',
        style: AppText.label(size: 12),
      ),
      trailing: Pill(
        outcome.label,
        color: switch (outcome) {
          RiskOutcome.returned => AppColors.successSoft,
          RiskOutcome.notReturned => AppColors.redSoft,
          RiskOutcome.pending => AppColors.cream,
        },
      ),
    );
  }
}

/// Rédaction du message : brouillon (IA ou calculé), relu et modifiable,
/// envoyé par le coach.
class _MessageSheet extends StatefulWidget {
  const _MessageSheet({required this.memberId});
  final String memberId;

  @override
  State<_MessageSheet> createState() => _MessageSheetState();
}

class _MessageSheetState extends State<_MessageSheet> {
  final _text = TextEditingController();
  bool _loading = true;
  bool _fromAi = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _draft();
  }

  Future<void> _draft() async {
    setState(() => _loading = true);
    try {
      final (text, ai) = await Backend.I.churnRisk.draftMessage(
        widget.memberId,
      );
      _text.text = text;
      _fromAi = ai;
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final ok = await runAction(
      context,
      () => Backend.I.churnRisk.sendMessage(widget.memberId, _text.text),
      success: 'Message envoyé.',
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Gap.m,
        Gap.m,
        Gap.m,
        MediaQuery.of(context).viewInsets.bottom + Gap.m,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Message personnalisé', style: AppText.title(size: 18)),
          const SizedBox(height: Gap.xs),
          Text(
            _loading
                ? 'Préparation du brouillon…'
                : _fromAi
                ? 'Brouillon rédigé par l\'IA (prénom, objectif et constats '
                      'seulement) : relisez-le avant d\'envoyer.'
                : 'Brouillon préparé par l\'application : adaptez-le avant '
                      'd\'envoyer.',
            key: const Key('draft_source'),
            style: AppText.label(size: 12),
          ),
          const SizedBox(height: Gap.s),
          TextField(
            key: const Key('message_text'),
            controller: _text,
            enabled: !_loading,
            minLines: 4,
            maxLines: 8,
            maxLength: 800,
            decoration: const InputDecoration(labelText: 'Message'),
          ),
          Row(
            children: [
              TextButton.icon(
                onPressed: _loading ? null : _draft,
                icon: const Icon(Icons.refresh),
                label: const Text('Nouveau brouillon'),
              ),
              const Spacer(),
              ElevatedButton.icon(
                key: const Key('send_message'),
                onPressed: _loading || _sending ? null : _send,
                icon: const Icon(Icons.send),
                label: const Text('Envoyer'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
