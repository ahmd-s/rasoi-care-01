import 'dart:convert';

import 'package:care_plus/data/api/passport_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

PassportClient _client(MockClient c, {String? token = 'tok'}) =>
    PassportClient(client: c, tokenProvider: () async => token);

http.Response _json(int status, Object body) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> _appliance({
  String id = 'KAPP-1',
  int? score = 78,
  String? status = 'attention',
  Object? nextService = const {'urgency': 'soon', 'estimatedDays': 21},
  List<Object?> history = const [],
}) =>
    {
      'id': id,
      'category': 'hob',
      'brand': 'Elica',
      'model': 'Flexi',
      'score': score,
      'status': status,
      'checksTested': 8,
      'checksTotal': 8,
      'notEnoughChecks': score == null,
      'safetyFlagged': false,
      'attentionItems': ['Ignition'],
      'basis': 'technician_only',
      'assessedAt': 't',
      'nextService': nextService,
      'history': history,
    };

Map<String, dynamic> _body({List<Object?>? appliances, Object? kitchen}) => {
      'kitchen': kitchen ??
          {
            'score': 78,
            'status': 'attention',
            'registeredCount': 1,
            'assessedCount': 1,
            'safetyFlagged': false,
            'basis': 'technician_only',
            'nextService': {
              'urgency': 'soon',
              'estimatedDays': 21,
              'applianceId': 'KAPP-1',
              'category': 'hob'
            },
          },
      'appliances': appliances ?? [_appliance()],
      'needsAttention': ['KAPP-1'],
    };

void main() {
  test('sends the bearer token to the overview route and parses the passport',
      () async {
    late http.BaseRequest seen;
    final r = await _client(MockClient((req) async {
      seen = req;
      return _json(200, _body());
    })).overview();
    expect(seen.url.path, '/api/kitchen-passport/overview');
    expect(seen.headers['Authorization'], 'Bearer tok');
    final p = r.passport!;
    expect(p.score, 78);
    expect(p.status, 'attention');
    expect(p.nextService!.estimatedDays, 21);
    expect(p.appliances.single.attentionItems, ['Ignition']);
    expect(p.needsAttention, ['KAPP-1']);
  });

  test('no token means signed-out and no request', () async {
    var called = false;
    final r = await _client(MockClient((_) async {
      called = true;
      return _json(200, _body());
    }), token: null)
        .overview();
    expect(called, isFalse);
    expect(r.failure!.kind, PassportFailureKind.signedOut);
  });

  test(
      '401 is signed-out, 5xx and junk are server errors, transport errors are network',
      () async {
    expect(
        (await _client(MockClient((_) async => _json(401, {}))).overview())
            .failure!
            .kind,
        PassportFailureKind.signedOut);
    expect(
        (await _client(MockClient((_) async => _json(500, {}))).overview())
            .failure!
            .kind,
        PassportFailureKind.server);
    expect(
        (await _client(MockClient((_) async => http.Response('<html>', 200)))
                .overview())
            .failure!
            .kind,
        PassportFailureKind.server);
    expect(
        (await _client(MockClient((_) async => _json(200, {'nope': 1})))
                .overview())
            .failure!
            .kind,
        PassportFailureKind.server);
    expect(
        (await _client(MockClient((_) async => throw http.ClientException('x')))
                .overview())
            .failure!
            .kind,
        PassportFailureKind.network);
  });

  test('missing scores stay null and are never defaulted', () async {
    final p = (await _client(MockClient((_) async => _json(
            200,
            _body(
              appliances: [
                _appliance(score: null, status: null, nextService: null)
              ],
              kitchen: {
                'score': null,
                'status': null,
                'registeredCount': 1,
                'assessedCount': 0,
                'nextService': null
              },
            )))).overview())
        .passport!;
    expect(p.score, isNull);
    expect(p.status, isNull);
    expect(p.nextService, isNull);
    final a = p.appliances.single;
    expect(a.score, isNull);
    expect(a.notEnoughChecks, isTrue);
    expect(a.nextService, isNull);
  });

  test(
      'malformed entries are dropped; unknown statuses and urgencies are not guessed',
      () async {
    final p = (await _client(MockClient((_) async => _json(200, {
              'kitchen': {
                'score': 'high',
                'status': 'excellent',
                'registeredCount': 2,
                'nextService': {'urgency': 'whenever', 'estimatedDays': 5},
              },
              'appliances': [
                'junk',
                {'category': 'hob'},
                _appliance(status: 'amazing', nextService: {
                  'urgency': 'soon',
                  'estimatedDays': -1
                }, history: [
                  'x',
                  {'serviceName': 'no date'},
                  {
                    'date': '2026-10-01T10:00:00Z',
                    'serviceName': 'Deep clean',
                    'score': 93,
                    'status': 'healthy'
                  },
                ]),
              ],
              'needsAttention': ['KAPP-1', 'KAPP-OTHER', 5],
            }))).overview())
        .passport!;
    expect(p.score, isNull);
    expect(p.status, isNull);
    expect(p.nextService, isNull);
    expect(p.appliances, hasLength(1));
    expect(p.appliances.single.status, isNull);
    expect(p.appliances.single.nextService, isNull);
    expect(p.appliances.single.history.single.serviceName, 'Deep clean');
    expect(p.needsAttention, ['KAPP-1']);
  });
}
