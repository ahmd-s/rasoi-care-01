import 'auth_service.dart';

/// Used until this app is wired to a real technician-auth backend. Any phone
/// number "sends", and the code is always 4402, matching the OTP screen's
/// auto-fill affordance.
class MockAuthService implements AuthService {
  static const demoCode = '4402';
  bool _signedIn = false;

  @override
  bool get isLive => false;

  @override
  bool get isSignedIn => _signedIn;

  @override
  Future<OtpSent> sendOtp(String e164Phone) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return const OtpSent('mock-verification-id');
  }

  @override
  Future<void> verifyOtp({required String verificationId, required String smsCode}) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (smsCode != demoCode) {
      throw const AuthException('That code doesn\'t match. Check and try again.');
    }
    _signedIn = true;
  }

  @override
  Future<void> registerWithEmail({required String email, required String password}) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _signedIn = true;
  }

  @override
  Future<void> signInWithEmail({required String email, required String password}) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _signedIn = true;
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  @override
  Future<void> signInWithGoogle() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _signedIn = true;
  }

  @override
  Future<void> signOut() async => _signedIn = false;
}
