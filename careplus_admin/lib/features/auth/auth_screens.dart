import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_auth/smart_auth.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/widgets/brand_logo.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/auth/mock_auth_service.dart';
import '../../data/models.dart';
import '../../state/auth_providers.dart';
import '../../state/providers.dart';
import 'legal_document_screen.dart';

/// Routes a just-signed-in staff/owner to the dashboard — the first time
/// this ever happens on a device that can actually satisfy fingerprint/face
/// unlock, it detours through a one-time "turn on biometric login?" offer
/// instead (see BiometricService.hasPrompted).
Future<void> _completeSignIn(BuildContext context, WidgetRef ref) async {
  final biometric = ref.read(biometricServiceProvider);
  final alreadyPrompted = await biometric.hasPrompted();
  if (!alreadyPrompted && await biometric.isDeviceSupported()) {
    if (context.mounted) context.go('/biometric-enroll');
    return;
  }
  if (context.mounted) context.go('/dashboard');
}

// ============================================================ SPLASH
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});
  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(milliseconds: 1600), () async {
      // Used to always land on /login regardless of whether Firebase still
      // had a valid persisted session — meaning a plain cold start (e.g.
      // Android killing the app after the system back button leaves it,
      // completely normal Android behavior, not a sign-out) forced a fresh
      // login every single time. This only ever ran the mock/no-Firebase
      // check the *other* two apps already had.
      if (!ref.read(authServiceProvider).isSignedIn) {
        if (mounted) context.go('/login');
        return;
      }
      // Re-sync the real role from the backend rather than trusting
      // whatever AuthFlowState.role defaults to (owner) — a restored
      // session never went through the login flow that normally sets it.
      await ref.read(authFlowProvider.notifier).bootstrapAndSyncRole();
      if (!mounted) return;
      // A returning session with biometric login turned on gets locked
      // behind a fingerprint/face check instead of dropping straight into
      // the dashboard — the one-time enroll offer in _completeSignIn is for
      // a fresh sign-in, not a resumed one.
      if (await ref.read(biometricServiceProvider).isEnabled()) {
        if (mounted) context.go('/lock');
        return;
      }
      if (mounted) context.go('/dashboard');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBF7ED),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandLogo(size: 220, rounded: false),
            const SizedBox(height: 20),
            Text('ADMIN',
                style: CareType.mono(CareColors.pine, size: 13)
                    .copyWith(letterSpacing: 4, fontWeight: FontWeight.w600)),
            const SizedBox(height: 20),
            Text('OPERATIONS · ANALYTICS · REPORTS',
                textAlign: TextAlign.center,
                style: CareType.mono(CareColors.pine.withValues(alpha: 0.78), size: 10)
                    .copyWith(letterSpacing: 2.2, height: 1.6)),
          ],
        ),
      ),
    );
  }
}

class _RoleToggle extends StatelessWidget {
  const _RoleToggle({required this.role, required this.onChanged});
  final AdminRole role;
  final ValueChanged<AdminRole> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: context.scheme.surfaceContainerHigh, borderRadius: Radii.rSm),
        child: Row(
          children: [
            for (final r in AdminRole.values)
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(r),
                  child: AnimatedContainer(
                    duration: Motion.press,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: r == role ? context.scheme.surface : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: r == role
                          ? Shadows.card(Theme.of(context).brightness == Brightness.dark)
                          : null,
                    ),
                    child: Text(r.label,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: r == role
                                ? context.scheme.onSurface
                                : context.care.inkMuted)),
                  ),
                ),
              ),
          ],
        ),
      );
}

// ============================================================ PHONE
class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});
  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _phoneCtrl = TextEditingController();
  bool _googleBusy = false;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _continueWithGoogle() async {
    setState(() => _googleBusy = true);
    final ok = await ref.read(authFlowProvider.notifier).signInWithGoogle();
    if (!mounted) return;
    setState(() => _googleBusy = false);
    if (ok) {
      _completeSignIn(context, ref);
    } else {
      final err = ref.read(authFlowProvider).error;
      if (err != null && err != 'Sign-in cancelled.') {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      }
    }
  }

  Future<void> _send() async {
    final digits = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 10) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a 10-digit mobile number.')));
      return;
    }
    final ok = await ref.read(authFlowProvider.notifier).sendOtp(digits);
    if (!mounted) return;
    if (ok) {
      context.push('/login/otp');
    } else {
      final err = ref.read(authFlowProvider).error ?? 'Could not send a code.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sending = ref.watch(authFlowProvider.select((s) => s.sending));
    final role = ref.watch(authFlowProvider.select((s) => s.role));
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(child: BrandLogo(size: 128)),
              const SizedBox(height: 26),
              Text('Rasoi Care Admin', style: context.type.headlineLarge),
              const SizedBox(height: 10),
              Text(
                  "Sign in with your mobile number. We'll text you a one-time code.",
                  style: context.type.bodyMedium),
              const SizedBox(height: 24),
              Eyebrow('Signing in as'),
              const SizedBox(height: 10),
              _RoleToggle(
                role: role,
                onChanged: (r) => ref.read(authFlowProvider.notifier).setRole(r),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  CareCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                    child: const Text('🇮🇳 +91',
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: CareField('Mobile number',
                        controller: _phoneCtrl, keyboardType: TextInputType.phone),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: sending ? null : _send,
                  child: sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Send code'),
                ),
              ),
              const SizedBox(height: 26),
              Row(children: [
                const Expanded(child: Divider()),
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Mono('OR', color: context.care.inkMuted)),
                const Expanded(child: Divider()),
              ]),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _googleBusy ? null : _continueWithGoogle,
                  child: _googleBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Continue with Google'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                    onPressed: () => context.push('/login/email'),
                    child: const Text('Continue with email')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================ EMAIL
class EmailAuthScreen extends ConsumerStatefulWidget {
  const EmailAuthScreen({super.key});
  @override
  ConsumerState<EmailAuthScreen> createState() => _EmailAuthScreenState();
}

class _EmailAuthScreenState extends ConsumerState<EmailAuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _creatingAccount = false;
  bool _obscure = true;
  bool _confirmedAdult = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_creatingAccount && !_confirmedAdult) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Confirm you are 18 or older and agree to the Terms to continue.')));
      return;
    }
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    final vm = ref.read(authFlowProvider.notifier);
    final ok = _creatingAccount
        ? await vm.registerWithEmail(email, password)
        : await vm.signInWithEmail(email, password);
    if (!mounted) return;
    if (ok) {
      _completeSignIn(context, ref);
    } else {
      final err = ref.read(authFlowProvider).error ?? 'Something went wrong.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final submitting = ref.watch(authFlowProvider.select((s) => s.submitting));
    final role = ref.watch(authFlowProvider.select((s) => s.role));
    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: context.pop)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 30),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CareDial(
                  value: 1,
                  size: 54,
                  stroke: 5,
                  showTicks: false,
                  child: Icon(Icons.insights_outlined, color: context.scheme.primary, size: 22),
                ),
                const SizedBox(height: 26),
                Text(_creatingAccount ? 'Create an account' : 'Rasoi Care Admin',
                    style: context.type.headlineLarge),
                const SizedBox(height: 10),
                Text(
                    _creatingAccount
                        ? 'Set an email and password — signing in as ${role.label}.'
                        : 'Sign in with email — signing in as ${role.label}.',
                    style: context.type.bodyMedium),
                const SizedBox(height: 24),
                Eyebrow('Signing in as'),
                const SizedBox(height: 10),
                _RoleToggle(
                  role: role,
                  onChanged: (r) => ref.read(authFlowProvider.notifier).setRole(r),
                ),
                const SizedBox(height: 24),
                CareField('Email',
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Enter a valid email address'
                        : null),
                const SizedBox(height: 13),
                CareField('Password',
                    controller: _passwordCtrl,
                    obscureText: _obscure,
                    suffix: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    validator: (v) => (v == null || v.length < 6)
                        ? 'Password must be at least 6 characters'
                        : null),
                if (_creatingAccount) ...[
                  const SizedBox(height: 18),
                  _AgeAndTermsRow(
                    value: _confirmedAdult,
                    onChanged: (v) => setState(() => _confirmedAdult = v),
                  ),
                ],
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: submitting ? null : _submit,
                    child: submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_creatingAccount ? 'Create account' : 'Sign in'),
                  ),
                ),
                const SizedBox(height: 18),
                Center(
                  child: GestureDetector(
                    onTap: () => setState(() => _creatingAccount = !_creatingAccount),
                    child: Text(
                        _creatingAccount
                            ? 'Already have an account? Sign in'
                            : "New here? Create an account",
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: context.scheme.primary)),
                  ),
                ),
                const SizedBox(height: 22),
                CareCard(
                  color: context.scheme.surfaceContainerHigh,
                  borderColor: Colors.transparent,
                  child: Row(children: [
                    const Text('🔐', style: TextStyle(fontSize: 17)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                          'Owner sees financials and staff access. Staff members get operations and reports without payout detail.',
                          style: context.type.bodySmall),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================ OTP
class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key});
  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  // Firebase's real SMS codes are 6 digits; the mock demo code is 4. Using
  // a hardcoded 4 here meant a real code could never be fully entered — the
  // 4th digit auto-submitted an incomplete code and verification always
  // failed, even when the SMS had genuinely arrived.
  late final int _length = ref.read(authFlowProvider.notifier).isMock ? 4 : 6;
  // Live mode types into one real (invisible) field overlaid on the boxes —
  // not one TextField per box. Separate boxes each juggling their own
  // FocusNode is the usual way this kind of UI silently ends up with no box
  // ever focused (nothing requests focus on open, so the on-screen keyboard
  // has nothing to type into) — a single field sidesteps that whole bug
  // class: autofocus is trivial, backspace works for free, and there's only
  // ever one focus target. Mock mode has no keyboard at all (it's a
  // read-only auto-fill demo), so it just animates a plain string.
  final _codeCtrl = TextEditingController();
  final _codeFocus = FocusNode();
  String _mockCode = '';
  int _secs = 24;
  Timer? _t;
  bool _verifying = false;

  String get _code =>
      ref.read(authFlowProvider.notifier).isMock ? _mockCode : _codeCtrl.text;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_secs == 0) return;
      setState(() => _secs--);
    });
    // Mock mode fakes SMS auto-read on a timer; live mode listens for the
    // real SMS via Android's User Consent API (no manifest permission
    // needed — the OS shows its own one-time "allow?" dialog).
    if (ref.read(authFlowProvider.notifier).isMock) {
      const code = MockAuthService.demoCode;
      for (var i = 0; i < _length; i++) {
        Timer(Duration(milliseconds: 420 + i * 230), () {
          if (!mounted) return;
          setState(() => _mockCode = code.substring(0, i + 1));
          if (i == _length - 1) _submit();
        });
      }
    } else {
      _listenForSms();
    }
  }

  Future<void> _listenForSms() async {
    // Firebase's codes are always exactly 6 digits — matching that exactly
    // (rather than the package's default 4-8 digit range) avoids grabbing
    // the wrong digit run out of an SMS that happens to contain other
    // numbers (a DLT sender-ID header, a phone number, etc.) before the
    // real code.
    final result = await SmartAuth.instance.getSmsWithUserConsentApi(matcher: r'\d{6}');
    if (!mounted) return;
    final code = result.data?.code;
    if (code == null || code.length != _length) {
      // Not surfaced to the user — the manual code boxes are already
      // focused and usable, so a missed auto-read isn't a dead end, just a
      // convenience that didn't fire this time (e.g. the sender is saved
      // as a contact, which Android's User Consent API deliberately
      // ignores, or the OS-level "Allow?" prompt was dismissed).
      debugPrint('OtpScreen: SMS auto-read found no usable code (result: $result)');
      return;
    }
    setState(() => _codeCtrl.text = code);
    _submit();
  }

  @override
  void dispose() {
    _t?.cancel();
    _codeCtrl.dispose();
    _codeFocus.dispose();
    if (!ref.read(authFlowProvider.notifier).isMock) {
      SmartAuth.instance.removeUserConsentApiListener();
    }
    super.dispose();
  }

  void _onCodeChanged(String v) {
    setState(() {});
    if (v.length == _length) _submit();
  }

  Future<void> _submit() async {
    if (_verifying || _code.length != _length) return;
    setState(() => _verifying = true);
    final ok = await ref.read(authFlowProvider.notifier).verifyOtp(_code);
    if (!mounted) return;
    setState(() => _verifying = false);
    if (ok) {
      _completeSignIn(context, ref);
    } else {
      final err = ref.read(authFlowProvider).error ?? 'Verification failed.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      setState(() => _codeCtrl.clear());
    }
  }

  Future<void> _resend() async {
    if (_secs > 0) return;
    final phone = ref.read(authFlowProvider).phone;
    setState(() => _secs = 24);
    await ref.read(authFlowProvider.notifier).sendOtp(phone);
    // getSmsWithUserConsentApi's native listener is one-shot — it already
    // resolved (or timed out) for the first SMS, so a resent code needs its
    // own fresh registration or auto-fill would never see it.
    if (!ref.read(authFlowProvider.notifier).isMock) _listenForSms();
  }

  @override
  Widget build(BuildContext context) {
    final isMock = ref.watch(authFlowProvider.notifier).isMock;
    final phone = ref.watch(authFlowProvider.select((s) => s.phone));
    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: context.pop)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Enter the code', style: context.type.headlineLarge),
                    const SizedBox(height: 10),
                    Text(
                        phone.isEmpty
                            ? 'Enter the $_length-digit code we sent.'
                            : 'Sent to +91 $phone.',
                        style: context.type.bodyMedium),
                    const SizedBox(height: 34),
                    Stack(
                      children: [
                        Row(
                          children: [
                            for (var i = 0; i < _length; i++) ...[
                              Expanded(
                                child: _OtpBox(
                                  digit: i < _code.length ? _code[i] : '',
                                  filled: i < _code.length,
                                  active: i == _code.length && _code.length < _length,
                                ),
                              ),
                              if (i != _length - 1) const SizedBox(width: 11),
                            ],
                          ],
                        ),
                        // The actual typing surface — invisible, but sized to
                        // cover the whole box row so tapping anywhere focuses
                        // it. Mock mode has nothing here; the boxes above
                        // just animate _mockCode on a timer.
                        //
                        // Two independent auto-fill paths feed this same
                        // field, whichever fires first: SmartAuth's User
                        // Consent API above (a system "Allow?" banner reading
                        // the SMS directly), and — new here — the platform
                        // Autofill Framework's own SMS suggestion chip above
                        // the keyboard, triggered by `autofillHints:
                        // oneTimeCode` inside a real `AutofillGroup`. The
                        // second one needs no dialog at all and is what iOS
                        // and most modern Android keyboards surface as a
                        // one-tap "123456" suggestion.
                        if (!isMock)
                          Positioned.fill(
                            child: Opacity(
                              opacity: 0,
                              child: AutofillGroup(
                                child: TextField(
                                  controller: _codeCtrl,
                                  focusNode: _codeFocus,
                                  autofocus: true,
                                  keyboardType: TextInputType.number,
                                  maxLength: _length,
                                  autofillHints: const [AutofillHints.oneTimeCode],
                                  decoration: const InputDecoration(
                                      counterText: '', border: InputBorder.none),
                                  onChanged: _onCodeChanged,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                        _verifying
                            ? 'Verifying…'
                            : isMock
                                ? (_mockCode.length < _length ? 'Auto-reading SMS…' : 'Code read from SMS.')
                                : 'Enter the code from the SMS you received.',
                        style: context.type.bodySmall),
                    const SizedBox(height: 26),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("Didn't get it?", style: context.type.bodySmall),
                        GestureDetector(
                          onTap: _resend,
                          child: Mono(
                              _secs > 0
                                  ? 'Resend in 0:${_secs.toString().padLeft(2, '0')}'
                                  : 'Resend code',
                              color: context.scheme.secondary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),
                    CareCard(
                      color: context.scheme.primaryContainer,
                      borderColor: Colors.transparent,
                      child: Row(children: [
                        const Text('🔒', style: TextStyle(fontSize: 17)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                              'Rasoi Care never asks for your OTP over a call. Share it only inside this app.',
                              style: context.type.bodySmall),
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _verifying ? null : _submit,
                  child: _verifying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Verify'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One digit cell in the OTP row. A filled digit gets a soft primary-tinted
/// fill and a matching glow; the next box waiting for input gets a brighter
/// glow, a thicker border, a slight pop (via the caller's scale), and a
/// blinking cursor so it's obvious exactly where typing lands — same
/// underlying single-hidden-TextField input as before (see the Stack this
/// sits in), just a clearer view of the state that field is already tracking.
class _OtpBox extends StatelessWidget {
  const _OtpBox({required this.digit, required this.filled, required this.active});
  final String digit;
  final bool filled;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final accent = context.scheme.primary;
    return AnimatedScale(
      scale: active ? 1.06 : 1.0,
      duration: Motion.press,
      curve: Motion.ease,
      child: AnimatedContainer(
        duration: Motion.press,
        curve: Motion.ease,
        height: 68,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? accent.withValues(alpha: 0.10) : context.scheme.surface,
          borderRadius: Radii.rLg,
          border: Border.all(
            color: filled || active ? accent : context.care.hairline,
            width: active ? 2 : 1.5,
          ),
          boxShadow: filled || active
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: active ? 0.32 : 0.14),
                    blurRadius: active ? 18 : 8,
                    spreadRadius: active ? 1 : 0,
                  ),
                ]
              : null,
        ),
        child: digit.isNotEmpty
            ? Text(digit,
                style: CareType.mono(context.scheme.onSurface, size: 24, w: FontWeight.w700))
            : (active ? _BlinkCursor(color: accent) : null),
      ),
    );
  }
}

/// A slow, steady fade in/out — the "something is waiting for you here"
/// signal on the OTP row's next empty box, independent of the real input
/// field's own (invisible) cursor.
class _BlinkCursor extends StatefulWidget {
  const _BlinkCursor({required this.color});
  final Color color;
  @override
  State<_BlinkCursor> createState() => _BlinkCursorState();
}

class _BlinkCursorState extends State<_BlinkCursor> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _c.drive(CurveTween(curve: Curves.easeInOut)),
        child: Container(
          width: 2,
          height: 26,
          decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(1)),
        ),
      );
}

/// The age-eligibility gate a new Owner/Staff account must clear before it's
/// created — there's no other age verification step in this sign-up flow.
class _AgeAndTermsRow extends StatelessWidget {
  const _AgeAndTermsRow({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return CareCard(
      color: context.scheme.surfaceContainerHigh,
      borderColor: Colors.transparent,
      onTap: () => onChanged(!value),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 13),
              child: RichText(
                text: TextSpan(
                  style: context.type.bodySmall?.copyWith(color: context.care.inkMuted) ??
                      TextStyle(color: context.care.inkMuted, fontSize: 12.5),
                  children: [
                    const TextSpan(text: 'I confirm I am 18 years or older, and I agree to the '),
                    TextSpan(
                      text: 'Terms of Service',
                      style: TextStyle(
                          color: context.scheme.primary,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const LegalDocumentScreen(
                                kind: 'terms', fallbackTitle: 'Terms of Service'))),
                    ),
                    const TextSpan(text: ' and '),
                    TextSpan(
                      text: 'Privacy Policy',
                      style: TextStyle(
                          color: context.scheme.primary,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const LegalDocumentScreen(
                                kind: 'privacy', fallbackTitle: 'Privacy Policy'))),
                    ),
                    const TextSpan(text: '.'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
