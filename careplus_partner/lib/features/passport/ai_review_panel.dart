import 'package:flutter/material.dart';

import '../../core/widgets/care_widgets.dart';
import '../../data/api/vision_api.dart';

const _severities = ['low', 'medium', 'high', 'critical'];

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Called with the decision to save. Returns an error message to show, or null
/// when the server confirmed it was saved.
typedef SubmitReview =
    Future<String?> Function(
      String decision,
      List<AiFindingDecision>? findings,
    );

/// The technician's decision about an AI result: accept, edit finding by
/// finding, or reject. Nothing here changes a score locally; a decision only
/// counts once the server confirms it, and the server alone decides whether
/// (and how) an accepted result is blended into the health score.
class AiReviewPanel extends StatefulWidget {
  const AiReviewPanel({
    super.key,
    required this.result,
    required this.review,
    required this.onSubmit,
  });
  final AiResult result;
  final AiReview? review;
  final SubmitReview onSubmit;

  @override
  State<AiReviewPanel> createState() => _AiReviewPanelState();
}

class _AiReviewPanelState extends State<AiReviewPanel> {
  bool _changing = false;
  bool _editing = false;
  bool _busy = false;
  String? _error;
  final _confirm = <String, bool>{};
  final _severity = <String, String>{};
  final _notes = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _resetEdit();
  }

  @override
  void dispose() {
    for (final c in _notes.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _resetEdit() {
    for (final f in widget.result.findings) {
      _confirm[f.code] = true;
      _severity[f.code] = _severities.contains(f.severity)
          ? f.severity!
          : 'medium';
      _notes.putIfAbsent(f.code, TextEditingController.new).text = '';
    }
  }

  bool get _canAccept => widget.result.conditionScore != null;

  Future<void> _send(
    String decision, [
    List<AiFindingDecision>? findings,
  ]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.onSubmit(decision, findings);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      if (error == null) {
        _changing = false;
        _editing = false;
      }
    });
  }

  String _summary(AiReview r) => switch (r.decision) {
    'accept' => 'You accepted this result.',
    'edit' =>
      'You accepted this result with your changes '
          '(${r.findings.where((f) => f.confirmed).length} of ${r.findings.length} findings confirmed).',
    _ => 'You rejected this result. None of it is treated as confirmed.',
  };

  @override
  Widget build(BuildContext context) {
    final review = widget.review;
    final showSaved = review != null && !_changing;
    return CareCard(
      key: const ValueKey('ai-review-panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Eyebrow('Your review'),
          const SizedBox(height: 8),
          if (showSaved)
            ..._saved(context, review)
          else if (_editing)
            ..._edit(context)
          else
            ..._choose(context, review),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                key: const ValueKey('ai-review-error'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _saved(BuildContext context, AiReview r) => [
    Text(
      _summary(r),
      key: const ValueKey('ai-review-saved'),
      style: Theme.of(context).textTheme.titleSmall,
    ),
    const SizedBox(height: 4),
    Text(
      r.accepted && r.reviewedScore != null
          ? 'Saved. The AI visual score is ${r.reviewedScore}/100 from the findings you confirmed. '
                'It is blended into the appliance health score only together with your own checklist '
                '(70% yours, 30% AI).'
          : 'Saved. This result does not affect any score.',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    const SizedBox(height: 4),
    Text(
      'The original AI result is kept unchanged. Changing your decision saves a new revision '
      '(this is revision ${r.revision}).',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    const SizedBox(height: 8),
    OutlinedButton(
      key: const ValueKey('ai-review-change'),
      onPressed: _busy ? null : () => setState(() => _changing = true),
      child: const Text('Change my decision'),
    ),
  ];

  List<Widget> _choose(BuildContext context, AiReview? previous) => [
    Text(
      previous == null
          ? 'Nothing in this AI result counts as confirmed until you accept it. Check each '
                'finding against the appliance yourself first.'
          : 'Choose a new decision. It is saved as a new revision.',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    if (!_canAccept) ...[
      const SizedBox(height: 6),
      Text(
        'There is no score to accept because the photos were not clear enough. '
        'Reject this result and retake the photos.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
    const SizedBox(height: 12),
    if (_canAccept)
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: const ValueKey('ai-review-accept'),
          onPressed: _busy ? null : () => _send('accept'),
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Accept result'),
        ),
      ),
    if (_canAccept && widget.result.findings.isNotEmpty) ...[
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          key: const ValueKey('ai-review-edit'),
          onPressed: _busy ? null : () => setState(() => _editing = true),
          child: const Text('Review findings one by one'),
        ),
      ),
    ],
    const SizedBox(height: 8),
    SizedBox(
      width: double.infinity,
      child: TextButton(
        key: const ValueKey('ai-review-reject'),
        onPressed: _busy ? null : () => _send('reject'),
        child: const Text('Reject result'),
      ),
    ),
  ];

  List<Widget> _edit(BuildContext context) {
    final findings = widget.result.findings;
    final confirmed = findings.where((f) => _confirm[f.code] == true).length;
    return [
      Text(
        'Confirm only what you can see yourself. You can lower or raise a severity; the AI '
        'score is then recalculated by the server from the findings you confirm.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 10),
      for (final f in findings) ...[
        Text(f.label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceTag(
              'Confirm',
              key: ValueKey('ai-confirm-${f.code}'),
              selected: _confirm[f.code] == true,
              onTap: _busy
                  ? () {}
                  : () => setState(() => _confirm[f.code] = true),
            ),
            ChoiceTag(
              'Reject',
              key: ValueKey('ai-drop-${f.code}'),
              selected: _confirm[f.code] == false,
              onTap: _busy
                  ? () {}
                  : () => setState(() => _confirm[f.code] = false),
            ),
          ],
        ),
        if (_confirm[f.code] == true) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final sev in _severities)
                ChoiceTag(
                  _cap(sev),
                  key: ValueKey('ai-sev-${f.code}-$sev'),
                  selected: _severity[f.code] == sev,
                  onTap: _busy
                      ? () {}
                      : () => setState(() => _severity[f.code] = sev),
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          key: ValueKey('ai-note-${f.code}'),
          controller: _notes[f.code],
          maxLength: 300,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Your note (optional)'),
        ),
        const SizedBox(height: 8),
      ],
      if (confirmed == 0)
        Text(
          'You have rejected every finding. Reject the whole result instead.',
          key: const ValueKey('ai-review-all-rejected'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: const ValueKey('ai-review-save'),
          onPressed: _busy || confirmed == 0
              ? null
              : () => _send('edit', [
                  for (final f in findings)
                    AiFindingDecision(
                      code: f.code,
                      confirmed: _confirm[f.code] == true,
                      severity: _severity[f.code]!,
                      note: _notes[f.code]!.text.trim(),
                    ),
                ]),
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save my review'),
        ),
      ),
      TextButton(
        onPressed: _busy ? null : () => setState(() => _editing = false),
        child: const Text('Back'),
      ),
    ];
  }
}
