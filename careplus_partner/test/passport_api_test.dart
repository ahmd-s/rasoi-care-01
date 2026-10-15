import 'dart:convert';

import 'package:care_plus_partner/data/api/passport_api.dart';
import 'package:care_plus_partner/features/passport/inspection_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

PassportApi _api(MockClient c, {String? token = 'tok'}) =>
    PassportApi(client: c, tokenProvider: () async => token);

http.Response _json(int status, Object body) => http.Response(jsonEncode(body), status,
    headers: {'content-type': 'application/json'});

void main() {
  test('kitchenFor parses appliances and sends the bearer token', () async {
    late http.BaseRequest seen;
    final api = _api(MockClient((req) async {
      seen = req;
      return _json(200, {
        'appliances': [
          {
            'id': 'KAPP-1', 'category': 'hob', 'brand': 'Elica', 'model': '',
            'serialNumber': '', 'installYear': 2021,
            'specs': {'fuel': 'gas', 'burners': 4}, 'notes': '',
          },
        ],
      });
    }));
    final r = await api.kitchenFor('B-1');
    expect(r.ok, isTrue);
    expect(r.value!.single.brand, 'Elica');
    expect(r.value!.single.specs['burners'], 4);
    expect(seen.url.path, '/api/technician/bookings/B-1/kitchen');
    expect(seen.headers['Authorization'], 'Bearer tok');
  });

  test('no token means a sign-in message and no request', () async {
    var called = false;
    final api = _api(MockClient((_) async {
      called = true;
      return _json(200, {});
    }), token: null);
    final r = await api.kitchenFor('B-1');
    expect(r.ok, isFalse);
    expect(r.error, contains('Sign in'));
    expect(called, isFalse);
  });

  test('register posts the payload and returns the created appliance', () async {
    late http.Request seen;
    final api = _api(MockClient((req) async {
      seen = req;
      return _json(201, {
        'id': 'KAPP-2', 'category': 'hob', 'brand': 'Elica',
        'specs': {'fuel': 'gas', 'burners': 4},
      });
    }));
    final r = await api.register('B-1', {'category': 'hob', 'brand': 'Elica'});
    expect(r.ok, isTrue);
    expect(r.value!.id, 'KAPP-2');
    expect(seen.method, 'POST');
    expect(seen.url.path, '/api/technician/bookings/B-1/kitchen/appliances');
    expect(jsonDecode(seen.body), {'category': 'hob', 'brand': 'Elica'});
  });

  test('validation errors surface the server field messages', () async {
    final api = _api(MockClient((_) async => _json(400, {
          'error': 'Invalid request',
          'fields': {'specs.fuel': 'is required'},
        })));
    final r = await api.register('B-1', {});
    expect(r.ok, isFalse);
    expect(r.error, 'specs.fuel: is required');
  });

  test('404 reads as no longer assigned; 401 as sign in', () async {
    expect((await _api(MockClient((_) async => _json(404, {'error': 'not found'})))
            .kitchenFor('B-1'))
        .error, contains('no longer assigned'));
    expect((await _api(MockClient((_) async => _json(401, {}))).kitchenFor('B-1')).error,
        contains('Sign in'));
  });

  test('network failure is reported, not thrown', () async {
    final api = _api(MockClient((_) async => throw http.ClientException('down')));
    final r = await api.kitchenFor('B-1');
    expect(r.ok, isFalse);
    expect(r.error, contains('Could not reach'));
  });

  test('customBrands returns names for the category', () async {
    late http.BaseRequest seen;
    final api = _api(MockClient((req) async {
      seen = req;
      return _json(200, {
        'brands': [
          {'id': 'b1', 'category': 'chimney', 'name': 'Nova Air'},
        ],
      });
    }));
    final r = await api.customBrands('chimney');
    expect(r.value, ['Nova Air']);
    expect(seen.url.queryParameters['category'], 'chimney');
  });

  test('addCustomBrand distinguishes created from existing', () async {
    final created = await _api(MockClient((_) async =>
            _json(201, {'id': 'b1', 'category': 'hob', 'name': 'Nova'})))
        .addCustomBrand('hob', 'Nova');
    expect(created.ok && created.created, isTrue);
    final existing = await _api(MockClient((_) async =>
            _json(200, {'id': 'b1', 'category': 'hob', 'name': 'Nova'})))
        .addCustomBrand('hob', 'nova');
    expect(existing.ok, isTrue);
    expect(existing.created, isFalse);
    expect(existing.value, 'Nova');
  });

  test('register treats 200 as an existing record (retry) and 409 as a message', () async {
    final replay = await _api(MockClient((_) async =>
            _json(200, {'id': 'KAPP-1', 'category': 'hob', 'brand': 'Elica', 'specs': {}})))
        .register('B-1', {});
    expect(replay.ok, isTrue);
    expect(replay.created, isFalse);

    final dup = await _api(MockClient((_) async => _json(409, {
          'error': 'Conflict',
          'code': 'duplicate_appliance',
          'message': 'An appliance with this serial number is already registered for this customer.',
        }))).register('B-1', {});
    expect(dup.ok, isFalse);
    expect(dup.error, contains('serial number is already registered'));
  });

  group('inspection', () {
    final body = {
      'applianceId': 'KAPP-1',
      'category': 'hob',
      'bookingId': 'B-1',
      'checks': [
        {'key': 'ignition', 'label': 'Ignition', 'result': 'attention', 'note': 'slow', 'updatedAt': 't'},
        {'key': 'gas_flow', 'label': 'Gas flow', 'result': null, 'note': '', 'updatedAt': null},
      ],
    };

    test('inspectionFor maps results, leaving unrecorded items null', () async {
      late http.BaseRequest seen;
      final r = await _api(MockClient((req) async {
        seen = req;
        return _json(200, body);
      })).inspectionFor('B-1', 'KAPP-1');
      expect(r.ok, isTrue);
      expect(seen.method, 'GET');
      expect(seen.url.path, '/api/technician/bookings/B-1/kitchen/appliances/KAPP-1/inspection');
      final checks = r.value!.checks;
      expect(checks[0].result, InspectionResult.attention);
      expect(checks[0].note, 'slow');
      expect(checks[1].result, isNull);
      expect(r.value!.category, 'hob');
    });

    test('saveInspection PUTs wire values and omits empty notes', () async {
      late http.Request seen;
      final r = await _api(MockClient((req) async {
        seen = req;
        return _json(200, body);
      })).saveInspection('B-1', 'KAPP-1', [
        (key: 'ignition', result: InspectionResult.attention, note: 'slow'),
        (key: 'gas_flow', result: InspectionResult.good, note: ''),
      ]);
      expect(r.ok, isTrue);
      expect(seen.method, 'PUT');
      expect(jsonDecode(seen.body), {
        'results': [
          {'key': 'ignition', 'result': 'attention', 'note': 'slow'},
          {'key': 'gas_flow', 'result': 'good'},
        ],
      });
      expect(seen.headers['Authorization'], 'Bearer tok');
    });

    test('closed booking, not found and validation errors surface a message', () async {
      final closed = await _api(MockClient((_) async => _json(409, {
            'error': 'Conflict',
            'code': 'booking_closed',
            'message': 'This booking is completed; appliances can no longer be registered on it.',
          }))).saveInspection('B-1', 'KAPP-1', [
        (key: 'ignition', result: InspectionResult.good, note: ''),
      ]);
      expect(closed.ok, isFalse);
      expect(closed.error, contains('completed'));

      final missing = await _api(MockClient((_) async => _json(404, {'error': 'not found'})))
          .inspectionFor('B-1', 'KAPP-9');
      expect(missing.error, contains('no longer assigned'));

      final invalid = await _api(MockClient((_) async => _json(400, {
            'error': 'Invalid request',
            'fields': {'results[0].result': 'must be one of: good, attention, not_tested'},
          }))).saveInspection('B-1', 'KAPP-1', [
        (key: 'ignition', result: InspectionResult.good, note: ''),
      ]);
      expect(invalid.error, contains('results[0].result'));
    });
  });

  group('health', () {
    final scored = {
      'applianceId': 'KAPP-1',
      'technicianScore': 85,
      'scoreStatus': 'healthy',
      'status': 'attention',
      'statusLabel': 'Attention',
      'coverage': {'tested': 8, 'total': 8, 'label': '8 of 8 checks tested'},
      'safetyFlagged': true,
      'safetyWarning': 'Safety item flagged',
      'safetyFlaggedItems': ['Safety'],
      'flaggedItems': [
        {'key': 'safety', 'label': 'Safety', 'note': 'loose hose'},
      ],
      'message': null,
      'explanation': ['Technician assessment only. Vision AI inspection is not available yet.'],
      'aiScore': null,
      'combinedScore': null,
      'scoreBasisLabel': 'Technician assessment only',
      'disclaimer': 'Operational guidance, not a certification or a diagnosis of hidden faults.',
    };

    test('applianceHealth maps score, held status, safety and null AI fields', () async {
      late http.BaseRequest seen;
      final r = await _api(MockClient((req) async {
        seen = req;
        return _json(200, scored);
      })).applianceHealth('B-1', 'KAPP-1');
      expect(seen.url.path, '/api/technician/bookings/B-1/kitchen/appliances/KAPP-1/health');
      final h = r.value!;
      expect(h.score, 85);
      expect(h.status, 'attention'); // held below Healthy by the safety flag
      expect(h.safetyFlagged, isTrue);
      expect(h.safetyItems, ['Safety']);
      expect(h.flaggedLabels, ['Safety']);
      expect(h.coverageLabel, '8 of 8 checks tested');
      expect(h.aiScore, isNull);
      expect(h.combinedScore, isNull);
      expect(h.basisLabel, 'Technician assessment only');
    });

    test('an unscored appliance has a null score and a message', () async {
      final r = await _api(MockClient((_) async => _json(200, {
            ...scored,
            'technicianScore': null,
            'status': null,
            'statusLabel': null,
            'safetyFlagged': false,
            'safetyFlaggedItems': [],
            'message': 'Not enough checks to score.',
            'coverage': {'tested': 5, 'total': 8, 'label': '5 of 8 checks tested'},
          }))).applianceHealth('B-1', 'KAPP-1');
      expect(r.value!.score, isNull);
      expect(r.value!.status, isNull);
      expect(r.value!.message, 'Not enough checks to score.');
    });

    test('kitchenHealth maps coverage and per-appliance rows', () async {
      final r = await _api(MockClient((_) async => _json(200, {
            'technicianScore': 70,
            'status': 'attention',
            'statusLabel': 'Attention',
            'coverage': {'assessed': 1, 'registered': 2, 'label': '1 of 2 appliances assessed'},
            'safetyFlagged': false,
            'message': null,
            'explanation': [],
            'scoreBasisLabel': 'Technician assessment only',
            'disclaimer': 'x',
            'appliances': [
              {...scored, 'id': 'KAPP-1', 'category': 'hob', 'brand': 'Elica', 'model': ''},
              {
                'id': 'KAPP-2', 'category': 'ro_purifier', 'brand': 'Kent', 'model': '',
                'technicianScore': null, 'status': null,
                'coverage': {'tested': 0, 'total': 8, 'label': '0 of 8 checks tested'},
                'message': 'Not enough checks to score.',
              },
            ],
          }))).kitchenHealth('B-1');
      final k = r.value!;
      expect(k.score, 70);
      expect(k.assessedCount, 1);
      expect(k.registeredCount, 2);
      expect(k.coverageLabel, '1 of 2 appliances assessed');
      expect(k.forAppliance('KAPP-1')!.assessment.score, 85);
      expect(k.forAppliance('KAPP-2')!.assessment.score, isNull);
      expect(k.forAppliance('nope'), isNull);
    });

    test('404 reads as no longer assigned', () async {
      final r = await _api(MockClient((_) async => _json(404, {'error': 'not found'})))
          .kitchenHealth('B-1');
      expect(r.ok, isFalse);
      expect(r.error, contains('no longer assigned'));
    });
  });
}
