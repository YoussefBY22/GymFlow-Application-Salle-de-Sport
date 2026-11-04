import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../models/chat.dart';
import '../../services/backend.dart';
import '../../widgets/common.dart';
import '../../widgets/pickers.dart';

/// Signalements de la messagerie (administrateur).
///
/// Les signalements sont sur Supabase : l'administrateur relie d'abord son
/// compte avec son mot de passe, puis lit les signalements. La personne
/// signalée n'en est jamais informée, et les blocages ne sont jamais visibles.
class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  bool _showHandled = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final m = Backend.I.moderation;
    if (m.connected) unawaited(m.refresh().catchError((Object _) {}));
  }

  Future<void> _connect() async {
    final pwd = await askText(
      context,
      title: 'Confirmez votre mot de passe',
      label: 'Mot de passe administrateur',
      obscure: true,
      hint: 'Pour lire les signalements de la messagerie',
      validator: (v) =>
          (v == null || v.isEmpty) ? 'Saisissez le mot de passe.' : null,
    );
    if (pwd == null || !mounted) return;
    setState(() => _busy = true);
    await runAction(context, () => Backend.I.moderation.connect(pwd));
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _handle(ReportEntry r) async {
    final note = await askText(
      context,
      title: 'Marquer comme traité',
      label: 'Note (facultatif)',
      hint: 'Ex. personne avertie',
      validator: (v) =>
          (v != null && v.length > 500) ? '500 caractères au plus.' : null,
    );
    if (note == null || !mounted) return;
    setState(() => _busy = true);
    await runAction(
      context,
      () => Backend.I.moderation.handle(r, note: note),
      success: 'Signalement traité.',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final m = Backend.I.moderation;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Signalements'),
        actions: [
          if (m.connected)
            IconButton(
              key: const Key('reports_refresh'),
              tooltip: 'Actualiser',
              onPressed: _busy
                  ? null
                  : () => runAction(context, () => m.refresh()),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: m,
        builder: (context, _) {
          if (!m.available) {
            return const EmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'Messagerie indisponible',
              message:
                  'Supabase n\'est pas configuré dans cette version de '
                  'l\'application.',
            );
          }
          if (!m.connected) {
            return ListView(
              padding: pagePadding(context, maxWidth: 760),
              children: [
                GfCard(
                  key: const Key('reports_connect'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Lire les signalements',
                        style: AppText.title(size: 18),
                      ),
                      const SizedBox(height: Gap.s),
                      Text(
                        'Les signalements sont stockés sur Supabase. Reliez '
                        'votre compte administrateur avec votre mot de passe '
                        'pour les lire. Seul le compte administrateur y a '
                        'accès.',
                        style: AppText.body(size: 14, color: AppColors.inkSoft),
                      ),
                      if (m.error != null) ...[
                        const SizedBox(height: Gap.s),
                        Text(
                          friendlyError(m.error!),
                          style: AppText.body(size: 14, color: AppColors.redText),
                        ),
                      ],
                      const SizedBox(height: Gap.m),
                      ElevatedButton.icon(
                        key: const Key('reports_connect_button'),
                        onPressed: _busy ? null : _connect,
                        icon: const Icon(Icons.lock_open_outlined),
                        label: const Text('Se connecter'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }
          final list = [
            for (final r in m.reports)
              if (r.handled == _showHandled) r,
          ];
          return ListView(
            padding: pagePadding(context, maxWidth: 760),
            children: [
              SegmentedButton<bool>(
                key: const Key('reports_filter'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text('Nouveaux (${m.newCount})'),
                  ),
                  const ButtonSegment(value: true, label: Text('Traités')),
                ],
                selected: {_showHandled},
                onSelectionChanged: (s) =>
                    setState(() => _showHandled = s.first),
              ),
              const SizedBox(height: Gap.m),
              if (list.isEmpty)
                GfCard(
                  child: InfoRow(
                    Icons.check_circle_outline,
                    _showHandled
                        ? 'Aucun signalement traité.'
                        : 'Aucun nouveau signalement.',
                  ),
                )
              else
                for (final r in list) ...[
                  _ReportCard(
                    report: r,
                    busy: _busy,
                    onHandle: () => _handle(r),
                  ),
                  const SizedBox(height: Gap.s),
                ],
            ],
          );
        },
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({
    required this.report,
    required this.busy,
    required this.onHandle,
  });

  final ReportEntry report;
  final bool busy;
  final VoidCallback onHandle;

  @override
  Widget build(BuildContext context) {
    final r = report;
    return GfCard(
      key: Key('report_${r.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill(
                r.isConversation ? 'Discussion' : 'Personne',
                color: r.isConversation ? AppColors.navy : AppColors.red,
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Text(
                  Fmt.dateTime(r.createdAt.toLocal()),
                  style: AppText.label(size: 12),
                ),
              ),
              if (r.handled) const Pill('Traité', color: AppColors.success),
            ],
          ),
          const SizedBox(height: Gap.s),
          Text(
            '${r.reporterName} signale ${r.reportedName}',
            style: AppText.subtitle(size: 15),
          ),
          if (r.remark != null && r.remark!.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text('« ${r.remark} »', style: AppText.body(size: 14)),
          ],
          if (r.messages.isNotEmpty) ...[
            const SizedBox(height: Gap.s),
            Text(
              'Messages signalés (${r.messages.length})',
              style: AppText.label(size: 12),
            ),
            const SizedBox(height: Gap.xs),
            for (final m in r.messages)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        m.from,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.label(size: 12, color: AppColors.heading),
                      ),
                    ),
                    Expanded(
                      child: Text(m.display, style: AppText.body(size: 14)),
                    ),
                  ],
                ),
              ),
          ],
          if (r.handled && r.handledNote != null) ...[
            const SizedBox(height: Gap.s),
            InfoRow(Icons.note_alt_outlined, 'Note : ${r.handledNote}'),
          ],
          if (!r.handled) ...[
            const SizedBox(height: Gap.s),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                key: Key('handle_${r.id}'),
                onPressed: busy ? null : onHandle,
                icon: const Icon(Icons.check),
                label: const Text('Marquer comme traité'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
