import 'package:care_plus_admin/data/api/api_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _prod = 'https://rasoicare-backend.onrender.com';

void main() {
  group('release builds keep the production default', () {
    test('no override -> production', () {
      expect(ApiConfig.resolve(override: '', releaseMode: true), _prod);
      expect(ApiConfig.resolve(override: '  ', releaseMode: true), _prod);
    });
    test('an explicit override is honoured', () {
      expect(
        ApiConfig.resolve(
          override: 'https://staging.example.com',
          releaseMode: true,
        ),
        'https://staging.example.com',
      );
    });
    test('no developer error in release', () {
      expect(ApiConfig.problemFor(override: '', releaseMode: true), isNull);
      expect(ApiConfig.problemFor(override: _prod, releaseMode: true), isNull);
    });
  });

  group('debug and profile builds never default to production', () {
    test('no override -> an unreachable placeholder, not production', () {
      final url = ApiConfig.resolve(override: '', releaseMode: false);
      expect(url, ApiConfig.unconfiguredUrl);
      expect(url, isNot(_prod));
      expect(Uri.parse(url).host, endsWith('.invalid'));
    });

    test('an explicit local URL is used as given', () {
      expect(
        ApiConfig.resolve(override: 'http://10.0.2.2:8420', releaseMode: false),
        'http://10.0.2.2:8420',
      );
      expect(
        ApiConfig.resolve(
          override: ' http://localhost:8420 ',
          releaseMode: false,
        ),
        'http://localhost:8420',
      );
      expect(
        ApiConfig.problemFor(
          override: 'http://10.0.2.2:8420',
          releaseMode: false,
        ),
        isNull,
      );
    });

    test('a different hosted staging URL is allowed', () {
      const staging = 'https://rasoicare-staging.onrender.com';
      expect(ApiConfig.resolve(override: staging, releaseMode: false), staging);
      expect(
        ApiConfig.problemFor(override: staging, releaseMode: false),
        isNull,
      );
    });

    test('the production URL is rejected in every spelling', () {
      for (final url in [
        _prod,
        '$_prod/',
        '$_prod/api/health',
        'http://rasoicare-backend.onrender.com',
        'HTTPS://RasoiCare-Backend.OnRender.com',
        '  $_prod  ',
      ]) {
        expect(
          ApiConfig.resolve(override: url, releaseMode: false),
          ApiConfig.unconfiguredUrl,
          reason: url,
        );
        expect(
          ApiConfig.problemFor(override: url, releaseMode: false),
          contains('production'),
          reason: url,
        );
      }
    });

    test('the error tells a developer what to do', () {
      final msg = ApiConfig.problemFor(override: '', releaseMode: false)!;
      expect(msg, contains('API_BASE_URL'));
      expect(msg, contains('--dart-define=API_BASE_URL=http://10.0.2.2:8420'));
    });

    test(
      'the running test build (a debug build) is not pointed at production',
      () {
        expect(ApiConfig.baseUrl, isNot(_prod));
        expect(ApiConfig.baseUrl, isNotEmpty);
      },
    );
  });

  testWidgets('the error screen shows the title and the instructions', (
    tester,
  ) async {
    final msg = ApiConfig.problemFor(override: '', releaseMode: false)!;
    await tester.pumpWidget(ApiConfigErrorApp(msg));
    expect(
      find.byKey(const ValueKey('api-config-error-title')),
      findsOneWidget,
    );
    expect(find.text('Backend URL not configured'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('api-config-error-message')))
          .data,
      msg,
    );
  });
}
