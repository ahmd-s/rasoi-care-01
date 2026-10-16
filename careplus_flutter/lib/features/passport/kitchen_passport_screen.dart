import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/care_plus_theme.dart';
import '../../core/widgets/care_widgets.dart';
import '../../data/api/passport_client.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/passport_providers.dart';

String _statusLabel(AppLocalizations t, String status) => switch (status) {
      'healthy' => t.passportStatusHealthy,
      'attention' => t.passportStatusAttention,
      'priority' => t.passportStatusPriority,
      _ => t.passportStatusCritical,
    };

ChipTone _tone(String? status) => switch (status) {
      'healthy' => ChipTone.success,
      'attention' || 'priority' => ChipTone.warning,
      'critical' => ChipTone.danger,
      _ => ChipTone.neutral,
    };

String _categoryLabel(AppLocalizations t, String category) =>
    switch (category) {
      'chimney' => t.applianceChimney,
      'hob' => t.applianceHob,
      'microwave' => t.applianceMicrowave,
      'oven' => t.applianceOtg,
      'dishwasher' => t.applianceDishwasher,
      'refrigerator' => t.applianceFridge,
      'ro_purifier' => t.appliancePurifier,
      _ => category,
    };

String _guidance(AppLocalizations t, String urgency) => switch (urgency) {
      'urgent' => t.passportGuidanceUrgent,
      'priority' => t.passportGuidancePriority,
      'soon' => t.passportGuidanceSoon,
      _ => t.passportGuidanceRoutine,
    };

String _timing(AppLocalizations t, int days) =>
    days == 0 ? t.passportAsap : t.passportWithinDays(days);

String _name(AppLocalizations t, PassportAppliance a) {
  final detail = [a.brand, if (a.model.isNotEmpty) a.model]
      .where((s) => s.isNotEmpty)
      .join(' ');
  final category = _categoryLabel(t, a.category);
  return detail.isEmpty ? category : '$category · $detail';
}

/// The customer's own Kitchen Passport: overall and per-appliance health,
/// what needs attention, the next recommended service and the visit history —
/// all read from the server, none of it computed or invented here.
class KitchenPassportScreen extends ConsumerWidget {
  const KitchenPassportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.l10n;
    final async = ref.watch(kitchenPassportProvider);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
            onPressed: () =>
                context.canPop() ? context.pop() : context.go('/account')),
        title: Text(t.passportTitle),
      ),
      body: SafeArea(
        top: false,
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            padding: const EdgeInsets.all(Space.screenH),
            children: [
              EmptyState(
                glyph: '⚠',
                title: t.passportTitle,
                body: e is PassportFailure &&
                        e.kind == PassportFailureKind.signedOut
                    ? t.passportSignedOut
                    : t.passportLoadError,
                action: FilledButton(
                  onPressed: () => ref.invalidate(kitchenPassportProvider),
                  child: Text(t.passportRetry),
                ),
              ),
            ],
          ),
          data: (p) => p.appliances.isEmpty
              ? ListView(
                  padding: const EdgeInsets.all(Space.screenH),
                  children: [
                    EmptyState(
                        glyph: '▤',
                        title: t.passportEmptyTitle,
                        body: t.passportEmptyBody)
                  ],
                )
              : RefreshIndicator(
                  onRefresh: () async =>
                      ref.refresh(kitchenPassportProvider.future),
                  child: _Body(p),
                ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.p);
  final KitchenPassport p;

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final byId = {for (final a in p.appliances) a.id: a};
    final attention = [
      for (final id in p.needsAttention)
        if (byId[id] != null) byId[id]!
    ];
    final next = p.nextService;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Space.screenH, 16, Space.screenH, 32),
      children: [
        _KitchenCard(p),
        if (next != null) ...[
          const SizedBox(height: 12),
          CareCard(
            key: const ValueKey('passport-next-service'),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Eyebrow(t.passportNextService),
              const SizedBox(height: 8),
              Text(_guidance(t, next.urgency), style: context.type.titleSmall),
              const SizedBox(height: 4),
              Text(_timing(t, next.estimatedDays),
                  style: context.type.bodyMedium),
              if (byId[next.applianceId] != null) ...[
                const SizedBox(height: 4),
                Text(t.passportForAppliance(_name(t, byId[next.applianceId]!)),
                    style: context.type.bodySmall),
              ],
            ]),
          ),
        ],
        if (attention.isNotEmpty) ...[
          SectionHeader(t.passportNeedsAttention),
          for (final a in attention)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: CareCard(
                key: ValueKey('passport-attention-${a.id}'),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(_name(t, a),
                                style: context.type.titleSmall)),
                        if (a.status != null)
                          StatusChip(_statusLabel(t, a.status!),
                              tone: _tone(a.status), height: 26),
                      ]),
                      if (a.attentionItems.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                            t.passportFlaggedItems(a.attentionItems.join(', ')),
                            style: context.type.bodySmall),
                      ],
                      if (a.safetyFlagged) ...[
                        const SizedBox(height: 6),
                        Text(t.passportSafetyFlag,
                            style: TextStyle(
                                color: context.scheme.error,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600)),
                      ],
                    ]),
              ),
            ),
        ],
        SectionHeader(t.passportAppliances),
        for (final a in p.appliances) ...[
          _ApplianceCard(a),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 6),
        Text(t.passportDisclaimer,
            key: const ValueKey('passport-disclaimer'),
            style:
                context.type.bodySmall!.copyWith(fontStyle: FontStyle.italic)),
      ],
    );
  }
}

class _KitchenCard extends StatelessWidget {
  const _KitchenCard(this.p);
  final KitchenPassport p;

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final score = p.score;
    return CareCard(
      key: const ValueKey('passport-kitchen-card'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Eyebrow(t.passportKitchenScore),
        const SizedBox(height: 10),
        if (score == null) ...[
          Text(t.passportNoScoreTitle,
              key: const ValueKey('passport-kitchen-noscore'),
              style: context.type.titleMedium),
          const SizedBox(height: 4),
          Text(t.passportNoScoreBody, style: context.type.bodyMedium),
        ] else
          Semantics(
            label: t.passportScoreOutOf(
                score, p.status == null ? '' : _statusLabel(t, p.status!)),
            excludeSemantics: true,
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Text('$score',
                  key: const ValueKey('passport-kitchen-score'),
                  style: context.type.displaySmall),
              const SizedBox(width: 6),
              Text('/ 100', style: context.type.bodySmall),
              const SizedBox(width: 14),
              if (p.status != null)
                StatusChip(_statusLabel(t, p.status!),
                    tone: _tone(p.status), height: 28),
            ]),
          ),
        const SizedBox(height: 8),
        Text(t.passportAssessed(p.assessedCount, p.registeredCount),
            style: context.type.bodySmall),
        Text(t.passportKitchenBasis, style: context.type.bodySmall),
        if (p.safetyFlagged) ...[
          const SizedBox(height: 8),
          Text(t.passportSafetyFlag,
              key: const ValueKey('passport-kitchen-safety'),
              style: TextStyle(
                  color: context.scheme.error,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
        ],
      ]),
    );
  }
}

class _ApplianceCard extends StatelessWidget {
  const _ApplianceCard(this.a);
  final PassportAppliance a;

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    final date = DateFormat.yMMMd(locale);
    final score = a.score;
    return CareCard(
      key: ValueKey('passport-appliance-${a.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_name(t, a), style: context.type.titleSmall),
        const SizedBox(height: 8),
        if (score == null || a.notEnoughChecks)
          Text(t.passportNotEnoughChecks,
              key: ValueKey('passport-noscore-${a.id}'),
              style: context.type.bodyMedium)
        else
          Semantics(
            label: t.passportScoreOutOf(
                score, a.status == null ? '' : _statusLabel(t, a.status!)),
            excludeSemantics: true,
            child: Row(children: [
              Text('$score',
                  key: ValueKey('passport-score-${a.id}'),
                  style: context.type.headlineSmall),
              const SizedBox(width: 4),
              Text('/ 100', style: context.type.bodySmall),
              const SizedBox(width: 12),
              if (a.status != null)
                StatusChip(_statusLabel(t, a.status!),
                    tone: _tone(a.status), height: 26),
            ]),
          ),
        const SizedBox(height: 6),
        if (a.checksTotal > 0)
          Text(t.passportChecksTested(a.checksTested, a.checksTotal),
              style: context.type.bodySmall),
        if (score != null && !a.notEnoughChecks)
          Text(
              a.includesPhotoReview
                  ? t.passportBasisPhoto
                  : t.passportBasisTechnician,
              style: context.type.bodySmall),
        if (a.attentionItems.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(t.passportFlaggedItems(a.attentionItems.join(', ')),
              style: context.type.bodySmall),
        ],
        if (a.safetyFlagged) ...[
          const SizedBox(height: 6),
          Text(t.passportSafetyFlag,
              style: TextStyle(
                  color: context.scheme.error,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
        ],
        if (a.nextService != null) ...[
          const SizedBox(height: 8),
          Text(
              '${_guidance(t, a.nextService!.urgency)} ${_timing(t, a.nextService!.estimatedDays)}.',
              style: context.type.bodySmall),
        ],
        // The tile paints ink on the nearest Material; the card behind it has
        // a background, so give it its own transparent one.
        Material(
            type: MaterialType.transparency,
            child: Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: ValueKey('passport-history-${a.id}'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(t.passportHistory, style: context.type.labelLarge),
                children: [
                  if (a.history.isEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(t.passportHistoryEmpty,
                            style: context.type.bodySmall),
                      ),
                    )
                  else
                    for (final v in a.history)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(v.serviceName ?? '',
                                          style: context.type.bodyMedium),
                                      if (v.date != null)
                                        Text(date.format(v.date!.toLocal()),
                                            style: context.type.bodySmall),
                                    ]),
                              ),
                              Text(
                                  v.score == null
                                      ? t.passportHistoryNotScored
                                      : t.passportHistoryScore(v.score!),
                                  style: context.type.bodySmall),
                              if (v.status != null) ...[
                                const SizedBox(width: 8),
                                StatusChip(_statusLabel(t, v.status!),
                                    tone: _tone(v.status), height: 24),
                              ],
                            ]),
                      ),
                ],
              ),
            )),
      ]),
    );
  }
}
