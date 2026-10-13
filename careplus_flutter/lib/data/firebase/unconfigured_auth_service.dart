import 'auth_service.dart';

/// Release-safe stand-in when Firebase failed to initialize.
///
/// Unlike [MockAuthService], this never accepts a demo OTP or silent
/// sign-in — every auth call fails with a clear [AuthException]. Used only
/// when `kReleaseMode` is true and Firebase apps are empty.
class UnconfiguredAuthService implements AuthService {
  const UnconfiguredAuthService();

  static const _message =
      'Sign-in is unavailable: Firebase is not configured for this build.';

  @override
  bool get isLive => false;

  @override
  bool get isSignedIn => false;

  @override
  String? get currentDisplayName => null;

  @override
  String? get currentEmail => null;

  @override
  String? get currentPhoneNumber => null;

  Never _unavailable() => throw const AuthException(_message);

  @override
  Future<OtpSent> sendOtp(String e164Phone) async => _unavailable();

  @override
  Future<void> verifyOtp({
    required String verificationId,
    required String smsCode,
  }) async =>
      _unavailable();

  @override
  Future<void> registerWithEmail({
    required String email,
    required String password,
  }) async =>
      _unavailable();

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async =>
      _unavailable();

  @override
  Future<void> signInWithGoogle() async => _unavailable();

  @override
  Future<void> signOut() async {}
}
