import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/care_plus_theme.dart';
import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/care_widgets.dart';
import '../../data/auth/auth_service.dart';
import '../../state/auth_providers.dart';

/// Email/password sign-in is intentionally limited to the Technician
/// workspace. Staff and Owner access continue to use their existing
/// Firebase identity and server-side roster/allowlist checks.
class PartnerEmailAuthScreen extends ConsumerStatefulWidget {
  const PartnerEmailAuthScreen({super.key});

  @override
  ConsumerState<PartnerEmailAuthScreen> createState() =>
      _PartnerEmailAuthScreenState();
}

class _PartnerEmailAuthScreenState
    extends ConsumerState<PartnerEmailAuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _creatingAccount = false;
  bool _obscurePassword = true;
  bool _resettingPassword = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (ref.read(authFlowProvider).signInRole != SignInRole.technician) {
      context.go('/login');
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final vm = ref.read(authFlowProvider.notifier);
    final ok = _creatingAccount
        ? await vm.registerWithEmail(_emailCtrl.text.trim(), _passwordCtrl.text)
        : await vm.signInWithEmail(_emailCtrl.text.trim(), _passwordCtrl.text);
    if (!mounted) return;
    if (ok) {
      routeToStage(context, ref, ref.read(authFlowProvider).stage);
    } else {
      final message =
          ref.read(authFlowProvider).error ??
          'Could not sign in. Check your details and try again.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _sendPasswordReset() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your email address first.')),
      );
      return;
    }

    setState(() => _resettingPassword = true);
    try {
      await ref.read(authServiceProvider).sendPasswordResetEmail(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'If an account exists, a password reset link has been sent.',
          ),
        ),
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _resettingPassword = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(authFlowProvider.select((s) => s.signInRole));
    if (role != SignInRole.technician) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/login');
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final submitting = ref.watch(authFlowProvider.select((s) => s.submitting));
    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: context.pop)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const BrandLogo(size: 72),
                const SizedBox(height: 24),
                Text(
                  _creatingAccount
                      ? 'Create partner account'
                      : 'Partner sign in',
                  style: context.type.headlineLarge,
                ),
                const SizedBox(height: 10),
                Text(
                  'Use your email and password to continue as a technician.',
                  style: context.type.bodyMedium,
                ),
                const SizedBox(height: 28),
                CareField(
                  'Email address',
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  validator: (value) =>
                      value == null || !value.trim().contains('@')
                      ? 'Enter a valid email address.'
                      : null,
                ),
                const SizedBox(height: 14),
                CareField(
                  'Password',
                  controller: _passwordCtrl,
                  obscureText: _obscurePassword,
                  suffix: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                  validator: (value) => value == null || value.length < 6
                      ? 'Password must be at least 6 characters.'
                      : null,
                ),
                if (!_creatingAccount)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _resettingPassword ? null : _sendPasswordReset,
                      child: Text(
                        _resettingPassword ? 'Sending…' : 'Forgot password?',
                      ),
                    ),
                  ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: submitting ? null : _submit,
                    child: submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_creatingAccount ? 'Create account' : 'Sign in'),
                  ),
                ),
                const SizedBox(height: 14),
                Center(
                  child: TextButton(
                    onPressed: submitting
                        ? null
                        : () => setState(
                            () => _creatingAccount = !_creatingAccount,
                          ),
                    child: Text(
                      _creatingAccount
                          ? 'Already have an account? Sign in'
                          : 'New partner? Create an account',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
