import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'auth_service.dart';
import 'firebase_config.dart';

/// Real phone/email/Google auth via Firebase. Only ever constructed after
/// `Firebase.initializeApp()` has succeeded — see main.dart.
class FirebaseAuthService implements AuthService {
  final _auth = FirebaseAuth.instance;

  @override
  bool get isLive => true;

  @override
  bool get isSignedIn => _auth.currentUser != null;

  @override
  Future<OtpSent> sendOtp(String e164Phone) {
    final completer = Completer<OtpSent>();
    _auth.verifyPhoneNumber(
      phoneNumber: e164Phone,
      timeout: const Duration(seconds: 60),
      // Some Android devices can verify without the user typing anything
      // (SMS Retriever / instant verification). When that happens we sign
      // in immediately and hand back a synthetic "already done" id so the
      // OTP screen can skip straight past.
      verificationCompleted: (credential) async {
        try {
          await _auth.signInWithCredential(credential);
          if (!completer.isCompleted) completer.complete(const OtpSent('auto-verified'));
        } catch (e) {
          if (!completer.isCompleted) {
            completer.completeError(AuthException(_friendly(e)));
          }
        }
      },
      verificationFailed: (e) {
        if (!completer.isCompleted) {
          completer.completeError(AuthException(_friendly(e)));
        }
      },
      codeSent: (verificationId, _) {
        if (!completer.isCompleted) completer.complete(OtpSent(verificationId));
      },
      codeAutoRetrievalTimeout: (_) {},
    );
    return completer.future;
  }

  @override
  Future<void> verifyOtp({required String verificationId, required String smsCode}) async {
    if (verificationId == 'auto-verified') return; // already signed in above
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode,
      );
      await _auth.signInWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      throw AuthException(_friendly(e));
    }
  }

  @override
  Future<void> registerWithEmail({required String email, required String password}) async {
    try {
      await _auth.createUserWithEmailAndPassword(email: email, password: password);
    } on FirebaseAuthException catch (e) {
      throw AuthException(_friendly(e));
    }
  }

  @override
  Future<void> signInWithEmail({required String email, required String password}) async {
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
    } on FirebaseAuthException catch (e) {
      throw AuthException(_friendly(e));
    }
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (e) {
      // Keep account existence private; the UI shows the same confirmation
      // whether or not a matching email is registered.
      if (e.code == 'user-not-found') return;
      throw AuthException(_friendly(e));
    }
  }

  @override
  Future<void> signInWithGoogle() async {
    try {
      final googleSignIn = GoogleSignIn(serverClientId: FirebaseConfig.googleServerClientId);
      final account = await googleSignIn.signIn();
      if (account == null) {
        throw const AuthException('Sign-in cancelled.');
      }
      final googleAuth = await account.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      await _auth.signInWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      throw AuthException(_friendly(e));
    } on AuthException {
      rethrow;
    } catch (e) {
      throw const AuthException('Could not sign in with Google right now. Try again.');
    }
  }

  @override
  Future<void> signOut() async {
    await _auth.signOut();
    await GoogleSignIn().signOut();
  }

  String _friendly(Object e) {
    if (e is FirebaseAuthException) {
      return switch (e.code) {
        'invalid-verification-code' => 'That code doesn\'t match. Check and try again.',
        'invalid-phone-number' => 'That doesn\'t look like a valid phone number.',
        'too-many-requests' => 'Too many attempts — wait a bit before retrying.',
        'session-expired' => 'That code expired. Request a new one.',
        'email-already-in-use' => 'An account already exists with that email — try signing in instead.',
        'invalid-email' => 'That doesn\'t look like a valid email address.',
        'weak-password' => 'Choose a password with at least 6 characters.',
        'user-not-found' => 'No account found with that email.',
        'wrong-password' || 'invalid-credential' => 'Incorrect email or password.',
        'account-exists-with-different-credential' =>
          'That email is already linked to a different sign-in method.',
        // Never fall back to e.message — that's Firebase's own internal
        // English text, not a curated, localized message, and leaks SDK
        // implementation detail for any error code not explicitly handled
        // above (a future SDK version's new code, network-request-failed,
        // internal-error, ...).
        'network-request-failed' => 'No internet connection. Check your network and try again.',
        'operation-not-allowed' =>
          'This sign-in method is not enabled for this app yet (code: operation-not-allowed).',
        'app-not-authorized' || 'missing-client-identifier' || 'invalid-app-credential' ||
        'captcha-check-failed' || 'missing-app-credential' =>
          'This build is not authorised for phone sign-in yet — the app fingerprint must be registered in Firebase (code: ${e.code}).',
        'quota-exceeded' => 'SMS limit reached for now. Try a Firebase test number or wait (code: quota-exceeded).',
        // Only the non-secret error code is appended, so a tester can report
        // what actually failed; Firebase's own message text is still not shown.
        _ => 'Something went wrong (code: ${e.code}). Try again.',
      };
    }
    return 'Something went wrong. Try again.';
  }
}
