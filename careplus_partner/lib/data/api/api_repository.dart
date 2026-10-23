// Real-backend-backed [PartnerRepository].
//
// The interface stays 100% synchronous (see repository.dart's header
// comment), so this class keeps an in-memory cache of the last successful
// fetch and serves every synchronous getter off that cache. Network calls
// (`refreshBookings`, `refreshMe`, `advanceJob`, `setOnDuty`) are async and
// meant to be awaited by the UI layer, which then forces a rebuild so the
// screens re-read the now-updated cache — see
// lib/state/providers.dart's `jobsFeedTickProvider`.
//
// Anything the backend genuinely has no concept of at all (a parts/quote
// workflow, invoice line detail) stays empty rather than fabricating it —
// this never serves [MockPartnerRepository]'s canned data for a real,
// fetched booking.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../models.dart';
import '../repository.dart';
import 'api_config.dart';
import 'booking_dto.dart';
import 'earnings_dto.dart';

const _timeout = Duration(seconds: 8);

// Job photos and the customer's signature go up as base64 JSON bodies —
// hundreds of KB to a few MB, not the few-hundred-byte payloads every
// other call here sends. On top of the transfer itself taking longer,
// this backend runs on Render's free tier, which spins down after 15
// minutes idle — exactly the kind of gap a technician leaves between
// arriving on-site and actually taking the after photo — and can take
// well past 8 seconds to cold-start (see TechApplyScreen's bootstrap
// retry for the same issue on a much smaller request). Without more
// room here, a cold start reliably fails the upload and blames "check
// your connection" on a technician who did nothing wrong.
const _uploadTimeout = Duration(seconds: 30);

class ApiRepository implements PartnerRepository {
  ApiRepository({MockPartnerRepository? mock}) : _mock = mock ?? MockPartnerRepository();

  final MockPartnerRepository _mock;

  List<BookingDto> _bookings = const [];

  /// True once `/technician/bookings` has been fetched successfully at
  /// least once. Until then — backend not deployed, no network, still
  /// loading — [routeToday] serves Mock-shaped data so the feed is never
  /// just blank; after a real fetch, an empty result is trusted as
  /// genuinely empty (no more falling back to Mock).
  bool _bookingsFetched = false;

  /// Unclaimed requests currently broadcast to this technician — real
  /// Uber/Ola/Rapido-style dispatch: every verified, on-duty technician
  /// whose category/area matches sees the same booking here at once, and
  /// whoever taps Accept first (see [claimJob]) actually gets it. See
  /// [refreshAvailableBookings].
  List<BookingDto> _available = const [];
  bool _availableFetched = false;

  /// Null until the first successful `/technician/online` or
  /// `/technician/me` response — falls back to the mock's onDuty until then.
  bool? _online;

  /// Null until the first successful `/technician/me` response — falls
  /// back to the mock's rating/jobsCompletedTotal until then. See
  /// [refreshMe].
  double? _rating;
  int? _jobsCompletedTotal;

  /// Null until the first successful [fetchEarnings] — [techStats] uses
  /// this real, commission-based figure for "today's earnings" instead of
  /// the customer's full invoice total (see the doc comment on
  /// earnings_dto.dart's EarningsJob for why those two numbers differ).
  TechEarningsSummary? _earningsSummary;

  // ---------------------------------------------------------------- auth

  Future<String?> _idToken() async {
    if (Firebase.apps.isEmpty) return null; // mock/unconfigured — no token to send
    try {
      return await FirebaseAuth.instance.currentUser?.getIdToken();
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------- fetching

  /// Refreshes this technician's assigned bookings from the real backend.
  /// Silently keeps the previous cache (or the empty list) on any failure —
  /// backend not deployed yet, timeout, network error, unauthenticated.
  Future<void> refreshBookings() async {
    try {
      final token = await _idToken();
      if (token == null) return;
      final res = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/api/technician/bookings'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body);
      if (data is! List) return;
      _bookings = data
          .whereType<Map<String, dynamic>>()
          .map(BookingDto.fromJson)
          .toList(growable: false);
      _bookingsFetched = true;
    } catch (_) {
      // Backend unreachable or not deployed yet — keep whatever we had.
    }
  }

  /// Refreshes the broadcast feed of unclaimed requests this technician is
  /// currently eligible for, via `GET /api/technician/bookings/available`.
  /// Best-effort, same failure handling as [refreshBookings] — keeps
  /// whatever was already cached (or empty) rather than blanking the
  /// incoming-request card on a hiccup.
  Future<void> refreshAvailableBookings() async {
    try {
      final token = await _idToken();
      if (token == null) return;
      final res = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/api/technician/bookings/available'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body);
      if (data is! List) return;
      _available = data
          .whereType<Map<String, dynamic>>()
          .map(BookingDto.fromJson)
          .toList(growable: false);
      _availableFetched = true;
    } catch (_) {
      // Backend unreachable or not deployed yet — keep whatever we had.
    }
  }

  /// Refreshes on-duty state and this technician's real rating/completed-
  /// job total from `/api/technician/me`. Best-effort, same failure
  /// handling as [refreshBookings].
  Future<void> refreshMe() async {
    try {
      final token = await _idToken();
      if (token == null) return;
      final res = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/api/technician/me'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body);
      if (data is! Map<String, dynamic>) return;
      if (data['online'] is bool) _online = data['online'] as bool;
      // Previously discarded — the Jobs tab's "Rating" stat box kept
      // showing Mock's fixed 4.94 forever, even after this real value
      // loaded, while the Profile tab a few taps away showed the real
      // (and often different) one.
      if (data['rating'] is num) _rating = (data['rating'] as num).toDouble();
      if (data['jobsCompleted'] is num) {
        _jobsCompletedTotal = (data['jobsCompleted'] as num).toInt();
      }
    } catch (_) {
      // Ignored — techStats() falls back to the mock's figures.
    }
  }

  /// Fetches bookings, the incoming-request broadcast feed, and on-duty
  /// state together — call once after sign-in / whenever the job feed
  /// wants a fresh look at the server.
  Future<void> refreshAll() =>
      Future.wait([refreshBookings(), refreshAvailableBookings(), refreshMe(), fetchEarnings()]);

  // -------------------------------------------------------------- actions

  /// Moves [jobId] to its next status via the real backend (the server
  /// decides the target — this can't request an arbitrary one). Returns
  /// true if the call succeeded, in which case the local cache has already
  /// been advanced to match so the caller can rebuild immediately without
  /// waiting on another round trip.
  /// [startCode] is required by the backend for the "On the way" -> "In
  /// Progress" transition (the customer's 4-digit code, proving the
  /// technician is actually there) — see advance_booking in app.py. The
  /// error message on a 400 (wrong code, or missing photos/signature for
  /// the -> Completed transition) is the backend's own, so the technician
  /// sees exactly what's still needed rather than a generic failure toast.
  Future<({bool ok, String? error})> advanceJob(String jobId,
      {int? suctionBefore, int? suctionAfter, String? startCode}) async {
    try {
      final token = await _idToken();
      if (token == null) return (ok: false, error: null);
      final res = await http
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings/$jobId/advance'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              if (suctionBefore != null) 'suctionBefore': suctionBefore,
              if (suctionAfter != null) 'suctionAfter': suctionAfter,
              if (startCode != null) 'startCode': startCode,
            }),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        String? error;
        try {
          final body = jsonDecode(res.body);
          if (body is Map<String, dynamic>) error = body['message'] as String?;
        } catch (_) {
          // Non-JSON error body — fall through with no message.
        }
        return (ok: false, error: error);
      }
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic> && data['status'] is String) {
        _replaceBookingStatus(jobId, data['status'] as String);
      } else {
        _advanceBookingStatusLocally(jobId);
      }
      return (ok: true, error: null);
    } catch (_) {
      return (ok: false, error: null);
    }
  }

  /// Uploads a before/after photo as base64 via `PATCH /api/bookings/<id>/photo`
  /// — stored directly in the booking's row rather than Firebase
  /// Storage, so this never depends on a Storage bucket/rules setup.
  /// Updates the local cache's ready flag on success so the Jobs screen's
  /// gating reflects it immediately without waiting on a refetch.
  Future<bool> uploadJobPhoto(String jobId, {required bool isBefore, required File file}) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final bytes = await file.readAsBytes();
      final res = await http
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings/$jobId/photo'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'kind': isBefore ? 'before' : 'after',
              'dataBase64': base64Encode(bytes),
            }),
          )
          .timeout(_uploadTimeout);
      if (res.statusCode != 200) return false;
      final i = _bookings.indexWhere((b) => b.id == jobId);
      if (i != -1) {
        _bookings = [
          ..._bookings.sublist(0, i),
          isBefore
              ? _bookings[i].copyWith(beforePhotoReady: true)
              : _bookings[i].copyWith(afterPhotoReady: true),
          ..._bookings.sublist(i + 1),
        ];
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Asks the server for the live UPI QR for this completed job's exact
  /// outstanding invoice amount (`POST .../payment-qr`). The server prices
  /// it, creates the Razorpay QR and returns what to show — nothing here
  /// decides the amount or whether anything is paid.
  Future<PaymentStateDto> createInvoiceQr(String jobId) =>
      _paymentCall('POST', 'payment-qr', jobId);

  /// Re-checks payment (`GET .../payment`): the server asks Razorpay whether
  /// the QR was paid and answers with the verified state.
  Future<PaymentStateDto> refreshPayment(String jobId) =>
      _paymentCall('GET', 'payment', jobId);

  Future<PaymentStateDto> _paymentCall(String method, String path, String jobId) async {
    const generic = PaymentStateDto(error: "Couldn't reach the payment service. Please try again.");
    try {
      final token = await _idToken();
      if (token == null) return const PaymentStateDto(error: 'Please sign in again.');
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/technician/bookings/$jobId/$path');
      final headers = {'Authorization': 'Bearer $token'};
      final res = await (method == 'POST'
              ? http.post(uri, headers: headers)
              : http.get(uri, headers: headers))
          .timeout(_uploadTimeout);
      final body = jsonDecode(res.body);
      if (body is! Map<String, dynamic>) return generic;
      if (res.statusCode != 200 && res.statusCode != 201) {
        return PaymentStateDto(
          error: (body['error'] as String?) ?? generic.error,
          code: body['code'] as String?,
        );
      }
      final payment = PaymentSummaryDto.fromJson(body['payment']);
      final i = _bookings.indexWhere((b) => b.id == jobId);
      if (i != -1) {
        _bookings = [
          ..._bookings.sublist(0, i),
          _bookings[i].copyWith(
            payment: payment,
            paymentMethod: payment.isPaid ? 'upi' : null,
          ),
          ..._bookings.sublist(i + 1),
        ];
      }
      return PaymentStateDto(
        payment: payment,
        qr: InvoiceQrDto.tryParse(body['qr']),
        warning: body['warning'] as String?,
      );
    } catch (_) {
      return generic;
    }
  }

  /// The server-reported payment picture for [jobId] from the last fetch.
  PaymentSummaryDto paymentOf(String jobId) {
    final match = _bookings.where((b) => b.id == jobId);
    return match.isEmpty ? const PaymentSummaryDto() : match.first.payment;
  }

  /// Uploads the customer's captured signature (PNG bytes) via
  /// `PATCH /api/bookings/<id>/signature` — same reasoning as [uploadJobPhoto].
  Future<bool> uploadSignature(String jobId, Uint8List pngBytes) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final res = await http
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings/$jobId/signature'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'dataBase64': base64Encode(pngBytes)}),
          )
          .timeout(_uploadTimeout);
      if (res.statusCode != 200) return false;
      final i = _bookings.indexWhere((b) => b.id == jobId);
      if (i != -1) {
        _bookings = [
          ..._bookings.sublist(0, i),
          _bookings[i].copyWith(signatureReady: true),
          ..._bookings.sublist(i + 1),
        ];
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether [jobId]'s before/after photo and customer signature have
  /// already been uploaded — used to gate "Complete and invoice" so it
  /// can't be tapped only to fail against the backend's own check.
  bool beforePhotoReady(String jobId) {
    final match = _bookings.where((b) => b.id == jobId);
    return match.isEmpty ? false : match.first.beforePhotoReady;
  }

  bool afterPhotoReady(String jobId) {
    final match = _bookings.where((b) => b.id == jobId);
    return match.isEmpty ? false : match.first.afterPhotoReady;
  }

  bool signatureReady(String jobId) {
    final match = _bookings.where((b) => b.id == jobId);
    return match.isEmpty ? false : match.first.signatureReady;
  }

  /// Sets on-duty state via `/api/technician/online`. Returns true on
  /// success (and updates the local cache to match); false on any failure,
  /// in which case the UI should not optimistically flip the toggle.
  Future<bool> setOnDuty(bool value) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final res = await http
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/technician/online'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'online': value}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      _online = value;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Accepts a broadcast request via `PATCH /api/bookings/<id>/claim` —
  /// real Uber/Ola/Rapido-style dispatch: several technicians can see the
  /// same unclaimed request at once (see [refreshAvailableBookings]), and
  /// only the first to actually call this wins it — the backend's own
  /// atomic UPDATE is the race guard, not anything client-side. `error`
  /// carries the backend's own message on a 409 (someone else already
  /// claimed it, or it's no longer open) so the screen can say exactly
  /// what happened instead of a generic failure. Either way the request
  /// is no longer open, so it's dropped from the local available-list so
  /// a stale copy doesn't keep showing as tappable.
  Future<({bool ok, String? error})> claimJob(String jobId) async {
    try {
      final token = await _idToken();
      if (token == null) return (ok: false, error: null);
      final res = await http
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings/$jobId/claim'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      _available = _available.where((b) => b.id != jobId).toList(growable: false);
      if (res.statusCode != 200) {
        String? error;
        try {
          final body = jsonDecode(res.body);
          if (body is Map<String, dynamic>) error = body['message'] as String?;
        } catch (_) {
          // Non-JSON error body — fall through with no message.
        }
        return (ok: false, error: error);
      }
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) {
        _bookings = [BookingDto.fromJson(decoded), ..._bookings.where((b) => b.id != jobId)];
      }
      return (ok: true, error: null);
    } catch (_) {
      return (ok: false, error: null);
    }
  }

  /// Backs out of [jobId] after already accepting it, before actually
  /// heading over, via `PATCH /api/bookings/<id>/decline` — puts it back
  /// in the broadcast pool (real Uber/Ola/Rapido-style: any other
  /// eligible technician can claim it next) instead of the old single-
  /// reassign-to-one-other-technician chain a hard-assigned dispatch
  /// model needed. Returns true on success, dropping the job from this
  /// technician's own cache since it's no longer theirs; false on
  /// failure (wrong state, or a real network error), leaving the local
  /// cache untouched.
  Future<bool> unclaimJob(String jobId) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final res = await http
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings/$jobId/decline'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      _bookings = _bookings.where((b) => b.id != jobId).toList(growable: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Records how the customer actually paid via `/api/bookings/<id>/payment`
  /// — [method] is one of upi/card/cash/link. Previously the close-job
  /// screen's "Mark paid" button called nothing at all; the booking was
  /// already Completed by the prior advance-to-Completed call, so this had
  /// zero effect beyond a SnackBar. Returns whether the call succeeded.
  Future<bool> setPaymentMethod(String jobId, String method) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final res = await http
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings/$jobId/payment'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'paymentMethod': method}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      final i = _bookings.indexWhere((b) => b.id == jobId);
      if (i != -1) {
        final next = [..._bookings];
        next[i] = next[i].copyWith(paymentMethod: method);
        _bookings = next;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _replaceBookingStatus(String jobId, String status) {
    final i = _bookings.indexWhere((b) => b.id == jobId);
    if (i == -1) return;
    final next = [..._bookings];
    next[i] = next[i].copyWith(status: status);
    _bookings = next;
  }

  void _advanceBookingStatusLocally(String jobId) {
    final i = _bookings.indexWhere((b) => b.id == jobId);
    if (i == -1) return;
    final order = kBookingStatusOrder.indexOf(_bookings[i].status);
    if (order == -1 || order >= kBookingStatusOrder.length - 1) return;
    _replaceBookingStatus(jobId, kBookingStatusOrder[order + 1]);
  }

  // ------------------------------------------------------- PartnerRepository

  @override
  TechStats techStats() {
    final mock = _mock.techStats();
    final online = _online;
    final rating = _rating ?? mock.rating;
    final jobsCompletedTotal = _jobsCompletedTotal ?? mock.jobsCompletedTotal;
    if (!_bookingsFetched) {
      return online == null && _rating == null && _jobsCompletedTotal == null
          ? mock
          : _withRealFields(mock, online, rating, jobsCompletedTotal);
    }
    final today = DateTime.now();
    bool isToday(DateTime? dt) =>
        dt != null && dt.year == today.year && dt.month == today.month && dt.day == today.day;
    final completedToday =
        _bookings.where((b) => b.status == 'Completed' && isToday(b.updatedAt));
    final touchedToday = _bookings.where((b) => isToday(b.createdAt) || isToday(b.updatedAt));
    // The technician's real, commission-based pay for jobs completed today
    // — never the customer's full invoice total, which is only ever a
    // fraction of what's actually earned (see compute_commission_paise in
    // app.py). Falls back to the invoice-total sum only until the first
    // real earnings fetch lands, so the dashboard isn't blank before that.
    final earningsSummary = _earningsSummary;
    final earningsTodayPaise = earningsSummary != null
        ? earningsSummary.jobs
            .where((j) => isToday(j.completedAt))
            .fold<int>(0, (sum, j) => sum + j.commissionPaise)
        : completedToday.fold<int>(0, (sum, b) => sum + b.totalAmountPaise);
    return TechStats(
      earningsTodayPaise: earningsTodayPaise,
      jobsDone: completedToday.length,
      // touchedToday is a superset of completedToday by construction
      // (completed-today implies updated-today), so this is always >= jobsDone.
      jobsTotal: touchedToday.length,
      rating: rating,
      jobsCompletedTotal: jobsCompletedTotal,
      onDuty: online ?? mock.onDuty,
    );
  }

  TechStats _withRealFields(TechStats s, bool? onDuty, double rating, int jobsCompletedTotal) =>
      TechStats(
        earningsTodayPaise: s.earningsTodayPaise,
        jobsDone: s.jobsDone,
        jobsTotal: s.jobsTotal,
        rating: rating,
        jobsCompletedTotal: jobsCompletedTotal,
        onDuty: onDuty ?? s.onDuty,
      );

  /// Every completed booking, most recent first — the real data behind the
  /// earnings/reports screen. Empty (not Mock) once bookings have actually
  /// been fetched, same "don't fabricate" rule as [hasActiveJob].
  List<BookingDto> completedBookings() {
    final list = _bookings.where((b) => b.status == 'Completed').toList();
    list.sort((a, b) => (b.updatedAt ?? b.createdAt ?? DateTime(0))
        .compareTo(a.updatedAt ?? a.createdAt ?? DateTime(0)));
    return list;
  }

  /// Jobs a customer cancelled after this technician had already committed
  /// time — the ones that actually carry a real cancellation fee (see
  /// app.py's CANCELLATION_FEE_BY_STATUS). A cancellation before any
  /// engagement carries a fee of 0 and is filtered out here; there's
  /// nothing to compensate for.
  List<BookingDto> cancellationFeeBookings() {
    final list = _bookings
        .where((b) => b.status == 'Cancelled' && (b.cancellationFeePaise ?? 0) > 0)
        .toList();
    list.sort((a, b) => (b.updatedAt ?? b.createdAt ?? DateTime(0))
        .compareTo(a.updatedAt ?? a.createdAt ?? DateTime(0)));
    return list;
  }

  bool get bookingsFetched => _bookingsFetched;

  /// Real, itemized earnings for the signed-in technician — see
  /// app.py's /api/technician/earnings. Null on any failure (network,
  /// unauthenticated); the caller shows a loading/error state rather than
  /// falling back to a fabricated total. Caches the result on success (see
  /// [_earningsSummary]) so [techStats] can use it too — refreshAll calls
  /// this alongside the booking fetches specifically so the dashboard has
  /// it without the technician needing to first open the Earnings tab.
  Future<TechEarningsSummary?> fetchEarnings() async {
    try {
      final token = await _idToken();
      if (token == null) return null;
      final res = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/api/technician/earnings'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is! Map<String, dynamic>) return null;
      final summary = TechEarningsSummary.fromJson(data);
      _earningsSummary = summary;
      return summary;
    } catch (_) {
      return null;
    }
  }

  @override
  JobRequest? incomingRequest() {
    if (!_availableFetched) return _mock.incomingRequest();
    if (_available.isEmpty) return null;
    final b = _available.first; // oldest first — see refreshAvailableBookings
    double? distanceKm;
    if (_myLat != null && _myLng != null && b.lat != null && b.lng != null) {
      distanceKm = Geolocator.distanceBetween(_myLat!, _myLng!, b.lat!, b.lng!) / 1000;
    }
    return JobRequest(
      jobId: b.id,
      serviceTitle: b.service,
      // The customer's real area, from their booking — previously a
      // hardcoded "Gangapur Road" shown for every request regardless of
      // which of this app's supported cities it was actually in.
      areaLabel: (b.area?.trim().isNotEmpty ?? false) ? b.area! : '',
      distanceKm: distanceKm,
      timeWindow: _timeWindow(b.createdAt),
      payoutPaise: b.totalAmountPaise,
      note: '',
    );
  }

  /// Caches this technician's last known position so [incomingRequest] can
  /// compute a real straight-line distance to a job — called by
  /// TechJobsScreen once after a best-effort Geolocator fix. Never queried
  /// itself (no permission prompts live in this repository layer); a
  /// missing position just means [incomingRequest] leaves distance null
  /// instead of ever fabricating one.
  void setMyPosition(double lat, double lng) {
    _myLat = lat;
    _myLng = lng;
  }

  double? _myLat;
  double? _myLng;

  @override
  List<RouteStop> routeToday() {
    if (!_bookingsFetched) return _mock.routeToday();
    return _bookings
        .where((b) => b.status == 'Accepted' || b.status == 'On the way' || b.status == 'In Progress')
        .map((b) => RouteStop(
              jobId: b.id,
              time: _clockTime(b.createdAt),
              title: b.service,
              customerName: b.customerName,
              meta: b.area ?? '',
              status: b.status == 'Accepted' ? StopStatus.next : StopStatus.inProgress,
            ))
        .toList(growable: false);
  }

  @override
  JobDetail jobDetail(String jobId) {
    final match = _bookings.where((b) => b.id == jobId);
    final base = _mock.jobDetail(jobId);
    if (match.isEmpty) return base;
    final b = match.first;
    return JobDetail(
      jobId: base.jobId,
      customerName: b.customerName,
      customerInitials: _initials(b.customerName),
      // The real street address, when the customer's app sent one —
      // `area` alone is just a short label ("Home"/"Office") and isn't
      // enough to find the door, so it's only the fallback here.
      addressLine: b.addressLine ??
          ((b.area?.trim().isNotEmpty ?? false) ? b.area! : base.addressLine),
      // The customer's own real "directions for the technician" text —
      // previously this always showed the mock job's fabricated "Gate code
      // 4402, lift on the left" for every real booking too, regardless of
      // what the customer actually typed (or didn't).
      directions: b.directions ?? 'No directions given by the customer.',
      // The customer's own real reported symptoms/notes — previously this
      // always showed the mock job's fabricated "Weak suction, rattling
      // noise..." for every real booking regardless of appliance or what
      // was actually reported (or nothing at all).
      reportedTags: b.issues,
      reportedQuote: b.notes ?? '',
      // Real parts/extra-work quotes this technician has actually raised —
      // see addPart/removePart below. Never the mock's fabricated
      // pre-approved "Baffle filter — Elica 90cm".
      parts: b.parts
          .map((p) => PartLine(
                id: p.id,
                name: p.name,
                sku: p.sku,
                qty: p.qty,
                pricePaise: p.pricePaise,
                status: partStatusFrom(p.status),
                decidedAt: p.decidedAt,
              ))
          .toList(growable: false),
      lat: b.lat,
      lng: b.lng,
      customerPhone: b.customerPhone,
      brand: b.brand,
      modelNumber: b.modelNumber,
      category: b.category,
      service: b.service,
      totalAmountPaise: b.totalAmountPaise,
      serviceChanges: b.serviceChanges
          .map((c) => ServiceChangeLine(
                id: c.id,
                oldService: c.oldService,
                newService: c.newService,
                oldPricePaise: c.oldPricePaise,
                newPricePaise: c.newPricePaise,
                createdAt: c.createdAt?.toIso8601String(),
              ))
          .toList(growable: false),
    );
  }

  /// Real jobs get the service's actual booked total_amount, straight from
  /// the last `/technician/bookings` fetch, plus one line per part the
  /// customer has actually approved — there's still no real payment gateway
  /// or coupon/GST backend behind this app, so nothing invented is added on
  /// top. Falls back to the mock invoice only for a job this technician
  /// doesn't have in their real, fetched bookings (a mock/demo job).
  @override
  List<InvoiceLine> closeInvoice(String jobId) {
    final match = _bookings.where((b) => b.id == jobId);
    if (match.isEmpty) return _mock.closeInvoice(jobId);
    final booking = match.first;
    return [
      InvoiceLine(booking.service, booking.totalAmountPaise),
      for (final p in booking.parts)
        if (p.status == 'approved')
          InvoiceLine(p.name, p.pricePaise * p.qty, tone: LineTone.success),
    ];
  }

  /// The live status string for [jobId] if it's a known real booking from
  /// the last successful `/technician/bookings` fetch, else null (a mock
  /// job, or a real job not yet fetched). Used by the job screen to decide
  /// which status-advance action to offer next.
  String? statusOf(String jobId) {
    final match = _bookings.where((b) => b.id == jobId);
    return match.isEmpty ? null : match.first.status;
  }

  /// The appliance category code (e.g. 'RasoiAir' for chimneys) for [jobId]
  /// if it's a known real booking, else null — used to offer the airflow
  /// (CFM) reading screen only for chimney jobs.
  String? categoryOf(String jobId) {
    final match = _bookings.where((b) => b.id == jobId);
    return match.isEmpty ? null : match.first.category;
  }

  /// Sets the appliance's real brand/model once the technician is actually
  /// on-site looking at it — see app.py's PATCH .../appliance. Either
  /// argument can be omitted to leave that field untouched; passing an
  /// empty string clears it. Returns whether the call succeeded.
  Future<bool> updateApplianceInfo(String jobId, {String? brand, String? modelNumber}) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final res = await http
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/technician/bookings/$jobId/appliance'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              if (brand != null) 'brand': brand,
              if (modelNumber != null) 'modelNumber': modelNumber,
            }),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      final i = _bookings.indexWhere((b) => b.id == jobId);
      if (i != -1) {
        _bookings = [
          ..._bookings.sublist(0, i),
          _bookings[i].copyWith(brand: brand, modelNumber: modelNumber),
          ..._bookings.sublist(i + 1),
        ];
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Real, catalog-priced options a technician can switch this booking's
  /// service to — always scoped to the booking's own category (see
  /// ServiceOptionDto). GET /api/services is public, no auth needed. Empty
  /// list on any failure — the UI just shows nothing to pick, never a
  /// fabricated option.
  Future<List<ServiceOptionDto>> fetchServiceOptions(String category) async {
    try {
      final res = await http
          .get(Uri.parse(
              '${ApiConfig.baseUrl}/api/services?category=${Uri.encodeQueryComponent(category)}'))
          .timeout(_timeout);
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(res.body);
      if (data is! List) return const [];
      return data
          .whereType<Map<String, dynamic>>()
          .map(ServiceOptionDto.fromJson)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Swaps this booking's service for a different one in the same
  /// category — e.g. the customer asks mid-visit to upgrade a filter clean
  /// into a full deep clean. See app.py's PATCH .../service, which
  /// recomputes price/total_amount from the real catalog and logs the
  /// change so the customer's invoice shows exactly what changed. Updates
  /// the cached booking's service/total/serviceChanges from the real
  /// response on success.
  Future<({bool ok, String? error})> changeService(String jobId, String serviceId) async {
    try {
      final token = await _idToken();
      if (token == null) return (ok: false, error: null);
      final res = await http
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/technician/bookings/$jobId/service'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'serviceId': serviceId}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        // Relay the backend's real reason (e.g. "Can't change the service
        // on a completed or cancelled job.") instead of the client always
        // guessing "check your connection" — this is almost never actually
        // a network failure, it's a real business-rule rejection the
        // technician needs to understand, not retry.
        String? error;
        try {
          final body = jsonDecode(res.body);
          if (body is Map<String, dynamic>) error = body['message'] as String?;
        } catch (_) {
          // Non-JSON error body — fall through with no message.
        }
        return (ok: false, error: error);
      }
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic>) {
        final updated = BookingDto.fromJson(data);
        final i = _bookings.indexWhere((b) => b.id == jobId);
        if (i != -1) {
          _bookings = [
            ..._bookings.sublist(0, i),
            _bookings[i].copyWith(
              service: updated.service,
              totalAmountPaise: updated.totalAmountPaise,
              serviceChanges: updated.serviceChanges,
            ),
            ..._bookings.sublist(i + 1),
          ];
        }
      }
      return (ok: true, error: null);
    } catch (_) {
      return (ok: false, error: null);
    }
  }

  /// Raises a real part/extra-work quote for the customer to approve or
  /// reject — see app.py's POST .../parts. On success the newly created
  /// part (with its real backend id) is appended to the cached booking so
  /// the Parts & quotes section reflects it immediately, no refetch needed.
  Future<bool> addPart(String jobId,
      {required String name, String? sku, required int qty, required int pricePaise}) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final res = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/technician/bookings/$jobId/parts'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'name': name,
              if (sku != null && sku.trim().isNotEmpty) 'sku': sku,
              'qty': qty,
              'pricePaise': pricePaise,
            }),
          )
          .timeout(_timeout);
      if (res.statusCode != 201) return false;
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic>) {
        final part = PartQuoteDto.fromJson(data);
        final i = _bookings.indexWhere((b) => b.id == jobId);
        if (i != -1) {
          _bookings = [
            ..._bookings.sublist(0, i),
            _bookings[i].copyWith(parts: [..._bookings[i].parts, part]),
            ..._bookings.sublist(i + 1),
          ];
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Retracts a part quote this technician raised by mistake — the backend
  /// only allows this while the customer hasn't decided on it yet.
  Future<bool> removePart(String jobId, String partId) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final res = await http
          .delete(
            Uri.parse('${ApiConfig.baseUrl}/api/technician/bookings/$jobId/parts/$partId'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      final i = _bookings.indexWhere((b) => b.id == jobId);
      if (i != -1) {
        _bookings = [
          ..._bookings.sublist(0, i),
          _bookings[i].copyWith(
              parts: _bookings[i].parts.where((p) => p.id != partId).toList(growable: false)),
          ..._bookings.sublist(i + 1),
        ];
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True if any of this technician's real bookings from the last
  /// `/technician/bookings` fetch is assigned and not yet completed
  /// (`Accepted`, `On the way`, or `In Progress`). Used to gate live GPS
  /// reporting — see `technician_location_reporter.dart`. Unlike
  /// [routeToday], this deliberately does NOT fall back to Mock data before
  /// the first fetch: reporting should only ever start for a real job.
  bool hasActiveJob() => _bookings.any((b) =>
      b.status == 'Accepted' || b.status == 'On the way' || b.status == 'In Progress');

  // ------------------------------------------------------------- helpers

  String _clockTime(DateTime? dt) {
    if (dt == null) return 'Today';
    try {
      return DateFormat('h:mm a').format(dt.toLocal());
    } catch (_) {
      return 'Today';
    }
  }

  String _timeWindow(DateTime? dt) {
    if (dt == null) return 'Today';
    try {
      final local = dt.toLocal();
      final start = DateFormat('h:mm a').format(local);
      final end = DateFormat('h:mm a').format(local.add(const Duration(hours: 1)));
      return '$start–$end';
    } catch (_) {
      return 'Today';
    }
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}

