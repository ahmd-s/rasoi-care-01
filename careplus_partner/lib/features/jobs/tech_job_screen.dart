import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/maps_config.dart';
import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/api/api_repository.dart';
import '../../data/api/booking_dto.dart';
import '../../data/models.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/providers.dart';
import 'airflow_check_screen.dart';

/// Curated for the Indian kitchen-appliance market this app actually
/// services (chimneys, hobs, microwaves, dishwashers, fridges, water
/// purifiers) — not an exhaustive global brand registry. [kApplianceBrandOther]
/// falls through to a free-text prompt for anything not on the list.
const kApplianceBrandOther = 'Other';
const kApplianceBrands = <String>[
  'LG', 'Samsung', 'Whirlpool', 'IFB', 'Bosch', 'Siemens', 'Godrej', 'Haier',
  'Panasonic', 'Voltas', 'Faber', 'Elica', 'Kaff', 'Hindware', 'Kutchina',
  'Sunflame', 'Prestige', 'Butterfly', 'Glen', 'Kenstar', 'Onida', 'Videocon',
  'Electrolux', 'Kelvinator', 'Miele', 'Philips', 'Bajaj', kApplianceBrandOther,
];

class TechJobScreen extends ConsumerStatefulWidget {
  const TechJobScreen({super.key, required this.jobId});
  final String jobId;
  @override
  ConsumerState<TechJobScreen> createState() => _TechJobScreenState();
}

class _TechJobScreenState extends ConsumerState<TechJobScreen> {
  int _elapsedSecs = 84; // 01:24 — matches the on-site timer already running
  Timer? _t;
  bool _advancing = false;
  bool _unclaiming = false;
  // Guards add-part/remove-part/change-service — none of these disabled
  // their trigger button while the request was in flight, so a double-tap
  // on a slow connection could fire the same mutation twice (e.g. raising
  // the same part/quote for the customer to approve two times over).
  bool _mutatingParts = false;

  // ---- job-tracking map (only ever used when MapsConfig.isConfigured) ----
  GoogleMapController? _mapController;
  LatLng? _myLocation;
  Timer? _locationTimer;

  // Model number is free text the technician edits in place — the
  // controller holds it between saves rather than rebuilding on every
  // provider tick, which would otherwise fight the technician's typing.
  late final TextEditingController _modelCtrl;

  @override
  void initState() {
    super.initState();
    _modelCtrl = TextEditingController(
        text: ref.read(repositoryProvider).jobDetail(widget.jobId).modelNumber ?? '');
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsedSecs++);
    });
    if (MapsConfig.isConfigured) {
      _refreshMyLocation();
      _locationTimer =
          Timer.periodic(const Duration(seconds: 15), (_) => _refreshMyLocation());
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    _locationTimer?.cancel();
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshMyLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
      ).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      final point = LatLng(pos.latitude, pos.longitude);
      setState(() => _myLocation = point);
      await _mapController?.animateCamera(CameraUpdate.newLatLng(point));
    } catch (_) {
      // Best-effort — the map just shows the destination alone.
    }
  }

  /// Dials the customer's real, Firebase-verified phone number — previously
  /// this was a "Calling — masked" toast that never actually called anyone,
  /// regardless of whether a number was even known.
  Future<void> _callCustomer(JobDetail job) async {
    final t = context.l10n;
    final phone = job.customerPhone;
    if (phone == null || phone.trim().isEmpty) {
      _toast(context, t.jobDetailCallUnavailable);
      return;
    }
    final launched = await launchUrl(Uri(scheme: 'tel', path: phone));
    if (!launched && mounted) _toast(context, t.jobDetailCallError);
  }

  /// Opens the phone's own Google Maps app for turn-by-turn directions
  /// (falls back to a plain maps search URL if that's not available, or if
  /// this booking has no real coordinates — only a label-only address).
  Future<void> _openNavigation(JobDetail job) async {
    var launched = false;
    if (job.lat != null && job.lng != null) {
      try {
        launched = await launchUrl(
          Uri.parse('google.navigation:q=${job.lat},${job.lng}&mode=d'),
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        launched = false;
      }
    }
    if (!launched) {
      final query = (job.lat != null && job.lng != null)
          ? '${job.lat},${job.lng}'
          : Uri.encodeComponent(job.addressLine);
      try {
        launched = await launchUrl(
          Uri.parse('https://www.google.com/maps/search/?api=1&query=$query'),
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        launched = false;
      }
    }
    if (!launched && mounted) _toast(context, context.l10n.jobDetailNavError);
  }

  String get _clock {
    final m = _elapsedSecs ~/ 60, s = _elapsedSecs % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Label for the dock's primary button, driven by the job's real status
  /// when this is a known live booking (see `ApiRepository.statusOf`);
  /// `null` covers mock/local jobs, which keep the original single-step
  /// flow straight into the invoice screen.
  String _primaryLabel(AppLocalizations t, String? liveStatus) => switch (liveStatus) {
        'Requested' => t.jobDetailPrimaryAccept,
        'Accepted' => t.jobDetailPrimaryOnMyWay,
        'On the way' => t.jobDetailPrimaryArrived,
        _ => t.jobDetailPrimaryComplete, // In Progress, Completed, null (mock)
      };

  Future<void> _handlePrimaryAction(String? liveStatus, JobDetail job) async {
    if (liveStatus == null || liveStatus == 'Completed') {
      context.push('/tech/job/${widget.jobId}/close');
      return;
    }
    final t = context.l10n;

    // "Arrived — start job": the backend refuses to move into "In
    // Progress" without the 4-digit code the Customer app shows that
    // customer, so a technician can't mark a visit started without
    // actually being there in person to ask for it. For a chimney
    // (RasoiAir) job, this is also the moment the airflow "before" reading
    // gets taken — right as the visit actually starts, not retroactively
    // guessed at completion.
    if (liveStatus == 'On the way') {
      final code = await _askStartCode();
      if (code == null || !mounted) return; // cancelled
      final repo = ref.read(repositoryProvider);
      final category = repo is ApiRepository ? repo.categoryOf(widget.jobId) : null;
      if (category == 'RasoiAir') {
        final before = await _askAirflowBefore(job);
        if (!mounted) return;
        if (before != null) {
          ref.read(techAirflowBeforeProvider(widget.jobId).notifier).set(before);
        }
      }
      await _advanceStatus(startCode: code);
      return;
    }

    if (liveStatus == 'In Progress') {
      final beforeDone = ref.read(techBeforePhotosProvider(widget.jobId)).isNotEmpty;
      final afterDone = ref.read(techAfterPhotosProvider(widget.jobId)).isNotEmpty;
      if (!beforeDone || !afterDone) {
        _toast(context, t.jobDetailPhotosMissing);
        return;
      }
      // Airflow (CFM) is the only reading this app ever asks a technician
      // for, and only for chimney (RasoiAir) jobs — the "before" half was
      // already captured on arrival, above; this is just the "after" half.
      // The actual advance-to-Completed call now happens on the close
      // screen, once the customer's signature is captured — not here,
      // which is exactly what let an invoice appear before a signature
      // ever existed.
      final repo = ref.read(repositoryProvider);
      final category = repo is ApiRepository ? repo.categoryOf(widget.jobId) : null;
      (int?, int?) suction = (null, null);
      if (category == 'RasoiAir') {
        final before = ref.read(techAirflowBeforeProvider(widget.jobId)) ?? const AirflowReading();
        suction = await _askAirflowAfter(job, before);
        if (!mounted) return;
      }
      context.push('/tech/job/${widget.jobId}/close', extra: suction);
      return;
    }

    // Requested -> Accepted (shouldn't normally reach this screen — that
    // happens on the Jobs feed's incoming-request card) or Accepted -> On
    // the way: a plain advance, no gate.
    await _advanceStatus();
  }

  Future<String?> _askStartCode() async {
    final t = context.l10n;
    final codeCtrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.jobDetailEnterCodeTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.jobDetailEnterCodeSubtitle,
                style: Theme.of(dialogContext).textTheme.bodySmall),
            const SizedBox(height: 14),
            TextField(
              controller: codeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 4,
              autofocus: true,
              decoration: InputDecoration(labelText: t.jobDetailStartCode),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: Text(t.jobDetailCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(codeCtrl.text.trim()),
            child: Text(t.jobDetailConfirm),
          ),
        ],
      ),
    );
  }

  /// Pushed the moment a chimney (RasoiAir) technician enters the start
  /// code on arrival — captures only the "before" reading and duct size.
  /// Returns null if the technician backs out without saving.
  Future<AirflowReading?> _askAirflowBefore(JobDetail job) => context.push<AirflowReading>(
        '/tech/job/${widget.jobId}/airflow',
        extra: (AirflowStage.before, job.customerName, job.addressLine, const AirflowReading()),
      );

  /// Pushed when completing a chimney (RasoiAir) job — seeded with the
  /// reading already captured on arrival, collects only the "after" value.
  Future<(int?, int?)> _askAirflowAfter(JobDetail job, AirflowReading before) async {
    final result = await context.push<(int, int)>(
      '/tech/job/${widget.jobId}/airflow',
      extra: (AirflowStage.after, job.customerName, job.addressLine, before),
    );
    return result ?? (null, null);
  }

  Future<void> _advanceStatus({int? suctionBefore, int? suctionAfter, String? startCode}) async {
    setState(() => _advancing = true);
    final repo = ref.read(repositoryProvider);
    if (repo is ApiRepository) {
      final result = await repo.advanceJob(widget.jobId,
          suctionBefore: suctionBefore, suctionAfter: suctionAfter, startCode: startCode);
      if (result.ok) {
        // A completed job changes this technician's real, commission-based
        // earnings — refetch so the Jobs dashboard's "Today's earnings"
        // reflects it right away rather than only after the next poll.
        unawaited(repo.fetchEarnings());
        ref.read(jobsFeedTickProvider.notifier).bump();
      } else if (mounted) {
        _toast(context, result.error ?? context.l10n.jobDetailStatusError);
      }
    }
    if (mounted) setState(() => _advancing = false);
  }

  /// Backs out of a job before heading over — real Uber/Ola/Rapido-style:
  /// puts it back in the broadcast pool (see unclaimJob/decline_booking in
  /// app.py) for any other eligible technician to claim, instead of the
  /// old single-reassign-to-one-other-technician chain a hard-assigned
  /// dispatch model needed. Only offered while still just Accepted (see
  /// the Dock below) — once actually on the way, backing out needs a real
  /// cancellation, not a quiet handoff.
  Future<void> _unclaim() async {
    setState(() => _unclaiming = true);
    final repo = ref.read(repositoryProvider);
    var ok = false;
    if (repo is ApiRepository) ok = await repo.unclaimJob(widget.jobId);
    if (!mounted) return;
    setState(() => _unclaiming = false);
    if (ok) {
      context.pop();
    } else {
      _toast(context, context.l10n.jobDetailUnclaimError);
    }
  }

  // Opens the real device camera (not a fake "fills a box in" counter),
  // shows the thumbnail immediately, then uploads it to the backend (see
  // ApiRepository.uploadJobPhoto) — completing the job now genuinely
  // depends on this having landed there (advance_booking checks for it
  // server-side), not just on a local thumbnail existing, so a failed
  // upload removes the thumbnail again and says so rather than letting the
  // technician believe the requirement was satisfied when it wasn't.
  Future<void> _capturePhoto(bool isBefore) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 80);
    if (picked == null || !mounted) return;
    final vm = ref.read((isBefore ? techBeforePhotosProvider : techAfterPhotosProvider)(widget.jobId).notifier);
    vm.add(picked.path);
    final repo = ref.read(repositoryProvider);
    final uploaded = repo is ApiRepository
        ? await repo.uploadJobPhoto(widget.jobId, isBefore: isBefore, file: File(picked.path))
        : false;
    if (!mounted) return;
    if (!uploaded) {
      vm.remove(picked.path);
      _toast(context, context.l10n.jobDetailPhotoUploadError);
    } else {
      ref.read(jobsFeedTickProvider.notifier).bump();
    }
  }

  // ---------------------------------------------------------- appliance info

  Future<void> _saveApplianceInfo({String? brand, String? modelNumber}) async {
    final repo = ref.read(repositoryProvider);
    if (repo is! ApiRepository) return;
    final ok =
        await repo.updateApplianceInfo(widget.jobId, brand: brand, modelNumber: modelNumber);
    if (!mounted) return;
    if (ok) {
      ref.read(jobsFeedTickProvider.notifier).bump();
    } else {
      _toast(context, context.l10n.jobDetailApplianceSaveError);
    }
  }

  Future<void> _pickBrand(String? current) async {
    final t = context.l10n;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Align(alignment: Alignment.centerLeft, child: Eyebrow(t.jobDetailBrand)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                children: [
                  for (final brand in kApplianceBrands)
                    ListTile(
                      title: Text(brand),
                      trailing: current == brand
                          ? Icon(Icons.check, color: Theme.of(sheetContext).colorScheme.primary)
                          : null,
                      onTap: () => Navigator.of(sheetContext).pop(brand),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == kApplianceBrandOther) {
      final custom = await _askCustomBrand();
      if (custom != null && custom.trim().isNotEmpty) _saveApplianceInfo(brand: custom.trim());
      return;
    }
    _saveApplianceInfo(brand: selected);
  }

  Future<String?> _askCustomBrand() async {
    final t = context.l10n;
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.jobDetailBrand),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: Text(t.jobDetailCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(ctrl.text),
            child: Text(t.jobDetailSave),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------------- service

  /// Lets the technician swap this job's service for a different one in the
  /// same category — e.g. the customer asks mid-visit to upgrade a filter
  /// clean into a full deep clean. Options come straight from the real
  /// backend catalog (see ApiRepository.fetchServiceOptions); the price
  /// change is server-computed, never typed in by the technician, so it
  /// can't drift from what the customer's invoice actually shows.
  Future<void> _showChangeService() async {
    if (_mutatingParts) return;
    final repo = ref.read(repositoryProvider);
    if (repo is! ApiRepository) return;
    final t = context.l10n;
    final job = repo.jobDetail(widget.jobId);
    final options = await repo.fetchServiceOptions(job.category);
    if (!mounted) return;
    if (options.isEmpty) {
      _toast(context, t.jobDetailServiceOptionsError);
      return;
    }
    final selected = await showModalBottomSheet<ServiceOptionDto>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Eyebrow(t.jobDetailChangeService),
              ),
            ),
            for (final opt in options)
              ListTile(
                title: Text(opt.displayName),
                trailing: Text(Money.rupees(opt.pricePaise)),
                selected: opt.displayName == job.service,
                onTap: () => Navigator.of(sheetContext).pop(opt),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.jobDetailChangeService),
        content: Text(t.jobDetailServiceChangeConfirm(
          job.service,
          Money.rupees(job.totalAmountPaise),
          selected.displayName,
          Money.rupees(selected.pricePaise),
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t.jobDetailCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t.jobDetailSave),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _mutatingParts = true);
    final result = await repo.changeService(widget.jobId, selected.id);
    if (!mounted) return;
    setState(() => _mutatingParts = false);
    if (result.ok) {
      ref.read(jobsFeedTickProvider.notifier).bump();
    } else {
      _toast(context, result.error ?? t.jobDetailServiceChangeError);
    }
  }

  // ------------------------------------------------------------- parts/quotes

  Future<void> _showAddPart() async {
    if (_mutatingParts) return;
    final t = context.l10n;
    final nameCtrl = TextEditingController();
    final skuCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');
    final priceCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.jobDetailAddPart),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: InputDecoration(labelText: t.jobDetailPartName),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: skuCtrl,
                decoration: InputDecoration(labelText: t.jobDetailPartSkuOptional),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: qtyCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: t.jobDetailQty),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: priceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: t.jobDetailPricePerUnit),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t.jobDetailCancel),
          ),
          FilledButton(
            onPressed: () {
              final validQty = int.tryParse(qtyCtrl.text) != null && int.parse(qtyCtrl.text) > 0;
              final validPrice = double.tryParse(priceCtrl.text) != null;
              if (nameCtrl.text.trim().isEmpty || !validQty || !validPrice) return;
              Navigator.of(dialogContext).pop(true);
            },
            child: Text(t.jobDetailSave),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final repo = ref.read(repositoryProvider);
    if (repo is! ApiRepository) return;
    setState(() => _mutatingParts = true);
    final ok = await repo.addPart(
      widget.jobId,
      name: nameCtrl.text.trim(),
      sku: skuCtrl.text.trim().isEmpty ? null : skuCtrl.text.trim(),
      qty: int.parse(qtyCtrl.text),
      pricePaise: (double.parse(priceCtrl.text) * 100).round(),
    );
    if (!mounted) return;
    setState(() => _mutatingParts = false);
    if (ok) {
      ref.read(jobsFeedTickProvider.notifier).bump();
    } else {
      _toast(context, context.l10n.jobDetailPartSaveError);
    }
  }

  Future<void> _removePart(String partId) async {
    if (_mutatingParts) return;
    final repo = ref.read(repositoryProvider);
    if (repo is! ApiRepository) return;
    setState(() => _mutatingParts = true);
    final ok = await repo.removePart(widget.jobId, partId);
    if (!mounted) return;
    setState(() => _mutatingParts = false);
    if (ok) {
      ref.read(jobsFeedTickProvider.notifier).bump();
    } else {
      _toast(context, context.l10n.jobDetailPartRemoveError);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(jobsFeedTickProvider); // rebuild once a real fetch/action lands
    final repo = ref.watch(repositoryProvider);
    final job = repo.jobDetail(widget.jobId);
    final liveStatus = repo is ApiRepository ? repo.statusOf(widget.jobId) : null;
    final beforePhotos = ref.watch(techBeforePhotosProvider(widget.jobId));
    final afterPhotos = ref.watch(techAfterPhotosProvider(widget.jobId));
    final t = context.l10n;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: context.pop),
        title: Text(widget.jobId),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(child: StatusChip(_clock, height: 30)),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                children: [
                  CareCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Blob(job.customerInitials),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(job.customerName,
                                  style: const TextStyle(
                                      fontSize: 14, fontWeight: FontWeight.w700)),
                              const SizedBox(height: 3),
                              Text('${job.addressLine}\n${job.directions}',
                                  style: context.type.bodySmall!.copyWith(height: 1.5)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (MapsConfig.isConfigured && job.lat != null && job.lng != null) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: Radii.rMd,
                      child: SizedBox(
                        height: 160,
                        child: GoogleMap(
                          initialCameraPosition: CameraPosition(
                              target: _myLocation ?? LatLng(job.lat!, job.lng!), zoom: 14),
                          onMapCreated: (c) => _mapController = c,
                          markers: {
                            Marker(
                              markerId: const MarkerId('destination'),
                              position: LatLng(job.lat!, job.lng!),
                              infoWindow: InfoWindow(title: job.customerName),
                            ),
                            if (_myLocation != null)
                              Marker(
                                markerId: const MarkerId('me'),
                                position: _myLocation!,
                                icon: BitmapDescriptor.defaultMarkerWithHue(
                                    BitmapDescriptor.hueAzure),
                                infoWindow: const InfoWindow(title: 'You'),
                              ),
                          },
                          myLocationButtonEnabled: false,
                          zoomControlsEnabled: false,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  GridView.count(
                    crossAxisCount: 4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.95,
                    children: [
                      _ActionTile(
                          glyph: '🧭',
                          label: t.jobDetailNavigate,
                          onTap: () => _openNavigation(job)),
                      _ActionTile(
                          glyph: '📞',
                          label: t.jobDetailCall,
                          onTap: () => _callCustomer(job)),
                      _ActionTile(
                          glyph: '💬',
                          label: t.jobDetailChat,
                          onTap: () => context.push('/tech/help')),
                      _ActionTile(
                          glyph: '⚑',
                          label: t.jobDetailEscalate,
                          onTap: () => context.push('/tech/help')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  CareCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Eyebrow(t.jobDetailCustomerReported),
                        const SizedBox(height: 10),
                        if (job.reportedTags.isEmpty && job.reportedQuote.trim().isEmpty)
                          Text(t.jobDetailNothingReported, style: context.type.bodySmall)
                        else ...[
                          if (job.reportedTags.isNotEmpty) ...[
                            Wrap(
                              spacing: 7,
                              runSpacing: 7,
                              children: [
                                for (final tag in job.reportedTags)
                                  StatusChip(tag, tone: ChipTone.danger, height: 28),
                              ],
                            ),
                            if (job.reportedQuote.trim().isNotEmpty) const SizedBox(height: 11),
                          ],
                          if (job.reportedQuote.trim().isNotEmpty)
                            Text('"${job.reportedQuote}"',
                                style: context.type.bodySmall!.copyWith(height: 1.55)),
                        ],
                      ],
                    ),
                  ),
                  SectionHeader(t.jobDetailServiceHeader,
                      trailing: TextButton(
                        // Mirrors the backend's own gate in
                        // update_booking_service — a Completed/Cancelled
                        // job's invoice is final, so offering this at all
                        // just invites a confusing "couldn't change"
                        // failure instead of never showing the option.
                        onPressed: _mutatingParts ||
                                job.category.trim().isEmpty ||
                                liveStatus == 'Completed' ||
                                liveStatus == 'Cancelled'
                            ? null
                            : _showChangeService,
                        child: Text(t.jobDetailChangeService),
                      )),
                  CareCard(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(job.service,
                              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                        ),
                        Text(Money.rupees(job.totalAmountPaise),
                            style: CareType.mono(context.scheme.onSurface,
                                size: 13.5, w: FontWeight.w600)),
                      ],
                    ),
                  ),
                  for (final change in job.serviceChanges) ...[
                    const SizedBox(height: 8),
                    CareCard(
                      child: Text(
                        t.jobDetailServiceChanged(
                          change.oldService,
                          Money.rupees(change.oldPricePaise),
                          change.newService,
                          Money.rupees(change.newPricePaise),
                        ),
                        style: context.type.bodySmall,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  CareCard(
                    onTap: () => context.push('/tech/job/${widget.jobId}/kitchen'),
                    child: Row(
                      children: [
                        Text('▤', style: TextStyle(fontSize: 22, color: context.scheme.primary)),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text('Kitchen Passport',
                              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                        ),
                        Icon(Icons.chevron_right, color: context.care.inkFaint),
                      ],
                    ),
                  ),
                  SectionHeader(t.jobDetailApplianceDetails),
                  CareCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.jobDetailBrand,
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        Pressable(
                          onTap: () => _pickBrand(job.brand),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                            decoration: BoxDecoration(
                              borderRadius: Radii.rMd,
                              border: Border.all(color: context.care.hairline),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  (job.brand?.trim().isNotEmpty ?? false)
                                      ? job.brand!
                                      : t.jobDetailBrandPlaceholder,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: (job.brand?.trim().isNotEmpty ?? false)
                                        ? context.scheme.onSurface
                                        : context.care.inkFaint,
                                  ),
                                ),
                                Icon(Icons.expand_more, size: 18, color: context.care.inkFaint),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(t.jobDetailModelNumber,
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _modelCtrl,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: t.jobDetailModelNumberHint,
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.check, size: 18),
                              onPressed: () =>
                                  _saveApplianceInfo(modelNumber: _modelCtrl.text.trim()),
                            ),
                          ),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (v) => _saveApplianceInfo(modelNumber: v.trim()),
                        ),
                      ],
                    ),
                  ),
                  SectionHeader(t.jobDetailPhotos),
                  Text(t.jobDetailPhotosRequired, style: context.type.bodySmall),
                  const SizedBox(height: 10),
                  GridView.count(
                    crossAxisCount: 4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1,
                    children: [
                      for (var i = 0; i < 2; i++)
                        _photoBox(context,
                            label: t.jobDetailBefore,
                            imagePath: i < beforePhotos.length ? beforePhotos[i] : null,
                            onTap: i == beforePhotos.length ? () => _capturePhoto(true) : null),
                      for (var i = 0; i < 2; i++)
                        _photoBox(context,
                            label: t.jobDetailAfter,
                            imagePath: i < afterPhotos.length ? afterPhotos[i] : null,
                            onTap: i == afterPhotos.length ? () => _capturePhoto(false) : null),
                    ],
                  ),
                  SectionHeader(t.jobDetailPartsUsed,
                      trailing: TextButton(
                        onPressed: _mutatingParts ? null : _showAddPart,
                        child: Text(t.jobDetailAddPart),
                      )),
                  if (job.parts.isEmpty)
                    Text(t.jobDetailPartsEmpty, style: context.type.bodySmall),
                  for (final part in job.parts) ...[
                    CareCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(part.name,
                                        style: const TextStyle(
                                            fontSize: 13, fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 3),
                                    Text(
                                        part.sku != null
                                            ? t.jobDetailSkuQty(part.sku!, '${part.qty}')
                                            : t.jobDetailQtyOnly('${part.qty}'),
                                        style: context.type.bodySmall),
                                  ],
                                ),
                              ),
                              Text(Money.rupees(part.pricePaise * part.qty),
                                  style: CareType.mono(context.scheme.onSurface, size: 13)),
                            ],
                          ),
                          const Divider(height: 22),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              StatusChip(
                                switch (part.status) {
                                  PartStatus.approved => t.jobDetailPartApproved,
                                  PartStatus.rejected => t.jobDetailPartRejected,
                                  PartStatus.pending => t.jobDetailPartPending,
                                },
                                tone: switch (part.status) {
                                  PartStatus.approved => ChipTone.success,
                                  PartStatus.rejected => ChipTone.danger,
                                  PartStatus.pending => ChipTone.warning,
                                },
                                height: 26,
                              ),
                              if (part.status == PartStatus.pending)
                                TextButton(
                                  onPressed: _mutatingParts ? null : () => _removePart(part.id),
                                  child: Text(t.jobDetailRemove),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
            Dock(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed:
                          _advancing ? null : () => _handlePrimaryAction(liveStatus, job),
                      child: _advancing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(_primaryLabel(t, liveStatus)),
                    ),
                  ),
                  if (liveStatus == 'Accepted') ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: _unclaiming ? null : _unclaim,
                        child: Text(t.jobDetailUnclaim),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Widget _photoBox(BuildContext context,
      {required String label, String? imagePath, VoidCallback? onTap}) {
    final filled = imagePath != null;
    final content = ClipRRect(
      borderRadius: Radii.rMd,
      child: Container(
        decoration: BoxDecoration(
          color: filled ? context.scheme.primaryContainer : context.scheme.surfaceContainerHigh,
          border: Border.all(color: context.care.hairline),
        ),
        child: filled
            ? Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(File(imagePath), fit: BoxFit.cover),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Icon(Icons.check_circle,
                        size: 16, color: context.scheme.primary, shadows: const [
                      Shadow(color: Colors.black45, blurRadius: 3),
                    ]),
                  ),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_a_photo_outlined, size: 18, color: context.care.inkFaint),
                  const SizedBox(height: 4),
                  Text(label, style: TextStyle(fontSize: 10.5, color: context.care.inkFaint)),
                ],
              ),
      ),
    );
    return onTap == null ? content : Pressable(onTap: onTap, scale: 0.94, child: content);
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.glyph, required this.label, required this.onTap});
  final String glyph, label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        scale: 0.94,
        child: Container(
          decoration: BoxDecoration(
            color: context.scheme.surface,
            borderRadius: Radii.rMd,
            border: Border.all(color: context.care.hairline),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(glyph, style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
}
