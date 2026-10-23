import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import 'assign_technician_sheet.dart';
import 'dashboard_header.dart';
import 'location_picker.dart';

class BookingsScreen extends ConsumerStatefulWidget {
  const BookingsScreen({super.key});
  @override
  ConsumerState<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends ConsumerState<BookingsScreen> {
  int _filter = 0; // All · Unassigned · In progress · Closed

  BookingCategory? _categoryFor(int i) => switch (i) {
        1 => BookingCategory.unassigned,
        2 => BookingCategory.inProgress,
        3 => BookingCategory.closed,
        _ => null,
      };

  ChipTone _tone(BookingCategory c) => switch (c) {
        BookingCategory.unassigned => ChipTone.danger,
        BookingCategory.inProgress => ChipTone.warning,
        BookingCategory.closed => ChipTone.success,
      };

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final allBookings = repo.bookings();
    final filter = ref.watch(locationFilterProvider);
    final bookings = allBookings?.where((b) => filter.matches(b.city)).toList();
    final failed = repo.fetchFailed('bookings');

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const DashboardHeader(
              eyebrow: 'Rasoi Care operations',
              title: 'Bookings queue',
              trailing: LocationPickerChip(),
            ),
            Expanded(
              child: bookings != null
                  ? _BookingsBody(
                      bookings: bookings,
                      filter: _filter,
                      onFilterChanged: (i) => setState(() => _filter = i),
                      categoryFor: _categoryFor,
                      toneFor: _tone,
                    )
                  : failed
                      ? EmptyState(
                          glyph: '⚠',
                          title: "Couldn't load bookings",
                          body: 'Check your connection and try again.',
                          action: FilledButton(
                            onPressed: () => repo.retryFetch('bookings'),
                            child: const Text('Retry'),
                          ),
                        )
                      : const Center(child: CircularProgressIndicator()),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookingsBody extends StatelessWidget {
  const _BookingsBody({
    required this.bookings,
    required this.filter,
    required this.onFilterChanged,
    required this.categoryFor,
    required this.toneFor,
  });
  final List<AdminBooking> bookings;
  final int filter;
  final ValueChanged<int> onFilterChanged;
  final BookingCategory? Function(int) categoryFor;
  final ChipTone Function(BookingCategory) toneFor;

  @override
  Widget build(BuildContext context) {
    final want = categoryFor(filter);
    final shown = want == null ? bookings : bookings.where((b) => b.category == want).toList();
    final counts = {
      for (final c in BookingCategory.values) c: bookings.where((b) => b.category == c).length,
    };
    final chips = [
      'All ${bookings.length}',
      'Unassigned ${counts[BookingCategory.unassigned] ?? 0}',
      'In progress ${counts[BookingCategory.inProgress] ?? 0}',
      'Closed ${counts[BookingCategory.closed] ?? 0}',
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
      children: [
        SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: chips.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) => ChoiceTag(chips[i],
                selected: filter == i, onTap: () => onFilterChanged(i)),
          ),
        ),
        const SizedBox(height: 14),
        if (bookings.isEmpty)
          const EmptyState(
              glyph: '◌', title: 'No bookings yet', body: 'Real bookings will appear here.')
        else if (shown.isEmpty)
          const EmptyState(
              glyph: '◌', title: 'Nothing here', body: 'No bookings match this filter right now.')
        else
          Stagger(children: [
            for (final b in shown)
              CareCard(
                onTap: () => _openDetail(context, b),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        StatusChip(b.statusLabel, tone: toneFor(b.category), height: 24),
                        Mono(b.jobId, color: context.care.inkMuted),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(b.title,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(b.meta, style: context.type.bodySmall),
                  ],
                ),
              ),
          ]),
      ],
    );
  }

  void _openDetail(BuildContext context, AdminBooking b) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BookingDetailSheet(booking: b, tone: toneFor(b.category)),
    );
  }
}

class _BookingDetailSheet extends StatelessWidget {
  const _BookingDetailSheet({required this.booking, required this.tone});
  final AdminBooking booking;
  final ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, scrollController) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: ListView(
          controller: scrollController,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration:
                    BoxDecoration(color: context.care.hairline, borderRadius: Radii.pill),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(b.title,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                StatusChip(b.statusLabel, tone: tone, height: 24),
              ],
            ),
            const SizedBox(height: 4),
            Mono(b.jobId, color: context.care.inkMuted),
            const Divider(height: 26),
            _row(context, 'Total', Money.rupees(b.totalPaise)),
            _row(context, 'Area', b.area ?? '—'),
            _row(context, 'Customer', b.customerName ?? '—'),
            if (b.technicianName != null)
              _row(context, 'Technician', b.technicianName!)
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Technician', style: context.type.bodySmall),
                    TextButton(
                      onPressed: () => showAssignTechnicianSheet(context,
                          bookingId: b.jobId, jobTitle: b.title),
                      child: const Text('Assign a technician'),
                    ),
                  ],
                ),
              ),
            _row(
                context,
                'Booked',
                b.createdAt == null
                    ? '—'
                    : DateFormat('d MMM yyyy · h:mm a').format(b.createdAt!.toLocal())),
            const SizedBox(height: 10),
            Eyebrow('Directions for technician'),
            const SizedBox(height: 8),
            Text(b.directions?.isNotEmpty == true ? b.directions! : 'None given',
                style: context.type.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: context.type.bodySmall),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
}
