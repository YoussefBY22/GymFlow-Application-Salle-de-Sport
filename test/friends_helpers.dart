// Outils communs des tests de la fonction Amis et de la messagerie : deux
// « téléphones » (deux backends) reliés par un faux serveur.
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/services/backend.dart';
import 'package:gymflow/services/push/push_gateway.dart';

import 'friends_fake.dart';
import 'helpers.dart';

const kPwd = 'Membre2026!';
const kAhmed = 'ahmed@gymflow.tn';
const kNour = 'nour@gymflow.tn';

typedef Phone = ({Backend b, FakeFriendsRemote r});

/// Laisse passer les événements en direct (flux et chaînes d'attentes).
Future<void> flush() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Phone> phone(
  FakeFriendsServer server,
  String email, {
  DateTime? now,
  PushGateway? push,
}) async {
  final r = server.phone();
  final b = await makeBackend(friendsRemote: r, now: now, pushGateway: push);
  await loginAs(b, email);
  addTearDown(() {
    b.friends.stop();
    b.chat.stop();
  });
  return (b: b, r: r);
}

/// Active la fonction et attend que tout soit en place.
Future<void> enable(Phone p) async {
  await p.b.friends.enable(kPwd);
  await flush();
}

/// Deux amis déjà acceptés, tous deux connectés.
Future<(Phone, Phone)> friendsPair(FakeFriendsServer server) async {
  final a = await phone(server, kAhmed);
  final n = await phone(server, kNour);
  await enable(a);
  await enable(n);
  await a.b.friends.sendRequest(kNour);
  await flush();
  await n.b.friends.respond(n.b.friends.requests.single, true);
  await flush();
  return (a, n);
}

/// Identifiant Supabase de l'ami (la seule personne de la liste).
String friendIdOf(Phone p) => p.b.friends.friends.single.id;
