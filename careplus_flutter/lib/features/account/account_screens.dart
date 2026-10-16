import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/api/api_repository.dart';
import '../../data/models.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/providers.dart';
import '../../state/auth_providers.dart';
import '../../state/firestore_providers.dart';
import '../booking/cancellation_policy_sheet.dart';
import '../settings/language_screen.dart';
import 'legal_document_screen.dart';

/// True while a just-picked profile photo is uploading — the avatar shows a
/// spinner instead of letting you fire off a second upload mid-flight.
final _uploadingPhotoProvider = StateProvider<bool>((ref) => false);

// ============================================================ BOOKINGS
class BookingsScreen extends ConsumerStatefulWidget {
  const BookingsScreen({super.key});
  @override
  ConsumerState<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends ConsumerState<BookingsScreen> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // The repository's constructor already tries once, but that can race
    // Firebase Auth restoring `currentUser` on a cold start and silently
    // never retry — leaving this screen stuck on mock demo bookings for the
    // rest of the session. Asking again on every real visit to this screen
    // means a failed first attempt gets a real second chance.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final repo = ref.read(repositoryProvider);
    if (repo is ApiRepository) await repo.refreshBookings();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    // Rebuild when ApiRepository's real-booking cache changes (initial
    // fetch lands, or a booking is just created) — see providers.dart.
    ref.watch(bookingsRefreshProvider);
    final upcoming = repo.bookings();
    final past = repo.bookings(completed: true);
    final cancelled = repo.bookings(status: BookingStatus.cancelled);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your bookings'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _Tabs(
                labels: const ['Upcoming', 'Completed', 'Cancelled'],
                index: _tab,
                onChanged: (i) => setState(() => _tab = i),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: switch (_tab) {
                0 => upcoming.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: EmptyState(
                          glyph: '◌',
                          title: 'No upcoming visits',
                          body: 'Book a service and it shows up here.',
                          action: OutlinedButton(
                              onPressed: () => context.go('/services'),
                              child: const Text('Browse services')),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                        children: [
                          for (final b in upcoming) ...[
                            _BookingCard(booking: b, onCancel: () => _confirmCancel(b)),
                            const SizedBox(height: 10),
                          ],
                        ],
                      ),
                1 => ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                    children: [
                      for (final b in past) ...[
                        _BookingCard(booking: b, completed: true),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
                _ => cancelled.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: EmptyState(
                          glyph: '◌',
                          title: 'Nothing cancelled',
                          body: 'Cancelled visits appear here with any fee charged.',
                          action: OutlinedButton(
                              onPressed: () => context.go('/services'),
                              child: const Text('Browse services')),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                        children: [
                          for (final b in cancelled) ...[
                            _BookingCard(booking: b),
                            const SizedBox(height: 10),
                          ],
                        ],
                      ),
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCancel(Booking booking) async {
    final feePreview = ApiRepository.cancellationFeePreviewPaise(booking);
    final feeLine = feePreview == null
        ? "This job's already too far along to cancel."
        : feePreview == 0
            ? 'No technician has taken this job yet — cancelling now is free.'
            : 'A technician has already committed time to this job. Cancelling now applies a ${Money.rupees(feePreview)} fee, credited to them — not Rasoi Care.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this booking?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(feeLine),
            if (feePreview != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: () => showCancellationPolicySheet(context, booking: booking),
                  child: const Text('View full cancellation policy'),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep booking')),
          if (feePreview != null)
            FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Cancel booking')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final repo = ref.read(repositoryProvider);
    if (repo is! ApiRepository) return;

    final otpRequest = await repo.requestCancelOtp(booking.id);
    if (!mounted) return;
    if (otpRequest.sent != true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(otpRequest.error ??
              'Could not send a cancellation code — try again.')));
      return;
    }

    final otp = await _promptForOtp();
    if (otp == null || !mounted) return;

    final result = await repo.cancelBooking(booking.id, otp: otp);
    if (!mounted) return;
    if (result.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result.error!)));
      return;
    }
    ref.read(bookingsRefreshProvider.notifier).state++;
    final fee = result.feePaise ?? 0;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(fee == 0
            ? 'Booking cancelled — no fee.'
            : 'Booking cancelled — ${Money.rupees(fee)} fee credited to the technician.')));
  }

  /// Collects the 4-digit code just texted by [_confirmCancel] above.
  /// Returns null if the person backs out.
  Future<String?> _promptForOtp() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Enter the code we texted you'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 4,
          decoration: const InputDecoration(counterText: '', hintText: '0000'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Back')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Confirm')),
        ],
      ),
    );
  }
}

class _BookingCard extends StatelessWidget {
  const _BookingCard({required this.booking, this.completed = false, this.onCancel});
  final Booking booking;
  final bool completed;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final tone = switch (booking.status) {
      BookingStatus.onTheWay => ChipTone.warning,
      BookingStatus.completed => ChipTone.success,
      BookingStatus.cancelled => ChipTone.danger,
      _ => ChipTone.neutral,
    };
    return CareCard(
      onTap: () => booking.status == BookingStatus.onTheWay
          ? context.push('/booking/${booking.id}/track')
          : context.push('/booking/${booking.id}/invoice'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusChip(booking.status.label, tone: tone, height: 24),
              Mono(booking.id.split('-').take(2).join('-'), color: context.care.inkMuted),
            ],
          ),
          const SizedBox(height: 11),
          Text(booking.title,
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            completed
                ? '${booking.whenLabel} · ${Money.rupees(booking.totalPaise)}${booking.stars != null ? ' · ${'★' * booking.stars!}' : ''}'
                : booking.whenLabel,
            style: context.type.bodySmall,
          ),
          if (booking.status == BookingStatus.cancelled &&
              booking.cancellationFeePaise != null) ...[
            const SizedBox(height: 4),
            Text(
                booking.cancellationFeePaise == 0
                    ? 'No cancellation fee'
                    : '${Money.rupees(booking.cancellationFeePaise!)} fee credited to the technician',
                style: context.type.bodySmall),
          ],
          if (onCancel != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onCancel,
                style: TextButton.styleFrom(foregroundColor: context.scheme.error),
                child: const Text('Cancel booking'),
              ),
            ),
          ],
          if (booking.technician != null) ...[
            const Divider(height: 24),
            Row(children: [
              Blob(booking.technician!.initials, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text('${booking.technician!.name} · 14 min away',
                    style: context.type.bodySmall),
              ),
              Text('Track ›',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: context.scheme.primary)),
            ]),
          ],
        ],
      ),
    );
  }
}

// ============================================================ ACCOUNT
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});
  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  @override
  void initState() {
    super.initState();
    // Care Coins are earned server-side (2% cashback once a booking
    // completes) and can also change from a checkout on another device —
    // without this, this screen kept showing whatever balance happened to
    // be cached at cold start until something else incidentally refreshed
    // it, same stale-cache bug already fixed for InvoiceScreen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final repo = ref.read(repositoryProvider);
      if (repo is ApiRepository) {
        repo.refreshCoins();
        repo.refreshBookings();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final profile = ref.watch(userProfileStreamProvider).valueOrNull;
    final isMock = ref.read(authFlowProvider.notifier).isMock;
    final name = (profile?.name.isNotEmpty ?? false)
        ? profile!.name
        : (isMock ? 'Rohan Deshpande' : 'Your name');
    final phone = (profile?.phone.isNotEmpty ?? false)
        ? _formatIndianPhone(profile!.phone)
        : (isMock ? '+91 98220 41537' : '');
    // Bare 10 digits, for seeding _editPhone's dialog — profile.phone (and
    // the mock fallback above) are always the +91E.164 shape.
    final phoneDigits = RegExp(r'(\d{10})$').firstMatch(profile?.phone ?? '')?.group(1) ?? '';
    final address = profile?.address ?? '';
    ref.watch(bookingsRefreshProvider);
    final visitCount = ref.watch(repositoryProvider).bookings(completed: true).length;
    ref.watch(coinsRefreshProvider);
    final coinsBalance = ref.watch(apiRepositoryProvider).coinsBalance;
    final locale = ref.watch(localeProvider);
    final biometricSupported = ref.watch(biometricSupportedProvider).valueOrNull ?? false;
    final biometricOn = ref.watch(biometricEnabledProvider);
    final t = context.l10n;
    final languageLabel = switch (locale.languageCode) {
      'hi' => t.languageHindi,
      'mr' => t.languageMarathi,
      _ => t.languageEnglish,
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(t.accountTitle),
        actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.settings_outlined))],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
          children: [
            CareCard(
              child: Row(children: [
                _ProfileAvatar(name: name, photoUrl: profile?.photoUrl),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        ),
                        if (!isMock) ...[
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: () => _editName(context, ref, name),
                            child: Icon(Icons.edit_outlined,
                                size: 15, color: context.care.inkMuted),
                          ),
                        ],
                      ]),
                      if (phone.isNotEmpty || !isMock) ...[
                        const SizedBox(height: 3),
                        Row(children: [
                          Expanded(
                            child: Text(
                              phone.isNotEmpty ? phone : 'Add a phone number',
                              style: phone.isNotEmpty
                                  ? context.type.bodySmall
                                  : context.type.bodySmall!
                                      .copyWith(color: context.care.inkMuted),
                            ),
                          ),
                          if (!isMock) ...[
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: () => _editPhone(context, ref, phoneDigits, name),
                              child: Icon(Icons.edit_outlined,
                                  size: 14, color: context.care.inkMuted),
                            ),
                          ],
                        ]),
                      ],
                      if (address.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(address, style: context.type.bodySmall, maxLines: 2),
                      ],
                    ],
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _MiniStat(label: t.accountVisits, value: '$visitCount')),
              const SizedBox(width: 10),
              Expanded(
                  child: _MiniStat(
                      label: t.accountCareCoins,
                      value: coinsBalance == null ? '—' : '$coinsBalance')),
            ]),
            SectionHeader(t.accountYourCarePlus),
            CareCard(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(children: [
                _NavRow(icon: Icons.kitchen_outlined, label: t.accountKitchenPassport,
                    onTap: () => context.push('/passport')),
                _NavRow(icon: Icons.event_note, label: t.accountBookingsHistory,
                    onTap: () => context.go('/bookings')),
                _NavRow(icon: Icons.account_balance_wallet_outlined,
                    label: t.accountCareCoins,
                    onTap: () =>
                        _showComingSoon(context, t.accountCareCoins, t.accountCareCoinsBody)),
                _NavRow(icon: Icons.chat_bubble_outline, label: t.accountHelpSupport,
                    onTap: () =>
                        _showComingSoon(context, t.accountHelpSupport, t.accountHelpSupportBody),
                    last: true),
              ]),
            ),
            SectionHeader(t.accountPreferences),
            CareCard(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    const Icon(Icons.dark_mode_outlined, size: 20),
                    const SizedBox(width: 13),
                    Expanded(
                        child: Text(t.accountDarkMode,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700))),
                    Switch(
                      value: mode == ThemeMode.dark,
                      onChanged: (_) => ref.read(themeModeProvider.notifier).toggle(),
                    ),
                  ]),
                ),
                if (biometricSupported)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      const Icon(Icons.fingerprint, size: 20),
                      const SizedBox(width: 13),
                      Expanded(
                          child: Text(t.accountBiometricLogin,
                              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700))),
                      Switch(
                        value: biometricOn,
                        onChanged: (v) => _setBiometric(context, ref, v),
                      ),
                    ]),
                  ),
                _NavRow(icon: Icons.language, label: t.accountLanguage,
                    trailing: '$languageLabel ›',
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const LanguageScreen())),
                    last: true),
              ]),
            ),
            SectionHeader(t.accountLegal),
            CareCard(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(children: [
                _NavRow(
                    icon: Icons.description_outlined,
                    label: t.accountTerms,
                    onTap: () => _openLegalDocument(context, 'terms', t.accountTerms)),
                _NavRow(
                    icon: Icons.privacy_tip_outlined,
                    label: t.accountPrivacy,
                    onTap: () => _openLegalDocument(context, 'privacy', t.accountPrivacy),
                    last: true),
              ]),
            ),
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
                child: Text(t.accountSignOut),
              ),
            ),
            const SizedBox(height: 6),
            Center(child: Text('Rasoi Care 0.1.0 · build 1', style: context.type.bodySmall)),
          ],
        ),
      ),
    );
  }

  Future<void> _setBiometric(BuildContext context, WidgetRef ref, bool value) async {
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

  void _openLegalDocument(BuildContext context, String kind, String title) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LegalDocumentScreen(kind: kind, fallbackTitle: title),
      ));

  void _showComingSoon(BuildContext context, String title, String body) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: context.type.titleMedium),
            const SizedBox(height: 12),
            Text(body, style: context.type.bodyMedium),
          ],
        ),
      ),
    );
  }

  /// The only place someone can set their name after signing in with phone
  /// OTP alone — registration's "about you" step covers everyone else, but
  /// OTP-only sign-in skips straight into the app with no name on file.
  Future<void> _editName(BuildContext context, WidgetRef ref, String current) async {
    final controller = TextEditingController(text: current == 'Your name' ? '' : current);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'e.g. Rohan Deshpande'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || !context.mounted) return;
    final ok = await ref.read(userProfileServiceProvider).updateName(newName);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(ok ? 'Name updated.' : 'Could not save your name — check connection.')));
  }

  /// Lets someone set or change the phone number that actually matters for
  /// cancelling a booking (see request_cancel_otp in app.py) and for the
  /// technician's "Call" action — anyone who signed up with email/Google
  /// alone has never had a phone on file otherwise. Writes to both the
  /// backend (the number those two features read) and Firestore (what
  /// this screen itself displays) so the two can't drift apart.
  Future<void> _editPhone(
      BuildContext context, WidgetRef ref, String currentDigits, String name) async {
    final controller = TextEditingController(text: currentDigits);
    final newPhone = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Phone number'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.phone,
          maxLength: 10,
          decoration:
              const InputDecoration(hintText: '10-digit mobile number', prefixText: '+91 '),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (newPhone == null || !context.mounted) return;
    if (!RegExp(r'^[0-9]{10}$').hasMatch(newPhone)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid 10-digit mobile number.')));
      return;
    }
    final backendOk = await ref.read(apiRepositoryProvider).updatePhone(newPhone, name: name);
    final displayOk = await ref.read(userProfileServiceProvider).updatePhone(newPhone);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(backendOk && displayOk
            ? 'Phone number saved.'
            : 'Could not save your phone number — check connection.')));
  }
}

/// The account photo — a real uploaded photo when there is one, otherwise
/// the initials blob. Tapping it opens the gallery to pick a new one, real
/// image_picker + Firebase Storage upload — there was previously no way to
/// set a profile photo at all, just this fixed initials circle.
class _ProfileAvatar extends ConsumerWidget {
  const _ProfileAvatar({required this.name, required this.photoUrl});
  final String name;
  final String? photoUrl;

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null || !context.mounted) return;
    ref.read(_uploadingPhotoProvider.notifier).state = true;
    final url = await ref.read(userProfileServiceProvider).uploadPhoto(File(picked.path));
    ref.read(_uploadingPhotoProvider.notifier).state = false;
    if (url == null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update your photo — check connection.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uploading = ref.watch(_uploadingPhotoProvider);
    return GestureDetector(
      onTap: uploading ? null : () => _pick(context, ref),
      child: Stack(
        children: [
          if (uploading)
            const SizedBox(
                width: 56,
                height: 56,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          else if (photoUrl != null)
            CircleAvatar(radius: 28, backgroundImage: NetworkImage(photoUrl!))
          else
            Blob(_initialsOf(name),
                size: 56, bg: context.scheme.primary, fg: context.scheme.onPrimary),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.scheme.primary,
                border: Border.all(color: context.scheme.surface, width: 1.5),
              ),
              child: Icon(Icons.camera_alt, size: 11, color: context.scheme.onPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Rohan Deshpande" -> "RD"; falls back to a single "?" for an empty name.
String _initialsOf(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  final first = words.first[0];
  final last = words.length > 1 ? words.last[0] : '';
  return (first + last).toUpperCase();
}

/// "+919822041537" -> "+91 98220 41537". Anything that doesn't match the
/// expected +91-and-10-digits shape is shown as-is rather than mangled.
String _formatIndianPhone(String raw) {
  final match = RegExp(r'^\+91(\d{5})(\d{5})$').firstMatch(raw);
  if (match == null) return raw;
  return '+91 ${match.group(1)} ${match.group(2)}';
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => CareCard(
        radius: Radii.rMd,
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Eyebrow(label),
            const SizedBox(height: 6),
            Text(value,
                style: CareType.mono(context.scheme.onSurface, size: 20, w: FontWeight.w600)),
          ],
        ),
      );
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label, required this.onTap, this.trailing, this.last = false});
  final IconData icon;
  final String label;
  final String? trailing;
  final VoidCallback onTap;
  final bool last;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            border: last
                ? null
                : Border(bottom: BorderSide(color: context.care.hairline)),
          ),
          child: Row(children: [
            Icon(icon, size: 20),
            const SizedBox(width: 13),
            Expanded(
                child: Text(label,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700))),
            Text(trailing ?? '›', style: context.type.bodySmall),
          ]),
        ),
      );
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.labels, required this.index, required this.onChanged});
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: context.scheme.surfaceContainerHigh, borderRadius: Radii.rSm),
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(i),
                  child: AnimatedContainer(
                    duration: Motion.press,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == index ? context.scheme.surface : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: i == index
                          ? Shadows.card(Theme.of(context).brightness == Brightness.dark)
                          : null,
                    ),
                    child: Text(labels[i],
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: i == index
                                ? context.scheme.onSurface
                                : context.care.inkMuted)),
                  ),
                ),
              ),
          ],
        ),
      );
}

