// Customer-side live location reads go through the authenticated backend.
// The booking endpoint verifies ownership and active status before returning
// coordinates, so customer apps never need direct Firestore read access to a
// technician's location.

import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import '../api/api_config.dart';

class TechnicianLocation {
  const TechnicianLocation({required this.lat, required this.lng, this.updatedAt});
  final double lat;
  final double lng;
  final DateTime? updatedAt;
}

class TechnicianLocationService {
  static const _requestTimeout = Duration(seconds: 8);
  static const _pollInterval = Duration(seconds: 5);

  /// Polls an authenticated booking-scoped endpoint. The backend returns a
  /// position only to that booking's customer and only while the job is
  /// active; a missing/stale fix is emitted as null.
  Stream<TechnicianLocation?> watchLocation(String bookingId) async* {
    if (Firebase.apps.isEmpty) {
      yield null;
      return;
    }
    while (true) {
      yield await _fetch(bookingId);
      await Future<void>.delayed(_pollInterval);
    }
  }

  Future<TechnicianLocation?> _fetch(String bookingId) async {
    try {
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) return null;
      final response = await http
          .get(
            Uri.parse(
              '${ApiConfig.baseUrl}/api/bookings/${Uri.encodeComponent(bookingId)}/live-location',
            ),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_requestTimeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      final location = decoded['location'];
      if (location is! Map<String, dynamic>) return null;
      final lat = (location['lat'] as num?)?.toDouble();
      final lng = (location['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;
      return TechnicianLocation(
        lat: lat,
        lng: lng,
        updatedAt: DateTime.tryParse('${location['updatedAt'] ?? ''}'),
      );
    } catch (_) {
      return null;
    }
  }
}
