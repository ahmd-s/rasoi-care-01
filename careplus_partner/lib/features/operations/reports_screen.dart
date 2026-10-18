import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/operations_widgets/charts.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/operations/models.dart';
import '../../state/operations_providers.dart';
import '../../state/auth_providers.dart';
import 'dashboard_header.dart';
import 'location_picker.dart';

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(reportRangeProvider);
    final filter = ref.watch(locationFilterProvider);
    final report = ref.watch(operationsRepositoryProvider).report(range, district: filter.district);
    final role = ref.watch(currentRoleProvider);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            DashboardHeader(
              eyebrow: 'Analysis & reports',
              title: filter.stateName,
              trailing: const LocationPickerChip(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _RangeSeg(
                range: range,
                onChanged: (r) => ref.read(reportRangeProvider.notifier).set(r),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: report == null
                  ? const Center(child: CircularProgressIndicator())
                  : _ReportsBody(report: report, range: range, role: role),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportsBody extends StatelessWidget {
  const _ReportsBody({required this.report, required this.range, required this.role});
  final ReportBundle report;
  final ReportRange range;
  final AdminRole role;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
      children: [
        if (role == AdminRole.owner) ...[
          _RevenueTrendCard(report: report),
          const SizedBox(height: 12),
        ],
        _RatingTrendCard(report: report),
        if (role == AdminRole.owner) ...[
          SectionHeader('Revenue by category',
              trailing: Mono(range.label, color: context.care.inkMuted)),
          if (report.categoryRevenue.isEmpty)
            const EmptyState(glyph: '◌', title: 'No revenue yet', body: 'Nothing completed this period.')
          else
            _CategoryRevenueCard(report: report),
        ],
        SectionHeader('Technician leaderboard'),
        if (report.technicianLeaderboard.isEmpty)
          const EmptyState(
              glyph: '◌', title: 'No technicians yet', body: 'Add technicians from the Team tab.')
        else if (role == AdminRole.owner)
          _LeaderboardCard(report: report)
        else
          _StaffLeaderboardCard(report: report),
        SectionHeader('Complaints by status',
            trailing: StatusChip(
                '${report.complaintsByStatus.fold<int>(0, (s, c) => s + c.count)} total',
                tone: ChipTone.neutral,
                height: 26)),
        if (report.complaintsByStatus.isEmpty)
          const EmptyState(glyph: '✓', title: 'No complaints', body: 'None filed this period.')
        else
          _ComplaintsCard(report: report),
        SectionHeader('Financial P&L',
            trailing: role == AdminRole.owner
                ? null
                : const StatusChip('Owner only', tone: ChipTone.neutral, height: 24)),
        if (role != AdminRole.owner)
          const _OwnerOnlyLock()
        else if (report.financials == null)
          const EmptyState(
              glyph: '◌', title: 'Loading…', body: 'Fetching the owner P&L summary.')
        else
          _FinancialsCard(financials: report.financials!),
      ],
    );
  }
}

class _RangeSeg extends StatelessWidget {
  const _RangeSeg({required this.range, required this.onChanged});
  final ReportRange range;
  final ValueChanged<ReportRange> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration:
            BoxDecoration(color: context.scheme.surfaceContainerHigh, borderRadius: Radii.rSm),
        child: Row(
          children: [
            for (final r in ReportRange.values)
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(r),
                  child: AnimatedContainer(
                    duration: Motion.press,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: r == range ? context.scheme.surface : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: r == range
                          ? Shadows.card(Theme.of(context).brightness == Brightness.dark)
                          : null,
                    ),
                    child: Text(r.label,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color:
                                r == range ? context.scheme.onSurface : context.care.inkMuted)),
                  ),
                ),
              ),
          ],
        ),
      );
}

class _RevenueTrendCard extends StatelessWidget {
  const _RevenueTrendCard({required this.report});
  final ReportBundle report;
  @override
  Widget build(BuildContext context) {
    final total = report.categoryRevenue.fold<int>(0, (s, c) => s + c.revenuePaise);
    return CareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Revenue trend',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              Text(Money.rupees(total),
                  style: CareType.mono(context.scheme.primary, size: 15, w: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
          if (report.revenueTrend.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text('No completed bookings this period.',
                  style: context.type.bodySmall, textAlign: TextAlign.center),
            )
          else ...[
            SparkLineChart(values: [for (final p in report.revenueTrend) p.value]),
            const SizedBox(height: 6),
            Row(
              children: [
                for (final p in report.revenueTrend)
                  Expanded(
                    child: Text(p.label,
                        textAlign: TextAlign.center,
                        style: CareType.mono(context.care.inkMuted, size: 10)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RatingTrendCard extends StatelessWidget {
  const _RatingTrendCard({required this.report});
  final ReportBundle report;
  @override
  Widget build(BuildContext context) {
    return CareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Average rating trend',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              if (report.ratingTrend.isNotEmpty)
                Text('★ ${(report.ratingTrend.last.value * 5).toStringAsFixed(2)}',
                    style: CareType.mono(context.scheme.secondary, size: 15, w: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
          if (report.ratingTrend.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text('No ratings submitted this period.',
                  style: context.type.bodySmall, textAlign: TextAlign.center),
            )
          else ...[
            SparkLineChart(
                values: [for (final p in report.ratingTrend) p.value],
                color: context.scheme.secondary,
                height: 90),
            const SizedBox(height: 6),
            Row(
              children: [
                for (final p in report.ratingTrend)
                  Expanded(
                    child: Text(p.label,
                        textAlign: TextAlign.center,
                        style: CareType.mono(context.care.inkMuted, size: 10)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CategoryRevenueCard extends StatelessWidget {
  const _CategoryRevenueCard({required this.report});
  final ReportBundle report;
  @override
  Widget build(BuildContext context) {
    final list = [...report.categoryRevenue]..sort((a, b) => b.revenuePaise.compareTo(a.revenuePaise));
    final max = list.first.revenuePaise;
    return CareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final c in list)
            HBarRow(
              label: c.label,
              value: Money.rupees(c.revenuePaise),
              fraction: max <= 0 ? 0 : c.revenuePaise / max,
            ),
        ],
      ),
    );
  }
}

class _LeaderboardCard extends StatelessWidget {
  const _LeaderboardCard({required this.report});
  final ReportBundle report;
  @override
  Widget build(BuildContext context) {
    final list = [...report.technicianLeaderboard]
      ..sort((a, b) => b.revenuePaise.compareTo(a.revenuePaise));
    final max = list.first.revenuePaise;
    return CareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < list.length; i++)
            HBarRow(
              rank: i + 1,
              label: list[i].name,
              value: '${Money.rupees(list[i].revenuePaise)} · ★${list[i].rating}',
              fraction: max <= 0 ? 0 : list[i].revenuePaise / max,
              color: i == 0 ? context.scheme.secondary : null,
            ),
        ],
      ),
    );
  }
}

class _StaffLeaderboardCard extends StatelessWidget {
  const _StaffLeaderboardCard({required this.report});
  final ReportBundle report;
  @override
  Widget build(BuildContext context) {
    final list = [...report.technicianLeaderboard]..sort((a, b) => b.jobs.compareTo(a.jobs));
    final maxJobs = list.first.jobs;
    return CareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < list.length; i++)
            HBarRow(
              rank: i + 1,
              label: list[i].name,
              value: '${list[i].jobs} jobs · ★${list[i].rating}',
              fraction: maxJobs <= 0 ? 0 : list[i].jobs / maxJobs,
              color: i == 0 ? context.scheme.secondary : null,
            ),
        ],
      ),
    );
  }
}

class _ComplaintsCard extends StatelessWidget {
  const _ComplaintsCard({required this.report});
  final ReportBundle report;
  @override
  Widget build(BuildContext context) {
    final list = [...report.complaintsByStatus]..sort((a, b) => b.count.compareTo(a.count));
    final max = list.first.count;
    ChipTone toneFor(String status) => switch (status) {
          'Resolved' => ChipTone.success,
          'Open' => ChipTone.danger,
          _ => ChipTone.warning,
        };
    return CareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final c in list)
            HBarRow(
              label: c.status,
              value: '${c.count}',
              fraction: max <= 0 ? 0 : c.count / max,
              color: toneFor(c.status) == ChipTone.success
                  ? context.care.success
                  : toneFor(c.status) == ChipTone.danger
                      ? context.scheme.error
                      : context.scheme.secondary,
            ),
        ],
      ),
    );
  }
}

class _FinancialsCard extends StatelessWidget {
  const _FinancialsCard({required this.financials});
  final FinancialSummary financials;
  @override
  Widget build(BuildContext context) {
    final f = financials;
    return CareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _line(context, 'Gross revenue', f.grossRevenuePaise, positive: true),
          _line(context, 'Technician payouts (estimated)', -f.technicianPayoutEstimatePaise),
          const Divider(height: 24),
          _line(context, 'Net margin (estimated)', f.netMarginEstimatePaise,
              positive: true, bold: true),
          const SizedBox(height: 4),
          Text('${f.netMarginPct.toStringAsFixed(1)}% of gross revenue',
              style: context.type.bodySmall),
          const SizedBox(height: 10),
          Text(
              'Technician payout is estimated at ${(f.payoutRateAssumed * 100).toStringAsFixed(0)}% '
              'of gross revenue — there is no real per-job payout ledger yet, so this is an '
              'assumed rate, not an actual figure.',
              style: context.type.bodySmall),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, String label, int amountPaise,
      {bool positive = false, bool bold = false}) {
    final color = amountPaise < 0
        ? context.scheme.error
        : positive
            ? context.care.success
            : context.scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: bold ? 14 : 12.5, fontWeight: bold ? FontWeight.w700 : FontWeight.w600)),
          Text(
              amountPaise < 0
                  ? '-${Money.rupees(amountPaise.abs())}'
                  : Money.rupees(amountPaise),
              style: CareType.mono(color, size: bold ? 15 : 12.5, w: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _OwnerOnlyLock extends StatelessWidget {
  const _OwnerOnlyLock();
  @override
  Widget build(BuildContext context) => CareCard(
        color: context.scheme.surfaceContainerHigh,
        borderColor: Colors.transparent,
        child: Row(children: [
          Icon(Icons.lock_outline, size: 20, color: context.care.inkFaint),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
                'Payouts and margin are visible to the Owner account only.',
                style: context.type.bodySmall),
          ),
        ]),
      );
}
