import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/enums.dart';

class AnimatedExerciseAvatar extends StatefulWidget {
  const AnimatedExerciseAvatar({
    super.key,
    required this.name,
    required this.muscle,
  });

  final String name;
  final Muscle muscle;

  @override
  State<AnimatedExerciseAvatar> createState() => _AnimatedExerciseAvatarState();
}

class _AnimatedExerciseAvatarState extends State<AnimatedExerciseAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  _Movement get _movement => _Movement.forExercise(widget.name, widget.muscle);

  @override
  Widget build(BuildContext context) => Semantics(
    key: const Key('animated_exercise_avatar_semantics'),
    container: true,
    label: 'Démonstration animée : ${_movement.label}',
    child: Container(
      height: 224,
      decoration: BoxDecoration(
        color: AppColors.navy,
        borderRadius: BorderRadius.circular(Gap.radius),
      ),
      padding: const EdgeInsets.all(Gap.m),
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final reduceMotion = MediaQuery.disableAnimationsOf(context);
                return AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => CustomPaint(
                    key: const Key('animated_exercise_avatar_painter'),
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: _AvatarPainter(
                      progress: reduceMotion ? 0.5 : _controller.value,
                      movement: _movement,
                      muscle: widget.muscle,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: Gap.xs),
          Row(
            children: [
              const Icon(
                Icons.accessibility_new,
                color: AppColors.gold,
                size: 18,
              ),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(
                  _movement.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label(color: AppColors.white, size: 13),
                ),
              ),
              const Text(
                'Animation illustrative',
                style: TextStyle(color: AppColors.navyMuted, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

enum _MovementKind { squat, lunge, push, curl, hinge, plank, cardio }

class _Movement {
  const _Movement(this.kind, this.label);

  final _MovementKind kind;
  final String label;

  static _Movement forExercise(String name, Muscle muscle) {
    final normalized = name.toLowerCase();
    if (_containsAny(normalized, ['plank', 'gainage', 'planche'])) {
      return const _Movement(_MovementKind.plank, 'Gainage');
    }
    if (_containsAny(normalized, [
      'lunge',
      'fente',
      'split squat',
      'bulgare',
    ])) {
      return const _Movement(_MovementKind.lunge, 'Fente');
    }
    if (_containsAny(normalized, [
      'squat',
      'presse à jambes',
      'leg press',
      'chaise',
    ])) {
      return const _Movement(_MovementKind.squat, 'Flexion des jambes');
    }
    if (_containsAny(normalized, ['curl', 'flexion des bras', 'biceps'])) {
      return const _Movement(_MovementKind.curl, 'Flexion des bras');
    }
    if (_containsAny(normalized, [
      'deadlift',
      'soulevé de terre',
      'hip hinge',
      'good morning',
      'rowing',
      'row',
      'tirage',
    ])) {
      return const _Movement(
        _MovementKind.hinge,
        'Extension du dos et des hanches',
      );
    }
    if (_containsAny(normalized, [
      'push-up',
      'push up',
      'pompe',
      'bench press',
      'développé',
      'press',
      'pompes',
    ])) {
      return const _Movement(_MovementKind.push, 'Poussée des bras');
    }
    return switch (muscle) {
      Muscle.chest ||
      Muscle.shoulders ||
      Muscle.triceps => const _Movement(_MovementKind.push, 'Poussée des bras'),
      Muscle.biceps => const _Movement(_MovementKind.curl, 'Flexion des bras'),
      Muscle.back || Muscle.hamstrings || Muscle.glutes => const _Movement(
        _MovementKind.hinge,
        'Extension du dos et des hanches',
      ),
      Muscle.abs => const _Movement(_MovementKind.plank, 'Gainage'),
      Muscle.quads || Muscle.calves => const _Movement(
        _MovementKind.squat,
        'Flexion des jambes',
      ),
      Muscle.cardio => const _Movement(
        _MovementKind.cardio,
        'Course sur place',
      ),
      Muscle.fullBody => const _Movement(
        _MovementKind.squat,
        'Mouvement complet',
      ),
    };
  }

  static bool _containsAny(String text, List<String> terms) =>
      terms.any(text.contains);
}

class _AvatarPainter extends CustomPainter {
  const _AvatarPainter({
    required this.progress,
    required this.movement,
    required this.muscle,
  });

  final double progress;
  final _Movement movement;
  final Muscle muscle;

  static const _standing = [
    Offset(100, 25),
    Offset(100, 47),
    Offset(78, 53),
    Offset(122, 53),
    Offset(65, 75),
    Offset(135, 75),
    Offset(62, 96),
    Offset(138, 96),
    Offset(100, 105),
    Offset(82, 137),
    Offset(118, 137),
    Offset(78, 172),
    Offset(122, 172),
  ];

  static const _squat = [
    Offset(100, 43),
    Offset(100, 63),
    Offset(78, 68),
    Offset(122, 68),
    Offset(65, 89),
    Offset(135, 89),
    Offset(65, 109),
    Offset(135, 109),
    Offset(100, 120),
    Offset(67, 144),
    Offset(133, 144),
    Offset(78, 172),
    Offset(122, 172),
  ];

  static const _lunge = [
    Offset(100, 25),
    Offset(100, 47),
    Offset(78, 53),
    Offset(122, 53),
    Offset(65, 75),
    Offset(135, 75),
    Offset(62, 96),
    Offset(138, 96),
    Offset(100, 105),
    Offset(75, 135),
    Offset(126, 118),
    Offset(72, 172),
    Offset(143, 151),
  ];

  static const _pushUp = [
    Offset(177, 69),
    Offset(153, 77),
    Offset(144, 78),
    Offset(137, 83),
    Offset(133, 97),
    Offset(128, 99),
    Offset(118, 96),
    Offset(116, 100),
    Offset(79, 101),
    Offset(53, 109),
    Offset(43, 111),
    Offset(21, 119),
    Offset(28, 122),
  ];

  static const _pushUpDown = [
    Offset(177, 82),
    Offset(153, 88),
    Offset(144, 88),
    Offset(137, 93),
    Offset(132, 108),
    Offset(128, 110),
    Offset(118, 108),
    Offset(116, 112),
    Offset(79, 101),
    Offset(53, 109),
    Offset(43, 111),
    Offset(21, 119),
    Offset(28, 122),
  ];

  static const _curl = [
    Offset(100, 25),
    Offset(100, 47),
    Offset(78, 53),
    Offset(122, 53),
    Offset(66, 75),
    Offset(134, 75),
    Offset(72, 91),
    Offset(128, 91),
    Offset(100, 105),
    Offset(82, 137),
    Offset(118, 137),
    Offset(78, 172),
    Offset(122, 172),
  ];

  static const _curlUp = [
    Offset(100, 25),
    Offset(100, 47),
    Offset(78, 53),
    Offset(122, 53),
    Offset(77, 68),
    Offset(123, 68),
    Offset(91, 52),
    Offset(109, 52),
    Offset(100, 105),
    Offset(82, 137),
    Offset(118, 137),
    Offset(78, 172),
    Offset(122, 172),
  ];

  static const _hinge = [
    Offset(100, 42),
    Offset(100, 62),
    Offset(78, 67),
    Offset(122, 67),
    Offset(65, 85),
    Offset(135, 85),
    Offset(63, 105),
    Offset(137, 105),
    Offset(100, 118),
    Offset(80, 145),
    Offset(120, 145),
    Offset(78, 172),
    Offset(122, 172),
  ];

  static const _plank = [
    Offset(177, 70),
    Offset(153, 78),
    Offset(145, 80),
    Offset(138, 84),
    Offset(132, 100),
    Offset(128, 100),
    Offset(119, 101),
    Offset(116, 104),
    Offset(80, 103),
    Offset(53, 110),
    Offset(43, 112),
    Offset(21, 120),
    Offset(28, 123),
  ];

  static const _run = [
    Offset(100, 25),
    Offset(100, 47),
    Offset(78, 53),
    Offset(122, 53),
    Offset(65, 73),
    Offset(137, 78),
    Offset(57, 91),
    Offset(145, 96),
    Offset(100, 105),
    Offset(77, 133),
    Offset(125, 135),
    Offset(64, 158),
    Offset(145, 166),
  ];

  static const _links = [
    (1, 2),
    (1, 3),
    (2, 3),
    (1, 8),
    (2, 4),
    (4, 6),
    (3, 5),
    (5, 7),
    (8, 9),
    (9, 11),
    (8, 10),
    (10, 12),
  ];

  List<Offset> _poseFor(double t) {
    final end = switch (movement.kind) {
      _MovementKind.squat => _squat,
      _MovementKind.lunge => _lunge,
      _MovementKind.push => _pushUp,
      _MovementKind.curl => _curlUp,
      _MovementKind.hinge => _hinge,
      _MovementKind.plank => _plank,
      _MovementKind.cardio => _run,
    };
    final start = switch (movement.kind) {
      _MovementKind.push => _pushUpDown,
      _MovementKind.curl => _curl,
      _MovementKind.plank => _plank,
      _MovementKind.cardio => _standing,
      _ => _standing,
    };
    final phase = movement.kind == _MovementKind.plank
        ? 0.5 + (t - 0.5) * 0.08
        : t;
    return [
      for (var i = 0; i < start.length; i++)
        Offset.lerp(start[i], end[i], phase)!,
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width / 200, size.height / 190);
    final origin = Offset(
      (size.width - 200 * scale) / 2,
      (size.height - 190 * scale) / 2,
    );
    canvas
      ..save()
      ..translate(origin.dx, origin.dy)
      ..scale(scale);

    final ground = Paint()
      ..color = AppColors.navyMuted.withValues(alpha: 0.45)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(18, 180), const Offset(182, 180), ground);

    final points = _poseFor(progress);
    final body = Paint()
      ..color = AppColors.white
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final (from, to) in _links) {
      canvas.drawLine(points[from], points[to], body);
    }
    canvas.drawLine(points[0], points[1], body);
    canvas.drawCircle(points[0], 10, Paint()..color = AppColors.gold);

    final active = Paint()
      ..color = AppColors.gold
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    for (final (from, to) in _highlightedLinks) {
      canvas.drawLine(points[from], points[to], active);
    }
    for (final index in _highlightedJoints) {
      canvas.drawCircle(points[index], 5.5, Paint()..color = AppColors.gold);
    }
    canvas.restore();
  }

  List<(int, int)> get _highlightedLinks => switch (muscle) {
    Muscle.chest => [(2, 3), (2, 4), (3, 5)],
    Muscle.back => [(1, 8), (2, 4), (3, 5)],
    Muscle.shoulders => [(1, 2), (1, 3), (2, 4), (3, 5)],
    Muscle.biceps => [(2, 4), (3, 5)],
    Muscle.triceps => [(4, 6), (5, 7)],
    Muscle.quads => [(8, 9), (8, 10)],
    Muscle.hamstrings || Muscle.glutes => [(8, 9), (8, 10)],
    Muscle.calves => [(9, 11), (10, 12)],
    Muscle.abs => [(1, 8)],
    Muscle.fullBody || Muscle.cardio => [(2, 4), (3, 5), (8, 9), (8, 10)],
  };

  List<int> get _highlightedJoints => switch (muscle) {
    Muscle.chest => [2, 3],
    Muscle.back || Muscle.abs => [8],
    Muscle.shoulders => [2, 3],
    Muscle.biceps => [4, 5],
    Muscle.triceps => [4, 5],
    Muscle.quads => [9, 10],
    Muscle.hamstrings || Muscle.glutes => [8],
    Muscle.calves => [11, 12],
    Muscle.fullBody || Muscle.cardio => [4, 5, 9, 10],
  };

  @override
  bool shouldRepaint(covariant _AvatarPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.movement.kind != movement.kind ||
      oldDelegate.muscle != muscle;
}
