import 'package:care_plus/data/firebase/auth_service.dart';
import 'package:care_plus/data/firebase/auth_service_factory.dart';
import 'package:care_plus/data/firebase/mock_auth_service.dart';
import 'package:care_plus/data/firebase/unconfigured_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('selectAuthService (P2-14)', () {
    test('debug/profile without Firebase uses MockAuthService', () {
      final auth = selectAuthService(firebaseReady: false, allowMock: true);
      expect(auth, isA<MockAuthService>());
      expect(auth.isLive, isFalse);
    });

    test('release without Firebase never uses MockAuthService', () {
      final auth = selectAuthService(firebaseReady: false, allowMock: false);
      expect(auth, isA<UnconfiguredAuthService>());
      expect(auth, isNot(isA<MockAuthService>()));
    });

    test('unconfigured release rejects OTP send', () async {
      final auth = selectAuthService(firebaseReady: false, allowMock: false);
      await expectLater(
        auth.sendOtp('+919999999999'),
        throwsA(isA<AuthException>()),
      );
    });

    test('unconfigured release rejects demo OTP verify', () async {
      final auth = selectAuthService(firebaseReady: false, allowMock: false);
      await expectLater(
        auth.verifyOtp(
          verificationId: 'mock-verification-id',
          smsCode: MockAuthService.demoCode,
        ),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
