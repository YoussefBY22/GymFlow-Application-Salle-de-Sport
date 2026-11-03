import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'common.dart';

/// Avatar d'un ami avec pastille de présence (verte = en ligne).
class FriendAvatar extends StatelessWidget {
  const FriendAvatar({
    super.key,
    required this.name,
    this.url,
    this.online,
    this.size = 44,
  });

  final String name;
  final String? url;

  /// Diamètre de la photo.
  final double size;

  /// `null` : pas de pastille (demande reçue).
  final bool? online;

  @override
  Widget build(BuildContext context) {
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();
    final color =
        AppColors.accents[name.hashCode.abs() % AppColors.accents.length];
    final avatar = (url != null && url!.startsWith('https://'))
        ? ClipOval(
            child: NetImage(
              url,
              width: size,
              height: size,
              fallbackIcon: Icons.person,
              cacheWidth: size.round() * 2,
            ),
          )
        : CircleAvatar(
            radius: size / 2,
            backgroundColor: color,
            child: Text(
              initials.isEmpty ? '?' : initials,
              style: AppText.subtitle(color: onColor(color), size: 15),
            ),
          );
    final state = online;
    return SizedBox(
      width: size + 4,
      height: size + 4,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: Center(child: avatar)),
          if (state != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: state ? AppColors.success : AppColors.outline,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.white, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
