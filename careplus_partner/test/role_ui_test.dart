import 'package:care_plus_partner/app/router.dart';
import 'package:care_plus_partner/core/theme/care_plus_theme.dart';
import 'package:care_plus_partner/data/operations/api_repository.dart';
import 'package:care_plus_partner/data/operations/models.dart';
import 'package:care_plus_partner/features/auth/auth_screens.dart';
import 'package:care_plus_partner/features/auth/role_screen.dart';
import 'package:care_plus_partner/features/operations/reports_screen.dart';
import 'package:care_plus_partner/l10n/app_localizations.dart';
import 'package:care_plus_partner/state/auth_providers.dart';
import 'package:care_plus_partner/state/operations_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Repo extends ChangeNotifier implements OperationsApiRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  bool fetchFailed(String key) => false;
  @override
  ReportBundle? report(ReportRange range, {String? district}) => ReportBundle(
        range: range,
        revenueTrend: const [],
        ratingTrend: const [],
        categoryRevenue: const [],
        technicianLeaderboard: const [],
        complaintsByStatus: const [],
        completedJobs: 0,
      );
}

Widget _app(Widget home, {List<Override> overrides = const [], GoRouter? router}) {
  final base = ProviderScope(
    overrides: overrides,
    child: router != null
        ? MaterialApp.router(
            theme: CarePlusTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router)
        : MaterialApp(
            theme: CarePlusTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: home),
  );
  return base;
}

void _bigView(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 3000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
}

void main() {
  group('route guard', () {
    test('operations need a resolved role; technician routes are closed to staff/owner', () {
      expect(partnerRedirect('/ops/overview', null), '/login');
      expect(partnerRedirect('/ops/overview', AdminRole.staff), isNull);
      expect(partnerRedirect('/tech/jobs', AdminRole.staff), '/ops/overview');
      expect(partnerRedirect('/tech/jobs', AdminRole.owner), '/ops/overview');
      expect(partnerRedirect('/tech/jobs', null), isNull);
    });

    test('Staff & Access is owner-only', () {
      expect(partnerRedirect('/ops/staff', AdminRole.staff), '/ops/overview');
      expect(partnerRedirect('/ops/staff', null), '/login');
      expect(partnerRedirect('/ops/staff', AdminRole.owner), isNull);
    });
  });

  group('owner UI isolation', () {
    Future<void> pumpReports(WidgetTester t, AdminRole role) async {
      _bigView(t);
      await t.pumpWidget(_app(const ReportsScreen(), overrides: [
        operationsRepositoryProvider.overrideWith((ref) => _Repo()),
        currentRoleProvider.overrideWithValue(role),
      ]));
      await t.pump();
    }

    testWidgets('staff Reports show no owner labels, P&L or revenue', (t) async {
      await pumpReports(t, AdminRole.staff);
      expect(find.textContaining('Owner'), findsNothing);
      expect(find.textContaining('Financial'), findsNothing);
      expect(find.textContaining('Revenue'), findsNothing);
      expect(find.textContaining('Payouts'), findsNothing);
    });

    testWidgets('owner Reports do show the P&L section', (t) async {
      await pumpReports(t, AdminRole.owner);
      expect(find.textContaining('Financial P&L'), findsOneWidget);
    });
  });

  group('role picker', () {
    testWidgets('offers Technician, Staff and Owner; picking one records it and moves on', (t) async {
      _bigView(t);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final router = GoRouter(initialLocation: '/login', routes: [
        GoRoute(
          path: '/login',
          builder: (_, __) => const RoleSelectScreen(),
          routes: [GoRoute(path: 'phone', builder: (_, __) => const Text('PHONE-STEP'))],
        ),
      ]);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: CarePlusTheme.light(),
          routerConfig: router,
        ),
      ));
      await t.pump();
      expect(find.text('Technician'), findsOneWidget);
      expect(find.text('Staff'), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
      expect(container.read(authFlowProvider).signInRole, isNull);

      await t.tap(find.byKey(const Key('role-owner')));
      await t.pumpAndSettle();
      expect(container.read(authFlowProvider).signInRole, SignInRole.owner);
      expect(container.read(authFlowProvider).staffRole, isNull); // picking grants nothing
      expect(find.text('PHONE-STEP'), findsOneWidget);
    });
  });

  group('sign-in method per role', () {
    Future<ProviderContainer> pumpPhone(WidgetTester t, SignInRole role) async {
      _bigView(t);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authFlowProvider.notifier).selectRole(role);
      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: CarePlusTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const PhoneScreen(),
        ),
      ));
      await t.pump();
      return container;
    }

    testWidgets('Owner sees Google only — no phone entry', (t) async {
      await pumpPhone(t, SignInRole.owner);
      expect(find.textContaining('+91'), findsNothing);
      expect(find.byType(OutlinedButton), findsOneWidget); // Google
      expect(find.byType(TextField), findsNothing);
    });

    for (final role in [SignInRole.technician, SignInRole.staff]) {
      testWidgets('${role.name} can use phone OTP or Google', (t) async {
        await pumpPhone(t, role);
        expect(find.textContaining('+91'), findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        expect(find.byType(OutlinedButton), findsOneWidget);
      });
    }
  });
}
