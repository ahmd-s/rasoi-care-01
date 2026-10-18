import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/operations/models.dart';
import '../../state/providers.dart';
import '../../state/auth_providers.dart';

Future<void> _toggleBiometric(BuildContext context, WidgetRef ref, bool value) async {
  if (!value) {
    await ref.read(biometricEnabledProvider.notifier).set(false);
    return;
  }
  final ok = await ref
      .read(biometricServiceProvider)
      .authenticate('Confirm your fingerprint or face to turn on biometric login');
  if (ok) {
    await ref.read(biometricEnabledProvider.notifier).set(true);
  } else if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text("Couldn't verify — biometric login stays off.")));
  }
}

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = FirebaseAuth.instance.currentUser;
    final role = ref.watch(currentRoleProvider);
    final mode = ref.watch(themeModeProvider);
    final biometricSupported = ref.watch(biometricSupportedProvider).valueOrNull ?? false;
    final biometricOn = ref.watch(biometricEnabledProvider);

    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: context.pop), title: const Text('Account')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
          children: [
            CareCard(
              child: Row(children: [
                Blob('+91', size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user?.email ?? user?.phoneNumber ?? 'Partner account',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text('Signed in as ${role.label}', style: context.type.bodySmall),
                    ],
                  ),
                ),
                StatusChip(role.label, tone: ChipTone.selected, height: 28),
              ]),
            ),
            const SectionHeader('Preferences'),
            CareCard(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                const Icon(Icons.dark_mode_outlined, size: 20),
                const SizedBox(width: 13),
                const Expanded(
                    child: Text('Dark mode',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700))),
                Switch(
                  value: mode == ThemeMode.dark,
                  onChanged: (_) => ref.read(themeModeProvider.notifier).toggle(),
                ),
              ]),
            ),
            if (biometricSupported)
              CareCard(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  const Icon(Icons.fingerprint, size: 20),
                  const SizedBox(width: 13),
                  const Expanded(
                      child: Text('Biometric login',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700))),
                  Switch(
                    value: biometricOn,
                    onChanged: (v) => _toggleBiometric(context, ref, v),
                  ),
                ]),
              ),
            if (role == AdminRole.owner) ...[
              const SectionHeader('Owner tools'),
              CareCard(
                onTap: () => context.push('/ops/staff'),
                child: Row(children: [
                  Blob('◈', glyph: true, bg: context.scheme.primaryContainer, fg: context.scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Staff & access',
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 3),
                        Text('Invite staff, set roles, suspend access',
                            style: context.type.bodySmall),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: context.care.inkFaint),
                ]),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () async {
                  await ref.read(authServiceProvider).signOut();
                  ref.read(authFlowProvider.notifier).reset();
                  if (context.mounted) context.go('/login');
                },
                style: TextButton.styleFrom(foregroundColor: context.scheme.error),
                child: const Text('Sign out'),
              ),
            ),
            const SizedBox(height: 6),
            Center(child: Text('Rasoi Care Partner', style: context.type.bodySmall)),
          ],
        ),
      ),
    );
  }
}
