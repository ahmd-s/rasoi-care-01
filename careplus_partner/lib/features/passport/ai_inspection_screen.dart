import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/care_widgets.dart';
import '../../data/api/passport_api.dart';
import '../../data/api/vision_api.dart';
import '../../state/providers.dart';
import 'ai_result_view.dart';
import 'ai_review_panel.dart';
import 'passport_catalog.dart';
import 'photo_source.dart';

enum _Phase { loading, loadError, unavailable, capture, progress, done }

/// Delay before the next status poll: quick at first, then easing off.
@visibleForTesting
Duration pollDelay(int polls) => polls < 5
    ? const Duration(seconds: 2)
    : polls < 15
    ? const Duration(seconds: 3)
    : const Duration(seconds: 5);

/// Stop polling on our own after this many checks (~4½ minutes, past the
/// server's hard job cap) and hand control to the technician.
@visibleForTesting
const maxPolls = 60;
const _maxPollFailures = 3;

/// Photo capture → upload → progress → read-only results for one appliance on
/// one visit. Photos are held in memory only; nothing is uploaded until the
/// technician taps Analyse. The result is advisory and is never applied to a
/// checklist answer or to the Kitchen Health score.
class AiInspectionScreen extends ConsumerStatefulWidget {
  const AiInspectionScreen({
    super.key,
    required this.jobId,
    required this.appliance,
  });
  final String jobId;
  final KitchenAppliance appliance;

  @override
  ConsumerState<AiInspectionScreen> createState() => _AiInspectionScreenState();
}

class _AiInspectionScreenState extends ConsumerState<AiInspectionScreen>
    with WidgetsBindingObserver {
  _Phase _phase = _Phase.loading;
  AiConfig? _config;
  String? _loadError;

  final List<Uint8List> _photos = [];
  bool _picking = false;
  bool _submitting = false;
  String? _pickNotice;
  AiFailure? _submitFailure;
  // Reused only while the outcome of an upload is unknown (so a resend can't
  // create a second analysis); reset whenever the photo set changes.
  String? _requestId;

  AiInspection? _job;
  List<AiInspection> _earlier = const [];
  Timer? _timer;
  bool _polling = false;
  int _polls = 0;
  int _pollFailures = 0;
  bool _offline = false;
  bool _pollingStopped = false;
  String? _statusError;
  // Review saves: the id is reused only for the SAME decision after an
  // unconfirmed failure, so a resend can't create a second revision.
  String? _reviewRequestId;
  String? _reviewFingerprint;
  bool _reviewing = false;

  VisionApi get _api => ref.read(visionApiProvider);
  String get _categoryLabel =>
      categoryById(widget.appliance.category)?.label ??
      widget.appliance.category;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _photos.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_job == null || !_job!.status.inProgress) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _timer?.cancel();
    } else if (state == AppLifecycleState.resumed && !_pollingStopped) {
      _poll();
    }
  }

  // ---------------------------------------------------------------- loading
  Future<void> _load() async {
    setState(() {
      _phase = _Phase.loading;
      _loadError = null;
    });
    final cfg = await _api.config();
    if (!mounted) return;
    if (!cfg.ok) {
      setState(() {
        _phase = _Phase.loadError;
        _loadError = cfg.failure!.message;
      });
      return;
    }
    _config = cfg.value;
    if (!_config!.enabled) {
      setState(() => _phase = _Phase.unavailable);
      return;
    }
    // A job already running for this visit (e.g. the technician left and came
    // back) is resumed instead of inviting a second, duplicate submission.
    final list = await _api.list(widget.jobId, widget.appliance.id);
    if (!mounted) return;
    final all = list.ok ? list.value! : const <AiInspection>[];
    final running = all.where((j) => j.status.inProgress).toList();
    setState(() {
      _earlier = [
        for (final j in all)
          if (!j.status.inProgress) j,
      ];
      if (running.isNotEmpty) {
        _job = running.first;
        _phase = _Phase.progress;
      } else {
        _phase = _Phase.capture;
      }
    });
    if (running.isNotEmpty) _poll();
  }

  // ---------------------------------------------------------------- photos
  void _photosChanged() {
    _requestId = null;
    _submitFailure = null;
  }

  Future<void> _add(Future<List<Uint8List>> Function() pick) async {
    if (_picking || _submitting) return;
    setState(() {
      _picking = true;
      _pickNotice = null;
    });
    String? notice;
    try {
      final picked = await pick();
      if (!mounted) return;
      final cfg = _config!;
      var total = _photos.fold<int>(0, (s, p) => s + p.length);
      final problems = <String>[];
      for (final bytes in picked) {
        final number = _photos.length + 1;
        if (_photos.length >= cfg.maxImages) {
          problems.add('Only ${cfg.maxImages} photos can be analysed at once.');
          break;
        }
        final problem = photoProblem(bytes, cfg, number: number);
        if (problem != null) {
          problems.add(problem);
        } else if (_photos.any((p) => _sameBytes(p, bytes))) {
          problems.add('That photo is already added.');
        } else if (total + bytes.length > cfg.maxTotalBytes) {
          problems.add(
            'The photos together are too large (limit '
            '${(cfg.maxTotalBytes / 1000000).toStringAsFixed(1)} MB). Remove one first.',
          );
        } else {
          _photos.add(bytes);
          total += bytes.length;
          _photosChanged();
        }
      }
      if (problems.isNotEmpty) notice = problems.toSet().join('\n');
    } on PhotoPermissionDenied catch (e) {
      notice = e.kind == PhotoSourceKind.camera
          ? 'Camera access is off. Allow the camera for Rasoi Care Partner in your phone '
                'settings, or choose a photo from the gallery instead.'
          : 'Photo access is off. Allow photo access for Rasoi Care Partner in your phone '
                'settings, or take a photo with the camera instead.';
    } on PhotoPickFailed {
      notice = 'Could not get a photo. Please try again.';
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      _pickNotice = notice;
    });
  }

  void _remove(int index) {
    if (_submitting) return;
    setState(() {
      _photos.removeAt(index);
      _pickNotice = null;
      _photosChanged();
    });
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ------------------------------------------------------------ submission
  static String _newRequestId() {
    final r = Random.secure();
    return 'ai-${List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join()}';
  }

  Future<void> _submit() async {
    final cfg = _config;
    if (_submitting || cfg == null || _photos.length < cfg.minImages) return;
    // Set before the first await so a second tap in the same frame is a no-op.
    setState(() {
      _submitting = true;
      _submitFailure = null;
    });
    final id = _requestId ??= _newRequestId();
    final r = await _api.submit(
      widget.jobId,
      widget.appliance.id,
      photos: [
        for (final p in _photos)
          AiPhoto(bytes: p, mimeType: sniffImageType(p) ?? 'image/jpeg'),
      ],
      clientRequestId: id,
    );
    if (!mounted) return;
    if (!r.ok) {
      final f = r.failure!;
      setState(() {
        _submitting = false;
        _submitFailure = f;
        // The server definitively refused (4xx): a later attempt is a new
        // request. After a network error or 5xx the outcome is unknown, so
        // the same id is kept and the server returns the original job.
        if (f.status >= 400 && f.status < 500) _requestId = null;
      });
      return;
    }
    _requestId = null;
    _polls = 0;
    _pollFailures = 0;
    _offline = false;
    _pollingStopped = false;
    _statusError = null;
    setState(() => _submitting = false);
    _handleJob(r.value!);
  }

  // --------------------------------------------------------------- polling
  void _handleJob(AiInspection job) {
    _timer?.cancel();
    setState(() {
      _job = job;
      _phase = job.status.inProgress ? _Phase.progress : _Phase.done;
      if (!job.status.inProgress) {
        _pollingStopped = false;
        // Terminal: the photos are no longer needed except to retry a failure.
        if (job.status == AiJobStatus.completed) _photos.clear();
      }
    });
    if (!job.status.inProgress) return;
    if (_polls >= maxPolls) {
      setState(() => _pollingStopped = true);
      return;
    }
    _timer = Timer(pollDelay(_polls), _poll);
  }

  Future<void> _poll() async {
    final job = _job;
    if (_polling || job == null || !mounted) return;
    _timer?.cancel();
    _polling = true;
    _polls++;
    final r = await _api.status(widget.jobId, widget.appliance.id, job.id);
    _polling = false;
    if (!mounted) return;
    if (r.ok) {
      _pollFailures = 0;
      setState(() {
        _offline = false;
        _statusError = null;
        _pollingStopped = false;
      });
      _handleJob(r.value!);
      return;
    }
    final f = r.failure!;
    _pollFailures++;
    final fatal = f.status == 401 || f.status == 404;
    setState(() {
      _offline = f.networkError;
      _statusError = f.message;
      _pollingStopped = fatal || _pollFailures >= _maxPollFailures;
    });
    if (!_pollingStopped) _timer = Timer(pollDelay(_polls), _poll);
  }

  void _checkAgain() {
    _polls = _polls >= maxPolls ? maxPolls - 10 : _polls;
    _pollFailures = 0;
    setState(() {
      _pollingStopped = false;
      _statusError = null;
    });
    _poll();
  }

  // ----------------------------------------------------------------- review
  /// Saves the technician's decision. Returns an error message, or null once
  /// the server has confirmed it and the result has been reloaded.
  Future<String?> _submitReview(
    String decision,
    List<AiFindingDecision>? findings,
  ) async {
    final job = _job;
    if (_reviewing || job == null) return null;
    _reviewing = true;
    final fingerprint =
        '$decision|${findings?.map((f) => jsonEncode(f.toJson())).join(',')}';
    if (_reviewRequestId == null || _reviewFingerprint != fingerprint) {
      _reviewRequestId = _newRequestId();
      _reviewFingerprint = fingerprint;
    }
    final r = await _api.review(
      widget.jobId,
      widget.appliance.id,
      job.id,
      decision: decision,
      findings: findings,
      clientRequestId: _reviewRequestId!,
    );
    _reviewing = false;
    if (!r.ok) {
      final f = r.failure!;
      if (!mounted) return null;
      // A definite refusal (4xx) means a later attempt is a new request.
      if (f.status >= 400 && f.status < 500) _reviewRequestId = null;
      return f.networkError
          ? '${f.message} Your decision may or may not have been saved — tap again to retry safely.'
          : f.message;
    }
    _reviewRequestId = null;
    if (!mounted) return null;
    // Reload so the result shows what the server now says (accepted / used in score).
    final fresh = await _api.status(widget.jobId, widget.appliance.id, job.id);
    if (!mounted) return null;
    if (fresh.ok) {
      _handleJob(fresh.value!);
    } else {
      return 'Saved, but the screen could not refresh. ${fresh.failure!.message}';
    }
    return null;
  }

  // ------------------------------------------------------------- navigation
  /// Back to the capture view with the same photos still selected. The next
  /// Analyse is a new, explicit request and counts as another analysis.
  void _tryAgain() {
    _requestId = null;
    setState(() {
      _job = null;
      _phase = _Phase.capture;
      _submitFailure = null;
    });
  }

  void _newPhotos() {
    _photos.clear();
    _photosChanged();
    _tryAgain();
  }

  Future<void> _openEarlier(AiInspection summary) async {
    final r = await _api.status(widget.jobId, widget.appliance.id, summary.id);
    if (!mounted) return;
    if (r.ok) {
      _handleJob(r.value!);
    } else {
      setState(() => _submitFailure = r.failure);
    }
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: context.pop),
        title: Text('Photo inspection · $_categoryLabel'),
      ),
      body: SafeArea(top: false, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    switch (_phase) {
      case _Phase.loading:
        return const Center(child: CircularProgressIndicator());
      case _Phase.loadError:
        return _scroll([
          EmptyState(
            glyph: '⚠',
            title: 'Could not load photo inspection',
            body: _loadError ?? 'Please try again.',
            action: FilledButton(onPressed: _load, child: const Text('Retry')),
          ),
        ]);
      case _Phase.unavailable:
        return _scroll([
          const EmptyState(
            glyph: '○',
            title: 'AI photo inspection is not available',
            body:
                'It is switched off for now. Complete the checklist yourself — nothing '
                'else is affected and your scores are unchanged.',
          ),
        ]);
      case _Phase.capture:
        return _capture(context);
      case _Phase.progress:
        return _progress(context);
      case _Phase.done:
        return _done(context);
    }
  }

  Widget _scroll(List<Widget> children) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
    children: children,
  );

  Widget _capture(BuildContext context) {
    final cfg = _config!;
    final full = _photos.length >= cfg.maxImages;
    final canPick = !_picking && !_submitting && !full;
    final remaining = cfg.maxImages - _photos.length;
    return Column(
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
              const SizedBox(height: 12),
              CareCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Eyebrow('Before you take photos'),
                    const SizedBox(height: 6),
                    Text(
                      cfg.privacyNotice,
                      key: const ValueKey('ai-privacy-notice'),
                      style: context.type.bodyMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Take ${cfg.minImages}–${cfg.maxImages} clear photos of this '
                      '${_categoryLabel.toLowerCase()}. They are sent to the Rasoi Care server '
                      'for AI analysis only when you tap Analyse, and are not saved afterwards. '
                      'The AI only describes what is visible.',
                      style: context.type.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: canPick
                          ? () => _add(ref.read(photoSourceProvider).fromCamera)
                          : null,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Take photo'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: canPick
                          ? () => _add(
                              () => ref
                                  .read(photoSourceProvider)
                                  .fromGallery(limit: remaining),
                            )
                          : null,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Gallery'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${_photos.length} of ${cfg.maxImages} photos selected',
                key: const ValueKey('ai-photo-count'),
                style: context.type.bodySmall,
              ),
              if (_picking) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
              ],
              if (_pickNotice != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _pickNotice!,
                    key: const ValueKey('ai-pick-notice'),
                    style: TextStyle(color: context.scheme.error, fontSize: 13),
                  ),
                ),
              ],
              if (_photos.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (var i = 0; i < _photos.length; i++)
                      _PhotoTile(
                        key: ValueKey('ai-photo-$i'),
                        bytes: _photos[i],
                        number: i + 1,
                        total: _photos.length,
                        onRemove: _submitting ? null : () => _remove(i),
                      ),
                  ],
                ),
              ],
              if (_earlier.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Eyebrow('Earlier analyses this visit'),
                const SizedBox(height: 8),
                for (final j in _earlier)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: CareCard(
                      onTap: () => _openEarlier(j),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _statusLabel(j.status),
                              style: context.type.titleSmall,
                            ),
                          ),
                          if (j.imageCount != null)
                            Text(
                              '${j.imageCount} photo${j.imageCount == 1 ? '' : 's'}',
                              style: context.type.bodySmall,
                            ),
                          const SizedBox(width: 6),
                          const Icon(Icons.chevron_right, size: 18),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
        // Outside the scrolling list so an upload error is never off-screen.
        if (_submitFailure != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: _SubmitError(_submitFailure!, _requestId != null),
          ),
        Dock(
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed:
                  _submitting || _picking || _photos.length < cfg.minImages
                  ? null
                  : _submit,
              child: _submitting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _photos.isEmpty
                          ? 'Add a photo to analyse'
                          : 'Analyse ${_photos.length} photo${_photos.length == 1 ? '' : 's'}',
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _progress(BuildContext context) {
    final job = _job!;
    final running = job.status == AiJobStatus.running;
    return _scroll([
      CareCard(
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (!_pollingStopped)
                    const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (!_pollingStopped) const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      running ? 'Analysing your photos…' : 'Waiting to start…',
                      key: const ValueKey('ai-progress-title'),
                      style: context.type.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'This is not finished yet. A result appears here only after the server confirms '
                'it. You can leave this screen — the analysis carries on, and you can reopen '
                'photo inspection for this appliance to find it.',
                style: context.type.bodySmall,
              ),
              if (_offline && !_pollingStopped) ...[
                const SizedBox(height: 8),
                Text(
                  'Connection lost — retrying…',
                  key: const ValueKey('ai-offline'),
                  style: TextStyle(color: context.scheme.error, fontSize: 13),
                ),
              ],
              if (_pollingStopped) ...[
                const SizedBox(height: 10),
                Text(
                  _statusError ??
                      'This is taking longer than expected. The analysis may still finish.',
                  key: const ValueKey('ai-poll-stopped'),
                  style: TextStyle(color: context.scheme.error, fontSize: 13),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _checkAgain,
                  child: const Text('Check again'),
                ),
              ],
            ],
          ),
        ),
      ),
    ]);
  }

  Widget _done(BuildContext context) {
    final job = _job!;
    switch (job.status) {
      case AiJobStatus.completed:
        final result = job.result;
        if (result == null) {
          return _scroll([
            EmptyState(
              glyph: '⚠',
              title: 'The result could not be shown',
              body:
                  'The server marked this analysis complete but sent no usable result. '
                  'Nothing from it has been used.',
              action: FilledButton(
                onPressed: _newPhotos,
                child: const Text('Start over'),
              ),
            ),
          ]);
        }
        return _scroll([
          AiResultView(result),
          const SizedBox(height: 16),
          AiReviewPanel(
            key: ValueKey('review-${job.id}'),
            result: result,
            review: job.review,
            onSubmit: _submitReview,
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _newPhotos,
            child: const Text('Analyse different photos'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: context.pop,
            child: const Text('Back to checklist'),
          ),
        ]);
      case AiJobStatus.failed:
      case AiJobStatus.rejected:
        final rejected = job.status == AiJobStatus.rejected;
        return _scroll([
          EmptyState(
            glyph: '⚠',
            title: rejected
                ? 'The AI answer was rejected'
                : 'The analysis did not finish',
            body:
                '${job.errorMessage ?? 'Something went wrong.'}'
                '${rejected ? '\nThe answer did not pass the safety checks, so none of it is shown.' : ''}',
            action: job.retryable && _photos.isNotEmpty
                ? Column(
                    children: [
                      FilledButton(
                        onPressed: _tryAgain,
                        child: const Text('Review photos and try again'),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Trying again counts as another analysis.',
                        style: context.type.bodySmall,
                      ),
                    ],
                  )
                : OutlinedButton(
                    onPressed: _newPhotos,
                    child: const Text('Use new photos'),
                  ),
          ),
        ]);
      case AiJobStatus.queued:
      case AiJobStatus.running:
      case AiJobStatus.unknown:
        return _scroll([
          EmptyState(
            glyph: '?',
            title: 'Unexpected status',
            body:
                'The server sent a status this app does not understand, so nothing is shown '
                'as finished.',
            action: FilledButton(
              onPressed: _checkAgain,
              child: const Text('Check again'),
            ),
          ),
        ]);
    }
  }

  static String _statusLabel(AiJobStatus s) => switch (s) {
    AiJobStatus.completed => 'Completed analysis',
    AiJobStatus.failed => 'Analysis did not finish',
    AiJobStatus.rejected => 'Answer rejected',
    _ => 'Analysis',
  };
}

class _SubmitError extends StatelessWidget {
  const _SubmitError(this.failure, this.sameRequest);
  final AiFailure failure;

  /// True when a retry reuses the same request id (outcome was unknown).
  final bool sameRequest;

  @override
  Widget build(BuildContext context) {
    final photo = failure.imageIndex == null
        ? ''
        : 'Photo ${failure.imageIndex! + 1}: ';
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey('ai-submit-error'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.scheme.error.withValues(alpha: 0.08),
          border: Border.all(
            color: context.scheme.error.withValues(alpha: 0.5),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$photo${failure.message}',
              style: TextStyle(color: context.scheme.error, fontSize: 13),
            ),
            if (sameRequest) ...[
              const SizedBox(height: 4),
              Text(
                'We could not confirm whether the photos arrived. Tap Analyse again — the same '
                'request is reused, so it will not be analysed twice.',
                style: context.type.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    super.key,
    required this.bytes,
    required this.number,
    required this.total,
    required this.onRemove,
  });
  final Uint8List bytes;
  final int number;
  final int total;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              label: 'Selected photo $number of $total',
              image: true,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  cacheWidth: 256,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Container(
                    color: context.scheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              key: ValueKey('ai-remove-$number'),
              tooltip: 'Remove photo $number',
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
                foregroundColor: Colors.white,
                minimumSize: const Size(44, 44),
              ),
              icon: const Icon(Icons.close, size: 18),
              onPressed: onRemove,
            ),
          ),
        ],
      ),
    );
  }
}
