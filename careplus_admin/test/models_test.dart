import 'package:flutter_test/flutter_test.dart';
import 'package:care_plus_admin/data/models.dart';
import 'package:care_plus_admin/state/auth_providers.dart';

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

    test('label returns friendly display string', () {
      expect(AdminRole.owner.label, 'Owner');
      expect(AdminRole.staff.label, 'Staff member');
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
      const account = StaffAccount(
        id: 'staff1',
        name: 'John Doe',
        initials: 'JD',
        phone: '9876543210',
        role: AdminRole.staff,
        status: StaffStatus.active,
        lastActive: 'Just now',
      );

      expect(account.id, 'staff1');
      expect(account.name, 'John Doe');
      expect(account.initials, 'JD');
      expect(account.phone, '9876543210');
      expect(account.role, AdminRole.staff);
      expect(account.status, StaffStatus.active);
      expect(account.lastActive, 'Just now');
    });

    test('can create owner account', () {
      const account = StaffAccount(
        id: 'owner1',
        name: 'Owner',
        initials: 'OW',
        phone: '9123456780',
        role: AdminRole.owner,
        status: StaffStatus.active,
        lastActive: '2h ago',
      );

      expect(account.role, AdminRole.owner);
      expect(account.initials, 'OW');
    });

    test('can create suspended staff account', () {
      const account = StaffAccount(
        id: 'staff2',
        name: 'Jane Smith',
        initials: 'JS',
        phone: '9876543211',
        role: AdminRole.staff,
        status: StaffStatus.suspended,
        lastActive: 'Yesterday',
      );

      expect(account.status, StaffStatus.suspended);
    });
  });

  group('Money', () {
    test('rupees formats paise without decimals', () {
      expect(Money.rupees(89900), '₹899');
      expect(Money.rupees(0), '₹0');
    });

    test('rupeesDecimal formats paise with decimals', () {
      expect(Money.rupeesDecimal(89950), '₹899.50');
      expect(Money.rupeesDecimal(0), '₹0.00');
    });
  });

  group('AdminStockItem', () {
    test('fillFraction calculates stock proportion correctly', () {
      const item = AdminStockItem(
        id: 's1',
        name: 'Filter',
        sku: 'FLT-01',
        inStock: 5,
        reorderAt: 10,
        low: true,
      );
      expect(item.fillFraction, 0.5);
    });

    test('fillFraction clamps at 1.0 when overstocked', () {
      const item = AdminStockItem(
        id: 's2',
        name: 'Filter',
        sku: 'FLT-02',
        inStock: 20,
        reorderAt: 10,
        low: false,
      );
      expect(item.fillFraction, 1.0);
    });
  });

  group('AuthFlowState', () {
    test('default role is owner', () {
      const state = AuthFlowState();
      expect(state.role, AdminRole.owner);
    });

    test('default phone is empty', () {
      const state = AuthFlowState();
      expect(state.phone, '');
    });

    test('copyWith updates role', () {
      const state = AuthFlowState();
      final updated = state.copyWith(role: AdminRole.staff);
      
      expect(state.role, AdminRole.owner);
      expect(updated.role, AdminRole.staff);
    });

    test('copyWith updates phone', () {
      const state = AuthFlowState();
      final updated = state.copyWith(phone: '9876543210');
      
      expect(state.phone, '');
      expect(updated.phone, '9876543210');
    });

    test('clearError removes error', () {
      const state = AuthFlowState(error: 'Test error');
      final cleared = state.copyWith(clearError: true);
      
      expect(state.error, 'Test error');
      expect(cleared.error, isNull);
    });
  });

  group('latestKnownAdminRole', () {
    test('default is owner', () {
      expect(latestKnownAdminRole, AdminRole.owner);
    });

    test('can be updated and restored', () {
      final previous = latestKnownAdminRole;
      addTearDown(() => latestKnownAdminRole = previous);
      latestKnownAdminRole = AdminRole.staff;
      expect(latestKnownAdminRole, AdminRole.staff);
    });
  });
}
