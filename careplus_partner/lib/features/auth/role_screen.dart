import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/care_plus_theme.dart';
import '../../core/widgets/care_widgets.dart';
import '../../state/auth_providers.dart';

/// First step of sign-in: pick the workspace to open. The choice grants
/// nothing — it only selects which backend check runs next, and the backend
/// still has to authorise the signed-in identity for that role.
class RoleSelectScreen extends ConsumerWidget {
  const RoleSelectScreen({super.key});

  void _pick(BuildContext context, WidgetRef ref, SignInRole role) {
    ref.read(authFlowProvider.notifier).selectRole(role);
    context.push('/login/phone');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CareDial(
                value: 1,
                size: 54,
                stroke: 5,
                showTicks: false,
                child: Icon(Icons.build_outlined, color: context.scheme.primary, size: 22),
              ),
              const SizedBox(height: 26),
              Text('How are you signing in?', style: context.type.headlineLarge),
              const SizedBox(height: 10),
              Text(
                'Choose your role. Access is checked against your account — '
                'picking a role never gives you access by itself.',
                style: context.type.bodyMedium,
              ),
              const SizedBox(height: 26),
              _RoleCard(
                key: const Key('role-technician'),
                icon: Icons.handyman_outlined,
                title: 'Technician',
                body: 'Field jobs, earnings and your application. Phone OTP or Google.',
                onTap: () => _pick(context, ref, SignInRole.technician),
              ),
              const SizedBox(height: 12),
              _RoleCard(
                key: const Key('role-staff'),
                icon: Icons.badge_outlined,
                title: 'Staff',
                body: 'Operations for invited team members. Phone OTP or Google.',
                onTap: () => _pick(context, ref, SignInRole.staff),
              ),
              const SizedBox(height: 12),
              _RoleCard(
                key: const Key('role-owner'),
                icon: Icons.admin_panel_settings_outlined,
                title: 'Owner',
                body: 'Business owner. Google sign-in only.',
                onTap: () => _pick(context, ref, SignInRole.owner),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => CareCard(
        onTap: onTap,
        child: Row(children: [
          Icon(icon, size: 26, color: context.scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(body, style: context.type.bodySmall),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ]),
      );
}
