// Niveau : unitaire et intégration (sans réseau). Partage d'une séance, d'un
// workout, d'un exercice ou d'un programme dans une discussion : instantané
// en texte, aperçu et enregistrement d'une copie privée.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/models/chat.dart';

import 'friends_fake.dart';
import 'friends_helpers.dart';

void main() {
  group('Cartes de partage', () {
    test('une séance : résumé sans note personnelle ni image', () async {
      final (a, _) = await friendsPair(FakeFriendsServer());
      final s = a.b.share.mySessions().first;
      final card = a.b.share.sessionCard(s);
      expect(card.type, 'session');
      expect(card.title, s.title);
      final json = card.encode();
      expect(json, contains('"sets"'));
      expect(json, isNot(contains('note')));
      expect(
        json.toLowerCase(),
        isNot(contains('http')),
        reason: 'aucun média',
      );
      expect(a.b.share.canSave(card), isFalse);
    });

    test('un workout : exercices uniques et séries', () async {
      final (a, _) = await friendsPair(FakeFriendsServer());
      final w = a.b.share.workouts().first;
      final card = a.b.share.workoutCard(w);
      final data = card.data;
      final items = data['items'] as List;
      final exercises = data['exercises'] as List;
      expect(items, isNotEmpty);
      expect(
        exercises.map((e) => (e as Map)['name']).toSet().length,
        exercises.length,
        reason: 'chaque exercice une seule fois',
      );
      for (final i in items) {
        expect((i as Map)['e'], lessThan(exercises.length));
      }
      expect(card.encode().toLowerCase(), isNot(contains('http')));
    });

    test('un exercice : description, étapes, aucun média', () async {
      final (a, _) = await friendsPair(FakeFriendsServer());
      final e = a.b.share.exercises().first;
      final card = a.b.share.exerciseCard(e);
      expect(card.data['name'], e.name);
      expect(card.encode(), isNot(contains('"media')));
    });

    test('un programme : jours et workouts', () async {
      final (a, _) = await friendsPair(FakeFriendsServer());
      final p = a.b.share.programs().first;
      final card = a.b.share.programCard(p);
      expect((card.data['days'] as List), isNotEmpty);
      expect(card.data['weeks'], p.weeks);
    });

    test('tous les programmes et workouts tiennent dans un message', () async {
      final (a, _) = await friendsPair(FakeFriendsServer());
      for (final p in a.b.share.programs()) {
        expect(
          a.b.share.programCard(p).encode().length,
          lessThan(60000),
          reason: p.name,
        );
      }
      for (final w in a.b.share.workouts()) {
        expect(a.b.share.workoutCard(w).encode().length, lessThan(60000));
      }
    });

    test('la carte survit à l\'aller-retour en texte', () async {
      final (a, _) = await friendsPair(FakeFriendsServer());
      final card = a.b.share.workoutCard(a.b.share.workouts().first);
      final back = ShareCard.tryParse(card.encode())!;
      expect(back.type, 'workout');
      expect(back.title, card.title);
      expect(jsonEncode(back.data), jsonEncode(card.data));
    });
  });

  group('Envoi dans une discussion', () {
    test('l\'ami reçoit la carte, lisible, avec un aperçu', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final card = a.b.share.workoutCard(a.b.share.workouts().first);
      final nId = friendIdOf(a);
      final aId = friendIdOf(n);
      await n.b.chat.open(aId);
      await a.b.chat.send(nId, card.encode(), kind: MessageKind.share);
      await flush();

      final got = n.b.chat.thread(aId).messages.single;
      expect(got.kind, MessageKind.share);
      expect(got.share!.title, card.title);
      expect(got.preview, 'Workout partagé : ${card.title}');
      expect(
        n.b.chat.conversations.single.lastPreview,
        'Workout partagé : ${card.title}',
      );
    });
  });

  group('Enregistrer chez moi', () {
    test('un workout devient une copie privée, exercices réutilisés', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final card = a.b.share.workoutCard(a.b.share.workouts().first);
      final exercisesBefore = n.b.exercises.all.length;
      final workoutsBefore = n.b.workouts.all.length;

      final msg = await n.b.share.save(card);

      expect(msg, contains(card.title));
      expect(n.b.workouts.all.length, workoutsBefore + 1);
      expect(
        n.b.exercises.all.length,
        exercisesBefore,
        reason: 'mêmes exercices du club : rien de recréé',
      );
      final saved = n.b.workouts.all.firstWhere(
        (w) => w.name == card.title && w.authorId == n.b.auth.currentUser!.id,
      );
      expect(saved.isPrivate, isTrue);
      expect(saved.items.length, (card.data['items'] as List).length);
      expect(saved.coverImage, isNull, reason: 'pas de photo');
    });

    test('un exercice inconnu est créé en privé, puis réutilisé', () async {
      final server = FakeFriendsServer();
      final (_, n) = await friendsPair(server);
      final card = ShareCard(
        type: 'exercise',
        title: 'Pompes du dimanche',
        data: const {
          'name': 'Pompes du dimanche',
          'muscle': 'chest',
          'equipment': 'bodyweight',
          'level': 'beginner',
          'type': 'strength',
          'description': 'Des pompes, comme le dimanche matin.',
          'steps': ['Descendre', 'Remonter'],
          'mistakes': <String>[],
          'breathing': '',
          'secondary': <String>[],
        },
      );
      final before = n.b.exercises.all.length;
      await n.b.share.save(card);
      expect(n.b.exercises.all.length, before + 1);
      final created = n.b.exercises.all.firstWhere(
        (e) => e.name == 'Pompes du dimanche',
      );
      expect(created.publication.isPublished, isFalse, reason: 'privé');
      expect(created.steps, ['Descendre', 'Remonter']);

      await n.b.share.save(card);
      expect(n.b.exercises.all.length, before + 1, reason: 'pas de doublon');
    });

    test('un programme crée ses workouts et le programme, en privé', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final p = a.b.share.programs().first;
      final card = a.b.share.programCard(p);
      final programsBefore = n.b.programs.all.length;
      final workoutsBefore = n.b.workouts.all.length;

      final msg = await n.b.share.save(card);

      expect(msg, contains(p.name));
      expect(n.b.programs.all.length, programsBefore + 1);
      final days = (card.data['days'] as List).length;
      expect(n.b.workouts.all.length, workoutsBefore + days);
      final saved = n.b.programs.all.firstWhere(
        (x) => x.authorId == n.b.auth.currentUser!.id && x.name == p.name,
      );
      expect(saved.isPrivate, isTrue);
      expect(saved.days.length, days);
      for (final d in saved.days) {
        expect(n.b.workouts.byId(d.workoutId), isNotNull);
      }
    });

    test('une séance partagée est un résumé : pas enregistrable', () async {
      final (a, n) = await friendsPair(FakeFriendsServer());
      final card = a.b.share.sessionCard(a.b.share.mySessions().first);
      await expectLater(
        n.b.share.save(card),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('un workout sans exercice lisible est refusé', () async {
      final (_, n) = await friendsPair(FakeFriendsServer());
      const card = ShareCard(
        type: 'workout',
        title: 'Vide',
        data: {'name': 'Vide', 'exercises': [], 'items': []},
      );
      await expectLater(
        n.b.share.save(card),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('des valeurs hors limites sont ramenées dans les bornes', () async {
      final (_, n) = await friendsPair(FakeFriendsServer());
      const card = ShareCard(
        type: 'workout',
        title: 'Bornes',
        data: {
          'name': 'Bornes',
          'description': '',
          'level': 'inconnu',
          'goal': 'inconnu',
          'exercises': [
            {
              'name': 'Squat bizarre',
              'muscle': 'inconnu',
              'equipment': 'inconnu',
              'level': 'beginner',
              'type': 'strength',
              'description': 'Un squat un peu particulier.',
            },
          ],
          'items': [
            {'e': 0, 'sets': 99, 'reps': 10, 'rest': 99999},
          ],
        },
      );
      await n.b.share.save(card);
      final w = n.b.workouts.all.firstWhere((w) => w.name == 'Bornes');
      expect(w.items.single.sets, 10);
      expect(w.items.single.restSec, 600);
    });
  });
}
