import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/staff_bootstrap_service.dart';
import '../data/auth/auth_service.dart';
import '../data/auth/auth_service_factory.dart';
import '../data/auth/mock_auth_service.dart';
import '../data/firestore/staff_profile_service.dart';
import '../data/models.dart';

/// Picks Firebase when initialized; otherwise mock in debug/profile only.
/// Release builds never fall back to [MockAuthService] (P2-14).
final authServiceProvider = Provider<AuthService>(
  (ref) => selectAuthService(
    firebaseReady: Firebase.apps.isNotEmpty,
    allowMock: !kReleaseMode,
  ),
);

final staffProfileServiceProvider = Provider<StaffProfileService>(
  (ref) => StaffProfileService(),
);

final staffBootstrapServiceProvider = Provider<StaffBootstrapService>(
  (ref) => StaffBootstrapService(),
);

class AuthFlowState {
  const AuthFlowState({
    this.phone = '',
    this.role = AdminRole.owner,
    this.verificationId,
    this.sending = false,
    this.verifying = false,
    this.submitting = false,
    this.error,
  });
  final String phone;
  final AdminRole role;
  final String? verificationId;
  final bool sending;
  final bool verifying;

  /// Covers email/password and Google sign-in — separate from [sending]/
  /// [verifying], which are phone-OTP-specific.
  final bool submitting;
  final String? error;

  AuthFlowState copyWith({
    String? phone,
    AdminRole? role,
    String? verificationId,
    bool? sending,
    bool? verifying,
    bool? submitting,
    String? error,
    bool clearError = false,
  }) => AuthFlowState(
    phone: phone ?? this.phone,
    role: role ?? this.role,
    verificationId: verificationId ?? this.verificationId,
    sending: sending ?? this.sending,
    verifying: verifying ?? this.verifying,
    submitting: submitting ?? this.submitting,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Mirrors the signed-in role outside Riverpod so router.dart's GoRouter
/// — a bare top-level instance built before any ProviderScope exists, so
/// its `redirect` can't ref.read/watch — can still keep a staff account
/// off the owner-only Staff & Access screen. Matches AuthFlowState's own
/// default so the router's gate and the account screen's nav-tile gate
/// never disagree during the same not-yet-synced window. The backend is
/// the real enforcement point regardless (POST/PATCH /api/staff both
/// require @require_owner) — this only keeps the UI honest about what a
/// staff account can actually do.
AdminRole latestKnownAdminRole = AdminRole.owner;

final authFlowProvider = NotifierProvider<AuthFlowVM, AuthFlowState>(
  AuthFlowVM.new,
);

class AuthFlowVM extends Notifier<AuthFlowState> {
  @override
  AuthFlowState build() => const AuthFlowState();

  /// True only for [MockAuthService] — not for an unconfigured release build.
  bool get isMock => ref.read(authServiceProvider) is MockAuthService;

  void setRole(AdminRole role) {
    state = state.copyWith(role: role);
    latestKnownAdminRole = role;
  }

  Future<bool> sendOtp(String tenDigitPhone) async {
    state = state.copyWith(
      sending: true,
      clearError: true,
      phone: tenDigitPhone,
    );
    try {
      final result = await ref
          .read(authServiceProvider)
          .sendOtp('+91$tenDigitPhone');
      state = state.copyWith(
        sending: false,
        verificationId: result.verificationId,
      );
      return true;
    } on AuthException catch (e) {
      state = state.copyWith(sending: false, error: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(
        sending: false,
        error: 'Could not send a code right now. Try again.',
      );
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
      await ref
          .read(authServiceProvider)
          .verifyOtp(verificationId: vid, smsCode: code);
      state = state.copyWith(verifying: false);
      unawaited(
        ref.read(staffProfileServiceProvider).touchProfile(role: state.role),
      );
      unawaited(bootstrapAndSyncRole());
      return true;
    } on AuthException catch (e) {
      state = state.copyWith(verifying: false, error: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(
        verifying: false,
        error: 'Verification failed. Try again.',
      );
      return false;
    }
  }

  Future<bool> registerWithEmail(String email, String password) => _submit(
    () => ref
        .read(authServiceProvider)
        .registerWithEmail(email: email, password: password),
  );

  Future<bool> signInWithEmail(String email, String password) => _submit(
    () => ref
        .read(authServiceProvider)
        .signInWithEmail(email: email, password: password),
  );

  Future<bool> signInWithGoogle() =>
      _submit(() => ref.read(authServiceProvider).signInWithGoogle());

  Future<bool> _submit(Future<void> Function() action) async {
    state = state.copyWith(submitting: true, clearError: true);
    try {
      await action();
      state = state.copyWith(submitting: false);
      unawaited(
        ref.read(staffProfileServiceProvider).touchProfile(role: state.role),
      );
      unawaited(bootstrapAndSyncRole());
      return true;
    } on AuthException catch (e) {
      state = state.copyWith(submitting: false, error: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(
        submitting: false,
        error: 'Something went wrong. Try again.',
      );
      return false;
    }
  }

  /// Posts the requested role to /api/staff/bootstrap and, once the real
  /// backend-assigned role comes back, corrects [state.role] to match it —
  /// see StaffBootstrapService.bootstrap's doc comment. Runs after
  /// navigation has already happened (never blocks sign-in), so the UI may
  /// briefly show the requested role before this lands; that's the same
  /// lag every other real-data screen in this app already has while its
  /// first fetch is in flight.
  Future<void> bootstrapAndSyncRole() async {
    final real = await ref.read(staffBootstrapServiceProvider).bootstrap(role: state.role);
    if (real != null) {
      state = state.copyWith(role: real);
      latestKnownAdminRole = real;
    }
  }

  void reset() {
    state = const AuthFlowState();
    latestKnownAdminRole = AdminRole.owner;
  }
}

/// The signed-in role, valid once auth completes. Screens gate owner-only
/// sections on this.
final currentRoleProvider = Provider<AdminRole>(
  (ref) => ref.watch(authFlowProvider).role,
);
