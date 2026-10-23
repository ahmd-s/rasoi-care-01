import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/models.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/providers.dart';
import '../shop/shop_screen.dart' show productName, shopProducts;
import 'select_location_screen.dart';

// A thin frame every booking step shares: progress bar + dock.
class _StepScaffold extends StatelessWidget {
  const _StepScaffold({
    required this.title,
    required this.progress,
    required this.body,
    required this.dock,
  });
  final String title;
  final double progress;
  final Widget body, dock;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            leading: BackButton(onPressed: context.pop), title: Text(title)),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  children: [
                    ProgressBar(progress),
                    const SizedBox(height: 18),
                    body,
                  ],
                ),
              ),
              Dock(child: dock),
            ],
          ),
        ),
      );
}

// ============================================================ 1 · ISSUE
class IssueScreen extends ConsumerWidget {
  const IssueScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(bookingDraftProvider);
    final vm = ref.read(bookingDraftProvider.notifier);
    final t = context.l10n;
    return _StepScaffold(
      title: t.issueTitle,
      progress: 0.25,
      dock: SizedBox(
        width: double.infinity,
        child: FilledButton(
            onPressed: () => context.push('/book/slot'),
            child: Text(t.issueNextButton)),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.issueBody, style: context.type.bodyMedium),
          const SizedBox(height: 18),
          for (var i = 0; i < draft.issues.length; i++) ...[
            _IssueRow(issue: draft.issues[i], onTap: () => vm.toggleIssue(i)),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 8),
          TextFormField(
            initialValue: draft.notes,
            maxLines: 3,
            onChanged: vm.setNotes,
            decoration: InputDecoration(labelText: t.issueNotesLabel),
          ),
          const SizedBox(height: 22),
          Eyebrow(t.issuePhotosEyebrow),
          const SizedBox(height: 10),
          const _PhotoPicker(),
        ],
      ),
    );
  }
}

class _IssueRow extends StatelessWidget {
  const _IssueRow({required this.issue, required this.onTap});
  final Issue issue;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => CareCard(
        onTap: onTap,
        borderColor: issue.selected ? context.scheme.primary : null,
        child: Row(children: [
          Icon(issue.selected ? Icons.check_box : Icons.check_box_outline_blank,
              color: issue.selected
                  ? context.scheme.primary
                  : context.care.hairline),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(issue.label,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(issue.hint, style: context.type.bodySmall),
              ],
            ),
          ),
        ]),
      );
}

/// Up to 4 real photos, picked from the camera or gallery — previously four
/// decorative boxes captioned "Filter"/"Model tag"/"Add"/"Gallery" (leftover
/// labels that didn't match any actual action; tapping one did nothing).
/// These stay local to the booking flow rather than being uploaded anywhere
/// — there's no backend field yet to attach photos to a booking, so showing
/// them as sent to the technician would be exactly the kind of fabrication
/// this app avoids elsewhere. The customer still gets a real, working way to
/// review what they're about to describe before confirming the booking.
class _PhotoPicker extends StatefulWidget {
  const _PhotoPicker();
  @override
  State<_PhotoPicker> createState() => _PhotoPickerState();
}

class _PhotoPickerState extends State<_PhotoPicker> {
  static const _maxPhotos = 4;
  final List<File> _photos = [];

  Future<void> _add() async {
    final t = context.l10n;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(t.issuePhotoCamera),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(t.issuePhotoGallery),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final picked =
        await ImagePicker().pickImage(source: source, imageQuality: 80);
    if (picked != null && mounted)
      setState(() => _photos.add(File(picked.path)));
  }

  void _remove(int i) => setState(() => _photos.removeAt(i));

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (var i = 0; i < _maxPhotos; i++) ...[
        Expanded(
          child: i < _photos.length
              ? _FilledPhotoTile(file: _photos[i], onRemove: () => _remove(i))
              : _EmptyPhotoTile(onTap: i == _photos.length ? _add : null),
        ),
        if (i != _maxPhotos - 1) const SizedBox(width: 10),
      ],
    ]);
  }
}

class _EmptyPhotoTile extends StatelessWidget {
  const _EmptyPhotoTile({required this.onTap});
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: 1,
        child: InkWell(
          onTap: onTap,
          borderRadius: Radii.rMd,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.scheme.surfaceContainerHigh,
              borderRadius: Radii.rMd,
              border: Border.all(color: context.care.hairline),
            ),
            child: Icon(
              onTap != null
                  ? Icons.add_a_photo_outlined
                  : Icons.camera_alt_outlined,
              size: 18,
              color: context.care.inkFaint,
            ),
          ),
        ),
      );
}

class _FilledPhotoTile extends StatelessWidget {
  const _FilledPhotoTile({required this.file, required this.onRemove});
  final File file;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(
          borderRadius: Radii.rMd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(file, fit: BoxFit.cover),
              Positioned(
                right: 3,
                top: 3,
                child: GestureDetector(
                  onTap: onRemove,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                        color: Colors.black54, shape: BoxShape.circle),
                    child:
                        const Icon(Icons.close, size: 13, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

// ============================================================ 2 · SLOT
class SlotScreen extends ConsumerWidget {
  const SlotScreen({super.key});

  /// Today plus the next 5 real calendar days — this used to be six days
  /// hardcoded to "24 Jul – 29 Jul" regardless of the actual date, so every
  /// booking after that one week showed the wrong "Today".
  static List<(String, String, DateTime)> _days(String todayLabel) {
    final now = DateTime.now();
    return [
      for (var i = 0; i < 6; i++)
        (
          i == 0
              ? todayLabel
              : DateFormat('E').format(now.add(Duration(days: i))),
          DateFormat('d MMM').format(now.add(Duration(days: i))),
          DateTime(now.year, now.month, now.day).add(Duration(days: i)),
        ),
    ];
  }

  // Business hours 10 am–7 pm, 90-minute slots — was 8 am–8 pm in 1–2 hour
  // blocks that didn't match the actual service window.
  static const _am = ['10:00 – 11:30 am', '11:30 am – 1:00 pm'];
  static const _pm = [
    '1:00 – 2:30 pm',
    '2:30 – 4:00 pm',
    '4:00 – 5:30 pm',
    '5:30 – 7:00 pm'
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(bookingDraftProvider);
    final vm = ref.read(bookingDraftProvider.notifier);
    final t = context.l10n;
    final days = _days(t.slotToday);
    return _StepScaffold(
      title: t.slotTitle,
      progress: 0.5,
      dock: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Eyebrow(t.slotSelectedEyebrow),
              Text('${draft.day} · ${draft.slot}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        FilledButton(
            onPressed: () => context.push('/book/address'),
            child: Text(t.slotNext)),
      ]),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 76,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: days.length,
              separatorBuilder: (_, __) => const SizedBox(width: 9),
              itemBuilder: (_, i) {
                final label = '${days[i].$1} ${days[i].$2}';
                final sel = draft.day == label;
                return Pressable(
                  onTap: () =>
                      vm.setSlot(label, draft.slot, dayDate: days[i].$3),
                  child: Container(
                    width: 66,
                    decoration: BoxDecoration(
                      color:
                          sel ? context.scheme.primary : context.scheme.surface,
                      borderRadius: Radii.rMd,
                      border: Border.all(
                          color: sel
                              ? context.scheme.primary
                              : context.care.hairline),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(days[i].$1,
                            style: TextStyle(
                                fontSize: 11,
                                color: sel
                                    ? context.scheme.onPrimary
                                        .withValues(alpha: 0.8)
                                    : context.care.inkMuted)),
                        const SizedBox(height: 3),
                        Text(days[i].$2.split(' ').first,
                            style: CareType.mono(
                                sel
                                    ? context.scheme.onPrimary
                                    : context.scheme.onSurface,
                                size: 15,
                                w: FontWeight.w600)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SectionHeader(t.slotMorning),
          _slotGrid(context, ref, draft, _am),
          SectionHeader(t.slotAfternoonEvening),
          _slotGrid(context, ref, draft, _pm),
        ],
      ),
    );
  }

  Widget _slotGrid(BuildContext context, WidgetRef ref, BookingDraft draft,
      List<String> slots) {
    final vm = ref.read(bookingDraftProvider.notifier);
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.5,
      children: [
        for (final s in slots)
          Pressable(
            onTap: () => vm.setSlot(draft.day, s),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: draft.slot == s
                    ? context.scheme.primary
                    : context.scheme.surface,
                borderRadius: Radii.rMd,
                border: Border.all(
                    color: draft.slot == s
                        ? context.scheme.primary
                        : context.care.hairline),
              ),
              child: Text(s,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: draft.slot == s
                          ? context.scheme.onPrimary
                          : context.scheme.onSurface)),
            ),
          ),
      ],
    );
  }
}

// ============================================================ 3 · ADDRESS
class AddressScreen extends ConsumerWidget {
  const AddressScreen({super.key});

  // Prefers the exact object just picked (carries structured fields the
  // saved-addresses list lookup below wouldn't have yet on the very same
  // frame it's set), falling back to a lookup by id for whatever was
  // already selected coming into this step.
  SavedAddress? _currentAddress(WidgetRef ref, BookingDraft draft) {
    if (draft.pickedAddress?.id == draft.addressId) return draft.pickedAddress;
    for (final a in ref.read(savedAddressesProvider)) {
      if (a.id == draft.addressId) return a;
    }
    return draft.pickedAddress;
  }

  Future<void> _selectAddress(
      BuildContext context, BookingDraftVM vm, String? currentId) async {
    final picked = await Navigator.of(context).push<SavedAddress>(
      MaterialPageRoute(
          builder: (_) => SelectLocationScreen(currentId: currentId)),
    );
    if (picked != null) vm.setPickedAddress(picked);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(bookingDraftProvider);
    final vm = ref.read(bookingDraftProvider.notifier);
    final current = _currentAddress(ref, draft);
    final t = context.l10n;
    return _StepScaffold(
      title: t.addressTitle,
      progress: 0.75,
      dock: SizedBox(
        width: double.infinity,
        child: FilledButton(
            onPressed:
                current == null ? null : () => context.push('/book/payment'),
            child: Text(t.addressReviewAndPay)),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (current == null)
            CareCard(
              onTap: () => _selectAddress(context, vm, draft.addressId),
              child: Row(children: [
                Icon(Icons.add_location_alt_outlined,
                    color: context.scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(t.addressSelectLocation,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w700)),
                ),
                const Icon(Icons.chevron_right),
              ]),
            )
          else
            CareCard(
              onTap: () => _selectAddress(context, vm, draft.addressId),
              child: Row(children: [
                Text(current.glyph, style: const TextStyle(fontSize: 17)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(current.label,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(current.line, style: context.type.bodySmall),
                    ],
                  ),
                ),
                Text(t.addressChange,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w700)),
              ]),
            ),
          const SizedBox(height: 16),
          CareField(t.addressDirectionsLabel,
              initial: draft.directions,
              maxLines: 2,
              onChanged: vm.setDirections),
        ],
      ),
    );
  }
}

// ============================================================ 4 · PAYMENT
class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({super.key});
  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  bool _submitting = false;
  late final Razorpay _razorpay;
  String? _pendingOrderId;
  PaymentSuccessResponse? _pendingPayment;

  @override
  void initState() {
    super.initState();
    _razorpay = Razorpay()
      ..on(Razorpay.EVENT_PAYMENT_SUCCESS, _onPaymentSuccess)
      ..on(Razorpay.EVENT_PAYMENT_ERROR, _onPaymentError);
  }

  @override
  void dispose() {
    _razorpay.clear();
    super.dispose();
  }

  void _onPaymentSuccess(PaymentSuccessResponse response) {
    _pendingPayment = response;
    unawaited(_confirmPayment());
  }

  void _onPaymentError(PaymentFailureResponse response) {
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _pendingOrderId = null;
      _pendingPayment = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(response.message?.isNotEmpty == true
          ? response.message!
          : 'Payment was not completed. No booking was placed.'),
    ));
  }

  Future<void> _confirmPayment() async {
    final payment = _pendingPayment;
    final orderId = _pendingOrderId;
    if (payment == null || orderId == null) return;
    final paymentId = payment.paymentId;
    final signature = payment.signature;
    if (paymentId == null || signature == null) {
      if (mounted) setState(() => _submitting = false);
      return;
    }
    final result = await ref.read(apiRepositoryProvider).verifyRazorpayPayment(
          orderId: orderId,
          paymentId: paymentId,
          signature: signature,
        );
    if (!mounted) return;
    if (result.error != null) {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${result.error} Tap “Retry confirmation” to safely check again.'),
      ));
      return; // retain payment response: retry verifies it, never charges again
    }
    _pendingOrderId = null;
    _pendingPayment = null;
    setState(() => _submitting = false);
    ref.read(shopCartProvider.notifier).clear();
    final bookings = result.bookings ?? const <Booking>[];
    if (bookings.isNotEmpty) {
      context.go('/booking/${bookings.first.id}/confirmed',
          extra: bookings.length);
    } else if (result.shopOrderPlaced) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Payment confirmed and shop order placed.')),
      );
      context.go('/');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Payment was confirmed, but no order details were returned. Contact support.')),
      );
    }
  }

  /// Starts one Razorpay checkout for this combined cart. The server prices
  /// both parts and only creates booking/shop records after payment verifies.
  Future<void> _pay(BookingDraft draft, Map<String, int> shopCart) async {
    if (_submitting) return;
    if (_pendingPayment != null) {
      setState(() => _submitting = true);
      await _confirmPayment();
      return;
    }
    if (draft.services.isEmpty && shopCart.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.paymentEmptyCart)),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      SavedAddress? selected;
      for (final a in [
        ...ref.read(savedAddressesProvider),
        if (draft.pickedAddress != null) draft.pickedAddress!,
      ]) {
        if (a.id == draft.addressId) {
          selected = a;
          break;
        }
      }
      // One real booking per selected service — each keeps its own real
      // allocated price and gets routed/tracked independently on the
      // Partner side. Awaited (not fire-and-forget) because the
      // confirmation screen needs the real booking id(s) that come back —
      // it used to always link to the same hardcoded "CP-2481-NSK" no
      // matter what was actually created, which is exactly why "the actual
      // booking" never showed up.
      final directions = draft.directions.trim();
      final notes = draft.notes.trim();
      // What the customer actually ticked on the Issue screen — previously
      // collected in this exact draft and then never sent anywhere, so a
      // technician's job screen had nothing real to show and fell back to a
      // canned, identical symptom list for every booking.
      final selectedIssues = [
        for (final issue in draft.issues)
          if (issue.selected) issue.label,
      ];
      if (draft.useCoins) {
        if (!mounted) return;
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Turn off Care Coins to pay online. Care Coins are not available with Razorpay yet.'),
        ));
        return;
      }
      final bookingPayload = <String, dynamic>{
        if (selected?.label != null && selected!.label.isNotEmpty)
          'area': selected.label,
        if (selected?.line != null && selected!.line.isNotEmpty)
          'addressLine': selected.line,
        if (selected?.lat != null) 'lat': selected!.lat,
        if (selected?.lng != null) 'lng': selected!.lng,
        if (directions.isNotEmpty) 'directions': directions,
        if (notes.isNotEmpty) 'notes': notes,
        if (selectedIssues.isNotEmpty) 'issues': selectedIssues,
        if (draft.scheduledAt != null)
          'scheduledAt': draft.scheduledAt!.toUtc().toIso8601String(),
      };
      final shopItems = [
        for (final item in shopCart.entries)
          {'productId': item.key, 'qty': item.value},
      ];
      final result = await ref.read(apiRepositoryProvider).createRazorpayOrder(
            services: draft.services,
            booking: bookingPayload,
            shopItems: shopItems,
          );
      if (!mounted) return;
      if (result.order == null) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.error ?? 'Could not start secure payment.'),
        ));
        return;
      }
      final order = result.order!;
      _pendingOrderId = order['orderId'] as String?;
      if (_pendingOrderId == null) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Payment server returned an invalid order. Please try again.'),
        ));
        return;
      }
      _razorpay.open({
        'key': order['keyId'],
        'order_id': order['orderId'],
        'amount': order['amount'],
        'currency': order['currency'],
        'name': order['name'],
        'description': order['description'],
        'timeout': 300,
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _pendingOrderId = null;
        _pendingPayment = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.paymentOrderError)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(bookingDraftProvider);
    final pricing =
        computePricing(draft.services, useCoins: false, coinsBalance: 0);
    // A Shop cart added from ShopScreen rides along here rather than
    // needing its own separate checkout — see shopCartProvider's
    // doc-comment. Kit MRPs are the final, all-inclusive price (no visit
    // fee or GST stacked on them the way a service booking gets), so they
    // just add straight onto the combined total below.
    final shopCart = ref.watch(shopCartProvider);
    final shopLines = [
      for (final e in shopCart.entries)
        (shopProducts.firstWhere((p) => p.id == e.key), e.value),
    ];
    final shopTotalPaise =
        shopLines.fold(0, (sum, l) => sum + l.$1.mrpPaise * l.$2);
    final grandTotalPaise = pricing.grandTotalPaise + shopTotalPaise;
    final t = context.l10n;
    return _StepScaffold(
      title: t.paymentTitle,
      progress: 1,
      dock: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Eyebrow(_pendingPayment == null
                  ? t.paymentDueAfterVisit
                  : t.paymentRetryVerification),
              Text(Money.rupees(grandTotalPaise),
                  style: CareType.mono(context.scheme.onSurface,
                      size: 17, w: FontWeight.w600)),
            ],
          ),
        ),
        FilledButton(
          onPressed: _submitting ? null : () => _pay(draft, shopCart),
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(_pendingPayment == null
                  ? t.paymentPayButton(Money.rupees(grandTotalPaise))
                  : t.paymentRetryVerification),
        ),
      ]),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CareCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in draft.services) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(s.title,
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w700)),
                      ),
                      Text(Money.rupees(s.pricePaise),
                          style: CareType.mono(context.scheme.onSurface,
                              size: 12)),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                for (final (product, qty) in shopLines) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text('${productName(product.id, t)} × $qty',
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w700)),
                      ),
                      Text(Money.rupees(product.mrpPaise * qty),
                          style: CareType.mono(context.scheme.onSurface,
                              size: 12)),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                if (draft.services.isNotEmpty)
                  Text('${draft.day} · ${draft.slot}',
                      style: context.type.bodySmall),
                if (draft.services.isNotEmpty) ...[
                  const Divider(height: 24),
                  _priceLine(context, t.paymentVisitFee,
                      Money.rupees(pricing.visitFeePaise)),
                  if (pricing.couponDiscountPaise > 0)
                    _priceLine(context, t.paymentCouponApplied,
                        '-${Money.rupees(pricing.couponDiscountPaise)}',
                        color: context.care.success),
                  _priceLine(
                      context, t.paymentGst, Money.rupees(pricing.gstPaise)),
                  if (pricing.coinsRedeemed > 0)
                    _priceLine(context, t.paymentCoinsUsed,
                        '-${Money.rupees(pricing.coinsRedeemed * 100)}',
                        color: context.care.success),
                ],
                const Divider(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(t.paymentTotal,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w700)),
                    Text(Money.rupees(grandTotalPaise),
                        style: CareType.mono(context.scheme.onSurface,
                            size: 18, w: FontWeight.w600)),
                  ],
                ),
              ],
            ),
          ),
          // Care Coins are intentionally hidden during Razorpay checkout
          // until the server can safely reserve/refund them around payment.
          SectionHeader(t.paymentAfterVisitSection),
          CareCard(
            borderColor: context.scheme.primary,
            child: Row(children: [
              Icon(Icons.payments_outlined, color: context.scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.paymentAfterVisitTitle,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700)),
                    Text(t.paymentAfterVisitDetail,
                        style: context.type.bodySmall),
                  ],
                ),
              ),
              Icon(Icons.check_circle, color: context.scheme.primary),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _priceLine(BuildContext context, String label, String value,
          {Color? color}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: context.type.bodySmall),
            Text(value,
                style:
                    CareType.mono(color ?? context.scheme.onSurface, size: 12)),
          ],
        ),
      );
}

// ============================================================ CONFIRMED
// Previously always showed the same hardcoded "JOB CP-2481-NSK", a fixed
// mock technician's name/rating (with call/chat buttons that didn't do
// anything), and a fabricated "start code 4402" — regardless of what was
// actually booked. Now built from the real booking the backend just
// created; no technician identity is shown at all until one is genuinely
// assigned, since the Customer app has no real way to know who that is yet.
class ConfirmedScreen extends ConsumerWidget {
  const ConfirmedScreen(
      {super.key, required this.bookingId, this.totalBooked = 1});
  final String bookingId;
  final int totalBooked;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(bookingsRefreshProvider);
    final booking = ref.watch(repositoryProvider).bookingById(bookingId);
    final t = context.l10n;
    final summary = booking == null
        ? t.confirmedAssigning
        : t.confirmedSummary(
            '${booking.title}${totalBooked > 1 ? t.confirmedMoreSuffix(totalBooked - 1) : ''}',
            booking.addressLabel,
          );
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 34, 20, 20),
                children: [
                  Center(
                    child: Column(
                      children: [
                        CareDial(
                          value: 1,
                          size: 94,
                          color: context.care.success,
                          child: Icon(Icons.check,
                              size: 40, color: context.care.success),
                        ),
                        const SizedBox(height: 22),
                        Text(t.confirmedTitle,
                            style: context.type.headlineMedium),
                        const SizedBox(height: 10),
                        Text(summary,
                            textAlign: TextAlign.center,
                            style: context.type.bodyMedium),
                        const SizedBox(height: 14),
                        Mono('JOB $bookingId',
                            color: context.scheme.secondary, size: 13),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Dock(
              child: Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => context.go('/'),
                      child: Text(t.confirmedHome)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                      onPressed: () =>
                          context.push('/booking/$bookingId/track'),
                      child: Text(t.confirmedTrackVisit)),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
