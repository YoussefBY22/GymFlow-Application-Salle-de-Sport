// Niveau : unitaire et intégration (sans réseau). Fonction Amis : activation
// avec consentement, demandes d'ami par e-mail, présence en direct, messages
// (« poke ») et notifications, sur deux « téléphones » reliés par un faux
// serveur qui reproduit les règles de la base Supabase.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/errors.dart';
import 'package:gymflow/models/friends.dart';
import 'package:gymflow/models/privacy.dart';
import 'package:gymflow/services/friends_service.dart';
import 'package:gymflow/services/platform/platform_services.dart';

import 'friends_fake.dart';
import 'friends_helpers.dart';
import 'helpers.dart';

void main() {
  group('Disponibilité et réglage', () {
    test("sans Supabase configuré, la fonction n'est pas disponible", () async {
      final b = await makeBackend();
      await loginAs(b, kAhmed);
      expect(b.friends.available, isFalse);
      expect(b.friends.status, FriendsStatus.unavailable);
    });

    test('désactivée par défaut, y compris sur un ancien compte', () async {
      expect(const PrivacySettings().friends, isFalse);
      expect(PrivacySettings.fromJson(const {}).friends, isFalse);
      final p = await phone(FakeFriendsServer(), kAhmed);
      expect(p.b.auth.currentUser!.privacy.friends, isFalse);
      expect(p.b.friends.status, FriendsStatus.off);
    });

    test(
      'aucun contact avec le serveur tant que la fonction est éteinte',
      () async {
        final server = FakeFriendsServer();
        final p = await phone(server, kAhmed);
        await flush();
        expect(p.r.calls, isEmpty);
        expect(server.accountCount, 0);
      },
    );

    test('un mineur ne peut pas l\'activer', () async {
      final server = FakeFriendsServer();
      final p = await phone(server, kNour);
      final nour = p.b.users.byId('u_nour')!;
      await p.b.users.save(nour.copyWith(age: 16));
      p.b.auth.refreshCurrent();
      await expectLater(
        p.b.friends.enable(kPwd),
        throwsA(isA<BusinessRuleException>()),
      );
      expect(server.accountCount, 0);
      expect(p.b.auth.currentUser!.privacy.friends, isFalse);
    });

    test('un coach ou l\'administrateur ne peuvent pas l\'activer', () async {
      final server = FakeFriendsServer();
      final r = server.phone();
      final b = await makeBackend(friendsRemote: r);
      await b.auth.login('admin@gymflow.tn', 'Admin2026!');
      await expectLater(
        b.friends.enable('Admin2026!'),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(server.accountCount, 0);
    });
  });

  group('Activation', () {
    test('un mauvais mot de passe est refusé avant tout envoi', () async {
      final server = FakeFriendsServer();
      final p = await phone(server, kAhmed);
      await expectLater(
        p.b.friends.enable('pas-le-bon'),
        throwsA(isA<ValidationException>()),
      );
      expect(server.accountCount, 0);
      expect(p.b.auth.currentUser!.privacy.friends, isFalse);
    });

    test(
      'activation : compte créé sur le serveur, consentement tracé',
      () async {
        final server = FakeFriendsServer();
        final p = await phone(server, kAhmed);
        await enable(p);

        expect(p.b.friends.status, FriendsStatus.connected);
        expect(server.accountExists(kAhmed), isTrue);
        expect(server.isEnabled(kAhmed), isTrue);
        expect(server.lastSeenOf(kAhmed), isNotNull, reason: 'premier signal');
        final me = p.b.auth.currentUser!;
        expect(me.privacy.friends, isTrue);
        expect(
          me.consents.any((c) => c.type == ConsentType.friends && c.granted),
          isTrue,
        );
      },
    );

    test('le mot de passe envoyé est celui de GymFlow', () async {
      final server = FakeFriendsServer();
      final p = await phone(server, kAhmed);
      await enable(p);
      expect(server.passwordOf(kAhmed), kPwd);
    });

    test('si le serveur échoue, rien n\'est activé à moitié', () async {
      final server = FakeFriendsServer()..failWith = 'panne';
      final p = await phone(server, kAhmed);
      await expectLater(
        p.b.friends.enable(kPwd),
        throwsA(isA<BusinessRuleException>()),
      );
      expect(p.b.auth.currentUser!.privacy.friends, isFalse);
      expect(p.b.friends.status, FriendsStatus.off);
    });

    test('à la connexion suivante, la reconnexion est automatique', () async {
      final server = FakeFriendsServer();
      final p = await phone(server, kAhmed);
      await enable(p);
      await p.b.auth.logout();
      expect(p.b.friends.status, FriendsStatus.off);
      await loginAs(p.b, kAhmed);
      await flush();
      expect(p.b.friends.status, FriendsStatus.connected);
      expect(server.accountCount, 1, reason: 'le compte n\'est pas recréé');
    });

    test('désactivation : amis effacés du serveur, réglage éteint', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      expect(server.friendshipCount, 1);
      await n.b.friends.disable();
      await flush();
      expect(server.friendshipCount, 0);
      expect(server.isEnabled(kNour), isFalse);
      expect(n.b.auth.currentUser!.privacy.friends, isFalse);
      expect(n.b.friends.status, FriendsStatus.off);
      // L'autre téléphone voit la liste se vider.
      expect(a.b.friends.friends, isEmpty);
    });
  });

  group('Demandes d\'ami par e-mail', () {
    test('la demande arrive en direct avec une notification', () async {
      final server = FakeFriendsServer();
      final a = await phone(server, kAhmed);
      final n = await phone(server, kNour);
      await enable(a);
      await enable(n);

      await a.b.friends.sendRequest(kNour);
      await flush();

      expect(n.b.friends.requests.length, 1);
      expect(n.b.friends.pendingCount, 1);
      final name = a.b.auth.currentUser!.fullName;
      expect(
        n.b.notifications.mine().map((x) => x.title),
        contains('$name veut vous ajouter'),
      );
      expect(
        (n.b.notifier as RecordingNotifier).shown,
        contains('$name veut vous ajouter'),
      );
    });

    test(
      'accepter : amis des deux côtés et notification à l\'auteur',
      () async {
        final server = FakeFriendsServer();
        final (a, n) = await friendsPair(server);

        expect(a.b.friends.friends.single.name, n.b.auth.currentUser!.fullName);
        expect(n.b.friends.friends.single.name, a.b.auth.currentUser!.fullName);
        expect(n.b.friends.requests, isEmpty);
        final who = n.b.auth.currentUser!.fullName;
        expect(
          a.b.notifications.mine().map((x) => x.title),
          contains('$who a accepté'),
        );
      },
    );

    test('refuser : pas amis, rien ne se passe côté auteur', () async {
      final server = FakeFriendsServer();
      final a = await phone(server, kAhmed);
      final n = await phone(server, kNour);
      await enable(a);
      await enable(n);
      await a.b.friends.sendRequest(kNour);
      await flush();
      await n.b.friends.respond(n.b.friends.requests.single, false);
      await flush();
      expect(n.b.friends.friends, isEmpty);
      expect(a.b.friends.friends, isEmpty);
      expect(server.friendshipCount, 1, reason: 'la trace du refus est gardée');
    });

    test('adresse sans compte : « aucun compte avec cette adresse »', () async {
      final server = FakeFriendsServer();
      final a = await phone(server, kAhmed);
      await enable(a);
      await expectLater(
        a.b.friends.sendRequest('personne@inconnu.tn'),
        throwsA(
          isA<BusinessRuleException>().having(
            (e) => e.message,
            'message',
            contains('Aucun compte avec cette adresse'),
          ),
        ),
      );
      expect(server.friendshipCount, 0);
      expect(a.b.friends.sentRequests, isEmpty);
    });

    test("personne qui n'a pas activé la fonction : même message", () async {
      final server = FakeFriendsServer();
      final a = await phone(server, kAhmed);
      await enable(a);
      await expectLater(
        a.b.friends.sendRequest(kNour),
        throwsA(isA<BusinessRuleException>()),
      );
      expect(server.friendshipCount, 0);
    });

    test('invitation envoyée : visible « en attente », annulable', () async {
      final server = FakeFriendsServer();
      final a = await phone(server, kAhmed);
      final n = await phone(server, kNour);
      await enable(a);
      await enable(n);
      final result = await a.b.friends.sendRequest(kNour);
      await flush();
      expect(result, SendResult.sent);
      expect(a.b.friends.sentRequests.length, 1);
      expect(
        a.b.friends.sentRequests.single.toName,
        n.b.auth.currentUser!.fullName,
      );
      expect(n.b.friends.requests.length, 1);

      await a.b.friends.cancelRequest(a.b.friends.sentRequests.single);
      await flush();
      expect(a.b.friends.sentRequests, isEmpty);
      expect(
        n.b.friends.requests,
        isEmpty,
        reason: 'la demande disparaît aussi',
      );
      expect(server.friendshipCount, 0);
    });

    test(
      "l'invitation disparaît de la liste quand elle est acceptée",
      () async {
        final server = FakeFriendsServer();
        final (a, n) = await friendsPair(server);
        expect(a.b.friends.sentRequests, isEmpty);
        expect(n.b.friends.friends.length, 1);
      },
    );

    test(
      "invitation refusée : l'auteur la voit toujours « en attente »",
      () async {
        final server = FakeFriendsServer();
        final a = await phone(server, kAhmed);
        final n = await phone(server, kNour);
        await enable(a);
        await enable(n);
        await a.b.friends.sendRequest(kNour);
        await flush();
        await n.b.friends.respond(n.b.friends.requests.single, false);
        await flush();
        expect(a.b.friends.sentRequests.length, 1);
        expect(a.b.friends.friends, isEmpty);
      },
    );

    test('résultats : déjà en attente, déjà amis, demande croisée', () async {
      final server = FakeFriendsServer();
      final a = await phone(server, kAhmed);
      final n = await phone(server, kNour);
      await enable(a);
      await enable(n);
      expect(await a.b.friends.sendRequest(kNour), SendResult.sent);
      expect(await a.b.friends.sendRequest(kNour), SendResult.alreadyPending);
      await flush();
      expect(await n.b.friends.sendRequest(kAhmed), SendResult.accepted);
      await flush();
      expect(await a.b.friends.sendRequest(kNour), SendResult.alreadyFriends);
    });

    test('sa propre adresse ou une adresse invalide sont refusées', () async {
      final server = FakeFriendsServer();
      final a = await phone(server, kAhmed);
      await enable(a);
      await expectLater(
        a.b.friends.sendRequest(kAhmed),
        throwsA(isA<BusinessRuleException>()),
      );
      await expectLater(
        a.b.friends.sendRequest('pas-un-email'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('demande croisée : acceptée tout de suite', () async {
      final server = FakeFriendsServer();
      final a = await phone(server, kAhmed);
      final n = await phone(server, kNour);
      await enable(a);
      await enable(n);
      await a.b.friends.sendRequest(kNour);
      await flush();
      await n.b.friends.sendRequest(kAhmed);
      await flush();
      expect(a.b.friends.friends.length, 1);
      expect(n.b.friends.friends.length, 1);
    });

    test('retirer un ami le retire des deux côtés', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      await a.b.friends.remove(a.b.friends.friends.single);
      await flush();
      expect(a.b.friends.friends, isEmpty);
      expect(n.b.friends.friends, isEmpty);
    });
  });

  group('Présence en direct', () {
    test('en ligne, puis hors ligne après 45 secondes sans signal', () async {
      var elapsed = Duration.zero;
      final base = DateTime.utc(2026, 11, 3, 10);
      final server = FakeFriendsServer(clock: () => base.add(elapsed));
      final a = await phone(server, kAhmed);
      final n = await phone(server, kNour, now: DateTime(2026, 11, 3, 11));
      await enable(a);
      await enable(n);
      await a.b.friends.sendRequest(kNour);
      await flush();
      await n.b.friends.respond(n.b.friends.requests.single, true);
      await flush();

      await a.b.friends.beat();
      await flush();
      final friend = n.b.friends.friends.single;
      expect(n.b.friends.isOnline(friend), isTrue);

      // 30 s plus tard : toujours en ligne.
      elapsed = const Duration(seconds: 30);
      setNow(DateTime(2026, 11, 3, 11).add(elapsed));
      expect(n.b.friends.isOnline(n.b.friends.friends.single), isTrue);

      // 46 s sans nouveau signal : hors ligne.
      elapsed = const Duration(seconds: 46);
      setNow(DateTime(2026, 11, 3, 11).add(elapsed));
      expect(n.b.friends.isOnline(n.b.friends.friends.single), isFalse);
    });

    test('une horloge de téléphone fausse ne fausse pas la présence', () async {
      final server = FakeFriendsServer(); // 10 h 00 UTC
      final a = await phone(server, kAhmed);
      // Le téléphone de Nour a une horloge en avance de 3 heures.
      final n = await phone(server, kNour, now: DateTime.utc(2026, 11, 3, 13));
      await enable(a);
      await enable(n);
      await a.b.friends.sendRequest(kNour);
      await flush();
      await n.b.friends.respond(n.b.friends.requests.single, true);
      await flush();
      await a.b.friends.beat();
      await flush();
      expect(n.b.friends.isOnline(n.b.friends.friends.single), isTrue);
    });

    test('se déconnecter fait passer hors ligne immédiatement', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      await a.b.friends.beat();
      await flush();
      expect(n.b.friends.isOnline(n.b.friends.friends.single), isTrue);

      await a.b.auth.logout();
      await flush();
      final seen = n.b.friends.friends.single;
      expect(n.b.friends.isOnline(seen), isFalse);
      expect(
        seen.presenceLabel(n.b.friends.serverNow()),
        startsWith('Vu il y a'),
        reason: 'on garde la date du dernier signal',
      );
      expect(a.r.calls['signOut'], 1);
      expect(a.r.userId, isNull, reason: 'la session du serveur est fermée');
    });

    test('mode « Apparaître hors ligne » : les amis ne voient rien', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      await a.b.friends.beat();
      await flush();
      expect(n.b.friends.isOnline(n.b.friends.friends.single), isTrue);

      await a.b.friends.setInvisible(true);
      await flush();
      var f = n.b.friends.friends.single;
      expect(n.b.friends.isOnline(f), isFalse);
      expect(
        f.presenceLabel(n.b.friends.serverNow()),
        'Hors ligne',
        reason: 'ni « en ligne », ni « vu il y a »',
      );
      expect(a.b.friends.invisible, isTrue);

      // Les signaux continuent, mais rien ne se voit.
      await a.b.friends.beat();
      await flush();
      f = n.b.friends.friends.single;
      expect(n.b.friends.isOnline(f), isFalse);
      expect(f.lastSeen, isNull);

      await a.b.friends.setInvisible(false);
      await flush();
      expect(n.b.friends.isOnline(n.b.friends.friends.single), isTrue);
    });

    test('le mode invisible survit à une reconnexion', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      await a.b.friends.setInvisible(true);
      await a.b.auth.logout();
      await loginAs(a.b, kAhmed);
      await flush();
      expect(a.b.friends.invisible, isTrue);
    });

    test('application en arrière-plan : hors ligne tout de suite', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      await a.b.friends.beat();
      await flush();
      expect(n.b.friends.isOnline(n.b.friends.friends.single), isTrue);

      a.b.friends.didChangeAppLifecycleState(AppLifecycleState.paused);
      await flush();
      expect(n.b.friends.isOnline(n.b.friends.friends.single), isFalse);

      a.b.friends.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await flush();
      expect(n.b.friends.isOnline(n.b.friends.friends.single), isTrue);
    });

    test(
      'appli ouverte mais inutilisée depuis 2 minutes : hors ligne',
      () async {
        final server = FakeFriendsServer();
        // Nour d'abord, Ahmed ensuite : setNow() règle l'horloge d'Ahmed.
        final n = await phone(server, kNour);
        final a = await phone(server, kAhmed);
        await enable(n);
        await enable(a);
        await a.b.friends.sendRequest(kNour);
        await flush();
        await n.b.friends.respond(n.b.friends.requests.single, true);
        await flush();
        expect(n.b.friends.isOnline(n.b.friends.friends.single), isTrue);

        // 1 min 59 s sans geste : encore en ligne.
        setNow(testNow.add(const Duration(minutes: 1, seconds: 59)));
        await a.b.friends.tick();
        await flush();
        expect(n.b.friends.isOnline(n.b.friends.friends.single), isTrue);

        // 2 min 1 s sans geste : hors ligne.
        setNow(testNow.add(const Duration(minutes: 2, seconds: 1)));
        await a.b.friends.tick();
        await flush();
        expect(n.b.friends.isOnline(n.b.friends.friends.single), isFalse);

        // Un geste : de nouveau en ligne.
        a.b.friends.noteActivity();
        await flush();
        expect(n.b.friends.isOnline(n.b.friends.friends.single), isTrue);
      },
    );

    test('un geste régulier garde en ligne pendant des minutes', () async {
      final server = FakeFriendsServer();
      final n = await phone(server, kNour);
      final a = await phone(server, kAhmed);
      await enable(n);
      await enable(a);
      await a.b.friends.sendRequest(kNour);
      await flush();
      await n.b.friends.respond(n.b.friends.requests.single, true);
      await flush();
      for (var min = 1; min <= 6; min++) {
        setNow(testNow.add(Duration(minutes: min)));
        a.b.friends.noteActivity();
        await a.b.friends.tick();
      }
      await flush();
      expect(n.b.friends.isOnline(n.b.friends.friends.single), isTrue);
    });

    test('le nombre d\'amis en ligne est tenu à jour', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      await a.b.friends.beat();
      await flush();
      expect(n.b.friends.onlineCount, 1);
    });
  });

  group('Messages (poke)', () {
    test(
      'le message arrive en direct avec le texte d\'encouragement',
      () async {
        final server = FakeFriendsServer();
        final (a, n) = await friendsPair(server);
        await a.b.friends.poke(a.b.friends.friends.single);
        await flush();

        final who = a.b.auth.currentUser!.fullName;
        final titles = n.b.notifications.mine().map((x) => x.title);
        expect(titles, contains('$who vous encourage'));
        expect(
          n.b.notifications.mine().map((x) => x.body),
          contains(
            'Votre ami(e) vous encourage à dépasser vos limites aujourd\'hui !',
          ),
        );
        expect(
          (n.b.notifier as RecordingNotifier).shown,
          contains('$who vous encourage'),
        );
      },
    );

    test('un message par minute et par ami', () async {
      final server = FakeFriendsServer();
      final (a, _) = await friendsPair(server);
      final friend = a.b.friends.friends.single;
      await a.b.friends.poke(friend);
      await expectLater(
        a.b.friends.poke(friend),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('après une minute, on peut renvoyer un message', () async {
      var elapsed = Duration.zero;
      final base = DateTime.utc(2026, 11, 3, 10);
      final server = FakeFriendsServer(clock: () => base.add(elapsed));
      final (a, _) = await friendsPair(server);
      final friend = a.b.friends.friends.single;
      await a.b.friends.poke(friend);
      elapsed = const Duration(seconds: 59);
      await expectLater(
        a.b.friends.poke(friend),
        throwsA(isA<BusinessRuleException>()),
      );
      elapsed = const Duration(seconds: 61);
      await a.b.friends.poke(friend);
      expect(server.pokeCount, 2);
    });

    test('on ne peut pas écrire à quelqu\'un qui n\'est plus ami', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      final friend = a.b.friends.friends.single;
      await n.b.friends.remove(n.b.friends.friends.single);
      await flush();
      await expectLater(
        a.b.friends.poke(friend),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test(
      'un message envoyé pendant l\'absence est reçu à la reconnexion',
      () async {
        final server = FakeFriendsServer();
        final (a, n) = await friendsPair(server);
        await n.b.auth.logout();
        await flush();

        await a.b.friends.poke(a.b.friends.friends.single, PokeKind.challenge);
        await flush();
        expect(server.pokeCount, 1);

        await loginAs(n.b, kNour);
        await flush();
        final who = a.b.auth.currentUser!.fullName;
        expect(
          n.b.notifications.mine().map((x) => x.title),
          contains('$who vous lance un défi'),
        );
      },
    );

    test('un message n\'est jamais affiché deux fois', () async {
      final server = FakeFriendsServer();
      final (a, n) = await friendsPair(server);
      await a.b.friends.poke(a.b.friends.friends.single);
      await flush();
      // Reconnexion : le message déjà vu ne revient pas.
      await n.b.auth.logout();
      await loginAs(n.b, kNour);
      await flush();
      final count = n.b.notifications
          .mine()
          .where((x) => x.title.endsWith('vous encourage'))
          .length;
      expect(count, 1);
    });

    test('les deux messages ont un texte et une clé acceptés par la base', () {
      const allowed = {'encourage', 'challenge'};
      for (final k in PokeKind.values) {
        expect(allowed, contains(k.key));
        expect(k.title('Sarra'), contains('Sarra'));
        expect(k.body('Sarra'), isNotEmpty);
        expect(PokeKind.fromKey(k.key), k);
      }
      expect(PokeKind.fromKey('inconnu'), PokeKind.encourage);
    });
  });

  group('Session et reprise', () {
    test(
      'lancement avec une session du serveur déjà ouverte : reprise',
      () async {
        final server = FakeFriendsServer();
        final p = await phone(server, kAhmed);
        await enable(p);
        p.r.keepSessionFor(kAhmed);
        p.b.friends.stop();
        final signIns = p.r.calls['signIn'];
        await p.b.friends.resume();
        await flush();
        expect(p.b.friends.status, FriendsStatus.connected);
        expect(
          p.r.calls['signIn'],
          signIns,
          reason: 'sans ressaisir le mot de passe',
        );
      },
    );

    test(
      'session du serveur d\'un autre compte : mot de passe demandé',
      () async {
        final server = FakeFriendsServer();
        final n = await phone(server, kNour);
        await enable(n);
        final a = await phone(server, kAhmed);
        await enable(a);
        a.r.keepSessionFor(kNour); // reste d'un autre compte sur ce téléphone
        a.b.friends.stop();
        await a.b.friends.resume();
        expect(a.b.friends.status, FriendsStatus.needsPassword);
        await expectLater(
          a.b.friends.reconnect('faux'),
          throwsA(isA<ValidationException>()),
        );
        await a.b.friends.reconnect(kPwd);
        expect(a.b.friends.status, FriendsStatus.connected);
      },
    );

    test('changer de mot de passe met le compte du serveur à jour', () async {
      final server = FakeFriendsServer();
      final p = await phone(server, kAhmed);
      await enable(p);
      await p.b.auth.changePassword(kPwd, 'NouveauPass2026!');
      await flush();
      expect(server.passwordOf(kAhmed), 'NouveauPass2026!');
    });

    test('supprimer son compte efface aussi les données du serveur', () async {
      final server = FakeFriendsServer();
      final (_, n) = await friendsPair(server);
      expect(server.friendshipCount, 1);
      await n.b.privacy.deleteMyAccount(kPwd);
      await flush();
      expect(server.friendshipCount, 0);
    });

    test(
      'serveur injoignable pendant la reprise : erreur affichable',
      () async {
        final server = FakeFriendsServer();
        final p = await phone(server, kAhmed);
        await enable(p);
        p.b.friends.stop();
        server.failWith = 'Impossible de joindre le service Amis.';
        await p.b.friends.resume();
        expect(p.b.friends.status, FriendsStatus.error);
        expect(p.b.friends.error, isA<BusinessRuleException>());
      },
    );
  });

  group('Modèles', () {
    final now = DateTime.utc(2026, 11, 3, 10);
    Friend at(DateTime? seen, {bool online = true}) =>
        Friend(id: 'x', name: 'X', since: now, lastSeen: seen, online: online);

    test('en ligne : serveur en ligne ET signal de moins de 45 secondes', () {
      expect(
        at(now.subtract(const Duration(seconds: 44))).isOnline(now),
        isTrue,
      );
      expect(
        at(now.subtract(const Duration(seconds: 45))).isOnline(now),
        isFalse,
      );
      expect(at(now, online: false).isOnline(now), isFalse);
      expect(at(null).isOnline(now), isFalse);
    });

    test('libellés de présence', () {
      expect(at(now).presenceLabel(now), 'En ligne');
      expect(at(null).presenceLabel(now), 'Hors ligne');
      expect(
        at(now.subtract(const Duration(minutes: 5))).presenceLabel(now),
        'Vu il y a 5 min',
      );
      expect(
        at(now.subtract(const Duration(hours: 3))).presenceLabel(now),
        'Vu il y a 3 h',
      );
      expect(
        at(now.subtract(const Duration(days: 2))).presenceLabel(now),
        'Vu il y a 2 j',
      );
    });
  });
}
