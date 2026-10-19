import 'package:care_plus_partner/core/theme/care_plus_theme.dart';
import 'package:care_plus_partner/features/apply/tech_apply_screen.dart';
import 'package:care_plus_partner/l10n/app_localizations.dart';
import 'package:care_plus_partner/state/auth_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<AppLocalizations> _pump(WidgetTester t, {required bool deferred}) async {
  t.view.physicalSize = const Size(1080, 6000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    overrides: [
      technicianMeProvider.overrideWith((ref) => {
            'applicationSubmitted': false,
            'verified': false,
            'documentsDeferred': deferred,
          }),
    ],
    child: MaterialApp(
      theme: CarePlusTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const TechApplyScreen(),
    ),
  ));
  await t.pump();
  return AppLocalizations.of(t.element(find.byType(TechApplyScreen)))!;
}

void main() {
  testWidgets('staging (deferred): note shown, no photo/document upload controls', (t) async {
    final l = await _pump(t, deferred: true);
    expect(find.byKey(const Key('docs-deferred-note')), findsOneWidget);
    expect(find.textContaining('owner approval'), findsOneWidget);
    expect(find.text(l.applyAadhaarFrontUpload), findsNothing);
    expect(find.text(l.applyAadhaarBackUpload), findsNothing);
    expect(find.text(l.applyPanUpload), findsNothing);
    expect(find.text(l.applyPassbookUpload), findsNothing);
    expect(find.text(l.applyPhotoHint), findsNothing);
    // the typed fields are still collected
    expect(find.text(l.applyAadhaarNumber), findsOneWidget);
    expect(find.text(l.applyPanNumber), findsOneWidget);
  });

  testWidgets('production (not deferred): document pickers are shown and no note', (t) async {
    final l = await _pump(t, deferred: false);
    expect(find.byKey(const Key('docs-deferred-note')), findsNothing);
    expect(find.text(l.applyAadhaarFrontUpload), findsOneWidget);
    expect(find.text(l.applyAadhaarBackUpload), findsOneWidget);
    expect(find.text(l.applyPanUpload), findsOneWidget);
    expect(find.text(l.applyPassbookUpload), findsOneWidget);
  });

  testWidgets('unknown mode defaults to production behaviour', (t) async {
    t.view.physicalSize = const Size(1080, 6000);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: CarePlusTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const TechApplyScreen(),
      ),
    ));
    await t.pump();
    expect(find.byKey(const Key('docs-deferred-note')), findsNothing);
    final l = AppLocalizations.of(t.element(find.byType(TechApplyScreen)))!;
    expect(find.text(l.applyAadhaarFrontUpload), findsOneWidget);
  });
}
