import 'package:care_plus_partner/core/theme/care_plus_theme.dart';
import 'package:care_plus_partner/features/apply/tech_profile_screen.dart';
import 'package:care_plus_partner/l10n/app_localizations.dart';
import 'package:care_plus_partner/state/auth_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester t, Future<Map<String, dynamic>?> Function() loader,
    {Map<String, dynamic>? preset}) async {
  t.view.physicalSize = const Size(1080, 3000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    overrides: [
      technicianMeLoaderProvider.overrideWithValue(loader),
      if (preset != null) technicianMeProvider.overrideWith((ref) => preset),
    ],
    child: MaterialApp(
      theme: CarePlusTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const TechProfileScreen(),
    ),
  ));
}

void main() {
  testWidgets('opening Profile loads the technician record itself', (t) async {
    var calls = 0;
    await _pump(t, () async {
      calls++;
      return {'name': 'Asha Technician', 'verified': false};
    });
    await t.pump(); // post-frame refresh
    await t.pump();
    expect(calls, 1);
    expect(find.text('Asha Technician'), findsOneWidget);
    expect(find.textContaining("Couldn't load"), findsNothing);
  });

  testWidgets('an already-loaded record is shown without another request', (t) async {
    var calls = 0;
    await _pump(t, () async {
      calls++;
      return null;
    }, preset: {'name': 'Preloaded', 'verified': true});
    await t.pump();
    expect(calls, 0);
    expect(find.text('Preloaded'), findsOneWidget);
  });

  testWidgets('a failed load shows the error (no crash) and refresh can recover', (t) async {
    var ok = false;
    await _pump(t, () async => ok ? {'name': 'Recovered', 'verified': false} : null);
    await t.pump();
    await t.pump();
    expect(find.textContaining("Couldn't load your profile"), findsOneWidget);
    ok = true;
    await t.tap(find.byIcon(Icons.refresh));
    await t.pump();
    await t.pump();
    expect(find.text('Recovered'), findsOneWidget);
  });
}
