import 'dart:convert';

import 'package:care_plus/data/api/backend_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<T> _with<T>(
  Future<http.Response> Function(http.Request) handler,
  Future<T> Function() body,
) =>
    http.runWithClient(body, () => MockClient(handler));

Future<({List<Map<String, dynamic>>? bookings, Map<String, dynamic>? pricing, String? error, bool unauthorized})>
    _checkout({String? key}) => BackendClient().createBookingCart(
          idToken: 't',
          serviceIds: const ['svc_a'],
          useCoins: false,
          idempotencyKey: key,
        );

http.Response _json(int code, Object? body) =>
    http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json'});

void main() {
  group('createBookingCart', () {
    test('201 with a real booking id returns it and sends the idempotency key', () async {
      late http.Request seen;
      final r = await _with((req) async {
        seen = req;
        return _json(201, {
          'bookings': [
            {'id': 'RC-7', 'status': 'Requested'}
          ],
          'pricing': {'grandTotal': 100},
        });
      }, () => _checkout(key: 'co-key-12345'));
      expect(r.error, isNull);
      expect(r.bookings!.single['id'], 'RC-7');
      expect(seen.headers['Idempotency-Key'], 'co-key-12345');
      expect(seen.url.path, '/api/bookings/cart');
    });

    test('201 without a usable booking id is NOT a success', () async {
      for (final body in [
        {'bookings': []},
        {'bookings': [{'status': 'Requested'}]},
        {'bookings': [{'id': ''}]},
        {'bookings': null},
        {},
      ]) {
        final r = await _with((_) async => _json(201, body), _checkout);
        expect(r.bookings, isNull, reason: '$body');
        expect(r.error, isNotNull);
      }
    });

    test('JSON null / non-JSON / non-string error bodies never throw', () async {
      final nullBody = await _with((_) async => http.Response('null', 201), _checkout);
      expect(nullBody.bookings, isNull);
      expect(nullBody.error, isNotNull);

      final html = await _with((_) async => http.Response('<html>Bad gateway</html>', 502), _checkout);
      expect(html.bookings, isNull);
      expect(html.error, contains('server'));

      final weird = await _with((_) async => _json(400, {'error': 42}), _checkout);
      expect(weird.error, contains('400'));
    });

    test('backend rejection and no-technician messages reach the customer', () async {
      final r503 = await _with(
          (_) async => _json(503, {'error': 'No technician is available for this service yet'}), _checkout);
      expect(r503.bookings, isNull);
      expect(r503.error, 'No technician is available for this service yet');
      final r400 = await _with((_) async => _json(400, {'error': 'Unknown serviceId: x'}), _checkout);
      expect(r400.error, 'Unknown serviceId: x');
    });

    test('401 is flagged unauthorized; 429 is friendly', () async {
      final r401 = await _with((_) async => _json(401, {'error': 'Unauthorized'}), _checkout);
      expect(r401.unauthorized, isTrue);
      final r429 = await _with((_) async => _json(429, {'error': 'Too Many Requests'}), _checkout);
      expect(r429.error, contains('wait'));
    });

    test('network failure gives a connection message, not a null error', () async {
      final r = await _with((_) async => throw http.ClientException('down'), _checkout);
      expect(r.bookings, isNull);
      expect(r.error, contains('connection'));
    });
  });
}
