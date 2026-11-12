import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../models/enums.dart';
import '../../models/loyalty.dart';
import '../../services/backend.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../../widgets/pickers.dart';

Color _statusColor(String s) => switch (s) {
  'Actif' => AppColors.success,
  'Programmé' => AppColors.gold,
  _ => AppColors.divider,
};

/// Codes promo (super admin) : liste, utilisations, création, édition.
class CouponsAdminScreen extends StatelessWidget {
  const CouponsAdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Scaffold(
      appBar: AppBar(title: const Text('Codes promo')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'coupon_fab',
        onPressed: () => Navigator.pushNamed(context, Routes.couponForm),
        icon: const Icon(Icons.add),
        label: const Text('Code'),
      ),
      body: ListenableBuilder(
        listenable: b.bus,
        builder: (context, _) {
          final coupons = b.couponLoyalty.all();
          if (coupons.isEmpty) {
            return const EmptyState(
              icon: Icons.local_offer_outlined,
              title: 'Aucun code promo',
              message: 'Créez un code pour une opération commerciale.',
            );
          }
          return ListView.separated(
            padding: pagePadding(context, maxWidth: 900, bottom: 96),
            itemCount: coupons.length,
            separatorBuilder: (_, _) => const SizedBox(height: Gap.s),
            itemBuilder: (_, i) => FadeSlideIn(
              index: i,
              child: _CouponTile(coupon: coupons[i]),
            ),
          );
        },
      ),
    );
  }
}

class _CouponTile extends StatelessWidget {
  const _CouponTile({required this.coupon});
  final Coupon coupon;

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final c = coupon;
    final status = b.couponLoyalty.statusOf(c);
    final given = c.uses.fold(0.0, (s, u) => s + u.amount);
    final rules = [
      if (c.category != null) c.category!.label,
      if (c.minAmount > 0) 'dès ${Fmt.money(c.minAmount)}',
      if (c.expiresAt != null) 'jusqu\'au ${Fmt.date(c.expiresAt!)}',
      c.maxUsesPerUser == null
          ? 'sans limite par personne'
          : '${c.maxUsesPerUser} par personne',
    ];
    return GfCard(
      key: Key('coupon_${c.code}'),
      onTap: () =>
          Navigator.pushNamed(context, Routes.couponForm, arguments: c.id),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(c.code, style: AppText.title(size: 16)),
                    const SizedBox(width: Gap.s),
                    Pill(c.shortValue, color: AppColors.gold),
                  ],
                ),
                Text(c.label, style: AppText.body(size: 14)),
                Text(rules.join(' · '), style: AppText.label(size: 12)),
                Text(
                  '${c.uses.length}${c.maxUses == null ? '' : ' / ${c.maxUses}'} '
                  'utilisation(s) · ${Fmt.money(given)} accordés',
                  style: AppText.label(size: 12),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Pill(status, color: _statusColor(status)),
              IconButton(
                tooltip: c.uses.isEmpty ? 'Supprimer' : 'Désactiver',
                icon: Icon(c.uses.isEmpty ? Icons.delete_outline : Icons.block),
                onPressed: !c.active && c.uses.isNotEmpty
                    ? null
                    : () async {
                        final ok = await confirm(
                          context,
                          title: c.uses.isEmpty
                              ? 'Supprimer ${c.code} ?'
                              : 'Désactiver ${c.code} ?',
                          message: c.uses.isEmpty
                              ? 'Ce code n\'a jamais été utilisé.'
                              : 'Le code a déjà servi : il est désactivé et '
                                    'son historique est conservé.',
                        );
                        if (ok && context.mounted) {
                          await runAction(
                            context,
                            () => b.couponLoyalty.deleteCoupon(c.id),
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

/// Création ou modification d'un code promo.
class CouponFormScreen extends StatefulWidget {
  const CouponFormScreen({super.key, this.couponId});
  final String? couponId;

  @override
  State<CouponFormScreen> createState() => _CouponFormScreenState();
}

class _CouponFormScreenState extends State<CouponFormScreen> {
  late final Coupon? _existing = widget.couponId == null
      ? null
      : Backend.I.coupons.byId(widget.couponId);
  late final _code = TextEditingController(text: _existing?.code);
  late final _label = TextEditingController(text: _existing?.label);
  late final _value = TextEditingController(text: _num(_existing?.value));
  late final _min = TextEditingController(text: _num(_existing?.minAmount));
  late final _maxUses = TextEditingController(
    text: _existing?.maxUses?.toString(),
  );
  late final _perUser = TextEditingController(
    text: _existing == null ? '1' : _existing.maxUsesPerUser?.toString(),
  );
  late DiscountType _type = _existing?.type ?? DiscountType.percent;
  late ProductCategory? _category = _existing?.category;
  late DateTime? _startsAt = _existing?.startsAt;
  late DateTime? _expiresAt = _existing?.expiresAt;
  late bool _active = _existing?.active ?? true;
  bool _saving = false;

  static String? _num(double? v) =>
      v == null || v == 0 ? null : (v % 1 == 0 ? '${v.toInt()}' : '$v');

  @override
  void dispose() {
    for (final c in [_code, _label, _value, _min, _maxUses, _perUser]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _parse(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));
  int? _parseInt(TextEditingController c) => int.tryParse(c.text.trim());

  Future<void> _pickDate(bool start) async {
    final now = Backend.I.now();
    final d = await showDatePicker(
      context: context,
      initialDate: (start ? _startsAt : _expiresAt) ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (d == null) return;
    setState(() {
      if (start) {
        _startsAt = DateTime(d.year, d.month, d.day);
      } else {
        // Valable jusqu'à la fin de la journée choisie.
        _expiresAt = DateTime(d.year, d.month, d.day, 23, 59, 59);
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runAction(
      context,
      () => Backend.I.couponLoyalty.saveCoupon(
        id: _existing?.id,
        code: _code.text,
        label: _label.text,
        type: _type,
        value: _parse(_value) ?? 0,
        minAmount: _parse(_min) ?? 0,
        maxUses: _parseInt(_maxUses),
        maxUsesPerUser: _parseInt(_perUser),
        category: _category,
        startsAt: _startsAt,
        expiresAt: _expiresAt,
        active: _active,
      ),
      success: 'Code promo enregistré.',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  Widget _dateRow(String label, DateTime? value, bool start) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.event),
    title: Text(label),
    subtitle: Text(value == null ? 'Non définie' : Fmt.date(value)),
    trailing: value == null
        ? null
        : IconButton(
            tooltip: 'Effacer',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              if (start) {
                _startsAt = null;
              } else {
                _expiresAt = null;
              }
            }),
          ),
    onTap: () => _pickDate(start),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? 'Nouveau code promo' : _existing.code),
      ),
      body: ListView(
        padding: pagePadding(context, maxWidth: 760),
        children: [
          TextField(
            key: const Key('coupon_code'),
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Code',
              hintText: 'Ex. RENTREE15',
            ),
          ),
          const SizedBox(height: Gap.m),
          TextField(
            key: const Key('coupon_label'),
            controller: _label,
            decoration: const InputDecoration(labelText: 'Libellé'),
          ),
          const FormSection('Réduction'),
          SegmentedButton<DiscountType>(
            segments: [
              for (final t in DiscountType.values)
                ButtonSegment(value: t, label: Text(t.label)),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          const SizedBox(height: Gap.m),
          TextField(
            key: const Key('coupon_value'),
            controller: _value,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: _type == DiscountType.percent
                  ? 'Pourcentage (1 à 90)'
                  : 'Montant (DT)',
            ),
          ),
          const FormSection('Conditions'),
          EnumDropdown<ProductCategory?>(
            label: 'Catégorie ciblée',
            value: _category,
            values: [null, ...ProductCategory.values],
            labelOf: (c) => c?.label ?? 'Tout le catalogue',
            onChanged: (c) => setState(() => _category = c),
          ),
          const SizedBox(height: Gap.m),
          TextField(
            controller: _min,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Montant minimum du panier (DT)',
            ),
          ),
          const SizedBox(height: Gap.m),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _maxUses,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Utilisations au total',
                    hintText: 'Illimité',
                  ),
                ),
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: TextField(
                  controller: _perUser,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Par personne',
                    hintText: 'Illimité',
                  ),
                ),
              ),
            ],
          ),
          Text(
            'Le code ne s\'applique jamais aux produits déjà en promotion, et '
            'la réduction ne dépasse jamais le montant concerné.',
            style: AppText.label(size: 12),
          ),
          const FormSection('Validité'),
          _dateRow('Début', _startsAt, true),
          _dateRow('Expiration', _expiresAt, false),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Actif'),
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
          const SizedBox(height: Gap.l),
          LoadingButton(
            key: const Key('coupon_save'),
            label: 'Enregistrer',
            loading: _saving,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
