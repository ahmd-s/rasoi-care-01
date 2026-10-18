import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/operations/locations.dart';
import '../../state/operations_providers.dart';

/// The small "Nashik ▾" chip shown in a dashboard header's trailing slot —
/// tapping it opens the State/District picker sheet. Reused across
/// Overview, Reports, Bookings and Team so the same selection scopes every
/// tab's data at once.
class LocationPickerChip extends ConsumerWidget {
  const LocationPickerChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(locationFilterProvider);
    return Pressable(
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const _LocationPickerSheet(),
      ),
      scale: 0.95,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: context.scheme.surface,
          borderRadius: Radii.pill,
          border: Border.all(color: context.care.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.place_outlined, size: 14, color: context.scheme.primary),
            const SizedBox(width: 5),
            Text(filter.label,
                style: context.type.bodySmall!.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 16, color: context.care.inkMuted),
          ],
        ),
      ),
    );
  }
}

class _LocationPickerSheet extends ConsumerWidget {
  const _LocationPickerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(locationFilterProvider);
    final vm = ref.read(locationFilterProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
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
          Eyebrow('State'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in kStatesAndDistricts.keys)
                ChoiceTag(s, selected: filter.stateName == s, onTap: () => vm.setStateName(s)),
            ],
          ),
          const SizedBox(height: 18),
          Eyebrow('District'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceTag('All districts',
                  selected: filter.district == null, onTap: () => vm.setDistrict(null)),
              for (final d in filter.districtsInState)
                ChoiceTag(d, selected: filter.district == d, onTap: () => vm.setDistrict(d)),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}
