import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/widgets/appliance_illustration.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/models.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/auth_providers.dart';
import '../../state/firestore_providers.dart';
import '../../state/providers.dart';
import '../booking/select_location_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.l10n;
    final addresses = ref.watch(savedAddressesProvider);
    final selectedId = ref.watch(selectedAddressIdProvider);
    final override = ref.watch(homeAddressOverrideProvider);
    final current = override ??
        (addresses.isEmpty
            ? null
            : addresses.firstWhere((a) => a.id == selectedId, orElse: () => addresses.first));
    final profile = ref.watch(userProfileStreamProvider).valueOrNull;
    final isMock = ref.read(authFlowProvider.notifier).isMock;
    final displayName = (profile?.name.isNotEmpty ?? false)
        ? profile!.name
        : (isMock ? 'Rohan Deshpande' : '');
    final repo = ref.watch(repositoryProvider);
    // Rebuild once ApiRepository's real-booking cache lands, same signal
    // BookingsScreen watches — otherwise this stays empty until some other
    // screen happens to trigger a rebuild first.
    ref.watch(bookingsRefreshProvider);
    final completedBookings = repo.bookings(completed: true);
    final lastCompleted = completedBookings.isEmpty ? null : completedBookings.first;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // --- location + notifications ---
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _locationSheet(context, ref),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Eyebrow(t.homeServing),
                          const SizedBox(height: 3),
                          Row(children: [
                            Flexible(
                              child: Text(current?.line ?? t.homeAddAddress,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.type.titleMedium),
                            ),
                            const SizedBox(width: 5),
                            const Icon(Icons.expand_more, size: 16),
                          ]),
                        ],
                      ),
                    ),
                  ),
                  _RoundBtn(
                      icon: Icons.notifications_none,
                      onTap: () => _notificationsComingSoon(context)),
                  const SizedBox(width: 9),
                  Pressable(
                    onTap: () => context.go('/account'),
                    child: profile?.photoUrl != null
                        ? CircleAvatar(radius: 19, backgroundImage: NetworkImage(profile!.photoUrl!))
                        : Blob(_initialsOf(displayName), size: 38),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 120),
                children: [
                  // --- search ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: CareCard(
                      onTap: () => context.go('/services'),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      child: Row(children: [
                        Icon(Icons.search, color: context.care.inkFaint, size: 20),
                        const SizedBox(width: 10),
                        Text(t.homeSearchHint,
                            style: context.type.bodyMedium),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // --- customer kitchen passport ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: _KitchenPassportBanner(
                      onTap: () => context.go('/passport'),
                    ),
                  ),
                  // --- categories ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SectionHeader(t.homeWhatNeedsCare,
                        actionLabel: t.homeAll, onAction: () => context.go('/services')),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: GridView.count(
                      crossAxisCount: 4,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.82,
                      children: [
                        for (final a in Appliance.values)
                          _CategoryTile(
                              appliance: a,
                              onTap: () => _startBooking(context, ref, a)),
                      ],
                    ),
                  ),
                  // --- repeat --- real, most recent completed booking only;
                  // hidden entirely rather than showing a fabricated
                  // "Elica 90cm, due in 8 days" reminder when there's
                  // nothing real to rebook yet.
                  if (lastCompleted != null) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: SectionHeader(t.homeBookItAgain,
                          actionLabel: t.homeHistory,
                          onAction: () => context.go('/bookings')),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: CareCard(
                        onTap: () => _startBooking(context, ref, lastCompleted.appliance),
                        child: Row(children: [
                          Blob('◍',
                              glyph: true,
                              bg: context.scheme.secondaryContainer,
                              fg: context.scheme.secondary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(lastCompleted.title,
                                    style: const TextStyle(
                                        fontSize: 13.5, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 3),
                                Text(t.homeLastDone(lastCompleted.whenLabel),
                                    style: context.type.bodySmall),
                              ],
                            ),
                          ),
                          StatusChip(t.homeRebook, height: 30),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Service detail reads the appliance from the route and starts the draft there.
  void _startBooking(BuildContext context, WidgetRef ref, Appliance a) =>
      context.push('/services/${a.name}');

  /// The bell used to show a hardcoded "3" badge and do nothing when
  /// tapped — there's no real notifications system behind it (no push
  /// setup, no backend feed), so rather than keep faking a count, this
  /// says so plainly, same as the Account screen's other not-built-yet
  /// features (Wallet and Care Coins, Help and support).
  void _notificationsComingSoon(BuildContext context) {
    final t = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.notificationsTitle, style: context.type.titleMedium),
            const SizedBox(height: 12),
            Text(t.notificationsBody, style: context.type.bodyMedium),
          ],
        ),
      ),
    );
  }

  Future<void> _locationSheet(BuildContext context, WidgetRef ref) async {
    final currentId = ref.read(selectedAddressIdProvider);
    final picked = await Navigator.of(context).push<SavedAddress>(
      MaterialPageRoute(builder: (_) => SelectLocationScreen(currentId: currentId)),
    );
    if (picked == null) return;
    ref.read(homeAddressOverrideProvider.notifier).state = picked;
    ref.read(selectedAddressIdProvider.notifier).state = picked.id;
  }
}

/// "Rohan Deshpande" -> "RD"; falls back to "?" for an empty/unknown name —
/// this used to always be the hardcoded literal "RD" no matter who was
/// actually signed in.
String _initialsOf(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  final first = words.first[0];
  final last = words.length > 1 ? words.last[0] : '';
  return (first + last).toUpperCase();
}

/// Promotes the customer's Kitchen Passport from the home screen.
class _KitchenPassportBanner extends StatelessWidget {
  const _KitchenPassportBanner({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        scale: 0.985,
        child: Container(
          decoration: BoxDecoration(
              color: context.scheme.primary, borderRadius: Radii.rLg),
          padding: const EdgeInsets.fromLTRB(20, 20, 18, 20),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Eyebrow(context.l10n.homePassportEyebrow,
                        color: context.scheme.secondary),
                    const SizedBox(height: 8),
                    Text(context.l10n.passportTitle,
                        style: CareType.display(context.scheme.onPrimary, size: 27)),
                    const SizedBox(height: 8),
                    Text(context.l10n.homePassportDescription,
                        style: context.type.bodyMedium?.copyWith(
                          color: context.scheme.onPrimary.withValues(alpha: 0.82),
                        )),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.arrow_forward_rounded,
                  color: context.scheme.onPrimary, size: 24),
            ],
          ),
        ),
      );
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.appliance, required this.onTap});
  final Appliance appliance;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        scale: 0.94,
        child: Container(
          decoration: BoxDecoration(
            color: context.scheme.surface,
            borderRadius: Radii.rMd,
            border: Border.all(color: context.care.hairline),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.scheme.primaryContainer,
                ),
                child: ApplianceIllustration(
                    appliance: appliance, size: 24, color: context.scheme.primary),
              ),
              const SizedBox(height: 9),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(_short(context, appliance),
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600, height: 1.2)),
                ),
              ),
            ],
          ),
        ),
      );

  String _short(BuildContext context, Appliance a) {
    final t = context.l10n;
    return switch (a) {
      Appliance.chimney => t.applianceChimney,
      Appliance.hob => t.applianceHob,
      Appliance.cooktop => t.applianceCooktop,
      Appliance.dishwasher => t.applianceDishwasher,
      Appliance.microwave => t.applianceMicrowave,
      Appliance.refrigerator => t.applianceFridge,
      Appliance.otg => t.applianceOtg,
      Appliance.purifier => t.appliancePurifier,
    };
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.onTap});
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
          child: Icon(icon, size: 20),
        ),
      );
}
