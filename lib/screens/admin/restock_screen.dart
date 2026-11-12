import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../models/shop.dart';
import '../../services/backend.dart';
import '../../services/inventory_forecast_service.dart';
import '../../widgets/animations.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';

Color _abcColor(AbcClass c) => switch (c) {
  AbcClass.a => AppColors.navy,
  AbcClass.b => AppColors.gold,
  AbcClass.c => AppColors.divider,
};

Color _statusColor(StockStatus s) => switch (s) {
  StockStatus.outOfStock => AppColors.red,
  StockStatus.reorder => AppColors.red,
  StockStatus.watch => AppColors.gold,
  StockStatus.ok => AppColors.success,
};

String _days(double? d) => d == null
    ? 'Pas de vente récente'
    : d < 1
    ? 'Rupture imminente'
    : 'Rupture dans ${d.floor()} j';

/// Prévision des ruptures (super admin) : produits triés par urgence,
/// classe ABC, quantité conseillée et réglages du réapprovisionnement.
class RestockScreen extends StatelessWidget {
  const RestockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Réapprovisionnement'),
        actions: [
          IconButton(
            key: const Key('restock_settings'),
            tooltip: 'Réglages',
            icon: const Icon(Icons.tune),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const _SettingsSheet(),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: b.bus,
        builder: (context, _) {
          final items = b.inventory.forecast();
          final s = b.inventory.settings;
          int count(StockStatus st) =>
              items.where((f) => f.status == st).length;
          return ListView(
            padding: pagePadding(context, maxWidth: 900),
            children: [
              GfCard(
                color: AppColors.cream,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Délai fournisseur ${s.leadTimeDays} j · couverture '
                      '${s.coverageDays} j · service '
                      '${(s.serviceLevel * 100).round()} %',
                      style: AppText.subtitle(size: 14),
                    ),
                    const SizedBox(height: Gap.s),
                    Wrap(
                      spacing: Gap.s,
                      runSpacing: Gap.s,
                      children: [
                        for (final st in StockStatus.values.take(3))
                          Pill(
                            '${st.label} : ${count(st)}',
                            color: count(st) == 0
                                ? AppColors.surface
                                : _statusColor(st),
                          ),
                      ],
                    ),
                    const SizedBox(height: Gap.s),
                    Text(
                      'Prévision sur les ${InventoryForecastService.historyDays} '
                      'derniers jours de ventes (moyenne lissée). Classe A : '
                      '80 % du chiffre d\'affaires sur '
                      '${InventoryForecastService.abcDays} jours.',
                      style: AppText.label(size: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Gap.m),
              for (var i = 0; i < items.length; i++)
                FadeSlideIn(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: Gap.s),
                    child: _ForecastTile(item: items[i]),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _AbcBadge extends StatelessWidget {
  const _AbcBadge(this.abc);
  final AbcClass abc;

  @override
  Widget build(BuildContext context) {
    final color = _abcColor(abc);
    return Tooltip(
      message: 'Classe ${abc.label} : ${abc.description.toLowerCase()}',
      child: CircleAvatar(
        radius: 18,
        backgroundColor: color,
        child: Text(
          abc.label,
          style: AppText.subtitle(color: onColor(color), size: 15),
        ),
      ),
    );
  }
}

class _ForecastTile extends StatelessWidget {
  const _ForecastTile({required this.item});
  final StockForecast item;

  @override
  Widget build(BuildContext context) {
    final f = item;
    return GfCard(
      key: Key('forecast_${f.product.id}'),
      padding: const EdgeInsets.all(Gap.s + 4),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _ForecastDetail(productId: f.product.id),
      ),
      child: Row(
        children: [
          _AbcBadge(f.abc),
          const SizedBox(width: Gap.s + 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.product.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.subtitle(size: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  'Stock ${f.product.stock} · ${Fmt.dec1(f.dailyDemand)} / j · '
                  '${f.product.stock == 0 ? 'En rupture' : _days(f.daysToStockout)}',
                  style: AppText.label(size: 12),
                ),
                if (f.suggestedQuantity > 0)
                  Text(
                    'Commander ${f.suggestedQuantity} unité(s)',
                    style: AppText.label(color: AppColors.redText, size: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Gap.s),
          Pill(f.status.label, color: _statusColor(f.status)),
        ],
      ),
    );
  }
}

/// Détail d'un produit : graphique des ventes, calculs et réception.
class _ForecastDetail extends StatelessWidget {
  const _ForecastDetail({required this.productId});
  final String productId;

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return ListenableBuilder(
      listenable: b.bus,
      builder: (context, _) {
        final f = b.inventory.forProduct(productId);
        if (f == null) return const SizedBox.shrink();
        final s = b.inventory.settings;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _AbcBadge(f.abc),
                    const SizedBox(width: Gap.s),
                    Expanded(
                      child: Text(
                        f.product.name,
                        style: AppText.title(size: 18),
                      ),
                    ),
                    Pill(f.status.label, color: _statusColor(f.status)),
                  ],
                ),
                const SizedBox(height: Gap.m),
                Text(
                  'Ventes par jour et tendance lissée',
                  style: AppText.subtitle(size: 14),
                ),
                const SizedBox(height: Gap.s),
                GfDemandChart(
                  sales: f.sales,
                  smoothed: f.smoothed,
                  end: b.now(),
                ),
                const SizedBox(height: Gap.s),
                InfoRow(
                  Icons.trending_up,
                  'Ventes prévues : ${Fmt.dec1(f.dailyDemand)} par jour '
                  '(écart-type ${Fmt.dec1(f.deviation)})',
                ),
                InfoRow(
                  Icons.shield_outlined,
                  'Stock de sécurité : ${f.safetyStock.ceil()} unité(s)',
                ),
                InfoRow(
                  Icons.flag_outlined,
                  'Seuil de réapprovisionnement : '
                  '${f.reorderPoint.ceil()} unité(s) '
                  '(délai ${s.leadTimeDays} j)',
                ),
                InfoRow(
                  Icons.hourglass_bottom,
                  f.product.stock == 0
                      ? 'En rupture de stock'
                      : '${_days(f.daysToStockout)} '
                            '(stock ${f.product.stock})',
                ),
                InfoRow(
                  Icons.payments_outlined,
                  'Chiffre d\'affaires ${InventoryForecastService.abcDays} j : '
                  '${Fmt.money(f.revenue)} (classe ${f.abc.label})',
                ),
                const SizedBox(height: Gap.m),
                if (f.suggestedQuantity > 0)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      key: const Key('receive_stock'),
                      onPressed: () => runAction(
                        context,
                        () => b.productService.adjustStock(
                          f.product.id,
                          f.suggestedQuantity,
                        ),
                        success:
                            '${f.suggestedQuantity} unité(s) ajoutée(s) au stock.',
                      ),
                      icon: const Icon(Icons.local_shipping_outlined),
                      label: Text(
                        'Réceptionner ${f.suggestedQuantity} unité(s)',
                      ),
                    ),
                  )
                else
                  Text(
                    'Stock suffisant pour ${s.leadTimeDays + s.coverageDays} '
                    'jours : aucune commande conseillée.',
                    style: AppText.label(),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Réglages : délai fournisseur, couverture et niveau de service.
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late InventorySettings _s = Backend.I.inventory.settings;
  bool _saving = false;

  Widget _stepper(
    String label,
    String help,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged,
  ) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppText.subtitle(size: 15)),
            Text(help, style: AppText.label(size: 12)),
          ],
        ),
      ),
      IconButton(
        tooltip: 'Moins',
        onPressed: value > min ? () => onChanged(value - 1) : null,
        icon: const Icon(Icons.remove_circle_outline),
      ),
      SizedBox(
        width: 48,
        child: Text(
          '$value j',
          textAlign: TextAlign.center,
          style: AppText.stat(size: 16),
        ),
      ),
      IconButton(
        tooltip: 'Plus',
        onPressed: value < max ? () => onChanged(value + 1) : null,
        icon: const Icon(Icons.add_circle_outline),
      ),
    ],
  );

  InventorySettings _with({int? lead, int? coverage, double? level}) =>
      InventorySettings(
        leadTimeDays: lead ?? _s.leadTimeDays,
        coverageDays: coverage ?? _s.coverageDays,
        serviceLevel: level ?? _s.serviceLevel,
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Gap.m,
          Gap.m,
          Gap.m,
          Gap.m + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Réglages du réapprovisionnement',
              style: AppText.title(size: 18),
            ),
            const SizedBox(height: Gap.m),
            _stepper(
              'Délai fournisseur',
              'Entre la commande et la livraison',
              _s.leadTimeDays,
              1,
              60,
              (v) => setState(() => _s = _with(lead: v)),
            ),
            _stepper(
              'Couverture',
              'Jours de ventes couverts par une commande',
              _s.coverageDays,
              1,
              90,
              (v) => setState(() => _s = _with(coverage: v)),
            ),
            const SizedBox(height: Gap.s),
            Text('Niveau de service', style: AppText.subtitle(size: 15)),
            Text(
              'Probabilité de ne pas tomber en rupture pendant le délai',
              style: AppText.label(size: 12),
            ),
            const SizedBox(height: Gap.s),
            Wrap(
              spacing: Gap.s,
              children: [
                for (final pct in InventoryForecastService.zScores.keys)
                  ChoiceChip(
                    label: Text('$pct %'),
                    selected: (_s.serviceLevel * 100).round() == pct,
                    onSelected: (_) =>
                        setState(() => _s = _with(level: pct / 100)),
                  ),
              ],
            ),
            const SizedBox(height: Gap.l),
            LoadingButton(
              label: 'Enregistrer',
              loading: _saving,
              onPressed: () async {
                setState(() => _saving = true);
                final ok = await runAction(
                  context,
                  () => Backend.I.inventory.saveSettings(
                    leadTimeDays: _s.leadTimeDays,
                    coverageDays: _s.coverageDays,
                    serviceLevel: _s.serviceLevel,
                  ),
                  success: 'Réglages enregistrés.',
                );
                if (!context.mounted) return;
                setState(() => _saving = false);
                if (ok) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}
