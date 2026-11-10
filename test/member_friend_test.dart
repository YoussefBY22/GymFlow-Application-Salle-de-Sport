// Niveau : widget (sans réseau, faux serveur). Profil d'un membre de la salle :
// « Ajouter comme ami » dans le menu, et retrouver sur ce téléphone le
// membre qui correspond à un ami (même adresse e-mail).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/services/backend.dart';

import 'friends_fake.dart';
import 'friends_helpers.dart';
import 'widget_helpers.dart';

Future<void> _done(WidgetTester tester, Backend b) async {
  b.friends.stop();
  await tester.pumpWidget(const SizedBox());
}

void main() {
  testWidgets('profil d\'un membre : « Ajouter comme ami » envoie l\'invitation', (
    tester,
  ) async {
    final server = FakeFriendsServer();
    final mine = server.phone();
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: mine,
    );
    // Ines a activé la fonction Amis sur son téléphone.
    final ines = server.phone();
    await ines.signIn(
      email: 'ines@gymflow.tn',
      password: 'x',
      displayName: 'Ines',
      create: true,
    );
    await ines.updateProfile(displayName: 'Ines', enabled: true);
    await b.friends.enable();
    await settle(tester, 400);

    await go(tester, Routes.member, 'u_ines');
    await tester.tap(find.byKey(const Key('member_menu')));
    await settle(tester, 400);
    // « Ajouter comme ami » est au-dessus de « Signaler ce profil ».
    final add = tester.getTopLeft(find.text('Ajouter comme ami'));
    final report = tester.getTopLeft(find.text('Signaler ce profil'));
    expect(add.dy, lessThan(report.dy));
    await tester.tap(find.text('Ajouter comme ami'));
    await settle(tester, 1000);

    expect(find.textContaining('Invitation envoyée'), findsOneWidget);
    expect(server.friendshipCount, 1);
    await _done(tester, b);
  });

  testWidgets('fonction Amis éteinte : on propose de l\'activer', (tester) async {
    final server = FakeFriendsServer();
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: server.phone(),
    );
    await go(tester, Routes.member, 'u_ines');
    await tester.tap(find.byKey(const Key('member_menu')));
    await settle(tester, 400);
    await tester.tap(find.text('Ajouter comme ami'));
    await settle(tester, 600);

    expect(find.text('Activez la fonction Amis'), findsOneWidget);
    expect(server.friendshipCount, 0);
    await _done(tester, b);
  });

  test('un ami est retrouvé parmi les membres de ce téléphone', () async {
    final server = FakeFriendsServer();
    final (a, _) = await friendsPair(server);
    final friendId = a.b.friends.friends.single.id;

    final local = await a.b.friends.localUserOf(friendId);
    expect(local?.id, 'u_nour');
    expect(await a.b.friends.localUserOf('inconnu'), isNull);
  });
}
