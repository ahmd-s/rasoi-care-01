// Starts/stops periodic GPS reporting to Firestore for the Customer app's
// live tracking screen — see technician_location_service.dart for the write
// itself and its Firestore document contract.
//
// This listens to [jobsFeedTickProvider] (bumped by the UI after every real
// fetch/action against [repositoryProvider] completes — see providers.dart)
// rather than being driven directly by screens, so on-duty toggles, job
// acceptance, and job-status advances all naturally trigger a re-check no
// matter which screen performed them. Nothing needs to call this directly;
// a screen just needs to `ref.watch` it once, while mounted, to keep it
// alive for as long as the technician is in the jobs flow (see
// tech_jobs_screen.dart, whose route is never disposed while job
// detail/close are pushed on top of it).
//
// NOTE: Current implementation uses Timer.periodic which may be paused by the
// OS when the app is backgrounded. For reliable background tracking, a native
// Android foreground service would be required, which is beyond the scope of
// the current Flutter-only architecture. The existing implementation works
// reliably while the app is in the foreground.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../data/api/api_repository.dart';
import '../data/firebase/technician_location_service.dart';
import 'providers.dart';

/// Reports live GPS to Firestore while the technician is on-duty AND has at
/// least one active job (`Accepted` / `On the way` / `In Progress`). Value
/// reflects whether reporting is currently running.
///
/// Best-effort only, matching every other Firestore write in this codebase:
/// a location-permission denial, a GPS fix failure, or a Firestore write
/// failure just means nothing gets reported this tick — it never blocks the
/// on-duty toggle or job-status advancement, and never crashes the app.
final technicianLocationReporterProvider =
    NotifierProvider<TechnicianLocationReporterVM, bool>(
        TechnicianLocationReporterVM.new);

class TechnicianLocationReporterVM extends Notifier<bool> {
  final _service = TechnicianLocationService();
  Timer? _timer;

  /// Set once a permission request has been denied this session, so we
  /// don't re-prompt the technician on every subsequent on-duty/job tick.
  bool _permissionDenied = false;

  /// True while a permission/service check from [_start] is in flight, so a
  /// second resync landing before it resolves (e.g. two rapid bumps) can't
  /// kick off a duplicate timer.
  bool _starting = false;

  @override
  bool build() {
    ref.listen<int>(jobsFeedTickProvider, (_, _) => _resync());
    ref.onDispose(() => _timer?.cancel());
    return false;
  }

  void _resync() {
    final shouldRun = _shouldRun();
    if (shouldRun == state) return;
    if (shouldRun) {
      unawaited(_start());
    } else {
      _stop();
    }
  }

  Future<void> _start() async {
    if (_permissionDenied || _starting || _timer != null) return;
    _starting = true;
    try {
      try {
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          _permissionDenied = true;
          return;
        }
        if (!await Geolocator.isLocationServiceEnabled()) return;
      } catch (_) {
        return; // best-effort — e.g. no location support on this device
      }

      // A resync (another job completing, going off-duty) may have landed
      // while the permission prompt was up — don't start reporting into a
      // state that's no longer current.
      if (!_shouldRun()) return;

      state = true;
      unawaited(_report()); // first fix right away, don't wait a full tick
      _timer = Timer.periodic(const Duration(seconds: 15), (_) => _report());
    } finally {
      _starting = false;
    }
  }

  /// Public method to manually restart tracking (e.g., after app returns from
  /// background). This is a no-op if tracking is already running or conditions
  /// are not met. Call this from app lifecycle observers if needed.
  Future<void> restartIfEligible() async {
    _resync();
  }

  bool _shouldRun() {
    final repo = ref.read(repositoryProvider);
    if (repo is! ApiRepository) return false;
    return repo.techStats().onDuty && repo.hasActiveJob();
  }

  Future<void> _report() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 10));
      await _service.pushLocation(lat: pos.latitude, lng: pos.longitude);
    } catch (_) {
      // Best-effort — a missed GPS fix just means we skip this tick.
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    state = false;
    unawaited(_service.clearLocation());
  }
}
