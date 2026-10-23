import 'package:care_plus/core/theme/care_plus_theme.dart';
import 'package:care_plus/data/api/api_repository.dart';
import 'package:care_plus/data/models.dart';
import 'package:care_plus/features/booking/booking_screens.dart';
import 'package:care_plus/features/invoice/invoice_rate_screens.dart';
import 'package:care_plus/l10n/app_localizations.dart';
import 'package:care_plus/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves one booking and records payment refreshes; never touches a network.
class _Repo extends ApiRepository {
  _Repo(this.booking);
  Booking booking;
  int refreshes = 0;
  bool refreshOk = true;

  @override
  Booking? bookingById(String id) => id == booking.id ? booking : null;

  @override
  Future<void> refreshBookings() async {}

  @override
  Future<bool> refreshPaymentStatus(String bookingId) async {
    refreshes++;
    return refreshOk;
  }
}

Booking _b(BookingPayment payment,
        {BookingStatus status = BookingStatus.completed}) =>
    Booking(
      id: 'RC-5',
      title: 'Filter clean',
      appliance: Appliance.chimney,
      status: status,
      whenLabel: 'Today',
      addressLabel: 'Home',
      totalPaise: 100000,
      rawStatus: 'Completed',
      payment: payment,
    );

const _unpaid = BookingPayment(
    mode: 'pay_after_service',
    status: 'unpaid',
    invoicePaise: 100000,
    paidPaise: 0,
    duePaise: 100000);
const _paid = BookingPayment(
    mode: 'pay_now',
    status: 'paid',
    invoicePaise: 100000,
    paidPaise: 100000,
    duePaise: 0);

Future<void> _pump(WidgetTester tester, _Repo repo, Widget home) async {
  tester.view.physicalSize = const Size(1080, 3200);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [apiRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp(
      theme: CarePlusTheme.light(),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('invoice', () {
    testWidgets(
        'an unpaid completed invoice shows the amount due, no PAID stamp, and a refresh',
        (tester) async {
      final repo = _Repo(_b(_unpaid));
      await _pump(tester, repo, const InvoiceScreen(bookingId: 'RC-5'));
      expect(find.byKey(const Key('payment-due-card')), findsOneWidget);
      expect(find.text('Amount due'), findsWidgets);
      expect(find.text('Total paid'), findsNothing);
      expect(find.text('PAID'), findsNothing);
      expect(find.textContaining('any UPI app'), findsOneWidget);

      await tester.tap(find.byKey(const Key('refresh-payment-status')));
      await tester.pump();
      await tester.pump();
      expect(repo.refreshes, 1);
      expect(find.text('PAID'), findsNothing,
          reason: 'the app never marks paid by itself');
    });

    testWidgets('a failed status check is explained, not treated as paid',
        (tester) async {
      final repo = _Repo(_b(_unpaid))..refreshOk = false;
      await _pump(tester, repo, const InvoiceScreen(bookingId: 'RC-5'));
      await tester.tap(find.byKey(const Key('refresh-payment-status')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Couldn’t check the payment'), findsOneWidget);
      expect(find.text('PAID'), findsNothing);
    });

    testWidgets('a server-verified paid invoice shows PAID and no due card',
        (tester) async {
      await _pump(
          tester, _Repo(_b(_paid)), const InvoiceScreen(bookingId: 'RC-5'));
      expect(find.byKey(const Key('payment-due-card')), findsNothing);
      expect(find.text('Total paid'), findsOneWidget);
      expect(find.byType(Transform), findsWidgets);
    });
  });

  group('confirmation', () {
    testWidgets('pay-after-service tells the customer how much to pay later',
        (tester) async {
      await _pump(tester, _Repo(_b(_unpaid, status: BookingStatus.scheduled)),
          const ConfirmedScreen(bookingId: 'RC-5'));
      expect(find.byKey(const Key('confirmed-pay-after-note')), findsOneWidget);
      expect(find.textContaining('₹1,000'), findsWidgets);
      expect(find.textContaining('UPI QR'), findsOneWidget);
    });

    testWidgets('an already-paid booking shows no pay-later note',
        (tester) async {
      await _pump(tester, _Repo(_b(_paid, status: BookingStatus.scheduled)),
          const ConfirmedScreen(bookingId: 'RC-5'));
      expect(find.byKey(const Key('confirmed-pay-after-note')), findsNothing);
    });
  });

  test('BookingPayment parsing never invents a paid state', () {
    expect(BookingPayment.fromJson(null).isPaid, isFalse);
    expect(BookingPayment.fromJson('paid').isPaid, isFalse);
    expect(BookingPayment.fromJson(<String, dynamic>{}).status, 'unpaid');
    final p = BookingPayment.fromJson(<String, dynamic>{
      'mode': 'pay_after_service',
      'status': 'unpaid',
      'invoicePaise': 5000,
      'duePaise': 5000
    });
    expect(p.isPayAfterService, isTrue);
    expect(p.duePaise, 5000);
  });
}
