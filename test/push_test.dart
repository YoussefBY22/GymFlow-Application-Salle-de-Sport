// Niveau : unitaire et intégration (sans Firebase). Notifications push quand
// l'application est fermée : enregistrement du jeton à l'activation, renouvel-
// lement, retrait à la déconnexion, page ouverte au toucher d'une notification.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/services/push/push_gateway.dart';
import 'package:gymflow/services/push_service.dart';

import 'friends_fake.dart';
import 'friends_helpers.dart';
import 'helpers.dart';

const _token = 'tok_aaaaaaaaaaaaaaaaaaaaaaaaaaaa';

/// Faux Firebase : tout est piloté par le test.
class FakePush implements PushGateway {
  @override
  bool configured = true;
  PushPermission permission = PushPermission.granted;
  String? tokenValue = _token;
  PushOpen? initial;
  int deleted = 0;
  final refresh = StreamController<String>.broadcast();
  final taps = StreamController<PushOpen>.broadcast();

  @override
  Future<PushPermission> requestPermission() async => permission;

  @override
  Future<String?> token() async => tokenValue;

  @override
  Stream<String> get tokenRefresh => refresh.stream;

  @override
  Stream<PushOpen> get opened => taps.stream;

  @override
  Future<PushOpen?> initialOpen() async => initial;

  @override
  Future<void> deleteToken() async => deleted++;
}

void main() {
  group('Notifications application fermée', () {
    test('sans clés Firebase : indisponible, rien d\'enregistré', () async {
      final server = FakeFriendsServer();
      final p = await phone(server, kAhmed);
      await enable(p);
      expect(p.b.push.status, PushStatus.unavailable);
      expect(server.pushTokens, isEmpty);
    });

    test('configuré mais fonction Amis éteinte : rien d\'enregistré', () async {
      final server = FakeFriendsServer();
      final push = FakePush();
      final p = await phone(server, kAhmed, push: push);
      await flush();
      expect(p.b.push.status, PushStatus.off);
      expect(server.pushTokens, isEmpty);
    });

    test('à l\'activation : le téléphone est enregistré', () async {
      final server = FakeFriendsServer();
      final p = await phone(server, kAhmed, push: FakePush());
      await enable(p);
      expect(p.b.push.status, PushStatus.enabled);
      expect(server.pushTokens.keys, [_token]);
      expect(server.pushTokens[_token], p.r.userId);
    });

    test('notifications refusées dans le téléphone : « refusées »', () async {
      final server = FakeFriendsServer();
      final push = FakePush()..permission = PushPermission.denied;
      final p = await phone(server, kAhmed, push: push);
      await enable(p);
      expect(p.b.push.status, PushStatus.denied);
      expect(server.pushTokens, isEmpty);
      expect(p.b.friends.status.name, 'connected', reason: 'le reste marche');
    });

    test('jeton introuvable : erreur, sans casser la fonction Amis', () async {
      final server = FakeFriendsServer();
      final push = FakePush()..tokenValue = null;
      final p = await phone(server, kAhmed, push: push);
      await enable(p);
      expect(p.b.push.status, PushStatus.error);
      expect(p.b.friends.status.name, 'connected');
    });

    test('un nouveau jeton remplace l\'ancien', () async {
      final server = FakeFriendsServer();
      final push = FakePush();
      final p = await phone(server, kAhmed, push: push);
      await enable(p);
      push.refresh.add('tok_bbbbbbbbbbbbbbbbbbbbbbbbbbbb');
      await flush();
      expect(
        server.pushTokens.containsKey('tok_bbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
        isTrue,
      );
    });

    test('la déconnexion retire ce téléphone du serveur', () async {
      final server = FakeFriendsServer();
      final push = FakePush();
      final p = await phone(server, kAhmed, push: push);
      await enable(p);
      expect(server.pushTokens, isNotEmpty);

      await p.b.auth.logout();
      await flush();
      expect(server.pushTokens, isEmpty);
      expect(push.deleted, 1, reason: 'jeton Firebase supprimé aussi');
      expect(p.b.push.status, PushStatus.off);
    });

    test('désactiver la fonction Amis retire aussi le jeton', () async {
      final server = FakeFriendsServer();
      final push = FakePush();
      final p = await phone(server, kAhmed, push: push);
      await enable(p);
      await p.b.friends.disable();
      expect(server.pushTokens, isEmpty);
      expect(push.deleted, 1);
    });

    test('à la reconnexion, le téléphone est de nouveau enregistré', () async {
      final server = FakeFriendsServer();
      final push = FakePush();
      final p = await phone(server, kAhmed, push: push);
      await enable(p);
      await p.b.auth.logout();
      await loginAs(p.b, kAhmed);
      await flush();
      expect(server.pushTokens.keys, [_token]);
      expect(p.b.push.status, PushStatus.enabled);
    });

    test('une panne du serveur ne lève pas d\'erreur', () async {
      final server = FakeFriendsServer();
      final push = FakePush();
      final p = await phone(server, kAhmed, push: push);
      await enable(p);
      await p.b.push.stop();
      server.failWith = 'panne';
      await p.b.push.start(); // ne lève rien
      expect(p.b.push.status, PushStatus.error);
    });
  });

  group('Toucher une notification', () {
    test('ouvre la discussion de l\'ami', () async {
      final server = FakeFriendsServer();
      final push = FakePush();
      final p = await phone(server, kAhmed, push: push);
      final opened = <(String, String?)>[];
      p.b.push.onOpen = (route, ref) => opened.add((route, ref));
      await enable(p);

      push.taps.add(const PushOpen('/chat', 'sb_42'));
      await flush();
      expect(opened, [('/chat', 'sb_42')]);

      push.taps.add(const PushOpen('/friends', null));
      await flush();
      expect(opened.last, ('/friends', null));
    });

    test('une page inconnue est ignorée', () async {
      final server = FakeFriendsServer();
      final push = FakePush();
      final p = await phone(server, kAhmed, push: push);
      final opened = <String>[];
      p.b.push.onOpen = (route, ref) => opened.add(route);
      await enable(p);
      push.taps.add(const PushOpen('/admin/users', null));
      push.taps.add(const PushOpen('https://evil.example', null));
      await flush();
      expect(opened, isEmpty);
    });

    test(
      'une notification qui a lancé l\'application est suivie une fois',
      () async {
        final server = FakeFriendsServer();
        final push = FakePush()..initial = const PushOpen('/chat', 'sb_7');
        final p = await phone(server, kAhmed, push: push);
        final opened = <(String, String?)>[];
        p.b.push.onOpen = (route, ref) => opened.add((route, ref));
        await enable(p);
        expect(opened, [('/chat', 'sb_7')]);

        await p.b.push.stop();
        await p.b.push.start();
        expect(opened.length, 1, reason: 'pas deux fois');
      },
    );
  });

  group('Réglage de l\'aperçu', () {
    test('par défaut le texte est affiché ; le réglage est gardé', () async {
      final server = FakeFriendsServer();
      final p = await phone(server, kAhmed, push: FakePush());
      await enable(p);
      expect(p.b.friends.settings.pushPreview, isTrue);
      await p.b.friends.setChatSettings(pushPreview: false);
      await p.b.auth.logout();
      await loginAs(p.b, kAhmed);
      await flush();
      expect(p.b.friends.settings.pushPreview, isFalse);
    });
  });
}
