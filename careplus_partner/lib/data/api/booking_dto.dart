// Wire shape for a booking as returned by the real backend
// (GET /api/technician/bookings, PATCH /api/bookings/<id>/advance — see
// app.py's `booking_row_to_dict`). Only the fields this app actually uses
// are parsed; everything else in the JSON is ignored.

/// A real part/extra-work quote a technician has raised for a booking —
/// see app.py's booking_parts table and part_row_to_dict. `status` is one
/// of 'pending'/'approved'/'rejected', kept as the raw backend string here
/// (models.dart's PartLine parses it into PartStatus) since this file is
/// pure wire-shape parsing.
class PartQuoteDto {
  const PartQuoteDto({
    required this.id,
    required this.name,
    this.sku,
    required this.qty,
    required this.pricePaise,
    required this.status,
    this.decidedAt,
  });

  final String id;
  final String name;
  final String? sku;
  final int qty;
  final int pricePaise;
  final String status;
  final String? decidedAt;

  factory PartQuoteDto.fromJson(Map<String, dynamic> json) => PartQuoteDto(
        id: '${json['id']}',
        name: (json['name'] as String?) ?? '',
        sku: (json['sku'] as String?)?.trim().isNotEmpty == true ? json['sku'] as String : null,
        qty: (json['qty'] as num?)?.toInt() ?? 1,
        pricePaise: (json['pricePaise'] as num?)?.round() ?? 0,
        status: (json['status'] as String?) ?? 'pending',
        decidedAt: json['decidedAt'] as String?,
      );
}

/// A real record of the technician swapping this booking's service for a
/// different one — e.g. the customer asked mid-visit to upgrade a filter
/// clean into a full deep clean. See app.py's PATCH .../service.
class ServiceChangeDto {
  const ServiceChangeDto({
    required this.id,
    required this.oldService,
    required this.newService,
    required this.oldPricePaise,
    required this.newPricePaise,
    this.createdAt,
  });

  final String id;
  final String oldService;
  final String newService;
  final int oldPricePaise;
  final int newPricePaise;
  final DateTime? createdAt;

  factory ServiceChangeDto.fromJson(Map<String, dynamic> json) => ServiceChangeDto(
        id: '${json['id']}',
        oldService: (json['oldService'] as String?) ?? '',
        newService: (json['newService'] as String?) ?? '',
        oldPricePaise: (json['oldPricePaise'] as num?)?.round() ?? 0,
        newPricePaise: (json['newPricePaise'] as num?)?.round() ?? 0,
        createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}'),
      );
}

/// One real, catalog-priced service option a technician can switch a
/// booking to — from GET /api/services?category=..., the same real
/// backend catalog create_booking's service_id path prices a new booking
/// from. Only ever offered for the booking's own category, so a chimney
/// job can't be "upgraded" into a fridge repair.
class ServiceOptionDto {
  const ServiceOptionDto({
    required this.id,
    required this.category,
    required this.applianceName,
    required this.name,
    required this.pricePaise,
  });

  final String id;
  final String category;
  final String applianceName;
  final String name;
  final int pricePaise;

  /// Matches the "Appliance · Service" naming create_booking/
  /// update_booking_service both use server-side for `bookings.service`.
  String get displayName => '$applianceName · $name';

  factory ServiceOptionDto.fromJson(Map<String, dynamic> json) => ServiceOptionDto(
        id: '${json['id']}',
        category: (json['category'] as String?) ?? '',
        applianceName: (json['appliance_name'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        pricePaise: ((json['price'] as num?) ?? 0).round() * 100,
      );
}

/// What the server says about money for a booking. Everything here is derived
/// server-side from verified payments — the app never computes "paid".
class PaymentSummaryDto {
  const PaymentSummaryDto({
    this.mode,
    this.status = 'unpaid',
    this.invoicePaise = 0,
    this.paidPaise = 0,
    this.duePaise = 0,
  });

  /// `pay_now` (paid online at checkout) or `pay_after_service`; null on
  /// bookings made before payment choice existed.
  final String? mode;

  /// `paid`, `unpaid` or `cancelled`.
  final String status;
  final int invoicePaise;
  final int paidPaise;
  final int duePaise;

  bool get isPaid => status == 'paid';
  bool get isPayAfterService => mode == 'pay_after_service';

  factory PaymentSummaryDto.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const PaymentSummaryDto();
    int paise(String key) => (json[key] as num?)?.round() ?? 0;
    return PaymentSummaryDto(
      mode: json['mode'] as String?,
      status: (json['status'] as String?) ?? 'unpaid',
      invoicePaise: paise('invoicePaise'),
      paidPaise: paise('paidPaise'),
      duePaise: paise('duePaise'),
    );
  }
}

/// The technician's live invoice QR as created by the server.
class InvoiceQrDto {
  const InvoiceQrDto({
    required this.qrId,
    required this.imageUrl,
    required this.amountPaise,
    required this.status,
  });
  final String qrId;
  final String imageUrl;
  final int amountPaise;

  /// `active`, `paid`, `expired` or `closed`.
  final String status;

  static InvoiceQrDto? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['qrId'];
    final url = json['imageUrl'];
    final amount = json['amountPaise'];
    if (id is! String || url is! String || amount is! num) return null;
    return InvoiceQrDto(
      qrId: id,
      imageUrl: url,
      amountPaise: amount.round(),
      status: (json['status'] as String?) ?? 'active',
    );
  }
}

/// Result of asking the server for / about a booking's invoice payment.
class PaymentStateDto {
  const PaymentStateDto({
    this.payment = const PaymentSummaryDto(),
    this.qr,
    this.error,
    this.code,
    this.warning,
  });
  final PaymentSummaryDto payment;
  final InvoiceQrDto? qr;

  /// Human-safe failure message; null on success.
  final String? error;

  /// `qr_not_enabled` when the payment account cannot issue UPI QR codes.
  final String? code;
  final String? warning;
}

class BookingDto {
  const BookingDto({
    required this.id,
    required this.category,
    required this.service,
    required this.status,
    required this.customerName,
    required this.totalAmountPaise,
    required this.area,
    this.addressLine,
    required this.createdAt,
    this.updatedAt,
    this.lat,
    this.lng,
    this.cancellationFeePaise,
    this.directions,
    this.notes,
    this.issues = const [],
    this.customerPhone,
    this.paymentMethod,
    this.payment = const PaymentSummaryDto(),
    this.beforePhotoReady = false,
    this.afterPhotoReady = false,
    this.signatureReady = false,
    this.brand,
    this.modelNumber,
    this.parts = const [],
    this.serviceChanges = const [],
  });

  final String id;
  final String category;
  final String service;
  final String status;
  final String customerName;
  final int totalAmountPaise;
  final String? area;
  /// The real street address behind [area] (which is just a short label
  /// like "Home"/"Office") — previously nothing but that label ever
  /// reached this app, so the job screen showed "Home" as the entire
  /// address while its own mini-map (lat/lng, below) pointed at the real
  /// location. Null for bookings made before the backend captured this.
  final String? addressLine;
  final DateTime? createdAt;
  /// Free text the customer actually typed on the address step of their
  /// booking — null when they left it blank, never a fabricated fallback.
  final String? directions;
  /// Last status-transition time — for a Completed booking, this is when it
  /// was actually finished, which the earnings screen uses to bucket a job
  /// into "today"/"this week" rather than its (possibly much earlier)
  /// creation time.
  final DateTime? updatedAt;
  final double? lat;
  final double? lng;

  /// Set only when this booking was cancelled by the customer — the real
  /// fee credited to this technician for time already committed, from
  /// app.py's CANCELLATION_FEE_BY_STATUS. 0 if the customer cancelled
  /// before any technician engagement, null if not cancelled at all.
  final int? cancellationFeePaise;

  /// Free text the customer typed on the Issue screen ("Anything else?") —
  /// null when they left it blank. See JobDetail.reportedQuote.
  final String? notes;

  /// Which symptom checkboxes the customer actually ticked on the Issue
  /// screen — empty when they reported nothing, never a fabricated
  /// symptom list. See JobDetail.reportedTags.
  final List<String> issues;

  /// The customer's own Firebase-verified phone number, when known — lets
  /// the job screen's "Call" action dial a real number instead of a fake
  /// "Calling — masked" toast. Null for bookings made before the backend
  /// captured this, or a customer who never verified a phone.
  final String? customerPhone;

  /// How the customer actually paid, once the technician records it on the
  /// close-job screen — null until then. One of upi/card/cash/link.
  final String? paymentMethod;

  /// Pay-now / pay-after-service state and the amount still to collect.
  final PaymentSummaryDto payment;

  /// Whether a before/after photo or the customer's signature has already
  /// been uploaded via `PATCH /api/bookings/<id>/photo` (or `/signature`)
  /// — advance (moving to Completed) fails server-side until all three are true, so
  /// the Jobs screen uses these to show real progress instead of trusting
  /// its own local capture state (which a killed/reinstalled app would lose).
  final bool beforePhotoReady;
  final bool afterPhotoReady;
  final bool signatureReady;

  /// The appliance's real brand/model, set by the technician once they're
  /// actually looking at it on-site — see app.py's PATCH .../appliance.
  /// Null until a technician sets it.
  final String? brand;
  final String? modelNumber;

  /// Real part/extra-work quotes raised for this job — see PartQuoteDto.
  final List<PartQuoteDto> parts;

  /// Real record of the technician swapping this booking's service for a
  /// different one — [] when it's never happened. See ServiceChangeDto.
  final List<ServiceChangeDto> serviceChanges;

  factory BookingDto.fromJson(Map<String, dynamic> json) {
    // total_amount arrives in rupees (see app.py) — this app stores money in
    // paise everywhere, so convert at the edge.
    final totalAmount = json['total_amount'] ?? json['price'] ?? 0;
    final rupees = (totalAmount is num) ? totalAmount : num.tryParse('$totalAmount') ?? 0;
    return BookingDto(
      id: '${json['id']}',
      category: (json['category'] as String?) ?? '',
      service: (json['service'] as String?)?.trim().isNotEmpty == true
          ? json['service'] as String
          : 'Service visit',
      status: (json['status'] as String?) ?? 'Requested',
      customerName: (json['customerName'] as String?)?.trim().isNotEmpty == true
          ? json['customerName'] as String
          : 'Customer',
      totalAmountPaise: (rupees * 100).round(),
      area: json['area'] as String?,
      addressLine: (json['addressLine'] as String?)?.trim().isNotEmpty == true
          ? json['addressLine'] as String
          : null,
      createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}'),
      updatedAt: DateTime.tryParse('${json['updatedAt'] ?? ''}'),
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
      cancellationFeePaise: (json['cancellationFee'] as num?) == null
          ? null
          : (json['cancellationFee'] as num).round() * 100,
      directions: (json['directions'] as String?)?.trim().isNotEmpty == true
          ? json['directions'] as String
          : null,
      notes: (json['notes'] as String?)?.trim().isNotEmpty == true
          ? json['notes'] as String
          : null,
      issues: (json['issues'] as List?)?.whereType<String>().toList(growable: false) ??
          const [],
      customerPhone: (json['customerPhone'] as String?)?.trim().isNotEmpty == true
          ? json['customerPhone'] as String
          : null,
      paymentMethod: json['paymentMethod'] as String?,
      payment: PaymentSummaryDto.fromJson(json['payment']),
      beforePhotoReady: json['beforePhotoReady'] == true,
      afterPhotoReady: json['afterPhotoReady'] == true,
      signatureReady: json['signatureReady'] == true,
      brand: (json['brand'] as String?)?.trim().isNotEmpty == true
          ? json['brand'] as String
          : null,
      modelNumber: (json['modelNumber'] as String?)?.trim().isNotEmpty == true
          ? json['modelNumber'] as String
          : null,
      parts: (json['parts'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(PartQuoteDto.fromJson)
              .toList(growable: false) ??
          const [],
      serviceChanges: (json['serviceChanges'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ServiceChangeDto.fromJson)
              .toList(growable: false) ??
          const [],
    );
  }

  BookingDto copyWith({
    String? service,
    int? totalAmountPaise,
    String? status,
    String? paymentMethod,
    PaymentSummaryDto? payment,
    bool? beforePhotoReady,
    bool? afterPhotoReady,
    bool? signatureReady,
    String? brand,
    String? modelNumber,
    List<PartQuoteDto>? parts,
    List<ServiceChangeDto>? serviceChanges,
  }) =>
      BookingDto(
        id: id,
        category: category,
        service: service ?? this.service,
        status: status ?? this.status,
        customerName: customerName,
        totalAmountPaise: totalAmountPaise ?? this.totalAmountPaise,
        area: area,
        addressLine: addressLine,
        createdAt: createdAt,
        updatedAt: updatedAt,
        lat: lat,
        lng: lng,
        cancellationFeePaise: cancellationFeePaise,
        directions: directions,
        notes: notes,
        issues: issues,
        customerPhone: customerPhone,
        paymentMethod: paymentMethod ?? this.paymentMethod,
        payment: payment ?? this.payment,
        beforePhotoReady: beforePhotoReady ?? this.beforePhotoReady,
        afterPhotoReady: afterPhotoReady ?? this.afterPhotoReady,
        signatureReady: signatureReady ?? this.signatureReady,
        brand: brand ?? this.brand,
        modelNumber: modelNumber ?? this.modelNumber,
        parts: parts ?? this.parts,
        serviceChanges: serviceChanges ?? this.serviceChanges,
      );
}

/// Fixed status progression the backend enforces — mirrors `STATUS_ORDER` in
/// app.py. `/advance` always moves a booking exactly one step forward.
const List<String> kBookingStatusOrder = [
  'Requested',
  'Accepted',
  'On the way',
  'In Progress',
  'Completed',
];
