import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_auth/smart_auth.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/auth_providers.dart';
import '../../state/providers.dart';
import '../../data/auth/mock_auth_service.dart';

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
      if (!ref.read(authServiceProvider).isSignedIn) {
        if (mounted) context.go('/login');
        return;
      }
      // Reopen the workspace that was explicitly picked at sign-in. Staff and
      // Owner sessions must re-resolve to exactly that role; they never fall
      // back to the technician app.
      final picked = await SignInRoleStore.load();
      if (!mounted) return;
      if (picked == SignInRole.staff || picked == SignInRole.owner) {
        final restored = await refreshStaffRole(ref, selected: picked);
        if (!mounted) return;
        context.go(restored != null ? '/ops/overview' : '/login');
        return;
      }
      if (picked == SignInRole.technician) {
        ref.read(authFlowProvider.notifier).setStaffRole(null);
      } else {
        // Session from before role selection existed.
        final staffRole = await refreshStaffRole(ref);
        if (!mounted) return;
        if (staffRole != null) {
          context.go('/ops/overview');
          return;
        }
      }
      // Already signed in from a previous session — find out where they
      // actually belong (still applying, awaiting verification, or fully
      // onboarded) instead of always dropping them at the job feed.
      final result = await fetchTechnicianMeResult();
      if (!mounted) return;
      if (result.rejected) {
        // The backend refused this session's token (wrong environment or an
        // expired/invalid session) — don't present a technician experience
        // that can't load anything; start over from sign-in.
        await ref.read(authServiceProvider).signOut();
        ref.read(authFlowProvider.notifier).reset();
        if (mounted) context.go('/login');
        return;
      }
      final tech = result.json;
      final stage = stageFromTechnicianJson(tech);
      // A returning, already-verified session with biometric login turned
      // on gets locked behind a fingerprint/face check instead of dropping
      // straight into the job feed — routeToStage's one-time enroll offer
      // is for a session reaching the feed for the first time, not this.
      if (stage == TechnicianStage.jobs && await ref.read(biometricServiceProvider).isEnabled()) {
        if (mounted) context.go('/lock');
        return;
      }
      if (mounted) routeToStage(context, ref, stage);
    });
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
            CareDial(
              value: 0.78,
              size: 110,
              color: CareColors.brass,
              trackColor: const Color(0x33F6F4EF),
              child: const Icon(Icons.build_outlined, color: CareColors.porcelain, size: 34),
            ),
            const SizedBox(height: 26),
            Text(t.splashBrand, style: CareType.display(CareColors.porcelain, size: 34)),
            Text(t.splashPartnerBadge,
                style: CareType.mono(CareColors.brass, size: 13)
                    .copyWith(letterSpacing: 4, fontWeight: FontWeight.w600)),
            const SizedBox(height: 20),
            Text(t.splashTagline,
                textAlign: TextAlign.center,
                style: CareType.mono(CareColors.porcelain.withValues(alpha: 0.6), size: 10)
                    .copyWith(letterSpacing: 2.2, height: 1.6)),
          ],
        ),
      ),
    );
  }
}

// ============================================================ PHONE
//
// Single login path: mobile number + OTP is the only way in, and it's also
// the only way to create an account — a new number just gets bootstrapped a
// technician record on OTP verify (see bootstrapTechnicianBackend) and is
// routed to TechApplyScreen. The toggle below only changes the copy/button
// label to make that "new partner? enter your number to create an account"
// path visible on the starting page — both modes do the exact same OTP send.
class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});
  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _phoneCtrl = TextEditingController();
  bool _creatingAccount = false;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = context.l10n;
    final digits = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 10) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.phoneErrorDigits)));
      return;
    }
    final ok = await ref.read(authFlowProvider.notifier).sendOtp(digits);
    if (!mounted) return;
    if (ok) {
      context.push('/login/phone/otp');
    } else {
      final err = ref.read(authFlowProvider).error ?? t.phoneErrorGeneric;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _signInWithGoogle() async {
    final ok = await ref.read(authFlowProvider.notifier).signInWithGoogle();
    if (!mounted) return;
    if (ok) {
      if (ref.read(authFlowProvider).signInRole == SignInRole.technician) {
        routeToStage(context, ref, ref.read(authFlowProvider).stage);
      } else {
        context.go('/ops/overview');
      }
      return;
    }
    final error = ref.read(authFlowProvider).error ?? context.l10n.googleStaffSignInError;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(authFlowProvider.select((s) => s.signInRole));
    if (role == null) {
      // Arrived without choosing a role (for example a stale deep link).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/login');
      });
      return const Scaffold(body: SizedBox.shrink());
    }
    final isOwner = role == SignInRole.owner;
    final sending = ref.watch(authFlowProvider.select((s) => s.sending));
    final submitting = ref.watch(authFlowProvider.select((s) => s.submitting));
    final t = context.l10n;
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
              Text(
                  isOwner
                      ? 'Owner sign-in'
                      : (_creatingAccount ? t.phoneTitleCreate : t.phoneTitleSignIn),
                  style: context.type.headlineLarge),
              const SizedBox(height: 10),
              Text(
                  isOwner
                      ? 'Owners sign in with the configured Google account only.'
                      : (_creatingAccount ? t.phoneBodyCreate : t.phoneBodySignIn),
                  style: context.type.bodyMedium),
              const SizedBox(height: 30),
              if (!isOwner) ...[
              Row(
                children: [
                  CareCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                    child: const Text('🇮🇳 +91',
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: CareField(t.phoneFieldLabel,
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
                      : Text(_creatingAccount ? t.phoneButtonCreate : t.phoneButtonSend),
                ),
              ),
              const SizedBox(height: 10),
              ],
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: submitting ? null : _signInWithGoogle,
                  icon: submitting
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.account_circle_outlined),
                  label: Text(t.googleStaffSignIn),
                ),
              ),
              const SizedBox(height: 18),
              if (role == SignInRole.technician)
              Center(
                child: GestureDetector(
                  onTap: () => setState(() => _creatingAccount = !_creatingAccount),
                  child: Text(
                      _creatingAccount ? t.phoneToggleToSignIn : t.phoneToggleToCreate,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: context.scheme.primary)),
                ),
              ),
            ],
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
  // Firebase's real SMS codes are 6 digits; the mock demo code is 4.
  late final int _length = ref.read(authFlowProvider.notifier).isMock ? 4 : 6;
  // Live mode types into one real (invisible) field overlaid on the boxes —
  // not one TextField per box. Six separate boxes each juggling their own
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
      // Logs only that auto-read came up empty, never `result` itself —
      // that's the raw SmsCodeResult, which can carry a partially- or
      // incorrectly-parsed digit run pulled straight out of the SMS body.
      debugPrint('OtpScreen: SMS auto-read found no usable code');
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
      routeToStage(context, ref, ref.read(authFlowProvider).stage);
    } else {
      final err = ref.read(authFlowProvider).error ?? context.l10n.otpErrorGeneric;
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
    final t = context.l10n;
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
                    Text(t.otpTitle, style: context.type.headlineLarge),
                    const SizedBox(height: 10),
                    Text(
                        phone.isEmpty
                            ? t.otpBodyGeneric(_length)
                            : t.otpBodySentTo(phone),
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
                            ? t.otpVerifying
                            : isMock
                                ? (_mockCode.length < _length ? t.otpAutoReading : t.otpCodeRead)
                                : t.otpEnterFromSms,
                        style: context.type.bodySmall),
                    const SizedBox(height: 26),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(t.otpDidntGetIt, style: context.type.bodySmall),
                        GestureDetector(
                          onTap: _resend,
                          child: Mono(
                              _secs > 0
                                  ? t.otpResendIn(_secs.toString().padLeft(2, '0'))
                                  : t.otpResendCode,
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
                          child: Text(t.otpSecurityNote, style: context.type.bodySmall),
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
                      : Text(t.otpVerify),
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
