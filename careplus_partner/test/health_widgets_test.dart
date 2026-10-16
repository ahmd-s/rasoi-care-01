import 'package:care_plus_partner/core/theme/care_plus_theme.dart';
import 'package:care_plus_partner/core/widgets/care_widgets.dart';
import 'package:care_plus_partner/data/api/passport_api.dart';
import 'package:care_plus_partner/features/passport/health_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _disclaimer = 'Operational guidance, not a certification or a diagnosis of hidden faults.';

HealthAssessment _assessment({
  int? score = 78,
  String? status = 'attention',
  String? label = 'Attention',
  String? message,
  bool safety = false,
  String coverage = '8 of 8 checks tested',
  int? ai,
  int? combined,
}) =>
    HealthAssessment(
      score: score,
      status: status,
      statusLabel: label,
      testedChecks: 8,
      totalChecks: 8,
      coverageLabel: coverage,
      safetyFlagged: safety,
      safetyWarning: safety ? 'Safety item flagged' : null,
      safetyItems: safety ? const ['Safety'] : const [],
      flaggedLabels: const [],
      message: message,
      explanation: const [
        'Technician assessment only. Vision AI inspection is not available yet.',
        'Based on 8 of 8 checks.',
        _disclaimer,
      ],
      basisLabel: 'Technician assessment only',
      disclaimer: _disclaimer,
      aiScore: ai,
      combinedScore: combined,
    );

Future<void> _show(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(360, 740);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: CarePlusTheme.light(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows score, status, coverage, basis label and disclaimer', (tester) async {
    await _show(tester, ApplianceHealthPanel(_assessment()));
    expect(find.text('78'), findsOneWidget);
    expect(find.text('Attention'), findsOneWidget);
    expect(find.text('8 of 8 checks tested'), findsOneWidget);
    expect(find.text('TECHNICIAN ASSESSMENT ONLY'), findsOneWidget);
    expect(find.text(_disclaimer), findsOneWidget);
    expect(find.byKey(const ValueKey('safety-banner')), findsNothing);
    // No AI or combined score is ever presented.
    expect(find.textContaining('AI score'), findsNothing);
    expect(find.textContaining('Combined'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without enough checks there is no number, only the explanation', (tester) async {
    await _show(
      tester,
      ApplianceHealthPanel(_assessment(
        score: null,
        status: null,
        label: null,
        message: 'Not enough checks to score.',
        coverage: '5 of 8 checks tested',
      )),
    );
    expect(find.byKey(const ValueKey('health-score')), findsNothing);
    expect(find.text('Not enough checks to score.'), findsOneWidget);
    expect(find.text('5 of 8 checks tested'), findsOneWidget);
  });

  testWidgets('a safety flag shows a clear warning next to the unchanged score', (tester) async {
    await _show(
      tester,
      ApplianceHealthPanel(_assessment(score: 93, status: 'attention', label: 'Attention', safety: true)),
    );
    expect(find.text('93'), findsOneWidget); // the calculated number is not altered
    expect(find.text('Attention'), findsOneWidget); // status held below Healthy
    expect(find.text('Safety item flagged: Safety'), findsOneWidget);
  });

  testWidgets('kitchen panel labels assessed versus registered appliances', (tester) async {
    const kitchen = KitchenHealth(
      score: 85,
      status: 'healthy',
      statusLabel: 'Healthy',
      assessedCount: 2,
      registeredCount: 5,
      coverageLabel: '2 of 5 appliances assessed',
      safetyFlagged: false,
      safetyWarning: null,
      message: null,
      explanation: [],
      basisLabel: 'Technician assessment only',
      disclaimer: _disclaimer,
      appliances: [],
    );
    await _show(tester, const KitchenHealthPanel(kitchen));
    expect(find.text('85'), findsOneWidget);
    expect(find.text('Healthy'), findsOneWidget);
    expect(find.text('2 of 5 appliances assessed'), findsOneWidget);
    expect(find.textContaining('TECHNICIAN ASSESSMENT ONLY'), findsOneWidget);
    expect(find.text(_disclaimer), findsOneWidget);
  });

  testWidgets('kitchen with nothing assessed shows no score', (tester) async {
    const kitchen = KitchenHealth(
      score: null,
      status: null,
      statusLabel: null,
      assessedCount: 0,
      registeredCount: 2,
      coverageLabel: '0 of 2 appliances assessed',
      safetyFlagged: false,
      safetyWarning: null,
      message: 'No appliance has enough checks to score yet.',
      explanation: [],
      basisLabel: 'Technician assessment only',
      disclaimer: _disclaimer,
      appliances: [],
    );
    await _show(tester, const KitchenHealthPanel(kitchen));
    expect(find.byKey(const ValueKey('health-score')), findsNothing);
    expect(find.text('No appliance has enough checks to score yet.'), findsOneWidget);
    expect(find.text('0 of 2 appliances assessed'), findsOneWidget);
  });

  test('tones follow the status bands', () {
    expect(toneForStatus('healthy'), ChipTone.success);
    expect(toneForStatus('attention'), ChipTone.warning);
    expect(toneForStatus('priority'), ChipTone.warning);
    expect(toneForStatus('critical'), ChipTone.danger);
    expect(toneForStatus(null), ChipTone.neutral);
  });

  testWidgets('shows the accepted AI score and combined score only when present', (tester) async {
    await _show(tester, ApplianceHealthPanel(_assessment()));
    expect(find.byKey(const ValueKey('health-ai-line')), findsNothing);
    await _show(tester, ApplianceHealthPanel(_assessment(ai: 55, combined: 83)));
    expect(find.text('Combined score 83 = 70% your checks + 30% accepted AI visual score 55'),
        findsOneWidget);
    await _show(tester, ApplianceHealthPanel(_assessment(ai: 55)));
    expect(find.textContaining('not counted until enough checks are tested'), findsOneWidget);
    // The technician's own number is still the headline score.
    expect(find.byKey(const ValueKey('health-score')), findsOneWidget);
  });
}
