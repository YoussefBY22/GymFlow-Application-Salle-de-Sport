// Niveau : widget (sans réseau). Réglage « Mesure d'audience anonyme » :
// éteint par défaut, modifiable par un abonné majeur, absent pour la salle.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/routes.dart';

import 'helpers.dart';
import 'widget_helpers.dart';

void main() {
  testWidgets('abonné : interrupteur éteint par défaut, activable', (
    tester,
  ) async {
    final b = await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'ahmed@gymflow.tn',
    );
    await go(tester, Routes.privacy);
    final tile = find.byKey(const Key('privacy_analytics'));
    await tester.scrollUntilVisible(
      tile,
      300,
      scrollable: mainScrollable(tester),
    );
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(b.auth.currentUser!.privacy.analytics, isFalse);

    await tester.tap(tile);
    await settle(tester, 600);
    expect(b.auth.currentUser!.privacy.analytics, isTrue);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
  });

  testWidgets('mineur : interrupteur désactivé', (tester) async {
    final b = await pumpApp(tester);
    final nour = b.users.byId('u_nour')!;
    await b.users.save(nour.copyWith(age: 16));
    await loginAs(b, 'nour@gymflow.tn');
    await go(tester, Routes.privacy);
    final tile = find.byKey(const Key('privacy_analytics'));
    await tester.scrollUntilVisible(
      tile,
      300,
      scrollable: mainScrollable(tester),
    );
    expect(tester.widget<SwitchListTile>(tile).onChanged, isNull);
  });

  testWidgets('administrateur : aucun réglage de mesure', (tester) async {
    await pumpApp(
      tester,
      route: Routes.home,
      loginEmail: 'admin@gymflow.tn',
    );
    await go(tester, Routes.privacy);
    expect(find.byKey(const Key('privacy_analytics')), findsNothing);
  });
}
