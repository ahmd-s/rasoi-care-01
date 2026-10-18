// Shared "assign a technician to this unassigned booking" flow — used from
// both the Bookings queue's detail sheet and the Overview tab's "Needs
// attention" list, so there's exactly one place this picker-and-PATCH
// logic lives.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/operations/models.dart';
import '../../state/operations_providers.dart';

Future<void> showAssignTechnicianSheet(
  BuildContext context, {
  required String bookingId,
  required String jobTitle,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AssignTechnicianSheet(bookingId: bookingId, jobTitle: jobTitle),
  );
}

class _AssignTechnicianSheet extends ConsumerStatefulWidget {
  const _AssignTechnicianSheet({required this.bookingId, required this.jobTitle});
  final String bookingId;
  final String jobTitle;

  @override
  ConsumerState<_AssignTechnicianSheet> createState() => _AssignTechnicianSheetState();
}

class _AssignTechnicianSheetState extends ConsumerState<_AssignTechnicianSheet> {
  String? _selectedId;
  bool _submitting = false;

  Future<void> _assign(List<AdminTeamMember> options) async {
    final id = _selectedId;
    if (id == null) return;
    setState(() => _submitting = true);
    final repo = ref.read(operationsRepositoryProvider);
    final ok = await repo.assignTechnician(widget.bookingId, id);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't assign — check your connection and try again.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(operationsRepositoryProvider);
    // Only technicians the platform has actually verified — an unverified
    // applicant isn't real routing-ready yet, same gate as auto-routing.
    final options = repo.team()?.where((t) => t.verified && t.id != null).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: context.care.hairline, borderRadius: Radii.pill),
            ),
          ),
          const Text('Assign a technician',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(widget.jobTitle, style: context.type.bodySmall),
          const SizedBox(height: 18),
          if (options == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (options.isEmpty)
            const EmptyState(
              glyph: '◌',
              title: 'No verified technicians yet',
              body: 'Verify a technician on the Team tab before you can assign a job.',
            )
          else ...[
            // A plain tappable list rather than DropdownButtonFormField —
            // this app has never used a Flutter dropdown menu anywhere
            // else, and it's the one genuinely new, untested widget in the
            // exact tap that was crashing the app to a black screen on the
            // user's device; a form-field dropdown's popup-menu overlay is
            // a known trigger for Android GPU-driver rendering crashes on
            // some devices. This uses only widgets (Container, Pressable)
            // already proven to render fine elsewhere in this app.
            for (final t in options)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Pressable(
                  onTap: () => setState(() => _selectedId = t.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: _selectedId == t.id
                          ? context.scheme.primaryContainer
                          : context.scheme.surface,
                      borderRadius: Radii.rMd,
                      border: Border.all(
                        color: _selectedId == t.id
                            ? context.scheme.primary
                            : context.care.hairline,
                        width: _selectedId == t.id ? 1.5 : 1,
                      ),
                    ),
                    child: Row(children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.name,
                                style: const TextStyle(
                                    fontSize: 13.5, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(t.specialties, style: context.type.bodySmall),
                          ],
                        ),
                      ),
                      if (_selectedId == t.id)
                        Icon(Icons.check_circle, color: context.scheme.primary, size: 20),
                    ]),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _selectedId == null || _submitting ? null : () => _assign(options),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Text('Assign'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
