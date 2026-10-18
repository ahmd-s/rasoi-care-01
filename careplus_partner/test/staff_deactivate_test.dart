import 'package:care_plus_partner/core/theme/care_plus_theme.dart';
import 'package:care_plus_partner/data/operations/api_repository.dart';
import 'package:care_plus_partner/data/operations/models.dart';
import 'package:care_plus_partner/features/operations/staff_access_screen.dart';
import 'package:care_plus_partner/state/operations_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repo extends ChangeNotifier implements OperationsApiRepository {
  _Repo(this.accounts);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  List<StaffAccount> accounts;
  final calls = <String>[];
  @override
  List<StaffAccount>? staffAccounts() => accounts;
  @override
  bool fetchFailed(String key) => false;
  @override
  Future<bool> setStaffActive(String staffId, bool active) async {
    calls.add('$staffId:$active');
    return true;
  }
}

StaffAccount _acct(String id, AdminRole role, StaffStatus st) => StaffAccount(
    id: id, name: 'Name $id', initials: 'N', phone: '9000000000', role: role, status: st, lastActive: 'now');

Future<_Repo> _pump(WidgetTester t, List<StaffAccount> a) async {
  t.view.physicalSize = const Size(1080, 3000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final repo = _Repo(a);
  await t.pumpWidget(ProviderScope(
    overrides: [operationsRepositoryProvider.overrideWith((ref) => repo)],
    child: MaterialApp(theme: CarePlusTheme.light(), home: const StaffAccessScreen()),
  ));
  await t.pump();
  return repo;
}

void main() {
  testWidgets('deactivate asks for confirmation and only then revokes', (t) async {
    final repo = await _pump(t, [
      _acct('o', AdminRole.owner, StaffStatus.active),
      _acct('s', AdminRole.staff, StaffStatus.active),
    ]);
    expect(find.text('Deactivate'), findsOneWidget); // none for the owner row
    await t.tap(find.text('Deactivate'));
    await t.pumpAndSettle();
    expect(find.textContaining('does not delete them'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(repo.calls, isEmpty);

    await t.tap(find.text('Deactivate'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, 'Deactivate'));
    await t.pumpAndSettle();
    expect(repo.calls, ['s:false']);
  });

  testWidgets('deactivated staff show as such and can be reinstated', (t) async {
    final repo = await _pump(t, [_acct('s', AdminRole.staff, StaffStatus.suspended)]);
    expect(find.text('Deactivated'), findsOneWidget);
    await t.tap(find.text('Reinstate'));
    await t.pumpAndSettle();
    expect(repo.calls, ['s:true']);
  });
}
