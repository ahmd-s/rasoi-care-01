import 'dart:async';

import 'package:care_plus/core/theme/care_plus_theme.dart';
import 'package:care_plus/data/api/api_repository.dart';
import 'package:care_plus/data/models.dart';
import 'package:care_plus/features/booking/booking_screens.dart';
import 'package:care_plus/l10n/app_localizations.dart';
import 'package:care_plus/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeRepo extends ApiRepository {
  _FakeRepo(this.handler);
  final Future<({List<Booking>? bookings, String? error})> Function(String? key) handler;
  final keys = <String?>[];

  @override
  Future<({List<Booking>? bookings, String? error})> createBookingCart({
    required List<ServiceItem> services,
    required bool useCoins,
    String? areaLabel,
    String? addressLine,
    double? lat,
    double? lng,
    String? directions,
    String? notes,
    List<String>? issues,
    DateTime? scheduledAt,
    String? idempotencyKey,
  }) {
    keys.add(idempotencyKey);
    return handler(idempotencyKey);
  }
}

const _svc = ServiceItem(
  id: 'svc_chimney_filter_clean',
  appliance: Appliance.chimney,
  title: 'Filter clean',
  blurb: '',
  pricePaise: 49900,
  durationMin: 60,
);

Future<(ProviderContainer, String Function())> _pump(
    WidgetTester tester, _FakeRepo repo) async {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: [apiRepositoryProvider.overrideWithValue(repo)]);
  addTearDown(container.dispose);
  container.read(bookingDraftProvider.notifier).start([_svc]);
  var location = '/pay';
  final router = GoRouter(initialLocation: '/pay', routes: [
    GoRoute(path: '/pay', builder: (_, __) => const PaymentScreen()),
    GoRoute(path: '/booking/:id/confirmed', builder: (_, s) => Text('CONFIRMED ${s.pathParameters['id']}')),
    GoRoute(path: '/', builder: (_, __) => const Text('HOME')),
  ]);
  router.routerDelegate.addListener(() => location = router.routerDelegate.currentConfiguration.uri.toString());
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: router,
      theme: CarePlusTheme.light(),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  ));
  await tester.pump();
  return (container, () => location);
}

Booking _booking(String id) => Booking(
      id: id,
      title: 'Filter clean',
      appliance: Appliance.chimney,
      status: BookingStatus.scheduled,
      whenLabel: 'Today',
      addressLabel: 'Home',
      totalPaise: 49900,
    );

Finder get _confirm => find.byType(FilledButton);

void main() {
  testWidgets('shows loading, ignores a second tap, and confirms only with a real id', (tester) async {
    final gate = Completer<({List<Booking>? bookings, String? error})>();
    final repo = _FakeRepo((_) => gate.future);
    final (_, loc) = await _pump(tester, repo);

    await tester.tap(_confirm);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
    await tester.tap(_confirm, warnIfMissed: false);
    await tester.pump();
    expect(repo.keys.length, 1, reason: 'double tap must not send a second request');

    gate.complete((bookings: [_booking('RC-42')], error: null));
    await tester.pumpAndSettle();
    expect(find.text('CONFIRMED RC-42'), findsOneWidget);
    expect(loc(), '/booking/RC-42/confirmed');
  });

  testWidgets('failure shows the server-safe message, stays on screen, reuses the key on retry', (tester) async {
    var n = 0;
    final repo = _FakeRepo((_) async => n++ == 0
        ? (bookings: null, error: 'No technician is available for this service yet')
        : (bookings: [_booking('RC-9')], error: null));
    await _pump(tester, repo);

    await tester.tap(_confirm);
    await tester.pump();
    await tester.pump();
    expect(find.text('No technician is available for this service yet'), findsOneWidget);
    expect(find.textContaining('CONFIRMED'), findsNothing);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(repo.keys.length, 2);
    expect(repo.keys[0], isNotNull);
    expect(repo.keys[0], repo.keys[1], reason: 'retry of the same checkout must reuse its key');
    expect(find.text('CONFIRMED RC-9'), findsOneWidget);
  });

  testWidgets('a thrown error shows a generic message, never the raw exception', (tester) async {
    final repo = _FakeRepo((_) async => throw StateError('Null check operator used on a null value'));
    await _pump(tester, repo);
    await tester.tap(_confirm);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Null check'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
    expect(find.textContaining('confirm your order'), findsOneWidget);
  });
}
