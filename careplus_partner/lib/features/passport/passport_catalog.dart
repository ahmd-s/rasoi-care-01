// Kitchen Passport (V9.7) — the seven appliance categories, their
// appliance-specific registration fields and brand catalogs.
//
// The appliance selector *is* the category: there is deliberately no generic
// "Type" field, only attributes that mean something for that appliance.
// Category ids and spec keys must match /kitchen_passport.py on the backend
// (test/passport_catalog_test.dart pins the ids; the backend rejects anything
// it doesn't know).

import 'dart:math';

enum SpecKind { choice, integer }

class SpecField {
  const SpecField.choice(this.key, this.label, this.choices, {this.required = true})
      : kind = SpecKind.choice,
        min = null,
        max = null,
        unit = null;
  const SpecField.integer(this.key, this.label,
      {required int this.min, required int this.max, this.unit, this.required = true})
      : kind = SpecKind.integer,
        choices = const {};

  final String key;
  final String label;
  final SpecKind kind;

  /// Choice value (sent to the backend) -> label (shown to the technician).
  final Map<String, String> choices;
  final int? min;
  final int? max;
  final String? unit;
  final bool required;

  /// Null when [raw] is acceptable, else a message for the form field.
  String? validate(String? raw) {
    final v = raw?.trim() ?? '';
    if (v.isEmpty) return required ? 'Required' : null;
    if (kind == SpecKind.choice) {
      return choices.containsKey(v) ? null : 'Choose one';
    }
    final n = int.tryParse(v);
    if (n == null) return 'Enter a whole number';
    if (n < min! || n > max!) return 'Between $min and $max';
    return null;
  }
}

class ApplianceCategory {
  const ApplianceCategory({
    required this.id,
    required this.label,
    required this.glyph,
    required this.brands,
    required this.fields,
  });
  final String id;
  final String label;
  final String glyph;

  /// Predefined brands for this category, alphabetical. The UI appends
  /// [kBrandOther] and any technician-saved custom brands.
  final List<String> brands;
  final List<SpecField> fields;
}

const kBrandOther = 'Other';
const kMaxBrandLength = 60;

/// Collapses whitespace so "Bosch " and "Bosch" are the same brand.
String normaliseBrand(String name) =>
    name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).join(' ');

/// Null when [name] can be saved as a brand, else the problem.
String? validateBrandName(String? name) {
  final n = normaliseBrand(name ?? '');
  if (n.isEmpty) return 'Enter a brand name';
  if (n.length > kMaxBrandLength) return 'At most $kMaxBrandLength characters';
  if (n.toLowerCase() == kBrandOther.toLowerCase()) return 'Enter the real brand name';
  return null;
}

/// Finds [name] in [existing] ignoring case, so Add Brand re-selects a brand
/// that is already listed instead of creating a duplicate.
String? matchBrand(String name, Iterable<String> existing) {
  final key = normaliseBrand(name).toLowerCase();
  for (final b in existing) {
    if (b.toLowerCase() == key) return b;
  }
  return null;
}

const kInstallYearMin = 1990;

/// Null when [raw] is empty (optional) or a plausible year.
String? validateInstallYear(String? raw, {required int currentYear}) {
  final v = raw?.trim() ?? '';
  if (v.isEmpty) return null;
  final n = int.tryParse(v);
  if (n == null) return 'Enter a year';
  if (n < kInstallYearMin || n > currentYear) return '$kInstallYearMin–$currentYear';
  return null;
}

const kApplianceCategories = <ApplianceCategory>[
  ApplianceCategory(
    id: 'chimney',
    label: 'Chimney',
    glyph: '◍',
    brands: [
      'Bosch', 'Elica', 'Faber', 'Glen', 'Hindware', 'Kaff', 'Kutchina',
      'Prestige', 'Sunflame', 'Whirlpool',
    ],
    fields: [
      SpecField.choice('mounting', 'Mounting', {
        'wall_mounted': 'Wall mounted',
        'island': 'Island',
        'built_in': 'Built-in',
      }),
      SpecField.choice('filter', 'Filter', {
        'baffle': 'Baffle',
        'mesh': 'Mesh',
        'carbon': 'Carbon',
      }),
      SpecField.integer('width_cm', 'Width', min: 30, max: 150, unit: 'cm'),
      SpecField.integer('suction_m3h', 'Suction capacity',
          min: 200, max: 3000, unit: 'm³/h', required: false),
    ],
  ),
  ApplianceCategory(
    id: 'hob',
    label: 'Hob / Cooktop',
    glyph: '⊙',
    brands: [
      'Bosch', 'Elica', 'Faber', 'Glen', 'Hindware', 'Kaff', 'Prestige',
      'Preethi', 'Sunflame', 'Surya',
    ],
    fields: [
      SpecField.choice('fuel', 'Fuel', {
        'gas': 'Gas',
        'induction': 'Induction',
        'electric_radiant': 'Electric radiant',
      }),
      SpecField.integer('burners', 'Burners / zones', min: 1, max: 6),
    ],
  ),
  ApplianceCategory(
    id: 'microwave',
    label: 'Microwave',
    glyph: '▣',
    brands: [
      'Bajaj', 'Bosch', 'Godrej', 'IFB', 'LG', 'Panasonic', 'Samsung',
      'Siemens', 'Whirlpool',
    ],
    fields: [
      SpecField.choice('style', 'Style', {
        'solo': 'Solo',
        'grill': 'Grill',
        'convection': 'Convection',
      }),
      SpecField.choice('mounting', 'Mounting', {
        'countertop': 'Countertop',
        'built_in': 'Built-in',
      }),
      SpecField.integer('capacity_litres', 'Capacity', min: 10, max: 60, unit: 'L'),
    ],
  ),
  ApplianceCategory(
    id: 'oven',
    label: 'OTG / Oven',
    glyph: '▦',
    brands: [
      'Bajaj', 'Bosch', 'Faber', 'Glen', 'Havells', 'IFB', 'Morphy Richards',
      'Prestige', 'Siemens', 'Usha',
    ],
    fields: [
      SpecField.choice('mounting', 'Mounting', {
        'countertop': 'Countertop',
        'built_in': 'Built-in',
      }),
      SpecField.integer('capacity_litres', 'Capacity', min: 9, max: 120, unit: 'L'),
      SpecField.choice('convection', 'Convection fan', {'yes': 'Yes', 'no': 'No'}),
    ],
  ),
  ApplianceCategory(
    id: 'dishwasher',
    label: 'Dishwasher',
    glyph: '▥',
    brands: [
      'Bosch', 'Faber', 'Siemens', 'Voltas Beko', 'Whirlpool', 'IFB',
      'Samsung', 'LG', 'Miele',
    ],
    fields: [
      SpecField.choice('installation', 'Installation', {
        'freestanding': 'Freestanding',
        'built_in': 'Built-in',
        'countertop': 'Countertop',
      }),
      SpecField.integer('place_settings', 'Place settings', min: 4, max: 16),
    ],
  ),
  ApplianceCategory(
    id: 'refrigerator',
    label: 'Refrigerator',
    glyph: '❄',
    brands: [
      'Bosch', 'Godrej', 'Haier', 'LG', 'Panasonic', 'Samsung', 'Siemens',
      'Voltas Beko', 'Whirlpool',
    ],
    fields: [
      SpecField.choice('door_layout', 'Door layout', {
        'single': 'Single door',
        'double': 'Double door',
        'side_by_side': 'Side by side',
        'french_door': 'French door',
      }),
      SpecField.choice('cooling', 'Cooling', {
        'direct_cool': 'Direct cool',
        'frost_free': 'Frost free',
      }),
      SpecField.integer('capacity_litres', 'Capacity', min: 50, max: 800, unit: 'L'),
    ],
  ),
  ApplianceCategory(
    id: 'ro_purifier',
    label: 'RO Purifier',
    glyph: '◈',
    brands: [
      'Aquaguard', 'AO Smith', 'Blue Star', 'Havells', 'Kent', 'Livpure',
      'Pureit', 'Tata Swach', 'Whirlpool',
    ],
    fields: [
      SpecField.choice('technology', 'Purification', {
        'ro': 'RO',
        'ro_uv': 'RO + UV',
        'ro_uf': 'RO + UF',
        'ro_uv_uf': 'RO + UV + UF',
      }),
      SpecField.choice('mounting', 'Mounting', {
        'wall': 'Wall mounted',
        'counter': 'Countertop',
        'under_sink': 'Under sink',
      }),
      SpecField.integer('tank_litres', 'Storage tank', min: 3, max: 30, unit: 'L'),
    ],
  ),
];

ApplianceCategory? categoryById(String? id) {
  for (final c in kApplianceCategories) {
    if (c.id == id) return c;
  }
  return null;
}

/// A fresh id for one registration form. Sent as `clientRequestId` so a retry
/// of the same submit (lost response, double tap) is recognised by the server
/// instead of creating a second appliance. 32 hex chars, within the backend's
/// 8–64 letters/digits/-/_ rule.
String newClientRequestId([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Body for POST .../kitchen/appliances. [specValues] holds the raw form
/// strings keyed by [SpecField.key]; blanks are omitted, integers are sent as
/// numbers. Throws [ArgumentError] if a value that should be an integer isn't
/// — callers validate first.
Map<String, dynamic> buildRegistrationPayload({
  required ApplianceCategory category,
  required String brand,
  required Map<String, String> specValues,
  String model = '',
  String serialNumber = '',
  String installYear = '',
  String notes = '',
  String? clientRequestId,
}) {
  final specs = <String, dynamic>{};
  for (final f in category.fields) {
    final v = (specValues[f.key] ?? '').trim();
    if (v.isEmpty) continue;
    specs[f.key] = f.kind == SpecKind.integer ? int.parse(v) : v;
  }
  final year = installYear.trim();
  return {
    'category': category.id,
    'brand': normaliseBrand(brand),
    'clientRequestId': ?clientRequestId,
    if (model.trim().isNotEmpty) 'model': model.trim(),
    if (serialNumber.trim().isNotEmpty) 'serialNumber': serialNumber.trim(),
    if (year.isNotEmpty) 'installYear': int.parse(year),
    if (notes.trim().isNotEmpty) 'notes': notes.trim(),
    'specs': specs,
  };
}
