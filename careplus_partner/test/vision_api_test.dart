import 'dart:convert';
import 'dart:typed_data';

import 'package:care_plus_partner/data/api/vision_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

VisionApi _api(MockClient c, {String? token = 'tok'}) =>
    VisionApi(client: c, tokenProvider: () async => token);

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

final _photo = AiPhoto(
  bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]),
  mimeType: 'image/jpeg',
);

Map<String, dynamic> _job(String status, {Object? result, Object? error}) => {
  'id': 'AIN-1',
  'applianceId': 'KAPP-1',
  'bookingId': 'B-1',
  'status': status,
  'retryable': false,
  'attempts': 1,
  'imageCount': 1,
  'createdAt': 'x',
  'error': error,
  'result': result,
};

void main() {
  test(
    'submit posts base64 photos with the bearer token and the request id',
    () async {
      late http.Request seen;
      final api = _api(
        MockClient((req) async {
          seen = req;
          return _json(202, {'inspection': _job('queued')});
        }),
      );
      final r = await api.submit(
        'B-1',
        'KAPP-1',
        photos: [_photo],
        clientRequestId: 'req-12345678',
      );
      expect(r.ok, isTrue);
      expect(r.value!.status, AiJobStatus.queued);
      expect(seen.method, 'POST');
      expect(
        seen.url.path,
        '/api/technician/bookings/B-1/kitchen/appliances/KAPP-1/ai-inspections',
      );
      expect(seen.headers['Authorization'], 'Bearer tok');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['clientRequestId'], 'req-12345678');
      final img = (body['images'] as List).single as Map;
      expect(base64Decode(img['data'] as String), _photo.bytes);
      expect(img['mimeType'], 'image/jpeg');
      expect(body.keys.toSet(), {
        'images',
        'clientRequestId',
      }); // no keys, no extras
    },
  );

  test('no token: sign-in failure and no request is sent', () async {
    var called = false;
    final api = _api(
      MockClient((_) async {
        called = true;
        return _json(200, {});
      }),
      token: null,
    );
    final r = await api.submit(
      'B-1',
      'KAPP-1',
      photos: [_photo],
      clientRequestId: 'req-12345678',
    );
    expect(called, isFalse);
    expect(r.failure!.signedOut, isTrue);
  });

  test('a replayed request id (200) returns the existing job', () async {
    final api = _api(
      MockClient((_) async => _json(200, {'inspection': _job('running')})),
    );
    final r = await api.submit(
      'B-1',
      'KAPP-1',
      photos: [_photo],
      clientRequestId: 'req-12345678',
    );
    expect(r.value!.status, AiJobStatus.running);
  });

  test(
    'image rejection keeps the server message and the photo index',
    () async {
      final api = _api(
        MockClient(
          (_) async => _json(400, {
            'error': 'Invalid request',
            'code': 'image_too_large',
            'message': 'Image is too large.',
            'imageIndex': 1,
          }),
        ),
      );
      final f = (await api.submit(
        'B-1',
        'KAPP-1',
        photos: [_photo],
        clientRequestId: 'req-12345678',
      )).failure!;
      expect(f.message, 'Image is too large.');
      expect(f.imageIndex, 1);
      expect(f.status, 400);
      expect(f.networkError, isFalse);
    },
  );

  test('503 and 429 surface the server message', () async {
    final a = _api(
      MockClient(
        (_) async => _json(503, {
          'code': 'ai_unavailable',
          'message': 'AI inspection is not available right now.',
        }),
      ),
    );
    final f = (await a.submit(
      'B-1',
      'K',
      photos: [_photo],
      clientRequestId: 'req-12345678',
    )).failure!;
    expect(f.unavailable, isTrue);
    expect(f.code, 'ai_unavailable');
    final b = _api(
      MockClient(
        (_) async =>
            _json(429, {'code': 'visit_limit', 'message': 'Limit reached.'}),
      ),
    );
    expect(
      (await b.submit(
        'B-1',
        'K',
        photos: [_photo],
        clientRequestId: 'req-12345678',
      )).failure!.message,
      'Limit reached.',
    );
  });

  test('a transport error is a network failure (outcome unknown)', () async {
    final api = _api(
      MockClient((_) async => throw http.ClientException('boom')),
    );
    final f = (await api.submit(
      'B-1',
      'K',
      photos: [_photo],
      clientRequestId: 'req-12345678',
    )).failure!;
    expect(f.networkError, isTrue);
    expect(f.message, contains('Could not reach the server'));
  });

  test('config is disabled unless the server says enabled: true', () async {
    final off = await _api(
      MockClient((_) async => _json(200, {'enabled': 'yes'})),
    ).config();
    expect(off.value!.enabled, isFalse);
    final on = await _api(
      MockClient(
        (_) async => _json(200, {
          'enabled': true,
          'minImages': 1,
          'maxImages': 5,
          'maxImageBytes': 1500000,
          'maxTotalBytes': 6000000,
          'acceptedTypes': ['image/jpeg'],
          'privacyNotice': 'Keep it clean.',
        }),
      ),
    ).config();
    expect(on.value!.enabled, isTrue);
    expect(on.value!.maxImages, 5);
    expect(on.value!.privacyNotice, 'Keep it clean.');
  });

  test('status parses a completed result, dropping malformed pieces', () async {
    final api = _api(
      MockClient(
        (_) async => _json(200, {
          'inspection': _job(
            'completed',
            result: {
              'applianceProfile': 'Hob',
              'summary': 's',
              'conditionScore': 85,
              'findings': [
                {
                  'label': 'Grease',
                  'severity': 'low',
                  'confidence': 0.9,
                  'evidence': 'e',
                  'photoIndexes': [0, -1, 'x'],
                  'safetyRelevant': true,
                },
                {'severity': 'high'}, // no label: dropped
                'junk',
              ],
              'technicianReview': {
                'messages': ['review me', 5],
              },
              'limitations': ['a', 3],
              'accepted': false,
              'usedInHealthScore': false,
            },
          ),
        }),
      ),
    );
    final job = (await api.status('B-1', 'K', 'AIN-1')).value!;
    final r = job.result!;
    expect(r.findings.single.label, 'Grease');
    expect(r.findings.single.photoIndexes, [0]);
    expect(r.findings.single.safetyRelevant, isTrue);
    expect(r.reviewMessages, ['review me']);
    expect(r.limitations, ['a']);
    expect(r.usedInHealthScore, isFalse);
  });

  test('completed without an object result is flagged malformed', () async {
    final job = (await _api(
      MockClient((_) async => _json(200, {'inspection': _job('completed')})),
    ).status('B-1', 'K', 'AIN-1')).value!;
    expect(job.result, isNull);
    expect(job.resultMalformed, isTrue);
  });

  test(
    'failed/rejected carry the server error; unknown status is not guessed',
    () async {
      final f = (await _api(
        MockClient(
          (_) async => _json(200, {
            'inspection': _job(
              'rejected',
              error: {'code': 'x', 'message': 'Rejected.'},
            ),
          }),
        ),
      ).status('B-1', 'K', 'AIN-1')).value!;
      expect(f.status, AiJobStatus.rejected);
      expect(f.errorMessage, 'Rejected.');
      final u = (await _api(
        MockClient((_) async => _json(200, {'inspection': _job('exploded')})),
      ).status('B-1', 'K', 'AIN-1')).value!;
      expect(u.status, AiJobStatus.unknown);
      expect(u.status.inProgress, isFalse);
    },
  );

  test('a reply with no inspection id is an error, not a job', () async {
    final r = await _api(
      MockClient(
        (_) async => _json(200, {
          'inspection': {'status': 'queued'},
        }),
      ),
    ).status('B-1', 'K', 'AIN-1');
    expect(r.ok, isFalse);
  });
}
