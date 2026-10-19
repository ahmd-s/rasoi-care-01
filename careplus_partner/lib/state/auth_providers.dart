import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../data/api/api_config.dart';
import '../data/api/staff_bootstrap_service.dart';
import '../data/auth/auth_service.dart';
import '../data/auth/firebase_auth_service.dart';
import '../data/auth/mock_auth_service.dart';
import '../data/firestore/technician_profile_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/firebase/technician_upload_service.dart';
import '../data/operations/models.dart';
import 'providers.dart';

/// Picks the real service if `Firebase.initializeApp()` succeeded in
/// main.dart, otherwise the mock.
final authServiceProvider = Provider<AuthService>(
  (ref) => Firebase.apps.isEmpty ? MockAuthService() : FirebaseAuthService(),
);

final technicianProfileServiceProvider =
    Provider<TechnicianProfileService>((ref) => TechnicianProfileService());

final technicianUploadServiceProvider =
    Provider<TechnicianUploadService>((ref) => TechnicianUploadService());

final staffBootstrapServiceProvider = Provider<StaffBootstrapService>(
  (ref) => StaffBootstrapService(),
);

/// Router-level snapshot: owner routes default closed until the backend role
/// has been loaded from a verified Firebase identity.
AdminRole? latestKnownStaffRole;

/// The workspace someone explicitly picked before signing in. It never
/// grants access: it only selects which backend bootstrap runs, and the
/// backend must independently authorise the identity for that role.
enum SignInRole { staff, technician, owner }

/// Remembers the picked workspace so a returning session reopens the same
/// one (an identity can hold both a staff and a technician record).
abstract final class SignInRoleStore {
  static const _key = 'partner_sign_in_role';

  static Future<SignInRole?> load() async {
    try {
      final v = (await SharedPreferences.getInstance()).getString(_key);
      for (final r in SignInRole.values) {
        if (r.name == v) return r;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> save(SignInRole? role) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (role == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, role.name);
      }
    } catch (_) {}
  }
}

/// True when this build talks to the production API. Staging/test builds use
/// it only to pick a clearer UI (never for authorization — the backend
/// decides everything).
final isProductionApiProvider =
    Provider<bool>((ref) => ApiConfig.baseUrl == ApiConfig.productionUrl);

/// Loads the signed-in technician's record; overridable in tests.
final technicianMeLoaderProvider =
    Provider<Future<Map<String, dynamic>?> Function()>((ref) => fetchTechnicianMe);

/// Technician bootstrap call, overridable in tests.
final technicianBootstrapProvider =
    Provider<Future<TechnicianBootstrapResult> Function()>((ref) => bootstrapTechnicianBackendResult);

final currentRoleProvider = Provider<AdminRole>(
  (ref) => ref.watch(authFlowProvider).staffRole ?? AdminRole.staff,
);

/// The signed-in technician's own record — see [fetchTechnicianMe].
/// Populated by TechJobsScreen's initial refresh and re-populated by
/// TechProfileScreen's pull-to-refresh; null in mock mode or before the
/// first successful fetch, which callers treat as "nothing to show yet"
/// rather than fabricating a name.
final technicianMeProvider = StateProvider<Map<String, dynamic>?>((ref) => null);

/// Where the signed-in technician should land — decided from the real
/// backend record (`applicationSubmitted`/`verified`, see app.py's
/// technician_row_to_dict), modelled on Urban Company's partner flow: fill
/// in your profile/documents/bank details, then wait for verification
/// before you can go online for jobs.
enum TechnicianStage { apply, pending, jobs }

/// Best-effort call to the real backend right after a successful sign-in
/// (or app resume, from SplashScreen), mirroring
/// [TechnicianProfileService.touchProfile]'s "never block" spirit: in mock
/// mode, or if the request fails for any reason (backend not deployed yet,
/// timeout, network error), this returns null and callers fall back to
/// [TechnicianStage.jobs] — the original single-step mock flow.
Future<Map<String, dynamic>?> bootstrapTechnicianBackend() async =>
    (await bootstrapTechnicianBackendResult()).json;

/// [json] is the technician record; [denied] carries the backend's own
/// refusal text when it answered 401/403 (for example a staff-only identity
/// choosing Technician), so the screen can show a clear access error.
class TechnicianBootstrapResult {
  const TechnicianBootstrapResult({this.json, this.denied});
  final Map<String, dynamic>? json;
  final String? denied;
}

Future<TechnicianBootstrapResult> bootstrapTechnicianBackendResult() async {
  if (Firebase.apps.isEmpty) return const TechnicianBootstrapResult(); // mock mode
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return const TechnicianBootstrapResult();
  try {
    final token = await user.getIdToken();
    if (token == null) return const TechnicianBootstrapResult();
    final name = (user.displayName?.trim().isNotEmpty ?? false)
        ? user.displayName!.trim()
        : (user.email?.split('@').first ?? user.phoneNumber ?? 'Technician');
    final res = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/api/technician/bootstrap'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'name': name}),
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode == 401 || res.statusCode == 403) {
      String msg = 'This account is not authorized for Technician access.';
      try {
        final m = (jsonDecode(res.body) as Map)['message'];
        if (m is String && m.isNotEmpty && m.length < 200) msg = m;
      } catch (_) {}
      return TechnicianBootstrapResult(denied: msg);
    }
    if (res.statusCode != 200) return const TechnicianBootstrapResult();
    final decoded = jsonDecode(res.body);
    return TechnicianBootstrapResult(
        json: decoded is Map<String, dynamic> ? decoded : null);
  } catch (_) {
    return const TechnicianBootstrapResult(); // unreachable — never blocks sign-in
  }
}

/// Resolves staff/owner access from the backend for a returning Firebase
/// session. A null role means this identity must continue through technician
/// onboarding; the client never infers a privileged role itself.
Future<AdminRole?> refreshStaffRole(WidgetRef ref, {SignInRole? selected}) async {
  final result = await ref
      .read(staffBootstrapServiceProvider)
      .bootstrap(requestedRole: _requestedRole(selected));
  var role = result.role;
  // The backend must resolve exactly the workspace that was picked.
  if (!_roleMatches(selected, role)) role = null;
  // A definitive "not staff" answer must also clear any role left over from
  // an earlier session on this device; a transient error keeps what we have.
  if (role != null || result.notStaff) {
    ref.read(authFlowProvider.notifier).setStaffRole(role);
  }
  return role;
}

String? _requestedRole(SignInRole? r) => switch (r) {
      SignInRole.owner => 'owner',
      SignInRole.staff => 'staff',
      _ => null,
    };

bool _roleMatches(SignInRole? selected, AdminRole? role) => switch (selected) {
      SignInRole.owner => role == AdminRole.owner,
      SignInRole.staff => role == AdminRole.staff,
      _ => true,
    };

/// Re-checks status without re-bootstrapping — used by SplashScreen for a
/// returning technician, and by the "pending review" screen's refresh
/// action, via the technician's own already-issued Firebase token.
Future<Map<String, dynamic>?> fetchTechnicianMe() async =>
    (await fetchTechnicianMeResult()).json;

/// Outcome of GET /api/technician/me. [status] is the HTTP status, or null
/// when no request was made / it never completed (offline, timeout).
class TechnicianMeResult {
  const TechnicianMeResult({this.json, this.status});
  final Map<String, dynamic>? json;
  final int? status;

  /// The backend actively rejected this session's token (as opposed to being
  /// unreachable): the session is not valid for this backend.
  bool get rejected => status == 401 || status == 403;
}

/// Pure request half of [fetchTechnicianMeResult], injectable for tests.
/// Never logs the token or the response body; debug builds log only
/// "technician/me -> HTTP <status>".
Future<TechnicianMeResult> requestTechnicianMe({
  required http.Client client,
  required String baseUrl,
  required String token,
}) async {
  try {
    final res = await client
        .get(
          Uri.parse('$baseUrl/api/technician/me'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 8));
    if (kDebugMode) debugPrint('technician/me -> HTTP ${res.statusCode}');
    if (res.statusCode != 200) return TechnicianMeResult(status: res.statusCode);
    final decoded = jsonDecode(res.body);
    return TechnicianMeResult(
      json: decoded is Map<String, dynamic> ? decoded : null,
      status: res.statusCode,
    );
  } catch (_) {
    return const TechnicianMeResult();
  }
}

/// Status of the most recent GET /api/technician/me (null = never reached
/// the server). Shown beside the Profile load error to aid diagnosis; it
/// holds a number only — no token, phone or body.
int? lastTechnicianMeStatus;

Future<TechnicianMeResult> fetchTechnicianMeResult() async {
  final r = await _fetchTechnicianMeResult();
  lastTechnicianMeStatus = r.status;
  return r;
}

Future<TechnicianMeResult> _fetchTechnicianMeResult() async {
  if (Firebase.apps.isEmpty) return const TechnicianMeResult();
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return const TechnicianMeResult();
  try {
    final token = await user.getIdToken();
    if (token == null) return const TechnicianMeResult();
    return requestTechnicianMe(
        client: http.Client(), baseUrl: ApiConfig.baseUrl, token: token);
  } catch (_) {
    return const TechnicianMeResult();
  }
}

/// Submits (or partially updates) the technician's KYC application —
/// called by TechApplyScreen. Unlike [bootstrapTechnicianBackend]/
/// [fetchTechnicianMe], this is a primary action the person is actively
/// waiting on, so it throws a real [AuthException] instead of silently
/// swallowing failures — and it surfaces the backend's actual reason
/// rather than always blaming the connection. In particular, a 401 here
/// almost always means [bootstrapTechnicianBackend] never actually
/// created this technician's row yet (e.g. it silently timed out against
/// a cold-starting backend right after sign-in) — [TechApplyScreen]
/// catches [TechnicianProfileMissingException] specifically to retry that
/// bootstrap once before giving up, so a slow first request doesn't
/// permanently strand someone who filled out the whole form.
Future<Map<String, dynamic>> submitTechnicianApplication(
  Map<String, dynamic> fields,
) async {
  if (Firebase.apps.isEmpty) {
    throw const AuthException('Not available in demo mode.');
  }
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) throw const AuthException('Not signed in.');
  final token = await user.getIdToken();
  if (token == null) throw const AuthException('Not signed in.');
  http.Response res;
  try {
    res = await http
        .patch(
          Uri.parse('${ApiConfig.baseUrl}/api/technician/me'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(fields),
        )
        .timeout(const Duration(seconds: 15));
  } catch (_) {
    throw const AuthException('Could not submit — check your connection and try again.');
  }
  if (res.statusCode != 200) {
    final decoded = jsonDecode(res.body);
    final decodedMap = decoded is Map<String, dynamic> ? decoded : null;
    final serverMessage = decodedMap?['message'] as String?;
    if (res.statusCode == 401) {
      throw TechnicianProfileMissingException(
          serverMessage ?? 'Your technician profile isn\'t set up yet.');
    }
    // validate_json's error shape is {"error": ..., "fields": {name: reason}}
    // — there's no top-level "message" for this case, so serverMessage was
    // always null here and every field-format rejection (e.g. a lowercase
    // IFSC code, extra spaces in an Aadhaar number) surfaced as a bare
    // "Could not submit (error 400)" with no way to tell which field, or
    // why, from the app alone.
    final fieldErrors = decodedMap?['fields'];
    final fieldMessage = fieldErrors is Map
        ? fieldErrors.entries.map((e) => '${_fieldLabel('${e.key}')} ${e.value}').join('; ')
        : null;
    throw AuthException(serverMessage ??
        (fieldMessage != null && fieldMessage.isNotEmpty
            ? fieldMessage
            : 'Could not submit (error ${res.statusCode}). Try again.'));
  }
  final decoded = jsonDecode(res.body);
  if (decoded is! Map<String, dynamic>) {
    throw const AuthException('Unexpected response — try again.');
  }
  return decoded;
}

/// Turns a wire field name like "bankIfsc" into "Bank ifsc", so a per-field
/// validation error at least names the field in plain words instead of a
/// raw JSON key — not a full label lookup (that lives in each screen's own
/// l10n), just enough for a person to recognize which field is meant.
String _fieldLabel(String camelCase) {
  final spaced = camelCase.replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]!.toLowerCase()}');
  return spaced.isEmpty ? spaced : spaced[0].toUpperCase() + spaced.substring(1);
}

/// See [submitTechnicianApplication]'s doc comment.
class TechnicianProfileMissingException extends AuthException {
  const TechnicianProfileMissingException(super.message);
}

TechnicianStage stageFromTechnicianJson(Map<String, dynamic>? json) {
  if (json == null) return TechnicianStage.jobs; // mock mode / unreachable backend
  if (json['applicationSubmitted'] != true) return TechnicianStage.apply;
  if (json['verified'] != true) return TechnicianStage.pending;
  return TechnicianStage.jobs;
}

/// Routes a just-signed-in (or just-resumed) technician to wherever their
/// real application status says they belong. The first time this ever
/// lands someone on the job feed — fresh sign-up, or the day their
/// application gets verified — it detours through a one-time "turn on
/// biometric login?" offer instead, gated on the device actually
/// supporting it (see BiometricService.hasPrompted).
Future<void> routeToStage(BuildContext context, WidgetRef ref, TechnicianStage stage) async {
  if (ref.read(authFlowProvider).staffRole != null) {
    context.go('/ops/overview');
    return;
  }
  switch (stage) {
    case TechnicianStage.apply:
      context.go('/tech/apply');
    case TechnicianStage.pending:
      context.go('/tech/pending');
    case TechnicianStage.jobs:
      final biometric = ref.read(biometricServiceProvider);
      final alreadyPrompted = await biometric.hasPrompted();
      if (!alreadyPrompted && await biometric.isDeviceSupported()) {
        if (context.mounted) context.go('/biometric-enroll');
        return;
      }
      if (context.mounted) context.go('/tech/jobs');
  }
}

class AuthFlowState {
  const AuthFlowState({
    this.phone = '',
    this.verificationId,
    this.sending = false,
    this.verifying = false,
    this.submitting = false,
    this.error,
    this.stage = TechnicianStage.jobs,
    this.staffRole,
    this.signInRole,
  });
  final String phone;
  final String? verificationId;
  final bool sending;
  final bool verifying;
  /// Covers email/password and Google sign-in — separate from [sending]/
  /// [verifying], which are phone-OTP-specific.
  final bool submitting;
  final String? error;
  /// Where to route after a successful sign-in — set from the bootstrap
  /// response, see [bootstrapTechnicianBackend].
  final TechnicianStage stage;
  final AdminRole? staffRole;
  final SignInRole? signInRole;

  AuthFlowState copyWith({
    String? phone,
    String? verificationId,
    bool? sending,
    bool? verifying,
    bool? submitting,
    String? error,
    bool clearError = false,
    TechnicianStage? stage,
    AdminRole? staffRole,
    bool clearStaffRole = false,
    SignInRole? signInRole,
  }) =>
      AuthFlowState(
        phone: phone ?? this.phone,
        verificationId: verificationId ?? this.verificationId,
        sending: sending ?? this.sending,
        verifying: verifying ?? this.verifying,
        submitting: submitting ?? this.submitting,
        error: clearError ? null : (error ?? this.error),
        stage: stage ?? this.stage,
        staffRole: clearStaffRole ? null : (staffRole ?? this.staffRole),
        signInRole: signInRole ?? this.signInRole,
      );
}

final authFlowProvider =
    NotifierProvider<AuthFlowVM, AuthFlowState>(AuthFlowVM.new);

class AuthFlowVM extends Notifier<AuthFlowState> {
  @override
  AuthFlowState build() => const AuthFlowState();

  /// True when running against the mock — the OTP screen uses this to decide
  /// whether to show the simulated SMS auto-fill (mock only).
  bool get isMock => !ref.read(authServiceProvider).isLive;

  Future<bool> sendOtp(String tenDigitPhone) async {
    // A new phone sign-in is a new identity: never inherit a previous
    // owner/staff role from this device.
    _setStaffRole(null);
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

  /// Records the workspace picked on the role screen. Grants nothing.
  void selectRole(SignInRole role) {
    _setStaffRole(null);
    state = state.copyWith(signInRole: role, clearError: true);
  }

  Future<bool> verifyOtp(String code) async {
    final vid = state.verificationId;
    if (vid == null) {
      state = state.copyWith(error: 'Request a code first.');
      return false;
    }
    final selected = state.signInRole;
    if (selected == SignInRole.owner) {
      state = state.copyWith(error: 'Owner sign-in uses Google only.');
      return false;
    }
    state = state.copyWith(verifying: true, clearError: true);
    try {
      await ref.read(authServiceProvider).verifyOtp(verificationId: vid, smsCode: code);
      unawaited(ref.read(technicianProfileServiceProvider).touchProfile());
      if (selected == SignInRole.staff) {
        return _finishStaff(SignInRole.staff, verifying: true);
      }
      return _finishTechnician(verifying: true);
    } on AuthException catch (e) {
      state = state.copyWith(verifying: false, error: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(verifying: false, error: 'Verification failed. Try again.');
      return false;
    }
  }

  void _busy(bool verifying, {String? error}) {
    state = verifying
        ? state.copyWith(verifying: false, error: error)
        : state.copyWith(submitting: false, error: error);
  }

  /// Staff/Owner workspace: the backend must resolve exactly the picked role.
  Future<bool> _finishStaff(SignInRole picked, {required bool verifying}) async {
    final staff = await ref
        .read(staffBootstrapServiceProvider)
        .bootstrap(requestedRole: _requestedRole(picked));
    if (!_roleMatches(picked, staff.role) || staff.role == null) {
      await ref.read(authServiceProvider).signOut();
      _setStaffRole(null);
      final who = picked == SignInRole.owner ? 'Owner' : 'Staff';
      _busy(verifying,
          error: staff.error ?? 'This account is not authorized for $who access.');
      return false;
    }
    _setStaffRole(staff.role);
    unawaited(SignInRoleStore.save(picked));
    state = state.copyWith(
        verifying: false, submitting: false, stage: TechnicianStage.jobs);
    return true;
  }

  /// Technician workspace: never consults the staff roster, so an identity
  /// that also holds a staff record still lands in the technician app.
  Future<bool> _finishTechnician({required bool verifying}) async {
    _setStaffRole(null);
    final result = await ref.read(technicianBootstrapProvider)();
    if (result.denied != null) {
      await ref.read(authServiceProvider).signOut();
      _busy(verifying, error: result.denied);
      return false;
    }
    if (result.json == null && ref.read(authServiceProvider).isLive) {
      // Fail closed: never present an unknown application status as jobs.
      _busy(verifying, error: 'Could not load your application status. Try again.');
      return false;
    }
    unawaited(SignInRoleStore.save(SignInRole.technician));
    // Keep the server's view of this technician (incl. documentsDeferred).
    if (result.json != null) ref.read(technicianMeProvider.notifier).state = result.json;
    state = state.copyWith(
        verifying: false,
        submitting: false,
        stage: stageFromTechnicianJson(result.json));
    return true;
  }

  Future<bool> registerWithEmail(String email, String password) => _submit(
      () => ref.read(authServiceProvider).registerWithEmail(email: email, password: password));

  Future<bool> signInWithEmail(String email, String password) => _submit(
      () => ref.read(authServiceProvider).signInWithEmail(email: email, password: password));

  Future<bool> signInWithGoogle() {
    final selected = state.signInRole;
    if (selected == null) {
      state = state.copyWith(error: 'Choose how you are signing in first.');
      return Future.value(false);
    }
    return _submit(() => ref.read(authServiceProvider).signInWithGoogle(),
        picked: selected);
  }

  Future<bool> _submit(Future<void> Function() action, {SignInRole? picked}) async {
    state = state.copyWith(submitting: true, clearError: true);
    try {
      await action();
      unawaited(ref.read(technicianProfileServiceProvider).touchProfile());
      if (picked == SignInRole.owner || picked == SignInRole.staff) {
        return _finishStaff(picked!, verifying: false);
      }
      return _finishTechnician(verifying: false);
    } on AuthException catch (e) {
      state = state.copyWith(submitting: false, error: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(submitting: false, error: 'Something went wrong. Try again.');
      return false;
    }
  }

  void _setStaffRole(AdminRole? role) {
    latestKnownStaffRole = role;
    state = state.copyWith(staffRole: role, clearStaffRole: role == null);
  }

  void setStaffRole(AdminRole? role) => _setStaffRole(role);

  void reset() {
    latestKnownStaffRole = null;
    unawaited(SignInRoleStore.save(null));
    ref.invalidate(technicianMeProvider);
    state = const AuthFlowState();
  }
}
