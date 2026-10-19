import 'dart:async';
import 'dart:io';

import 'package:care_plus_partner/data/firebase/technician_upload_service.dart';
import 'package:care_plus_partner/features/apply/application_uploads.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStorage implements StorageUploader {
  _FakeStorage({this.failWith, this.failKinds = const {}, this.gate});
  final Object? failWith;
  final Set<String> failKinds; // fail only paths ending with <kind>.<ext>
  final Completer<void>? gate;
  final paths = <String>[];
  final contentTypes = <String>[];
  @override
  Future<String> uploadFile(String path, File file, {required String contentType}) async {
    paths.add(path);
    contentTypes.add(contentType);
    if (gate != null) await gate!.future;
    final kind = path.split('/').last.split('.').first;
    if (failWith != null && (failKinds.isEmpty || failKinds.contains(kind))) throw failWith!;
    return 'https://storage.example/o/$kind';
  }
}

FirebaseException _fe(String code) =>
    FirebaseException(plugin: 'firebase_storage', code: code, message: 'secret path /uid-123/aadhar 1234 5678 9012');

late Directory tmp;
File img(String name, {int bytes = 10}) =>
    File('${tmp.path}/$name')..writeAsBytesSync(List.filled(bytes, 1));

TechnicianUploadService svc(_FakeStorage s, {String? uid = 'uid-123', bool ready = true}) =>
    TechnicianUploadService(storage: s, currentUid: () => uid, firebaseReady: () => ready);

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('uploads'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('TechnicianUploadService', () {
    test('successful upload goes to technician_applications/<uid>/<kind>.<ext> with an image type', () async {
      final s = _FakeStorage();
      final r = await svc(s).uploadResult(img('a.JPG'), kind: 'aadhar_document');
      expect(r.ok, isTrue);
      expect(s.paths.single, 'technician_applications/uid-123/aadhar_document.jpg');
      expect(s.contentTypes.single, 'image/jpeg');
    });

    test('permission denied is reported as denied with the code, not Firebase\'s message', () async {
      final r = await svc(_FakeStorage(failWith: _fe('unauthorized')))
          .uploadResult(img('a.jpg'), kind: 'aadhar_document');
      expect(r.ok, isFalse);
      expect(r.failure!.operation, 'aadhar_document');
      expect(r.failure!.code, 'unauthorized');
      expect(r.failure!.kind, UploadErrorKind.denied);
      expect(r.failure!.userMessage, isNot(contains('1234')));
      expect(r.failure!.userMessage, isNot(contains('uid-123')));
    });

    test('missing bucket / object-not-found is reported as storage not set up', () async {
      for (final code in ['bucket-not-found', 'object-not-found', 'project-not-found']) {
        final r = await svc(_FakeStorage(failWith: _fe(code))).uploadResult(img('a.png'), kind: 'photo');
        expect(r.failure!.kind, UploadErrorKind.storageMissing, reason: code);
        expect(r.failure!.userMessage, contains("isn't set up"));
      }
    });

    test('timeout and network failures are reported as network', () async {
      var r = await svc(_FakeStorage(failWith: TimeoutException('slow'))).uploadResult(img('a.jpg'), kind: 'pan_document');
      expect(r.failure!.kind, UploadErrorKind.network);
      expect(r.failure!.code, 'timeout');
      r = await svc(_FakeStorage(failWith: _fe('retry-limit-exceeded'))).uploadResult(img('a.jpg'), kind: 'pan_document');
      expect(r.failure!.kind, UploadErrorKind.network);
      r = await svc(_FakeStorage(failWith: const SocketException('x'))).uploadResult(img('a.jpg'), kind: 'pan_document');
      expect(r.failure!.kind, UploadErrorKind.network);
    });

    test('not signed in / Firebase missing / bad file never reach Storage', () async {
      final s = _FakeStorage();
      expect((await svc(s, uid: null).uploadResult(img('a.jpg'), kind: 'photo')).failure!.kind, UploadErrorKind.denied);
      expect((await svc(s, ready: false).uploadResult(img('a.jpg'), kind: 'photo')).failure!.kind, UploadErrorKind.storageMissing);
      expect((await svc(s).uploadResult(img('a.exe'), kind: 'photo')).failure!.code, 'invalid-file-type');
      expect((await svc(s).uploadResult(img('big.jpg', bytes: TechnicianUploadService.maxBytes + 1), kind: 'photo')).failure!.code, 'file-too-large');
      expect(s.paths, isEmpty);
    });

    test('unexpected error codes are sanitised', () async {
      final r = await svc(_FakeStorage(failWith: _fe('weird code with spaces and 9876543210')))
          .uploadResult(img('a.jpg'), kind: 'photo');
      expect(r.failure!.code, 'unknown');
    });
  });

  group('ApplicationUploader', () {
    PickedApplicationFiles all() => PickedApplicationFiles(
          photo: img('p.jpg'),
          aadharFront: img('f.jpg'),
          aadharBack: img('b.jpg'),
          pan: img('pan.jpg'),
        );

    test('all uploads succeed and URLs are returned', () async {
      final o = (await ApplicationUploader(svc(_FakeStorage())).run(all()))!;
      expect(o.canSubmit, isTrue);
      expect(o.aadharFrontUrl, isNotNull);
      expect(o.aadharBackUrl, isNotNull);
      expect(o.panUrl, isNotNull);
      expect(o.photoUrl, isNotNull);
      expect(o.photoWarning, isNull);
    });

    test('a required document failing blocks submission and names it', () async {
      final s = _FakeStorage(failWith: _fe('unauthorized'), failKinds: {'aadhar_document'});
      final o = (await ApplicationUploader(svc(s)).run(all()))!;
      expect(o.canSubmit, isFalse);
      expect(o.blocking!.operation, 'aadhar_document');
      expect(o.blocking!.code, 'unauthorized');
      // stopped at the first failure — nothing after it (incl. the photo) was sent
      expect(s.paths.length, 1);
    });

    test('optional photo failing does not block; documents still go through', () async {
      final s = _FakeStorage(failWith: _fe('object-not-found'), failKinds: {'photo'});
      final o = (await ApplicationUploader(svc(s)).run(all()))!;
      expect(o.canSubmit, isTrue);
      expect(o.photoUrl, isNull);
      expect(o.photoWarning!.operation, 'photo');
      expect(o.aadharFrontUrl, isNotNull);
      expect(o.panUrl, isNotNull);
    });

    test('everything failing because Storage is missing still blocks (documents are required)', () async {
      final o = (await ApplicationUploader(svc(_FakeStorage(failWith: _fe('bucket-not-found')))).run(all()))!;
      expect(o.canSubmit, isFalse);
      expect(o.blocking!.kind, UploadErrorKind.storageMissing);
    });

    test('nothing picked uploads nothing and can submit', () async {
      final s = _FakeStorage();
      final o = (await ApplicationUploader(svc(s)).run(const PickedApplicationFiles()))!;
      expect(o.canSubmit, isTrue);
      expect(s.paths, isEmpty);
    });

    test('repeated taps while uploading do not start a second upload', () async {
      final gate = Completer<void>();
      final s = _FakeStorage(gate: gate);
      final up = ApplicationUploader(svc(s));
      final files = PickedApplicationFiles(aadharFront: img('f.jpg'));
      final first = up.run(files);
      await Future<void>.delayed(Duration.zero);
      expect(up.running, isTrue);
      expect(await up.run(files), isNull); // ignored
      expect(await up.run(files), isNull);
      gate.complete();
      final o = await first;
      expect(o!.canSubmit, isTrue);
      expect(s.paths.length, 1); // uploaded once
      expect(up.running, isFalse);
      // and it can run again afterwards
      expect(await up.run(files), isNotNull);
    });
  });
}
