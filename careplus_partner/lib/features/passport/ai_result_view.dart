import 'package:flutter/material.dart';

import '../../core/widgets/care_widgets.dart';
import '../../data/api/vision_api.dart';

const _advisoryBanner =
    'AI visual assessment of photos only. It is advisory, counts only after you accept it, '
    'and cannot see hidden mechanical, electrical, gas or performance faults. '
    'Check everything yourself before acting on it.';

ChipTone _toneForSeverity(String? s) => switch (s) {
  'high' || 'critical' => ChipTone.danger,
  'medium' => ChipTone.warning,
  _ => ChipTone.neutral,
};

String _capitalise(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Read-only view of a completed analysis. Every string is shown as plain
/// text (never parsed as markup), and any missing field is simply omitted —
/// nothing is filled in on the server's behalf.
class AiResultView extends StatelessWidget {
  const AiResultView(this.result, {super.key});
  final AiResult result;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final safety = r.findings.where((f) => f.safetyRelevant).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Banner(
          icon: Icons.info_outline,
          text: r.disclaimer ?? _advisoryBanner,
          tone: _BannerTone.info,
          extra: r.disclaimer == null ? null : _advisoryBanner,
        ),
        const SizedBox(height: 12),
        // The technician-review messages are always shown; safety ones lead.
        if (safety.isNotEmpty) ...[
          _Banner(
            icon: Icons.warning_amber_rounded,
            text:
                'Visible safety-relevant item${safety.length > 1 ? 's' : ''} reported: '
                '${safety.map((f) => f.label).join(', ')}. Verify in person before the job is closed.',
            tone: _BannerTone.danger,
          ),
          const SizedBox(height: 12),
        ],
        for (final m in r.reviewMessages) ...[
          _Banner(
            icon: Icons.fact_check_outlined,
            text: m,
            tone: _BannerTone.warning,
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 4),
        CareCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (r.applianceProfile != null) Eyebrow(r.applianceProfile!),
              if (r.applianceProfile != null) const SizedBox(height: 8),
              if (r.summary != null)
                Text(r.summary!, style: context.type.titleSmall),
              const SizedBox(height: 10),
              _ScoreLine(r),
              if (r.urgency != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Suggested urgency: ${_capitalise(r.urgency!)}'
                  '${r.estimatedDays == null ? '' : (r.estimatedDays == 0 ? ' · service now' : ' · service within ${r.estimatedDays} days')}',
                  key: const ValueKey('ai-urgency'),
                  style: context.type.bodySmall,
                ),
              ],
              if (r.focusAreas.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Looked at: ${r.focusAreas.join(', ')}',
                  style: context.type.bodySmall,
                ),
              ],
              if (r.photosAnalyzed != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Photos analysed: ${r.photosAnalyzed}',
                  style: context.type.bodySmall,
                ),
              ],
              if (r.visibility == 'insufficient') ...[
                const SizedBox(height: 8),
                const StatusChip(
                  'Photos not clear enough',
                  tone: ChipTone.warning,
                  height: 26,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Eyebrow('Visible findings (${r.findings.length})'),
        const SizedBox(height: 8),
        if (r.findings.isEmpty)
          CareCard(
            child: Text(
              r.visibility == 'insufficient'
                  ? 'Nothing could be assessed because the photos were not clear enough. '
                        'Retake them in good light.'
                  : 'No visible issues were identified in these photos. This does not rule out '
                        'faults that cannot be seen — follow the technician checklist.',
              key: const ValueKey('ai-no-findings'),
              style: context.type.bodyMedium,
            ),
          )
        else
          for (final f in r.findings) ...[
            _FindingCard(f),
            const SizedBox(height: 10),
          ],
        if (r.inconsistencies.isNotEmpty) ...[
          const SizedBox(height: 6),
          const Eyebrow('Differs from your checklist'),
          const SizedBox(height: 8),
          for (final i in r.inconsistencies) ...[
            CareCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (i.visualFinding.isNotEmpty)
                    Text(i.visualFinding, style: context.type.titleSmall),
                  Text(i.reason, style: context.type.bodySmall),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
        if (r.recommendation != null) ...[
          const SizedBox(height: 8),
          const Eyebrow('Suggested next step'),
          const SizedBox(height: 6),
          Text(r.recommendation!, style: context.type.bodyMedium),
        ],
        if (r.limitations.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Eyebrow('What photos cannot show'),
          const SizedBox(height: 6),
          for (final l in r.limitations)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $l', style: context.type.bodySmall),
            ),
        ],
        if (r.notAssessableChecks.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Eyebrow('Still needs your hands-on check'),
          const SizedBox(height: 6),
          for (final l in r.notAssessableChecks)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $l', style: context.type.bodySmall),
            ),
        ],
      ],
    );
  }
}

class _ScoreLine extends StatelessWidget {
  const _ScoreLine(this.r);
  final AiResult r;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: r.conditionScore == null
              ? 'Visual condition score: none'
              : 'Visual condition score ${r.conditionScore} out of 100, from photos only',
          excludeSemantics: true,
          child: Text(
            r.conditionScore == null
                ? 'Visual score: none'
                : 'Visual score (photos only): ${r.conditionScore}/100',
            style: context.type.titleMedium,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          r.usedInHealthScore
              ? 'Counted in the combined health score (30%) because you accepted this result.'
              : 'Not used in the Kitchen Health score unless you accept this result.',
          key: const ValueKey('ai-score-use'),
          style: context.type.bodySmall,
        ),
        if (r.scoreRationale != null)
          Text(r.scoreRationale!, style: context.type.bodySmall),
      ],
    );
  }
}

class _FindingCard extends StatelessWidget {
  const _FindingCard(this.f);
  final AiFinding f;

  @override
  Widget build(BuildContext context) {
    final photos = f.photoIndexes.toSet().toList()..sort();
    return CareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(f.label, style: context.type.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (f.severity != null)
                StatusChip(
                  '${_capitalise(f.severity!)} severity',
                  tone: _toneForSeverity(f.severity),
                  height: 26,
                ),
              if (f.confidence != null)
                StatusChip(
                  'Confidence ${(f.confidence! * 100).round()}%',
                  height: 26,
                ),
              if (f.safetyRelevant)
                const StatusChip(
                  'Safety — verify in person',
                  tone: ChipTone.danger,
                  height: 26,
                ),
            ],
          ),
          if (f.evidence != null) ...[
            const SizedBox(height: 8),
            Text(
              'What is visible: ${f.evidence}',
              style: context.type.bodyMedium,
            ),
          ],
          if (photos.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Seen in photo ${photos.map((i) => i + 1).join(', ')}',
              style: context.type.bodySmall,
            ),
          ],
          if (f.recommendation != null) ...[
            const SizedBox(height: 8),
            Text(f.recommendation!, style: context.type.bodySmall),
          ],
        ],
      ),
    );
  }
}

enum _BannerTone { info, warning, danger }

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.tone,
    this.extra,
  });
  final IconData icon;
  final String text;
  final _BannerTone tone;
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final color = switch (tone) {
      _BannerTone.danger => scheme.error,
      _BannerTone.warning => scheme.tertiary,
      _BannerTone.info => scheme.primary,
    };
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: context.type.bodySmall),
                  if (extra != null) ...[
                    const SizedBox(height: 4),
                    Text(extra!, style: context.type.bodySmall),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
