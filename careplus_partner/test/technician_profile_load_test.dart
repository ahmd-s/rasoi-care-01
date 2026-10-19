import 'dart:convert';

import 'package:care_plus_partner/data/api/api_config.dart';
import 'package:care_plus_partner/state/auth_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _staging = 'https://rasoi-care-01.onrender.com';

void main() {
  test('profile request goes to the configured base URL with the bearer token', () async {
    late http.Request seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response(jsonEncode({'id': 'T1', 'verified': true}), 200);
    });
    final r = await requestTechnicianMe(client: client, baseUrl: _staging, token: 'tok');
    expect(seen.url.toString(), '$_staging/api/technician/me');
    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(r.status, 200);
    expect(r.json?['verified'], true);
    expect(r.rejected, isFalse);
  });

  test('401/403 are reported as rejected, not as a connection problem', () async {
    for (final code in [401, 403]) {
      final client = MockClient((_) async => http.Response('{"error":"Unauthorized"}', code));
      final r = await requestTechnicianMe(client: client, baseUrl: _staging, token: 't');
      expect(r.json, isNull);
      expect(r.status, code);
      expect(r.rejected, isTrue);
    }
  });

  test('5xx, bad JSON and network errors yield no profile and are not "rejected"', () async {
    final cases = <MockClient>[
      MockClient((_) async => http.Response('oops', 503)),
      MockClient((_) async => http.Response('[1,2]', 200)),
      MockClient((_) async => throw http.ClientException('offline')),
    ];
    for (final c in cases) {
      final r = await requestTechnicianMe(client: c, baseUrl: _staging, token: 't');
      expect(r.json, isNull);
      expect(r.rejected, isFalse);
    }
  });

  test('release builds only use the staging API when API_BASE_URL is given', () {
    expect(ApiConfig.resolve(override: _staging, releaseMode: true), _staging);
    // Without the define a release build targets production — staging
    // builds MUST pass --dart-define=API_BASE_URL=... (see the runbook).
    expect(ApiConfig.resolve(override: '', releaseMode: true), ApiConfig.productionUrl);
  });
}
