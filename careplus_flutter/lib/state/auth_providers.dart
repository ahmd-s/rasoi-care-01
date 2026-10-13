import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/backend_client.dart';
import '../data/firebase/auth_service.dart';
import '../data/firebase/auth_service_factory.dart';
import '../data/firebase/mock_auth_service.dart';

/// Picks Firebase when initialized; otherwise mock in debug/profile only.
/// Release builds never fall back to [MockAuthService] (P2-14).
/// Override in tests via
/// `ProviderScope(overrides: [authServiceProvider.overrideWithValue(...)])`.
final authServiceProvider = Provider<AuthService>(
  (ref) => selectAuthService(
    firebaseReady: Firebase.apps.isNotEmpty,
    allowMock: !kReleaseMode,
  ),
);

/// Set once BiometricLockScreen successfully authenticates this session —
/// plain (non-Riverpod) so router.dart's GoRouter, a bare top-level
/// instance built before any ProviderScope exists, can still gate every
/// route behind the app's own lock, not just SplashScreen's one-time
/// check at cold start. Defaults to false (locked) and is reset there on
/// sign-out so a fresh session starts locked again.
bool biometricUnlockedThisSession = false;

class AuthFlowState {
  const AuthFlowState({
    this.phone = '',
    this.verificationId,
    this.sending = false,
    this.verifying = false,
    this.submitting = false,
    this.error,
  });
  final String phone;
  final String? verificationId;
  final bool sending;
  final bool verifying;
  /// Covers email/password and Google sign-in — separate from [sending]/
  /// [verifying], which are phone-OTP-specific, so the two flows' spinners
  /// never fight over the same flag.
  final bool submitting;
  final String? error;

  AuthFlowState copyWith({
    String? phone,
    String? verificationId,
    bool? sending,
    bool? verifying,
    bool? submitting,
    String? error,
    bool clearError = false,
  }) =>
      AuthFlowState(
        phone: phone ?? this.phone,
        verificationId: verificationId ?? this.verificationId,
        sending: sending ?? this.sending,
        verifying: verifying ?? this.verifying,
        submitting: submitting ?? this.submitting,
        error: clearError ? null : (error ?? this.error),
      );
}

final authFlowProvider =
    NotifierProvider<AuthFlowVM, AuthFlowState>(AuthFlowVM.new);

class AuthFlowVM extends Notifier<AuthFlowState> {
  @override
  AuthFlowState build() => const AuthFlowState();

  /// True only for [MockAuthService] — not for an unconfigured release build.
  /// The OTP screen uses this for simulated SMS auto-fill (demo code 4402).
  bool get isMock => ref.read(authServiceProvider) is MockAuthService;

  Future<bool> sendOtp(String tenDigitPhone) async {
    state = state.copyWith(sending: true, clearError: true, phone: tenDigitPhone);
    try {
      final result = await ref.read(authServiceProvider).sendOtp('+91$tenDigitPhone');
      state = state.copyWith(sending: false, verificationId: result.verificationId);
      return true;
    } on AuthException catch (e) {
      state = state.copyWith(sending: false, error: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(
          sending: false, error: 'Could not send a code right now. Try again.');
      return false;
    }
  }

  Future<bool> verifyOtp(String code) async {
    final vid = state.verificationId;
    if (vid == null) {
      state = state.copyWith(error: 'Request a code first.');
      return false;
    }
    state = state.copyWith(verifying: true, clearError: true);
    try {
      await ref.read(authServiceProvider).verifyOtp(verificationId: vid, smsCode: code);
      bootstrapBackend();
      state = state.copyWith(verifying: false);
      return true;
    } on AuthException catch (e) {
      state = state.copyWith(verifying: false, error: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(verifying: false, error: 'Verification failed. Try again.');
      return false;
    }
  }

  Future<bool> registerWithEmail(String email, String password) =>
      _submit(() => ref.read(authServiceProvider).registerWithEmail(email: email, password: password));

  Future<bool> signInWithEmail(String email, String password) =>
      _submit(() => ref.read(authServiceProvider).signInWithEmail(email: email, password: password));

  Future<bool> signInWithGoogle() =>
      _submit(() => ref.read(authServiceProvider).signInWithGoogle());

  Future<bool> _submit(Future<void> Function() action) async {
    state = state.copyWith(submitting: true, clearError: true);
    try {
      await action();
      bootstrapBackend();
      state = state.copyWith(submitting: false);
      return true;
    } on AuthException catch (e) {
      state = state.copyWith(submitting: false, error: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(submitting: false, error: 'Something went wrong. Try again.');
      return false;
    }
  }

  void reset() {
    state = const AuthFlowState();
    biometricUnlockedThisSession = false;
  }

  /// Best-effort POST to the backend right after any successful sign-in
  /// (register, email/password, Google, or phone OTP) so it has a matching
  /// `users` row — see bootstrap_customer in app.py. Fire-and-forget, same
  /// pattern as UserProfileService's Firestore write-through in
  /// firestore_user_profile_service.dart: never blocks getting into the
  /// app, and a no-op in mock mode (no Firebase project configured yet).
  ///
  /// Public so SplashScreen can also call this for an already-signed-in,
  /// restored session — a returning customer whose Firebase session is
  /// still valid never goes through sign-in again, so without this the
  /// backend can permanently lack their `users` row (e.g. if it was reset,
  /// as a backend migration to a fresh database would do) and every
  /// authenticated call, including booking creation, would 401 forever
  /// with no way for the app to ever retry it.
  void bootstrapBackend() {
    if (Firebase.apps.isEmpty) return;
    unawaited(_doBootstrapBackend());
  }

  Future<void> _doBootstrapBackend() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final idToken = await user.getIdToken();
      if (idToken == null) return;
      await BackendClient().bootstrap(
        idToken: idToken,
        name: user.displayName ?? user.email ?? 'Customer',
      );
    } catch (_) {
      // Best-effort — never blocks sign-in.
    }
  }
}
