import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/core/routes.dart';

import 'widget_helpers.dart';

void main() {
  testWidgets('le coach voit ses propositions à valider dès son accueil', (
    tester,
  ) async {
    await pumpApp(tester, route: Routes.home, loginEmail: 'sarra@gymflow.tn');

    expect(find.byKey(const Key('coach_pending_review')), findsOneWidget);
    expect(find.byKey(const Key('review_queue')), findsOneWidget);
    expect(find.textContaining('proposition'), findsOneWidget);

    await tester.tap(find.byKey(const Key('coach_pending_review')));
    await settle(tester);

    expect(find.text('Propositions à valider'), findsOneWidget);
  });
}
