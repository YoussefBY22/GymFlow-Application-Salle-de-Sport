// Niveau : unitaire et intégration (sans réseau). Messagerie entre amis :
// envoi sans limite, réception en direct, notifications, « vu » et « en train
// d'écrire » avec réciprocité, suppression, archivage, silence, blocage
// discret, signalements et écran administrateur. Deux « téléphones » reliés
// par un faux serveur qui reproduit les règles de la base Supabase.
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/models/chat.dart';
import 'package:gymflow/models/friends.dart';
import 'package:gymflow/services/platform/platform_services.dart';

import 'friends_fake.dart';
import 'friends_helpers.dart';
import 'helpers.dart';

Iterable<String> titles(Phone p) =>
    p.b.notifications.mine().map((n) => n.title);

void main() {
  group('Envoi et réception', () {
    test('un message apparaît tout de suite puis passe à « envoyé »', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      final nId = friendIdOf(a);
      await a.b.chat.open(nId);

      final pending = a.b.chat.send(nId, 'Salut !');
      expect(a.b.chat.thread(nId).messages.single.state, SendState.sending);
      await pending;

      final m = a.b.chat.thread(nId).messages.single;
      expect(m.state, SendState.sent);
      expect(m.text, 'Salut !');
      expect(m.mine, isTrue);
      expect(m.isLocal, isFalse);
    });

    test('l\'autre le reçoit en direct dans la discussion ouverte', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      final aId = friendIdOf(n);
      await n.b.chat.open(aId);
      n.b.chat.setActive(aId);

      await a.b.chat.send(nId, 'Tu viens à la salle ?');
      await flush();

      final got = n.b.chat.thread(aId).messages;
      expect(got.length, 1);
      expect(got.single.text, 'Tu viens à la salle ?');
      expect(got.single.mine, isFalse);
    });

    test('discussion pas à l\'écran : notification et non-lu', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      await a.b.chat.send(nId, 'Coucou');
      await flush();

      final who = a.b.auth.currentUser!.fullName;
      expect(titles(n), contains(who));
      expect(n.b.notifications.mine().map((x) => x.body), contains('Coucou'));
      expect((n.b.notifier as RecordingNotifier).shown, contains(who));
      expect(n.b.chat.unreadTotal, 1);
      expect(n.b.chat.conversations.single.unread, 1);
    });

    test('discussion à l\'écran : pas de notification, déjà lu', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      final aId = friendIdOf(n);
      await n.b.chat.open(aId);
      n.b.chat.setActive(aId);

      await a.b.chat.send(nId, 'Coucou');
      await flush();

      final who = a.b.auth.currentUser!.fullName;
      expect(titles(n), isNot(contains(who)));
      expect(n.b.chat.unreadTotal, 0);
    });

    test('aucune limite d\'envoi : 60 messages d\'affilée', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      final nId = friendIdOf(a);
      for (var i = 0; i < 60; i++) {
        await a.b.chat.send(nId, 'message $i');
      }
      expect(server.messageCount, 60);
      expect(
        a.b.chat.thread(nId).messages.every((m) => m.state == SendState.sent),
        isTrue,
      );
    });

    test('un message vide est ignoré, un message trop long refusé', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      final nId = friendIdOf(a);
      await a.b.chat.send(nId, '   ');
      expect(server.messageCount, 0);
      await expectLater(
        a.b.chat.send(nId, 'x' * 1001),
        throwsA(isA<ValidationException>()),
      );
      expect(server.messageCount, 0);
    });

    test('envoi en échec : message « échec », puis réessayer', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      final nId = friendIdOf(a);
      await a.b.chat.open(nId);

      server.failWith = 'panne réseau';
      await expectLater(
        a.b.chat.send(nId, 'Important'),
        throwsA(isA<BusinessRuleException>()),
      );
      final failed = a.b.chat.thread(nId).messages.single;
      expect(failed.state, SendState.failed);

      server.failWith = null;
      await a.b.chat.retry(nId, failed.id);
      final ok = a.b.chat.thread(nId).messages.single;
      expect(ok.state, SendState.sent);
      expect(server.messageCount, 1);
    });

    test('l\'historique se charge par pages', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      final nId = friendIdOf(a);
      for (var i = 0; i < 60; i++) {
        await a.b.chat.send(nId, 'm$i');
      }
      a.b.chat.reset();
      a.b.chat.attach();
      final t = await a.b.chat.open(nId);
      expect(t.messages.length, 50);
      expect(t.messages.last.text, 'm59', reason: 'les plus récents d\'abord');
      expect(t.hasMore, isTrue);
      await a.b.chat.loadMore(nId);
      expect(t.messages.length, 60);
      expect(t.messages.first.text, 'm0');
      expect(t.hasMore, isFalse);
      final texts = t.messages.map((m) => m.text).toList();
      expect(texts, [
        for (var i = 0; i < 60; i++) 'm$i',
      ], reason: 'dans l\'ordre');
    });

    test(
      'un message reçu pendant l\'absence est là à la reconnexion',
      () async {
        final server = FakeFriendsServer();
        final (a, n) = await friendsPair(server);
        final nId = friendIdOf(a);
        await n.b.auth.logout();
        await flush();
        await a.b.chat.send(nId, 'Tu es là ?');
        await flush();

        await loginAs(n.b, kNour);
        await flush();
        expect(n.b.chat.unreadTotal, 1);
        final t = await n.b.chat.open(friendIdOf(n));
        expect(t.messages.single.text, 'Tu es là ?');
      },
    );
  });

  group('« Vu » et « en train d\'écrire »', () {
    test('« Vu » apparaît quand l\'autre ouvre la discussion', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      final aId = friendIdOf(n);
      await a.b.chat.open(nId);
      await a.b.chat.send(nId, 'Salut');
      final sentAt = a.b.chat.thread(nId).messages.single.createdAt;
      expect(a.b.chat.thread(nId).info.peerReadAt, isNull);

      await n.b.chat.open(aId);
      await flush();
      final seen = a.b.chat.thread(nId).info.peerReadAt;
      expect(seen, isNotNull);
      expect(seen!.isBefore(sentAt), isFalse);
    });

    test('si l\'autre masque ses « vu », je n\'en vois pas', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      final aId = friendIdOf(n);
      await n.b.friends.setChatSettings(hideReadReceipts: true);
      await a.b.chat.open(nId);
      await a.b.chat.send(nId, 'Salut');
      await n.b.chat.open(aId);
      await flush();
      expect(a.b.chat.thread(nId).info.peerReadAt, isNull);
    });

    test(
      'réciprocité : si je masque les miens, je ne vois plus ceux des autres',
      () async {
        final server = FakeFriendsServer();
        final (a, n) = await friendsPair(server);
        final nId = friendIdOf(a);
        final aId = friendIdOf(n);
        await a.b.friends.setChatSettings(hideReadReceipts: true);
        await a.b.chat.open(nId);
        await a.b.chat.send(nId, 'Salut');
        await n.b.chat.open(aId);
        await flush();
        // Nour (qui n'a rien masqué) a lu, mais Ahmed ne le voit pas.
        expect(a.b.chat.thread(nId).info.peerReadAt, isNull);
        // Et Ahmed, qui masque, ne laisse pas de « vu » à Nour.
        await n.b.chat.send(aId, 'Réponse');
        await a.b.chat.open(nId);
        await flush();
        expect(n.b.chat.thread(aId).info.peerReadAt, isNull);
      },
    );

    test('« en train d\'écrire » est visible de l\'autre', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      final aId = friendIdOf(n);
      await n.b.chat.open(aId);
      a.b.chat.userTyping(nId, true);
      await flush();
      expect(n.b.chat.thread(aId).peerTyping, isTrue);

      // Quand le message arrive, l'indicateur disparaît.
      await a.b.chat.send(nId, 'Voilà');
      await flush();
      expect(n.b.chat.thread(aId).peerTyping, isFalse);
    });

    test('effacer le texte arrête l\'indicateur', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      final aId = friendIdOf(n);
      await n.b.chat.open(aId);
      a.b.chat.userTyping(nId, true);
      await flush();
      expect(n.b.chat.thread(aId).peerTyping, isTrue);
      a.b.chat.userTyping(nId, false);
      await flush();
      expect(n.b.chat.thread(aId).peerTyping, isFalse);
    });

    test(
      'masquer « en train d\'écrire » : rien n\'est envoyé ni reçu',
      () async {
        final server = FakeFriendsServer();
        final (a, n) = await friendsPair(server);
        final nId = friendIdOf(a);
        final aId = friendIdOf(n);
        await n.b.chat.open(aId);
        await a.b.chat.open(nId);

        // Ahmed masque : il n'envoie rien.
        await a.b.friends.setChatSettings(hideTyping: true);
        a.b.chat.userTyping(nId, true);
        await flush();
        expect(a.r.calls['setTyping'], isNull);
        expect(n.b.chat.thread(aId).peerTyping, isFalse);

        // Nour écrit : Ahmed ne le voit pas (réciprocité).
        n.b.chat.userTyping(aId, true);
        await flush();
        expect(a.b.chat.thread(nId).peerTyping, isFalse);
      },
    );
  });

  group('Suppression, archivage et silence', () {
    test('supprimer un message pour moi : l\'autre le garde', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      final aId = friendIdOf(n);
      await a.b.chat.send(nId, 'Premier');
      await flush();
      final ta = await a.b.chat.open(nId);
      await a.b.chat.delete(nId, ta.messages.single, forAll: false);
      expect(a.b.chat.thread(nId).messages, isEmpty);

      final tn = await n.b.chat.open(aId);
      expect(tn.messages.single.text, 'Premier');
    });

    test(
      'supprimer pour tout le monde : une trace reste des deux côtés',
      () async {
        final server = FakeFriendsServer();
        final (a, n) = await friendsPair(server);
        final nId = friendIdOf(a);
        final aId = friendIdOf(n);
        await n.b.chat.open(aId);
        n.b.chat.setActive(aId);
        await a.b.chat.send(nId, 'Oups, mauvais ami');
        await flush();
        final mine = a.b.chat.thread(nId).messages.single;

        await a.b.chat.delete(nId, mine, forAll: true);
        await flush();

        final mineAfter = a.b.chat.thread(nId).messages.single;
        expect(mineAfter.deleted, isTrue);
        expect(mineAfter.text, isNull);
        expect(mineAfter.preview, 'Message supprimé');
        final theirs = n.b.chat.thread(aId).messages.single;
        expect(theirs.deleted, isTrue);
        expect(theirs.text, isNull);
        expect(
          server.storedBodies.every((b) => !b.contains('Oups')),
          isTrue,
          reason: 'le contenu est effacé du serveur',
        );
      },
    );

    test('seul l\'auteur peut supprimer pour tout le monde', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      final aId = friendIdOf(n);
      await a.b.chat.send(nId, 'Bonjour');
      await flush();
      final tn = await n.b.chat.open(aId);
      await expectLater(
        n.b.chat.delete(aId, tn.messages.single, forAll: true),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('supprimer la discussion : pour moi seulement', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      final aId = friendIdOf(n);
      await a.b.chat.send(nId, 'Un');
      await a.b.chat.send(nId, 'Deux');
      await flush();
      await a.b.chat.refreshConversations();
      expect(a.b.chat.conversations.length, 1);

      await a.b.chat.clear(nId);
      expect(a.b.chat.conversations, isEmpty);
      expect((await a.b.chat.open(nId)).messages, isEmpty);

      final tn = await n.b.chat.open(aId);
      expect(tn.messages.length, 2, reason: 'l\'autre garde la sienne');

      // Un nouveau message revient, sans l'ancien historique.
      await n.b.chat.send(aId, 'Trois');
      await flush();
      expect((await a.b.chat.open(nId)).messages.map((m) => m.text), ['Trois']);
    });

    test(
      'archiver : la discussion quitte la liste, un message la ramène',
      () async {
        final server = FakeFriendsServer();
        final (a, n) = await friendsPair(server);
        final nId = friendIdOf(a);
        final aId = friendIdOf(n);
        await a.b.chat.send(nId, 'Salut');
        await flush();
        await a.b.chat.refreshConversations();

        await a.b.chat.setArchived(nId, true);
        expect(a.b.chat.conversations, isEmpty);
        expect(a.b.chat.archived.length, 1);

        await n.b.chat.send(aId, 'Tu es là ?');
        await flush();
        expect(
          a.b.chat.archived,
          isEmpty,
          reason: 'désarchivée par le message',
        );
        expect(a.b.chat.conversations.length, 1);
      },
    );

    test(
      'silence : pas de notification, mais le non-lu compte à l\'ouverture',
      () async {
        final server = FakeFriendsServer();
        final (a, n) = await friendsPair(server);
        final nId = friendIdOf(a);
        final aId = friendIdOf(n);
        await a.b.chat.send(nId, 'Premier');
        await flush();
        await n.b.chat.refreshConversations();
        await n.b.chat.setMuted(aId, true);
        final before = titles(n).length;

        await a.b.chat.send(nId, 'Deuxième');
        await flush();
        expect(titles(n).length, before, reason: 'discussion en silence');
        expect(n.b.chat.conversations.single.muted, isTrue);
        expect(
          n.b.chat.unreadTotal,
          0,
          reason: 'le silence masque la pastille',
        );
      },
    );
  });

  group('Blocage discret', () {
    test('bloquer : l\'amitié disparaît des deux côtés', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      await a.b.chat.send(nId, 'Salut');
      await flush();

      await a.b.chat.block(nId);
      await flush();
      expect(a.b.friends.friends, isEmpty);
      expect(n.b.friends.friends, isEmpty);
      expect(a.b.chat.conversations, isEmpty);
      expect(n.b.chat.conversations, isEmpty);
    });

    test('seul celui qui bloque le sait', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      await a.b.chat.block(friendIdOf(a));
      await flush();
      await a.b.chat.refreshBlocks();
      await n.b.chat.refreshBlocks();
      expect(a.b.chat.blocks.length, 1);
      expect(
        n.b.chat.blocks,
        isEmpty,
        reason: 'l\'autre ne voit aucun blocage',
      );
    });

    test('la personne bloquée croit que son invitation est partie', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      await a.b.chat.block(friendIdOf(a));
      await flush();

      final result = await n.b.friends.sendRequest(kAhmed);
      await flush();
      expect(result, SendResult.sent);
      expect(
        n.b.friends.sentRequests.length,
        1,
        reason: 'en attente pour elle',
      );
      expect(a.b.friends.requests, isEmpty, reason: 'jamais reçue');
    });

    test('inviter quelqu\'un qu\'on a bloqué : message clair', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      await a.b.chat.block(friendIdOf(a));
      await flush();
      await expectLater(
        a.b.friends.sendRequest(kNour),
        throwsA(
          isA<BusinessRuleException>().having(
            (e) => e.message,
            'message',
            contains('Vous avez bloqué'),
          ),
        ),
      );
    });

    test('débloquer permet de se réinviter', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      final nId = friendIdOf(a);
      await a.b.chat.block(nId);
      await flush();
      await a.b.chat.unblock(nId);
      expect(a.b.chat.blocks, isEmpty);
      expect(await a.b.friends.sendRequest(kNour), SendResult.sent);
    });
  });

  group('Signalements', () {
    test('signaler une discussion exige au moins un message', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      await expectLater(
        a.b.chat.reportConversation(friendIdOf(a), const []),
        throwsA(isA<ValidationException>()),
      );
      expect(server.reportCount, 0);
      expect(n.b.friends.friends.length, 1);
    });

    test('signaler : messages choisis, remarque facultative', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      await n.b.chat.send(friendIdOf(n), 'Premier message');
      await n.b.chat.send(friendIdOf(n), 'Insulte');
      await a.b.chat.send(nId, 'Réponse');
      await flush();
      final t = await a.b.chat.open(nId);
      final chosen = [t.messages[1].id, t.messages[2].id];

      await a.b.chat.reportConversation(nId, chosen);
      expect(server.reportCount, 1);

      // L'administrateur voit seulement les messages choisis.
      final admin = server.phone();
      final ab = await makeBackend(friendsRemote: admin);
      addTearDown(() {
        ab.friends.stop();
        ab.chat.stop();
      });
      await ab.auth.login('admin@gymflow.tn', 'Admin2026!');
      await ab.moderation.connect('Admin2026!');
      final r = ab.moderation.reports.single;
      expect(r.isConversation, isTrue);
      expect(r.remark, isNull, reason: 'remarque facultative');
      expect(r.messages.map((m) => m.text), ['Insulte', 'Réponse']);
      expect(r.reporterName, a.b.auth.currentUser!.fullName);
      expect(r.reportedName, n.b.auth.currentUser!.fullName);
    });

    test('la personne signalée n\'en sait rien', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final nId = friendIdOf(a);
      await a.b.chat.send(nId, 'Un message');
      await flush();
      final t = await a.b.chat.open(nId);
      final before = titles(n).length;
      await a.b.chat.reportConversation(nId, [
        t.messages.single.id,
      ], remark: 'Harcèlement');
      await flush();
      expect(titles(n).length, before);
      expect(n.b.friends.friends.length, 1, reason: 'rien ne change pour elle');
    });

    test('remarque enregistrée, et « bloquer aussi » bloque', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      final nId = friendIdOf(a);
      await a.b.chat.send(nId, 'Un message');
      final t = await a.b.chat.open(nId);
      await a.b.chat.reportConversation(
        nId,
        [t.messages.single.id],
        remark: '  Il me harcèle  ',
        alsoBlock: true,
      );
      await flush();
      expect(server.blockCount, 1);
      expect(a.b.friends.friends, isEmpty);

      final admin = server.phone();
      final ab = await makeBackend(friendsRemote: admin);
      addTearDown(() {
        ab.friends.stop();
        ab.chat.stop();
      });
      await ab.auth.login('admin@gymflow.tn', 'Admin2026!');
      await ab.moderation.connect('Admin2026!');
      expect(ab.moderation.reports.single.remark, 'Il me harcèle');
    });

    test(
      'signaler une personne : motif obligatoire, distinct de la discussion',
      () async {
        final server = FakeFriendsServer();
        final (a, _) = await friendsPair(server);
        final nId = friendIdOf(a);
        await expectLater(
          a.b.chat.reportPerson(nId, 'x'),
          throwsA(isA<ValidationException>()),
        );
        await a.b.chat.reportPerson(nId, 'Photo de profil inappropriée');

        final admin = server.phone();
        final ab = await makeBackend(friendsRemote: admin);
        addTearDown(() {
          ab.friends.stop();
          ab.chat.stop();
        });
        await ab.auth.login('admin@gymflow.tn', 'Admin2026!');
        await ab.moderation.connect('Admin2026!');
        final r = ab.moderation.reports.single;
        expect(r.isConversation, isFalse);
        expect(r.messages, isEmpty);
        expect(r.remark, 'Photo de profil inappropriée');
      },
    );
  });

  group('Écran administrateur', () {
    Future<dynamic> adminBackend(FakeFriendsServer server) async {
      final ab = await makeBackend(friendsRemote: server.phone());
      addTearDown(() {
        ab.friends.stop();
        ab.chat.stop();
      });
      await ab.auth.login('admin@gymflow.tn', 'Admin2026!');
      return ab;
    }

    test('un mauvais mot de passe est refusé', () async {
      final ab = await adminBackend(FakeFriendsServer());
      await expectLater(
        ab.moderation.connect('faux'),
        throwsA(isA<ValidationException>()),
      );
      expect(ab.moderation.connected, isFalse);
    });

    test('un abonné ne peut pas lire les signalements', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      await expectLater(
        a.b.moderation.connect(kPwd),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(
        () => a.r.adminLoadReports(),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('traiter un signalement : le compteur baisse', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      await a.b.chat.reportPerson(friendIdOf(a), 'Comportement gênant');
      final ab = await adminBackend(server);
      await ab.moderation.connect('Admin2026!');
      expect(ab.moderation.newCount, 1);
      await ab.moderation.handle(
        ab.moderation.reports.single,
        note: 'Vu, averti',
      );
      expect(ab.moderation.newCount, 0);
      final r = ab.moderation.reports.single;
      expect(r.handled, isTrue);
      expect(r.handledNote, 'Vu, averti');
    });

    test('déconnexion : plus rien n\'est gardé', () async {
      final server = FakeFriendsServer();
      final ab = await adminBackend(server);
      await ab.moderation.connect('Admin2026!');
      expect(ab.moderation.connected, isTrue);
      await ab.auth.logout();
      expect(ab.moderation.connected, isFalse);
      expect(ab.moderation.reports, isEmpty);
    });
  });

  group('Réglages et départ', () {
    test('les réglages sont gardés d\'une connexion à l\'autre', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      await a.b.friends.setChatSettings(
        hideReadReceipts: true,
        hideTyping: true,
        pushPreview: false,
      );
      await a.b.auth.logout();
      await loginAs(a.b, kAhmed);
      await flush();
      final s = a.b.friends.settings;
      expect(s.hideReadReceipts, isTrue);
      expect(s.hideTyping, isTrue);
      expect(s.pushPreview, isFalse);
    });

    test('désactiver la fonction efface les messages du serveur', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      await a.b.chat.send(friendIdOf(a), 'Salut');
      await flush();
      expect(server.messageCount, 1);
      await n.b.friends.disable();
      expect(server.messageCount, 0);
      expect(n.b.chat.conversations, isEmpty);
    });
  });

  group('Modèles', () {
    test('aperçu : texte, supprimé, carte partagée', () {
      final now = DateTime.utc(2026, 11, 3);
      ChatMessage msg({String? text, bool deleted = false, MessageKind? k}) =>
          ChatMessage(
            id: 'x',
            peerId: 'p',
            mine: true,
            kind: k ?? MessageKind.text,
            text: text,
            createdAt: now,
            deleted: deleted,
          );
      expect(msg(text: 'Salut').preview, 'Salut');
      expect(msg(deleted: true).preview, 'Message supprimé');
      final card = ShareCard(
        type: 'workout',
        title: 'Pull Day',
        data: const {},
      );
      expect(
        msg(text: card.encode(), k: MessageKind.share).preview,
        'Workout partagé : Pull Day',
      );
    });

    test('une carte illisible ne plante pas', () {
      expect(ShareCard.tryParse('pas du json'), isNull);
      expect(ShareCard.tryParse('{"type":"inconnu"}'), isNull);
      expect(ShareCard.tryParse('[]'), isNull);
    });
  });
}
