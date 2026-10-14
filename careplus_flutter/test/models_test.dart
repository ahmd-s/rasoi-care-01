import 'package:flutter_test/flutter_test.dart';
import 'package:care_plus/data/models.dart';

void main() {
  group('Appliance enum', () {
    test('all appliances have non-empty labels', () {
      for (final appliance in Appliance.values) {
        expect(appliance.label.isNotEmpty, true, 
            reason: '${appliance.name} should have a non-empty label');
      }
    });

    test('comingSoon appliances are correctly marked', () {
      expect(Appliance.refrigerator.comingSoon, true);
      expect(Appliance.purifier.comingSoon, true);
      
      // Other appliances should not be coming soon
      for (final appliance in Appliance.values) {
        if (appliance != Appliance.refrigerator && appliance != Appliance.purifier) {
          expect(appliance.comingSoon, false,
              reason: '${appliance.name} should not be marked as coming soon');
        }
      }
    });

    test('category round-trip through enum', () {
      // Test that category values round-trip correctly
      expect(Appliance.chimney.category, 'Chimney');
      expect(Appliance.hob.category, 'Hob');
      expect(Appliance.cooktop.category, 'Cooktop');
      expect(Appliance.dishwasher.category, 'Dishwasher');
      expect(Appliance.microwave.category, 'Microwave');
      expect(Appliance.otg.category, 'OTG');
      expect(Appliance.refrigerator.category, 'Refrigerator');
      expect(Appliance.purifier.category, 'Water Purifier');
    });
  });

  group('Money formatting', () {
    test('Money.rupees formats paise correctly', () {
      expect(Money.rupees(100), '₹1');
      expect(Money.rupees(500), '₹5');
      expect(Money.rupees(1000), '₹10');
      expect(Money.rupees(1500), '₹15');
      expect(Money.rupees(25000), '₹250');
    });

    test('Money.rupees handles zero', () {
      expect(Money.rupees(0), '₹0');
    });

    test('Money.rupees handles large amounts', () {
      expect(Money.rupees(100000), '₹1,000');
      expect(Money.rupees(1000000), '₹10,000');
    });
  });

  group('ServiceItem', () {
    test('service items have required fields', () {
      final service = ServiceItem(
        id: 's1',
        name: 'Deep clean',
        pricePaise: 50000,
        durationMin: 60,
      );

      expect(service.id, 's1');
      expect(service.name, 'Deep clean');
      expect(service.pricePaise, 50000);
      expect(service.durationMin, 60);
    });

    test('included list can be empty', () {
      final service = ServiceItem(
        id: 's1',
        name: 'Basic service',
        pricePaise: 30000,
        durationMin: 45,
        included: const [],
      );

      expect(service.included, isEmpty);
    });

    test('included list can have multiple items', () {
      final service = ServiceItem(
        id: 's1',
        name: 'Premium service',
        pricePaise: 80000,
        durationMin: 90,
        included: const ['Filter cleaning', 'Motor check', 'Safety inspection'],
      );

      expect(service.included.length, 3);
      expect(service.included, contains('Filter cleaning'));
      expect(service.included, contains('Motor check'));
      expect(service.included, contains('Safety inspection'));
    });
  });

  group('ApplianceDetail', () {
    test('comingSoon flag is preserved', () {
      final detail = ApplianceDetail(
        heading: 'Test',
        blurb: 'Test blurb',
        comingSoon: true,
      );

      expect(detail.comingSoon, true);
    });

    test('default comingSoon is false', () {
      final detail = ApplianceDetail(
        heading: 'Test',
        blurb: 'Test blurb',
      );

      expect(detail.comingSoon, false);
    });
  });
}
