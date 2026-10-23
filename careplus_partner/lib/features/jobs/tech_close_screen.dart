import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/api/api_repository.dart';
import '../../data/api/booking_dto.dart';
import '../../data/models.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/providers.dart';
import 'signature_pad.dart';

class TechCloseScreen extends ConsumerStatefulWidget {
  const TechCloseScreen({
    super.key,
    required this.jobId,
    this.suctionBefore,
    this.suctionAfter,
  });
  final String jobId;
  // Collected on the previous screen (see TechJobScreen._handlePrimaryAction)
  // before pushing here — this screen only records the signature/payment
  // and drives the final advance-to-Completed call.
  final int? suctionBefore;
  final int? suctionAfter;
  @override
  ConsumerState<TechCloseScreen> createState() => _TechCloseScreenState();
}

class _TechCloseScreenState extends ConsumerState<TechCloseScreen> {
  final _sigKey = GlobalKey<SignaturePadState>();
  bool _closing = false;

  /// True once the backend has the job as Completed (the final invoice
  /// amount is known). Reopening an already-completed job lands straight on
  /// the payment panel.
  late bool _completed;
  PaymentStateDto? _pay;
  bool _busy = false;
  String? _error;
  bool _qrNotEnabled = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(repositoryProvider);
    _completed = repo is ApiRepository && repo.statusOf(widget.jobId) == 'Completed';
    if (_completed) WidgetsBinding.instance.addPostFrameCallback((_) => _refresh(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  ApiRepository? get _repo {
    final repo = ref.read(repositoryProvider);
    return repo is ApiRepository ? repo : null;
  }

  /// Completes the job (signature + backend advance). Payment is NOT marked
  /// here: after completion the final amount is known and the payment panel
  /// takes over; "paid" only ever comes from a server-verified payment.
  Future<void> _completeJob() async {
    final t = context.l10n;
    if (!(_sigKey.currentState?.hasSignature ?? false)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.closeSignatureRequired)));
      return;
    }
    setState(() => _closing = true);
    final repo = _repo;
    if (repo == null) {
      setState(() => _closing = false);
      return;
    }
    final png = await _sigKey.currentState?.exportPng();
    if (png == null || !(await repo.uploadSignature(widget.jobId, png))) {
      if (!mounted) return;
      setState(() => _closing = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.closeSignatureUploadError)));
      return;
    }
    final advance = await repo.advanceJob(widget.jobId,
        suctionBefore: widget.suctionBefore, suctionAfter: widget.suctionAfter);
    if (!mounted) return;
    if (!advance.ok) {
      setState(() => _closing = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(advance.error ?? t.closePaymentError)));
      return;
    }
    setState(() {
      _closing = false;
      _completed = true;
    });
    await _refresh(silent: true);
  }

  Future<void> _showQr() async {
    final repo = _repo;
    if (repo == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _qrNotEnabled = false;
    });
    final result = await repo.createInvoiceQr(widget.jobId);
    if (!mounted) return;
    _apply(result);
  }

  Future<void> _refresh({bool silent = false}) async {
    final repo = _repo;
    if (repo == null || _busy) return;
    if (!silent) setState(() => _busy = true);
    final result = await repo.refreshPayment(widget.jobId);
    if (!mounted) return;
    _apply(result, keepQrOnError: true);
  }

  void _apply(PaymentStateDto result, {bool keepQrOnError = false}) {
    setState(() {
      _busy = false;
      if (result.error != null) {
        _error = result.error;
        _qrNotEnabled = result.code == 'qr_not_enabled';
        if (!keepQrOnError) _pay = null;
      } else {
        _error = result.warning;
        _qrNotEnabled = false;
        _pay = result;
      }
    });
    _poll?.cancel();
    final qr = result.qr;
    if (result.error == null && !result.payment.isPaid && qr != null && qr.status == 'active') {
      // Quietly re-check while the customer is paying; the server decides.
      _poll = Timer.periodic(const Duration(seconds: 6), (_) => _refresh(silent: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = ref.watch(repositoryProvider).closeInvoice(widget.jobId);
    final repo = ref.watch(repositoryProvider);
    final payment = _pay?.payment ?? (repo is ApiRepository ? repo.paymentOf(widget.jobId) : const PaymentSummaryDto());
    final invoiceTotal = lines.fold<int>(0, (sum, l) => sum + l.amountPaise);
    // The amount to collect is the server's outstanding figure whenever it
    // has one (it already nets off anything paid online).
    final collectNow = payment.mode != null ? payment.duePaise : invoiceTotal;
    final t = context.l10n;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: context.pop),
        title: Text(t.closeTitle),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                children: [
                  CareCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Eyebrow(t.closeInvoice(widget.jobId)),
                        const Divider(height: 22),
                        for (final l in lines) ...[
                          Padding(
                            padding: const EdgeInsets.only(bottom: 9),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(l.label,
                                    style: context.type.bodySmall!.copyWith(
                                        color: l.tone == LineTone.success
                                            ? context.care.success
                                            : context.scheme.onSurface)),
                                Text(Money.rupees(l.amountPaise),
                                    style: CareType.mono(
                                        l.tone == LineTone.success
                                            ? context.care.success
                                            : context.scheme.onSurface,
                                        size: 12)),
                              ],
                            ),
                          ),
                        ],
                        const Divider(height: 22),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_completed ? t.closeAmountDue : t.closeCollectNow,
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text(Money.rupees(collectNow),
                                key: const Key('collect-amount'),
                                style: CareType.mono(context.scheme.onSurface,
                                    size: 19, w: FontWeight.w600)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (!_completed) ...[
                    SectionHeader(t.closeCustomerSignature,
                        trailing: GestureDetector(
                          onTap: () => _sigKey.currentState?.clear(),
                          child: Text(t.closeClear,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: context.scheme.primary)),
                        )),
                    CareCard(
                      padding: EdgeInsets.zero,
                      child: SignaturePad(key: _sigKey),
                    ),
                    const SizedBox(height: 12),
                    CareCard(
                      color: context.scheme.surfaceContainerHigh,
                      borderColor: Colors.transparent,
                      child: Text(
                        payment.mode == 'pay_now'
                            ? t.closePaidOnlineNote
                            : payment.isPayAfterService
                                ? t.closePayAfterNote(Money.rupees(collectNow))
                                : t.closeQrAfterComplete,
                        key: const Key('payment-preview-note'),
                        style: context.type.bodySmall,
                      ),
                    ),
                  ] else
                    ..._paymentPanel(context, payment, collectNow),
                ],
              ),
            ),
            Dock(
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _closing
                      ? null
                      : _completed
                          ? () => context.go('/tech/jobs')
                          : _completeJob,
                  child: _closing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(_completed
                          ? (payment.isPaid || payment.duePaise <= 0 ? t.closeDone : t.closeQrUnpaidDone)
                          : t.closeCompleteJob),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Payment section once the job is Completed. Everything shown is the
  /// server's verified state; the only way to "Paid" is Razorpay confirming
  /// the QR payment to the backend.
  List<Widget> _paymentPanel(BuildContext context, PaymentSummaryDto payment, int due) {
    final t = context.l10n;
    final qr = _pay?.qr;
    if (payment.isPaid || payment.duePaise <= 0) {
      return [
        SectionHeader(t.closeCollectPayment),
        CareCard(
          child: Row(
            children: [
              Icon(Icons.check_circle, color: context.care.success),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  payment.mode == 'pay_now' && qr == null ? t.closePaidOnlineNote : t.closeQrPaid,
                  key: const Key('payment-paid'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ];
    }
    final qrActive = qr != null && qr.status == 'active';
    return [
      SectionHeader(t.closeCollectPayment),
      if (qrActive)
        CareCard(
          child: Column(
            children: [
              Container(
                width: 220,
                height: 220,
                alignment: Alignment.center,
                color: Colors.white,
                child: Image.network(
                  qr.imageUrl,
                  key: const Key('invoice-qr-image'),
                  fit: BoxFit.contain,
                  loadingBuilder: (c, child, p) =>
                      p == null ? child : const CircularProgressIndicator(strokeWidth: 2),
                  errorBuilder: (c, e, s) => Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(t.closePaymentError, textAlign: TextAlign.center),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(Money.rupees(qr.amountPaise),
                  style: CareType.mono(context.scheme.onSurface, size: 20, w: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(t.closeQrScan(Money.rupees(qr.amountPaise)),
                  textAlign: TextAlign.center, style: context.type.bodySmall),
              const SizedBox(height: 10),
              StatusChip(t.closeQrPending, tone: ChipTone.warning),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const Key('refresh-payment'),
                onPressed: _busy ? null : () => _refresh(),
                icon: _busy
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
                label: Text(t.closeRefreshStatus),
              ),
            ],
          ),
        )
      else
        CareCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (qr != null && qr.status == 'expired') ...[
                Text(t.closeQrExpired, style: context.type.bodySmall),
                const SizedBox(height: 10),
              ],
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('show-payment-qr'),
                  onPressed: _busy ? null : _showQr,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.qr_code_2),
                  label: Text(t.closeShowQr),
                ),
              ),
            ],
          ),
        ),
      if (_qrNotEnabled || _error != null) ...[
        const SizedBox(height: 10),
        Text(_qrNotEnabled ? t.closeQrNotEnabled : _error!,
            key: const Key('payment-error'),
            style: context.type.bodySmall!.copyWith(color: context.scheme.error)),
      ],
    ];
  }
}
