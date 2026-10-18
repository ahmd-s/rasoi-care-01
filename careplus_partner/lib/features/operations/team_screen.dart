import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/operations/models.dart';
import '../../state/operations_providers.dart';
import '../../state/auth_providers.dart';
import 'dashboard_header.dart';
import 'location_picker.dart';

class TeamScreen extends ConsumerWidget {
  const TeamScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(operationsRepositoryProvider);
    final allTeam = repo.team();
    final filter = ref.watch(locationFilterProvider);
    final team = allTeam?.where((t) => filter.matches(t.area)).toList();
    final failed = repo.fetchFailed('technicians');

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const DashboardHeader(
              eyebrow: 'Rasoi Care operations',
              title: 'Technician team',
              trailing: LocationPickerChip(),
            ),
            Expanded(
              child: team != null
                  ? _TeamBody(team: team)
                  : failed
                      ? EmptyState(
                          glyph: '⚠',
                          title: "Couldn't load the team",
                          body: 'Check your connection and try again.',
                          action: FilledButton(
                            onPressed: () => repo.retryFetch('technicians'),
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

class _TeamBody extends ConsumerWidget {
  const _TeamBody({required this.team});
  final List<AdminTeamMember> team;

  String _dutyLabel(DutyStatus d) => switch (d) {
        DutyStatus.onJob => 'On job',
        DutyStatus.idle => 'Idle',
        DutyStatus.offDuty => 'Off duty',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onDuty = team.where((t) => t.duty != DutyStatus.offDuty).length;
    final pendingReview = team.where((t) => t.applicationSubmitted && !t.verified).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
      children: [
        Row(children: [
          Expanded(child: _Kpi(label: 'On duty', value: '$onDuty / ${team.length}')),
          const SizedBox(width: 10),
          Expanded(
              child: _Kpi(
                  label: 'Awaiting review',
                  value: '$pendingReview',
                  warn: pendingReview > 0)),
        ]),
        const SizedBox(height: 12),
        if (team.isEmpty)
          const EmptyState(
              glyph: '◌',
              title: 'No technicians yet',
              body: 'Technicians who sign up in the Partner app will appear here.')
        else
          Stagger(children: [
            for (final t in team)
              CareCard(
                onTap: () => _openDetail(context, ref, t),
                child: Row(children: [
                  Blob(t.initials, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.name,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 3),
                        Text(
                          t.partnerCode != null
                              ? '${t.specialties} · ${t.statsLabel} · ${t.partnerCode}'
                              : '${t.specialties} · ${t.statsLabel}',
                          style: context.type.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _StatusBadge(t),
                      const SizedBox(height: 4),
                      Text(_dutyLabel(t.duty),
                          style: TextStyle(fontSize: 11, color: context.care.inkMuted)),
                    ],
                  ),
                ]),
              ),
          ]),
      ],
    );
  }

  void _openDetail(BuildContext context, WidgetRef ref, AdminTeamMember t) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TechnicianDetailSheet(member: t),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.member);
  final AdminTeamMember member;
  @override
  Widget build(BuildContext context) {
    if (member.verified) {
      return Text('★ ${member.rating}',
          style: CareType.mono(context.scheme.secondary, size: 12.5, w: FontWeight.w600));
    }
    return StatusChip(
      member.applicationSubmitted ? 'Awaiting review' : 'Applying',
      tone: ChipTone.warning,
      height: 22,
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, this.warn = false});
  final String label, value;
  final bool warn;
  @override
  Widget build(BuildContext context) => CareCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Eyebrow(label),
            const SizedBox(height: 6),
            Text(value,
                style: CareType.mono(
                    warn ? context.scheme.secondary : context.scheme.onSurface,
                    size: 21,
                    w: FontWeight.w600)),
          ],
        ),
      );
}

/// Full KYC application review — everything TechApplyScreen (careplus_partner)
/// collected: profile photo, category/area, experience, ID document, bank
/// payout details — plus the Verify action once an admin's checked it all,
/// mirroring Urban Company's partner-approval flow.
class _TechnicianDetailSheet extends ConsumerStatefulWidget {
  const _TechnicianDetailSheet({required this.member});
  final AdminTeamMember member;
  @override
  ConsumerState<_TechnicianDetailSheet> createState() => _TechnicianDetailSheetState();
}

class _TechnicianDetailSheetState extends ConsumerState<_TechnicianDetailSheet> {
  bool _verifying = false;
  TechnicianEarnings? _earnings;
  bool _loadingEarnings = true;

  @override
  void initState() {
    super.initState();
    if (ref.read(currentRoleProvider) == AdminRole.owner) _loadEarnings();
  }

  Future<void> _loadEarnings() async {
    final id = widget.member.id;
    if (id == null) {
      setState(() => _loadingEarnings = false);
      return;
    }
    final earnings = await ref.read(operationsRepositoryProvider).fetchTechnicianEarnings(id);
    if (!mounted) return;
    setState(() {
      _earnings = earnings;
      _loadingEarnings = false;
    });
  }

  Future<void> _verify() async {
    final id = widget.member.id;
    if (id == null) return;
    // Irreversible in practice — see verify_technician's own comment
    // ("there's no unverify") — and it puts someone straight into real
    // customer routing, so a single accidental tap while scrolling a
    // review queue shouldn't be enough to do it.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Verify this technician?'),
        content: Text(
          'They will immediately start receiving real bookings and appear '
          'as verified in the Partner app. This cannot be undone from here.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _verifying = true);
    final ok = await ref.read(operationsRepositoryProvider).verifyTechnician(id);
    if (!mounted) return;
    setState(() => _verifying = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not verify — check connection.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.member;
    final isOwner = ref.watch(currentRoleProvider) == AdminRole.owner;
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
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
                decoration: BoxDecoration(
                    color: context.care.hairline, borderRadius: Radii.pill),
              ),
            ),
            Row(children: [
              t.photoUrl != null
                  ? CircleAvatar(radius: 28, backgroundImage: NetworkImage(t.photoUrl!))
                  : Blob(t.initials, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(t.specialties, style: context.type.bodySmall),
                  ],
                ),
              ),
              _StatusBadge(t),
            ]),
            const Divider(height: 30),
            _row(context, 'Service area', t.area?.isNotEmpty == true ? t.area! : '—'),
            _row(context, 'Experience',
                t.experienceYears != null ? '${t.experienceYears} years' : '—'),
            _row(context, 'Rating', '★ ${t.rating}'),
            _row(context, 'Jobs completed', t.statsLabel),
            _row(
              context,
              'Employment type',
              switch (t.employmentType) {
                'payroll' => 'Payroll',
                'outsourced' => 'Outsourced / independent',
                _ => '—',
              },
            ),
            if (isOwner) ...[
              const SizedBox(height: 10),
              const Eyebrow('Earnings'),
              const SizedBox(height: 8),
              if (_loadingEarnings)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                )
              else if (_earnings == null)
                Text('Could not load earnings — check connection.', style: context.type.bodySmall)
              else ...[
                _row(context, 'Commission rate', '${(_earnings!.commissionRate * 100).round()}%'),
                _row(context, 'Total commission', Money.rupees(_earnings!.commissionTotalPaise)),
                _row(context, 'Net payout', Money.rupees(_earnings!.netTotalPaise)),
                if (_earnings!.incentives.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  const Text('Bonus & incentives',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  for (final e in _earnings!.incentives)
                    _ledgerRow(context, e, color: context.care.success),
                ],
                if (_earnings!.fines.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Fines', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  for (final e in _earnings!.fines)
                    _ledgerRow(context, e, color: context.scheme.error),
                ],
              ],
            ],
            const SizedBox(height: 10),
            Eyebrow('Aadhaar card'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                    child: _kycDocThumb(context, t.id, 'aadhar-front', t.aadharDocumentReady, 'Front')),
                const SizedBox(width: 10),
                Expanded(
                    child: _kycDocThumb(context, t.id, 'aadhar-back', t.aadharDocumentBackReady, 'Back')),
              ],
            ),
            const SizedBox(height: 18),
            Eyebrow('PAN card'),
            const SizedBox(height: 8),
            _kycDocThumb(context, t.id, 'pan', t.panDocumentReady, 'PAN'),
            // Older technician rows created before Aadhaar/PAN got their own
            // upload fields only ever had this generic one — still shown so
            // nothing on file silently disappears from review.
            if (t.idDocumentUrl != null) ...[
              const SizedBox(height: 18),
              Eyebrow('Other ID document'),
              const SizedBox(height: 8),
              _docThumb(context, t.idDocumentUrl, 'ID'),
            ],
            if (isOwner) ...[
              const SizedBox(height: 18),
              Eyebrow('Payout bank details'),
              const SizedBox(height: 8),
              _row(context, 'Account holder',
                  t.bankAccountName?.isNotEmpty == true ? t.bankAccountName! : '—'),
              _row(context, 'Account number',
                  t.bankAccountNumber?.isNotEmpty == true ? t.bankAccountNumber! : '—'),
              _row(context, 'IFSC', t.bankIfsc?.isNotEmpty == true ? t.bankIfsc! : '—'),
              const SizedBox(height: 8),
              _kycDocThumb(context, t.id, 'bank-passbook', t.bankPassbookReady, 'Passbook / cheque'),
            ],
            const SizedBox(height: 20),
            if (t.id != null && !t.verified)
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _verifying ? null : _verify,
                  child: _verifying
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Verify technician'),
                ),
              )
            else if (t.verified)
              Center(
                child: Text(
                  t.partnerCode != null
                      ? 'Verified · Partner ID ${t.partnerCode}'
                      : 'Already verified',
                  style: context.type.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _docThumb(BuildContext context, String? url, String label) {
    if (url == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: Radii.rMd,
          border: Border.all(color: context.care.warning.withValues(alpha: 0.4)),
          color: context.care.warning.withValues(alpha: 0.08),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 16, color: context.care.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text('$label — missing',
                  style: context.type.bodySmall!.copyWith(color: context.care.warning)),
            ),
          ],
        ),
      );
    }
    return ClipRRect(
      borderRadius: Radii.rMd,
      child: Image.network(url, height: 140, width: double.infinity, fit: BoxFit.cover),
    );
  }

  /// Same "missing" warning as [_docThumb], but for a KYC document that's
  /// now fetched through GET /api/technicians/<id>/document/<kind> instead
  /// of a raw Image.network(url) — the staff-scoped technician listing no
  /// longer hands out the underlying Firebase Storage URL at all (see
  /// technician_row_to_dict's redact_documents), so this needs a fresh
  /// staff bearer token attached to the request instead.
  Widget _kycDocThumb(BuildContext context, String? technicianId, String kind, bool ready, String label) {
    if (technicianId == null || !ready) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: Radii.rMd,
          border: Border.all(color: context.care.warning.withValues(alpha: 0.4)),
          color: context.care.warning.withValues(alpha: 0.08),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 16, color: context.care.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text('$label — missing',
                  style: context.type.bodySmall!.copyWith(color: context.care.warning)),
            ),
          ],
        ),
      );
    }
    final repo = ref.read(operationsRepositoryProvider);
    return FutureBuilder<Map<String, String>>(
      future: repo.documentHeaders(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 140,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        return ClipRRect(
          borderRadius: Radii.rMd,
          child: Image.network(
            repo.documentUrl(technicianId, kind),
            headers: snapshot.data,
            height: 140,
            width: double.infinity,
            fit: BoxFit.cover,
          ),
        );
      },
    );
  }

  Widget _ledgerRow(BuildContext context, TechnicianLedgerEntry entry, {required Color color}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(entry.reason, style: context.type.bodySmall),
            ),
            Text(
              '${entry.amountPaise >= 0 ? '+' : ''}${Money.rupees(entry.amountPaise)}',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color),
            ),
          ],
        ),
      );

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
