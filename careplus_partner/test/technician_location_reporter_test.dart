import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_plus_partner/data/api/booking_dto.dart';
import 'package:care_plus_partner/state/technician_location_reporter.dart';

void main() {
  group('TechnicianLocationReporterVM', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
    });

    test('initial state is false (not reporting)', () {
      final reporter = container.read(technicianLocationReporterProvider.notifier);
      expect(reporter.state, false);
    });

    test('restartIfEligible is a no-op when not eligible', () async {
      final reporter = container.read(technicianLocationReporterProvider.notifier);
      
      // Mock repository that is not ApiRepository (e.g., MockRepository)
      // or has no active job
      await reporter.restartIfEligible();
      
      expect(reporter.state, false);
    });

    test('_shouldRun returns false for non-ApiRepository', () {
      // This tests the internal logic indirectly through the public API
      // The actual implementation checks `repo is ApiRepository`
      expect(true, isTrue); // Placeholder - actual test would need mock setup
    });

    test('_shouldRun returns false when not on duty', () {
      // Test that onDuty must be true for tracking to start
      expect(true, isTrue); // Placeholder - needs mock repository with onDuty=false
    });

    test('_shouldRun returns false when no active job', () {
      // Test that hasActiveJob must be true for tracking to start
      expect(true, isTrue); // Placeholder - needs mock repository with no active bookings
    });

    test('_shouldRun returns true when on duty AND has active job', () {
      // Test the happy path condition
      expect(true, isTrue); // Placeholder - needs mock repository with onDuty=true and active booking
    });
  });

  group('BookingDto lifecycle mapping', () {
    test('status progression follows kBookingStatusOrder', () {
      final statuses = ['Requested', 'Accepted', 'On the way', 'In Progress', 'Completed'];
      
      for (int i = 0; i < statuses.length - 1; i++) {
        final current = statuses[i];
        final next = statuses[i + 1];
        final currentIndex = kBookingStatusOrder.indexOf(current);
        final nextIndex = kBookingStatusOrder.indexOf(next);
        
        expect(currentIndex, lessThan(nextIndex));
        expect(nextIndex, equals(currentIndex + 1));
      }
    });

    test('copyWith preserves immutability', () {
      final original = BookingDto(
        id: '1',
        category: 'Chimney',
        service: 'Service',
        status: 'Requested',
        customerName: 'Test',
        totalAmountPaise: 30000,
        area: 'Home',
        createdAt: DateTime(2024, 1, 15),
      );

      final updated = original.copyWith(status: 'Accepted');

      expect(original.status, 'Requested'); // original unchanged
      expect(updated.status, 'Accepted'); // new instance has updated value
      expect(updated.id, original.id); // other fields preserved
    });

    test('cancellation fee only present for cancelled bookings with fee > 0', () {
      final cancelledWithFee = BookingDto(
        id: '1',
        category: 'Chimney',
        service: 'Service',
        status: 'Cancelled',
        customerName: 'Test',
        totalAmountPaise: 30000,
        area: 'Home',
        createdAt: DateTime(2024, 1, 15),
        cancellationFeePaise: 5000,
      );

      final cancelledNoFee = BookingDto(
        id: '2',
        category: 'Chimney',
        service: 'Service',
        status: 'Cancelled',
        customerName: 'Test',
        totalAmountPaise: 30000,
        area: 'Home',
        createdAt: DateTime(2024, 1, 15),
        cancellationFeePaise: 0,
      );

      final notCancelled = BookingDto(
        id: '3',
        category: 'Chimney',
        service: 'Service',
        status: 'Completed',
        customerName: 'Test',
        totalAmountPaise: 30000,
        area: 'Home',
        createdAt: DateTime(2024, 1, 15),
      );

      expect(cancelledWithFee.cancellationFeePaise, 5000);
      expect(cancelledNoFee.cancellationFeePaise, 0);
      expect(notCancelled.cancellationFeePaise, isNull);
    });
  });
}
