import 'dart:async';

import 'package:care_plus/core/theme/care_plus_theme.dart';
import 'package:care_plus/data/api/api_repository.dart';
import 'package:care_plus/data/models.dart';
import 'package:care_plus/features/booking/booking_screens.dart';
import 'package:care_plus/l10n/app_localizations.dart';
import 'package:care_plus/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

typedef _Res = ({List<Booking>? bookings, bool shopOrderPlaced, String? error});
typedef _Verify
    = Future<({List<Booking>? bookings, bool shopOrderPlaced, String? error})>
        Function(String orderId, String paymentId, String signature);

/// Repository whose Razorpay calls are in-memory: it never talks to the
/// backend or to Razorpay.
class _FakeRepo extends ApiRepository {
  _FakeRepo({this.orderError, required this.verify});
  final String? orderError;
  final _Verify verify;
  int orderCalls = 0;
  final verifyCalls = <(String, String, String)>[];

  /// Pay-after-service: the booking-cart calls (paymentMode, idempotency key).
  final cartCalls = <({String? mode, String? key, bool useCoins})>[];
  Future<({List<Booking>? bookings, String? error})> Function()? cartHandler;

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
    String? paymentMode,
  }) {
    cartCalls.add((mode: paymentMode, key: idempotencyKey, useCoins: useCoins));
    return cartHandler!();
  }

  @override
  Future<({Map<String, dynamic>? order, String? error})> createRazorpayOrder({
    required List<ServiceItem> services,
    required Map<String, dynamic> booking,
    required List<Map<String, dynamic>> shopItems,
  }) async {
    orderCalls++;
    if (orderError != null) return (order: null, error: orderError);
    return (
      order: <String, dynamic>{
        'keyId': 'rzp_test_fake_key_id',
        'orderId': 'order_fake1',
        'amount': 58882,
        'currency': 'INR',
        'name': 'Rasoi Care',
        'description': 'Rasoi Care checkout',
      },
      error: null,
    );
  }

  @override
  Future<({List<Booking>? bookings, bool shopOrderPlaced, String? error})>
      verifyRazorpayPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) {
    verifyCalls.add((orderId, paymentId, signature));
    return verify(orderId, paymentId, signature);
  }
}

/// Replaces the Razorpay platform channel. `open` is answered with whatever
/// [result] returns (a success or failure payload); nothing leaves the test.
class _FakeCheckout {
  _FakeCheckout(this.result);
  final Map<String, dynamic> Function() result;
  final opened = <Map<dynamic, dynamic>>[];

  void install() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('razorpay_flutter'),
            (call) async {
      if (call.method == 'open') {
        opened.add(call.arguments as Map<dynamic, dynamic>);
        return result();
      }
      return null;
    });
  }
}

Map<String, dynamic> _paid() => {
      'type': 0,
      'data': {
        'razorpay_payment_id': 'pay_fake1',
        'razorpay_order_id': 'order_fake1',
        'razorpay_signature': 'sig_fake1',
      },
    };

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
  final container = ProviderContainer(
      overrides: [apiRepositoryProvider.overrideWithValue(repo)]);
  addTearDown(container.dispose);
  container.read(bookingDraftProvider.notifier).start([_svc]);
  var location = '/pay';
  final router = GoRouter(initialLocation: '/pay', routes: [
    GoRoute(path: '/pay', builder: (_, __) => const PaymentScreen()),
    GoRoute(
        path: '/booking/:id/confirmed',
        builder: (_, s) => Text('CONFIRMED ${s.pathParameters['id']}')),
    GoRoute(path: '/', builder: (_, __) => const Text('HOME')),
  ]);
  router.routerDelegate.addListener(() =>
      location = router.routerDelegate.currentConfiguration.uri.toString());
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

Booking _booking(String id,
        {BookingPayment payment = const BookingPayment()}) =>
    Booking(
      id: id,
      title: 'Filter clean',
      appliance: Appliance.chimney,
      status: BookingStatus.scheduled,
      whenLabel: 'Today',
      addressLabel: 'Home',
      totalPaise: 49900,
      payment: payment,
    );

_Res _ok(List<Booking> b) => (bookings: b, shopOrderPlaced: false, error: null);
_Res _fail(String e) => (bookings: null, shopOrderPlaced: false, error: e);

Finder get _confirm => find.byType(FilledButton);

void main() {
  testWidgets(
      'opens checkout from a server order, shows loading, ignores a second tap, confirms only after verification',
      (tester) async {
    final gate = Completer<
        ({List<Booking>? bookings, bool shopOrderPlaced, String? error})>();
    final repo = _FakeRepo(verify: (_, __, ___) => gate.future);
    final checkout = _FakeCheckout(_paid)..install();
    final (_, loc) = await _pump(tester, repo);

    await tester.tap(_confirm);
    await tester.pump();
    await tester.pump();
    expect(repo.orderCalls, 1);
    expect(checkout.opened, hasLength(1));
    expect(checkout.opened.single['order_id'], 'order_fake1');
    expect(checkout.opened.single['key'], 'rzp_test_fake_key_id');
    expect(checkout.opened.single['amount'], 58882,
        reason: 'amount comes from the server order');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
    await tester.tap(_confirm, warnIfMissed: false);
    await tester.pump();
    expect(repo.orderCalls, 1,
        reason: 'double tap must not create a second order');
    expect(repo.verifyCalls, [('order_fake1', 'pay_fake1', 'sig_fake1')]);
    expect(find.textContaining('CONFIRMED'), findsNothing,
        reason: 'not confirmed until the server verifies');

    gate.complete(_ok([_booking('RC-42')]));
    await tester.pumpAndSettle();
    expect(find.text('CONFIRMED RC-42'), findsOneWidget);
    expect(loc(), '/booking/RC-42/confirmed');
  });

  testWidgets(
      'a failed verification stays on screen and retries verification without charging again',
      (tester) async {
    var n = 0;
    final repo = _FakeRepo(
      verify: (_, __, ___) async => n++ == 0
          ? (
              bookings: null,
              shopOrderPlaced: false,
              error:
                  'Could not confirm payment status. Please retry verification.'
            )
          : _ok([_booking('RC-9')]),
    );
    final checkout = _FakeCheckout(_paid)..install();
    await _pump(tester, repo);

    await tester.tap(_confirm);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Could not confirm payment status'),
        findsOneWidget);
    expect(find.textContaining('CONFIRMED'), findsNothing);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(repo.verifyCalls, hasLength(2));
    expect(repo.verifyCalls[0], repo.verifyCalls[1],
        reason: 'retry re-verifies the same payment');
    expect(repo.orderCalls, 1, reason: 'retry must not create a new order');
    expect(checkout.opened, hasLength(1),
        reason: 'retry must not reopen checkout / charge again');
    expect(find.text('CONFIRMED RC-9'), findsOneWidget);
  });

  testWidgets('a cancelled payment places nothing and never calls verification',
      (tester) async {
    final repo = _FakeRepo(
        verify: (_, __, ___) async => throw StateError('must not verify'));
    _FakeCheckout(() => {
          'type': 1,
          'data': {'code': 2, 'message': 'Payment cancelled by user'},
        }).install();
    await _pump(tester, repo);

    await tester.tap(_confirm);
    await tester.pump();
    await tester.pump();
    expect(find.text('Payment cancelled by user'), findsOneWidget);
    expect(repo.verifyCalls, isEmpty);
    expect(find.textContaining('CONFIRMED'), findsNothing);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);
  });

  testWidgets('an order the server refuses never opens checkout',
      (tester) async {
    final repo = _FakeRepo(
      orderError:
          'Online payment is not configured yet. Please contact support.',
      verify: (_, __, ___) async => throw StateError('must not verify'),
    );
    final checkout = _FakeCheckout(_paid)..install();
    await _pump(tester, repo);

    await tester.tap(_confirm);
    await tester.pump();
    await tester.pump();
    expect(
        find.text(
            'Online payment is not configured yet. Please contact support.'),
        findsOneWidget);
    expect(checkout.opened, isEmpty);
    expect(repo.verifyCalls, isEmpty);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);
  });

  testWidgets(
      'both payment choices are offered and the selection really changes the flow and button',
      (tester) async {
    final repo = _FakeRepo(verify: (_, __, ___) async => _fail('unused'));
    await _pump(tester, repo);
    expect(find.byKey(const Key('pay-choice-now')), findsOneWidget);
    expect(find.byKey(const Key('pay-choice-after')), findsOneWidget);
    expect(find.textContaining('Pay now · ₹'), findsOneWidget,
        reason: 'Pay now is the default');
    await tester.tap(find.byKey(const Key('pay-choice-after')));
    await tester.pump();
    expect(find.textContaining('Confirm booking · ₹'), findsOneWidget);
    expect(find.textContaining('Pay now · ₹'), findsNothing);
    await tester.tap(find.byKey(const Key('pay-choice-now')));
    await tester.pump();
    expect(find.textContaining('Pay now · ₹'), findsOneWidget);
  });

  testWidgets('customer-facing copy never mentions Razorpay', (tester) async {
    final repo = _FakeRepo(verify: (_, __, ___) async => _fail('unused'));
    await _pump(tester, repo);
    expect(find.textContaining('Razorpay'), findsNothing);
    await tester.tap(find.byKey(const Key('pay-choice-after')));
    await tester.pump();
    expect(find.textContaining('Razorpay'), findsNothing);
    expect(find.textContaining('UPI'), findsWidgets);
  });

  testWidgets(
      'Pay after service books with no payment and no Razorpay checkout',
      (tester) async {
    final repo = _FakeRepo(
        verify: (_, __, ___) async => _fail('must not verify'))
      ..cartHandler = () async => (bookings: [_booking('RC-77')], error: null);
    final checkout = _FakeCheckout(_paid)..install();
    final (_, loc) = await _pump(tester, repo);

    await tester.tap(find.byKey(const Key('pay-choice-after')));
    await tester.pump();
    await tester.tap(_confirm);
    await tester.pumpAndSettle();

    expect(repo.cartCalls, hasLength(1));
    expect(repo.cartCalls.single.mode, 'pay_after_service');
    expect(repo.cartCalls.single.key, isNotNull);
    expect(repo.orderCalls, 0,
        reason: 'no Razorpay order for pay-after-service');
    expect(checkout.opened, isEmpty);
    expect(repo.verifyCalls, isEmpty);
    expect(loc(), '/booking/RC-77/confirmed');
  });

  testWidgets(
      'a failed Pay after service booking stays on screen and retries with the same key',
      (tester) async {
    var n = 0;
    final repo = _FakeRepo(verify: (_, __, ___) async => _fail('unused'))
      ..cartHandler = () async => n++ == 0
          ? (
              bookings: null,
              error: 'No technician is available for this service yet'
            )
          : (bookings: [_booking('RC-79')], error: null);
    _FakeCheckout(_paid).install();
    await _pump(tester, repo);
    await tester.tap(find.byKey(const Key('pay-choice-after')));
    await tester.pump();

    await tester.tap(_confirm);
    await tester.pump();
    await tester.pump();
    expect(find.text('No technician is available for this service yet'),
        findsOneWidget);
    expect(find.textContaining('CONFIRMED'), findsNothing);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(repo.cartCalls, hasLength(2));
    expect(repo.cartCalls[0].key, repo.cartCalls[1].key,
        reason: 'retry must not duplicate the booking');
    expect(find.text('CONFIRMED RC-79'), findsOneWidget);
  });

  testWidgets(
      'Pay after service is refused for shop kits, which are only sold prepaid',
      (tester) async {
    final repo = _FakeRepo(verify: (_, __, ___) async => _fail('unused'))
      ..cartHandler = () async => (bookings: [_booking('RC-80')], error: null);
    _FakeCheckout(_paid).install();
    final (container, _) = await _pump(tester, repo);
    container.read(shopCartProvider.notifier).setQty('chimney_kit', 1);
    await tester.pump();
    await tester.tap(find.byKey(const Key('pay-choice-after')));
    await tester.pump();
    await tester.tap(_confirm);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Shop kits are paid online'), findsWidgets);
    expect(repo.cartCalls, isEmpty);
    expect(repo.orderCalls, 0);
  });

  testWidgets(
      'Pay now never sends a payment mode of its own and never books without verification',
      (tester) async {
    final repo = _FakeRepo(
        verify: (_, __, ___) async => _fail(
            'Could not confirm payment status. Please retry verification.'));
    _FakeCheckout(_paid).install();
    await _pump(tester, repo);
    await tester.tap(_confirm);
    await tester.pump();
    await tester.pump();
    expect(repo.cartCalls, isEmpty,
        reason: 'Pay now goes order -> checkout -> server verification only');
    expect(repo.orderCalls, 1);
    expect(find.textContaining('CONFIRMED'), findsNothing);
  });

  testWidgets('a thrown error shows a generic message, never the raw exception',
      (tester) async {
    final repo = _ThrowingRepo();
    _FakeCheckout(_paid).install();
    await _pump(tester, repo);
    await tester.tap(_confirm);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Null check'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}

class _ThrowingRepo extends _FakeRepo {
  _ThrowingRepo()
      : super(verify: (_, __, ___) async => throw StateError('unused'));
  @override
  Future<({Map<String, dynamic>? order, String? error})> createRazorpayOrder({
    required List<ServiceItem> services,
    required Map<String, dynamic> booking,
    required List<Map<String, dynamic>> shopItems,
  }) async =>
      throw StateError('Null check operator used on a null value');
}
