import 'package:care_plus_partner/data/api/staff_bootstrap_service.dart';
import 'package:care_plus_partner/data/auth/auth_service.dart';
import 'package:care_plus_partner/data/operations/models.dart';
import 'package:care_plus_partner/state/auth_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuth implements AuthService {
  bool signedIn = false;
  @override
  bool get isLive => true;
  @override
  bool get isSignedIn => signedIn;
  @override
  Future<OtpSent> sendOtp(String e164Phone) async => const OtpSent('vid');
  @override
  Future<void> verifyOtp({required String verificationId, required String smsCode}) async =>
      signedIn = true;
  @override
  Future<void> registerWithEmail({required String email, required String password}) async {}
  @override
  Future<void> signInWithEmail({required String email, required String password}) async {}
  @override
  Future<void> signInWithGoogle() async => signedIn = true;
  @override
  Future<void> signOut() async => signedIn = false;
}

/// Mirrors the backend contract: the resolved role comes from the identity's
/// records; the requested role must MATCH it, never grants anything.
class _FakeStaff extends StaffBootstrapService {
  AdminRole? resolved; // what the roster/allowlist says about this identity
  final requests = <String?>[];
  @override
  Future<StaffBootstrapResult> bootstrap({String? requestedRole}) async {
    requests.add(requestedRole);
    if (resolved == null) {
      return const StaffBootstrapResult(
          notStaff: true, error: 'No active staff invitation for this identity');
    }
    if (requestedRole == 'owner' && resolved != AdminRole.owner) {
      return const StaffBootstrapResult(notStaff: true, error: 'Owner sign-in requires the configured owner Google account');
    }
    if (requestedRole == 'staff' && resolved == AdminRole.owner) {
      return const StaffBootstrapResult(notStaff: true, error: 'This is the owner account. Choose Owner to sign in.');
    }
    return StaffBootstrapResult(role: resolved);
  }
}

void main() {
  late _FakeStaff staffSvc;
  late _FakeAuth auth;
  late TechnicianBootstrapResult techResult;
  late ProviderContainer c;
  var techCalls = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    latestKnownStaffRole = null;
    techCalls = 0;
    staffSvc = _FakeStaff();
    auth = _FakeAuth();
    techResult = const TechnicianBootstrapResult(
        json: {'applicationSubmitted': true, 'verified': true});
    c = ProviderContainer(overrides: [
      authServiceProvider.overrideWithValue(auth),
      staffBootstrapServiceProvider.overrideWithValue(staffSvc),
      technicianBootstrapProvider.overrideWithValue(() async {
        techCalls++;
        return techResult;
      }),
    ]);
    addTearDown(c.dispose);
  });

  AuthFlowVM vm() => c.read(authFlowProvider.notifier);
  AuthFlowState st() => c.read(authFlowProvider);

  Future<bool> phoneLogin(SignInRole role) async {
    vm().selectRole(role);
    await vm().sendOtp('8668690490');
    return vm().verifyOtp('123456');
  }

  group('Technician selected', () {
    test('approved technician goes to jobs and never consults the staff roster', () async {
      staffSvc.resolved = AdminRole.staff; // also an active staff record
      expect(await phoneLogin(SignInRole.technician), isTrue);
      expect(staffSvc.requests, isEmpty);
      expect(st().staffRole, isNull);
      expect(latestKnownStaffRole, isNull);
      expect(st().stage, TechnicianStage.jobs);
      expect(techCalls, 1);
    });

    test("the server's technician record (incl. documentsDeferred) is kept for the apply form", () async {
      techResult = const TechnicianBootstrapResult(json: {
        'applicationSubmitted': false,
        'verified': false,
        'documentsDeferred': true,
      });
      expect(await phoneLogin(SignInRole.technician), isTrue);
      expect(c.read(technicianMeProvider)?['documentsDeferred'], true);
      expect(st().stage, TechnicianStage.apply); // still onboarding, not jobs
    });

    test('stale owner/staff role is cleared when Technician is chosen', () async {
      vm().setStaffRole(AdminRole.owner);
      expect(await phoneLogin(SignInRole.technician), isTrue);
      expect(st().staffRole, isNull);
      expect(latestKnownStaffRole, isNull);
    });

    test('unapproved technician lands on pending/apply, never jobs', () async {
      techResult = const TechnicianBootstrapResult(
          json: {'applicationSubmitted': true, 'verified': false});
      await phoneLogin(SignInRole.technician);
      expect(st().stage, TechnicianStage.pending);
      techResult = const TechnicianBootstrapResult(
          json: {'applicationSubmitted': false, 'verified': false});
      await phoneLogin(SignInRole.technician);
      expect(st().stage, TechnicianStage.apply);
    });

    test('backend refusal (staff-only identity) shows an access error and signs out', () async {
      techResult = const TechnicianBootstrapResult(
          denied: 'This account is a staff or owner account and has no technician profile');
      expect(await phoneLogin(SignInRole.technician), isFalse);
      expect(st().error, contains('no technician profile'));
      expect(auth.isSignedIn, isFalse);
      expect(st().staffRole, isNull);
    });

    test('unreachable technician bootstrap fails closed', () async {
      techResult = const TechnicianBootstrapResult();
      expect(await phoneLogin(SignInRole.technician), isFalse);
      expect(st().error, isNotNull);
    });
  });

  group('Staff selected', () {
    test('invited staff phone routes to staff, requesting only "staff"', () async {
      staffSvc.resolved = AdminRole.staff;
      expect(await phoneLogin(SignInRole.staff), isTrue);
      expect(staffSvc.requests, ['staff']);
      expect(st().staffRole, AdminRole.staff);
      expect(techCalls, 0);
    });

    test('technician-only phone is rejected: access error, signed out, no fallback', () async {
      staffSvc.resolved = null;
      expect(await phoneLogin(SignInRole.staff), isFalse);
      expect(st().error, isNotNull);
      expect(auth.isSignedIn, isFalse);
      expect(st().staffRole, isNull);
      expect(techCalls, 0); // did not silently fall back to Technician
    });

    test('an owner identity choosing Staff is rejected', () async {
      staffSvc.resolved = AdminRole.owner;
      expect(await phoneLogin(SignInRole.staff), isFalse);
      expect(st().staffRole, isNull);
      expect(auth.isSignedIn, isFalse);
    });

    test('Google as Staff for a non-staff Gmail is rejected', () async {
      staffSvc.resolved = null;
      vm().selectRole(SignInRole.staff);
      expect(await vm().signInWithGoogle(), isFalse);
      expect(latestKnownStaffRole, isNull);
      expect(auth.isSignedIn, isFalse);
    });
  });

  group('Owner selected', () {
    test('phone OTP is refused for Owner', () async {
      staffSvc.resolved = AdminRole.owner;
      expect(await phoneLogin(SignInRole.owner), isFalse);
      expect(st().error, contains('Google only'));
      expect(st().staffRole, isNull);
      expect(staffSvc.requests, isEmpty);
    });

    test('allowlisted owner Google account becomes owner', () async {
      staffSvc.resolved = AdminRole.owner;
      vm().selectRole(SignInRole.owner);
      expect(await vm().signInWithGoogle(), isTrue);
      expect(staffSvc.requests, ['owner']);
      expect(latestKnownStaffRole, AdminRole.owner);
    });

    test('non-allowlisted Google account is rejected and signed out', () async {
      staffSvc.resolved = AdminRole.staff; // a staff Gmail is still not the owner
      vm().selectRole(SignInRole.owner);
      expect(await vm().signInWithGoogle(), isFalse);
      expect(latestKnownStaffRole, isNull);
      expect(st().staffRole, isNull);
      expect(auth.isSignedIn, isFalse);
      expect(st().error, isNotNull);
    });
  });

  group('Google as Technician and general state', () {
    test('Google sign-in without choosing a role is refused', () async {
      expect(await vm().signInWithGoogle(), isFalse);
      expect(auth.isSignedIn, isFalse);
    });

    test('Google as Technician runs only the technician bootstrap', () async {
      vm().selectRole(SignInRole.technician);
      expect(await vm().signInWithGoogle(), isTrue);
      expect(staffSvc.requests, isEmpty);
      expect(st().stage, TechnicianStage.jobs);
    });

    test('selected role is remembered, and reset() clears role and memory', () async {
      staffSvc.resolved = AdminRole.staff;
      await phoneLogin(SignInRole.staff);
      await Future<void>.delayed(Duration.zero);
      expect(await SignInRoleStore.load(), SignInRole.staff);
      vm().reset();
      await Future<void>.delayed(Duration.zero);
      expect(await SignInRoleStore.load(), isNull);
      expect(latestKnownStaffRole, isNull);
      expect(st().staffRole, isNull);
      expect(st().signInRole, isNull);
      expect(st().phone, isEmpty);
    });
  });
}
