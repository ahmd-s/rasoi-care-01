import 'dart:io';

import '../../data/firebase/technician_upload_service.dart';

/// Files the applicant picked on the application form (null = not picked /
/// already on file).
class PickedApplicationFiles {
  const PickedApplicationFiles({
    this.photo,
    this.aadharFront,
    this.aadharBack,
    this.pan,
    this.passbook,
  });
  final File? photo;
  final File? aadharFront;
  final File? aadharBack;
  final File? pan;
  final File? passbook;
}

class ApplicationUploadOutcome {
  const ApplicationUploadOutcome({
    this.photoUrl,
    this.aadharFrontUrl,
    this.aadharBackUrl,
    this.panUrl,
    this.passbookUrl,
    this.blocking,
    this.photoWarning,
  });
  final String? photoUrl;
  final String? aadharFrontUrl;
  final String? aadharBackUrl;
  final String? panUrl;
  final String? passbookUrl;

  /// A required/picked document failed: the application must not be
  /// submitted.
  final UploadFailure? blocking;

  /// The OPTIONAL profile photo failed: submit without it, but tell them.
  final UploadFailure? photoWarning;

  bool get canSubmit => blocking == null;
}

/// Runs the application's uploads: identity documents first (any failure
/// blocks submission and names the failing document), then the optional
/// profile photo (a failure only produces a warning). At most one run is in
/// flight — a repeated tap while uploading returns null instead of starting
/// a second round of uploads.
class ApplicationUploader {
  ApplicationUploader(this._service);
  final TechnicianUploadService _service;
  bool _running = false;

  bool get running => _running;

  Future<ApplicationUploadOutcome?> run(PickedApplicationFiles files) async {
    if (_running) return null;
    _running = true;
    try {
      Future<UploadResult?> up(File? f, String kind) async =>
          f == null ? null : _service.uploadResult(f, kind: kind);

      final front = await up(files.aadharFront, 'aadhar_document');
      if (front != null && !front.ok) return ApplicationUploadOutcome(blocking: front.failure);
      final back = await up(files.aadharBack, 'aadhar_document_back');
      if (back != null && !back.ok) return ApplicationUploadOutcome(blocking: back.failure);
      final pan = await up(files.pan, 'pan_document');
      if (pan != null && !pan.ok) return ApplicationUploadOutcome(blocking: pan.failure);
      final passbook = await up(files.passbook, 'bank_passbook');
      if (passbook != null && !passbook.ok) {
        return ApplicationUploadOutcome(blocking: passbook.failure);
      }
      final photo = await up(files.photo, 'photo');
      return ApplicationUploadOutcome(
        aadharFrontUrl: front?.url,
        aadharBackUrl: back?.url,
        panUrl: pan?.url,
        passbookUrl: passbook?.url,
        photoUrl: photo?.url,
        photoWarning: photo != null && !photo.ok ? photo.failure : null,
      );
    } finally {
      _running = false;
    }
  }
}
