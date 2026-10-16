import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/local/biometric_service.dart';
import '../data/models.dart';
import '../state/auth_providers.dart';
import 'customer_shell.dart';
import '../features/auth/auth_screens.dart';
import '../features/auth/biometric_screens.dart';
import '../features/home/home_screen.dart';
import '../features/catalog/catalog_screens.dart';
import '../features/booking/booking_screens.dart';
import '../features/booking/address_picker_screen.dart';
import '../features/tracking/tracking_screen.dart';
import '../features/invoice/invoice_rate_screens.dart';
import '../features/account/account_screens.dart';
import '../features/passport/kitchen_passport_screen.dart';
import '../features/shop/shop_screen.dart';

final _rootKey = GlobalKey<NavigatorState>();
final _shellKey = GlobalKey<NavigatorState>();

/// Routes reachable without being signed in and past the lock (if any) —
/// the auth/onboarding flow itself, plus the lock screen, which obviously
/// can't require itself to already be unlocked.
const _publicPaths = {
  '/splash',
  '/onboarding',
  '/login',
  '/login/otp',
  '/login/email',
  '/register',
  '/biometric-enroll',
  '/lock',
};

/// SplashScreen only ever ran this check once, at cold start — any other
/// way to reach an in-app route (a resumed deep link, a future one this
/// app doesn't register today, or simply this router regaining control
/// after a hot restart mid-session) skipped both the sign-in and the
/// biometric-lock check entirely. This mirrors that same check on every
/// navigation instead.
Future<String?> _authRedirect(BuildContext context, GoRouterState state) async {
  final path = state.matchedLocation;
  if (_publicPaths.contains(path)) return null;
  final signedIn = Firebase.apps.isEmpty || FirebaseAuth.instance.currentUser != null;
  if (!signedIn) return '/onboarding';
  if (!biometricUnlockedThisSession && await BiometricService().isEnabled()) {
    return '/lock';
  }
  return null;
}

Appliance _appliance(String? name) => Appliance.values.firstWhere(
      (a) => a.name == name,
      orElse: () => Appliance.chimney,
    );

/// A slide-up transition used for the booking flow, so it reads as a stacked
/// task rather than a tab switch.
CustomTransitionPage<void> _slideUp(Widget child) => CustomTransitionPage(
      child: child,
      transitionDuration: const Duration(milliseconds: 340),
      transitionsBuilder: (_, anim, __, c) => SlideTransition(
        position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(
          CurvedAnimation(parent: anim, curve: const Cubic(.22, 1, .36, 1)),
        ),
        child: FadeTransition(opacity: anim, child: c),
      ),
    );

final router = GoRouter(
  navigatorKey: _rootKey,
  initialLocation: '/splash',
  redirect: _authRedirect,
  routes: [
    GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
    GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
    GoRoute(
      path: '/login',
      builder: (_, __) => const PhoneScreen(),
      routes: [
        GoRoute(path: 'otp', builder: (_, __) => const OtpScreen()),
        GoRoute(path: 'email', builder: (_, __) => const EmailAuthScreen()),
      ],
    ),
    GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
    GoRoute(path: '/biometric-enroll', builder: (_, __) => const BiometricEnrollScreen()),
    GoRoute(path: '/lock', builder: (_, __) => const BiometricLockScreen()),

    // Service detail sits above the shell so it can push the booking flow.
    GoRoute(
      path: '/services/:appliance',
      parentNavigatorKey: _rootKey,
      builder: (_, s) =>
          ServiceDetailScreen(appliance: _appliance(s.pathParameters['appliance'])),
    ),

    // Booking flow — root-level, slide-up, shares the BookingDraft notifier.
    GoRoute(
        path: '/book/issue',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, __) => _slideUp(const IssueScreen())),
    GoRoute(
        path: '/book/slot',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, __) => _slideUp(const SlotScreen())),
    GoRoute(
        path: '/book/address',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, __) => _slideUp(const AddressScreen())),
    GoRoute(
        path: '/book/address/pick',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, __) => _slideUp(const AddressPickerScreen())),
    GoRoute(
        path: '/book/payment',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, __) => _slideUp(const PaymentScreen())),

    // Post-booking, keyed by booking id.
    GoRoute(
        path: '/booking/:id/confirmed',
        parentNavigatorKey: _rootKey,
        builder: (_, s) => ConfirmedScreen(
            bookingId: s.pathParameters['id']!,
            totalBooked: s.extra as int? ?? 1)),
    GoRoute(
        path: '/booking/:id/track',
        parentNavigatorKey: _rootKey,
        builder: (_, s) => TrackingScreen(bookingId: s.pathParameters['id']!)),
    GoRoute(
        path: '/booking/:id/invoice',
        parentNavigatorKey: _rootKey,
        builder: (_, s) => InvoiceScreen(bookingId: s.pathParameters['id']!)),
    GoRoute(
        path: '/booking/:id/rate',
        parentNavigatorKey: _rootKey,
        builder: (_, s) => RateScreen(bookingId: s.pathParameters['id']!)),

    GoRoute(
        path: '/shop',
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const ShopScreen()),

    GoRoute(
        path: '/passport',
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const KitchenPassportScreen()),

    // The four-tab customer shell.
    StatefulShellRoute.indexedStack(
      parentNavigatorKey: _rootKey,
      builder: (_, __, shell) => CustomerShell(navigationShell: shell),
      branches: [
        StatefulShellBranch(
          navigatorKey: _shellKey,
          routes: [GoRoute(path: '/', builder: (_, __) => const HomeScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/services', builder: (_, __) => const CatalogScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/bookings', builder: (_, __) => const BookingsScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/account', builder: (_, __) => const AccountScreen())],
        ),
      ],
    ),
  ],
);
