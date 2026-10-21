// Domain models for Care+.
//
// Money is stored in paise (integer) everywhere and only formatted at the edge
// — floating-point rupees are how you end up owing a customer ₹0.01. See
// [Money] for the formatter.

import 'package:intl/intl.dart';

/// Which of the eight kitchen appliances a service belongs to.
enum Appliance {
  chimney('Kitchen chimney', '◍'),
  hob('Gas hob', '⊙'),
  cooktop('Cooktop', '▤'),
  dishwasher('Dishwasher', '▥'),
  microwave('Built-in microwave', '▣'),
  refrigerator('Refrigerator', '❄'),
  otg('OTG', '▦'),
  purifier('Water purifier', '◈');

  const Appliance(this.label, this.glyph);
  final String label;
  final String glyph;
}

/// A bookable service under an appliance (deep clean, repair visit, install…).
class ServiceItem {
  const ServiceItem({
    required this.id,
    required this.appliance,
    required this.title,
    required this.blurb,
    required this.pricePaise,
    required this.durationMin,
    this.mostBooked = false,
    this.strikePaise,
    this.included = const [],
    this.notIncluded = '',
    this.requirements = const [],
  });

  final String id;
  final Appliance appliance;
  final String title;
  final String blurb;
  final int pricePaise;
  final int durationMin;
  final bool mostBooked;
  final int? strikePaise;

  /// What's included in *this specific* service — shown as a dropdown on
  /// its card, not a shared appliance-wide list, since a repair visit and a
  /// deep clean genuinely include different things.
  final List<String> included;
  final String notIncluded;

  /// What the customer needs to have ready before the technician arrives
  /// (a nearby power point, water, a ladder for a high-mounted unit) — shown
  /// alongside "What's included" so there's no on-the-spot scramble at the
  /// door. Empty for a service with nothing unusual to ask for.
  final List<String> requirements;
}

/// One symptom a customer can flag before the visit.
class Issue {
  const Issue(this.label, this.hint, {this.selected = false});
  final String label;
  final String hint;
  final bool selected;
  Issue copyWith({bool? selected}) =>
      Issue(label, hint, selected: selected ?? this.selected);
}

/// One customer review on an appliance's service detail screen.
class Review {
  const Review(this.initials, this.name, this.meta, this.quote);
  final String initials;
  final String name;
  final String meta;
  final String quote;
}

/// Everything the service detail screen needs beyond the bookable
/// [ServiceItem]s themselves — rating, what's included, and reviews.
/// [comingSoon] appliances (refrigerator, water purifier as of writing)
/// have no services or issues yet — only [blurb] is shown.
class ApplianceDetail {
  const ApplianceDetail({
    required this.heading,
    required this.blurb,
    this.rating = 0,
    this.ratingCount = 0,
    this.reviews = const [],
    this.comingSoon = false,
  });
  final String heading;
  final String blurb;
  final double rating;
  final int ratingCount;
  final List<Review> reviews;
  final bool comingSoon;
}

class SavedAddress {
  /// [lat]/[lng] are null for the canned demo addresses (label-only, no
  /// real geocoding behind them) and for anything entered through the
  /// manual-entry fallback form when Maps isn't configured. They're set
  /// only when an address is confirmed through the real map picker — see
  /// AddressPickerScreen in lib/features/booking/address_picker_screen.dart.
  const SavedAddress(this.id, this.label, this.line, this.glyph,
      [this.lat, this.lng, this.pincode, this.photoUrl]);
  final String id;
  final String label;
  final String line;
  final String glyph;
  final double? lat;
  final double? lng;
  final String? pincode;
  final String? photoUrl;

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
        'line': line,
        'glyph': glyph,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (pincode != null) 'pincode': pincode,
        if (photoUrl != null) 'photoUrl': photoUrl,
      };

  static SavedAddress? fromMap(Map<String, dynamic> map) {
    final id = map['id'] as String?;
    final label = map['label'] as String?;
    final line = map['line'] as String?;
    final glyph = map['glyph'] as String?;
    if (id == null || label == null || line == null || glyph == null) return null;
    return SavedAddress(
      id,
      label,
      line,
      glyph,
      (map['lat'] as num?)?.toDouble(),
      (map['lng'] as num?)?.toDouble(),
      map['pincode'] as String?,
      map['photoUrl'] as String?,
    );
  }
}

/// A selectable entry on the checkout "Pay with" list. Purely a display
/// choice — no gateway is wired up behind any of these (see
/// PaymentScreen's build method), so the selection is never read by
/// booking creation. Shown because the customer explicitly asked to see
/// the familiar option list again, with the understanding that actual
/// payment collection is UPI-to-technician after the visit regardless of
/// which one is picked here.
class PaymentMethod {
  const PaymentMethod(this.id, this.name, this.detail, this.glyph, {required this.section});
  final String id;
  final String name;
  final String detail;
  final String glyph;

  /// Groups the checkout list under headers ("Pay on delivery", "UPI
  /// apps", ...) — PaymentScreen renders one only when it differs from
  /// the previous entry's, so [paymentMethods] must keep entries for the
  /// same section adjacent.
  final String section;
}

enum BookingStatus { scheduled, onTheWay, inProgress, completed, cancelled }

extension BookingStatusX on BookingStatus {
  String get label => switch (this) {
        BookingStatus.scheduled => 'Scheduled',
        BookingStatus.onTheWay => 'On the way',
        BookingStatus.inProgress => 'In progress',
        BookingStatus.completed => 'Completed',
        BookingStatus.cancelled => 'Cancelled',
      };
}

class Technician {
  const Technician({
    required this.id,
    required this.name,
    required this.initials,
    required this.rating,
    required this.jobsDone,
    required this.years,
    required this.vehicle,
  });
  final String id;
  final String name;
  final String initials;
  final double rating;
  final int jobsDone;
  final int years;
  final String vehicle;
}

/// A real part/extra-work quote a technician has raised for a booking —
/// see app.py's booking_parts table. `status` is 'pending' until the
/// customer decides; there's no undo once they approve or reject it.
class PartQuote {
  const PartQuote({
    required this.id,
    required this.name,
    this.sku,
    required this.qty,
    required this.pricePaise,
    required this.status,
  });

  final String id;
  final String name;
  final String? sku;
  final int qty;

  /// Per-unit price, in paise — the invoice's own display multiplies this
  /// by [qty] for the line total.
  final int pricePaise;
  final String status;

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';

  factory PartQuote.fromJson(Map<String, dynamic> json) => PartQuote(
        id: '${json['id']}',
        name: (json['name'] as String?) ?? '',
        sku: (json['sku'] as String?)?.trim().isNotEmpty == true ? json['sku'] as String : null,
        qty: (json['qty'] as num?)?.toInt() ?? 1,
        pricePaise: (json['pricePaise'] as num?)?.round() ?? 0,
        status: (json['status'] as String?) ?? 'pending',
      );
}

/// A real record of the technician swapping this booking's service for a
/// different one — e.g. asked mid-visit to upgrade a filter clean into a
/// full deep clean. See app.py's PATCH .../service. The invoice always
/// shows the booking's current (already-updated) service/total; this is
/// just the "here's what changed" note shown alongside it.
class ServiceChange {
  const ServiceChange({
    required this.id,
    required this.oldService,
    required this.newService,
    required this.oldPricePaise,
    required this.newPricePaise,
  });

  final String id;
  final String oldService;
  final String newService;
  final int oldPricePaise;
  final int newPricePaise;

  factory ServiceChange.fromJson(Map<String, dynamic> json) => ServiceChange(
        id: '${json['id']}',
        oldService: (json['oldService'] as String?) ?? '',
        newService: (json['newService'] as String?) ?? '',
        oldPricePaise: (json['oldPricePaise'] as num?)?.round() ?? 0,
        newPricePaise: (json['newPricePaise'] as num?)?.round() ?? 0,
      );
}

class Booking {
  const Booking({
    required this.id,
    required this.title,
    required this.appliance,
    required this.status,
    required this.whenLabel,
    required this.addressLabel,
    required this.totalPaise,
    this.technician,
    this.stars,
    this.technicianId,
    this.lat,
    this.lng,
    this.suctionBefore,
    this.suctionAfter,
    this.timeOnSiteMin,
    this.cancellationFeePaise,
    this.rawStatus = '',
    this.startCode,
    this.scheduledAt,
    this.brand,
    this.modelNumber,
    this.parts = const [],
    this.serviceChanges = const [],
  });

  final String id;
  final String title;
  final Appliance appliance;
  final BookingStatus status;
  final String whenLabel;
  final String addressLabel;
  final int totalPaise;
  final Technician? technician;
  final int? stars;

  /// The assigned technician's raw id, straight off the backend's
  /// `technicianId` field — unlike [technician] (a full profile, always
  /// null for API-sourced bookings, see ApiRepository) this is just the id,
  /// enough to look up their live location. See TechnicianLocationService
  /// in lib/data/firebase/technician_location_service.dart.
  final String? technicianId;

  /// The service address's coordinates, when known — set from the
  /// backend's `lat`/`lng` fields on bookings created through the real map
  /// picker. Null for anything booked with a label-only address.
  final double? lat;
  final double? lng;

  /// Real work-log readings, filled in by the technician as they actually
  /// advance the job (see app.py's advance_booking) — null until the
  /// relevant step has happened, which the invoice treats as "not
  /// recorded" rather than showing an invented number. For a chimney
  /// (Appliance.chimney) booking these are airflow readings in CFM,
  /// captured before/after the clean — the Partner app no longer asks for
  /// this on any other appliance. Minutes for time on site.
  final int? suctionBefore;
  final int? suctionAfter;
  final int? timeOnSiteMin;

  /// Set only once this booking is actually cancelled — the real fee
  /// charged for cancelling at that point in the job's progress (credited
  /// to the technician), from app.py's CANCELLATION_FEE_BY_STATUS. Null
  /// for anything not cancelled.
  final int? cancellationFeePaise;

  /// The backend's own status string (`Requested`/`Accepted`/`On the
  /// way`/`In Progress`/`Completed`/`Cancelled`), kept alongside [status]
  /// because that enum collapses Requested and Accepted into the same
  /// `scheduled` value — too coarse to preview a cancellation fee, which
  /// differs between the two. Empty for mock/demo bookings.
  final String rawStatus;

  /// The 4-digit code this booking's technician must ask for and enter
  /// before the backend lets them start work (see advance_booking in
  /// app.py) — hand it over only once they've actually arrived. Null once
  /// the job reaches "In Progress" or later (the backend only ever sends
  /// this to the customer, and only while it's still actionable), and
  /// always null for mock/demo bookings.
  final String? startCode;

  /// The real day+slot the customer picked, sent as an ISO timestamp from
  /// [providers.dart]'s BookingDraft.scheduledAt — see app.py's
  /// _cancellation_fee_for, which this drives. Null for a booking made
  /// before this existed, or with no picked slot.
  final DateTime? scheduledAt;

  /// The appliance's real brand/model, set by the technician once they're
  /// actually looking at it on-site — never typed by the customer. Null
  /// until a technician sets it.
  final String? brand;
  final String? modelNumber;

  /// Real part/extra-work quotes the technician has raised for this
  /// booking — see PartQuote. Empty when none exist.
  final List<PartQuote> parts;

  /// Real history of the technician swapping this booking's service for a
  /// different one — see ServiceChange. Empty when it's never happened.
  final List<ServiceChange> serviceChanges;
}

/// The cancellation-fee policy shown to the customer — mirrors (for
/// preview only) app.py's CANCELLATION_FEE_FAR_HOURS/NEAR_HOURS/
/// FAR_RUPEES/NEAR_RUPEES defaults. The server always recomputes and
/// applies the real fee independently when a cancellation actually
/// happens, so a stale preview here can never under- or overcharge — it
/// just shows the wrong estimate for a moment.
abstract final class CancellationPolicy {
  static const farHours = 12;
  static const nearHours = 3;
  static const farFeePaise = 10000;
  static const nearFeePaise = 20000;

  /// One row per tier, in display order, for the Cancellation Policy
  /// screen/sheet. `hoursThreshold`/`isFree` describe the tier structurally
  /// rather than storing an English label — cancellation_policy_sheet.dart
  /// builds the real, localized label from these at render time.
  static const tiers = [
    (hoursThreshold: farHours, isFree: true, feePaise: 0),
    (hoursThreshold: farHours, isFree: false, feePaise: farFeePaise),
    (hoursThreshold: nearHours, isFree: false, feePaise: nearFeePaise),
  ];

  /// What cancelling [booking] right now would cost, or null if it can't
  /// be cancelled at all (already completed/cancelled, or a mock/demo
  /// booking with no real status). Uses [Booking.scheduledAt] when set;
  /// falls back to the older status-based tiers for a booking made before
  /// that was captured, matching app.py's own fallback.
  static int? feePaisePreview(Booking booking) {
    if (booking.rawStatus == 'Completed' || booking.rawStatus == 'Cancelled') {
      return null;
    }
    final scheduledAt = booking.scheduledAt;
    if (scheduledAt != null) {
      final hoursLeft = scheduledAt.difference(DateTime.now()).inMinutes / 60;
      if (hoursLeft > farHours) return 0;
      if (hoursLeft > nearHours) return farFeePaise;
      return nearFeePaise;
    }
    return switch (booking.rawStatus) {
      'Requested' => 0,
      'Accepted' => farFeePaise,
      'On the way' || 'In Progress' => nearFeePaise,
      _ => null,
    };
  }
}

/// A timeline entry on the tracking screen.
class TimelineStep {
  const TimelineStep(this.title, this.detail, this.state);
  final String title;
  final String detail;
  final StepState state;
}

enum StepState { done, now, upcoming }

/// Indian-locale currency, from paise. `Money.rupees(89900) == '₹899'`.
abstract final class Money {
  static final _fmt = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );
  static String rupees(int paise) => _fmt.format(paise / 100);
}

