import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/operations/models.dart';
import '../../state/operations_providers.dart';
import '../../state/auth_providers.dart';
import 'assign_technician_sheet.dart';
import 'dashboard_header.dart';
import 'location_picker.dart';

class OverviewScreen extends ConsumerWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(locationFilterProvider);
    final repo = ref.watch(operationsRepositoryProvider);
    final o = repo.overview(district: filter.district);
    final isOwner = ref.watch(currentRoleProvider) == AdminRole.owner;
    // overview() needs all three of these to have loaded; if any one of
    // them failed rather than just still being in flight, show a retry
    // instead of spinning forever.
    final failed = repo.fetchFailed('overview') ||
        repo.fetchFailed('bookings') ||
        repo.fetchFailed('technicians');
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            DashboardHeader(
              eyebrow: 'Rasoi Care operations',
              title: filter.stateName,
              trailing: const LocationPickerChip(),
            ),
            Expanded(
              child: o != null
                  ? _OverviewBody(o: o, isOwner: isOwner)
                  : failed
                      ? EmptyState(
                          glyph: '⚠',
                          title: "Couldn't load the overview",
                          body: 'Check your connection and try again.',
                          action: FilledButton(
                            onPressed: () {
                              repo.retryFetch('overview');
                              repo.retryFetch('bookings');
                              repo.retryFetch('technicians');
                            },
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

class _OverviewBody extends StatelessWidget {
  const _OverviewBody({required this.o, required this.isOwner});
  final AdminOverview o;
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
      children: [
        Stagger(gap: 10, children: [
          if (isOwner) Row(children: [
            Expanded(
              child: _Kpi(
                  label: 'Revenue',
                  value: '₹${(o.revenuePaise / 100 / 100000).toStringAsFixed(2)}L'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Kpi(label: 'Jobs completed', value: '${o.completedJobs}'),
            ),
          ]),
          if (!isOwner) Row(children: [
            Expanded(
              child: _Kpi(label: 'Jobs completed', value: '${o.completedJobs}'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Kpi(
                  label: 'Open complaints',
                  value: '${o.openComplaints}',
                  danger: o.openComplaints > 0),
            ),
          ]),
          Row(children: [
            if (isOwner) ...[
            Expanded(
              child: _Kpi(
                  label: 'Open complaints',
                  value: '${o.openComplaints}',
                  danger: o.openComplaints > 0),
            ),
            const SizedBox(width: 10),
            ],
            Expanded(
              child: _Kpi(
                  label: 'Avg rating',
                  value: o.ratingCount == 0 ? '—' : o.avgRating.toStringAsFixed(2),
                  sub: o.ratingCount == 0 ? 'No ratings yet' : '${o.ratingCount} rated'),
            ),
          ]),
        ]),
        const SizedBox(height: 12),
        if (isOwner) CareCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Revenue by day',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                  Mono('7 days', color: context.care.inkMuted),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 104,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < o.weekBars.length; i++) ...[
                      Expanded(
                        child: _Bar(
                            heightPct: o.weekBars[i] / 100,
                            emphasize: i == o.weekBars.length - 1,
                            delay: Duration(milliseconds: i * 60)),
                      ),
                      if (i != o.weekBars.length - 1) const SizedBox(width: 9),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < o.weekLabels.length; i++) ...[
                    Expanded(
                      child: Text(o.weekLabels[i],
                          textAlign: TextAlign.center,
                          style: CareType.mono(context.care.inkMuted, size: 10.5)),
                    ),
                    if (i != o.weekLabels.length - 1) const SizedBox(width: 9),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _RingStat(pct: o.technicianUtilisationPct, label: 'Technician utilisation (online now)'),
        SectionHeader('Needs attention',
            trailing: o.attention.isEmpty
                ? null
                : StatusChip('${o.attention.length} open', tone: ChipTone.danger, height: 26)),
        if (o.attention.isEmpty)
          const EmptyState(
              glyph: '✓',
              title: 'All clear',
              body: 'No unassigned bookings or open complaints right now.')
        else
          Stagger(children: [
            for (final a in o.attention)
              CareCard(
                onTap: () => _showAttentionDetail(context, a),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(a.title,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                        ),
                        Mono(a.jobId, color: context.care.inkMuted),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(a.detail, style: context.type.bodySmall),
                  ],
                ),
              ),
          ]),
      ],
    );
  }

  void _showAttentionDetail(BuildContext context, AttentionItem a) {
    // An unassigned booking goes straight to the assign picker — no
    // intermediate dialog+button, both for a more direct flow and to
    // avoid ever popping one overlay route and opening another in the
    // same tap (a real bug that crashed this exact flow on the user's
    // device previously). A complaint has nothing to assign, so it still
    // just gets its detail in a plain dialog.
    if (!a.isComplaint) {
      showAssignTechnicianSheet(context, bookingId: a.jobId, jobTitle: a.title);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(a.title),
        content: Text(a.detail),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, this.sub, this.danger = false});
  final String label, value;
  final String? sub;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    return CareCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Eyebrow(label),
          const SizedBox(height: 6),
          Text(value,
              style: CareType.mono(danger ? context.scheme.error : context.scheme.onSurface,
                  size: 21, w: FontWeight.w600)),
          if (sub != null) ...[
            const SizedBox(height: 5),
            Text(sub!, style: TextStyle(fontSize: 11, color: context.care.inkMuted)),
          ],
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.heightPct, required this.emphasize, required this.delay});
  final double heightPct;
  final bool emphasize;
  final Duration delay;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: heightPct),
        duration: const Duration(milliseconds: 600),
        curve: Motion.ease,
        builder: (_, v, __) => FractionallySizedBox(
          alignment: Alignment.bottomCenter,
          heightFactor: v <= 0 ? 0.02 : v,
          child: Container(
            decoration: BoxDecoration(
              color: emphasize ? context.scheme.secondary : context.scheme.primary,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(7), bottom: Radius.circular(3)),
            ),
          ),
        ),
      );
}

class _RingStat extends StatelessWidget {
  const _RingStat({required this.pct, required this.label});
  final int pct;
  final String label;
  @override
  Widget build(BuildContext context) => CareCard(
        child: Row(children: [
          CareDial(
            value: pct / 100,
            size: 66,
            stroke: 7,
            showTicks: false,
            child: Text('$pct%',
                style: CareType.mono(context.scheme.onSurface, size: 15, w: FontWeight.w600)),
          ),
          const SizedBox(width: 14),
          Expanded(child: Text(label, style: context.type.bodySmall)),
        ]),
      );
}
