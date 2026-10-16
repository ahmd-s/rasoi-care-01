import 'dart:async';

import 'package:care_plus/core/theme/care_plus_theme.dart';
import 'package:care_plus/data/api/passport_client.dart';
import 'package:care_plus/features/passport/kitchen_passport_screen.dart';
import 'package:care_plus/l10n/app_localizations.dart';
import 'package:care_plus/state/passport_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

PassportAppliance _a({
  String id = 'KAPP-1',
  String category = 'hob',
  int? score = 78,
  String? status = 'attention',
  List<String> items = const ['Ignition'],
  bool safety = false,
  bool photo = false,
  PassportNextService? next =
      const PassportNextService(urgency: 'soon', estimatedDays: 21),
  List<PassportVisit> history = const [],
}) =>
    PassportAppliance(
      id: id,
      category: category,
      brand: 'Elica',
      model: 'Flexi',
      score: score,
      status: status,
      checksTested: score == null ? 3 : 8,
      checksTotal: 8,
      notEnoughChecks: score == null,
      safetyFlagged: safety,
      attentionItems: items,
      includesPhotoReview: photo,
      nextService: next,
      history: history,
    );

KitchenPassport _p({
  int? score = 78,
  String? status = 'attention',
  List<PassportAppliance>? appliances,
  PassportNextService? next = const PassportNextService(
      urgency: 'soon', estimatedDays: 21, applianceId: 'KAPP-1'),
  List<String> needs = const ['KAPP-1'],
  bool safety = false,
}) {
  final list = appliances ?? [_a()];
  return KitchenPassport(
    score: score,
    status: status,
    registeredCount: list.length,
    assessedCount: list.where((a) => a.score != null).length,
    safetyFlagged: safety,
    nextService: next,
    appliances: list,
    needsAttention: needs,
  );
}

class _Client extends PassportClient {
  _Client(this._results) : super(tokenProvider: () async => 't');
  final List<Future<PassportResult> Function()> _results;
  var calls = 0;
  @override
  Future<PassportResult> overview() =>
      _results[calls++ < _results.length ? calls - 1 : _results.length - 1]();
}

Future<PassportResult> Function() _ok(KitchenPassport p) =>
    () async => PassportResult.ok(p);
Future<PassportResult> Function() _fail(PassportFailureKind k) =>
    () async => PassportResult.fail(PassportFailure(k));

Future<void> _pump(WidgetTester tester, _Client client,
    {Locale locale = const Locale('en'),
    double scale = 1,
    Size size = const Size(360, 2400)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [passportClientProvider.overrideWithValue(client)],
    child: MaterialApp(
      theme: CarePlusTheme.light(),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: const KitchenPassportScreen(),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows a spinner while loading', (tester) async {
    final gate = Completer<PassportResult>();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        passportClientProvider.overrideWithValue(_Client([() => gate.future]))
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: CarePlusTheme.light(),
        home: const KitchenPassportScreen(),
      ),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete(PassportResult.ok(_p()));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the kitchen score, status, coverage and basis',
      (tester) async {
    await _pump(tester, _Client([_ok(_p())]));
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('passport-kitchen-score')))
            .data,
        '78');
    expect(find.text('Attention'), findsWidgets);
    expect(find.text('1 of 1 appliances assessed'), findsOneWidget);
    expect(find.text('Based on technician checks'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('passport-kitchen-noscore')), findsNothing);
  });

  testWidgets(
      'shows each appliance score, checks, flagged items and per-appliance guidance',
      (tester) async {
    await _pump(tester, _Client([_ok(_p())]));
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('passport-score-KAPP-1')))
            .data,
        '78');
    expect(find.text('Hob · Elica Flexi'), findsWidgets);
    expect(find.text('8 of 8 checks tested'), findsOneWidget);
    expect(find.text('Technician check'), findsOneWidget);
    expect(find.text('Flagged by your technician: Ignition'), findsWidgets);
    expect(find.byKey(const ValueKey('passport-attention-KAPP-1')),
        findsOneWidget);
  });

  testWidgets('shows the next recommended service with its estimated timing',
      (tester) async {
    await _pump(tester, _Client([_ok(_p())]));
    final card = find.byKey(const ValueKey('passport-next-service'));
    expect(
        find.descendant(
            of: card, matching: find.text('NEXT RECOMMENDED SERVICE')),
        findsOneWidget);
    expect(
        find.descendant(
            of: card,
            matching: find.text('Book a service within about three weeks.')),
        findsOneWidget);
    expect(
        find.descendant(of: card, matching: find.text('Within about 21 days')),
        findsOneWidget);
    expect(
        find.descendant(
            of: card, matching: find.text('For: Hob · Elica Flexi')),
        findsOneWidget);
  });

  testWidgets('urgent guidance reads as soon as possible', (tester) async {
    await _pump(
        tester,
        _Client([
          _ok(_p(
            score: 40,
            status: 'critical',
            next: const PassportNextService(
                urgency: 'urgent', estimatedDays: 0, applianceId: 'KAPP-1'),
            appliances: [
              _a(
                  score: 40,
                  status: 'critical',
                  next: const PassportNextService(
                      urgency: 'urgent', estimatedDays: 0))
            ],
          )),
        ]));
    final card = find.byKey(const ValueKey('passport-next-service'));
    expect(
        find.descendant(of: card, matching: find.text('As soon as possible')),
        findsOneWidget);
  });

  testWidgets(
      'a missing score is stated honestly: no number, no status, no recommendation',
      (tester) async {
    await _pump(
        tester,
        _Client([
          _ok(_p(
              score: null,
              status: null,
              next: null,
              needs: const [],
              appliances: [
                _a(score: null, status: null, items: const [], next: null)
              ])),
        ]));
    expect(
        find.byKey(const ValueKey('passport-kitchen-noscore')), findsOneWidget);
    expect(find.text('No score yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('passport-kitchen-score')), findsNothing);
    expect(
        find.byKey(const ValueKey('passport-noscore-KAPP-1')), findsOneWidget);
    expect(find.text('Not enough checks to score yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('passport-score-KAPP-1')), findsNothing);
    expect(find.byKey(const ValueKey('passport-next-service')), findsNothing);
    expect(find.text('Needs attention'), findsNothing);
  });

  testWidgets('safety flags are shown on the kitchen and the appliance',
      (tester) async {
    await _pump(
        tester,
        _Client([
          _ok(_p(safety: true, appliances: [
            _a(safety: true, items: const ['Safety'])
          ])),
        ]));
    expect(
        find.byKey(const ValueKey('passport-kitchen-safety')), findsOneWidget);
    expect(find.text('Safety item flagged — please have it checked'),
        findsWidgets);
  });

  testWidgets(
      'a reviewed-photo score is labelled; a technician-only one is not',
      (tester) async {
    await _pump(
        tester,
        _Client([
          _ok(_p(appliances: [
            _a(photo: true),
            _a(
                id: 'KAPP-2',
                category: 'chimney',
                items: const [],
                status: 'healthy',
                score: 95)
          ])),
        ]));
    expect(find.text('Technician check + reviewed photo analysis'),
        findsOneWidget);
    expect(find.text('Technician check'), findsOneWidget);
  });

  testWidgets('service history lists real visits, or says there are none',
      (tester) async {
    await _pump(
        tester,
        _Client([
          _ok(_p(appliances: [
            _a(history: [
              PassportVisit(
                  date: DateTime.utc(2026, 10, 1, 10),
                  serviceName: 'Deep Cleaning',
                  score: 93,
                  status: 'healthy',
                  safetyFlagged: false),
              const PassportVisit(
                  date: null,
                  serviceName: 'Repair visit',
                  score: null,
                  status: null,
                  safetyFlagged: false),
            ]),
            _a(id: 'KAPP-2', category: 'chimney', history: const []),
          ])),
        ]));
    await tester.tap(find.byKey(const ValueKey('passport-history-KAPP-1')));
    await tester.pumpAndSettle();
    expect(find.text('Deep Cleaning'), findsOneWidget);
    expect(find.text('Score 93'), findsOneWidget);
    expect(find.text('Repair visit'), findsOneWidget);
    expect(find.text('Not scored'), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('passport-history-KAPP-2')));
    await tester.tap(find.byKey(const ValueKey('passport-history-KAPP-2')));
    await tester.pumpAndSettle();
    expect(find.text('No checked visits recorded yet.'), findsOneWidget);
  });

  testWidgets('no appliances: an empty state, no score card', (tester) async {
    await _pump(
        tester,
        _Client([
          _ok(const KitchenPassport(
              score: null,
              status: null,
              registeredCount: 0,
              assessedCount: 0,
              safetyFlagged: false,
              nextService: null,
              appliances: [],
              needsAttention: [])),
        ]));
    expect(find.text('No appliances registered yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('passport-kitchen-card')), findsNothing);
  });

  testWidgets('a network error shows a retry that reloads', (tester) async {
    final client = _Client([_fail(PassportFailureKind.network), _ok(_p())]);
    await _pump(tester, client);
    expect(find.textContaining("Couldn't load your Kitchen Passport"),
        findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(client.calls, 2);
    expect(
        find.byKey(const ValueKey('passport-kitchen-score')), findsOneWidget);
  });

  testWidgets('a signed-out failure asks the customer to sign in again',
      (tester) async {
    await _pump(tester, _Client([_fail(PassportFailureKind.signedOut)]));
    expect(find.text('Sign in again to see your Kitchen Passport.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('passport-kitchen-card')), findsNothing);
  });

  testWidgets('the disclaimer is always present', (tester) async {
    await _pump(tester, _Client([_ok(_p())]));
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('passport-disclaimer')), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const ValueKey('passport-disclaimer')), findsOneWidget);
  });

  testWidgets('renders in Hindi and Marathi', (tester) async {
    await _pump(tester, _Client([_ok(_p())]), locale: const Locale('hi'));
    expect(find.text('किचन पासपोर्ट'), findsWidgets);
    expect(find.text('ध्यान दें'), findsWidgets);
    await _pump(tester, _Client([_ok(_p())]), locale: const Locale('mr'));
    expect(find.text('लक्ष द्या'), findsWidgets);
  });

  testWidgets('fits a small screen with large text', (tester) async {
    await _pump(tester, _Client([_ok(_p())]),
        size: const Size(320, 568), scale: 1.5);
    expect(tester.takeException(), isNull);
  });
}
