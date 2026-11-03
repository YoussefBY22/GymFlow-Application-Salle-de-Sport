// Niveau : widget (sans réseau, faux serveur). Écran « Mes amis » : fonction
// indisponible ou éteinte, activation avec mot de passe, ajout par e-mail,
// demandes reçues, liste avec présence et message d'encouragement.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/services/backend.dart';

import 'friends_fake.dart';
import 'widget_helpers.dart';

Future<void> flush() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Une autre personne (Nour) avec la fonction activée sur le faux serveur.
Future<FakeFriendsRemote> _otherPhone(FakeFriendsServer server) async {
  final r = server.phone();
  await r.signIn(
    email: 'nour@gymflow.tn',
    password: 'x',
    displayName: 'Nour Test',
  );
  await r.updateProfile(displayName: 'Nour Test', enabled: true);
  await r.heartbeat();
  await r.subscribe();
  return r;
}

/// Ferme proprement : minuteurs du service et de l'écran.
Future<void> _done(WidgetTester tester, Backend b) async {
  b.friends.stop();
  await tester.pumpWidget(const SizedBox());
}

Future<void> _activate(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('friends_enable')));
  await settle(tester, 600);
  await tester.enterText(
    find.byKey(const Key('friends_password')),
    'Membre2026!',
  );
  await tester.tap(find.byKey(const Key('friends_password_ok')));
  await settle(tester, 1500);
}

void main() {
  testWidgets('sans Supabase : pas d\'entrée au menu, écran explicatif', (
    tester,
  ) async {
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
    );
    expect(b.friends.available, isFalse);
    await go(tester, Routes.friends);
    expect(find.textContaining('pas disponible'), findsOneWidget);
    await _done(tester, b);
  });

  testWidgets('la route est réservée aux abonnés', (tester) async {
    expect(Routes.rolesFor(Routes.friends), isNotNull);
    await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'admin@gymflow.tn',
      friendsRemote: FakeFriendsServer().phone(),
    );
    await go(tester, Routes.friends);
    expect(find.text('Accès réservé'), findsOneWidget);
  });

  testWidgets('fonction éteinte : présentation et bouton d\'activation', (
    tester,
  ) async {
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: FakeFriendsServer().phone(),
    );
    await go(tester, Routes.friends);
    expect(find.byKey(const Key('friends_intro')), findsOneWidget);
    expect(find.byKey(const Key('friends_enable')), findsOneWidget);
    expect(find.textContaining('désactivé par défaut'), findsOneWidget);
    await _done(tester, b);
  });

  testWidgets('activation : mot de passe demandé, puis écran connecté', (
    tester,
  ) async {
    final server = FakeFriendsServer();
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: server.phone(),
    );
    await go(tester, Routes.friends);
    await _activate(tester);

    expect(server.accountExists('ahmed@gymflow.tn'), isTrue);
    expect(find.byKey(const Key('friend_email')), findsOneWidget);
    expect(find.byKey(const Key('friend_send')), findsOneWidget);
    expect(find.textContaining('Aucun ami pour le moment'), findsOneWidget);
    await _done(tester, b);
  });

  testWidgets('mauvais mot de passe : message d\'erreur, rien d\'activé', (
    tester,
  ) async {
    final server = FakeFriendsServer();
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: server.phone(),
    );
    await go(tester, Routes.friends);
    await tester.tap(find.byKey(const Key('friends_enable')));
    await settle(tester, 600);
    await tester.enterText(find.byKey(const Key('friends_password')), 'faux');
    await tester.tap(find.byKey(const Key('friends_password_ok')));
    await settle(tester, 1200);

    expect(find.text('Mot de passe incorrect.'), findsOneWidget);
    expect(server.accountCount, 0);
    expect(find.byKey(const Key('friends_enable')), findsOneWidget);
    await _done(tester, b);
  });

  testWidgets('ajout d\'un ami par e-mail : invitation en attente visible', (
    tester,
  ) async {
    final server = FakeFriendsServer();
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: server.phone(),
    );
    final other = await _otherPhone(server);
    await go(tester, Routes.friends);
    await _activate(tester);

    await tester.enterText(
      find.byKey(const Key('friend_email')),
      'nour@gymflow.tn',
    );
    await tester.tap(find.byKey(const Key('friend_send')));
    await settle(tester, 1200);

    expect(server.friendshipCount, 1);
    expect(find.textContaining('Invitation envoyée'), findsOneWidget);
    expect(find.byKey(const Key('sent_requests')), findsOneWidget);
    expect(find.text('En attente de réponse'), findsOneWidget);
    expect(other.userId, isNotNull);
    await _done(tester, b);
  });

  testWidgets('demande reçue : acceptation, l\'ami apparaît avec sa présence', (
    tester,
  ) async {
    final server = FakeFriendsServer();
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: server.phone(),
    );
    final other = await _otherPhone(server);
    await go(tester, Routes.friends);
    await _activate(tester);

    // Nour demande Ahmed en ami : la demande apparaît sans recharger.
    await other.sendRequest('ahmed@gymflow.tn');
    await settle(tester, 800);
    expect(find.byKey(const Key('friend_requests')), findsOneWidget);
    expect(find.textContaining('veut vous ajouter'), findsWidgets);

    final accept = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('accept_'),
    );
    await tapVisible(tester, accept);
    await settle(tester, 1200);

    expect(find.byKey(const Key('friend_list')), findsOneWidget);
    expect(find.text('Nour Test'), findsOneWidget);
    expect(find.text('En ligne'), findsOneWidget);
    await _done(tester, b);
  });

  testWidgets('message d\'encouragement : envoyé, puis limité à 1 par minute', (
    tester,
  ) async {
    final server = FakeFriendsServer();
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: server.phone(),
    );
    final other = await _otherPhone(server);
    await go(tester, Routes.friends);
    await _activate(tester);
    await other.sendRequest('ahmed@gymflow.tn');
    await settle(tester, 800);
    final acceptBtn = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('accept_'),
    );
    await tapVisible(tester, acceptBtn);
    await settle(tester, 1200);

    final poke = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('poke_'),
    );
    await tapVisible(tester, poke);
    await settle(tester, 1000);
    expect(server.pokeCount, 1);
    expect(find.textContaining('Message envoyé à Nour Test'), findsOneWidget);

    await tester.ensureVisible(poke);
    await tapVisible(tester, poke);
    await settle(tester, 1000);
    expect(server.pokeCount, 1);
    expect(find.textContaining('un message par minute'), findsOneWidget);
    await _done(tester, b);
  });

  testWidgets('adresse sans compte : message clair, aucune invitation', (
    tester,
  ) async {
    final server = FakeFriendsServer();
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: server.phone(),
    );
    await go(tester, Routes.friends);
    await _activate(tester);

    await tester.enterText(
      find.byKey(const Key('friend_email')),
      'personne@inconnu.tn',
    );
    await tester.tap(find.byKey(const Key('friend_send')));
    await settle(tester, 1200);

    expect(
      find.textContaining('Aucun compte avec cette adresse'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('sent_requests')), findsNothing);
    expect(server.friendshipCount, 0);
    await _done(tester, b);
  });

  testWidgets('annuler une invitation envoyée', (tester) async {
    final server = FakeFriendsServer();
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: server.phone(),
    );
    await _otherPhone(server);
    await go(tester, Routes.friends);
    await _activate(tester);
    await tester.enterText(
      find.byKey(const Key('friend_email')),
      'nour@gymflow.tn',
    );
    await tester.tap(find.byKey(const Key('friend_send')));
    await settle(tester, 1200);
    expect(find.byKey(const Key('sent_requests')), findsOneWidget);

    final cancel = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('cancel_'),
    );
    await tapVisible(tester, cancel);
    await settle(tester, 1200);

    expect(find.byKey(const Key('sent_requests')), findsNothing);
    expect(server.friendshipCount, 0);
    await _done(tester, b);
  });

  testWidgets('« Apparaître hors ligne » : interrupteur et effet serveur', (
    tester,
  ) async {
    final server = FakeFriendsServer();
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: server.phone(),
    );
    await go(tester, Routes.friends);
    await _activate(tester);

    final tile = find.byKey(const Key('friends_invisible'));
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.tap(tile);
    await settle(tester, 1000);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(server.isInvisible('ahmed@gymflow.tn'), isTrue);
    expect(find.textContaining('vous voient hors ligne'), findsOneWidget);
    await _done(tester, b);
  });

  testWidgets('désactivation : confirmation puis retour à la présentation', (
    tester,
  ) async {
    final server = FakeFriendsServer();
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
      friendsRemote: server.phone(),
    );
    await go(tester, Routes.friends);
    await _activate(tester);

    // La page est longue : on la fait défiler jusqu'en bas (liste paresseuse).
    // (et on laisse partir le message du bas, qui masquerait le bouton).
    await settle(tester, 5000);
    await tester.drag(mainScrollable(tester), const Offset(0, -3000));
    await settle(tester, 400);
    await tester.tap(find.byKey(const Key('friends_disable')));
    await settle(tester, 600);
    expect(find.text('Désactiver la fonction Amis ?'), findsOneWidget);
    await tester.tap(find.text('Désactiver'));
    await settle(tester, 1200);

    expect(find.byKey(const Key('friends_intro')), findsOneWidget);
    expect(b.auth.currentUser!.privacy.friends, isFalse);
    await _done(tester, b);
  });
}
