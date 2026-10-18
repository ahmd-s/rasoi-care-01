import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/care_plus_theme.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/auth_providers.dart';
import '../../state/providers.dart';

/// Shown once, right after a technician's application first reaches the
/// job feed (fresh sign-up, or the day their application gets verified) —
/// offers to turn on fingerprint/face unlock for next time. Only reached
/// when the device actually has usable biometric hardware, so there's no
/// "no fingerprint enrolled" dead end here. Marks itself as shown the
/// moment it appears, so it's never offered a second time whether someone
/// enables it or skips it.
class BiometricEnrollScreen extends ConsumerStatefulWidget {
  const BiometricEnrollScreen({this.nextRoute = '/tech/jobs', super.key});

  /// Where to land once this screen is done, either way.
  final String nextRoute;

  @override
  ConsumerState<BiometricEnrollScreen> createState() => _BiometricEnrollScreenState();
}

class _BiometricEnrollScreenState extends ConsumerState<BiometricEnrollScreen> {
  bool _working = false;

  @override
  void initState() {
    super.initState();
    ref.read(biometricServiceProvider).setPrompted(true);
  }

  Future<void> _enable() async {
    setState(() => _working = true);
    final ok = await ref
        .read(biometricServiceProvider)
        .authenticate(context.l10n.biometricEnrollAuthReason);
    if (!mounted) return;
    if (ok) {
      await ref.read(biometricEnabledProvider.notifier).set(true);
      if (!mounted) return;
      context.go(widget.nextRoute);
    } else {
      setState(() => _working = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.biometricEnrollError)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.fingerprint, size: 64, color: context.scheme.primary),
              const SizedBox(height: 24),
              Text(t.biometricEnrollTitle,
                  style: CareType.display(context.scheme.onSurface, size: 26)),
              const SizedBox(height: 12),
              Text(
                t.biometricEnrollBody,
                style: context.type.bodyMedium!.copyWith(color: context.care.inkMuted),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _working ? null : _enable,
                  child: _working
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(t.biometricEnrollButton),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: _working ? null : () => context.go(widget.nextRoute),
                  child: Text(t.biometricEnrollSkip),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gates a returning, already-signed-in session behind a fingerprint/face
/// check when biometric login is turned on — see SplashScreen. Signing out
/// is always offered as an escape hatch so a failed sensor never strands
/// anyone outside their own account.
class BiometricLockScreen extends ConsumerStatefulWidget {
  const BiometricLockScreen({super.key});
  @override
  ConsumerState<BiometricLockScreen> createState() => _BiometricLockScreenState();
}

class _BiometricLockScreenState extends ConsumerState<BiometricLockScreen> {
  bool _working = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    setState(() {
      _working = true;
      _failed = false;
    });
    final ok = await ref
        .read(biometricServiceProvider)
        .authenticate(context.l10n.biometricLockAuthReason);
    if (!mounted) return;
    if (ok) {
      context.go(ref.read(authFlowProvider).staffRole != null
          ? '/ops/overview'
          : '/tech/jobs');
    } else {
      setState(() {
        _working = false;
        _failed = true;
      });
    }
  }

  Future<void> _signOut() async {
    await ref.read(authServiceProvider).signOut();
    ref.read(authFlowProvider.notifier).reset();
    if (!mounted) return;
    context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return Scaffold(
      backgroundColor: CareColors.pine,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fingerprint, size: 72, color: CareColors.porcelain),
            const SizedBox(height: 20),
            Text('Rasoi Care Partner', style: CareType.display(CareColors.porcelain, size: 24)),
            const SizedBox(height: 8),
            Text(
              _failed ? t.biometricLockSubtitleFailed : t.biometricLockSubtitleDefault,
              style: CareType.mono(CareColors.brass, size: 11).copyWith(letterSpacing: 1.2),
            ),
            const SizedBox(height: 28),
            if (_working)
              const CircularProgressIndicator(color: CareColors.brass)
            else
              FilledButton(
                onPressed: _unlock,
                child: Text(t.biometricLockRetry),
              ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _working ? null : _signOut,
              child: Text(t.biometricLockSignOut, style: const TextStyle(color: CareColors.porcelain)),
            ),
          ],
        ),
      ),
    );
  }
}
