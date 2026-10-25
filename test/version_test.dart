// Niveau : unitaire. La version affichée dans l'application doit toujours
// correspondre à celle de pubspec.yaml. Sans ce test, un oubli ferait
// afficher une version fausse, ce qui est pire que de ne rien afficher :
// on croirait avoir la bonne version installée.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/config.dart';

void main() {
  group('Version de l\'application', () {
    late String pubspecVersion;

    setUpAll(() {
      final ligne = File('pubspec.yaml')
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('version:'));
      // « version: 2.1.0+3 » → « 2.1.0 »
      pubspecVersion = ligne.split(':')[1].trim().split('+').first;
    });

    test('la version complète correspond à pubspec.yaml', () {
      expect(
        AppConfig.appVersionFull,
        pubspecVersion,
        reason:
            'AppConfig.appVersionFull doit être mis à jour en même temps '
            'que version: dans pubspec.yaml',
      );
    });

    test('la version courte est le début de la version complète', () {
      expect(AppConfig.appVersionFull, startsWith(AppConfig.appVersion));
    });

    test('le format reste lisible (chiffres et points)', () {
      expect(AppConfig.appVersion, matches(RegExp(r'^\d+\.\d+$')));
      expect(AppConfig.appVersionFull, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    });

    test('le numéro de build est incrémenté avec la version', () {
      final ligne = File('pubspec.yaml')
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('version:'));
      final build = int.parse(ligne.split('+').last.trim());
      expect(
        build,
        greaterThan(1),
        reason: 'Android refuse d\'installer par-dessus sans build supérieur',
      );
    });
  });
}
