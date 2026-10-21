// Starts/stops GPS reporting to the authenticated backend for the Customer
// app's live tracking screen — see technician_location_service.dart.
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
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../data/api/api_repository.dart';
import '../data/firebase/technician_location_service.dart';
import 'providers.dart';

/// Reports live GPS to the backend while the technician is on-duty AND has at
/// least one active job (`Accepted` / `On the way` / `In Progress`). Value
/// reflects whether reporting is currently running.
///
/// Best-effort only: a location-permission denial, a GPS fix failure, or a
/// backend write failure means an update is missed — it never blocks the
/// on-duty toggle or job-status advancement, and never crashes the app.
final technicianLocationReporterProvider =
    NotifierProvider<TechnicianLocationReporterVM, bool>(
        TechnicianLocationReporterVM.new);

class TechnicianLocationReporterVM extends Notifier<bool> {
  final _service = TechnicianLocationService();
  StreamSubscription<Position>? _positionSubscription;

  /// Set once a permission request has been denied this session, so we
  /// don't re-prompt the technician on every subsequent on-duty/job tick.
  bool _permissionDenied = false;

  /// True while a permission/service check from [_start] is in flight, so a
  /// second resync landing before it resolves (e.g. two rapid bumps) can't
  /// start a duplicate location stream.
  bool _starting = false;

  @override
  bool build() {
    ref.listen<int>(jobsFeedTickProvider, (_, _) => _resync());
    ref.onDispose(() {
      unawaited(_positionSubscription?.cancel());
      unawaited(_service.clearLocation());
    });
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
    if (_permissionDenied || _starting || _positionSubscription != null) return;
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

      final LocationSettings settings = defaultTargetPlatform == TargetPlatform.android
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
              intervalDuration: const Duration(seconds: 15),
              foregroundNotificationConfig: const ForegroundNotificationConfig(
                notificationTitle: 'Rasoi Care location sharing',
                notificationText:
                    'Your live location is shared with the customer for your active job.',
                notificationChannelName: 'Active job location',
                enableWakeLock: false,
                setOngoing: true,
              ),
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            );
      try {
        _positionSubscription = Geolocator.getPositionStream(
          locationSettings: settings,
        ).listen(
          (position) async {
            final ok = await _service.pushLocation(
              lat: position.latitude,
              lng: position.longitude,
            );
            // The backend is the authority on eligibility (approved, on
            // duty, active job): if it refuses, stop sharing.
            if (!ok && _positionSubscription != null) _stop();
          },
          onError: (_) {
            _positionSubscription?.cancel();
            _positionSubscription = null;
            state = false;
          },
        );
      } catch (_) {
        state = false;
        return;
      }
      state = true;
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

  /// Stops sharing and clears the stored fix. Awaited before sign-out so the
  /// DELETE still carries a valid token.
  Future<void> stopAndClear() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    state = false;
    await _service.clearLocation();
  }

  bool _shouldRun() {
    final repo = ref.read(repositoryProvider);
    if (repo is! ApiRepository) return false;
    return repo.techStats().onDuty && repo.hasActiveJob();
  }

  void _stop() {
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = null;
    state = false;
    unawaited(_service.clearLocation());
  }
}
