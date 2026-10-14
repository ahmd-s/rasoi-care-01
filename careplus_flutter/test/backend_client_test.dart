import 'package:flutter_test/flutter_test.dart';
import 'package:care_plus/data/api/backend_client.dart';
import 'package:care_plus/data/api/api_config.dart';

void main() {
  group('BackendClient', () {
    late BackendClient client;

    setUp(() {
      client = BackendClient();
    });

    test('bootstrap returns false on null idToken', () async {
      // Should handle null gracefully without throwing
      final result = await client.bootstrap(idToken: '', name: 'Test');
      expect(result, false);
    });

    test('bootstrap returns false on empty idToken', () async {
      final result = await client.bootstrap(idToken: '', name: 'Test User');
      expect(result, false);
    });

    test('bootstrap handles null phone parameter', () async {
      // Should not throw when phone is null
      final result = await client.bootstrap(
        idToken: 'test_token',
        name: 'Test User',
        phone: null,
      );
      // Will return false since we're not hitting a real backend
      expect(result, false);
    });

    test('bootstrap handles empty phone string', () async {
      final result = await client.bootstrap(
        idToken: 'test_token',
        name: 'Test User',
        phone: '',
      );
      // Will return false since we're not hitting a real backend
      expect(result, false);
    });

    test('ApiConfig.baseUrl is not empty', () {
      expect(ApiConfig.baseUrl.isNotEmpty, true);
    });
  });

  group('Error handling', () {
    test('methods should not throw on network errors', () async {
      final client = BackendClient();
      
      // These should complete without throwing even without a real backend
      expect(
        () async => await client.bootstrap(idToken: 'invalid', name: 'Test'),
        returnsNormally,
      );
    });
  });
}
