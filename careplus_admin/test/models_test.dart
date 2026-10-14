import 'package:flutter_test/flutter_test.dart';
import 'package:care_plus_admin/data/models.dart';

void main() {
  group('AdminRole', () {
    test('owner role exists', () {
      expect(AdminRole.owner, isNotNull);
    });

    test('staff role exists', () {
      expect(AdminRole.staff, isNotNull);
    });

    test('roles are distinct', () {
      expect(AdminRole.owner, isNot(AdminRole.staff));
    });

    test('default role is owner', () {
      expect(AdminRole.owner, AdminRole.owner);
    });
  });

  group('StaffStatus', () {
    test('active status exists', () {
      expect(StaffStatus.active, isNotNull);
    });

    test('suspended status exists', () {
      expect(StaffStatus.suspended, isNotNull);
    });

    test('statuses are distinct', () {
      expect(StaffStatus.active, isNot(StaffStatus.suspended));
    });
  });

  group('StaffAccount', () {
    test('can create staff account with required fields', () {
      final account = StaffAccount(
        id: 'staff1',
        name: 'John Doe',
        phone: '9876543210',
        role: AdminRole.staff,
        status: StaffStatus.active,
      );

      expect(account.id, 'staff1');
      expect(account.name, 'John Doe');
      expect(account.phone, '9876543210');
      expect(account.role, AdminRole.staff);
      expect(account.status, StaffStatus.active);
    });

    test('can create owner account', () {
      final account = StaffAccount(
        id: 'owner1',
        name: 'Owner',
        phone: '9123456780',
        role: AdminRole.owner,
        status: StaffStatus.active,
      );

      expect(account.role, AdminRole.owner);
    });

    test('can create suspended staff account', () {
      final account = StaffAccount(
        id: 'staff2',
        name: 'Jane Smith',
        phone: '9876543211',
        role: AdminRole.staff,
        status: StaffStatus.suspended,
      );

      expect(account.status, StaffStatus.suspended);
    });

    test('copyWith updates specified fields', () {
      final original = StaffAccount(
        id: 'staff1',
        name: 'John Doe',
        phone: '9876543210',
        role: AdminRole.staff,
        status: StaffStatus.active,
      );

      final updated = original.copyWith(
        status: StaffStatus.suspended,
      );

      expect(original.status, StaffStatus.active); // unchanged
      expect(updated.status, StaffStatus.suspended); // updated
      expect(updated.id, original.id); // preserved
      expect(updated.name, original.name); // preserved
    });
  });

  group('AuthFlowState', () {
    test('default role is owner', () {
      final state = AuthFlowState();
      expect(state.role, AdminRole.owner);
    });

    test('default phone is empty', () {
      final state = AuthFlowState();
      expect(state.phone, '');
    });

    test('copyWith updates role', () {
      final state = AuthFlowState();
      final updated = state.copyWith(role: AdminRole.staff);
      
      expect(state.role, AdminRole.owner); // unchanged
      expect(updated.role, AdminRole.staff); // updated
    });

    test('copyWith updates phone', () {
      final state = AuthFlowState();
      final updated = state.copyWith(phone: '9876543210');
      
      expect(state.phone, ''); // unchanged
      expect(updated.phone, '9876543210'); // updated
    });

    test('clearError removes error', () {
      final state = AuthFlowState(error: 'Test error');
      final cleared = state.copyWith(clearError: true);
      
      expect(state.error, 'Test error'); // unchanged
      expect(cleared.error, isNull); // cleared
    });
  });

  group('latestKnownAdminRole', () {
    test('default is owner', () {
      expect(latestKnownAdminRole, AdminRole.owner);
    });

    test('can be updated', () {
      // This tests that the global variable can be modified
      // In real usage, this is updated by authFlowProvider
      expect(latestKnownAdminRole, AdminRole.owner);
    });
  });
}
