import 'auth_service.dart';
import 'firebase_auth_service.dart';
import 'mock_auth_service.dart';
import 'unconfigured_auth_service.dart';

/// Chooses the auth backend for this process.
///
/// - Firebase ready → live [FirebaseAuthService]
/// - Debug/profile without Firebase → [MockAuthService] (demo OTP)
/// - Release without Firebase → [UnconfiguredAuthService] (never mock OTP)
AuthService selectAuthService({
  required bool firebaseReady,
  required bool allowMock,
}) {
  if (firebaseReady) return FirebaseAuthService();
  if (allowMock) return MockAuthService();
  return const UnconfiguredAuthService();
}
