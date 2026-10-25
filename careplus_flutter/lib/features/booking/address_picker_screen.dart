// Pick a service address with a real GPS pin — pushed from AddressScreen's
// "+ Add a new address" button. Two entirely different bodies live in this
// one screen, split by [MapsConfig.isConfigured]:
//
//   - not configured: today's level of address entry (a label + a free-text
//     line, no coordinates) — just moved into its own screen instead of
//     being a dead `onTap: () {}`, so the flow isn't a dead end while no
//     Maps key exists.
//   - configured: a draggable GoogleMap ("pan the map to place the pin"), a
//     Places Autocomplete search bar, and a "use my current location"
//     button — native map rendering plus authenticated backend requests for
//     Places Autocomplete and Geocoding. The web-service key stays on server.
//
// Either way, confirming pops the screen with a [SavedAddress] the caller
// (AddressScreen) hands to BookingDraftVM.setPickedAddress.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../../core/config/maps_config.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../core/widgets/care_widgets.dart';
import '../../data/api/api_config.dart';
import '../../data/models.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/firestore_providers.dart';

/// Reverse-geocodes a point to a human-readable line — shared by
/// _MapPickerBody's own resolving (as someone pans the map) and
/// SelectLocationScreen's "Use Current Location" fast path (which skips
/// the map entirely). Falls back to a bare lat/lng string on any failure.
Future<Map<String, dynamic>?> _mapsRequest(
  String endpoint,
  Map<String, String> query,
) async {
  try {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) return null;
    final uri = Uri.parse('${ApiConfig.baseUrl}/api/maps/$endpoint')
        .replace(queryParameters: query);
    final response = await http.get(uri, headers: {
      'Authorization': 'Bearer $token',
    }).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

Future<String> resolveAreaLine(double lat, double lng) async {
  try {
    final decoded = await _mapsRequest('geocode', {
      'lat': '$lat',
      'lng': '$lng',
    });
    final results = decoded?['results'];
    if (results is List && results.isNotEmpty) {
      final first = results.first;
      if (first is Map<String, dynamic>) {
        final formatted = first['formatted_address'] as String?;
        if (formatted != null) return formatted;
      }
    }
  } catch (_) {
    // Falls through to the lat/lng string below.
  }
  return '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
}

class AddressPickerScreen extends StatelessWidget {
  const AddressPickerScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: context.pop),
          title: Text(context.l10n.addressPickerTitle),
        ),
        body: SafeArea(
          top: false,
          child: MapsConfig.isConfigured ? const _MapPickerBody() : const _ManualEntryBody(),
        ),
      );
}

// ============================================================ FALLBACK
// No Maps key yet — a plain label + address-line form, styled like every
// other step in the booking flow.
class _ManualEntryBody extends StatefulWidget {
  const _ManualEntryBody();
  @override
  State<_ManualEntryBody> createState() => _ManualEntryBodyState();
}

class _ManualEntryBodyState extends State<_ManualEntryBody> {
  final _formKey = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _line = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    _line.dispose();
    super.dispose();
  }

  void _confirm() {
    if (!_formKey.currentState!.validate()) return;
    final address = SavedAddress(
      'a_picked_${DateTime.now().millisecondsSinceEpoch}',
      _label.text.trim(),
      _line.text.trim(),
      '📍',
      // No map configured — no coordinates to attach. See SavedAddress's
      // doc comment in lib/data/models.dart.
    );
    context.pop(address);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            children: [
              Text(t.addressPickerManualIntro, style: context.type.bodyMedium),
              const SizedBox(height: 20),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    CareField(t.addressPickerLabelField,
                        controller: _label,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? t.addressPickerLabelRequired
                            : null),
                    const SizedBox(height: 14),
                    CareField(t.addressPickerFullAddressField,
                        controller: _line,
                        maxLines: 3,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? t.addressPickerFullAddressRequired
                            : null),
                  ],
                ),
              ),
            ],
          ),
        ),
        Dock(
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _confirm, child: Text(t.addressPickerSaveAddress)),
          ),
        ),
      ],
    );
  }
}

// ============================================================ ADDRESS DETAILS
// Pushed once a pin is confirmed on the map — a structured form (type,
// building/floor, street, a custom label) instead of handing back nothing
// but a raw reverse-geocoded line. Pops with the final [SavedAddress];
// _MapPickerBody._confirm forwards that result on as its own pop, so
// nothing about the caller (AddressScreen / HomeScreen) changes.
class AddressDetailsScreen extends ConsumerStatefulWidget {
  const AddressDetailsScreen(
      {super.key, required this.lat, required this.lng, required this.resolvedArea});
  final double lat;
  final double lng;
  final String resolvedArea;

  @override
  ConsumerState<AddressDetailsScreen> createState() => _AddressDetailsScreenState();
}

class _AddressDetailsScreenState extends ConsumerState<AddressDetailsScreen> {
  // Internal keys — never shown as-is; see _typeLabel for the real,
  // localized display text. Kept in English so _glyphByType's lookup and
  // the _type == t comparisons below stay simple and stable regardless of
  // locale.
  static const _types = ['House', 'Office', 'Other'];
  static const _glyphByType = {'House': '🏠', 'Office': '💼', 'Other': '📍'};

  String _typeLabel(String type, AppLocalizations t) => switch (type) {
        'House' => t.addressDetailsTypeHouse,
        'Office' => t.addressDetailsTypeOffice,
        _ => t.addressDetailsTypeOther,
      };

  final _formKey = GlobalKey<FormState>();
  final _building = TextEditingController();
  final _street = TextEditingController();
  final _pincode = TextEditingController();
  final _saveAs = TextEditingController();
  String _type = 'House';
  File? _photo;
  bool _saving = false;
  bool _saveAsSeeded = false;

  @override
  void dispose() {
    _building.dispose();
    _street.dispose();
    _pincode.dispose();
    _saveAs.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final t = context.l10n;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: Text(t.addressDetailsTakePhoto),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(t.addressDetailsChooseGallery),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85);
    if (picked != null && mounted) setState(() => _photo = File(picked.path));
  }

  Future<void> _confirm() async {
    if (!_formKey.currentState!.validate()) return;
    final t = context.l10n;
    setState(() => _saving = true);
    final line = [
      if (_building.text.trim().isNotEmpty) _building.text.trim(),
      if (_street.text.trim().isNotEmpty) _street.text.trim(),
      widget.resolvedArea,
    ].join(', ');
    final label = _saveAs.text.trim().isEmpty ? _typeLabel(_type, t) : _saveAs.text.trim();
    final id = 'a_picked_${DateTime.now().millisecondsSinceEpoch}';
    final profileService = ref.read(userProfileServiceProvider);
    String? photoUrl;
    if (_photo != null) {
      photoUrl = await profileService.uploadAddressPhoto(_photo!, id);
    }
    final address = SavedAddress(id, label, line, _glyphByType[_type]!, widget.lat, widget.lng,
        _pincode.text.trim().isEmpty ? null : _pincode.text.trim(), photoUrl);
    // Best-effort — persisting it for next time shouldn't block handing
    // the address to whoever's waiting on this pick right now.
    unawaited(profileService.addAddress(address));
    if (!mounted) return;
    Navigator.pop(context, address);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    // Seeds the "Save address as" field with the real, localized label for
    // the default type — once only, same reasoning as ServiceDetailScreen's
    // _seeded flag, so a person's own edit is never silently overwritten
    // on a later rebuild.
    if (!_saveAsSeeded) {
      _saveAs.text = _typeLabel(_type, t);
      _saveAsSeeded = true;
    }
    return Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => Navigator.pop(context)),
          title: Text(t.addressDetailsTitle),
        ),
        body: SafeArea(
          top: false,
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              children: [
                SectionHeader(t.addressDetailsLocationType),
                Row(children: [
                  for (final type in _types) ...[
                    ChoiceTag(_typeLabel(type, t),
                        selected: _type == type, onTap: () => setState(() => _type = type)),
                    const SizedBox(width: 8),
                  ],
                ]),
                const SizedBox(height: 20),
                CareField(t.addressDetailsBuildingField,
                    controller: _building,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? t.addressDetailsBuildingRequired
                        : null),
                const SizedBox(height: 14),
                CareField(t.addressDetailsStreetField, controller: _street),
                const SizedBox(height: 14),
                CareCard(
                  child: Row(children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Eyebrow(t.addressDetailsAreaEyebrow),
                          const SizedBox(height: 4),
                          Text(widget.resolvedArea, style: context.type.bodyMedium),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
                      label: Text(t.addressDetailsChange),
                    ),
                  ]),
                ),
                const SizedBox(height: 14),
                CareField(t.addressDetailsPincodeField,
                    controller: _pincode,
                    keyboardType: TextInputType.number,
                    validator: (v) => (v != null && v.trim().isNotEmpty && v.trim().length != 6)
                        ? t.addressDetailsPincodeInvalid
                        : null),
                const SizedBox(height: 14),
                CareField(t.addressDetailsSaveAsField,
                    controller: _saveAs,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? t.addressDetailsSaveAsRequired
                        : null),
                const SizedBox(height: 20),
                SectionHeader(t.addressDetailsPhotoHeader),
                Text(t.addressDetailsPhotoHint, style: context.type.bodySmall),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: _pickPhoto,
                  child: Container(
                    height: 110,
                    decoration: BoxDecoration(
                      color: context.scheme.surfaceContainerHigh,
                      borderRadius: Radii.rMd,
                      border: Border.all(color: context.care.hairline),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _photo == null
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add_a_photo_outlined,
                                    size: 22, color: context.care.inkFaint),
                                const SizedBox(height: 6),
                                Text(t.addressDetailsAddPhoto, style: context.type.bodySmall),
                              ],
                            ),
                          )
                        : Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.file(_photo!, fit: BoxFit.cover),
                              Positioned(
                                right: 6,
                                top: 6,
                                child: GestureDetector(
                                  onTap: () => setState(() => _photo = null),
                                  child: const CircleAvatar(
                                    radius: 12,
                                    backgroundColor: Colors.black54,
                                    child: Icon(Icons.close, size: 14, color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
            child: FilledButton(
              onPressed: _saving ? null : _confirm,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(t.addressPickerSaveAddress),
            ),
          ),
        ),
      );
  }
}

// ============================================================ MAP PICKER
// Only reachable once MapsConfig.isConfigured is true — every call here
// assumes a working API key.
class _MapPickerBody extends StatefulWidget {
  const _MapPickerBody();
  @override
  State<_MapPickerBody> createState() => _MapPickerBodyState();
}

class _MapPickerBodyState extends State<_MapPickerBody> {
  static const _timeout = Duration(seconds: 8);
  static const _fallbackCenter = LatLng(19.9975, 73.7898); // Nashik — same city as the mock addresses

  final _searchController = TextEditingController();
  GoogleMapController? _mapController;
  LatLng _center = _fallbackCenter;
  String? _resolvedLine;
  bool _resolving = false;
  bool _locating = false;
  List<_PlaceSuggestion> _suggestions = [];
  Timer? _debounce;
  // Set only on a real API-level failure (a rejected/misconfigured key,
  // quota exceeded) — never for a plain "nothing matched" search, which
  // Google reports as a 200 with an empty predictions list, not an error.
  // Without this, the two looked identical: the dropdown just never
  // appeared and the pin could never be moved by typing, with nothing to
  // tell the person (or whoever's debugging it) why.
  String? _searchError;

  @override
  void initState() {
    super.initState();
    // Auto-locate on open instead of sitting on the fallback city center —
    // silent because a permission prompt or GPS miss on first load
    // shouldn't greet the person with an error before they've done anything.
    _useCurrentLocation(silent: true);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _reverseGeocode(LatLng point) async {
    setState(() => _resolving = true);
    _resolvedLine = await resolveAreaLine(point.latitude, point.longitude);
    if (mounted) setState(() => _resolving = false);
  }

  Future<void> _search(String query) async {
    _debounce?.cancel();
    if (query.trim().length < 3) {
      setState(() {
        _suggestions = [];
        _searchError = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final decoded = await _mapsRequest('autocomplete', {'input': query});
        final predictions = decoded?['predictions'];
        if (predictions is List) {
          final parsed = predictions
              .whereType<Map<String, dynamic>>()
              .map(_PlaceSuggestion.fromJson)
              .whereType<_PlaceSuggestion>()
              .toList();
          if (mounted) {
            setState(() {
              _suggestions = parsed;
              _searchError = null;
            });
          }
          return;
        }
        if (mounted) setState(() => _searchError = context.l10n.mapPickerSearchError);
      } catch (_) {
        // Best-effort — an empty suggestion list just means no dropdown.
      }
      if (mounted) setState(() => _suggestions = []);
    });
  }

  Future<void> _selectSuggestion(_PlaceSuggestion s) async {
    setState(() {
      _suggestions = [];
      _searchController.text = s.description;
    });
    try {
      final decoded = await _mapsRequest('geocode', {'placeId': s.placeId});
      final results = decoded?['results'];
      if (results is List && results.isNotEmpty) {
        final first = results.first;
        if (first is Map<String, dynamic>) {
          final lat = (first['lat'] as num?)?.toDouble();
          final lng = (first['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) {
            final point = LatLng(lat, lng);
            setState(() {
              _center = point;
              _resolvedLine = first['formatted_address'] as String? ?? s.description;
            });
            await _mapController?.animateCamera(CameraUpdate.newLatLng(point));
            return;
          }
        }
      }
    } catch (_) {
      // Best-effort — the pin just stays put if this fails.
    }
  }

  // [silent] is used for the automatic on-open attempt: permission prompts
  // still happen (so it can actually succeed), but a denial/failure just
  // quietly falls back to resolving an address for the default center
  // instead of greeting the person with an error before they've done
  // anything. An explicit tap on the location button always reports back.
  Future<void> _useCurrentLocation({bool silent = false}) async {
    setState(() => _locating = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.mapPickerPermissionDenied)));
        }
        if (silent) await _reverseGeocode(_center);
        return;
      }
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.mapPickerServiceDisabled)));
        }
        if (silent) await _reverseGeocode(_center);
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
      ).timeout(_timeout);
      final point = LatLng(position.latitude, position.longitude);
      setState(() => _center = point);
      await _mapController?.animateCamera(CameraUpdate.newLatLng(point));
      await _reverseGeocode(point);
    } catch (_) {
      // Degrade to manual pin placement — never dead-end the flow.
      if (!silent && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.l10n.mapPickerLocationError)));
      }
      if (silent) await _reverseGeocode(_center);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  // The pin only gives a rough reverse-geocoded line — pushes into a
  // details form (building/floor, street, a House/Office/Other type, a
  // custom label) before this screen itself pops with the fully composed
  // address, same as before from the caller's point of view.
  Future<void> _confirm() async {
    final line = _resolvedLine ??
        '${_center.latitude.toStringAsFixed(5)}, ${_center.longitude.toStringAsFixed(5)}';
    final result = await Navigator.of(context).push<SavedAddress>(
      MaterialPageRoute(
        builder: (_) => AddressDetailsScreen(
            lat: _center.latitude, lng: _center.longitude, resolvedArea: line),
      ),
    );
    if (result != null && context.mounted) context.pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
            child: CareField(t.mapPickerSearchHint,
                controller: _searchController,
                prefix: const Icon(Icons.search),
                suffix: _locating
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                    : IconButton(
                        icon: const Icon(Icons.my_location),
                        tooltip: t.mapPickerUseCurrentLocation,
                        onPressed: _locating ? null : _useCurrentLocation,
                      ),
                onChanged: _search),
          ),
          if (_searchError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(_searchError!,
                  style: context.type.bodySmall?.copyWith(color: context.scheme.error)),
            )
          else if (_suggestions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: CareCard(
                padding: EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final s in _suggestions)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.place_outlined, size: 18),
                        title: Text(s.description, style: context.type.bodySmall),
                        onTap: () => _selectSuggestion(s),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 10),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(target: _center, zoom: 16),
                  onMapCreated: (c) => _mapController = c,
                  onCameraMove: (pos) => _center = pos.target,
                  onCameraIdle: () => _reverseGeocode(_center),
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                ),
                // Fixed center pin — the map pans underneath it, so wherever
                // it points is the address being picked.
                IgnorePointer(
                  child: Icon(Icons.location_on, size: 42, color: context.scheme.primary,
                      shadows: const [Shadow(blurRadius: 6, color: Colors.black38)]),
                ),
                // A second, clearly-labelled way to re-center on GPS — the
                // search bar's icon is easy to miss, this one isn't.
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: FloatingActionButton.small(
                    heroTag: 'address-picker-locate-me',
                    onPressed: _locating ? null : () => _useCurrentLocation(),
                    tooltip: t.mapPickerUseCurrentLocation,
                    child: _locating
                        ? const SizedBox(
                            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.my_location),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Text(
              t.mapPickerPanHint,
              style: context.type.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
          Dock(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_resolving)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(t.mapPickerFindingAddress, style: context.type.bodySmall),
                  )
                else if (_resolvedLine != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_resolvedLine!,
                        style: context.type.bodySmall, textAlign: TextAlign.center),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                      onPressed: _confirm, child: Text(t.mapPickerConfirmLocation)),
                ),
              ],
            ),
          ),
        ],
      );
  }
}

class _PlaceSuggestion {
  const _PlaceSuggestion(this.placeId, this.description);
  final String placeId;
  final String description;

  static _PlaceSuggestion? fromJson(Map<String, dynamic> json) {
    final placeId = json['place_id'] as String?;
    final description = json['description'] as String?;
    if (placeId == null || description == null) return null;
    return _PlaceSuggestion(placeId, description);
  }
}
