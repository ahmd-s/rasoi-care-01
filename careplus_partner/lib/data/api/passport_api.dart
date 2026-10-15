// Kitchen Passport client for the Flask backend (technician-authenticated).
//
// Mirrors ApiRepository's conventions — Firebase ID token as the bearer, the
// same base URL and timeouts — but is its own small class so the passport
// feature has no dependency on the job-feed cache. The token provider and
// http client are injectable so the request/response handling is unit
// testable without Firebase.
import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import 'api_config.dart';

const _timeout = Duration(seconds: 15);

class KitchenAppliance {
  const KitchenAppliance({
    required this.id,
    required this.category,
    required this.brand,
    required this.model,
    required this.serialNumber,
    required this.installYear,
    required this.specs,
    required this.notes,
  });

  factory KitchenAppliance.fromJson(Map<String, dynamic> j) => KitchenAppliance(
        id: j['id'] as String,
        category: j['category'] as String,
        brand: j['brand'] as String,
        model: (j['model'] as String?) ?? '',
        serialNumber: (j['serialNumber'] as String?) ?? '',
        installYear: j['installYear'] as int?,
        specs: Map<String, dynamic>.from((j['specs'] as Map?) ?? const {}),
        notes: (j['notes'] as String?) ?? '',
      );

  final String id;
  final String category;
  final String brand;
  final String model;
  final String serialNumber;
  final int? installYear;
  final Map<String, dynamic> specs;
  final String notes;
}

/// Outcome of a passport call. [error] is a message safe to show the user.
class PassportResult<T> {
  const PassportResult.ok(this.value)
      : error = null,
        created = true;
  const PassportResult.okExisting(this.value)
      : error = null,
        created = false;
  const PassportResult.failure(this.error)
      : value = null,
        created = false;

  final T? value;
  final String? error;

  /// False when the server returned an existing record (HTTP 200) rather
  /// than creating one (201).
  final bool created;
  bool get ok => error == null;
}

class PassportApi {
  PassportApi({http.Client? client, Future<String?> Function()? tokenProvider})
      : _client = client ?? http.Client(),
        _token = tokenProvider ?? _firebaseToken;

  final http.Client _client;
  final Future<String?> Function() _token;

  static Future<String?> _firebaseToken() async {
    if (Firebase.apps.isEmpty) return null;
    try {
      return await FirebaseAuth.instance.currentUser?.getIdToken();
    } catch (_) {
      return null;
    }
  }

  static const _signInMessage = 'Sign in again to use Kitchen Passport.';
  static const _networkMessage = 'Could not reach the server. Check your connection and retry.';

  Future<PassportResult<List<KitchenAppliance>>> kitchenFor(String bookingId) async {
    final r = await _send('GET', '/api/technician/bookings/$bookingId/kitchen');
    if (r.status != 200) return PassportResult.failure(_message(r));
    final list = (r.json['appliances'] as List?) ?? const [];
    return PassportResult.ok([
      for (final a in list) KitchenAppliance.fromJson(a as Map<String, dynamic>),
    ]);
  }

  Future<PassportResult<KitchenAppliance>> register(
      String bookingId, Map<String, dynamic> payload) async {
    final r = await _send('POST', '/api/technician/bookings/$bookingId/kitchen/appliances',
        body: payload);
    // 200 = the server already had this request id (a retry after a lost
    // response) and returned the existing record.
    if (r.status != 201 && r.status != 200) return PassportResult.failure(_message(r));
    final appliance = KitchenAppliance.fromJson(r.json);
    return r.status == 201
        ? PassportResult.ok(appliance)
        : PassportResult.okExisting(appliance);
  }

  Future<PassportResult<List<String>>> customBrands(String categoryId) async {
    final r = await _send('GET', '/api/technician/custom-brands?category=$categoryId');
    if (r.status != 200) return PassportResult.failure(_message(r));
    final list = (r.json['brands'] as List?) ?? const [];
    return PassportResult.ok([for (final b in list) (b as Map)['name'] as String]);
  }

  /// Saves [name] for [categoryId]. The value is the name as stored by the
  /// server (whitespace-normalised, or the existing spelling if it was
  /// already saved with different case).
  Future<PassportResult<String>> addCustomBrand(String categoryId, String name) async {
    final r = await _send('POST', '/api/technician/custom-brands',
        body: {'category': categoryId, 'name': name});
    if (r.status != 201 && r.status != 200) return PassportResult.failure(_message(r));
    final saved = r.json['name'] as String;
    return r.status == 201 ? PassportResult.ok(saved) : PassportResult.okExisting(saved);
  }

  Future<_Reply> _send(String method, String path, {Map<String, dynamic>? body}) async {
    final token = await _token();
    if (token == null) return const _Reply.failed(_signInMessage);
    try {
      final req = http.Request(method, Uri.parse('${ApiConfig.baseUrl}$path'))
        ..headers['Authorization'] = 'Bearer $token';
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      final res = await http.Response.fromStream(await _client.send(req).timeout(_timeout));
      Map<String, dynamic> json = const {};
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {
        // Non-JSON body — status code alone drives the outcome.
      }
      return _Reply(res.statusCode, json);
    } on TimeoutException {
      return const _Reply.failed(_networkMessage);
    } catch (_) {
      return const _Reply.failed(_networkMessage);
    }
  }

  static String _message(_Reply r) {
    if (r.failure != null) return r.failure!;
    switch (r.status) {
      case 401:
        return _signInMessage;
      case 404:
        return 'This job is no longer assigned to you.';
      case 429:
        return 'Too many requests. Wait a moment and retry.';
    }
    final fields = r.json['fields'];
    if (fields is Map && fields.isNotEmpty) {
      return fields.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    }
    final msg = r.json['message'] ?? r.json['error'];
    return msg is String ? msg : 'Something went wrong (error ${r.status}).';
  }
}

class _Reply {
  const _Reply(this.status, this.json) : failure = null;

  /// Request never completed (no token, timeout, network error).
  const _Reply.failed(this.failure)
      : status = 0,
        json = const {};
  final int status;
  final Map<String, dynamic> json;
  final String? failure;
}
