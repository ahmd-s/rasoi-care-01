// Vision AI inspection client for the Flask backend (technician-authenticated).
//
// Mirrors PassportApi's conventions (Firebase ID token as bearer, same base
// URL) but is its own class. Everything here talks to the Flask server only:
// no provider is called from the app and no provider credential exists in it.
//
// Routes (see docs/VISION_AI.md; the backend has no accept/edit/reject route,
// so none is modelled here):
//   GET  /api/technician/ai-inspection/config
//   POST /api/technician/bookings/<b>/kitchen/appliances/<a>/ai-inspections
//   GET  .../ai-inspections            (recent jobs for this visit, no results)
//   GET  .../ai-inspections/<id>       (status + validated result)
//
// Result parsing is deliberately tolerant: every field is optional, wrong
// types are dropped, and nothing is rendered as markup.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import 'api_config.dart';

const _readTimeout = Duration(seconds: 15);
// Up to ~6 MB of base64 photos: allow a slow mobile uplink.
const _uploadTimeout = Duration(seconds: 90);

/// Server-reported job states. [unknown] is anything else; the app stops
/// polling on it rather than guessing.
enum AiJobStatus {
  queued,
  running,
  completed,
  failed,
  rejected,
  unknown;

  static AiJobStatus fromWire(Object? v) => switch (v) {
    'queued' => queued,
    'running' => running,
    'completed' => completed,
    'failed' => failed,
    'rejected' => rejected,
    _ => unknown,
  };

  bool get inProgress => this == queued || this == running;
}

String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
int? _int(Object? v) =>
    v is int ? v : (v is double && v == v.roundToDouble() ? v.toInt() : null);
double? _num(Object? v) => v is num ? v.toDouble() : null;
List<String> _strings(Object? v) => v is List
    ? [
        for (final x in v)
          if (_str(x) != null) x as String,
      ]
    : const [];

class AiConfig {
  const AiConfig({
    required this.enabled,
    required this.minImages,
    required this.maxImages,
    required this.maxImageBytes,
    required this.maxTotalBytes,
    required this.acceptedTypes,
    required this.recommendedLongEdgePx,
    required this.recommendedJpegQuality,
    required this.maxSubmissionsPerVisit,
    required this.privacyNotice,
    this.simulated = false,
  });

  /// Only an explicit `enabled: true` enables the feature; anything missing
  /// or malformed falls back to disabled and the documented upload limits.
  factory AiConfig.fromJson(Map<String, dynamic> j) => AiConfig(
    enabled: j['enabled'] == true,
    simulated: j['simulated'] == true,
    minImages: _int(j['minImages']) ?? 1,
    maxImages: _int(j['maxImages']) ?? 5,
    maxImageBytes: _int(j['maxImageBytes']) ?? 1500000,
    maxTotalBytes: _int(j['maxTotalBytes']) ?? 6000000,
    acceptedTypes: _strings(j['acceptedTypes']).isEmpty
        ? const ['image/jpeg', 'image/png', 'image/webp']
        : _strings(j['acceptedTypes']),
    recommendedLongEdgePx: _int(j['recommendedLongEdgePx']) ?? 1280,
    recommendedJpegQuality: _int(j['recommendedJpegQuality']) ?? 80,
    maxSubmissionsPerVisit: _int(j['maxSubmissionsPerVisit']),
    privacyNotice:
        _str(j['privacyNotice']) ??
        'Keep people, documents and any sensitive information out of frame. '
            'Photograph only the appliance.',
  );

  final bool enabled;
  final int minImages;
  final int maxImages;
  final int maxImageBytes;
  final int maxTotalBytes;
  final List<String> acceptedTypes;
  final int recommendedLongEdgePx;
  final int recommendedJpegQuality;
  final int? maxSubmissionsPerVisit;
  final String privacyNotice;

  /// True when the server's active provider fabricates output (test mode).
  final bool simulated;
}

class AiFinding {
  const AiFinding({
    required this.code,
    required this.label,
    required this.severity,
    required this.confidence,
    required this.evidence,
    required this.photoIndexes,
    required this.safetyRelevant,
    required this.recommendation,
    required this.checklistKey,
  });

  static AiFinding? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final label = _str(raw['label']);
    // A finding with no label cannot be shown meaningfully; drop it rather
    // than invent text.
    if (label == null) return null;
    return AiFinding(
      code: _str(raw['code']) ?? '',
      label: label,
      severity: _str(raw['severity']),
      confidence: _num(raw['confidence']),
      evidence: _str(raw['evidence']),
      photoIndexes: [
        if (raw['photoIndexes'] is List)
          for (final i in raw['photoIndexes'] as List)
            if (_int(i) != null && _int(i)! >= 0) _int(i)!,
      ],
      safetyRelevant: raw['safetyRelevant'] == true,
      recommendation: _str(raw['recommendation']),
      checklistKey: _str(raw['checklistKey']),
    );
  }

  final String code;
  final String label;
  final String? severity;
  final double? confidence;
  final String? evidence;

  /// 0-based photo positions in the submission.
  final List<int> photoIndexes;
  final bool safetyRelevant;
  final String? recommendation;
  final String? checklistKey;
}

class AiInconsistency {
  const AiInconsistency({required this.visualFinding, required this.reason});
  final String visualFinding;
  final String reason;
}

/// The validated result of a completed analysis. [conditionScore] is a
/// visual-only number: the server never feeds it into Kitchen Health here
/// ([usedInHealthScore] is false) and neither does the app.
class AiResult {
  const AiResult({
    required this.applianceProfile,
    required this.summary,
    required this.conditionScore,
    required this.scoreRationale,
    required this.findings,
    required this.urgency,
    required this.estimatedDays,
    required this.focusAreas,
    required this.recommendation,
    required this.inconsistencies,
    required this.limitations,
    required this.notAssessableChecks,
    required this.reviewMessages,
    required this.photosAnalyzed,
    required this.visibility,
    required this.disclaimer,
    required this.accepted,
    required this.usedInHealthScore,
    this.simulated = false,
    required this.analyzedAt,
  });

  factory AiResult.fromJson(Map<String, dynamic> j) {
    final review = j['technicianReview'];
    return AiResult(
      applianceProfile: _str(j['applianceProfile']),
      summary: _str(j['summary']),
      conditionScore: _int(j['conditionScore']),
      scoreRationale: _str(j['scoreRationale']),
      findings: [
        if (j['findings'] is List)
          for (final f in j['findings'] as List)
            if (AiFinding.tryParse(f) != null) AiFinding.tryParse(f)!,
      ],
      urgency: _str(j['urgency']),
      estimatedDays: _int(j['estimatedDays']),
      focusAreas: _strings(j['focusAreas']),
      recommendation: _str(j['recommendation']),
      inconsistencies: [
        if (j['inconsistencies'] is List)
          for (final i in j['inconsistencies'] as List)
            if (i is Map && _str(i['reason']) != null)
              AiInconsistency(
                visualFinding: _str(i['visualFinding']) ?? '',
                reason: i['reason'] as String,
              ),
      ],
      limitations: _strings(j['limitations']),
      notAssessableChecks: _strings(j['notAssessableChecks']),
      reviewMessages: review is Map ? _strings(review['messages']) : const [],
      photosAnalyzed: _int(j['photosAnalyzed']),
      visibility: _str(j['visibility']),
      disclaimer: _str(j['disclaimer']),
      accepted: j['accepted'] == true,
      usedInHealthScore: j['usedInHealthScore'] == true,
      simulated: j['simulated'] == true,
      analyzedAt: _str(j['analyzedAt']),
    );
  }

  final String? applianceProfile;
  final String? summary;
  final int? conditionScore;
  final String? scoreRationale;
  final List<AiFinding> findings;
  final String? urgency;

  /// Server-suggested days until the next service for this urgency.
  final int? estimatedDays;

  /// What this appliance's visual profile looks at.
  final List<String> focusAreas;
  final String? recommendation;
  final List<AiInconsistency> inconsistencies;
  final List<String> limitations;
  final List<String> notAssessableChecks;
  final List<String> reviewMessages;
  final int? photosAnalyzed;
  final String? visibility;
  final String? disclaimer;
  final bool accepted;
  final bool usedInHealthScore;

  /// Produced by a test provider: not a real inspection and never used in a
  /// score. Set by the server; the app only displays it.
  final bool simulated;
  final String? analyzedAt;
}

class AiInspection {
  const AiInspection({
    required this.id,
    required this.status,
    required this.retryable,
    required this.imageCount,
    required this.createdAt,
    required this.errorCode,
    required this.errorMessage,
    required this.result,
    required this.resultMalformed,
    this.review,
  });

  /// Null when the payload has no usable id (nothing could be polled).
  static AiInspection? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _str(raw['id']);
    if (id == null) return null;
    final status = AiJobStatus.fromWire(raw['status']);
    final err = raw['error'];
    final resultRaw = raw['result'];
    AiResult? result;
    var malformed = false;
    if (status == AiJobStatus.completed) {
      if (resultRaw is Map<String, dynamic>) {
        result = AiResult.fromJson(resultRaw);
      } else {
        malformed = true;
      }
    }
    return AiInspection(
      id: id,
      status: status,
      retryable: raw['retryable'] == true,
      imageCount: _int(raw['imageCount']),
      createdAt: _str(raw['createdAt']),
      errorCode: err is Map ? _str(err['code']) : null,
      errorMessage: err is Map ? _str(err['message']) : null,
      result: result,
      resultMalformed: malformed,
      review: AiReview.tryParse(raw['review']),
    );
  }

  final String id;
  final AiJobStatus status;
  final bool retryable;
  final int? imageCount;
  final String? createdAt;
  final String? errorCode;
  final String? errorMessage;
  final AiResult? result;

  /// Completed, but the result payload was missing or not an object.
  final bool resultMalformed;

  /// The technician's latest saved decision, if any.
  final AiReview? review;
}

/// One finding's verdict inside a technician review.
class AiFindingReview {
  const AiFindingReview({
    required this.code,
    required this.confirmed,
    required this.severity,
    required this.note,
  });
  final String code;
  final bool confirmed;
  final String? severity;
  final String note;
}

/// The technician's saved decision about an AI result (the server keeps it
/// separate from the immutable AI result and never lets a client set a score).
class AiReview {
  const AiReview({
    required this.id,
    required this.revision,
    required this.decision,
    required this.reviewedScore,
    required this.reviewedAt,
    this.simulated = false,
    required this.findings,
    required this.reason,
  });

  static AiReview? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _str(raw['id']);
    final decision = _str(raw['decision']);
    if (id == null || !const ['accept', 'edit', 'reject'].contains(decision)) {
      return null;
    }
    return AiReview(
      id: id,
      revision: _int(raw['revision']) ?? 1,
      decision: decision!,
      reviewedScore: _int(raw['reviewedScore']),
      reviewedAt: _str(raw['reviewedAt']),
      simulated: raw['simulated'] == true,
      reason: _str(raw['reason']) ?? '',
      findings: [
        if (raw['findings'] is List)
          for (final f in raw['findings'] as List)
            if (f is Map && _str(f['code']) != null)
              AiFindingReview(
                code: f['code'] as String,
                confirmed: f['decision'] == 'confirm',
                severity: _str(f['severity']),
                note: _str(f['note']) ?? '',
              ),
      ],
    );
  }

  final String id;
  final int revision;

  /// accept | edit | reject
  final String decision;
  final int? reviewedScore;
  final String? reviewedAt;
  final bool simulated;
  final List<AiFindingReview> findings;
  final String reason;
  bool get accepted => decision != 'reject';
}

/// What the technician decided for one finding when editing.
class AiFindingDecision {
  const AiFindingDecision({
    required this.code,
    required this.confirmed,
    required this.severity,
    this.note = '',
  });
  final String code;
  final bool confirmed;
  final String severity;
  final String note;

  Map<String, dynamic> toJson() => {
    'code': code,
    'decision': confirmed ? 'confirm' : 'reject',
    'severity': severity,
    if (note.isNotEmpty) 'note': note,
  };
}

/// A photo to upload. Bytes live in memory only.
class AiPhoto {
  const AiPhoto({required this.bytes, required this.mimeType});
  final Uint8List bytes;
  final String mimeType;
}

/// Why a call failed. [message] is safe to show. [networkError] means the
/// request may or may not have reached the server (no response was read).
class AiFailure {
  const AiFailure(
    this.message, {
    this.code,
    this.status = 0,
    this.imageIndex,
    this.networkError = false,
  });
  final String message;
  final String? code;
  final int status;
  final int? imageIndex;
  final bool networkError;

  /// 503 ai_unavailable / busy / circuit_open: the feature is off or full.
  bool get unavailable => status == 503;
  bool get signedOut => status == 401;
}

class AiResultOf<T> {
  const AiResultOf.ok(this.value) : failure = null;
  const AiResultOf.fail(this.failure) : value = null;
  final T? value;
  final AiFailure? failure;
  bool get ok => failure == null;
}

class VisionApi {
  VisionApi({http.Client? client, Future<String?> Function()? tokenProvider})
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

  static const _signIn = 'Sign in again to use photo inspection.';
  static const _network =
      'Could not reach the server. Check your connection and retry.';

  String _base(String bookingId, String applianceId) =>
      '/api/technician/bookings/$bookingId/kitchen/appliances/$applianceId/ai-inspections';

  Future<AiResultOf<AiConfig>> config() async {
    final r = await _send('GET', '/api/technician/ai-inspection/config');
    if (r.status != 200) return AiResultOf.fail(_failure(r));
    return AiResultOf.ok(AiConfig.fromJson(r.json));
  }

  /// Uploads [photos] for analysis. Returns the queued job (202), or the
  /// existing job when [clientRequestId] was already used (200). Reusing an
  /// id after an unconfirmed network failure is what prevents a double
  /// analysis; a deliberate new attempt must use a new id.
  Future<AiResultOf<AiInspection>> submit(
    String bookingId,
    String applianceId, {
    required List<AiPhoto> photos,
    required String clientRequestId,
  }) async {
    final r = await _send(
      'POST',
      _base(bookingId, applianceId),
      body: {
        'images': [
          for (final p in photos)
            {'data': base64Encode(p.bytes), 'mimeType': p.mimeType},
        ],
        'clientRequestId': clientRequestId,
      },
      timeout: _uploadTimeout,
    );
    if (r.status != 202 && r.status != 200) return AiResultOf.fail(_failure(r));
    final job = AiInspection.tryParse(r.json['inspection']);
    if (job == null) {
      return const AiResultOf.fail(
        AiFailure('The server sent an unexpected reply.', status: 502),
      );
    }
    return AiResultOf.ok(job);
  }

  Future<AiResultOf<AiInspection>> status(
    String bookingId,
    String applianceId,
    String inspectionId,
  ) async {
    final r = await _send(
      'GET',
      '${_base(bookingId, applianceId)}/$inspectionId',
    );
    if (r.status != 200) return AiResultOf.fail(_failure(r));
    final job = AiInspection.tryParse(r.json['inspection']);
    if (job == null) {
      return const AiResultOf.fail(
        AiFailure('The server sent an unexpected reply.', status: 502),
      );
    }
    return AiResultOf.ok(job);
  }

  /// Recent analyses for this appliance on this visit (newest first). They
  /// carry status only, never a result body.
  Future<AiResultOf<List<AiInspection>>> list(
    String bookingId,
    String applianceId,
  ) async {
    final r = await _send('GET', _base(bookingId, applianceId));
    if (r.status != 200) return AiResultOf.fail(_failure(r));
    final raw = r.json['inspections'];
    return AiResultOf.ok([
      if (raw is List)
        for (final x in raw)
          if (AiInspection.tryParse(x) != null) AiInspection.tryParse(x)!,
    ]);
  }

  /// Saves the technician's decision about a completed analysis. [decision] is
  /// accept | edit | reject; [findings] is only for edit. The score is never
  /// sent: the server recomputes it. Reusing a [clientRequestId] after an
  /// unconfirmed failure returns the original decision rather than a new one.
  Future<AiResultOf<AiReview>> review(
    String bookingId,
    String applianceId,
    String inspectionId, {
    required String decision,
    List<AiFindingDecision>? findings,
    String? reason,
    required String clientRequestId,
  }) async {
    final r = await _send(
      'POST',
      '${_base(bookingId, applianceId)}/$inspectionId/review',
      body: {
        'decision': decision,
        if (findings != null)
          'findings': [for (final f in findings) f.toJson()],
        if (reason != null && reason.isNotEmpty) 'reason': reason,
        'clientRequestId': clientRequestId,
      },
    );
    if (r.status != 201 && r.status != 200) return AiResultOf.fail(_failure(r));
    final review = AiReview.tryParse(r.json['review']);
    if (review == null) {
      return const AiResultOf.fail(
        AiFailure('The server sent an unexpected reply.', status: 502),
      );
    }
    return AiResultOf.ok(review);
  }

  Future<_Reply> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = _readTimeout,
  }) async {
    final token = await _token();
    if (token == null) return const _Reply.failed(_signIn, 401);
    try {
      final req = http.Request(method, Uri.parse('${ApiConfig.baseUrl}$path'))
        ..headers['Authorization'] = 'Bearer $token';
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      final res = await http.Response.fromStream(
        await _client.send(req).timeout(timeout),
      );
      Map<String, dynamic> json = const {};
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {
        // Non-JSON body — the status code alone drives the outcome.
      }
      return _Reply(res.statusCode, json);
    } catch (_) {
      // Timeout or transport error: the server may still have received it.
      return const _Reply.failed(_network, 0);
    }
  }

  static AiFailure _failure(_Reply r) {
    if (r.failure != null) {
      return AiFailure(
        r.failure!,
        status: r.status,
        networkError: r.status == 0,
      );
    }
    final code = _str(r.json['code']);
    final serverMessage = _str(r.json['message']);
    final index = _int(r.json['imageIndex']);
    switch (r.status) {
      case 401:
        return const AiFailure(_signIn, status: 401);
      case 404:
        return const AiFailure(
          'This job is no longer assigned to you.',
          status: 404,
        );
    }
    return AiFailure(
      serverMessage ??
          _str(r.json['error']) ??
          'Something went wrong (error ${r.status}).',
      code: code,
      status: r.status,
      imageIndex: index,
    );
  }
}

class _Reply {
  const _Reply(this.status, this.json) : failure = null;
  const _Reply.failed(this.failure, this.status) : json = const {};
  final int status;
  final Map<String, dynamic> json;
  final String? failure;
}
