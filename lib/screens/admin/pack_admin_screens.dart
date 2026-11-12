import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../models/enums.dart';
import '../../models/session_pack.dart';
import '../../services/backend.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../../widgets/pickers.dart';

/// Formules de carnets (super admin) : liste, ventes, réglage du délai
/// d'annulation gratuite.
class PackOffersAdminScreen extends StatelessWidget {
  const PackOffersAdminScreen({super.key});

  Future<void> _settings(BuildContext context) async {
    final b = Backend.I;
    final value = await askText(
      context,
      title: 'Annulation gratuite',
      label: 'Heures avant le cours (1 à 72)',
      initial: '${b.packs.settings.freeCancelHours}',
    );
    final hours = int.tryParse(value?.trim() ?? '');
    if (value == null || !context.mounted) return;
    await runAction(
      context,
      () => b.packs.saveSettings(freeCancelHours: hours ?? 0),
      success: 'Délai enregistré.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Formules de cours'),
        actions: [
          IconButton(
            key: const Key('pack_settings'),
            tooltip: 'Délai d\'annulation gratuite',
            icon: const Icon(Icons.tune),
            onPressed: () => _settings(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'pack_offer_fab',
        onPressed: () => Navigator.pushNamed(context, Routes.packOfferForm),
        icon: const Icon(Icons.add),
        label: const Text('Formule'),
      ),
      body: ListenableBuilder(
        listenable: b.bus,
        builder: (context, _) {
          final offers = b.packs.offers(includeInactive: true);
          return ListView(
            padding: pagePadding(context, maxWidth: 900, bottom: 96),
            children: [
              GfCard(
                color: AppColors.cream,
                child: InfoRow(
                  Icons.event_busy,
                  'Annulation gratuite jusqu\'à '
                  '${b.packs.settings.freeCancelHours} h avant le cours '
                  '(au-delà, la séance est décomptée).',
                ),
              ),
              const SizedBox(height: Gap.s),
              if (offers.isEmpty)
                const EmptyState(
                  icon: Icons.confirmation_number_outlined,
                  title: 'Aucune formule',
                  message: 'Créez un carnet ou une formule hebdomadaire.',
                ),
              for (final (i, o) in offers.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.s),
                  child: FadeSlideIn(
                    index: i,
                    child: _OfferTile(offer: o),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _OfferTile extends StatelessWidget {
  const _OfferTile({required this.offer});
  final PackOffer offer;

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final o = offer;
    final sold = b.packs.soldCount(o.id);
    return GfCard(
      key: Key('offer_${o.id}'),
      onTap: () =>
          Navigator.pushNamed(context, Routes.packOfferForm, arguments: o.id),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(o.name, style: AppText.subtitle()),
                Text(
                  '${o.quotaLabel} · ${o.validityDays} jours · '
                  '${Fmt.money(o.price)}',
                  style: AppText.body(size: 14),
                ),
                Text(
                  '${o.categoriesLabel} · ${Fmt.plural(sold, 'vente')}',
                  style: AppText.label(size: 12),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Pill(
                o.active ? 'En vente' : 'Retirée',
                color: o.active ? AppColors.successSoft : AppColors.divider,
              ),
              IconButton(
                tooltip: sold == 0 ? 'Supprimer' : 'Retirer de la vente',
                icon: Icon(sold == 0 ? Icons.delete_outline : Icons.block),
                onPressed: !o.active && sold > 0
                    ? null
                    : () async {
                        final ok = await confirm(
                          context,
                          title: sold == 0
                              ? 'Supprimer « ${o.name} » ?'
                              : 'Retirer « ${o.name} » de la vente ?',
                          message: sold == 0
                              ? 'Cette formule n\'a jamais été vendue.'
                              : 'Les carnets déjà vendus restent valables.',
                        );
                        if (ok && context.mounted) {
                          await runAction(
                            context,
                            () => b.packs.deleteOffer(o.id),
                          );
                        }
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Création ou modification d'une formule.
class PackOfferFormScreen extends StatefulWidget {
  const PackOfferFormScreen({super.key, this.offerId});
  final String? offerId;

  @override
  State<PackOfferFormScreen> createState() => _PackOfferFormScreenState();
}

class _PackOfferFormScreenState extends State<PackOfferFormScreen> {
  late final PackOffer? _existing = widget.offerId == null
      ? null
      : Backend.I.packOffers.byId(widget.offerId);
  late final _name = TextEditingController(text: _existing?.name);
  late final _quota = TextEditingController(text: '${_existing?.quota ?? 10}');
  late final _validity = TextEditingController(
    text: '${_existing?.validityDays ?? 90}',
  );
  late final _price = TextEditingController(
    text: _existing == null ? '' : _num(_existing.price),
  );
  late PackKind _kind = _existing?.kind ?? PackKind.credits;
  late final Set<CourseCategory> _categories = {...?_existing?.categories};
  late bool _active = _existing?.active ?? true;
  bool _saving = false;

  static String _num(double v) => v % 1 == 0 ? '${v.toInt()}' : '$v';

  @override
  void dispose() {
    for (final c in [_name, _quota, _validity, _price]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runAction(
      context,
      () => Backend.I.packs.saveOffer(
        id: _existing?.id,
        name: _name.text,
        kind: _kind,
        quota: int.tryParse(_quota.text.trim()) ?? 0,
        validityDays: int.tryParse(_validity.text.trim()) ?? 0,
        price: double.tryParse(_price.text.trim().replaceAll(',', '.')) ?? 0,
        categories: _categories.toList(),
        active: _active,
      ),
      success: 'Formule enregistrée.',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final sold = _existing == null
        ? 0
        : Backend.I.packs.soldCount(_existing.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? 'Nouvelle formule' : _existing.name),
      ),
      body: ListView(
        padding: pagePadding(context, maxWidth: 760),
        children: [
          TextField(
            key: const Key('offer_name'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Nom',
              hintText: 'Ex. Carnet 10 séances',
            ),
          ),
          const FormSection('Type'),
          SegmentedButton<PackKind>(
            segments: [
              for (final k in PackKind.values)
                ButtonSegment(value: k, label: Text(k.label)),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: Gap.m),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('offer_quota'),
                  controller: _quota,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _kind == PackKind.credits
                        ? 'Séances'
                        : 'Cours par semaine',
                  ),
                ),
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: TextField(
                  key: const Key('offer_validity'),
                  controller: _validity,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Validité (jours)',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.m),
          TextField(
            key: const Key('offer_price'),
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Prix (DT, hors timbre fiscal)',
            ),
          ),
          const FormSection('Cours autorisés'),
          Text(
            _categories.isEmpty
                ? 'Aucune catégorie cochée : tous les cours.'
                : 'Seulement les catégories cochées.',
            style: AppText.label(size: 12),
          ),
          const SizedBox(height: Gap.s),
          Wrap(
            spacing: Gap.s,
            runSpacing: Gap.s,
            children: [
              for (final c in CourseCategory.values)
                FilterChip(
                  avatar: Icon(c.icon, size: 18),
                  label: Text(c.label),
                  selected: _categories.contains(c),
                  onSelected: (on) => setState(
                    () => on ? _categories.add(c) : _categories.remove(c),
                  ),
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('En vente'),
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
          if (sold > 0)
            Text(
              'Déjà ${Fmt.plural(sold, 'vente')} : les modifications ne '
              's\'appliquent qu\'aux prochains achats.',
              style: AppText.label(size: 12),
            ),
          const SizedBox(height: Gap.l),
          LoadingButton(
            key: const Key('offer_save'),
            label: 'Enregistrer',
            icon: Icons.save,
            loading: _saving,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
