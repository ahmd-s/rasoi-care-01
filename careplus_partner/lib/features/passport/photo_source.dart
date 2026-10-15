import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/api/vision_api.dart';

/// Camera/gallery access behind an interface so the inspection screen can be
/// tested without platform channels. Nothing here uploads or stores a photo:
/// bytes are handed to the caller and live in memory only.
abstract class PhotoSource {
  /// Takes one photo. Empty when the technician cancels.
  Future<List<Uint8List>> fromCamera();

  /// Chooses up to [limit] existing photos. Empty when cancelled.
  Future<List<Uint8List>> fromGallery({required int limit});
}

enum PhotoSourceKind { camera, gallery }

/// The OS refused camera/photo access (denied, or denied permanently).
class PhotoPermissionDenied implements Exception {
  const PhotoPermissionDenied(this.kind);
  final PhotoSourceKind kind;
}

/// Any other picker failure (no camera, plugin error, unreadable file).
class PhotoPickFailed implements Exception {
  const PhotoPickFailed();
}

/// image_picker implementation. The picker itself downsizes to the long edge
/// and JPEG quality the server recommends, so a typical photo is a few
/// hundred KB; the screen still checks the server's hard limits.
class ImagePickerPhotoSource implements PhotoSource {
  ImagePickerPhotoSource({
    ImagePicker? picker,
    this.maxEdge = 1280,
    this.quality = 80,
  }) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;
  final double maxEdge;
  final int quality;

  @override
  Future<List<Uint8List>> fromCamera() async {
    try {
      final f = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: maxEdge,
        maxHeight: maxEdge,
        imageQuality: quality,
        requestFullMetadata: false,
      );
      return f == null ? const [] : [await f.readAsBytes()];
    } on PlatformException catch (e) {
      throw _map(e, PhotoSourceKind.camera);
    } catch (_) {
      throw const PhotoPickFailed();
    }
  }

  @override
  Future<List<Uint8List>> fromGallery({required int limit}) async {
    try {
      if (limit <= 1) {
        final f = await _picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: maxEdge,
          maxHeight: maxEdge,
          imageQuality: quality,
          requestFullMetadata: false,
        );
        return f == null ? const [] : [await f.readAsBytes()];
      }
      final files = await _picker.pickMultiImage(
        maxWidth: maxEdge,
        maxHeight: maxEdge,
        imageQuality: quality,
        limit: limit,
        requestFullMetadata: false,
      );
      return [for (final f in files.take(limit)) await f.readAsBytes()];
    } on PlatformException catch (e) {
      throw _map(e, PhotoSourceKind.gallery);
    } catch (_) {
      throw const PhotoPickFailed();
    }
  }

  static Object _map(PlatformException e, PhotoSourceKind kind) {
    const denied = {
      'camera_access_denied',
      'photo_access_denied',
      'camera_access_restricted',
    };
    return denied.contains(e.code)
        ? PhotoPermissionDenied(kind)
        : const PhotoPickFailed();
  }
}

/// Content-based type check (the file name/extension is never trusted).
/// Returns the MIME type, or null when the bytes are not JPEG/PNG/WebP.
String? sniffImageType(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A) {
    return 'image/png';
  }
  if (b.length >= 12 &&
      String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
    return 'image/webp';
  }
  return null;
}

/// Why a picked photo was not added. [message] is safe to show.
String? photoProblem(Uint8List bytes, AiConfig config, {required int number}) {
  final mime = sniffImageType(bytes);
  if (mime == null || !config.acceptedTypes.contains(mime)) {
    return 'Photo $number is not a supported type. Use a JPEG, PNG or WebP photo.';
  }
  if (bytes.length > config.maxImageBytes) {
    return 'Photo $number is too large (${_mb(bytes.length)} MB; the limit is '
        '${_mb(config.maxImageBytes)} MB). Retake it or choose a smaller one.';
  }
  return null;
}

String _mb(int bytes) => (bytes / 1000000).toStringAsFixed(1);
