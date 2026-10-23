import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth_screens.dart';
import '../features/auth/partner_email_auth_screen.dart';
import '../features/auth/biometric_screens.dart';
import '../features/apply/tech_apply_screen.dart';
import '../features/apply/tech_financial_screen.dart';
import '../features/apply/tech_pending_screen.dart';
import '../features/apply/tech_profile_screen.dart';
import '../features/apply/tech_more_screen.dart';
import '../features/earnings/tech_earnings_screen.dart';
import '../features/jobs/tech_jobs_screen.dart';
import '../features/jobs/tech_shifts_screen.dart';
import '../features/jobs/tech_job_screen.dart';
import '../features/jobs/tech_close_screen.dart';
import '../features/jobs/airflow_check_screen.dart';
import '../data/api/passport_api.dart';
import '../features/passport/ai_inspection_screen.dart';
import '../features/passport/inspection_screen.dart';
import '../features/passport/kitchen_passport_screen.dart';
import '../features/passport/register_appliance_screen.dart';
import '../features/support/coming_soon_screen.dart';
import '../features/support/language_screen.dart';
import '../features/support/tech_help_screen.dart';
import '../features/operations/overview_screen.dart';
import '../features/operations/reports_screen.dart';
import '../features/operations/bookings_screen.dart';
import '../features/operations/team_screen.dart';
import '../features/operations/stock_screen.dart';
import '../features/operations/account_screen.dart';
import '../features/operations/staff_access_screen.dart';
import '../features/operations/operations_shell.dart';
import '../data/operations/models.dart';
import '../features/auth/role_screen.dart';
import '../state/auth_providers.dart' show latestKnownStaffRole;
import '../l10n/l10n_extensions.dart';
import 'partner_shell.dart';

final _rootKey = GlobalKey<NavigatorState>();

/// Client-side route guard (the backend enforces the real authorization):
/// operations routes need a resolved staff/owner role, technician routes are
/// closed to staff/owner sessions, and Staff & Access is owner-only.
String? partnerRedirect(String location, AdminRole? role) {
  if (location.startsWith('/ops') && role == null) return '/login';
  if (location.startsWith('/tech') && role != null) return '/ops/overview';
  if (location == '/ops/staff' && role != AdminRole.owner) return '/ops/overview';
  return null;
}

final router = GoRouter(
  navigatorKey: _rootKey,
  initialLocation: '/splash',
  redirect: (context, state) => partnerRedirect(state.matchedLocation, latestKnownStaffRole),
  routes: [
    GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
    GoRoute(
      path: '/login',
      builder: (_, _) => const RoleSelectScreen(),
      routes: [
        GoRoute(
          path: 'phone',
          builder: (_, _) => const PhoneScreen(),
          routes: [GoRoute(path: 'otp', builder: (_, _) => const OtpScreen())],
        ),
        GoRoute(
          path: 'email',
          builder: (_, _) => const PartnerEmailAuthScreen(),
        ),
        GoRoute(
          path: 'email',
          builder: (_, _) => const PartnerEmailAuthScreen(),
        ),
      ],
    ),
    GoRoute(
      path: '/biometric-enroll',
      builder: (_, __) => const BiometricEnrollScreen(),
    ),
    GoRoute(
      path: '/lock',
      builder: (_, __) => const BiometricLockScreen(),
    ),
    GoRoute(
      path: '/ops/account',
      parentNavigatorKey: _rootKey,
      builder: (_, __) => const AccountScreen(),
    ),
    GoRoute(
      path: '/ops/staff',
      parentNavigatorKey: _rootKey,
      builder: (_, __) => const StaffAccessScreen(),
    ),

    GoRoute(
      path: '/tech/apply',
      parentNavigatorKey: _rootKey,
      builder: (_, s) =>
          TechApplyScreen(existing: s.extra as Map<String, dynamic>?),
    ),
    GoRoute(
      path: '/tech/pending',
      parentNavigatorKey: _rootKey,
      builder: (_, __) => const TechPendingScreen(),
    ),
    GoRoute(
      path: '/tech/financial',
      parentNavigatorKey: _rootKey,
      builder: (_, __) => const TechFinancialScreen(),
    ),
    GoRoute(
      path: '/tech/help',
      parentNavigatorKey: _rootKey,
      builder: (_, __) => const TechHelpScreen(),
    ),
    GoRoute(
      path: '/tech/soon',
      parentNavigatorKey: _rootKey,
      builder: (context, s) =>
          ComingSoonScreen(title: s.extra as String? ?? context.l10n.moreWork),
    ),
    GoRoute(
      path: '/tech/language',
      parentNavigatorKey: _rootKey,
      builder: (_, __) => const LanguageScreen(),
    ),
    GoRoute(
      path: '/tech/job/:id',
      parentNavigatorKey: _rootKey,
      builder: (_, s) => TechJobScreen(jobId: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/tech/job/:id/close',
      parentNavigatorKey: _rootKey,
      builder: (_, s) {
        final extra = s.extra as (int?, int?)?;
        return TechCloseScreen(
          jobId: s.pathParameters['id']!,
          suctionBefore: extra?.$1,
          suctionAfter: extra?.$2,
        );
      },
    ),
    GoRoute(
      path: '/tech/job/:id/kitchen',
      parentNavigatorKey: _rootKey,
      builder: (_, s) => KitchenPassportScreen(jobId: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/tech/job/:id/kitchen/register',
      parentNavigatorKey: _rootKey,
      builder: (_, s) => RegisterApplianceScreen(jobId: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/tech/job/:id/kitchen/appliance/:aid/inspection',
      parentNavigatorKey: _rootKey,
      builder: (_, s) {
        final appliance = s.extra as KitchenAppliance?;
        // Reached only from a Kitchen Passport card, which passes the
        // appliance; a bare deep link has nothing to show, so go back.
        if (appliance == null) return KitchenPassportScreen(jobId: s.pathParameters['id']!);
        return InspectionScreen(jobId: s.pathParameters['id']!, appliance: appliance);
      },
    ),
    GoRoute(
      path: '/tech/job/:id/kitchen/appliance/:aid/ai-inspection',
      parentNavigatorKey: _rootKey,
      builder: (_, s) {
        final appliance = s.extra as KitchenAppliance?;
        if (appliance == null) return KitchenPassportScreen(jobId: s.pathParameters['id']!);
        return AiInspectionScreen(jobId: s.pathParameters['id']!, appliance: appliance);
      },
    ),
    GoRoute(
      path: '/tech/job/:id/airflow',
      parentNavigatorKey: _rootKey,
      builder: (_, s) {
        final extra = s.extra as (AirflowStage, String, String, AirflowReading)?;
        return AirflowCheckScreen(
          jobId: s.pathParameters['id']!,
          stage: extra?.$1 ?? AirflowStage.before,
          customerName: extra?.$2 ?? 'Customer',
          customerArea: extra?.$3 ?? '',
          initialReading: extra?.$4 ?? const AirflowReading(),
        );
      },
    ),

    // Home / Money / Shifts / Profile / More — the five persistent tabs,
    // matching the bottom-nav shape of Swiggy Partner / Urban Company
    // Partner instead of the old tap-a-card-to-push-a-screen navigation.
    StatefulShellRoute.indexedStack(
      parentNavigatorKey: _rootKey,
      builder: (_, __, shell) => PartnerShell(navigationShell: shell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/tech/jobs',
              builder: (_, __) => const TechJobsScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/tech/earnings',
              builder: (_, __) => const TechEarningsScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/tech/shifts',
              builder: (_, __) => const TechShiftsScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/tech/profile',
              builder: (_, __) => const TechProfileScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/tech/more',
              builder: (_, __) => const TechMoreScreen(),
            ),
          ],
        ),
      ],
    ),
    StatefulShellRoute.indexedStack(
      parentNavigatorKey: _rootKey,
      builder: (_, __, shell) => OperationsShell(navigationShell: shell),
      branches: [
        StatefulShellBranch(
          routes: [GoRoute(path: '/ops/overview', builder: (_, __) => const OverviewScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/ops/reports', builder: (_, __) => const ReportsScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/ops/bookings', builder: (_, __) => const BookingsScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/ops/team', builder: (_, __) => const TeamScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/ops/stock', builder: (_, __) => const StockScreen())],
        ),
      ],
    ),
  ],
);
