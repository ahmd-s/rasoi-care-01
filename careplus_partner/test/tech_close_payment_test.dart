import 'package:care_plus_partner/core/theme/care_plus_theme.dart';
import 'package:care_plus_partner/data/api/api_repository.dart';
import 'package:care_plus_partner/data/api/booking_dto.dart';
import 'package:care_plus_partner/data/models.dart';
import 'package:care_plus_partner/features/jobs/tech_close_screen.dart';
import 'package:care_plus_partner/l10n/app_localizations.dart';
import 'package:care_plus_partner/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// No network: every payment call is answered by the test.
class _Repo extends ApiRepository {
  _Repo({
    required this.status,
    required this.payment,
    this.onCreate,
    this.onRefresh,
  });
  final String status;
  PaymentSummaryDto payment;
  final PaymentStateDto Function()? onCreate;
  final PaymentStateDto Function()? onRefresh;
  int creates = 0;
  int refreshes = 0;

  @override
  String? statusOf(String jobId) => status;

  @override
  PaymentSummaryDto paymentOf(String jobId) => payment;

  @override
  List<InvoiceLine> closeInvoice(String jobId) =>
      const [InvoiceLine('Deep clean', 100000)];

  @override
  Future<PaymentStateDto> createInvoiceQr(String jobId) async {
    creates++;
    final r = onCreate!();
    if (r.error == null) payment = r.payment;
    return r;
  }

  @override
  Future<PaymentStateDto> refreshPayment(String jobId) async {
    refreshes++;
    final r = onRefresh?.call() ?? PaymentStateDto(payment: payment);
    if (r.error == null) payment = r.payment;
    return r;
  }
}

const _due = PaymentSummaryDto(
    mode: 'pay_after_service', status: 'unpaid', invoicePaise: 100000, paidPaise: 0, duePaise: 100000);
const _paid = PaymentSummaryDto(
    mode: 'pay_after_service', status: 'paid', invoicePaise: 100000, paidPaise: 100000, duePaise: 0);
const _qr = InvoiceQrDto(
    qrId: 'qr_1', imageUrl: 'https://example.test/qr_1.png', amountPaise: 100000, status: 'active');

Future<void> _pump(WidgetTester tester, _Repo repo) async {
  tester.view.physicalSize = const Size(1080, 3000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [repositoryProvider.overrideWithValue(repo)],
    child: MaterialApp(
      theme: CarePlusTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const TechCloseScreen(jobId: 'RC-1'),
    ),
  ));
  await tester.pump();
  await tester.pump();
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox()); // cancels the status poll timer
}

void main() {
  testWidgets('before completion: no fake QR, no Mark paid; pay-after-service amount is explained', (tester) async {
    final repo = _Repo(status: 'In Progress', payment: _due);
    await _pump(tester, repo);
    expect(find.text('Complete job'), findsOneWidget);
    expect(find.textContaining('Mark paid'), findsNothing);
    expect(find.byIcon(Icons.qr_code_2), findsNothing, reason: 'no placeholder QR before the amount is final');
    expect(find.byKey(const Key('show-payment-qr')), findsNothing);
    expect(find.textContaining('Pay after service'), findsOneWidget);
    expect(find.textContaining('₹1,000'), findsWidgets);
    expect(repo.creates, 0);
  });

  testWidgets('before completion: an online-paid job says there is nothing to collect', (tester) async {
    final repo = _Repo(
        status: 'In Progress',
        payment: const PaymentSummaryDto(mode: 'pay_now', status: 'paid', invoicePaise: 100000, paidPaise: 100000));
    await _pump(tester, repo);
    expect(find.byKey(const Key('payment-preview-note')), findsOneWidget);
    expect(find.textContaining('already paid online'), findsOneWidget);
    expect(find.text('₹0'), findsOneWidget);
  });

  testWidgets('completing without a signature is refused and never marks anything paid', (tester) async {
    final repo = _Repo(status: 'In Progress', payment: _due);
    await _pump(tester, repo);
    await tester.tap(find.text('Complete job'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byKey(const Key('payment-paid')), findsNothing);
    expect(repo.creates + repo.refreshes, 0);
  });

  testWidgets('completed + unpaid: shows the amount and fetches a server QR only on request', (tester) async {
    final repo = _Repo(
      status: 'Completed',
      payment: _due,
      onCreate: () => const PaymentStateDto(payment: _due, qr: _qr),
    );
    await _pump(tester, repo);
    expect(find.byKey(const Key('show-payment-qr')), findsOneWidget);
    expect(find.byKey(const Key('invoice-qr-image')), findsNothing, reason: 'nothing shown until the server creates it');
    expect(find.byKey(const Key('payment-paid')), findsNothing);

    await tester.tap(find.byKey(const Key('show-payment-qr')));
    await tester.pump();
    await tester.pump();
    expect(repo.creates, 1);
    final image = tester.widget<Image>(find.byKey(const Key('invoice-qr-image')));
    expect((image.image as NetworkImage).url, 'https://example.test/qr_1.png');
    expect(find.text('Waiting for payment'), findsOneWidget);
    expect(find.textContaining('any UPI app'), findsOneWidget);
    expect(find.byKey(const Key('payment-paid')), findsNothing, reason: 'still pending until the server confirms');
    await _dispose(tester);
  });

  testWidgets('refresh reflects the verified server status: pending stays pending, paid shows paid', (tester) async {
    var paid = false;
    final repo = _Repo(
      status: 'Completed',
      payment: _due,
      onCreate: () => const PaymentStateDto(payment: _due, qr: _qr),
      onRefresh: () => paid
          ? const PaymentStateDto(payment: _paid, qr: InvoiceQrDto(
              qrId: 'qr_1', imageUrl: 'https://example.test/qr_1.png', amountPaise: 100000, status: 'paid'))
          : const PaymentStateDto(payment: _due, qr: _qr),
    );
    await _pump(tester, repo); // reopening shows the server's still-live QR
    expect(find.byKey(const Key('invoice-qr-image')), findsOneWidget);

    await tester.tap(find.byKey(const Key('refresh-payment')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Waiting for payment'), findsOneWidget);
    expect(find.byKey(const Key('payment-paid')), findsNothing);

    paid = true;
    await tester.tap(find.byKey(const Key('refresh-payment')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('payment-paid')), findsOneWidget);
    expect(find.byKey(const Key('invoice-qr-image')), findsNothing);
    expect(find.byKey(const Key('show-payment-qr')), findsNothing);
    expect(find.text('Done'), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('an unpaid job can be left unpaid and stays payable', (tester) async {
    final repo = _Repo(status: 'Completed', payment: _due, onCreate: () => const PaymentStateDto(payment: _due, qr: _qr));
    await _pump(tester, repo);
    expect(find.text('Leave unpaid for now'), findsOneWidget);
    expect(find.byKey(const Key('payment-paid')), findsNothing);
  });

  testWidgets('an account without QR support explains the prerequisite and shows no QR', (tester) async {
    final repo = _Repo(
      status: 'Completed',
      payment: _due,
      onCreate: () => const PaymentStateDto(
          error: 'UPI QR codes are not enabled on this payment account yet.', code: 'qr_not_enabled'),
    );
    await _pump(tester, repo);
    await tester.tap(find.byKey(const Key('show-payment-qr')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('payment-error')), findsOneWidget);
    expect(find.textContaining('request QR Codes'), findsOneWidget);
    expect(find.byKey(const Key('invoice-qr-image')), findsNothing);
    expect(find.byKey(const Key('payment-paid')), findsNothing);
  });

  testWidgets('a server failure while creating the QR is shown and nothing is marked paid', (tester) async {
    final repo = _Repo(
      status: 'Completed',
      payment: _due,
      onCreate: () => const PaymentStateDto(error: 'Could not create the payment QR. Please try again.'),
    );
    await _pump(tester, repo);
    await tester.tap(find.byKey(const Key('show-payment-qr')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Could not create the payment QR. Please try again.'), findsOneWidget);
    expect(find.byKey(const Key('payment-paid')), findsNothing);
    expect(find.byKey(const Key('show-payment-qr')), findsOneWidget, reason: 'can retry');
  });

  testWidgets('completed and already paid: shows paid, offers no QR', (tester) async {
    final repo = _Repo(status: 'Completed', payment: _paid);
    await _pump(tester, repo);
    expect(find.byKey(const Key('payment-paid')), findsOneWidget);
    expect(find.byKey(const Key('show-payment-qr')), findsNothing);
  });

  test('payment summary parsing never invents a paid state', () {
    expect(PaymentSummaryDto.fromJson(null).isPaid, isFalse);
    expect(PaymentSummaryDto.fromJson('paid').isPaid, isFalse);
    expect(PaymentSummaryDto.fromJson(<String, dynamic>{}).status, 'unpaid');
    final p = PaymentSummaryDto.fromJson(<String, dynamic>{
      'mode': 'pay_after_service', 'status': 'unpaid', 'invoicePaise': 5000, 'paidPaise': 0, 'duePaise': 5000});
    expect(p.isPayAfterService, isTrue);
    expect(p.duePaise, 5000);
    expect(InvoiceQrDto.tryParse(<String, dynamic>{'qrId': 'q'}), isNull);
    expect(BookingDto.fromJson(<String, dynamic>{'id': 'x', 'payment': {'status': 'paid', 'duePaise': 0}}).payment.isPaid, isTrue);
  });
}
