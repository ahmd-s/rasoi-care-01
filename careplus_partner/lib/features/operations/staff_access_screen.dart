import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/operations/models.dart';
import '../../state/operations_providers.dart';

class StaffAccessScreen extends ConsumerWidget {
  const StaffAccessScreen({super.key});

  ChipTone _statusTone(StaffStatus s) =>
      s == StaffStatus.active ? ChipTone.success : ChipTone.danger;

  String _statusLabel(StaffStatus s) => s == StaffStatus.active ? 'Active' : 'Deactivated';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(operationsRepositoryProvider);
    final staff = repo.staffAccounts();
    final failed = repo.fetchFailed('staff');

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: context.pop),
        title: const Text('Staff & access'),
      ),
      body: SafeArea(
        top: false,
        child: staff != null
            ? _StaffBody(staff: staff, statusTone: _statusTone, statusLabel: _statusLabel)
            : failed
                ? EmptyState(
                    glyph: '⚠',
                    title: "Couldn't load staff accounts",
                    body: 'Check your connection and try again.',
                    action: FilledButton(
                      onPressed: () => repo.retryFetch('staff'),
                      child: const Text('Retry'),
                    ),
                  )
                : const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _StaffBody extends ConsumerWidget {
  const _StaffBody({required this.staff, required this.statusTone, required this.statusLabel});
  final List<StaffAccount> staff;
  final ChipTone Function(StaffStatus) statusTone;
  final String Function(StaffStatus) statusLabel;

  Future<void> _toggleSuspend(BuildContext context, WidgetRef ref, StaffAccount s) async {
    final nextActive = s.status == StaffStatus.suspended;
    if (!nextActive) {
      // Suspending (not reinstating) locks someone out immediately — a
      // single accidental tap while scanning this list shouldn't be
      // enough to do that to a colleague's account.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Deactivate ${s.name}?'),
          content: const Text(
              'This revokes their staff access immediately. It does not delete them or change any technician account that uses the same phone number. You can reinstate them later.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Deactivate'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    final ok = await ref.read(operationsRepositoryProvider).setStaffActive(s.id, nextActive);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not update — check connection.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeCount = staff.where((s) => s.status == StaffStatus.active).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
      children: [
        Row(children: [
          Expanded(child: _Kpi(label: 'Active accounts', value: '$activeCount / ${staff.length}')),
          const SizedBox(width: 10),
          Expanded(
              child: _Kpi(
                  label: 'Owners',
                  value: '${staff.where((s) => s.role == AdminRole.owner).length}')),
        ]),
        const SectionHeader('Accounts'),
        if (staff.isEmpty)
          const EmptyState(glyph: '◌', title: 'No staff yet', body: 'Invite your first team member below.')
        else
          Stagger(children: [
            for (final s in staff)
              CareCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Blob(s.initials, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                              child: Text(s.name,
                                  style: const TextStyle(
                                      fontSize: 13.5, fontWeight: FontWeight.w700)),
                            ),
                            StatusChip(s.role.label,
                                tone: s.role == AdminRole.owner
                                    ? ChipTone.selected
                                    : ChipTone.neutral,
                                height: 22),
                          ]),
                          const SizedBox(height: 4),
                          Text('${s.phone} · ${s.lastActive}', style: context.type.bodySmall),
                          const SizedBox(height: 8),
                          Row(children: [
                            StatusChip(statusLabel(s.status),
                                tone: statusTone(s.status), height: 24),
                            const Spacer(),
                            if (s.role != AdminRole.owner)
                              GestureDetector(
                                onTap: () => _toggleSuspend(context, ref, s),
                                child: Text(
                                    s.status == StaffStatus.suspended ? 'Reinstate' : 'Deactivate',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: s.status == StaffStatus.suspended
                                            ? context.care.success
                                            : context.scheme.error)),
                              ),
                          ]),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ]),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => _openInvite(context, ref),
            child: const Text('+ Invite a staff member'),
          ),
        ),
      ],
    );
  }

  void _openInvite(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _InviteStaffSheet(),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => CareCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Eyebrow(label),
            const SizedBox(height: 6),
            Text(value,
                style: CareType.mono(context.scheme.onSurface, size: 21, w: FontWeight.w600)),
          ],
        ),
      );
}

class _InviteStaffSheet extends ConsumerStatefulWidget {
  const _InviteStaffSheet();
  @override
  ConsumerState<_InviteStaffSheet> createState() => _InviteStaffSheetState();
}

class _InviteStaffSheetState extends ConsumerState<_InviteStaffSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  AdminRole _role = AdminRole.staff;
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final ok = await ref.read(operationsRepositoryProvider).inviteStaff(
          name: _nameCtrl.text.trim(),
          phone: _phoneCtrl.text.trim(),
          pin: _pinCtrl.text.trim(),
          role: _role,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not create the account — check the phone number is unique.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Invite a staff member',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            CareField('Full name',
                controller: _nameCtrl,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
            const SizedBox(height: 12),
            CareField('Phone number',
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                validator: (v) => (v == null || v.trim().length < 10) ? 'Enter a valid phone number' : null),
            const SizedBox(height: 12),
            CareField('4+ digit PIN',
                controller: _pinCtrl,
                keyboardType: TextInputType.number,
                obscureText: true,
                validator: (v) => (v == null || v.trim().length < 4) ? 'At least 4 digits' : null),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.scheme.primaryContainer,
                borderRadius: Radii.rSm,
              ),
              child: Text(AdminRole.staff.label,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                      color: context.scheme.primary)),
            ),
            const SizedBox(height: 8),
            Text('Owner access is assigned only through the configured, verified Google account.',
                style: context.type.bodySmall),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Create account'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
