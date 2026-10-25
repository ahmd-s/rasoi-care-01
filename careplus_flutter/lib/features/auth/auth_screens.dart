import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_auth/smart_auth.dart';

import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/auth_providers.dart';
import '../../state/firestore_providers.dart';
import '../../state/providers.dart';
import '../../data/firebase/mock_auth_service.dart';
import '../../data/local/recent_phone_store.dart';
import '../../data/models.dart';
import '../account/legal_document_screen.dart';

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
      if (!mounted) return;
      // Already signed in from a previous session (Firebase persists this
      // across app restarts) — skip straight past onboarding/login instead
      // of making a returning customer sit through them again.
      final alreadySignedIn = ref.read(authServiceProvider).isSignedIn;
      if (alreadySignedIn) {
        // Sign-in itself already did this once, but that was on whatever
        // backend existed at the time — a returning session never runs
        // that step again, so if the backend's `users` row was ever lost
        // (e.g. a database migration reset it) there'd be no other chance
        // to recreate it, and every authenticated call would 401 forever.
        ref.read(authFlowProvider.notifier).bootstrapBackend();
      }
      if (!alreadySignedIn) {
        context.go('/onboarding');
        return;
      }
      final biometricOn = await ref.read(biometricServiceProvider).isEnabled();
      if (!mounted) return;
      context.go(biometricOn ? '/lock' : '/');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      // Same white background and 160dp logo as the native splash (see
      // launch_background.xml / values-v31), so the handoff is seamless.
      body: const Center(child: BrandLogo(size: 160, rounded: false)),
    );
  }
}

// ============================================================ ONBOARDING
class _Slide {
  const _Slide(this.title, this.body, this.icon);
  final String title, body;
  final IconData icon;
}

List<_Slide> _slides(AppLocalizations t) => [
      _Slide(t.authOnboardSlide1Title, t.authOnboardSlide1Body, Icons.kitchen_outlined),
      _Slide(t.authOnboardSlide2Title, t.authOnboardSlide2Body, Icons.receipt_long_outlined),
      _Slide(t.authOnboardSlide3Title, t.authOnboardSlide3Body, Icons.verified_user_outlined),
    ];

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pager = PageController();
  int _i = 0;

  void _next(List<_Slide> slides) {
    if (_i < slides.length - 1) {
      _pager.nextPage(duration: Motion.screen, curve: Motion.ease);
    } else {
      context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final slides = _slides(t);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Eyebrow(t.authOnboardStepCounter(_i + 1, slides.length)),
                  TextButton(
                      onPressed: () => context.go('/login'), child: Text(t.authOnboardSkip)),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pager,
                onPageChanged: (i) => setState(() => _i = i),
                itemCount: slides.length,
                itemBuilder: (_, i) {
                  final s = slides[i];
                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 280,
                          child: Center(
                            child: CareDial(
                              value: 0.62 + i * 0.12,
                              size: 220,
                              stroke: 10,
                              child: Icon(s.icon,
                                  size: 78, color: context.scheme.primary),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(s.title, style: context.type.headlineMedium),
                        const SizedBox(height: 12),
                        Text(s.body,
                            style: context.type.bodyMedium!.copyWith(fontSize: 14)),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 34),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: List.generate(
                          slides.length,
                          (d) => AnimatedContainer(
                            duration: Motion.screen,
                            width: d == _i ? 18 : 5,
                            height: 5,
                            margin: const EdgeInsets.only(right: 5),
                            decoration: BoxDecoration(
                              color: d == _i
                                  ? context.scheme.primary
                                  : context.care.hairline,
                              borderRadius: Radii.pill,
                            ),
                          ),
                        ),
                      ),
                      Mono(_i == slides.length - 1 ? t.authOnboardFreeToBrowse : t.authOnboardSwipeOrTap,
                          color: context.care.inkMuted),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => _next(slides),
                      child: Text(_i == slides.length - 1 ? t.authOnboardGetStarted : t.authOnboardNext),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
  void initState() {
    super.initState();
    RecentPhoneStore().read().then((saved) {
      if (mounted && saved != null) _phoneCtrl.text = saved;
    });
  }

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
      context.go('/register');
    } else {
      final err = ref.read(authFlowProvider).error;
      if (err != null && err != 'Sign-in cancelled.') {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      }
    }
  }

  Future<void> _send() async {
    final t = context.l10n;
    final digits = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 10) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.authPhoneInvalidNumber)));
      return;
    }
    final ok = await ref.read(authFlowProvider.notifier).sendOtp(digits);
    if (!mounted) return;
    if (ok) {
      unawaited(RecentPhoneStore().save(digits));
      context.push('/login/otp');
    } else {
      final err = ref.read(authFlowProvider).error ?? t.authPhoneSendFailed;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sending = ref.watch(authFlowProvider.select((s) => s.sending));
    final t = context.l10n;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const BrandLogo(size: 72),
              const SizedBox(height: 26),
              Text(t.authPhoneWelcomeBack, style: context.type.headlineLarge),
              const SizedBox(height: 10),
              Text(t.authPhoneSubtitle, style: context.type.bodyMedium),
              const SizedBox(height: 30),
              Row(
                children: [
                  CareCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                    child: const Text('🇮🇳 +91',
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: CareField(t.authPhoneMobileField,
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
                      : Text(t.authPhoneSendCode),
                ),
              ),
              const SizedBox(height: 26),
              Row(children: [
                const Expanded(child: Divider()),
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Mono(t.authPhoneOrDivider, color: context.care.inkMuted)),
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
                      : Text(t.authPhoneContinueWithGoogle),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                    onPressed: () => context.push('/login/email'),
                    child: Text(t.authPhoneContinueWithEmail)),
              ),
              const SizedBox(height: 22),
              Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(t.authPhoneNewToApp, style: context.type.bodySmall),
                    GestureDetector(
                      onTap: () => context.push('/register'),
                      child: Text(t.authPhoneCreateAccount,
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: context.scheme.primary)),
                    ),
                  ],
                ),
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

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final t = context.l10n;
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    final vm = ref.read(authFlowProvider.notifier);
    final ok = _creatingAccount
        ? await vm.registerWithEmail(email, password)
        : await vm.signInWithEmail(email, password);
    if (!mounted) return;
    if (ok) {
      context.go('/register');
    } else {
      final err = ref.read(authFlowProvider).error ?? t.authEmailGenericError;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final submitting = ref.watch(authFlowProvider.select((s) => s.submitting));
    final t = context.l10n;
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
                Text(_creatingAccount ? t.authEmailCreateTitle : t.authEmailSignInTitle,
                    style: context.type.headlineLarge),
                const SizedBox(height: 10),
                Text(
                    _creatingAccount ? t.authEmailCreateSubtitle : t.authEmailSignInSubtitle,
                    style: context.type.bodyMedium),
                const SizedBox(height: 30),
                CareField(t.authEmailField,
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    validator: (v) =>
                        (v == null || !v.contains('@')) ? t.authEmailInvalid : null),
                const SizedBox(height: 13),
                CareField(t.authEmailPasswordField,
                    controller: _passwordCtrl,
                    obscureText: _obscure,
                    suffix: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    validator: (v) =>
                        (v == null || v.length < 6) ? t.authEmailPasswordTooShort : null),
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
                        : Text(_creatingAccount ? t.authEmailCreateButton : t.authEmailSignInButton),
                  ),
                ),
                const SizedBox(height: 18),
                Center(
                  child: GestureDetector(
                    onTap: () => setState(() => _creatingAccount = !_creatingAccount),
                    child: Text(
                        _creatingAccount
                            ? t.authEmailToggleToSignIn
                            : t.authEmailToggleToCreate,
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
      context.go('/register');
    } else {
      final err = ref.read(authFlowProvider).error ?? context.l10n.authOtpVerificationFailed;
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
                    Text(t.authOtpTitle, style: context.type.headlineLarge),
                    const SizedBox(height: 10),
                    Text(
                        phone.isEmpty
                            ? t.authOtpSubtitleGeneric(_length)
                            : t.authOtpSubtitlePhone(phone),
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
                            ? t.authOtpVerifying
                            : isMock
                                ? (_mockCode.length < _length ? t.authOtpAutoReading : t.authOtpCodeRead)
                                : t.authOtpEnterFromSms,
                        style: context.type.bodySmall),
                    const SizedBox(height: 26),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(t.authOtpDidntGetIt, style: context.type.bodySmall),
                        GestureDetector(
                          onTap: _resend,
                          child: Mono(
                              _secs > 0
                                  ? t.authOtpResendIn(_secs.toString().padLeft(2, '0'))
                                  : t.authOtpResendCode,
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
                          child: Text(t.authOtpSecurityNote, style: context.type.bodySmall),
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
                      : Text(t.authOtpVerify),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================ REGISTER
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  // Google sign-in gives us a real name/email — prefill from that. Phone
  // OTP carries no profile info, so it's blank there; mock mode keeps the
  // original demo values so the flow still reads naturally without Firebase.
  late final _nameCtrl = TextEditingController(
      text: ref.read(authServiceProvider).currentDisplayName ??
          (ref.read(authFlowProvider.notifier).isMock ? 'Rohan Deshpande' : ''));
  late final _emailCtrl = TextEditingController(
      text: ref.read(authServiceProvider).currentEmail ??
          (ref.read(authFlowProvider.notifier).isMock ? 'rohan.d@gmail.com' : ''));
  // Non-null only when this account signed in via phone OTP — that number
  // is already Firebase-verified, so it's shown read-only instead of asking
  // for it again. Email/Google sign-ups have no phone on the account at
  // all (the gap this field exists to close), so they get an editable one.
  late final String? _verifiedPhone =
      RegExp(r'(\d{10})$').firstMatch(ref.read(authServiceProvider).currentPhoneNumber ?? '')?.group(1);
  late final _phoneCtrl = TextEditingController(text: _verifiedPhone ?? '');
  // Picked via the real map (or the plain-text fallback when no Maps key is
  // configured — see AddressPickerScreen), so this carries accurate
  // lat/lng, not just a typed line.
  SavedAddress? _pickedAddress;
  Set<String> _owned = {'Chimney', 'Hob', 'Refrigerator', 'Water purifier'};
  bool _saving = false;
  bool _confirmedAdult = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAddress() async {
    final picked = await context.push<SavedAddress>('/book/address/pick');
    if (picked != null && mounted) setState(() => _pickedAddress = picked);
  }

  Future<void> _save() async {
    final t = context.l10n;
    if (_pickedAddress == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.authRegisterAddAddress)));
      return;
    }
    // Already-verified phone-OTP sign-ins skip this — the number's real.
    // Everyone else (email/Google) must supply one here, since it's the
    // only number the technician's "Call" action and the cancellation-OTP
    // SMS have to reach them on.
    final phoneDigits = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (_verifiedPhone == null && !RegExp(r'^[0-9]{10}$').hasMatch(phoneDigits)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.authRegisterInvalidPhone)));
      return;
    }
    if (!_confirmedAdult) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.authRegisterConfirmAge)));
      return;
    }
    setState(() => _saving = true);
    // Fire-and-forget — see UserProfileService. Never blocks getting into
    // the app, even if Firestore is slow, unreachable, or not set up yet.
    unawaited(ref.read(userProfileServiceProvider).saveProfile(
          name: _nameCtrl.text.trim(),
          email: _emailCtrl.text.trim(),
          address: _pickedAddress!.line,
          lat: _pickedAddress!.lat,
          lng: _pickedAddress!.lng,
          ownedAppliances: _owned,
          phone: _verifiedPhone == null ? phoneDigits : null,
        ));
    // The backend's `users.phone` column only ever gets a phone-OTP number
    // for free (bootstrap reads it straight off the verified Firebase
    // token) — an email/Google sign-up has to hand it over explicitly, the
    // same call AccountScreen's phone editor makes after the fact.
    if (_verifiedPhone == null) {
      unawaited(ref.read(apiRepositoryProvider).updatePhone(phoneDigits, name: _nameCtrl.text.trim()));
    }
    if (!mounted) return;
    // Offer biometric login right after sign-up, but only on a device that
    // can actually satisfy it — no dead-end "no fingerprint enrolled" screen.
    final biometricSupported =
        await ref.read(biometricServiceProvider).isDeviceSupported();
    if (!mounted) return;
    context.go(biometricSupported ? '/biometric-enroll' : '/');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: context.pop),
        title: Text(t.authRegisterTitle),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const ProgressBar(0.66),
                    const SizedBox(height: 7),
                    Mono(t.authRegisterStep, color: context.care.inkMuted),
                    const SizedBox(height: 22),
                    CareField(t.authRegisterFullName, controller: _nameCtrl),
                    const SizedBox(height: 13),
                    CareField(t.authRegisterEmail,
                        controller: _emailCtrl, keyboardType: TextInputType.emailAddress),
                    const SizedBox(height: 13),
                    if (_verifiedPhone != null)
                      CareCard(
                        child: Row(children: [
                          Icon(Icons.verified_outlined, color: context.scheme.primary, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text('+91 $_verifiedPhone',
                                style: context.type.bodyMedium!.copyWith(fontWeight: FontWeight.w600)),
                          ),
                          Mono(t.authRegisterVerified, color: context.care.inkMuted),
                        ]),
                      )
                    else
                      Row(
                        children: [
                          CareCard(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                            child: const Text('🇮🇳 +91',
                                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: CareField(t.authRegisterMobileNumber,
                                controller: _phoneCtrl, keyboardType: TextInputType.phone),
                          ),
                        ],
                      ),
                    const SizedBox(height: 13),
                    Eyebrow(t.authRegisterAddressEyebrow),
                    const SizedBox(height: 8),
                    CareCard(
                      onTap: _pickAddress,
                      child: Row(children: [
                        Icon(Icons.location_on_outlined, color: context.scheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _pickedAddress?.line ?? t.authRegisterPickAddress,
                            style: _pickedAddress == null
                                ? context.type.bodyMedium
                                : context.type.bodyMedium!.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Icon(Icons.chevron_right, color: context.care.inkMuted),
                      ]),
                    ),
                    const SizedBox(height: 13),
                    CareField(t.authRegisterReferralCode),
                    const SizedBox(height: 20),
                    Eyebrow(t.authRegisterAppliancesEyebrow),
                    const SizedBox(height: 10),
                    _OwnedChips(owned: _owned, onChanged: (s) => _owned = s),
                    const SizedBox(height: 22),
                    _AgeAndTermsRow(
                      value: _confirmedAdult,
                      onChanged: (v) => setState(() => _confirmedAdult = v),
                    ),
                  ],
                ),
              ),
            ),
            Dock(
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(t.authRegisterSaveAndContinue),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OwnedChips extends StatefulWidget {
  const _OwnedChips({required this.owned, required this.onChanged});
  final Set<String> owned;
  final ValueChanged<Set<String>> onChanged;
  @override
  State<_OwnedChips> createState() => _OwnedChipsState();
}

class _OwnedChipsState extends State<_OwnedChips> {
  late final Set<String> _sel = {...widget.owned};
  // Internal keys sent straight to UserProfileService.saveProfile as
  // ownedAppliances — never shown as-is; see _ownedApplianceLabel for the
  // real, localized display text. Kept in English so the stored profile
  // data stays stable regardless of locale.
  static const _all = [
    'Chimney', 'Hob', 'Dishwasher', 'Refrigerator',
    'Built-in oven', 'OTG', 'Water purifier', 'Cooktop',
  ];
  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final a in _all)
          ChoiceTag(_ownedApplianceLabel(a, t),
              selected: _sel.contains(a),
              onTap: () => setState(() {
                    _sel.contains(a) ? _sel.remove(a) : _sel.add(a);
                    widget.onChanged(_sel);
                  })),
      ],
    );
  }
}

String _ownedApplianceLabel(String key, AppLocalizations t) => switch (key) {
      'Chimney' => t.authApplianceChimney,
      'Hob' => t.authApplianceHob,
      'Dishwasher' => t.authApplianceDishwasher,
      'Refrigerator' => t.authApplianceRefrigerator,
      'Built-in oven' => t.authApplianceBuiltInOven,
      'OTG' => t.authApplianceOtg,
      'Water purifier' => t.authApplianceWaterPurifier,
      _ => t.authApplianceCooktop,
    };

/// The age-eligibility gate every account must clear before finishing
/// sign-up — Rasoi Care doesn't verify age any other way (no ID upload at
/// registration), so this checkbox plus the required Terms/Privacy tap-
/// throughs are the real check in place today.
class _AgeAndTermsRow extends StatelessWidget {
  const _AgeAndTermsRow({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
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
                    TextSpan(text: t.authTermsConfirmPrefix),
                    TextSpan(
                      text: t.authTermsTermsOfService,
                      style: TextStyle(
                          color: context.scheme.primary,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => LegalDocumentScreen(
                                kind: 'terms', fallbackTitle: t.authTermsTermsOfService))),
                    ),
                    TextSpan(text: t.authTermsAnd),
                    TextSpan(
                      text: t.authTermsPrivacyPolicy,
                      style: TextStyle(
                          color: context.scheme.primary,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => LegalDocumentScreen(
                                kind: 'privacy', fallbackTitle: t.authTermsPrivacyPolicy))),
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
