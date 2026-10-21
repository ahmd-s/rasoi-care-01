// Best-effort authenticated GPS write-through to the backend. The backend
// verifies the technician identity, approval, on-duty state and active job;
// customer reads are scoped to their own booking.

import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import '../api/api_config.dart';

class TechnicianLocationService {
  static const _timeout = Duration(seconds: 8);

  /// Returns false when the backend says this technician is no longer
  /// eligible to share (403 not approved/on duty, 409 no active job), so the
  /// caller can stop the location stream. Any other outcome returns true.
  Future<bool> pushLocation({required double lat, required double lng}) async {
    if (Firebase.apps.isEmpty) return true;
    try {
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) return true;
      final response = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/technician/location'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'lat': lat, 'lng': lng}),
          )
          .timeout(_timeout);
      return response.statusCode != 403 && response.statusCode != 409;
    } catch (_) {
      // A missed location update must never block the technician's job flow.
      return true;
    }
  }

  Future<void> clearLocation() async {
    if (Firebase.apps.isEmpty) return;
    try {
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) return;
      await http
          .delete(
            Uri.parse('${ApiConfig.baseUrl}/api/technician/location'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
    } catch (_) {
      // Best-effort cleanup; the backend also withholds locations after 90s.
    }
  }
}
