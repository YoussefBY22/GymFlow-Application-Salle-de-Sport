// Niveau : unitaire. Outils d'emojis : code Unicode, détection des messages
// faits uniquement d'emojis, adresse de la version animée (liste officielle
// de Google), réactions rapides.
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/animated_emoji_data.dart';
import 'package:gymflow/core/emoji.dart';

void main() {
  group('Code Unicode', () {
    test('emoji simple, avec sélecteur, séquence', () {
      expect(Emojis.codepoint('🔥'), '1f525');
      expect(Emojis.codepoint('❤️'), '2764_fe0f');
      expect(Emojis.codepoint('😮‍💨'), '1f62e_200d_1f4a8');
    });
  });

  group('Version animée (Noto Emoji Animation)', () {
    test('la liste officielle est embarquée', () {
      expect(animatedEmojiCodepoints.length, 881);
      for (final c in animatedEmojiCodepoints) {
        expect(c, matches(RegExp(r'^[0-9a-f]+(_[0-9a-f]+)*$')), reason: c);
      }
    });

    test('toutes les réactions rapides sont animées', () {
      for (final e in Emojis.quickReactions) {
        expect(Emojis.animatedUrl(e), isNotNull, reason: e);
      }
      expect(
        Emojis.quickReactions.toSet().length,
        Emojis.quickReactions.length,
      );
    });

    test('adresse au bon format', () {
      expect(
        Emojis.animatedUrl('🔥'),
        'https://fonts.gstatic.com/s/e/notoemoji/latest/1f525/512.webp',
      );
      expect(
        Emojis.animatedUrl('❤️'),
        'https://fonts.gstatic.com/s/e/notoemoji/latest/2764_fe0f/512.webp',
      );
    });

    test('un emoji écrit avec un sélecteur en trop retrouve sa version', () {
      // ⚡ est dans la liste sans sélecteur ; le clavier peut en ajouter un.
      expect(Emojis.animatedUrl('⚡'), isNotNull);
      expect(Emojis.animatedUrl('⚡️'), Emojis.animatedUrl('⚡'));
    });

    test('pas de version animée : null (repli sur l\'emoji normal)', () {
      expect(Emojis.animatedUrl('🏋️'), isNull);
      expect(Emojis.animatedUrl('a'), isNull);
      expect(Emojis.animatedUrl(''), isNull);
    });
  });

  group('Message fait uniquement d\'emojis', () {
    test('un à trois emojis', () {
      expect(Emojis.isEmojiOnly('🔥'), isTrue);
      expect(Emojis.isEmojiOnly('🔥💪'), isTrue);
      expect(Emojis.isEmojiOnly('🔥💪🎉'), isTrue);
      expect(Emojis.isEmojiOnly('  🔥  '), isTrue);
    });

    test('plus de trois emojis : un message normal', () {
      expect(Emojis.isEmojiOnly('🔥💪🎉👏'), isFalse);
    });

    test('du texte avec un emoji n\'est pas « emojis seuls »', () {
      expect(Emojis.isEmojiOnly('Salut 🔥'), isFalse);
      expect(Emojis.isEmojiOnly('bravo'), isFalse);
      expect(Emojis.isEmojiOnly('123'), isFalse);
      expect(Emojis.isEmojiOnly('#'), isFalse);
      expect(Emojis.isEmojiOnly(''), isFalse);
      expect(Emojis.isEmojiOnly('   '), isFalse);
    });

    test('teintes de peau, familles et drapeaux comptent pour un emoji', () {
      expect(Emojis.isEmojiOnly('👍🏽'), isTrue);
      expect(Emojis.isEmojiOnly('👨‍👩‍👧'), isTrue);
      expect(Emojis.isEmojiOnly('🇹🇳'), isTrue);
    });
  });
}
