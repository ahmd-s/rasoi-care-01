import 'package:flutter/material.dart';

import '../../core/theme/care_plus_theme.dart';
import '../../core/widgets/care_widgets.dart';
import '../../data/api/passport_api.dart';

ChipTone toneForStatus(String? status) => switch (status) {
  'healthy' => ChipTone.success,
  'attention' || 'priority' => ChipTone.warning,
  'critical' => ChipTone.danger,
  _ => ChipTone.neutral,
};

/// Technician health score for one appliance: the number (or "Not enough
/// checks to score."), its status, coverage, any safety warning, and the
/// plain-language explanation. Always labelled as technician-only.
class ApplianceHealthPanel extends StatelessWidget {
  const ApplianceHealthPanel(this.health, {super.key});
  final HealthAssessment health;

  @override
  Widget build(BuildContext context) {
    return CareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Eyebrow(health.basisLabel),
          const SizedBox(height: 10),
          _ScoreRow(
            score: health.score,
            status: health.status,
            statusLabel: health.statusLabel,
            caption: health.coverageLabel,
            emptyMessage: health.message,
          ),
          if (health.aiScore != null) ...[
            const SizedBox(height: 10),
            Text(
              health.combinedScore != null
                  ? 'Combined score ${health.combinedScore} = 70% your checks + 30% accepted '
                        'AI visual score ${health.aiScore}'
                  : 'Accepted AI visual score ${health.aiScore} (not counted until enough '
                        'checks are tested)',
              key: const ValueKey('health-ai-line'),
              style: context.type.bodySmall,
            ),
          ],
          if (health.safetyFlagged) ...[
            const SizedBox(height: 12),
            _SafetyBanner(
              health.safetyWarning ?? 'Safety item flagged',
              health.safetyItems,
            ),
          ],
          const SizedBox(height: 12),
          for (final line in health.explanation.where(
            (l) => l != health.disclaimer,
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(line, style: context.type.bodySmall),
            ),
          const SizedBox(height: 6),
          Text(
            health.disclaimer,
            style: context.type.bodySmall!.copyWith(
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

/// Kitchen-level summary shown at the top of the Kitchen Passport screen.
class KitchenHealthPanel extends StatelessWidget {
  const KitchenHealthPanel(this.health, {super.key});
  final KitchenHealth health;

  @override
  Widget build(BuildContext context) {
    return CareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Eyebrow('Kitchen health · ${health.basisLabel}'),
          const SizedBox(height: 10),
          _ScoreRow(
            score: health.score,
            status: health.status,
            statusLabel: health.statusLabel,
            caption: health.coverageLabel,
            emptyMessage: health.message,
          ),
          if (health.safetyFlagged) ...[
            const SizedBox(height: 12),
            _SafetyBanner(
              health.safetyWarning ?? 'Safety item flagged',
              const [],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            health.disclaimer,
            style: context.type.bodySmall!.copyWith(
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({
    required this.score,
    required this.status,
    required this.statusLabel,
    required this.caption,
    required this.emptyMessage,
  });
  final int? score;
  final String? status;
  final String? statusLabel;
  final String caption;
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (score == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            emptyMessage ?? 'Not enough checks to score.',
            style: context.type.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(caption, style: context.type.bodySmall),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          '$score',
          key: const ValueKey('health-score'),
          style: CareType.mono(
            context.scheme.onSurface,
            size: 34,
            w: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 6),
        Text('/ 100', style: context.type.bodySmall),
        const SizedBox(width: 14),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (statusLabel != null)
                StatusChip(
                  statusLabel!,
                  tone: toneForStatus(status),
                  height: 28,
                ),
              Text(caption, style: context.type.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _SafetyBanner extends StatelessWidget {
  const _SafetyBanner(this.warning, this.items);
  final String warning;
  final List<String> items;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('safety-banner'),
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.scheme.errorContainer,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      items.isEmpty ? warning : '$warning: ${items.join(', ')}',
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: context.scheme.onErrorContainer,
      ),
    ),
  );
}
