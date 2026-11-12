// Niveau : service (sans réseau, faux salon temps réel). Compteur « abonnés
// connectés maintenant » : qui est compté, et quand il disparaît.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/live_presence_service.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

/// Faux salon : partagé par tous les « appareils » d'un test.
class FakeRoom {
  final Map<String, bool> present = {}; // clé -> compté (abonné)
  final List<FakeTransport> _listeners = [];

  int get counted => present.values.where((m) => m).length;

  void _changed() {
    for (final l in _listeners) {
      if (l.watching) l.controller.add(counted);
    }
  }
}

class FakeTransport implements PresenceTransport {
  FakeTransport(this.room) {
    room._listeners.add(this);
  }

  final FakeRoom room;
  final controller = StreamController<int>.broadcast();
  String? key;
  bool watching = false;
  int joins = 0;

  @override
  Stream<int> get members => controller.stream;

  @override
  Future<void> join({required String key, required bool member}) async {
    await leave();
    this.key = key;
    watching = true;
    joins++;
    room.present[key] = member;
    room._changed();
  }

  @override
  Future<void> leave() async {
    final k = key;
    key = null;
    watching = false;
    if (k != null) {
      room.present.remove(k);
      room._changed();
    }
  }
}

Future<void> _idle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _consent(Backend b, bool on) async {
  final me = b.auth.currentUser!;
  await b.privacy.updateSettings(me.privacy.copyWith(analytics: on));
  await _idle();
}

void main() {
  test('abonné consentant : compté au premier plan, retiré en partant', () async {
    final room = FakeRoom();
    final b = await makeBackend(
      presenceTransport: FakeTransport(room),
    );
    await loginAs(b, 'ahmed@gymflow.tn');
    await _idle();
    expect(room.counted, 0, reason: 'sans consentement : pas compté');

    await _consent(b, true);
    expect(room.counted, 1);

    b.live.setForeground(false);
    await _idle();
    expect(room.counted, 0, reason: 'application quittée : retiré');
    b.live.setForeground(true);
    await _idle();
    expect(room.counted, 1, reason: 'retour : recompté');

    await b.auth.logout();
    await _idle();
    expect(room.counted, 0, reason: 'déconnexion : retiré');

    await loginAs(b, 'ahmed@gymflow.tn');
    await _idle();
    expect(room.counted, 1, reason: 'reconnexion : recompté');

    await _consent(b, false);
    expect(room.counted, 0, reason: 'consentement retiré : retiré');
    await b.live.stop();
  });

  test('l\'admin voit le chiffre en direct et n\'est jamais compté', () async {
    final room = FakeRoom();
    // Téléphone d'un abonné.
    final phone = await makeBackend(presenceTransport: FakeTransport(room));
    await loginAs(phone, 'ahmed@gymflow.tn');
    await _consent(phone, true);

    // Téléphone de l'admin (autre backend, même salon).
    final admin = await makeBackend(presenceTransport: FakeTransport(room));
    await loginAs(admin, 'admin@gymflow.tn');
    await _idle();
    expect(room.present.length, 1, reason: 'l\'admin n\'écoute pas encore');

    admin.live.watch(true);
    await _idle();
    expect(admin.live.members, 1);
    expect(admin.live.synced, isTrue);
    expect(room.counted, 1, reason: 'l\'admin n\'est pas compté');

    await phone.auth.logout();
    await _idle();
    expect(admin.live.members, 0);

    admin.live.watch(false);
    await _idle();
    expect(room.present, isEmpty);
    await phone.live.stop();
    await admin.live.stop();
  });

  test('sans serveur configuré : rien ne plante', () async {
    final b = await makeBackend();
    await loginAs(b, 'ahmed@gymflow.tn');
    b.live.watch(true);
    b.live.setForeground(false);
    expect(b.live.available, isFalse);
    expect(b.live.members, 0);
  });

  testWidgets('écran Statistiques : le compteur « connectés maintenant »', (
    tester,
  ) async {
    final room = FakeRoom();
    final phone = await makeBackend(presenceTransport: FakeTransport(room));
    await loginAs(phone, 'ahmed@gymflow.tn');
    await phone.privacy.updateSettings(
      phone.auth.currentUser!.privacy.copyWith(analytics: true),
    );
    await tester.pump();

    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'admin@gymflow.tn',
      presenceTransport: FakeTransport(room),
    );
    await go(tester, Routes.adminStats);
    await settle(tester, 600);
    expect(find.byKey(const Key('live_now')), findsOneWidget);
    expect(find.byKey(const Key('live_count')), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    expect(find.text('abonné connecté maintenant'), findsOneWidget);

    await phone.auth.logout();
    await settle(tester, 600);
    expect(find.text('abonnés connectés maintenant'), findsOneWidget);
    await phone.live.stop();
    await b.live.stop();
    phone.friends.stop();
    b.friends.stop();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
