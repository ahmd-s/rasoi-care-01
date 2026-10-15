import 'dart:async';
import 'dart:typed_data';

import 'package:care_plus_partner/core/theme/care_plus_theme.dart';
import 'package:care_plus_partner/data/api/passport_api.dart';
import 'package:care_plus_partner/data/api/vision_api.dart';
import 'package:care_plus_partner/features/passport/ai_inspection_screen.dart';
import 'package:care_plus_partner/features/passport/inspection_catalog.dart';
import 'package:care_plus_partner/features/passport/photo_source.dart';
import 'package:care_plus_partner/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:care_plus_partner/features/passport/inspection_screen.dart';

const _hob = KitchenAppliance(
  id: 'KAPP-1',
  category: 'hob',
  brand: 'Elica',
  model: 'Flexi 4B',
  serialNumber: '',
  installYear: null,
  specs: {},
  notes: '',
);

Uint8List _jpeg(int n, {int size = 300}) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, n, ...List.filled(size, n)]);

AiConfig _config({
  bool enabled = true,
  int maxImages = 3,
  int maxImageBytes = 1000,
}) => AiConfig(
  enabled: enabled,
  minImages: 1,
  maxImages: maxImages,
  maxImageBytes: maxImageBytes,
  maxTotalBytes: 2500,
  acceptedTypes: const ['image/jpeg', 'image/png'],
  recommendedLongEdgePx: 1280,
  recommendedJpegQuality: 80,
  maxSubmissionsPerVisit: 3,
  privacyNotice: 'Keep people and documents out of frame.',
);

AiInspection _job(
  String status, {
  String id = 'AIN-1',
  Map<String, dynamic>? result,
  bool retryable = false,
  String? error,
}) => AiInspection.tryParse({
  'id': id,
  'status': status,
  'retryable': retryable,
  'imageCount': 1,
  'error': error == null ? null : {'code': 'x', 'message': error},
  'result': result,
})!;

Map<String, dynamic> _result({
  List<Map<String, dynamic>> findings = const [],
  int? score = 85,
}) => {
  'applianceProfile': 'Hob / Cooktop',
  'summary': 'Summary from server.',
  'conditionScore': score,
  'scoreRationale': 'Computed by the server.',
  'findings': findings,
  'urgency': 'soon',
  'recommendation': 'Review the visible items.',
  'limitations': ['Photos cannot show internal faults.'],
  'notAssessableChecks': ['Gas flow'],
  'technicianReview': {
    'required': true,
    'messages': ['AI results are advisory.'],
  },
  'photosAnalyzed': 1,
  'visibility': 'adequate',
  'disclaimer': 'AI visual assessment of photos only.',
  'accepted': false,
  'usedInHealthScore': false,
};

const _safetyFinding = {
  'code': 'burner_blocked',
  'label': 'Blocked burner port',
  'severity': 'high',
  'confidence': 0.88,
  'evidence': 'Residue covers the burner ports in photo 1.',
  'photoIndexes': [0],
  'safetyRelevant': true,
  'recommendation': 'Clean and verify.',
};

class _FakeVision extends VisionApi {
  _FakeVision({AiConfig? config, this.configFailure})
    : config_ = config ?? _config(),
      super(tokenProvider: () async => 't');

  final AiConfig config_;
  final AiFailure? configFailure;
  List<AiInspection> existing = [];
  final submits = <({List<AiPhoto> photos, String id})>[];
  final statusCalls = <String>[];
  final submitResults = <AiResultOf<AiInspection>>[];
  Completer<AiResultOf<AiInspection>>? submitGate;
  final statusResults = <AiResultOf<AiInspection>>[];

  @override
  Future<AiResultOf<AiConfig>> config() async => configFailure != null
      ? AiResultOf.fail(configFailure)
      : AiResultOf.ok(config_);

  @override
  Future<AiResultOf<List<AiInspection>>> list(String b, String a) async =>
      AiResultOf.ok(existing);

  @override
  Future<AiResultOf<AiInspection>> submit(
    String b,
    String a, {
    required List<AiPhoto> photos,
    required String clientRequestId,
  }) {
    submits.add((photos: photos, id: clientRequestId));
    if (submitGate != null) return submitGate!.future;
    return Future.value(submitResults.removeAt(0));
  }

  @override
  Future<AiResultOf<AiInspection>> status(String b, String a, String id) async {
    statusCalls.add(id);
    return statusResults.removeAt(0);
  }
}

class _FakeCamera implements PhotoSource {
  final cameraQueue = <List<Uint8List>>[];
  final galleryQueue = <List<Uint8List>>[];
  Object? cameraError;
  var cameraCalls = 0;
  var galleryCalls = 0;
  int? lastLimit;

  @override
  Future<List<Uint8List>> fromCamera() async {
    cameraCalls++;
    if (cameraError != null) throw cameraError!;
    return cameraQueue.isEmpty ? const [] : cameraQueue.removeAt(0);
  }

  @override
  Future<List<Uint8List>> fromGallery({required int limit}) async {
    galleryCalls++;
    lastLimit = limit;
    return galleryQueue.isEmpty ? const [] : galleryQueue.removeAt(0);
  }
}

class _CountingPassport extends PassportApi {
  _CountingPassport() : super(tokenProvider: () async => 't');
  var calls = 0;
  @override
  Future<PassportResult<Inspection>> inspectionFor(String b, String a) async =>
      const PassportResult.ok(
        Inspection(applianceId: 'KAPP-1', category: 'hob', checks: []),
      );

  @override
  Future<PassportResult<HealthAssessment>> applianceHealth(
    String b,
    String a,
  ) async {
    calls++;
    return const PassportResult.failure('n/a');
  }

  @override
  Future<PassportResult<Inspection>> saveInspection(
    String b,
    String a,
    List<({String key, InspectionResult result, String note})> r,
  ) async {
    calls++;
    return const PassportResult.failure('n/a');
  }
}

Future<void> _pump(
  WidgetTester tester,
  _FakeVision api,
  _FakeCamera cam, {
  _CountingPassport? passport,
  Size size = const Size(360, 800),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        visionApiProvider.overrideWithValue(api),
        photoSourceProvider.overrideWithValue(cam),
        if (passport != null) passportApiProvider.overrideWithValue(passport),
      ],
      child: MaterialApp(
        theme: CarePlusTheme.light(),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(
            c,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const AiInspectionScreen(jobId: 'B-1', appliance: _hob),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _take(
  WidgetTester tester,
  _FakeCamera cam,
  Uint8List photo,
) async {
  cam.cameraQueue.add([photo]);
  await tester.tap(find.text('Take photo'));
  await tester.pumpAndSettle();
}

Finder get _analyse => find.byType(FilledButton);

void main() {
  testWidgets('disabled AI: explains it is unavailable and offers no capture', (
    tester,
  ) async {
    await _pump(
      tester,
      _FakeVision(config: _config(enabled: false)),
      _FakeCamera(),
    );
    expect(find.text('AI photo inspection is not available'), findsOneWidget);
    expect(find.text('Take photo'), findsNothing);
    expect(find.textContaining('scores are unchanged'), findsOneWidget);
  });

  testWidgets('config failure shows a retry', (tester) async {
    await _pump(
      tester,
      _FakeVision(
        configFailure: const AiFailure(
          'Could not reach the server.',
          networkError: true,
        ),
      ),
      _FakeCamera(),
    );
    expect(find.text('Could not reach the server.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('shows the privacy notice and nothing uploads before Analyse', (
    tester,
  ) async {
    final api = _FakeVision();
    final cam = _FakeCamera();
    await _pump(tester, api, cam);
    expect(
      find.text('Keep people and documents out of frame.'),
      findsOneWidget,
    );
    await _take(tester, cam, _jpeg(1));
    expect(find.text('1 of 3 photos selected'), findsOneWidget);
    expect(api.submits, isEmpty);
  });

  testWidgets('camera and gallery add previews; a photo can be removed', (
    tester,
  ) async {
    final api = _FakeVision();
    final cam = _FakeCamera();
    await _pump(tester, api, cam);
    cam.galleryQueue.add([_jpeg(2), _jpeg(3)]);
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();
    await _take(tester, cam, _jpeg(1));
    expect(cam.lastLimit, 3);
    expect(find.text('3 of 3 photos selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-photo-2')), findsOneWidget);
    // Full: both pickers are disabled.
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Take photo'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('ai-remove-2')));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3 photos selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-photo-2')), findsNothing);
    expect(api.submits, isEmpty);
  });

  testWidgets(
    'rejects unsupported, oversized and duplicate photos with a message',
    (tester) async {
      final cam = _FakeCamera();
      await _pump(tester, _FakeVision(), cam);
      await _take(
        tester,
        cam,
        Uint8List.fromList(List.filled(300, 7)),
      ); // not an image
      expect(find.textContaining('not a supported type'), findsOneWidget);
      await _take(tester, cam, _jpeg(1, size: 2000)); // > 1000 bytes
      expect(find.textContaining('too large'), findsOneWidget);
      await _take(tester, cam, _jpeg(1));
      await _take(tester, cam, _jpeg(1));
      expect(find.text('That photo is already added.'), findsOneWidget);
      expect(find.text('1 of 3 photos selected'), findsOneWidget);
    },
  );

  testWidgets('permission denial is explained, not thrown', (tester) async {
    final cam = _FakeCamera()
      ..cameraError = const PhotoPermissionDenied(PhotoSourceKind.camera);
    await _pump(tester, _FakeVision(), cam);
    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Camera access is off'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('0 of 3 photos selected'), findsOneWidget);
  });

  testWidgets(
    'Analyse is disabled with no photos; a fast double tap submits once',
    (tester) async {
      final api = _FakeVision()..submitGate = Completer();
      final cam = _FakeCamera();
      await _pump(tester, api, cam);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await _take(tester, cam, _jpeg(1));
      await tester.tap(_analyse);
      await tester.tap(_analyse, warnIfMissed: false);
      await tester.pump();
      expect(api.submits, hasLength(1));
      expect(api.submits.single.photos, hasLength(1));
      expect(api.submits.single.photos.single.mimeType, 'image/jpeg');
      expect(api.submits.single.id, hasLength(greaterThanOrEqualTo(8)));
      // Controls are locked while the upload is in flight.
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Take photo'),
            )
            .onPressed,
        isNull,
      );
      api.submitGate!.complete(AiResultOf.ok(_job('queued')));
      api.statusResults.add(AiResultOf.ok(_job('queued')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('ai-progress-title')), findsOneWidget);
      // Unmount to cancel the poll timer.
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'submit error is shown with the photo number; retry after 4xx uses a new id',
    (tester) async {
      final api = _FakeVision()
        ..submitResults.add(
          const AiResultOf.fail(
            AiFailure(
              'Image is too large.',
              status: 400,
              code: 'image_too_large',
              imageIndex: 0,
            ),
          ),
        );
      final cam = _FakeCamera();
      await _pump(tester, api, cam);
      await _take(tester, cam, _jpeg(1));
      await tester.tap(_analyse);
      await tester.pumpAndSettle();
      expect(find.text('Photo 1: Image is too large.'), findsOneWidget);
      expect(find.textContaining('same request is reused'), findsNothing);
      api.submitResults.add(
        const AiResultOf.fail(AiFailure('Limit.', status: 429)),
      );
      await tester.tap(_analyse);
      await tester.pumpAndSettle();
      expect(api.submits[0].id, isNot(api.submits[1].id));
    },
  );

  testWidgets('after a network failure the same request id is reused', (
    tester,
  ) async {
    final api = _FakeVision()
      ..submitResults.add(
        const AiResultOf.fail(
          AiFailure('Could not reach the server.', networkError: true),
        ),
      );
    final cam = _FakeCamera();
    await _pump(tester, api, cam);
    await _take(tester, cam, _jpeg(1));
    await tester.tap(_analyse);
    await tester.pumpAndSettle();
    expect(find.textContaining('will not be analysed twice'), findsOneWidget);
    api.submitResults.add(
      const AiResultOf.fail(
        AiFailure('Could not reach the server.', networkError: true),
      ),
    );
    await tester.tap(_analyse);
    await tester.pumpAndSettle();
    expect(api.submits[0].id, api.submits[1].id);
    // Changing the photos starts a new request.
    await _take(tester, cam, _jpeg(2));
    api.submitResults.add(
      const AiResultOf.fail(AiFailure('x', networkError: true)),
    );
    await tester.tap(_analyse);
    await tester.pumpAndSettle();
    expect(api.submits[2].id, isNot(api.submits[0].id));
  });

  testWidgets(
    'queued → running → completed; polling stops at the terminal state',
    (tester) async {
      final api = _FakeVision()
        ..submitResults.add(AiResultOf.ok(_job('queued')))
        ..statusResults.addAll([
          AiResultOf.ok(_job('running')),
          AiResultOf.ok(
            _job('completed', result: _result(findings: [_safetyFinding])),
          ),
        ]);
      final cam = _FakeCamera();
      final passport = _CountingPassport();
      await _pump(tester, api, cam, passport: passport);
      await _take(tester, cam, _jpeg(1));
      await tester.tap(_analyse);
      await tester.pump();
      expect(find.text('Waiting to start…'), findsOneWidget);
      expect(find.textContaining('not finished yet'), findsOneWidget);
      expect(
        find.text('Summary from server.'),
        findsNothing,
      ); // no result before confirmation
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('Analysing your photos…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(api.statusCalls, hasLength(2));
      expect(find.text('Summary from server.'), findsOneWidget);
      // No further polling once completed.
      await tester.pump(const Duration(minutes: 2));
      expect(api.statusCalls, hasLength(2));
      // Evidence, severity, confidence, photo refs.
      expect(find.text('Blocked burner port'), findsOneWidget);
      expect(
        find.textContaining('Residue covers the burner ports'),
        findsOneWidget,
      );
      expect(find.text('High severity'), findsOneWidget);
      expect(find.text('Confidence 88%'), findsOneWidget);
      expect(find.text('Seen in photo 1'), findsOneWidget);
      // Safety stays visible and flagged for the technician.
      expect(
        find.textContaining('Visible safety-relevant item reported'),
        findsOneWidget,
      );
      expect(find.text('Safety — verify in person'), findsOneWidget);
      expect(find.text('AI results are advisory.'), findsOneWidget);
      // The AI score is shown only as visual-only, and never touches the health/checklist API.
      expect(
        find.textContaining('Visual score (photos only): 85/100'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('ai-score-not-used')), findsOneWidget);
      expect(passport.calls, 0);
      // Read-only: no accept / edit / reject controls.
      for (final label in ['Accept', 'Reject', 'Edit', 'Approve', 'Save']) {
        expect(find.widgetWithText(FilledButton, label), findsNothing);
        expect(find.widgetWithText(OutlinedButton, label), findsNothing);
        expect(find.widgetWithText(TextButton, label), findsNothing);
      }
      expect(find.byKey(const ValueKey('ai-read-only-note')), findsOneWidget);
    },
  );

  testWidgets(
    'completed with no findings says so without claiming the appliance is fine',
    (tester) async {
      final api = _FakeVision()
        ..submitResults.add(
          AiResultOf.ok(_job('completed', result: _result())),
        );
      final cam = _FakeCamera();
      await _pump(tester, api, cam);
      await _take(tester, cam, _jpeg(1));
      await tester.tap(_analyse);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-no-findings')), findsOneWidget);
      expect(find.textContaining('does not rule out'), findsOneWidget);
      expect(
        find.text('Photos cannot show internal faults.'),
        findsNothing,
      ); // below the fold is fine
    },
  );

  testWidgets(
    'malformed completed result shows an error, not a fabricated result',
    (tester) async {
      final api = _FakeVision()
        ..submitResults.add(AiResultOf.ok(_job('completed')));
      final cam = _FakeCamera();
      await _pump(tester, api, cam);
      await _take(tester, cam, _jpeg(1));
      await tester.tap(_analyse);
      await tester.pumpAndSettle();
      expect(find.text('The result could not be shown'), findsOneWidget);
    },
  );

  testWidgets('sparse result with missing fields renders safely', (
    tester,
  ) async {
    final api = _FakeVision()
      ..submitResults.add(
        AiResultOf.ok(
          AiInspection.tryParse({
            'id': 'AIN-1',
            'status': 'completed',
            'result': {
              'findings': [
                {'label': '<b>Bold</b> label'},
              ],
            },
          })!,
        ),
      );
    final cam = _FakeCamera();
    await _pump(tester, api, cam);
    await _take(tester, cam, _jpeg(1));
    await tester.tap(_analyse);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.text('<b>Bold</b> label'),
      findsOneWidget,
    ); // plain text, never markup
    expect(find.text('Visual score: none'), findsOneWidget);
    expect(find.textContaining('advisory'), findsWidgets);
  });

  testWidgets(
    'failed job: server message, explicit retry keeps photos and uses a new id',
    (tester) async {
      final api = _FakeVision()
        ..submitResults.addAll([
          AiResultOf.ok(_job('queued')),
          AiResultOf.ok(_job('queued', id: 'AIN-2')),
        ])
        ..statusResults.addAll([
          AiResultOf.ok(
            _job(
              'failed',
              retryable: true,
              error: 'The AI service failed. Please try again later.',
            ),
          ),
          AiResultOf.ok(_job('completed', id: 'AIN-2', result: _result())),
        ]);
      final cam = _FakeCamera();
      await _pump(tester, api, cam);
      await _take(tester, cam, _jpeg(1));
      await tester.tap(_analyse);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('The analysis did not finish'), findsOneWidget);
      expect(
        find.text('The AI service failed. Please try again later.'),
        findsOneWidget,
      );
      expect(find.textContaining('another analysis'), findsOneWidget);
      expect(api.submits, hasLength(1)); // no automatic resubmission
      await tester.pump(const Duration(minutes: 1));
      expect(api.statusCalls, hasLength(1)); // polling stopped
      await tester.tap(find.text('Review photos and try again'));
      await tester.pumpAndSettle();
      expect(find.text('1 of 3 photos selected'), findsOneWidget);
      expect(api.submits, hasLength(1)); // still explicit
      await tester.tap(_analyse);
      await tester.pumpAndSettle();
      expect(api.submits, hasLength(2));
      expect(api.submits[1].id, isNot(api.submits[0].id));
    },
  );

  testWidgets('rejected job explains that nothing from the answer is shown', (
    tester,
  ) async {
    final api = _FakeVision()
      ..submitResults.add(
        AiResultOf.ok(
          _job('rejected', retryable: true, error: 'Answer failed checks.'),
        ),
      );
    final cam = _FakeCamera();
    await _pump(tester, api, cam);
    await _take(tester, cam, _jpeg(1));
    await tester.tap(_analyse);
    await tester.pumpAndSettle();
    expect(find.text('The AI answer was rejected'), findsOneWidget);
    expect(find.textContaining('none of it is shown'), findsOneWidget);
  });

  testWidgets(
    'connectivity loss while polling: shows offline, then stops and offers Check again',
    (tester) async {
      const net = AiFailure('Could not reach the server.', networkError: true);
      final api = _FakeVision()
        ..submitResults.add(AiResultOf.ok(_job('queued')))
        ..statusResults.addAll([
          const AiResultOf.fail(net),
          const AiResultOf.fail(net),
          const AiResultOf.fail(net),
          AiResultOf.ok(_job('completed', result: _result())),
        ]);
      final cam = _FakeCamera();
      await _pump(tester, api, cam);
      await _take(tester, cam, _jpeg(1));
      await tester.tap(_analyse);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const ValueKey('ai-offline')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const ValueKey('ai-poll-stopped')), findsOneWidget);
      expect(api.statusCalls, hasLength(3));
      await tester.pump(const Duration(minutes: 1));
      expect(api.statusCalls, hasLength(3)); // not hammering a dead connection
      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();
      expect(find.text('Summary from server.'), findsOneWidget);
    },
  );

  testWidgets(
    'a job still running from an earlier visit to the screen is resumed, not duplicated',
    (tester) async {
      final api = _FakeVision()
        ..existing = [_job('running')]
        ..statusResults.add(
          AiResultOf.ok(_job('completed', result: _result())),
        );
      await _pump(tester, api, _FakeCamera());
      expect(api.submits, isEmpty);
      await tester.pumpAndSettle();
      expect(find.text('Summary from server.'), findsOneWidget);
    },
  );

  testWidgets('fits a small screen with large text', (tester) async {
    final cam = _FakeCamera();
    await _pump(
      tester,
      _FakeVision(),
      cam,
      size: const Size(320, 568),
      textScale: 1.5,
    );
    await tester.scrollUntilVisible(
      find.text('Take photo'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -80));
    await tester.pumpAndSettle();
    await _take(tester, cam, _jpeg(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'polling gives up after the maximum number of checks and offers Check again',
    (tester) async {
      final api = _FakeVision()
        ..submitResults.add(AiResultOf.ok(_job('queued')))
        ..statusResults.addAll([
          for (var i = 0; i < maxPolls + 20; i++)
            AiResultOf.ok(_job('running')),
        ]);
      final cam = _FakeCamera();
      await _pump(tester, api, cam);
      await _take(tester, cam, _jpeg(1));
      await tester.tap(_analyse);
      await tester.pump();
      for (var i = 0; i < maxPolls * 2; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      expect(api.statusCalls.length, maxPolls);
      expect(find.byKey(const ValueKey('ai-poll-stopped')), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
    },
  );

  testWidgets(
    'the checklist screen links to photo inspection for the same appliance',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                const InspectionScreen(jobId: 'B-1', appliance: _hob),
          ),
          GoRoute(
            path: '/tech/job/:id/kitchen/appliance/:aid/ai-inspection',
            builder: (_, s) => Text(
              'AI ${s.pathParameters['id']} ${s.pathParameters['aid']} '
              '${(s.extra as KitchenAppliance).brand}',
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            passportApiProvider.overrideWithValue(_CountingPassport()),
          ],
          child: MaterialApp.router(
            theme: CarePlusTheme.light(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('open-ai-inspection')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('AI B-1 KAPP-1 Elica'), findsOneWidget);
    },
  );
}
