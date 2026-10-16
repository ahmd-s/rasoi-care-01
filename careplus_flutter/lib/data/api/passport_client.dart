// Customer-facing Kitchen Passport client for the Flask backend.
//
// Reads the signed-in customer's own Passport from
// GET /api/kitchen-passport/overview (the server scopes it to the token's
// customer). The http client and token provider are injectable so parsing and
// failure handling are unit-testable without Firebase or a network.
//
// Parsing is deliberately tolerant and never fills a gap: a missing score
// stays null, a malformed list entry is dropped, and an unknown status is
// treated as "no status" rather than guessed.
import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import 'api_config.dart';

const _timeout = Duration(seconds: 12);

const _statuses = {'healthy', 'attention', 'priority', 'critical'};
const _urgencies = {'urgent', 'priority', 'soon', 'routine'};

String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
int? _int(Object? v) => v is int ? v : null;
String? _status(Object? v) => v is String && _statuses.contains(v) ? v : null;

class PassportNextService {
  const PassportNextService({
    required this.urgency,
    required this.estimatedDays,
    this.applianceId,
    this.category,
  });

  static PassportNextService? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final urgency = raw['urgency'];
    final days = _int(raw['estimatedDays']);
    if (urgency is! String ||
        !_urgencies.contains(urgency) ||
        days == null ||
        days < 0) {
      return null;
    }
    return PassportNextService(
      urgency: urgency,
      estimatedDays: days,
      applianceId: _str(raw['applianceId']),
      category: _str(raw['category']),
    );
  }

  /// urgent | priority | soon | routine
  final String urgency;
  final int estimatedDays;
  final String? applianceId;
  final String? category;
}

class PassportVisit {
  const PassportVisit({
    required this.date,
    required this.serviceName,
    required this.score,
    required this.status,
    required this.safetyFlagged,
  });

  static PassportVisit? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final date = _str(raw['date']);
    if (date == null) return null;
    return PassportVisit(
      date: DateTime.tryParse(date),
      serviceName: _str(raw['serviceName']),
      score: _int(raw['score']),
      status: _status(raw['status']),
      safetyFlagged: raw['safetyFlagged'] == true,
    );
  }

  final DateTime? date;
  final String? serviceName;

  /// Technician-only score for that visit; null when it was not scored.
  final int? score;
  final String? status;
  final bool safetyFlagged;
}

class PassportAppliance {
  const PassportAppliance({
    required this.id,
    required this.category,
    required this.brand,
    required this.model,
    required this.score,
    required this.status,
    required this.checksTested,
    required this.checksTotal,
    required this.notEnoughChecks,
    required this.safetyFlagged,
    required this.attentionItems,
    required this.includesPhotoReview,
    required this.nextService,
    required this.history,
  });

  static PassportAppliance? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _str(raw['id']);
    final category = _str(raw['category']);
    if (id == null || category == null) return null;
    return PassportAppliance(
      id: id,
      category: category,
      brand: _str(raw['brand']) ?? '',
      model: _str(raw['model']) ?? '',
      score: _int(raw['score']),
      status: _status(raw['status']),
      checksTested: _int(raw['checksTested']) ?? 0,
      checksTotal: _int(raw['checksTotal']) ?? 0,
      notEnoughChecks:
          raw['notEnoughChecks'] == true || _int(raw['score']) == null,
      safetyFlagged: raw['safetyFlagged'] == true,
      attentionItems: [
        if (raw['attentionItems'] is List)
          for (final x in raw['attentionItems'] as List)
            if (_str(x) != null) x as String,
      ],
      includesPhotoReview: raw['basis'] == 'technician_plus_photo_review',
      nextService: PassportNextService.tryParse(raw['nextService']),
      history: [
        if (raw['history'] is List)
          for (final h in raw['history'] as List)
            if (PassportVisit.tryParse(h) != null) PassportVisit.tryParse(h)!,
      ],
    );
  }

  final String id;
  final String category;
  final String brand;
  final String model;
  final int? score;
  final String? status;
  final int checksTested;
  final int checksTotal;
  final bool notEnoughChecks;
  final bool safetyFlagged;
  final List<String> attentionItems;

  /// True when a technician-accepted photo review is part of [score].
  final bool includesPhotoReview;
  final PassportNextService? nextService;
  final List<PassportVisit> history;
}

class KitchenPassport {
  const KitchenPassport({
    required this.score,
    required this.status,
    required this.registeredCount,
    required this.assessedCount,
    required this.safetyFlagged,
    required this.nextService,
    required this.appliances,
    required this.needsAttention,
  });

  /// Null when the response isn't an object with the expected sections.
  static KitchenPassport? tryParse(Object? raw) {
    if (raw is! Map || raw['kitchen'] is! Map || raw['appliances'] is! List) {
      return null;
    }
    final k = raw['kitchen'] as Map;
    final appliances = [
      for (final a in raw['appliances'] as List)
        if (PassportAppliance.tryParse(a) != null)
          PassportAppliance.tryParse(a)!,
    ];
    final ids = appliances.map((a) => a.id).toSet();
    return KitchenPassport(
      score: _int(k['score']),
      status: _status(k['status']),
      registeredCount: _int(k['registeredCount']) ?? appliances.length,
      assessedCount: _int(k['assessedCount']) ?? 0,
      safetyFlagged: k['safetyFlagged'] == true,
      nextService: PassportNextService.tryParse(k['nextService']),
      appliances: appliances,
      needsAttention: [
        if (raw['needsAttention'] is List)
          for (final x in raw['needsAttention'] as List)
            if (x is String && ids.contains(x)) x,
      ],
    );
  }

  final int? score;
  final String? status;
  final int registeredCount;
  final int assessedCount;
  final bool safetyFlagged;
  final PassportNextService? nextService;
  final List<PassportAppliance> appliances;

  /// Appliance ids, most urgent first.
  final List<String> needsAttention;
}

enum PassportFailureKind { signedOut, network, server }

class PassportFailure {
  const PassportFailure(this.kind);
  final PassportFailureKind kind;
}

class PassportResult {
  const PassportResult.ok(this.passport) : failure = null;
  const PassportResult.fail(this.failure) : passport = null;
  final KitchenPassport? passport;
  final PassportFailure? failure;
  bool get ok => failure == null;
}

class PassportClient {
  PassportClient(
      {http.Client? client, Future<String?> Function()? tokenProvider})
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

  Future<PassportResult> overview() async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      return const PassportResult.fail(
          PassportFailure(PassportFailureKind.signedOut));
    }
    try {
      final res = await _client.get(
        Uri.parse('${ApiConfig.baseUrl}/api/kitchen-passport/overview'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(_timeout);
      if (res.statusCode == 401) {
        return const PassportResult.fail(
            PassportFailure(PassportFailureKind.signedOut));
      }
      if (res.statusCode != 200) {
        return const PassportResult.fail(
            PassportFailure(PassportFailureKind.server));
      }
      final passport = KitchenPassport.tryParse(jsonDecode(res.body));
      if (passport == null) {
        return const PassportResult.fail(
            PassportFailure(PassportFailureKind.server));
      }
      return PassportResult.ok(passport);
    } on TimeoutException {
      return const PassportResult.fail(
          PassportFailure(PassportFailureKind.network));
    } on FormatException {
      return const PassportResult.fail(
          PassportFailure(PassportFailureKind.server));
    } catch (_) {
      return const PassportResult.fail(
          PassportFailure(PassportFailureKind.network));
    }
  }
}
