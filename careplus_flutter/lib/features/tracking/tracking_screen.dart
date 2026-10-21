import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/config/maps_config.dart';
import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/api/api_repository.dart';
import '../../data/firebase/technician_location_service.dart';
import '../../data/models.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/firestore_providers.dart';
import '../../state/providers.dart';
import '../booking/cancellation_policy_sheet.dart';

/// Real backend status order — mirrors kBookingStatusOrder in the Partner
/// app (app.py enforces the same progression server-side). These are the
/// backend's literal status values, matched against booking.rawStatus —
/// never shown to the customer directly; see _statusLabel for the real,
/// localized display text.
const _statusOrder = ['Requested', 'Accepted', 'On the way', 'In Progress', 'Completed'];

String _statusLabel(String rawStatus, AppLocalizations t) => switch (rawStatus) {
      'Requested' => t.trackingStatusRequested,
      'Accepted' => t.trackingStatusAccepted,
      'On the way' => t.trackingStatusOnTheWay,
      'In Progress' => t.trackingStatusInProgress,
      'Completed' => t.trackingStatusCompleted,
      _ => rawStatus,
    };

class TrackingScreen extends ConsumerStatefulWidget {
  const TrackingScreen({super.key, required this.bookingId});
  final String bookingId;

  @override
  ConsumerState<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends ConsumerState<TrackingScreen> {
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // A status change (technician accepts, heads over, arrives) used to
    // never appear here until the customer backed out to the bookings list
    // and pulled to refresh — the only fetch was whatever BookingsScreen
    // last did before this screen opened. That's exactly the window this
    // screen most needs to catch live: the 4-digit code below only shows
    // for the brief Accepted/On-the-way stretch, so without polling here a
    // customer who just watches this screen can easily never see it at all.
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final repo = ref.read(repositoryProvider);
    if (repo is ApiRepository) await repo.refreshBookings();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(bookingsRefreshProvider);
    final repo = ref.watch(repositoryProvider);
    final booking = repo.bookingById(widget.bookingId);

    // Location is only exposed while this booking is in an active service
    // state. A completed or cancelled booking must not keep showing a
    // technician who may now be working for someone else.
    final canTrack = booking != null &&
        const {'Accepted', 'On the way', 'In Progress'}.contains(booking.rawStatus);
    final liveLocation = (MapsConfig.isConfigured && canTrack)
        ? ref.watch(technicianLocationProvider(widget.bookingId)).valueOrNull
        : null;

    final stepIndex = booking == null ? 0 : _statusOrder.indexOf(booking.rawStatus);
    final cancelled = booking?.status == BookingStatus.cancelled;
    final t = context.l10n;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
            onPressed: () => context.canPop() ? context.pop() : context.go('/')),
        title: Text(t.trackingTitle),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
          children: [
            _TrackingMap(
              booking: booking,
              liveLocation: liveLocation,
              canTrack: canTrack,
            ),
            const SizedBox(height: 16),
            CareCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Eyebrow(t.trackingStatusEyebrow),
                  const SizedBox(height: 4),
                  Text(
                      cancelled
                          ? t.trackingStatusCancelled
                          : (booking?.rawStatus.isNotEmpty ?? false)
                              ? _statusLabel(booking!.rawStatus, t)
                              : t.trackingStatusRequested,
                      style: CareType.mono(context.scheme.onSurface,
                          size: 20, w: FontWeight.w600)),
                  if (booking != null) ...[
                    const SizedBox(height: 3),
                    Text('${booking.title} · ${booking.addressLabel}',
                        style: context.type.bodySmall),
                  ],
                ],
              ),
            ),
            if (!cancelled) ...[
              const SizedBox(height: 12),
              CareCard(
                child: Row(children: [
                  Icon(Icons.person_outline, color: context.care.inkFaint, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                        stepIndex >= 1 ? t.trackingTechAssigned : t.trackingFindingTech,
                        style: context.type.bodySmall),
                  ),
                ]),
              ),
            ],
            // Shown only up through "On the way" — the technician's app
            // requires this exact code before it lets them start work (see
            // advance_booking in app.py), so it stops being anything the
            // customer needs to keep handy once work has actually begun.
            if (!cancelled && stepIndex >= 1 && stepIndex <= 2 && booking?.startCode != null) ...[
              const SizedBox(height: 12),
              CareCard(
                color: context.scheme.primaryContainer,
                borderColor: Colors.transparent,
                child: Row(
                  children: [
                    Icon(Icons.pin_outlined, color: context.scheme.onPrimaryContainer, size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.trackingGiveCode,
                              style: context.type.bodySmall!
                                  .copyWith(color: context.scheme.onPrimaryContainer)),
                          const SizedBox(height: 4),
                          Text(booking!.startCode!,
                              style: CareType.mono(context.scheme.onPrimaryContainer,
                                  size: 26, w: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (!cancelled && booking != null && stepIndex < _statusOrder.length - 1) ...[
              const SizedBox(height: 12),
              CareCard(
                onTap: () => showCancellationPolicySheet(context, booking: booking),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: context.care.inkFaint, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(t.trackingCancellationPolicy, style: context.type.bodySmall),
                    ),
                    Icon(Icons.chevron_right, color: context.care.inkFaint, size: 20),
                  ],
                ),
              ),
            ],
            SectionHeader(t.trackingProgressHeader),
            if (booking == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(t.trackingLoadingBooking, style: context.type.bodySmall),
              )
            else if (cancelled)
              StepDot(TimelineStepView(
                  t.trackingBookingCancelledStep, booking.whenLabel, TrackState.done),
                  last: true)
            else ...[
              StepDot(TimelineStepView(
                  t.trackingBookingConfirmedStep, booking.whenLabel, TrackState.done)),
              for (var i = 1; i < _statusOrder.length; i++)
                StepDot(
                  TimelineStepView(
                    _statusOrder[i] == 'Accepted'
                        ? t.trackingTechAssignedStep
                        : _statusLabel(_statusOrder[i], t),
                    '',
                    i < stepIndex
                        ? TrackState.done
                        : i == stepIndex
                            ? TrackState.now
                            : TrackState.upcoming,
                  ),
                  last: i == _statusOrder.length - 1,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows the customer's service location while the technician's first GPS fix
/// is pending, then follows the technician as Firestore positions arrive.
/// A completed/cancelled booking never subscribes to live technician data.
class _TrackingMap extends StatefulWidget {
  const _TrackingMap({
    required this.booking,
    required this.liveLocation,
    required this.canTrack,
  });
  final Booking? booking;
  final TechnicianLocation? liveLocation;
  final bool canTrack;

  @override
  State<_TrackingMap> createState() => _TrackingMapState();
}

class _TrackingMapState extends State<_TrackingMap> {
  GoogleMapController? _controller;
  Timer? _freshnessTimer;

  @override
  void initState() {
    super.initState();
    // Refresh the live/stale indicator even if a location stream stops
    // emitting, so a disconnected technician never stays marked "live".
    _freshnessTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && widget.liveLocation?.updatedAt != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _TrackingMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.liveLocation;
    final current = widget.liveLocation;
    if (current != null &&
        (previous == null || previous.lat != current.lat || previous.lng != current.lng)) {
      _follow(current);
    }
  }

  void _follow(TechnicianLocation location) {
    _controller?.animateCamera(CameraUpdate.newLatLng(
      LatLng(location.lat, location.lng),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final booking = widget.booking;
    final liveLocation = widget.liveLocation;
    final hasCustomerPoint = booking?.lat != null && booking?.lng != null;
    if (MapsConfig.isConfigured && (liveLocation != null || hasCustomerPoint)) {
      final t = context.l10n;
      final techPoint = liveLocation == null
          ? null
          : LatLng(liveLocation.lat, liveLocation.lng);
      final customerPoint =
          hasCustomerPoint
              ? LatLng(booking!.lat!, booking.lng!)
              : null;
      final initialPoint = techPoint ?? customerPoint!;
      final updatedAt = liveLocation?.updatedAt;
      final isStale = updatedAt != null &&
          DateTime.now().difference(updatedAt) > const Duration(seconds: 75);
      return ClipRRect(
        borderRadius: Radii.rLg,
        child: SizedBox(
          height: 210,
          child: Stack(
            children: [
              GoogleMap(
                initialCameraPosition: CameraPosition(target: initialPoint, zoom: 14),
                onMapCreated: (controller) {
                  _controller = controller;
                  if (techPoint != null) {
                    controller.animateCamera(CameraUpdate.newLatLng(techPoint));
                  }
                },
                markers: {
                  if (techPoint != null)
                    Marker(
                      markerId: const MarkerId('technician'),
                      position: techPoint,
                      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
                      infoWindow: InfoWindow(title: t.trackingMarkerTechnician),
                    ),
                  if (customerPoint != null)
                    Marker(
                      markerId: const MarkerId('customer'),
                      position: customerPoint,
                      infoWindow: InfoWindow(title: t.trackingMarkerAddress),
                    ),
                },
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                liteModeEnabled: true,
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: _LocationStatusPill(
                  text: !widget.canTrack
                      ? t.trackingLocationNotActive
                      : liveLocation == null
                          ? t.trackingWaitingForLocation
                          : isStale
                              ? t.trackingLocationStale
                              : t.trackingLocationLive,
                  live: liveLocation != null && !isStale && widget.canTrack,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      height: 210,
      decoration: BoxDecoration(
        color: context.scheme.surfaceContainerHigh,
        borderRadius: Radii.rLg,
        border: Border.all(color: context.care.hairline),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 38, color: context.care.inkFaint),
            const SizedBox(height: 8),
            Text(
              MapsConfig.isConfigured
                  ? context.l10n.trackingWaitingForLocation
                  : context.l10n.trackingMapSetupRequired,
              style: context.type.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationStatusPill extends StatelessWidget {
  const _LocationStatusPill({required this.text, required this.live});
  final String text;
  final bool live;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: context.scheme.surface.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 8)],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 9,
                  color: live ? context.scheme.primary : context.care.inkFaint),
              const SizedBox(width: 7),
              Flexible(child: Text(text, style: context.type.labelSmall)),
            ],
          ),
        ),
      );
}
