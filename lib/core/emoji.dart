import 'package:characters/characters.dart';

import 'animated_emoji_data.dart';

/// Outils sur les emojis des messages.
///
/// Un message qui ne contient que des emojis s'affiche en grand ; s'il n'en
/// contient qu'un et que Google en propose une version animée (Noto Emoji
/// Animation, licence libre), l'application l'affiche animé, avec l'emoji
/// normal en repli (hors connexion, ou emoji sans version animée).
class Emojis {
  Emojis._();

  /// Réactions rapides proposées dans la discussion (toutes animées).
  static const quickReactions = [
    '🔥',
    '💪',
    '🎉',
    '👏',
    '😂',
    '❤️',
    '👍',
    '🏆',
    '🙌',
    '😎',
    '🤩',
    '💯',
    '🚀',
    '😅',
  ];

  static bool _isEmojiRune(int r) =>
      r >= 0x1F000 && r <= 0x1FAFF ||
      r >= 0x2600 && r <= 0x27BF ||
      r >= 0x2300 && r <= 0x23FF ||
      r >= 0x2B00 && r <= 0x2BFF ||
      r == 0x203C ||
      r == 0x2049 ||
      r == 0x2122 ||
      r == 0x2139 ||
      r >= 0x2190 && r <= 0x21FF ||
      r == 0x00A9 ||
      r == 0x00AE ||
      r == 0x3030 ||
      r == 0x303D ||
      r == 0x3297 ||
      r == 0x3299;

  /// Le texte n'est-il fait que d'emojis (1 à 3), sans autre caractère ?
  static bool isEmojiOnly(String text, {int max = 3}) {
    final t = text.trim();
    if (t.isEmpty) return false;
    final clusters = t.characters;
    if (clusters.length > max) return false;
    for (final c in clusters) {
      final runes = c.runes.toList();
      if (!runes.any(_isEmojiRune)) return false;
      // Un chiffre ou une lettre suivi d'un sélecteur n'est pas un emoji ici.
      if (runes.every((r) => r < 0x2000 && r != 0xA9 && r != 0xAE)) {
        return false;
      }
    }
    return true;
  }

  /// Code Unicode d'un emoji : `1f525`, `2764_fe0f`, `1f62e_200d_1f4a8`.
  static String codepoint(String emoji) =>
      emoji.runes.map((r) => r.toRadixString(16)).join('_');

  /// Adresse de la version animée de [emoji], ou `null` s'il n'en existe pas.
  static String? animatedUrl(String emoji) {
    var cp = codepoint(emoji.trim());
    if (!animatedEmojiCodepoints.contains(cp)) {
      // Variante sans sélecteur de présentation (U+FE0F).
      cp = cp.replaceAll('_fe0f', '');
      if (!animatedEmojiCodepoints.contains(cp)) return null;
    }
    return 'https://fonts.gstatic.com/s/e/notoemoji/latest/$cp/512.webp';
  }
}
