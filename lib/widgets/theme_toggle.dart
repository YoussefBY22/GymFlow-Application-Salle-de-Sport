import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services/theme_controller.dart';

/// Bouton clair / sombre de la barre du haut : le soleil se couche pendant que
/// la lune se lève (et inversement), puis l'écran change de mode en un fondu
/// circulaire qui part du bouton.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeController.I;
    return ListenableBuilder(
      listenable: theme,
      builder: (context, _) {
        final dark = theme.isDark;
        return IconButton(
          key: const Key('theme_toggle'),
          tooltip: dark ? 'Passer en mode clair' : 'Passer en mode sombre',
          onPressed: () {
            final box = context.findRenderObject() as RenderBox?;
            final origin = box == null || !box.hasSize
                ? null
                : box.localToGlobal(box.size.center(Offset.zero));
            theme.toggle(origin: origin);
          },
          icon: ClipRect(
            child: SizedBox(
              width: 24,
              height: 24,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1.1),
                    end: Offset.zero,
                  ).animate(animation),
                  child: RotationTransition(
                    turns: Tween<double>(begin: -0.12, end: 0).animate(
                      animation,
                    ),
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                ),
                child: Icon(
                  dark ? Icons.nightlight_round : Icons.wb_sunny_rounded,
                  key: ValueKey(dark),
                  size: 24,
                  color: dark
                      ? const Color(0xFFCFE0FF)
                      : const Color(0xFFFFCF70),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Enveloppe l'application : garde une capture de l'écran avant le changement
/// de mode et la « retire » en cercle grandissant pour révéler le nouveau.
class ThemeTransitionHost extends StatefulWidget {
  const ThemeTransitionHost({super.key, required this.child});

  final Widget child;

  @override
  State<ThemeTransitionHost> createState() => _ThemeTransitionHostState();
}

class _ThemeTransitionHostState extends State<ThemeTransitionHost>
    with SingleTickerProviderStateMixin {
  final _boundary = GlobalKey();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  ui.Image? _old;
  Offset _origin = Offset.zero;

  @override
  void initState() {
    super.initState();
    final theme = ThemeController.I;
    theme.captureHost = _capture;
    theme.revealHost = _reveal;
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() {
          _old?.dispose();
          _old = null;
        });
      }
    });
  }

  Future<ui.Image?> _capture() async {
    final render = _boundary.currentContext?.findRenderObject();
    if (render is! RenderRepaintBoundary) return null;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return render.toImage(pixelRatio: ratio);
  }

  void _reveal(ui.Image image, Offset origin) {
    if (!mounted) {
      image.dispose();
      return;
    }
    setState(() {
      _old?.dispose();
      _old = image;
      _origin = origin;
    });
    _anim.forward(from: 0);
  }

  @override
  void dispose() {
    final theme = ThemeController.I;
    if (theme.captureHost == _capture) theme.captureHost = null;
    if (theme.revealHost == _reveal) theme.revealHost = null;
    _anim.dispose();
    _old?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final old = _old;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        RepaintBoundary(key: _boundary, child: widget.child),
        if (old != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _anim,
                builder: (context, _) => CustomPaint(
                  painter: _RevealPainter(
                    image: old,
                    origin: _origin,
                    t: Curves.easeInOutCubic.transform(_anim.value),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Dessine l'ancien écran avec un trou circulaire qui grandit : à l'intérieur
/// du trou, on voit déjà le nouveau mode.
class _RevealPainter extends CustomPainter {
  _RevealPainter({required this.image, required this.origin, required this.t});

  final ui.Image image;
  final Offset origin;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final farthest = [
      origin.distance,
      (origin - Offset(size.width, 0)).distance,
      (origin - Offset(0, size.height)).distance,
      (origin - Offset(size.width, size.height)).distance,
    ].reduce(math.max);
    final hole = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: origin, radius: farthest * t));
    canvas.save();
    canvas.clipPath(hole);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RevealPainter old) => old.t != t || old.image != image;
}
