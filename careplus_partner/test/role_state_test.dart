import 'package:care_plus_partner/data/api/staff_bootstrap_service.dart';
import 'package:care_plus_partner/data/auth/auth_service.dart';
import 'package:care_plus_partner/data/operations/models.dart';
import 'package:care_plus_partner/state/auth_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

class _FakeStaff extends StaffBootstrapService {
  _FakeStaff(this.next);
  StaffBootstrapResult next;
  @override
  Future<StaffBootstrapResult> bootstrap() async => next;
}

const _owner = StaffBootstrapResult(role: AdminRole.owner);
const _staff = StaffBootstrapResult(role: AdminRole.staff);
const _notStaff = StaffBootstrapResult(notStaff: true);

void main() {
  late _FakeStaff staffSvc;
  late Map<String, dynamic>? tech;
  late ProviderContainer c;

  setUp(() {
    latestKnownStaffRole = null;
    staffSvc = _FakeStaff(_notStaff);
    tech = {'applicationSubmitted': true, 'verified': true};
    c = ProviderContainer(overrides: [
      authServiceProvider.overrideWithValue(_FakeAuth()),
      staffBootstrapServiceProvider.overrideWithValue(staffSvc),
      technicianBootstrapProvider.overrideWithValue(() async => tech),
    ]);
    addTearDown(c.dispose);
  });

  Future<bool> phoneLogin() async {
    final vm = c.read(authFlowProvider.notifier);
    await vm.sendOtp('8668690490');
    return vm.verifyOtp('123456');
  }

  test('approved technician signing in again goes to jobs, not ops', () async {
    expect(await phoneLogin(), isTrue);
    expect(c.read(authFlowProvider).staffRole, isNull);
    expect(latestKnownStaffRole, isNull);
    expect(c.read(authFlowProvider).stage, TechnicianStage.jobs);
  });

  test('stale owner role does not survive owner sign-out then technician OTP login', () async {
    final vm = c.read(authFlowProvider.notifier);
    vm.setStaffRole(AdminRole.owner); // owner Google session
    // Sign out path that forgot to reset (previous biometric-lock bug) —
    // the next phone login must still not inherit the role.
    expect(await phoneLogin(), isTrue);
    expect(c.read(authFlowProvider).staffRole, isNull);
    expect(latestKnownStaffRole, isNull);
  });

  test('stale role is cleared even if send step is skipped', () async {
    c.read(authFlowProvider.notifier).setStaffRole(AdminRole.staff);
    final vm = c.read(authFlowProvider.notifier);
    await vm.sendOtp('8668690490');
    expect(latestKnownStaffRole, isNull);
  });

  test('phone explicitly authorised as staff still routes to staff', () async {
    staffSvc.next = _staff;
    expect(await phoneLogin(), isTrue);
    expect(c.read(authFlowProvider).staffRole, AdminRole.staff);
    expect(latestKnownStaffRole, AdminRole.staff);
  });

  test('transient staff-check error does not leave a stale role', () async {
    c.read(authFlowProvider.notifier).setStaffRole(AdminRole.owner);
    staffSvc.next = const StaffBootstrapResult(error: 'offline');
    expect(await phoneLogin(), isTrue);
    expect(c.read(authFlowProvider).staffRole, isNull);
  });

  test('unapproved technician is sent to pending/apply, never jobs', () async {
    tech = {'applicationSubmitted': true, 'verified': false};
    await phoneLogin();
    expect(c.read(authFlowProvider).stage, TechnicianStage.pending);
    tech = {'applicationSubmitted': false, 'verified': false};
    await phoneLogin();
    expect(c.read(authFlowProvider).stage, TechnicianStage.apply);
  });

  test('failed technician bootstrap fails closed instead of showing jobs', () async {
    tech = null;
    expect(await phoneLogin(), isFalse);
    expect(c.read(authFlowProvider).error, isNotNull);
    expect(c.read(authFlowProvider).verifying, isFalse);
  });

  test('Google sign-in rejected by backend clears role and signs out', () async {
    final vm = c.read(authFlowProvider.notifier);
    vm.setStaffRole(AdminRole.owner);
    expect(await vm.signInWithGoogle(), isFalse);
    expect(latestKnownStaffRole, isNull);
    expect(c.read(authServiceProvider).isSignedIn, isFalse);
  });

  test('Google sign-in as allowlisted owner sets owner; reset clears everything', () async {
    staffSvc.next = _owner;
    final vm = c.read(authFlowProvider.notifier);
    expect(await vm.signInWithGoogle(), isTrue);
    expect(latestKnownStaffRole, AdminRole.owner);
    vm.reset();
    expect(latestKnownStaffRole, isNull);
    expect(c.read(authFlowProvider).staffRole, isNull);
    expect(c.read(authFlowProvider).phone, isEmpty);
  });
}
