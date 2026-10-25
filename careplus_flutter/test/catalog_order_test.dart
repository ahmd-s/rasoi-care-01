import 'package:care_plus/data/mock_repository.dart';
import 'package:care_plus/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final repo = MockRepository();

  test('chimney starts with Steam deep clean (1299) then Deep clean (1699)', () {
    final s = repo.servicesFor(Appliance.chimney);
    expect(s[0].id, 'svc_chimney_steam_deep_clean');
    expect(s[0].pricePaise, 129900);
    expect(s[1].id, 'svc_chimney_deep_clean_full');
    expect(s[1].pricePaise, 169900);
  });

  test('hob install and uninstall prices', () {
    final s = repo.servicesFor(Appliance.hob);
    expect(s.firstWhere((x) => x.id == 'svc_hob_install').pricePaise, 49900);
    expect(s.firstWhere((x) => x.id == 'svc_hob_uninstall').pricePaise, 29900);
  });
}
