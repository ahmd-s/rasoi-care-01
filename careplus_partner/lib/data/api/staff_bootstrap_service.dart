import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import '../operations/models.dart';
import 'api_config.dart';

class StaffBootstrapResult {
  const StaffBootstrapResult({this.role, this.notStaff = false, this.error});
  final AdminRole? role;
  final bool notStaff;
  final String? error;
}

class StaffBootstrapService {
  StaffBootstrapService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<StaffBootstrapResult> bootstrap({String? requestedRole}) async {
    if (Firebase.apps.isEmpty) return const StaffBootstrapResult(notStaff: true);
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const StaffBootstrapResult(notStaff: true);
    try {
      final token = await user.getIdToken();
      if (token == null) return const StaffBootstrapResult(error: 'Sign in again to continue.');
      final response = await _client
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/staff/bootstrap'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'name': user.displayName ?? user.email ?? user.phoneNumber ?? 'Staff',
              if (requestedRole != null) 'role': requestedRole,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        return StaffBootstrapResult(
          role: payload['role'] == 'owner' ? AdminRole.owner : AdminRole.staff,
        );
      }
      if (response.statusCode == 403 || response.statusCode == 401) {
        String? message;
        try {
          final m = (jsonDecode(response.body) as Map)['message'];
          if (m is String && m.isNotEmpty && m.length < 200) message = m;
        } catch (_) {}
        return StaffBootstrapResult(notStaff: true, error: message);
      }
      return const StaffBootstrapResult(error: 'Could not verify Partner access. Try again.');
    } catch (_) {
      return const StaffBootstrapResult(error: 'Could not reach the service. Check your connection.');
    }
  }
}
