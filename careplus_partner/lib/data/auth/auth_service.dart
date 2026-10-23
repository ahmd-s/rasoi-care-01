// The seam between the auth screens and whichever phone-auth backend is
// live. Swap MockAuthService for a real implementation (e.g. Firebase phone
// auth, matching careplus_flutter's lib/data/firebase/) when this app needs
// to verify a real technician roster — the screens only ever talk to
// AuthService, never to a backend directly.

/// Outcome of requesting an OTP.
class OtpSent {
  const OtpSent(this.verificationId);
  final String verificationId;
}

abstract interface class AuthService {
  /// True once real Firebase auth is backing this instance. The OTP screen
  /// uses this to decide whether to show the "auto-fill" demo affordance
  /// (mock only) or ask for a real typed SMS code.
  bool get isLive;

  /// Whether a user is currently signed in (checked once at app start).
  bool get isSignedIn;

  /// Sends the OTP. Throws an [AuthException] on failure.
  Future<OtpSent> sendOtp(String e164Phone);

  /// Verifies the code against the most recent [OtpSent.verificationId].
  /// Throws an [AuthException] if it doesn't match.
  Future<void> verifyOtp({required String verificationId, required String smsCode});

  /// Creates a new email/password account. Throws an [AuthException] on
  /// failure (e.g. email already registered, weak password).
  Future<void> registerWithEmail({required String email, required String password});

  /// Signs in with an existing email/password account. Throws an
  /// [AuthException] on failure (wrong password, no such user, etc).
  Future<void> signInWithEmail({required String email, required String password});

  /// Sends a password reset link to an existing email account.
  Future<void> sendPasswordResetEmail(String email);

  /// Signs in with Google. Throws an [AuthException] on failure, including
  /// when the person closes the account picker without choosing one.
  Future<void> signInWithGoogle();

  Future<void> signOut();
}

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}
