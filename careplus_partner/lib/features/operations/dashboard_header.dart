import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/care_widgets.dart';
import '../../data/operations/models.dart';
import '../../state/auth_providers.dart';

/// Shared top bar for every dashboard tab: eyebrow + title, and a profile
/// icon that pushes the account screen (sign out, owner-only staff access).
class DashboardHeader extends ConsumerWidget {
  const DashboardHeader({super.key, required this.eyebrow, required this.title, this.trailing});
  final String eyebrow;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(currentRoleProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Eyebrow(eyebrow),
                const SizedBox(height: 3),
                Text(title, style: context.type.titleMedium),
              ],
            ),
          ),
          if (trailing != null) ...[trailing!, const SizedBox(width: 9)],
          StatusChip(role.label, tone: ChipTone.selected, height: 30),
          const SizedBox(width: 9),
          _RoundIcon(icon: Icons.person_outline, onTap: () => context.push('/ops/account')),
        ],
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        scale: 0.9,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.scheme.surface,
            shape: BoxShape.circle,
            border: Border.all(color: context.care.hairline),
          ),
          child: Icon(icon, size: 18),
        ),
      );
}
