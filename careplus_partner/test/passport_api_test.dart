import 'dart:convert';

import 'package:care_plus_partner/data/api/passport_api.dart';
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
}
