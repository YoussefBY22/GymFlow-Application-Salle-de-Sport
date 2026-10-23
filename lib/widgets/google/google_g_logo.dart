import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Le « G » de Google, dessiné directement.
///
/// Dessiné plutôt qu'importé : cela évite une dépendance SVG et un fichier
/// d'image supplémentaire pour une icône de 20 pixels. Les quatre couleurs
/// sont celles de la charte de Google.
class GoogleGLogo extends StatelessWidget {
  const GoogleGLogo({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GooglePainter());
}

class _GooglePainter extends CustomPainter {
  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  static double _rad(double degrees) => degrees * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    // Proportions reprises du logo officiel (anneau d'environ un cinquième
    // du diamètre, barre un peu plus fine que l'anneau).
    final s = size.width;
    final thickness = s * 0.205;
    final radius = (s - thickness) / 2;
    final center = Offset(s / 2, s / 2);
    final box = Rect.fromCircle(center: center, radius: radius);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.butt;

    // Quatre arcs, dans le sens horaire depuis la droite (0° = 3 heures).
    void segment(Color color, double from, double sweep) {
      canvas.drawArc(box, _rad(from), _rad(sweep), false, arc..color = color);
    }

    segment(_blue, -62, 68); // droite
    segment(_green, 6, 89); // bas
    segment(_yellow, 95, 80); // gauche
    segment(_red, 175, 123); // haut

    // La barre horizontale du G : du centre vers le bord droit, à
    // mi-hauteur, légèrement plus fine que l'anneau.
    final bar = thickness * 0.82;
    canvas.drawRect(
      Rect.fromLTRB(
        s * 0.49,
        center.dy - bar / 2,
        s * 0.97,
        center.dy + bar / 2,
      ),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
