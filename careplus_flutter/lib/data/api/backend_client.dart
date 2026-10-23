// Thin HTTP client for the shared Flask+SQLite backend. Every method here is
// best-effort: wrapped in try/catch with a timeout, so a network failure
// (backend not deployed yet, offline device, slow connection) never throws
// past this class — callers get null/[] back and fall back to whatever
// MockRepository already provides. Mirrors the same never-block-a-flow
// philosophy as UserProfileService's Firestore writes
// (lib/data/firebase/firestore_user_profile_service.dart).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_config.dart';

class BackendClient {
  static const _timeout = Duration(seconds: 8);
  // Checkout writes data and the free-tier API can take ~30s to wake from a
  // cold start, so it gets longer than the read calls; the Idempotency-Key
  // makes a retry after a timeout safe.
  static const _checkoutTimeout = Duration(seconds: 45);

  Map<String, String> _headers(String idToken) => {
        'Authorization': 'Bearer $idToken',
        'Content-Type': 'application/json',
      };

  /// Asks the server to re-check a booking's payment (`GET /api/bookings/<id>/payment`).
  Future<bool> checkBookingPayment({
    required String idToken,
    required String bookingId,
  }) async {
    try {
      final res = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings/${Uri.encodeComponent(bookingId)}/payment'),
            headers: _headers(idToken),
          )
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Creates a server-priced Razorpay order. The secret key is never sent to
  /// the app; only the public key id and Razorpay order id are returned.
  Future<({Map<String, dynamic>? order, String? error, bool unauthorized})>
      createRazorpayOrder({
    required String idToken,
    required List<String> serviceIds,
    required Map<String, dynamic> booking,
    required List<Map<String, dynamic>> shopItems,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/payments/razorpay/order'),
            headers: _headers(idToken),
            body: jsonEncode({
              'serviceIds': serviceIds,
              'useCoins': false,
              'booking': booking,
              'shopItems': shopItems,
            }),
          )
          .timeout(_checkoutTimeout);
      final decoded = jsonDecode(res.body);
      if (res.statusCode == 201 && decoded is Map<String, dynamic>) {
        return (order: decoded, error: null, unauthorized: false);
      }
      return (
        order: null,
        error: decoded is Map<String, dynamic> && decoded['error'] is String
            ? decoded['error'] as String
            : 'Could not start secure payment.',
        unauthorized: res.statusCode == 401,
      );
    } catch (_) {
      return (
        order: null,
        error: 'Could not reach the payment server. Please try again.',
        unauthorized: false
      );
    }
  }

  /// Server verifies the Razorpay signature and captured amount before
  /// creating bookings or shop orders.
  Future<({Map<String, dynamic>? result, String? error, bool unauthorized})>
      verifyRazorpayPayment({
    required String idToken,
    required String orderId,
    required String paymentId,
    required String signature,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/payments/razorpay/verify'),
            headers: _headers(idToken),
            body: jsonEncode({
              'orderId': orderId,
              'paymentId': paymentId,
              'signature': signature,
            }),
          )
          .timeout(_checkoutTimeout);
      final decoded = jsonDecode(res.body);
      if (res.statusCode == 200 && decoded is Map<String, dynamic>) {
        return (result: decoded, error: null, unauthorized: false);
      }
      return (
        result: null,
        error: decoded is Map<String, dynamic> && decoded['error'] is String
            ? decoded['error'] as String
            : 'Payment could not be confirmed. Keep this screen open and retry.',
        unauthorized: res.statusCode == 401,
      );
    } catch (_) {
      return (
        result: null,
        error:
            'Payment confirmation is taking longer than expected. Please retry verification.',
        unauthorized: false
      );
    }
  }

  /// POST /api/me/bootstrap — called once right after Firebase sign-in so
  /// the backend has a matching `users` row; also reused by AccountScreen
  /// to set a phone number after the fact (the endpoint's own UPDATE is an
  /// upsert-if-non-null, see app.py), passing the current name through so
  /// that call doesn't revert it to the Firebase-claims default. Returns
  /// whether the backend actually accepted it — the fire-and-forget
  /// post-sign-in call ignores this, but the phone-number path needs to
  /// tell the person it worked.
  Future<bool> bootstrap({
    required String idToken,
    required String name,
    String? phone,
    Duration timeout = _timeout,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/me/bootstrap'),
            headers: _headers(idToken),
            body: jsonEncode({
              'name': name,
              if (phone != null && phone.isNotEmpty) 'phone': phone,
            }),
          )
          .timeout(timeout);
      return res.statusCode == 200;
    } catch (_) {
      // Best-effort — see file header.
      return false;
    }
  }

  /// POST /api/bookings using the legacy category/service/price shape.
  /// Returns the decoded booking JSON on a 201. On any failure, `booking`
  /// is null and `error` carries the reason: the backend's own message for
  /// an unsuccessful-but-reachable request (e.g. app.py's 503 "No
  /// technician is available for this service yet" once the demo
  /// technicians were removed), or a generic one for a real network
  /// failure (offline, timeout) — so the caller can show the customer what
  /// actually went wrong instead of always blaming their connection.
  Future<({Map<String, dynamic>? booking, String? error, bool unauthorized})>
      createBooking({
    required String idToken,
    required String category,
    required String service,
    required int price,
    String? area,
    String? addressLine,
    double? lat,
    double? lng,
    String? directions,
    String? notes,
    List<String>? issues,
    DateTime? scheduledAt,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings'),
            headers: _headers(idToken),
            body: jsonEncode({
              'category': category,
              'service': service,
              'price': price,
              if (area != null && area.isNotEmpty) 'area': area,
              // The real street address behind that short label — a
              // technician's job screen otherwise has nothing but "Home" to
              // go on even though the map pin (lat/lng, below) points at
              // the right spot.
              if (addressLine != null && addressLine.isNotEmpty)
                'addressLine': addressLine,
              if (lat != null) 'lat': lat,
              if (lng != null) 'lng': lng,
              if (directions != null && directions.isNotEmpty)
                'directions': directions,
              if (notes != null && notes.isNotEmpty) 'notes': notes,
              if (issues != null && issues.isNotEmpty) 'issues': issues,
              // .toUtc() first — a bare local-time ISO string (no offset)
              // would otherwise be silently misread as UTC server-side,
              // shifting the real cancellation-policy deadline by however
              // far local time is from UTC.
              if (scheduledAt != null)
                'scheduledAt': scheduledAt.toUtc().toIso8601String(),
            }),
          )
          .timeout(_timeout);
      final decoded = jsonDecode(res.body);
      if (res.statusCode == 201 && decoded is Map<String, dynamic>) {
        return (booking: decoded, error: null, unauthorized: false);
      }
      if (res.statusCode == 401) {
        // require_auth's own 401s use {"error": "Unauthorized", "message":
        // "<real reason>"} — "error" here is just a coarse category label,
        // not something worth showing a customer. This is almost always a
        // stale ID token, so `unauthorized: true` tells ApiRepository to
        // retry once with a forced token refresh before ever surfacing
        // this to the UI as a final failure.
        return (
          booking: null,
          error: 'Your session needs refreshing — please try again.',
          unauthorized: true,
        );
      }
      // Business-logic rejections (e.g. the 503 "no technician available")
      // put the full human-readable reason directly in "error".
      final message =
          decoded is Map<String, dynamic> ? decoded['error'] as String? : null;
      return (
        booking: null,
        error:
            message ?? 'The server rejected this booking (${res.statusCode}).',
        unauthorized: false,
      );
    } catch (_) {
      return (
        booking: null,
        error: null,
        unauthorized: false
      ); // real network failure — see file header
    }
  }

  /// POST /api/bookings/cart — the real checkout call, replacing a client-
  /// computed total with one or more real catalog `serviceId`s. The
  /// backend looks up each service's real price and computes the visit
  /// fee/coupon/GST/coins math itself, so the returned bookings' prices
  /// are always the authoritative ones — never trust a locally-computed
  /// figure once this call returns. Same never-throw/best-effort shape as
  /// createBooking above.
  Future<
      ({
        List<Map<String, dynamic>>? bookings,
        Map<String, dynamic>? pricing,
        String? error,
        bool unauthorized
      })> createBookingCart({
    required String idToken,
    required List<String> serviceIds,
    required bool useCoins,
    String? area,
    String? addressLine,
    double? lat,
    double? lng,
    String? directions,
    String? notes,
    List<String>? issues,
    DateTime? scheduledAt,
    String? idempotencyKey,
    String? paymentMode,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings/cart'),
            headers: {
              ..._headers(idToken),
              if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
            },
            body: jsonEncode({
              'serviceIds': serviceIds,
              'useCoins': useCoins,
              if (paymentMode != null) 'paymentMode': paymentMode,
              if (area != null && area.isNotEmpty) 'area': area,
              if (addressLine != null && addressLine.isNotEmpty)
                'addressLine': addressLine,
              if (lat != null) 'lat': lat,
              if (lng != null) 'lng': lng,
              if (directions != null && directions.isNotEmpty)
                'directions': directions,
              if (notes != null && notes.isNotEmpty) 'notes': notes,
              if (issues != null && issues.isNotEmpty) 'issues': issues,
              if (scheduledAt != null)
                'scheduledAt': scheduledAt.toUtc().toIso8601String(),
            }),
          )
          .timeout(_checkoutTimeout);
      Object? decoded;
      try {
        decoded = jsonDecode(res.body);
      } catch (_) {
        decoded = null; // e.g. an HTML 502 page from the host
      }
      if (res.statusCode == 201 && decoded is Map<String, dynamic>) {
        final bookings = (decoded['bookings'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .where((b) => (b['id'] is String) && (b['id'] as String).isNotEmpty)
            .toList();
        if (bookings != null && bookings.isNotEmpty) {
          final pricing = decoded['pricing'];
          return (
            bookings: bookings,
            pricing: pricing is Map<String, dynamic> ? pricing : null,
            error: null,
            unauthorized: false,
          );
        }
        return (
          bookings: null,
          pricing: null,
          error:
              'The server did not confirm your booking. Nothing was booked — please try again.',
          unauthorized: false,
        );
      }
      if (res.statusCode == 401) {
        return (
          bookings: null,
          pricing: null,
          error: 'Your session needs refreshing — please try again.',
          unauthorized: true,
        );
      }
      final serverMessage =
          decoded is Map<String, dynamic> && decoded['error'] is String
              ? decoded['error'] as String
              : null;
      final String friendly;
      if (res.statusCode == 429) {
        friendly = 'Too many attempts — please wait a moment and try again.';
      } else if (res.statusCode >= 500 && serverMessage == null) {
        friendly =
            'Our server had a problem. Nothing was booked — please try again shortly.';
      } else {
        friendly = serverMessage ??
            'The server rejected this booking (${res.statusCode}).';
      }
      return (
        bookings: null,
        pricing: null,
        error: friendly,
        unauthorized: false
      );
    } on TimeoutException {
      return (
        bookings: null,
        pricing: null,
        error:
            'The server is taking too long to respond. Please check your connection and tap Confirm again — you will not be booked twice.',
        unauthorized: false,
      );
    } catch (_) {
      return (
        bookings: null,
        pricing: null,
        error:
            'Could not reach the server. Please check your connection and try again.',
        unauthorized: false,
      );
    }
  }

  /// GET /api/bookings with the caller's Firebase ID token — the backend
  /// scopes the result to that user's own bookings. Returns an empty list
  /// on any failure.
  Future<List<Map<String, dynamic>>> fetchBookings(
      {required String idToken}) async {
    try {
      final res = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/api/bookings'),
        headers: {'Authorization': 'Bearer $idToken'},
      ).timeout(_timeout);
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is List) {
          return decoded.whereType<Map<String, dynamic>>().toList();
        }
      }
    } catch (_) {
      // Best-effort — see file header.
    }
    return [];
  }

  /// POST /api/bookings/{id}/cancel/request-otp — texts the customer a
  /// short-lived code that [cancelBooking] below now requires before it
  /// takes effect. `sent` is true once the backend confirms the SMS
  /// actually went out. `error`, when set, is the backend's own real
  /// reason it didn't — no phone on file (a 400, fixable in Account
  /// settings) vs. the httpSMS gateway itself failing (a 200 with
  /// `sent: false`, not fixable by the customer at all) are genuinely
  /// different situations and get genuinely different messages; this
  /// used to collapse both into a guess based only on the HTTP status,
  /// which told a customer with a real phone on file to go add one.
  Future<({bool? sent, String? error})> requestCancelOtp({
    required String idToken,
    required String bookingId,
  }) async {
    try {
      final res = await http.post(
        Uri.parse(
            '${ApiConfig.baseUrl}/api/bookings/$bookingId/cancel/request-otp'),
        headers: {'Authorization': 'Bearer $idToken'},
      ).timeout(_timeout);
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) {
        if (res.statusCode == 200) {
          final ok = decoded['sent'] == true;
          return (
            sent: ok,
            error: ok ? null : decoded['message'] as String?,
          );
        }
        final message = (decoded['message'] ?? decoded['error']) as String?;
        return (
          sent: null,
          error: message ?? 'Could not send a cancellation code — try again.'
        );
      }
    } catch (_) {
      // Best-effort — see file header.
    }
    return (
      sent: null,
      error:
          'Could not send a cancellation code — check your connection and try again.',
    );
  }

  /// PATCH /api/bookings/{id}/cancel — the backend computes and applies the
  /// real cancellation fee itself (based on how far the job had progressed;
  /// see app.py's CANCELLATION_FEE_BY_STATUS), so this call carries no fee
  /// the client could tamper with. Requires the SMS code from
  /// [requestCancelOtp] above. Returns the updated booking JSON on a 200;
  /// on failure returns null plus a human-readable message where the
  /// backend supplied one (wrong/expired code, no such booking, etc.) —
  /// unlike this class's other methods, a caller here needs to tell "wrong
  /// code, try again" apart from "check your connection".
  Future<({Map<String, dynamic>? booking, String? error})> cancelBooking({
    required String idToken,
    required String bookingId,
    required String otp,
  }) async {
    try {
      final res = await http
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings/$bookingId/cancel'),
            headers: _headers(idToken),
            body: jsonEncode({'otp': otp}),
          )
          .timeout(_timeout);
      final decoded = jsonDecode(res.body);
      if (res.statusCode == 200 && decoded is Map<String, dynamic>) {
        return (booking: decoded, error: null);
      }
      final message = decoded is Map<String, dynamic>
          ? (decoded['message'] ?? decoded['error']) as String?
          : null;
      return (booking: null, error: message ?? 'Could not cancel — try again.');
    } catch (_) {
      return (
        booking: null,
        error: 'Could not cancel — check your connection and try again.'
      );
    }
  }

  /// POST /api/bookings/{id}/rating — the real endpoint the RateScreen
  /// star rating submits to. Returns true on success; the caller decides
  /// what to tell the customer on failure rather than silently pretending
  /// it worked.
  Future<bool> rateBooking({
    required String idToken,
    required String bookingId,
    required int rating,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings/$bookingId/rating'),
            headers: _headers(idToken),
            body: jsonEncode({'serviceRating': rating, 'techRating': rating}),
          )
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// PATCH /api/bookings/{id}/parts/{partId} — the customer approving or
  /// rejecting a part/extra-work quote a technician raised. Returns whether
  /// the backend actually recorded it — the backend refuses a second
  /// decision on an already-decided part, same as any other real failure.
  Future<bool> decidePart({
    required String idToken,
    required String bookingId,
    required String partId,
    required bool approve,
  }) async {
    try {
      final res = await http
          .patch(
            Uri.parse(
                '${ApiConfig.baseUrl}/api/bookings/$bookingId/parts/$partId'),
            headers: _headers(idToken),
            body: jsonEncode({'status': approve ? 'approved' : 'rejected'}),
          )
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// GET /api/auth/me — the real signed-in customer's backend profile,
  /// including their real Care Coins balance (`coinsBalance`). Returns
  /// null on any failure; the caller treats that as "balance unknown yet"
  /// rather than zero, so the checkout screen doesn't briefly claim a real
  /// customer has no coins before the fetch lands.
  Future<Map<String, dynamic>?> fetchMe({required String idToken}) async {
    try {
      final res = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/api/auth/me'),
        headers: {'Authorization': 'Bearer $idToken'},
      ).timeout(_timeout);
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) return decoded;
      }
    } catch (_) {
      // Best-effort — see file header.
    }
    return null;
  }

  /// POST /api/me/coins/redeem — deducts real Care Coins from the
  /// customer's balance right before checkout creates the booking(s), so
  /// redemption happens exactly once per order regardless of how many
  /// booking rows a multi-service cart creates. Returns the updated
  /// profile (with the new `coinsBalance`) on success, or null if the
  /// redemption was rejected (e.g. insufficient balance) or the request
  /// failed outright.
  Future<Map<String, dynamic>?> redeemCoins({
    required String idToken,
    required int amount,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/me/coins/redeem'),
            headers: _headers(idToken),
            body: jsonEncode({'amount': amount}),
          )
          .timeout(_timeout);
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) return decoded;
      }
    } catch (_) {
      // Best-effort — see file header.
    }
    return null;
  }

  /// POST /api/shop/orders — places a real order for one or more cleaning
  /// kits from ShopScreen's cart. `items` is a list of
  /// `{'productId': ..., 'qty': ...}` maps; prices are looked up
  /// server-side from the real catalog, never trusted from the client.
  /// Returns the created order (with its real total) on success, or
  /// `error` with the backend's rejection reason (e.g. an unknown product
  /// id) so the checkout screen can show why instead of a generic failure.
  Future<({Map<String, dynamic>? order, String? error})> placeShopOrder({
    required String idToken,
    required List<Map<String, dynamic>> items,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/shop/orders'),
            headers: _headers(idToken),
            body: jsonEncode({'items': items}),
          )
          .timeout(_timeout);
      final decoded = jsonDecode(res.body);
      if (res.statusCode == 201 && decoded is Map<String, dynamic>) {
        return (order: decoded, error: null);
      }
      final message =
          decoded is Map<String, dynamic> ? decoded['error'] as String? : null;
      return (order: null, error: message ?? 'Could not place your order.');
    } catch (_) {
      return (
        order: null,
        error: 'Could not reach the server — check your connection.'
      );
    }
  }

  /// GET /api/legal/{terms|privacy} — the real Terms of Service / Privacy
  /// Policy text served by the backend (`kind` is 'terms' or 'privacy').
  /// Returns null on any failure so the caller can show a real "couldn't
  /// load" state instead of silently rendering nothing.
  Future<Map<String, dynamic>?> fetchLegalDocument(String kind) async {
    try {
      final res = await http
          .get(Uri.parse('${ApiConfig.baseUrl}/api/legal/$kind'))
          .timeout(_timeout);
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) return decoded;
      }
    } catch (_) {
      // Best-effort — see file header.
    }
    return null;
  }
}
