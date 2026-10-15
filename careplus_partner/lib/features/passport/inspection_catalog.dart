// Kitchen Passport (V9.7) — appliance-specific technician inspection
// checklists. Keys and labels must match CHECKLISTS in /kitchen_passport.py
// (tests/test_kitchen_inspection.py fails if they drift); the backend rejects
// any key that isn't on the appliance's own checklist.

class InspectionItem {
  const InspectionItem(this.key, this.label);
  final String key;
  final String label;
}

/// What the technician observed. [notTested] is explicit so a skipped item is
/// never mistaken for a passed one. [wire] is the value sent to the backend.
enum InspectionResult {
  good('good', 'Good'),
  attention('attention', 'Attention'),
  notTested('not_tested', 'Not tested');

  const InspectionResult(this.wire, this.label);
  final String wire;
  final String label;

  static InspectionResult? fromWire(String? value) {
    for (final r in values) {
      if (r.wire == value) return r;
    }
    return null;
  }
}

const kMaxInspectionNoteLength = 300;

/// Checklist per category id (same ids as kApplianceCategories).
const kInspectionChecklists = <String, List<InspectionItem>>{
  'chimney': [
    InspectionItem('suction_performance', 'Suction performance'),
    InspectionItem('filter_condition', 'Filter condition'),
    InspectionItem('grease_and_dirt', 'Grease and dirt'),
    InspectionItem('motor_condition', 'Motor condition'),
    InspectionItem('controls_and_lights', 'Controls and lights'),
    InspectionItem('duct_and_airflow', 'Duct and airflow'),
    InspectionItem('physical_condition', 'Physical condition'),
    InspectionItem('safety', 'Safety'),
  ],
  'hob': [
    InspectionItem('burner_performance', 'Burner performance'),
    InspectionItem('ignition', 'Ignition'),
    InspectionItem('gas_flow', 'Gas flow'),
    InspectionItem('burner_and_cap_condition', 'Burner and cap condition'),
    InspectionItem('pan_support', 'Pan support'),
    InspectionItem('glass_surface', 'Glass / surface'),
    InspectionItem('knobs_and_controls', 'Knobs and controls'),
    InspectionItem('safety', 'Safety'),
  ],
  'microwave': [
    InspectionItem('heating_performance', 'Heating performance'),
    InspectionItem('power_operation', 'Power / operation'),
    InspectionItem('door_and_seal', 'Door and seal'),
    InspectionItem('turntable', 'Turntable'),
    InspectionItem('controls_display', 'Controls / display'),
    InspectionItem('interior_condition', 'Interior condition'),
    InspectionItem('noise_vibration', 'Noise / vibration'),
    InspectionItem('electrical_safety', 'Electrical safety'),
  ],
  'oven': [
    InspectionItem('heating_performance', 'Heating performance'),
    InspectionItem('temperature_control', 'Temperature control'),
    InspectionItem('heating_elements', 'Heating elements'),
    InspectionItem('door_and_seal', 'Door and seal'),
    InspectionItem('controls_timer', 'Controls / timer'),
    InspectionItem('interior_condition', 'Interior condition'),
    InspectionItem('fan_convection', 'Fan / convection'),
    InspectionItem('electrical_safety', 'Electrical safety'),
  ],
  'dishwasher': [
    InspectionItem('cleaning_performance', 'Cleaning performance'),
    InspectionItem('water_inlet', 'Water inlet'),
    InspectionItem('drainage', 'Drainage'),
    InspectionItem('spray_arms', 'Spray arms'),
    InspectionItem('filter_condition', 'Filter condition'),
    InspectionItem('door_and_seal', 'Door and seal'),
    InspectionItem('noise_vibration', 'Noise / vibration'),
    InspectionItem('electrical_safety', 'Electrical safety'),
  ],
  'refrigerator': [
    InspectionItem('cooling_performance', 'Cooling performance'),
    InspectionItem('compressor', 'Compressor'),
    InspectionItem('door_seal', 'Door seal'),
    InspectionItem('frost_ice_condition', 'Frost / ice condition'),
    InspectionItem('drainage', 'Drainage'),
    InspectionItem('interior_condition', 'Interior condition'),
    InspectionItem('fan_airflow', 'Fan / airflow'),
    InspectionItem('electrical_safety', 'Electrical safety'),
  ],
  'ro_purifier': [
    InspectionItem('purification_tds_performance', 'Purification / TDS performance'),
    InspectionItem('ro_membrane_condition', 'RO membrane condition'),
    InspectionItem('pre_filter_sediment', 'Pre-filter / sediment filter'),
    InspectionItem('carbon_filter_condition', 'Carbon filter condition'),
    InspectionItem('water_leakage', 'Water leakage'),
    InspectionItem('storage_tank_float', 'Storage tank / float'),
    InspectionItem('pump_flow_condition', 'Pump / flow condition'),
    InspectionItem('electrical_and_safety', 'Electrical and safety'),
  ],
};

List<InspectionItem> checklistFor(String categoryId) =>
    kInspectionChecklists[categoryId] ?? const [];
