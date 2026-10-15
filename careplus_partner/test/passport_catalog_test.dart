import 'package:care_plus_partner/features/passport/passport_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('catalog', () {
    test('has the seven V9.7 categories, ids matching the backend', () {
      expect(kApplianceCategories.map((c) => c.id), [
        'chimney', 'hob', 'microwave', 'oven', 'dishwasher', 'refrigerator', 'ro_purifier',
      ]);
      expect(kApplianceCategories.map((c) => c.label), [
        'Chimney', 'Hob / Cooktop', 'Microwave', 'OTG / Oven', 'Dishwasher',
        'Refrigerator', 'RO Purifier',
      ]);
    });

    test('no category has a generic Type field', () {
      for (final c in kApplianceCategories) {
        expect(c.fields.map((f) => f.key), isNot(contains('type')), reason: c.id);
        expect(c.fields.map((f) => f.label.toLowerCase()), isNot(contains('type')));
      }
    });

    test('every category has unique, non-empty brands without Other', () {
      for (final c in kApplianceCategories) {
        expect(c.brands, isNotEmpty, reason: c.id);
        expect(c.brands.toSet().length, c.brands.length, reason: c.id);
        expect(c.brands, isNot(contains(kBrandOther)), reason: c.id);
      }
    });

    test('categoryById', () {
      expect(categoryById('hob')?.label, 'Hob / Cooktop');
      expect(categoryById('toaster'), isNull);
      expect(categoryById(null), isNull);
    });
  });

  group('spec validation', () {
    final hob = categoryById('hob')!;
    final fuel = hob.fields.firstWhere((f) => f.key == 'fuel');
    final burners = hob.fields.firstWhere((f) => f.key == 'burners');
    final suction =
        categoryById('chimney')!.fields.firstWhere((f) => f.key == 'suction_m3h');

    test('required choice', () {
      expect(fuel.validate(null), 'Required');
      expect(fuel.validate(''), 'Required');
      expect(fuel.validate('coal'), 'Choose one');
      expect(fuel.validate('gas'), isNull);
    });

    test('integer range', () {
      expect(burners.validate('0'), 'Between 1 and 6');
      expect(burners.validate('7'), 'Between 1 and 6');
      expect(burners.validate('4'), isNull);
      expect(burners.validate('four'), 'Enter a whole number');
      expect(burners.validate('4.5'), 'Enter a whole number');
      expect(burners.validate(''), 'Required');
    });

    test('optional field may be blank but not invalid', () {
      expect(suction.validate(''), isNull);
      expect(suction.validate('100'), isNotNull);
      expect(suction.validate('1200'), isNull);
    });
  });

  group('brands', () {
    test('normaliseBrand collapses whitespace', () {
      expect(normaliseBrand('  Nova   Air '), 'Nova Air');
    });

    test('validateBrandName', () {
      expect(validateBrandName(''), isNotNull);
      expect(validateBrandName('   '), isNotNull);
      expect(validateBrandName(null), isNotNull);
      expect(validateBrandName('other'), isNotNull);
      expect(validateBrandName('x' * (kMaxBrandLength + 1)), isNotNull);
      expect(validateBrandName('Nova Air'), isNull);
    });

    test('matchBrand ignores case and spacing', () {
      expect(matchBrand(' kent ', ['Kent', 'Pureit']), 'Kent');
      expect(matchBrand('Nova', ['Kent']), isNull);
    });
  });

  test('validateInstallYear', () {
    expect(validateInstallYear('', currentYear: 2026), isNull);
    expect(validateInstallYear('1980', currentYear: 2026), isNotNull);
    expect(validateInstallYear('2027', currentYear: 2026), isNotNull);
    expect(validateInstallYear('abc', currentYear: 2026), isNotNull);
    expect(validateInstallYear('2021', currentYear: 2026), isNull);
  });

  group('buildRegistrationPayload', () {
    test('sends ints as numbers, omits blanks, normalises brand', () {
      final payload = buildRegistrationPayload(
        category: categoryById('hob')!,
        brand: '  Elica ',
        specValues: {'fuel': 'gas', 'burners': '4'},
        installYear: '2021',
      );
      expect(payload, {
        'category': 'hob',
        'brand': 'Elica',
        'installYear': 2021,
        'specs': {'fuel': 'gas', 'burners': 4},
      });
    });

    test('includes optional text when present', () {
      final payload = buildRegistrationPayload(
        category: categoryById('chimney')!,
        brand: 'Faber',
        specValues: {
          'mounting': 'wall_mounted', 'filter': 'baffle', 'width_cm': '90', 'suction_m3h': '',
        },
        model: ' Hood 90 ',
        serialNumber: 'SN1',
        notes: 'Near window',
      );
      expect(payload['model'], 'Hood 90');
      expect(payload['serialNumber'], 'SN1');
      expect(payload['notes'], 'Near window');
      expect(payload['specs'], {'mounting': 'wall_mounted', 'filter': 'baffle', 'width_cm': 90});
    });
  });

  group('clientRequestId', () {
    test('is 32 hex chars and differs between forms', () {
      final a = newClientRequestId();
      expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(newClientRequestId(), isNot(a));
    });

    test('is sent in the payload only when provided', () {
      final hob = categoryById('hob')!;
      final specs = {'fuel': 'gas', 'burners': '2'};
      expect(buildRegistrationPayload(category: hob, brand: 'Elica', specValues: specs)
          .containsKey('clientRequestId'), isFalse);
      expect(
          buildRegistrationPayload(
              category: hob, brand: 'Elica', specValues: specs, clientRequestId: 'abc12345')['clientRequestId'],
          'abc12345');
    });
  });
}
