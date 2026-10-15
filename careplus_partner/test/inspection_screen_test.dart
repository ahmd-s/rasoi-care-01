import 'package:care_plus_partner/core/theme/care_plus_theme.dart';
import 'package:care_plus_partner/data/api/passport_api.dart';
import 'package:care_plus_partner/features/passport/inspection_catalog.dart';
import 'package:care_plus_partner/features/passport/inspection_screen.dart';
import 'package:care_plus_partner/features/passport/kitchen_passport_screen.dart';
import 'package:care_plus_partner/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _hob = KitchenAppliance(
  id: 'KAPP-1', category: 'hob', brand: 'Elica', model: 'Flexi 4B', serialNumber: '',
  installYear: null, specs: {'fuel': 'gas', 'burners': 4}, notes: '',
);

Inspection _inspection({Map<String, (InspectionResult, String)> saved = const {}}) => Inspection(
      applianceId: 'KAPP-1',
      category: 'hob',
      checks: [
        for (final i in checklistFor('hob'))
          InspectionCheck(
            key: i.key,
            label: i.label,
            result: saved[i.key]?.$1,
            note: saved[i.key]?.$2 ?? '',
          ),
      ],
    );

class _FakeApi extends PassportApi {
  _FakeApi({Inspection? initial, this.loadError, this.saveError})
      : _stored = initial ?? _inspection(),
        super(tokenProvider: () async => 't');

  Inspection _stored;
  final String? loadError;
  final String? saveError;
  final saves = <List<({String key, InspectionResult result, String note})>>[];
  var loads = 0;

  @override
  Future<PassportResult<Inspection>> inspectionFor(String bookingId, String applianceId) async {
    loads++;
    if (loadError != null && loads == 1) return PassportResult.failure(loadError);
    return PassportResult.ok(_stored);
  }

  @override
  Future<PassportResult<Inspection>> saveInspection(String bookingId, String applianceId,
      List<({String key, InspectionResult result, String note})> results) async {
    saves.add(results);
    if (saveError != null) return PassportResult.failure(saveError);
    _stored = _inspection(saved: {for (final e in results) e.key: (e.result, e.note)});
    return PassportResult.ok(_stored);
  }
}

Future<void> _pump(WidgetTester tester, _FakeApi api, {Size size = const Size(360, 740)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [passportApiProvider.overrideWithValue(api)],
    child: MaterialApp(
      theme: CarePlusTheme.light(),
      home: const InspectionScreen(jobId: 'B-1', appliance: _hob),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _choice(String itemLabel, String choice) => find.descendant(
      of: find.ancestor(of: find.text(itemLabel), matching: find.byType(Column)).first,
      matching: find.text(choice),
    );

Future<void> _reveal(WidgetTester tester, Finder target) async {
  // The checklist is a lazy ListView: jump to the top, then scroll down until
  // the target has been built and is on screen.
  final list = find.byType(Scrollable).first;
  if (target.evaluate().isEmpty) {
    await tester.drag(list, const Offset(0, 5000));
    await tester.pumpAndSettle();
  }
  await tester.scrollUntilVisible(target, 120, scrollable: list);
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String itemLabel, String choice) async {
  await _reveal(tester, find.text(itemLabel));
  await tester.tap(_choice(itemLabel, choice).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the hob checklist with nothing recorded, on a 360dp screen', (tester) async {
    await _pump(tester, _FakeApi());
    expect(find.text('Hob / Cooktop checklist'), findsOneWidget);
    expect(find.text('Elica · Flexi 4B'), findsOneWidget);
    expect(find.text('0 OF 8 RECORDED'), findsOneWidget);
    expect(find.text('Burner performance'), findsOneWidget);
    expect(tester.takeException(), isNull); // no overflow at small width
    // Nothing to save yet.
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });

  testWidgets('reloads previously saved results and notes', (tester) async {
    await _pump(
      tester,
      _FakeApi(initial: _inspection(saved: {
        'ignition': (InspectionResult.attention, 'clicks slowly'),
        'safety': (InspectionResult.good, ''),
      })),
    );
    expect(find.text('2 OF 8 RECORDED'), findsOneWidget);
    expect(find.text('clicks slowly'), findsOneWidget);
  });

  testWidgets('a note field appears only for Attention and Not tested', (tester) async {
    await _pump(tester, _FakeApi());
    expect(find.byType(TextField), findsNothing);
    await _pick(tester, 'Ignition', 'Attention');
    expect(find.byKey(const ValueKey('note-ignition')), findsOneWidget);
    await _pick(tester, 'Ignition', 'Good');
    expect(find.byKey(const ValueKey('note-ignition')), findsNothing);
    await _pick(tester, 'Gas flow', 'Not tested');
    expect(find.byKey(const ValueKey('note-gas_flow')), findsOneWidget);
  });

  testWidgets('saves recorded items; Good drops any note', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);
    await _pick(tester, 'Ignition', 'Attention');
    await tester.enterText(find.byKey(const ValueKey('note-ignition')), '  clicks slowly ');
    await _pick(tester, 'Gas flow', 'Not tested');
    await tester.enterText(find.byKey(const ValueKey('note-gas_flow')), 'Induction hob');
    await _pick(tester, 'Safety', 'Attention');
    await _reveal(tester, find.byKey(const ValueKey('note-safety')));
    await tester.enterText(find.byKey(const ValueKey('note-safety')), 'will be dropped');
    await _pick(tester, 'Safety', 'Good');
    await _pick(tester, 'Pan support', 'Good');

    await tester.tap(find.text('Save checklist'));
    await tester.pumpAndSettle();

    expect(api.saves, hasLength(1));
    final byKey = {for (final e in api.saves.single) e.key: e};
    expect(byKey.keys.toSet(), {'ignition', 'gas_flow', 'safety', 'pan_support'});
    expect(byKey['ignition']!.result, InspectionResult.attention);
    expect(byKey['ignition']!.note, 'clicks slowly');
    expect(byKey['gas_flow']!.result, InspectionResult.notTested);
    expect(byKey['gas_flow']!.note, 'Induction hob');
    expect(byKey['safety']!.result, InspectionResult.good);
    expect(byKey['safety']!.note, '');
    expect(find.text('Checklist saved'), findsOneWidget);
    await _reveal(tester, find.text('4 OF 8 RECORDED'));
    expect(find.text('4 OF 8 RECORDED'), findsOneWidget);
    // Saved, so there is nothing further to save.
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });

  testWidgets('a rejected save (closed booking) shows the server message', (tester) async {
    final api = _FakeApi(saveError: 'This booking is completed; appliances can no longer be registered on it.');
    await _pump(tester, api);
    await _pick(tester, 'Ignition', 'Good');
    await tester.tap(find.text('Save checklist'));
    await tester.pumpAndSettle();
    await _reveal(tester, find.textContaining('This booking is completed'));
    expect(find.textContaining('This booking is completed'), findsOneWidget);
    // Still editable so the technician's input isn't lost.
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
  });

  testWidgets('a failed load shows the error and Retry reloads', (tester) async {
    final api = _FakeApi(loadError: 'This job is no longer assigned to you.');
    await _pump(tester, api);
    expect(find.text('Could not load the checklist'), findsOneWidget);
    expect(find.text('This job is no longer assigned to you.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Burner performance'), findsOneWidget);
    expect(api.loads, 2);
  });

  testWidgets('tapping a registered appliance opens its own checklist', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/tech/job/B-1/kitchen',
      routes: [
        GoRoute(
          path: '/tech/job/:id/kitchen',
          builder: (_, s) => KitchenPassportScreen(jobId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/tech/job/:id/kitchen/appliance/:aid/inspection',
          builder: (_, s) => InspectionScreen(
              jobId: s.pathParameters['id']!, appliance: s.extra as KitchenAppliance),
        ),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        passportApiProvider.overrideWithValue(_FakeApi()),
        kitchenAppliancesProvider('B-1').overrideWith((_) async => [_hob]),
      ],
      child: MaterialApp.router(routerConfig: router, theme: CarePlusTheme.light()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Open checklist ›'), findsOneWidget);
    await tester.tap(find.text('Hob / Cooktop'));
    await tester.pumpAndSettle();
    expect(find.text('Hob / Cooktop checklist'), findsOneWidget);
    expect(find.text('Burner performance'), findsOneWidget);
  });
}
