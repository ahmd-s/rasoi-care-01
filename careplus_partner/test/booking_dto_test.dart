import 'package:flutter_test/flutter_test.dart';
import 'package:care_plus_partner/data/api/booking_dto.dart';

void main() {
  group('BookingDto.fromJson', () {
    test('parses minimal booking JSON correctly', () {
      final json = {
        'id': '123',
        'category': 'Chimney',
        'service': 'Deep clean',
        'status': 'Requested',
        'customerName': 'John Doe',
        'total_amount': 500,
        'area': 'Home',
        'createdAt': '2024-01-15T10:30:00Z',
      };

      final dto = BookingDto.fromJson(json);

      expect(dto.id, '123');
      expect(dto.category, 'Chimney');
      expect(dto.service, 'Deep clean');
      expect(dto.status, 'Requested');
      expect(dto.customerName, 'John Doe');
      expect(dto.totalAmountPaise, 50000); // 500 rupees * 100
      expect(dto.area, 'Home');
      expect(dto.createdAt, isNotNull);
    });

    test('converts rupees to paise correctly', () {
      final json = {
        'id': '1',
        'category': 'Hob',
        'service': 'Service',
        'status': 'Accepted',
        'customerName': 'Jane',
        'total_amount': 250.50,
        'area': 'Office',
        'createdAt': '2024-01-15T10:30:00Z',
      };

      final dto = BookingDto.fromJson(json);
      expect(dto.totalAmountPaise, 25050); // 250.50 * 100
    });

    test('handles missing optional fields gracefully', () {
      final json = {
        'id': '1',
        'category': 'Microwave',
        'service': '  ', // empty/whitespace service
        'status': 'Completed',
        'customerName': '  ', // empty/whitespace name
        'total_amount': 0,
        'area': null,
        'createdAt': '2024-01-15T10:30:00Z',
      };

      final dto = BookingDto.fromJson(json);

      expect(dto.service, 'Service visit'); // fallback value
      expect(dto.customerName, 'Customer'); // fallback value
      expect(dto.area, isNull);
      expect(dto.addressLine, isNull);
      expect(dto.lat, isNull);
      expect(dto.lng, isNull);
    });

    test('parses cancellation fee correctly', () {
      final json = {
        'id': '1',
        'category': 'Dishwasher',
        'service': 'Repair',
        'status': 'Cancelled',
        'customerName': 'Test User',
        'total_amount': 1000,
        'cancellationFee': 200, // in rupees
        'area': 'Home',
        'createdAt': '2024-01-15T10:30:00Z',
      };

      final dto = BookingDto.fromJson(json);
      expect(dto.cancellationFeePaise, 20000); // 200 * 100
    });

    test('null cancellation fee when not cancelled', () {
      final json = {
        'id': '1',
        'category': 'OTG',
        'service': 'Service',
        'status': 'Completed',
        'customerName': 'Test',
        'total_amount': 500,
        'area': 'Home',
        'createdAt': '2024-01-15T10:30:00Z',
      };

      final dto = BookingDto.fromJson(json);
      expect(dto.cancellationFeePaise, isNull);
    });

    test('parses nested parts list', () {
      final json = {
        'id': '1',
        'category': 'Chimney',
        'service': 'Service',
        'status': 'In Progress',
        'customerName': 'Test',
        'total_amount': 500,
        'area': 'Home',
        'createdAt': '2024-01-15T10:30:00Z',
        'parts': [
          {
            'id': 'p1',
            'name': 'Filter',
            'qty': 2,
            'pricePaise': 1500,
            'status': 'approved',
          },
        ],
      };

      final dto = BookingDto.fromJson(json);
      expect(dto.parts.length, 1);
      expect(dto.parts[0].name, 'Filter');
      expect(dto.parts[0].qty, 2);
      expect(dto.parts[0].pricePaise, 1500);
      expect(dto.parts[0].status, 'approved');
    });

    test('parses service changes list', () {
      final json = {
        'id': '1',
        'category': 'Chimney',
        'service': 'Service',
        'status': 'In Progress',
        'customerName': 'Test',
        'total_amount': 500,
        'area': 'Home',
        'createdAt': '2024-01-15T10:30:00Z',
        'serviceChanges': [
          {
            'id': 'sc1',
            'oldService': 'Basic clean',
            'newService': 'Deep clean',
            'oldPricePaise': 30000,
            'newPricePaise': 50000,
          },
        ],
      };

      final dto = BookingDto.fromJson(json);
      expect(dto.serviceChanges.length, 1);
      expect(dto.serviceChanges[0].oldService, 'Basic clean');
      expect(dto.serviceChanges[0].newService, 'Deep clean');
      expect(dto.serviceChanges[0].oldPricePaise, 30000);
      expect(dto.serviceChanges[0].newPricePaise, 50000);
    });

    test('copyWith updates specified fields', () {
      final dto = BookingDto(
        id: '1',
        category: 'Chimney',
        service: 'Basic',
        status: 'Requested',
        customerName: 'Test',
        totalAmountPaise: 30000,
        area: 'Home',
        createdAt: DateTime(2024, 1, 15),
      );

      final updated = dto.copyWith(
        service: 'Deep clean',
        totalAmountPaise: 50000,
        status: 'Accepted',
      );

      expect(updated.id, '1'); // unchanged
      expect(updated.service, 'Deep clean');
      expect(updated.totalAmountPaise, 50000);
      expect(updated.status, 'Accepted');
      expect(updated.category, 'Chimney'); // unchanged
    });
  });

  group('PartQuoteDto.fromJson', () {
    test('parses part quote correctly', () {
      final json = {
        'id': 'p1',
        'name': 'Motor',
        'sku': 'MOT-123',
        'qty': 1,
        'pricePaise': 5000,
        'status': 'pending',
      };

      final dto = PartQuoteDto.fromJson(json);
      expect(dto.id, 'p1');
      expect(dto.name, 'Motor');
      expect(dto.sku, 'MOT-123');
      expect(dto.qty, 1);
      expect(dto.pricePaise, 5000);
      expect(dto.status, 'pending');
    });

    test('handles missing optional fields', () {
      final json = {
        'id': 'p1',
        'name': 'Filter',
        'qty': 2,
        'pricePaise': 1000,
        'status': 'approved',
      };

      final dto = PartQuoteDto.fromJson(json);
      expect(dto.sku, isNull);
      expect(dto.decidedAt, isNull);
    });
  });

  group('ServiceOptionDto.fromJson', () {
    test('parses service option correctly', () {
      final json = {
        'id': 's1',
        'category': 'Chimney',
        'appliance_name': 'Elica',
        'name': 'Deep clean',
        'price': 500,
      };

      final dto = ServiceOptionDto.fromJson(json);
      expect(dto.id, 's1');
      expect(dto.category, 'Chimney');
      expect(dto.applianceName, 'Elica');
      expect(dto.name, 'Deep clean');
      expect(dto.pricePaise, 50000); // 500 * 100
    });

    test('displayName combines appliance and service name', () {
      final dto = ServiceOptionDto(
        id: 's1',
        category: 'Chimney',
        applianceName: 'Faber',
        name: 'Basic service',
        pricePaise: 30000,
      );

      expect(dto.displayName, 'Faber · Basic service');
    });
  });

  group('kBookingStatusOrder', () {
    test('contains all expected statuses in correct order', () {
      expect(kBookingStatusOrder, [
        'Requested',
        'Accepted',
        'On the way',
        'In Progress',
        'Completed',
      ]);
    });
  });
}
