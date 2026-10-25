import 'package:care_plus/core/theme/care_plus_theme.dart';
import 'package:care_plus/core/widgets/care_widgets.dart';
import 'package:care_plus/data/mock_repository.dart';
import 'package:care_plus/data/models.dart';
import 'package:care_plus/features/catalog/catalog_screens.dart';
import 'package:care_plus/features/home/home_screen.dart';
import 'package:care_plus/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Widget _app(GoRouter router) => ProviderScope(
      child: MaterialApp.router(
        theme: CarePlusTheme.light(),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );

void _bigScreen(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
}

void main() {
  testWidgets('catalogue "From" price is the category minimum, not an index', (t) async {
    _bigScreen(t);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const CatalogScreen()),
    ]);
    await t.pumpWidget(_app(router));
    await t.pumpAndSettle();
    final repo = MockRepository();
    final chimenyMin = repo
        .servicesFor(Appliance.chimney)
        .map((s) => s.pricePaise)
        .reduce((a, b) => a < b ? a : b);
    expect(find.text(Money.rupees(chimenyMin)), findsWidgets);
    expect(find.text(Money.rupees(169900)), findsNothing); // was the buggy services[1]
  });

  testWidgets('home green banner reads Customer Kitchen Passport and opens /passport',
      (t) async {
    _bigScreen(t);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/passport', builder: (_, __) => const Scaffold(body: Text('PASSPORT_SCREEN'))),
    ]);
    await t.pumpWidget(_app(router));
    await t.pumpAndSettle();
    expect(find.text('Customer Kitchen Passport'), findsOneWidget);
    await t.tap(find.text('Customer Kitchen Passport'));
    await t.pumpAndSettle();
    expect(find.text('PASSPORT_SCREEN'), findsOneWidget);
    router.pop(); // Back must return to Home, not another tab.
    await t.pumpAndSettle();
    expect(find.text('PASSPORT_SCREEN'), findsNothing);
    expect(find.text('Customer Kitchen Passport'), findsOneWidget);
  });

  testWidgets('first service of every appliance is preselected, also after switching',
      (t) async {
    _bigScreen(t);
    final repo = MockRepository();
    final router = GoRouter(
      initialLocation: '/services/chimney',
      routes: [
        GoRoute(
          path: '/services/:appliance',
          builder: (_, s) => ServiceDetailScreen(
              appliance: Appliance.values.byName(s.pathParameters['appliance']!)),
        ),
      ],
    );
    await t.pumpWidget(_app(router));
    await t.pumpAndSettle();

    for (final a in Appliance.values) {
      if (repo.applianceDetail(a).comingSoon) continue;
      router.go('/services/${a.name}');
      await t.pumpAndSettle();
      final first = repo.servicesFor(a).first;
      expect(find.text(Money.rupees(first.pricePaise)), findsWidgets,
          reason: '${a.name}: first service price shown');
      // Dock total equals exactly the first service => only it is selected.
      final dockTotal = find.descendant(
          of: find.byType(Dock), matching: find.text(Money.rupees(first.pricePaise)));
      expect(dockTotal, findsOneWidget, reason: '${a.name}: only first service selected');
    }
  });
}
