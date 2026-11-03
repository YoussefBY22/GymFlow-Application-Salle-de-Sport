import 'package:characters/characters.dart';
import 'package:flutter/material.dart';

import '../core/emoji.dart';
import 'common.dart';

/// Un emoji, animé quand Google en propose une version animée.
///
/// L'image animée vient de `fonts.gstatic.com` (Noto Emoji Animation). Tant
/// qu'elle charge, hors connexion ou si elle n'existe pas, on affiche
/// l'emoji normal : un message n'est jamais vide.
class EmojiView extends StatelessWidget {
  const EmojiView(this.emoji, {super.key, this.size = 32, this.animated = true});

  final String emoji;
  final double size;

  /// Désactive l'animation (plusieurs emojis côte à côte, listes…).
  final bool animated;

  @override
  Widget build(BuildContext context) {
    final fallback = SizedBox(
      width: size,
      height: size,
      child: FittedBox(
        child: Text(emoji, style: TextStyle(fontSize: size * 0.8)),
      ),
    );
    final url = animated && NetImage.networkEnabled
        ? Emojis.animatedUrl(emoji)
        : null;
    if (url == null) return fallback;
    return Image.network(
      url,
      width: size,
      height: size,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => fallback,
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : fallback,
    );
  }
}

/// Un message fait uniquement d'emojis : affichés en grand, sans bulle ;
/// un seul emoji est animé quand c'est possible.
class EmojiOnlyContent extends StatelessWidget {
  const EmojiOnlyContent(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final list = text.trim().characters.toList();
    final single = list.length == 1;
    return Wrap(
      spacing: 4,
      children: [
        for (final e in list)
          EmojiView(e, size: single ? 88 : 44, animated: single),
      ],
    );
  }
}
