import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

/// Why an upload failed, in terms a person (and a support engineer reading a
/// screenshot) can act on.
enum UploadErrorKind {
  /// Storage rules refused the write (or the user isn't signed in).
  denied,

  /// The bucket / project isn't set up (Storage never initialised).
  storageMissing,

  /// Offline, timed out, or the transfer was retried out.
  network,

  /// Rejected before sending (too big / not an image).
  invalidFile,
  unknown,
}

/// A failed upload. Holds only the failing operation (which document) and
/// the Firebase error *code* — never tokens, file contents, phone/Aadhaar
/// numbers, or Firebase's free-text message (which can embed paths/uids).
class UploadFailure {
  const UploadFailure({required this.operation, required this.code, required this.kind});
  final String operation;
  final String code;
  final UploadErrorKind kind;

  String get userMessage => switch (kind) {
        UploadErrorKind.denied =>
          "Uploads aren't permitted for this account yet (storage/$code). Please contact support.",
        UploadErrorKind.storageMissing =>
          "Photo storage isn't set up for this app yet (storage/$code). Please contact support.",
        UploadErrorKind.network =>
          'Upload failed — check your connection and try again (storage/$code).',
        UploadErrorKind.invalidFile =>
          'That file can\'t be uploaded ($code). Choose a JPG or PNG under 10 MB.',
        UploadErrorKind.unknown => 'Upload failed (storage/$code). Try again.',
      };

  @override
  String toString() => 'UploadFailure($operation, $code)';
}

class UploadResult {
  const UploadResult.ok(String this.url) : failure = null;
  const UploadResult.failed(UploadFailure this.failure) : url = null;
  final String? url;
  final UploadFailure? failure;
  bool get ok => url != null;
}

/// The one Firebase Storage call this feature makes, behind a seam so the
/// error handling can be tested without Firebase.
abstract interface class StorageUploader {
  /// Uploads [file] to [path] and returns its download URL. Throws
  /// [FirebaseException] (code = Firebase Storage error code) on failure.
  Future<String> uploadFile(String path, File file, {required String contentType});
}

class FirebaseStorageUploader implements StorageUploader {
  @override
  Future<String> uploadFile(String path, File file, {required String contentType}) async {
    final ref = FirebaseStorage.instance.ref(path);
    await ref
        .putFile(file, SettableMetadata(contentType: contentType))
        .timeout(const Duration(seconds: 60));
    return ref.getDownloadURL();
  }
}

/// Uploads a technician's application photos (profile photo, ID documents)
/// to `technician_applications/<uid>/<kind>.<ext>` in Firebase Storage —
/// see TechApplyScreen. Never throws: every failure comes back as an
/// [UploadFailure] naming the operation and the sanitized error code.
class TechnicianUploadService {
  TechnicianUploadService({
    StorageUploader? storage,
    String? Function()? currentUid,
    bool Function()? firebaseReady,
  })  : _storage = storage ?? FirebaseStorageUploader(),
        _currentUid = currentUid ?? _defaultUid,
        _firebaseReady = firebaseReady ?? _defaultReady;

  final StorageUploader _storage;
  final String? Function() _currentUid;
  final bool Function() _firebaseReady;

  static bool _defaultReady() => Firebase.apps.isNotEmpty;
  static String? _defaultUid() =>
      Firebase.apps.isEmpty ? null : FirebaseAuth.instance.currentUser?.uid;

  /// Matches the Storage rules (images only, < 10 MB).
  static const maxBytes = 10 * 1024 * 1024;

  static String? contentTypeFor(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      _ => null,
    };
  }

  Future<UploadResult> uploadResult(File file, {required String kind}) async {
    UploadResult fail(String code, UploadErrorKind k) =>
        UploadResult.failed(UploadFailure(operation: kind, code: code, kind: k));

    if (!_firebaseReady()) return fail('not-configured', UploadErrorKind.storageMissing);
    final uid = _currentUid();
    if (uid == null) return fail('unauthenticated', UploadErrorKind.denied);

    final contentType = contentTypeFor(file.path);
    if (contentType == null) return fail('invalid-file-type', UploadErrorKind.invalidFile);
    try {
      if (await file.length() > maxBytes) {
        return fail('file-too-large', UploadErrorKind.invalidFile);
      }
    } catch (_) {
      return fail('file-unreadable', UploadErrorKind.invalidFile);
    }

    final ext = file.path.split('.').last.toLowerCase();
    try {
      final url = await _storage.uploadFile(
          'technician_applications/$uid/$kind.$ext', file,
          contentType: contentType);
      return UploadResult.ok(url);
    } on TimeoutException {
      return _log(kind, fail('timeout', UploadErrorKind.network));
    } on FirebaseException catch (e) {
      return _log(kind, fail(_safeCode(e.code), classify(e.code)));
    } on SocketException {
      return _log(kind, fail('network-request-failed', UploadErrorKind.network));
    } catch (_) {
      return _log(kind, fail('unknown', UploadErrorKind.unknown));
    }
  }

  /// Convenience for callers that only need the URL.
  Future<String?> upload(File file, {required String kind}) async =>
      (await uploadResult(file, kind: kind)).url;

  static UploadResult _log(String kind, UploadResult r) {
    // Operation + code only; never the message, path, token or file.
    debugPrint('TechnicianUploadService: $kind failed — ${r.failure?.code}');
    return r;
  }

  static String _safeCode(String code) {
    final c = code.toLowerCase();
    return RegExp(r'^[a-z0-9\-_/]{1,40}$').hasMatch(c) ? c.replaceFirst('storage/', '') : 'unknown';
  }

  /// Maps Firebase Storage error codes to a [UploadErrorKind].
  @visibleForTesting
  static UploadErrorKind classify(String rawCode) {
    switch (_safeCode(rawCode)) {
      case 'unauthorized':
      case 'unauthenticated':
      case 'app-check-token-invalid':
        return UploadErrorKind.denied;
      case 'bucket-not-found':
      case 'project-not-found':
      case 'object-not-found':
        return UploadErrorKind.storageMissing;
      case 'retry-limit-exceeded':
      case 'network-request-failed':
      case 'canceled':
        return UploadErrorKind.network;
      case 'quota-exceeded':
        return UploadErrorKind.unknown;
      default:
        return UploadErrorKind.unknown;
    }
  }
}
