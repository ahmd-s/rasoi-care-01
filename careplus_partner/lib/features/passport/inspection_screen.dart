import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/care_widgets.dart';
import '../../data/api/passport_api.dart';
import '../../state/providers.dart';
import 'health_widgets.dart';
import 'inspection_catalog.dart';
import 'passport_catalog.dart';

/// The appliance-specific inspection checklist for one registered appliance
/// on one visit (job). Results are saved to the server and reloaded from it.
class InspectionScreen extends ConsumerStatefulWidget {
  const InspectionScreen({super.key, required this.jobId, required this.appliance});
  final String jobId;
  final KitchenAppliance appliance;

  @override
  ConsumerState<InspectionScreen> createState() => _InspectionScreenState();
}

class _InspectionScreenState extends ConsumerState<InspectionScreen> {
  List<InspectionItem> get _items => checklistFor(widget.appliance.category);

  final _results = <String, InspectionResult>{};
  final _notes = <String, TextEditingController>{};
  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _saveError;
  bool _dirty = false;
  HealthAssessment? _health;

  @override
  void initState() {
    super.initState();
    for (final item in _items) {
      _notes[item.key] = TextEditingController();
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in _notes.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply(Inspection inspection) {
    for (final check in inspection.checks) {
      final r = check.result;
      if (r == null) {
        _results.remove(check.key);
      } else {
        _results[check.key] = r;
      }
      _notes[check.key]?.text = check.note;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final r = await ref
        .read(passportApiProvider)
        .inspectionFor(widget.jobId, widget.appliance.id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r.ok) {
        _apply(r.value!);
        _dirty = false;
      } else {
        _loadError = r.error;
      }
    });
    if (r.ok) _refreshHealth();
  }

  /// The score is computed by the server from the saved answers; a failure to
  /// fetch it just hides the panel — it never blocks the checklist.
  Future<void> _refreshHealth() async {
    final h = await ref
        .read(passportApiProvider)
        .applianceHealth(widget.jobId, widget.appliance.id);
    if (!mounted) return;
    setState(() => _health = h.ok ? h.value : null);
  }

  Future<void> _save() async {
    final entries = <({String key, InspectionResult result, String note})>[
      for (final item in _items)
        if (_results[item.key] != null)
          (
            key: item.key,
            result: _results[item.key]!,
            // A note only travels with Attention / Not tested; marking an item
            // Good clears whatever was written.
            note: _results[item.key] == InspectionResult.good
                ? ''
                : (_notes[item.key]?.text.trim() ?? ''),
          ),
    ];
    if (entries.isEmpty) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final r = await ref
        .read(passportApiProvider)
        .saveInspection(widget.jobId, widget.appliance.id, entries);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (r.ok) {
        _apply(r.value!);
        _dirty = false;
      } else {
        _saveError = r.error;
      }
    });
    if (r.ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Checklist saved')));
      _refreshHealth();
    }
  }

  @override
  Widget build(BuildContext context) {
    final category = categoryById(widget.appliance.category);
    final recorded = _items.where((i) => _results[i.key] != null).length;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: context.pop),
        title: Text('${category?.label ?? widget.appliance.category} checklist'),
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      EmptyState(
                        glyph: '⚠',
                        title: 'Could not load the checklist',
                        body: _loadError!,
                        action: FilledButton(onPressed: _load, child: const Text('Retry')),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                          children: [
                            Text(
                              [
                                widget.appliance.brand,
                                if (widget.appliance.model.isNotEmpty) widget.appliance.model,
                              ].join(' · '),
                              style: context.type.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Eyebrow('$recorded of ${_items.length} recorded'),
                            const SizedBox(height: 4),
                            ProgressBar(_items.isEmpty ? 0 : recorded / _items.length),
                            const SizedBox(height: 16),
                            if (_health != null) ...[
                              ApplianceHealthPanel(_health!),
                              if (_dirty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text('Unsaved changes — save to update the score.',
                                      style: context.type.bodySmall),
                                ),
                              const SizedBox(height: 16),
                            ],
                            OutlinedButton.icon(
                              key: const ValueKey('open-ai-inspection'),
                              onPressed: () => context.push(
                                  '/tech/job/${widget.jobId}/kitchen/appliance/${widget.appliance.id}/ai-inspection',
                                  extra: widget.appliance),
                              icon: const Icon(Icons.photo_camera_outlined),
                              label: const Text('Photo inspection (AI, advisory)'),
                            ),
                            const SizedBox(height: 16),
                            for (final item in _items) ...[
                              _CheckCard(
                                item: item,
                                result: _results[item.key],
                                noteController: _notes[item.key]!,
                                onResult: (r) => setState(() {
                                  _results[item.key] = r;
                                  _dirty = true;
                                }),
                                onNoteChanged: () => setState(() => _dirty = true),
                              ),
                              const SizedBox(height: 10),
                            ],
                            if (_saveError != null) ...[
                              const SizedBox(height: 6),
                              Text(_saveError!,
                                  style: TextStyle(color: context.scheme.error, fontSize: 13)),
                            ],
                          ],
                        ),
                      ),
                      Dock(
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _saving || !_dirty || recorded == 0 ? null : _save,
                            child: _saving
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2))
                                : const Text('Save checklist'),
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _CheckCard extends StatelessWidget {
  const _CheckCard({
    required this.item,
    required this.result,
    required this.noteController,
    required this.onResult,
    required this.onNoteChanged,
  });

  final InspectionItem item;
  final InspectionResult? result;
  final TextEditingController noteController;
  final ValueChanged<InspectionResult> onResult;
  final VoidCallback onNoteChanged;

  @override
  Widget build(BuildContext context) {
    final needsNote = result == InspectionResult.attention || result == InspectionResult.notTested;
    return CareCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.label, style: context.type.titleSmall),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in InspectionResult.values)
                ChoiceTag(r.label, selected: result == r, onTap: () => onResult(r)),
            ],
          ),
          if (needsNote) ...[
            const SizedBox(height: 12),
            TextField(
              key: ValueKey('note-${item.key}'),
              controller: noteController,
              maxLength: kMaxInspectionNoteLength,
              maxLines: 2,
              onChanged: (_) => onNoteChanged(),
              decoration: InputDecoration(
                labelText: result == InspectionResult.attention
                    ? 'What needs attention?'
                    : 'Why was it not tested?',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
