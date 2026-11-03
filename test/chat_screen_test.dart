// Niveau : widget (sans réseau, faux serveur). Écrans de la messagerie :
// liste des discussions, discussion (envoi, réception en direct, « Vu »,
// « en train d'écrire », suppression avec trace), signalement d'une
// discussion et écran « Signalements » de l'administrateur.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/routes.dart';
import 'package:gymflow/models/chat.dart';
import 'package:gymflow/services/backend.dart';

import 'friends_fake.dart';
import 'widget_helpers.dart';

/// Ahmed (écran testé) est ami avec Nour (téléphone simulé, sans écran).
class _Setup {
  _Setup(this.b, this.server, this.mine, this.other, this.otherId, this.myId);
  final Backend b;
  final FakeFriendsServer server;
  final FakeFriendsRemote mine;
  final FakeFriendsRemote other;
  final String otherId;
  final String myId;
}

Future<_Setup> _setup(WidgetTester tester) async {
  final server = FakeFriendsServer();
  final mine = server.phone();
  final b = await pumpApp(
    tester,
    route: Routes.home,
    loginEmail: 'ahmed@gymflow.tn',
    friendsRemote: mine,
  );
  final other = server.phone();
  await other.signIn(
    email: 'nour@gymflow.tn',
    password: 'x',
    displayName: 'Nour Test',
  );
  await other.updateProfile(displayName: 'Nour Test', enabled: true);
  await other.heartbeat();
  await other.subscribe();

  await b.friends.enable('Membre2026!');
  await other.sendRequest('ahmed@gymflow.tn');
  await settle(tester, 300);
  await b.friends.respond(b.friends.requests.single, true);
  await settle(tester, 300);
  return _Setup(
    b,
    server,
    mine,
    other,
    b.friends.friends.single.id,
    mine.userId!,
  );
}

Future<void> _done(WidgetTester tester, Backend b) async {
  b.friends.stop();
  await tester.pumpWidget(const SizedBox());
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('chat_input')), text);
  await tester.pump();
}

void main() {
  testWidgets('la route de discussion est réservée aux abonnés', (
    tester,
  ) async {
    expect(Routes.rolesFor(Routes.chat), isNotNull);
    expect(Routes.rolesFor(Routes.chats), isNotNull);
    expect(Routes.rolesFor(Routes.chatReport), isNotNull);
    expect(Routes.rolesFor(Routes.adminReports), isNotNull);
  });

  testWidgets('liste vide puis discussion reçue avec pastille de non-lus', (
    tester,
  ) async {
    final s = await _setup(tester);
    await go(tester, Routes.chats);
    expect(find.text('Aucune discussion'), findsOneWidget);

    await s.other.sendMessage(s.myId, MessageKind.text, 'Tu viens ce soir ?');
    await settle(tester, 600);

    expect(find.text('Nour Test'), findsWidgets);
    expect(find.text('Tu viens ce soir ?'), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: 'pastille de non-lus');
    await _done(tester, s.b);
  });

  testWidgets('ouvrir une discussion : message lu, non-lu effacé', (
    tester,
  ) async {
    final s = await _setup(tester);
    await s.other.sendMessage(s.myId, MessageKind.text, 'Salut Ahmed');
    await settle(tester, 300);
    await go(tester, Routes.chats);
    expect(s.b.chat.unreadTotal, 1);

    await tester.tap(find.byKey(Key('conv_${s.otherId}')));
    await settle(tester, 800);
    expect(find.text('Salut Ahmed'), findsOneWidget);
    expect(s.b.chat.unreadTotal, 0);
    await _done(tester, s.b);
  });

  testWidgets('envoyer un message : bulle, « Envoyé », puis « Vu »', (
    tester,
  ) async {
    final s = await _setup(tester);
    await go(tester, Routes.chat, s.otherId);
    expect(find.textContaining('Écrivez le premier message'), findsOneWidget);

    await _type(tester, 'Bonjour Nour');
    await tester.tap(find.byKey(const Key('chat_send')));
    await settle(tester, 600);

    expect(find.text('Bonjour Nour'), findsOneWidget);
    expect(find.text('Envoyé'), findsOneWidget);
    expect(s.server.messageCount, 1);

    // Nour lit la discussion : « Vu » apparaît chez Ahmed.
    await s.other.markRead(s.myId);
    await settle(tester, 600);
    expect(find.text('Vu'), findsOneWidget);
    await _done(tester, s.b);
  });

  testWidgets('message reçu en direct dans la discussion ouverte', (
    tester,
  ) async {
    final s = await _setup(tester);
    await go(tester, Routes.chat, s.otherId);
    await s.other.sendMessage(s.myId, MessageKind.text, 'Coucou en direct');
    await settle(tester, 600);
    expect(find.text('Coucou en direct'), findsOneWidget);
    expect(s.b.chat.unreadTotal, 0, reason: 'lu car à l\'écran');
    await _done(tester, s.b);
  });

  testWidgets('« en train d\'écrire » dans la barre du haut', (tester) async {
    final s = await _setup(tester);
    await go(tester, Routes.chat, s.otherId);
    await s.other.setTyping(s.myId, true);
    await settle(tester, 400);
    expect(find.text('est en train d\'écrire…'), findsOneWidget);
    await s.other.setTyping(s.myId, false);
    await settle(tester, 400);
    expect(find.text('est en train d\'écrire…'), findsNothing);
    await _done(tester, s.b);
  });

  testWidgets('supprimer pour tout le monde : une trace reste', (tester) async {
    final s = await _setup(tester);
    await go(tester, Routes.chat, s.otherId);
    await _type(tester, 'Message à retirer');
    await tester.tap(find.byKey(const Key('chat_send')));
    await settle(tester, 600);

    await tester.longPress(find.text('Message à retirer'));
    await settle(tester, 500);
    await tester.tap(find.byKey(const Key('msg_delete_all')));
    await settle(tester, 500);
    await tester.tap(find.text('Supprimer'));
    await settle(tester, 800);

    expect(find.text('Message à retirer'), findsNothing);
    expect(find.text('Ce message a été supprimé'), findsOneWidget);
    await _done(tester, s.b);
  });

  testWidgets('un message de l\'autre ne se supprime que pour soi', (
    tester,
  ) async {
    final s = await _setup(tester);
    await s.other.sendMessage(s.myId, MessageKind.text, 'Message reçu');
    await settle(tester, 300);
    await go(tester, Routes.chat, s.otherId);
    await tester.longPress(find.text('Message reçu'));
    await settle(tester, 500);
    expect(find.byKey(const Key('msg_delete_me')), findsOneWidget);
    expect(find.byKey(const Key('msg_delete_all')), findsNothing);
    await tester.tap(find.byKey(const Key('msg_delete_me')));
    await settle(tester, 600);
    expect(find.text('Message reçu'), findsNothing);
    await _done(tester, s.b);
  });

  testWidgets('signaler la discussion : au moins un message, remarque libre', (
    tester,
  ) async {
    final s = await _setup(tester);
    await s.other.sendMessage(s.myId, MessageKind.text, 'Premier');
    await s.other.sendMessage(s.myId, MessageKind.text, 'Insulte grave');
    await settle(tester, 400);
    await go(tester, Routes.chatReport, s.otherId);

    final submit = find.byKey(const Key('report_submit'));
    expect(tester.widget<ElevatedButton>(submit).onPressed, isNull);
    expect(find.text('Sélectionnez au moins un message'), findsOneWidget);

    await tester.tap(find.text('Insulte grave'));
    await settle(tester, 300);
    expect(tester.widget<ElevatedButton>(submit).onPressed, isNotNull);

    // La remarque n'est pas obligatoire.
    await tester.tap(submit);
    await settle(tester, 800);
    expect(s.server.reportCount, 1);
    await _done(tester, s.b);
  });

  testWidgets('menu de la discussion : signaler la discussion, bloquer', (
    tester,
  ) async {
    final s = await _setup(tester);
    await go(tester, Routes.chat, s.otherId);
    await tester.tap(find.byKey(const Key('chat_menu')));
    await settle(tester, 400);
    expect(find.text('Signaler la discussion'), findsOneWidget);
    expect(find.text('Bloquer'), findsOneWidget);
    expect(find.text('Archiver'), findsOneWidget);
    expect(find.text('Supprimer la discussion'), findsOneWidget);
    expect(find.text('Mettre en silence'), findsOneWidget);

    await tester.tap(find.text('Bloquer'));
    await settle(tester, 500);
    await tester.tap(find.text('Bloquer').last);
    await settle(tester, 1000);
    expect(s.server.blockCount, 1);
    expect(s.b.friends.friends, isEmpty);
    await _done(tester, s.b);
  });

  testWidgets('conversation archivée : visible dans « Archivées »', (
    tester,
  ) async {
    final s = await _setup(tester);
    await s.other.sendMessage(s.myId, MessageKind.text, 'Message');
    await settle(tester, 300);
    await s.b.chat.setArchived(s.otherId, true);
    await go(tester, Routes.chats);
    expect(find.text('Aucune discussion'), findsOneWidget);
    await tester.tap(find.byKey(const Key('toggle_archived')));
    await settle(tester, 400);
    expect(find.text('Nour Test'), findsWidgets);
    await _done(tester, s.b);
  });

  testWidgets('partager un workout depuis la discussion', (tester) async {
    final s = await _setup(tester);
    await go(tester, Routes.chat, s.otherId);
    await tester.tap(find.byKey(const Key('chat_attach')));
    await settle(tester, 500);
    await tester.tap(find.byKey(const Key('share_type_workout')));
    await settle(tester, 500);
    final pick = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('share_pick_'),
    );
    await tester.tap(pick.first);
    await settle(tester, 1000);

    expect(find.byKey(const Key('share_view')), findsOneWidget);
    expect(
      find.byKey(const Key('share_save')),
      findsNothing,
      reason: 'on n\'enregistre pas sa propre carte',
    );
    final sent = (await s.other.loadMessages(s.myId)).single;
    expect(sent.kind, MessageKind.share);
    expect(sent.share!.type, 'workout');
    await _done(tester, s.b);
  });

  testWidgets('carte reçue : aperçu puis « Enregistrer chez moi »', (
    tester,
  ) async {
    final s = await _setup(tester);
    final workout = s.b.share.workouts().first;
    final card = s.b.share.workoutCard(workout);
    await s.other.sendMessage(s.myId, MessageKind.share, card.encode());
    await settle(tester, 400);
    await go(tester, Routes.chat, s.otherId);

    expect(find.text(workout.name), findsWidgets);
    await tester.tap(find.byKey(const Key('share_view')));
    await settle(tester, 600);
    expect(find.byKey(const Key('share_detail')), findsOneWidget);
    expect(find.byKey(const Key('share_save_detail')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // referme la feuille
    await settle(tester, 600);

    final before = s.b.workouts.all.length;
    await tester.tap(find.byKey(const Key('share_save')));
    await settle(tester, 1000);
    expect(s.b.workouts.all.length, before + 1);
    expect(find.textContaining('enregistré dans vos workouts'), findsOneWidget);
    await _done(tester, s.b);
  });

  testWidgets('séance reçue : aperçu seulement, pas d\'enregistrement', (
    tester,
  ) async {
    final s = await _setup(tester);
    final card = s.b.share.sessionCard(s.b.share.mySessions().first);
    await s.other.sendMessage(s.myId, MessageKind.share, card.encode());
    await settle(tester, 400);
    await go(tester, Routes.chat, s.otherId);
    expect(find.byKey(const Key('share_view')), findsOneWidget);
    expect(find.byKey(const Key('share_save')), findsNothing);
    await _done(tester, s.b);
  });

  testWidgets('écran administrateur : connexion puis signalements', (
    tester,
  ) async {
    final server = FakeFriendsServer();
    // Un signalement existe déjà sur le serveur.
    final a = server.phone();
    final n = server.phone();
    await a.signIn(email: 'a@x.tn', password: 'x', displayName: 'Alice');
    await a.updateProfile(displayName: 'Alice', enabled: true);
    await n.signIn(email: 'b@x.tn', password: 'x', displayName: 'Bob');
    await n.updateProfile(displayName: 'Bob', enabled: true);
    await a.sendRequest('b@x.tn');
    final req = (await n.loadRequests()).single;
    await n.respond(req.id, true);
    final id = await a.sendMessage(
      n.userId!,
      MessageKind.text,
      'Propos abusif',
    );
    await n.reportConversation(a.userId!, [id], remark: 'Il me harcèle');

    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'admin@gymflow.tn',
      friendsRemote: server.phone(),
    );
    expect(find.byKey(const Key('admin_reports_button')), findsOneWidget);
    await go(tester, Routes.adminReports);
    expect(find.byKey(const Key('reports_connect')), findsOneWidget);

    await tester.tap(find.byKey(const Key('reports_connect_button')));
    await settle(tester, 600);
    await tester.enterText(find.byType(TextFormField).last, 'Admin2026!');
    await tester.tap(find.text('Valider'));
    await settle(tester, 1200);

    expect(find.textContaining('Bob signale Alice'), findsOneWidget);
    expect(find.text('Propos abusif'), findsOneWidget);
    expect(find.textContaining('Il me harcèle'), findsOneWidget);
    await _done(tester, b);
  });
}
