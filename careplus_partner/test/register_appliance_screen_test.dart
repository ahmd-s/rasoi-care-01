import 'package:care_plus_partner/core/theme/care_plus_theme.dart';
import 'package:care_plus_partner/data/api/passport_api.dart';
import 'package:care_plus_partner/features/passport/register_appliance_screen.dart';
import 'package:care_plus_partner/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeApi extends PassportApi {
  _FakeApi({this.saved = const [], this.addResult, this.failFirstRegister = false})
      : super(tokenProvider: () async => 't');

  final bool failFirstRegister;

  final List<String> saved;
  final PassportResult<String>? addResult;
  final registered = <Map<String, dynamic>>[];
  final addedBrands = <String>[];

  @override
  Future<PassportResult<List<String>>> customBrands(String categoryId) async =>
      PassportResult.ok(saved);

  @override
  Future<PassportResult<String>> addCustomBrand(String categoryId, String name) async {
    addedBrands.add('$categoryId:$name');
    return addResult ?? PassportResult.ok(name);
  }

  @override
  Future<PassportResult<KitchenAppliance>> register(
      String bookingId, Map<String, dynamic> payload) async {
    registered.add(payload);
    if (failFirstRegister && registered.length == 1) {
      return const PassportResult.failure('Could not reach the server.');
    }
    return PassportResult.ok(KitchenAppliance.fromJson({
      'id': 'KAPP-1',
      'category': payload['category'],
      'brand': payload['brand'],
      'specs': payload['specs'],
    }));
  }
}

Future<bool?> _pumpScreen(WidgetTester tester, _FakeApi api) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  bool? popped;
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () async =>
                popped = await context.push<bool>('/register'),
            child: const Text('open'),
          ),
        ),
      ),
      GoRoute(path: '/register', builder: (_, _) => const RegisterApplianceScreen(jobId: 'B-1')),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [passportApiProvider.overrideWithValue(api)],
    child: MaterialApp.router(routerConfig: router, theme: _theme()),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return popped;
}

ThemeData _theme() => CarePlusTheme.light();

Future<void> _pickDropdown(WidgetTester tester, String label, String option) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the seven appliances and no generic Type field', (tester) async {
    await _pumpScreen(tester, _FakeApi());
    for (final label in [
      'Chimney', 'Hob / Cooktop', 'Microwave', 'OTG / Oven', 'Dishwasher',
      'Refrigerator', 'RO Purifier',
    ]) {
      expect(find.textContaining(label), findsOneWidget, reason: label);
    }
    expect(find.text('Type'), findsNothing);
    // Nothing else is asked until an appliance is chosen.
    expect(find.text('Brand name'), findsNothing);
  });

  testWidgets('fields follow the selected appliance', (tester) async {
    await _pumpScreen(tester, _FakeApi());
    await tester.tap(find.textContaining('Hob / Cooktop'));
    await tester.pumpAndSettle();
    expect(find.text('Fuel'), findsOneWidget);
    expect(find.text('Burners / zones'), findsOneWidget);
    expect(find.text('Storage tank (L)'), findsNothing);

    await tester.tap(find.textContaining('RO Purifier'));
    await tester.pumpAndSettle();
    expect(find.text('Storage tank (L)'), findsOneWidget);
    expect(find.text('Fuel'), findsNothing);
  });

  testWidgets('brand list is category specific, includes saved brands and Other',
      (tester) async {
    await _pumpScreen(tester, _FakeApi(saved: ['Nova Air']));
    await tester.tap(find.textContaining('Chimney'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Brand name'));
    await tester.pumpAndSettle();
    expect(find.text('Faber'), findsWidgets);
    expect(find.text('Nova Air'), findsWidgets);
    expect(find.text('Other'), findsWidgets);
    expect(find.text('Kent'), findsNothing); // an RO brand, not a chimney brand
  });

  testWidgets('Other → Add Brand saves the brand and selects it', (tester) async {
    final api = _FakeApi();
    await _pumpScreen(tester, api);
    await tester.tap(find.textContaining('Chimney'));
    await tester.pumpAndSettle();
    await _pickDropdown(tester, 'Brand name', 'Other');

    await tester.tap(find.text('Add Brand'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a brand name'), findsOneWidget);
    expect(api.addedBrands, isEmpty);

    await tester.enterText(find.widgetWithText(TextFormField, 'New brand name'), '  Nova   Air ');
    await tester.tap(find.text('Add Brand'));
    await tester.pumpAndSettle();

    expect(api.addedBrands, ['chimney:Nova Air']);
    expect(find.text('New brand name'), findsNothing);
    expect(find.text('Nova Air'), findsOneWidget); // selected in the dropdown
  });

  testWidgets('Add Brand with an existing brand selects it without saving', (tester) async {
    final api = _FakeApi();
    await _pumpScreen(tester, api);
    await tester.tap(find.textContaining('Chimney'));
    await tester.pumpAndSettle();
    await _pickDropdown(tester, 'Brand name', 'Other');
    await tester.enterText(find.widgetWithText(TextFormField, 'New brand name'), 'faber');
    await tester.tap(find.text('Add Brand'));
    await tester.pumpAndSettle();
    expect(api.addedBrands, isEmpty);
    expect(find.text('Faber'), findsOneWidget);
  });

  testWidgets('a failed Add Brand shows the error and does not select', (tester) async {
    final api = _FakeApi(addResult: const PassportResult.failure('Could not reach the server.'));
    await _pumpScreen(tester, api);
    await tester.tap(find.textContaining('Chimney'));
    await tester.pumpAndSettle();
    await _pickDropdown(tester, 'Brand name', 'Other');
    await tester.enterText(find.widgetWithText(TextFormField, 'New brand name'), 'Nova Air');
    await tester.tap(find.text('Add Brand'));
    await tester.pumpAndSettle();
    expect(find.text('Could not reach the server.'), findsOneWidget);
    expect(find.text('New brand name'), findsOneWidget);
  });

  testWidgets('submit is blocked until brand and required specs are valid', (tester) async {
    final api = _FakeApi();
    await _pumpScreen(tester, api);
    await tester.tap(find.textContaining('Hob / Cooktop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to Kitchen Passport'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a brand'), findsOneWidget);
    expect(find.text('Required'), findsWidgets);
    expect(api.registered, isEmpty);
  });

  testWidgets('a valid hob registers with category-specific specs and pops true',
      (tester) async {
    final api = _FakeApi();
    await _pumpScreen(tester, api);
    await tester.tap(find.textContaining('Hob / Cooktop'));
    await tester.pumpAndSettle();
    await _pickDropdown(tester, 'Brand name', 'Elica');
    await _pickDropdown(tester, 'Fuel', 'Gas');
    await tester.enterText(find.widgetWithText(TextFormField, 'Burners / zones'), '4');
    await tester.enterText(find.widgetWithText(TextFormField, 'Model'), 'Flexi 4B');
    await tester.tap(find.text('Save to Kitchen Passport'));
    await tester.pumpAndSettle();

    expect(api.registered, hasLength(1));
    final sent = api.registered.single;
    expect(sent['clientRequestId'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect({...sent}..remove('clientRequestId'), {
      'category': 'hob',
      'brand': 'Elica',
      'model': 'Flexi 4B',
      'specs': {'fuel': 'gas', 'burners': 4},
    });
    // Popped back to the launcher screen.
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('out-of-range burners is rejected before any request', (tester) async {
    final api = _FakeApi();
    await _pumpScreen(tester, api);
    await tester.tap(find.textContaining('Hob / Cooktop'));
    await tester.pumpAndSettle();
    await _pickDropdown(tester, 'Brand name', 'Elica');
    await _pickDropdown(tester, 'Fuel', 'Gas');
    await tester.enterText(find.widgetWithText(TextFormField, 'Burners / zones'), '9');
    await tester.tap(find.text('Save to Kitchen Passport'));
    await tester.pumpAndSettle();
    expect(find.text('Between 1 and 6'), findsOneWidget);
    expect(api.registered, isEmpty);
  });

  testWidgets('a retry after a failed save reuses the same request id', (tester) async {
    final api = _FakeApi(failFirstRegister: true);
    await _pumpScreen(tester, api);
    await tester.tap(find.textContaining('Hob / Cooktop'));
    await tester.pumpAndSettle();
    await _pickDropdown(tester, 'Brand name', 'Elica');
    await _pickDropdown(tester, 'Fuel', 'Gas');
    await tester.enterText(find.widgetWithText(TextFormField, 'Burners / zones'), '4');
    await tester.tap(find.text('Save to Kitchen Passport'));
    await tester.pumpAndSettle();
    expect(find.text('Could not reach the server.'), findsOneWidget);

    await tester.tap(find.text('Save to Kitchen Passport'));
    await tester.pumpAndSettle();
    expect(api.registered, hasLength(2));
    expect(api.registered[1]['clientRequestId'], api.registered[0]['clientRequestId']);
  });
}
