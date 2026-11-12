import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Carte de chaleur jour × heure (fl_chart n'en propose pas).
///
/// 7 colonnes (lundi → dimanche) et une ligne par heure d'ouverture : la
/// grille tient en largeur sur un téléphone de 360 dp (colonne des heures
/// de 34 dp, cellules d'environ 40 dp). Couleur de la crème au rouge de la
/// charte selon la valeur relative au maximum ; un toucher affiche le
/// détail via [onTap].
class GfHeatmap extends StatelessWidget {
  const GfHeatmap({
    super.key,
    required this.firstHour,
    required this.lastHour,
    required this.valueOf,
    this.maxValue,
    this.onTap,
    this.highlight,
    this.cellHeight = 22,
  });

  /// Heures affichées : [firstHour] à [lastHour] exclue.
  final int firstHour;
  final int lastHour;

  /// Valeur d'une case (jour 1 = lundi … 7, heure).
  final double Function(int weekday, int hour) valueOf;

  /// Valeur correspondant à la couleur la plus foncée (sinon le maximum).
  final double? maxValue;
  final void Function(int weekday, int hour)? onTap;

  /// Case mise en évidence (créneau actuel).
  final (int, int)? highlight;
  final double cellHeight;

  static const days = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
  static const dayNames = [
    'lundi',
    'mardi',
    'mercredi',
    'jeudi',
    'vendredi',
    'samedi',
    'dimanche',
  ];

  static Color get low => AppColors.cream;
  static Color get high => AppColors.red;

  /// Couleur pour une part de 0 à 1.
  static Color colorFor(double t) => Color.lerp(low, high, t.clamp(0.0, 1.0))!;

  @override
  Widget build(BuildContext context) {
    var max = maxValue ?? 0;
    if (maxValue == null) {
      for (var d = 1; d <= 7; d++) {
        for (var h = firstHour; h < lastHour; h++) {
          final v = valueOf(d, h);
          if (v > max) max = v;
        }
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(width: 34),
            for (final d in days)
              Expanded(
                child: Text(
                  d,
                  textAlign: TextAlign.center,
                  style: AppText.label(size: 12),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var h = firstHour; h < lastHour; h++)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: Text('$h h', style: AppText.label(size: 11)),
                ),
                for (var d = 1; d <= 7; d++) _cell(context, d, h, max),
              ],
            ),
          ),
        const SizedBox(height: Gap.s),
        Row(
          children: [
            Text('Calme', style: AppText.label(size: 11)),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  gradient: LinearGradient(colors: [low, high]),
                ),
              ),
            ),
            const SizedBox(width: Gap.xs),
            Text('Chargé', style: AppText.label(size: 11)),
          ],
        ),
      ],
    );
  }

  Widget _cell(BuildContext context, int d, int h, double max) {
    final v = valueOf(d, h);
    final t = max <= 0 ? 0.0 : v / max;
    final current = highlight == (d, h);
    return Expanded(
      child: Semantics(
        label: '${dayNames[d - 1]} $h h : ${v.toStringAsFixed(1)} personnes',
        button: onTap != null,
        child: GestureDetector(
          key: Key('heat_${d}_$h'),
          onTap: onTap == null ? null : () => onTap!(d, h),
          child: Container(
            height: cellHeight,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: colorFor(t),
              borderRadius: BorderRadius.circular(4),
              border: current
                  ? Border.all(color: AppColors.heading, width: 2)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
