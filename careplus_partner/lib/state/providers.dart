// Riverpod wiring. The repository provider is the single place you change to
// go from mock data to a real backend.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api/api_repository.dart';
import '../data/api/passport_api.dart';
import '../data/api/vision_api.dart';
import '../data/local/biometric_service.dart';
import '../data/repository.dart';
import '../features/jobs/airflow_check_screen.dart';
import '../features/passport/photo_source.dart';

/// Live-backend-backed repository. It falls back to
/// [MockPartnerRepository]-shaped data internally for anything the server
/// doesn't have and for any failed request — see ApiRepository's header
/// comment. A single instance lives for the app's lifetime so its request
/// cache survives screen rebuilds; watch [jobsFeedTickProvider] to rebuild
/// after its async methods complete.
final repositoryProvider = Provider<PartnerRepository>((ref) => ApiRepository());

/// Bumped by the UI after every real fetch/action against
/// [repositoryProvider] (cast to [ApiRepository]) completes. The repository
/// interface itself stays synchronous, so this is the signal that tells
/// screens watching it to rebuild and re-read the (mutated in place) cache
/// — see tech_jobs_screen.dart / tech_job_screen.dart.
final jobsFeedTickProvider = NotifierProvider<JobsFeedTickVM, int>(JobsFeedTickVM.new);

class JobsFeedTickVM extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

/// App-wide light/dark toggle. Persist to shared_preferences in production.
final themeModeProvider = NotifierProvider<ThemeModeVM, ThemeMode>(ThemeModeVM.new);

class ThemeModeVM extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.light;
  void toggle() =>
      state = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
  set(ThemeMode m) => state = m;
}

// ---------------------------------------------------------------------------
// Chimney (RasoiAir) airflow "before" reading — captured once, at arrival,
// when the technician enters the customer's start code (see
// TechJobScreen._handlePrimaryAction). Held here, keyed by jobId, until the
// job's completion screen needs it to seed the "after" reading and compute
// the improvement — the backend only accepts suctionBefore/suctionAfter
// together, at the final Completed transition, so this is what bridges the
// gap between when the reading is actually taken and when it's submitted.
// ---------------------------------------------------------------------------
final techAirflowBeforeProvider = NotifierProvider.family<TechAirflowBeforeVM,
    AirflowReading?, String>(TechAirflowBeforeVM.new);

class TechAirflowBeforeVM extends FamilyNotifier<AirflowReading?, String> {
  @override
  AirflowReading? build(String arg) => null;
  void set(AirflowReading reading) => state = reading;
}

/// The before/after photos actually captured (via the device camera) for a
/// job — up to 2 each, local file paths. Real capture, not a fake counter:
/// see _capturePhoto in tech_job_screen.dart.
final techBeforePhotosProvider =
    NotifierProvider.family<JobPhotosVM, List<String>, String>(JobPhotosVM.new);
final techAfterPhotosProvider =
    NotifierProvider.family<JobPhotosVM, List<String>, String>(JobPhotosVM.new);

class JobPhotosVM extends FamilyNotifier<List<String>, String> {
  @override
  List<String> build(String arg) => const [];
  void add(String path) {
    if (state.length < 2) state = [...state, path];
  }

  /// Rolls back a capture whose backend upload failed — see _capturePhoto
  /// in tech_job_screen.dart. Without this, a failed upload would still
  /// show the thumbnail as "done" even though completing the job actually
  /// depends on the backend having received it.
  void remove(String path) {
    state = state.where((p) => p != path).toList(growable: false);
  }
}

/// Whether this device should get job-critical updates over WhatsApp —
/// a real, persisted device preference (see More tab). What it doesn't do,
/// because there's no WhatsApp Business API wired into this backend yet,
/// is actually deliver anything over WhatsApp — the preference is real,
/// the delivery channel behind it isn't built. Defaults to off — WhatsApp
/// messaging requires the technician's opt-in consent, not an opt-out
/// toggle — until the real stored value (if any) loads.
final whatsappUpdatesProvider =
    NotifierProvider<WhatsAppUpdatesVM, bool>(WhatsAppUpdatesVM.new);

class WhatsAppUpdatesVM extends Notifier<bool> {
  static const _key = 'whatsapp_updates_enabled';

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getBool(_key);
    if (stored != null) state = stored;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

/// The app's display language — a real, persisted device preference, not
/// just a menu row. Defaults to the device's own language when it's one we
/// support (English/Hindi today), else falls back to English, until the
/// real stored choice (if any) loads. Data that actually came from the
/// server — a customer's name, an address a technician typed — is never
/// translated; only this app's own UI chrome changes.
/// Fingerprint/face unlock — see BiometricService for what "enabled" means
/// on top of just "the phone has biometric hardware".
final biometricServiceProvider =
    Provider<BiometricService>((ref) => BiometricService());

/// Whether this account has actually turned biometric login on — offered
/// once right after sign-up and toggleable in the More tab. Defaults to
/// off until the real stored value (if any) loads.
final biometricEnabledProvider =
    NotifierProvider<BiometricEnabledVM, bool>(BiometricEnabledVM.new);

class BiometricEnabledVM extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    state = await ref.read(biometricServiceProvider).isEnabled();
  }

  Future<void> set(bool value) async {
    state = value;
    await ref.read(biometricServiceProvider).setEnabled(value);
  }
}

/// Whether this device actually has usable biometric hardware — gates
/// whether the More tab even shows the biometric login row.
final biometricSupportedProvider = FutureProvider<bool>(
  (ref) => ref.watch(biometricServiceProvider).isDeviceSupported(),
);

final localeProvider = NotifierProvider<LocaleVM, Locale>(LocaleVM.new);

const supportedLocales = [Locale('en'), Locale('hi')];

class LocaleVM extends Notifier<Locale> {
  static const _key = 'app_locale';

  @override
  Locale build() {
    _load();
    return const Locale('en');
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    if (stored != null) {
      final match = supportedLocales.where((l) => l.languageCode == stored);
      if (match.isNotEmpty) {
        state = match.first;
        return;
      }
    }
    final deviceCode = PlatformDispatcher.instance.locale.languageCode;
    final deviceMatch = supportedLocales.where((l) => l.languageCode == deviceCode);
    if (deviceMatch.isNotEmpty) state = deviceMatch.first;
  }

  Future<void> set(Locale locale) async {
    state = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, locale.languageCode);
  }
}

// ---------------------------------------------------------------------------
// Kitchen Passport (V9.7) — see lib/features/passport.
// ---------------------------------------------------------------------------
final passportApiProvider = Provider<PassportApi>((ref) => PassportApi());

/// Vision AI photo inspection (server-mediated; no provider credential here).
final visionApiProvider = Provider<VisionApi>((ref) => VisionApi());
final photoSourceProvider = Provider<PhotoSource>((ref) => ImagePickerPhotoSource());

/// Appliances already registered for the customer of job [jobId]. Errors
/// carry a user-presentable message (see PassportApi).
final kitchenAppliancesProvider = FutureProvider.autoDispose
    .family<List<KitchenAppliance>, String>((ref, jobId) async {
  final r = await ref.watch(passportApiProvider).kitchenFor(jobId);
  if (!r.ok) throw PassportException(r.error!);
  return r.value!;
});

/// Kitchen-level health for the customer of job [jobId] (read-only, computed
/// on the server from the saved checklists).
final kitchenHealthProvider =
    FutureProvider.autoDispose.family<KitchenHealth, String>((ref, jobId) async {
  final r = await ref.watch(passportApiProvider).kitchenHealth(jobId);
  if (!r.ok) throw PassportException(r.error!);
  return r.value!;
});

class PassportException implements Exception {
  const PassportException(this.message);
  final String message;
  @override
  String toString() => message;
}
