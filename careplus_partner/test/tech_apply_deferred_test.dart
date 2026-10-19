import 'package:care_plus_partner/core/theme/care_plus_theme.dart';
import 'package:care_plus_partner/features/apply/tech_apply_screen.dart';
import 'package:care_plus_partner/l10n/app_localizations.dart';
import 'package:care_plus_partner/state/auth_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _rec(bool deferred) =>
    {'applicationSubmitted': false, 'verified': false, 'documentsDeferred': deferred};

/// [cached] = what the app had in memory (possibly stale); [server] = what the
/// server returns right now (null = unreachable).
Future<AppLocalizations> _pump(
  WidgetTester t, {
  Map<String, dynamic>? cached,
  required Map<String, dynamic>? server,
  required bool productionApi,
  int loaderCalls = -1,
}) async {
  t.view.physicalSize = const Size(1080, 6000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    overrides: [
      isProductionApiProvider.overrideWithValue(productionApi),
      technicianMeLoaderProvider.overrideWithValue(() async => server),
      if (cached != null) technicianMeProvider.overrideWith((ref) => cached),
    ],
    child: MaterialApp(
      theme: CarePlusTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const TechApplyScreen(),
    ),
  ));
  await t.pump(); // post-frame mode load
  await t.pump();
  return AppLocalizations.of(t.element(find.byType(Scaffold).first))!;
}

void _expectNoUploadControls(AppLocalizations l) {
  expect(find.text(l.applyAadhaarFrontUpload), findsNothing);
  expect(find.text(l.applyAadhaarBackUpload), findsNothing);
  expect(find.text(l.applyPanUpload), findsNothing);
  expect(find.text(l.applyPassbookUpload), findsNothing);
  expect(find.text(l.applyPhotoHint), findsNothing);
}

void main() {
  testWidgets('fresh login (nothing cached) + server says deferred: note, no upload controls', (t) async {
    final l = await _pump(t, server: _rec(true), productionApi: false);
    expect(find.byKey(const Key('docs-deferred-note')), findsOneWidget);
    expect(find.textContaining('owner approval'), findsOneWidget);
    _expectNoUploadControls(l);
    expect(find.text(l.applyAadhaarNumber), findsOneWidget); // typed details still collected
  });

  testWidgets('production API, server not deferred: required document pickers are shown', (t) async {
    final l = await _pump(t, server: _rec(false), productionApi: true);
    expect(find.byKey(const Key('docs-deferred-note')), findsNothing);
    expect(find.text(l.applyAadhaarFrontUpload), findsOneWidget);
    expect(find.text(l.applyAadhaarBackUpload), findsOneWidget);
    expect(find.text(l.applyPanUpload), findsOneWidget);
  });

  testWidgets('stale cache says deferred but server says no (production): server wins', (t) async {
    final l = await _pump(t, cached: _rec(true), server: _rec(false), productionApi: true);
    expect(find.byKey(const Key('docs-deferred-note')), findsNothing);
    expect(find.text(l.applyAadhaarBackUpload), findsOneWidget);
  });

  testWidgets('stale cache says deferred but staging server is not: config error, no form', (t) async {
    final l = await _pump(t, cached: _rec(true), server: _rec(false), productionApi: false);
    expect(find.byKey(const Key('staging-misconfigured')), findsOneWidget);
    expect(find.textContaining('Staging configuration error'), findsOneWidget);
    _expectNoUploadControls(l);
    expect(find.text(l.applyAadhaarNumber), findsNothing); // no form at all
  });

  testWidgets('stale cache says NOT deferred but server now says deferred: server wins', (t) async {
    final l = await _pump(t, cached: _rec(false), server: _rec(true), productionApi: false);
    expect(find.byKey(const Key('docs-deferred-note')), findsOneWidget);
    _expectNoUploadControls(l);
  });

  testWidgets('server unreachable: no form is drawn from stale state, retry offered', (t) async {
    final l = await _pump(t, cached: _rec(true), server: null, productionApi: true);
    expect(find.byKey(const Key('mode-load-failed')), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    _expectNoUploadControls(l);
    expect(find.text(l.applyAadhaarNumber), findsNothing);
  });
}
