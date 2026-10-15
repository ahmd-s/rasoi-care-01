import 'package:care_plus_partner/features/passport/inspection_catalog.dart';
import 'package:care_plus_partner/features/passport/passport_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

const _expected = <String, List<String>>{
  'chimney': [
    'Suction performance', 'Filter condition', 'Grease and dirt', 'Motor condition',
    'Controls and lights', 'Duct and airflow', 'Physical condition', 'Safety',
  ],
  'hob': [
    'Burner performance', 'Ignition', 'Gas flow', 'Burner and cap condition',
    'Pan support', 'Glass / surface', 'Knobs and controls', 'Safety',
  ],
  'microwave': [
    'Heating performance', 'Power / operation', 'Door and seal', 'Turntable',
    'Controls / display', 'Interior condition', 'Noise / vibration', 'Electrical safety',
  ],
  'oven': [
    'Heating performance', 'Temperature control', 'Heating elements', 'Door and seal',
    'Controls / timer', 'Interior condition', 'Fan / convection', 'Electrical safety',
  ],
  'dishwasher': [
    'Cleaning performance', 'Water inlet', 'Drainage', 'Spray arms', 'Filter condition',
    'Door and seal', 'Noise / vibration', 'Electrical safety',
  ],
  'refrigerator': [
    'Cooling performance', 'Compressor', 'Door seal', 'Frost / ice condition', 'Drainage',
    'Interior condition', 'Fan / airflow', 'Electrical safety',
  ],
  'ro_purifier': [
    'Purification / TDS performance', 'RO membrane condition', 'Pre-filter / sediment filter',
    'Carbon filter condition', 'Water leakage', 'Storage tank / float',
    'Pump / flow condition', 'Electrical and safety',
  ],
};

void main() {
  test('every registered category has exactly its own 8-item checklist', () {
    expect(kInspectionChecklists.keys.toSet(), kApplianceCategories.map((c) => c.id).toSet());
    for (final c in kApplianceCategories) {
      final items = checklistFor(c.id);
      expect(items.map((i) => i.label).toList(), _expected[c.id], reason: c.id);
      expect(items.map((i) => i.key).toSet().length, 8, reason: '${c.id} keys unique');
    }
  });

  test('unknown category has no checklist', () {
    expect(checklistFor('toaster'), isEmpty);
  });

  test('results map to the backend wire values', () {
    expect(InspectionResult.values.map((r) => r.wire), ['good', 'attention', 'not_tested']);
    expect(InspectionResult.values.map((r) => r.label), ['Good', 'Attention', 'Not tested']);
    expect(InspectionResult.fromWire('not_tested'), InspectionResult.notTested);
    expect(InspectionResult.fromWire(null), isNull);
    expect(InspectionResult.fromWire('excellent'), isNull);
  });
}
