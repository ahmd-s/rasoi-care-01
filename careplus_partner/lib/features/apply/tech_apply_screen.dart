// Self-signup application — modelled directly on Urban Company's Partner
// app "Tell us about yourself" screen: name (validated), a work-category
// dropdown, a city dropdown, and a terms checkbox before continuing, plus
// (on later steps, collapsed into one screen here) an ID document and
// payout bank + PAN details. All reviewed by an admin before the
// technician is verified and starts appearing in the real job feed — see
// TechPendingScreen for what happens right after submitting.
//
// Also reused for editing an already-submitted application (see
// TechProfileScreen's "Edit" action) — [existing] prefills every field from
// the technician's current record, and a re-picked photo/ID document is the
// only thing that overwrites what's already on file; everything else is
// just a normal field update via the same PATCH /api/technician/me call.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/auth/auth_service.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/auth_providers.dart';
import 'application_uploads.dart';
import 'aadhaar_ocr.dart';

/// IFSC decodes to a bank + branch via Razorpay's free, public, no-key-
/// needed lookup — real-time confirmation that a typo'd code gets caught
/// before submitting, not a substitute for actual account-ownership
/// verification (that needs a paid penny-drop KYC vendor this app doesn't
/// have credentials for).
final _ifscFormatRe = RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$');

const _categoryOptions = [
  ('RasoiAir', 'Chimney'),
  ('RasoiSpark', 'Hob / Cooktop'),
  ('RasoiWash', 'Dishwasher'),
  ('RasoiBuilt', 'Microwave / OTG'),
  ('RasoiChill', 'Refrigerator'),
  ('RasoiPure', 'Water purifier'),
];

// The cities Rasoi Care actually operates in today — same idea as UC's city
// picker, just a real (short) list instead of a free-text field, so a typo
// can't put someone in an area nobody's routing jobs for.
const _cities = ['Nashik', 'Pune', 'Mumbai', 'Nagpur', 'Aurangabad'];

final _nameCharsRe = RegExp(r'^[A-Za-z ]*$');

/// A technician can be skilled in more than one appliance category, so this
/// prefills from the new `categories` list the backend returns; a record
/// saved before that existed only has the old single `category` field.
Set<String> _initialCategories(Map<String, dynamic>? existing) {
  final raw = existing?['categories'];
  if (raw is List && raw.isNotEmpty) {
    return raw.map((e) => e.toString()).toSet();
  }
  final single = existing?['category'] as String?;
  return single == null || single.isEmpty ? {} : {single};
}

class TechApplyScreen extends ConsumerStatefulWidget {
  const TechApplyScreen({super.key, this.existing});
  final Map<String, dynamic>? existing;
  @override
  ConsumerState<TechApplyScreen> createState() => _TechApplyScreenState();
}

class _TechApplyScreenState extends ConsumerState<TechApplyScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _nameCtrl = TextEditingController(text: widget.existing?['name'] as String? ?? '');
  late final _experienceCtrl = TextEditingController(
      text: widget.existing?['experienceYears'] != null
          ? '${widget.existing!['experienceYears']}'
          : '');
  late final _bankNameCtrl =
      TextEditingController(text: widget.existing?['bankAccountName'] as String? ?? '');
  late final _bankAccountCtrl =
      TextEditingController(text: widget.existing?['bankAccountNumber'] as String? ?? '');
  late final _bankIfscCtrl =
      TextEditingController(text: widget.existing?['bankIfsc'] as String? ?? '');
  late final _panCtrl =
      TextEditingController(text: widget.existing?['panNumber'] as String? ?? '');
  late final _gstCtrl =
      TextEditingController(text: widget.existing?['gstNumber'] as String? ?? '');
  late final _aadharCtrl =
      TextEditingController(text: widget.existing?['aadharNumber'] as String? ?? '');
  late final _dobCtrl =
      TextEditingController(text: widget.existing?['dateOfBirth'] as String? ?? '');
  late final _emergencyNameCtrl =
      TextEditingController(text: widget.existing?['emergencyContactName'] as String? ?? '');
  late final _emergencyPhoneCtrl =
      TextEditingController(text: widget.existing?['emergencyContactPhone'] as String? ?? '');
  late final _addressCtrl =
      TextEditingController(text: widget.existing?['address'] as String? ?? '');
  late final _upiCtrl = TextEditingController(text: widget.existing?['upiId'] as String? ?? '');
  late final Set<String> _categories = _initialCategories(widget.existing);
  late String? _employmentType = widget.existing?['employmentType'] as String?;

  /// The backend only ever writes employmentType while an application is
  /// still unsubmitted (see app.py's update_technician_me) — once true,
  /// the choice is permanent, so the form shows it read-only instead of a
  /// picker that would silently do nothing.
  bool get _employmentTypeLocked => widget.existing?['applicationSubmitted'] == true;
  late String? _city = _cities.contains(widget.existing?['area'])
      ? widget.existing!['area'] as String
      : null;
  late final String? _existingPhotoUrl = widget.existing?['photoUrl'] as String?;
  late final String? _existingAadharDocumentUrl =
      widget.existing?['aadharDocumentUrl'] as String?;
  late final String? _existingAadharDocumentBackUrl =
      widget.existing?['aadharDocumentBackUrl'] as String?;
  late final String? _existingPanDocumentUrl = widget.existing?['panDocumentUrl'] as String?;
  late final String? _existingPassbookUrl = widget.existing?['bankPassbookUrl'] as String?;
  File? _photo;
  File? _aadharDocument;
  File? _aadharDocumentBack;
  File? _panDocument;
  File? _passbookDocument;
  bool _agreedToTerms = false;
  bool _submitting = false;
  late final ApplicationUploader _uploader =
      ApplicationUploader(ref.read(technicianUploadServiceProvider));
  bool _addressAutofilled = false;
  bool _autofillingAddress = false;
  Timer? _ifscDebounce;
  String? _ifscBankBranch;
  bool _ifscLookupFailed = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMode());
    _bankIfscCtrl.addListener(_onIfscChanged);
    if (_ifscFormatRe.hasMatch(_bankIfscCtrl.text.trim().toUpperCase())) {
      _lookupIfsc(_bankIfscCtrl.text.trim().toUpperCase());
    }
  }

  _Mode _mode = _Mode.loading;

  /// Always re-reads the technician record from the server (never trusts a
  /// cached copy for the document-upload mode).
  Future<void> _loadMode() async {
    setState(() => _mode = _Mode.loading);
    final me = await ref.read(technicianMeLoaderProvider)();
    if (!mounted) return;
    if (me != null) ref.read(technicianMeProvider.notifier).state = me;
    setState(() => _mode = me == null ? _Mode.failed : _Mode.ready);
  }

  void _onIfscChanged() {
    _ifscDebounce?.cancel();
    final code = _bankIfscCtrl.text.trim().toUpperCase();
    if (!_ifscFormatRe.hasMatch(code)) {
      if (_ifscBankBranch != null || _ifscLookupFailed) {
        setState(() {
          _ifscBankBranch = null;
          _ifscLookupFailed = false;
        });
      }
      return;
    }
    _ifscDebounce = Timer(const Duration(milliseconds: 500), () => _lookupIfsc(code));
  }

  Future<void> _lookupIfsc(String code) async {
    try {
      final res = await http
          .get(Uri.parse('https://ifsc.razorpay.com/$code'))
          .timeout(const Duration(seconds: 6));
      if (!mounted) return;
      if (res.statusCode != 200) {
        setState(() {
          _ifscBankBranch = null;
          _ifscLookupFailed = true;
        });
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final bank = body['BANK'] as String?;
      final branch = body['BRANCH'] as String?;
      setState(() {
        _ifscLookupFailed = false;
        _ifscBankBranch =
            [bank, branch].where((s) => s != null && s.isNotEmpty).join(' — ');
      });
    } catch (_) {
      // No network / lookup service unreachable — not a reason to block
      // submission, just no confirmation shown for now.
    }
  }

  @override
  void dispose() {
    _ifscDebounce?.cancel();
    _bankIfscCtrl.removeListener(_onIfscChanged);
    _nameCtrl.dispose();
    _experienceCtrl.dispose();
    _bankNameCtrl.dispose();
    _bankAccountCtrl.dispose();
    _bankIfscCtrl.dispose();
    _panCtrl.dispose();
    _gstCtrl.dispose();
    _aadharCtrl.dispose();
    _dobCtrl.dispose();
    _emergencyNameCtrl.dispose();
    _emergencyPhoneCtrl.dispose();
    _addressCtrl.dispose();
    _upiCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final initial = DateTime.tryParse(_dobCtrl.text) ?? DateTime(now.year - 25);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 80),
      lastDate: DateTime(now.year - 18, now.month, now.day),
    );
    if (picked != null) {
      setState(() => _dobCtrl.text =
          '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _pickPhoto() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked != null) setState(() => _photo = File(picked.path));
  }

  // KYC document photos (as opposed to the casual profile photo above) need
  // to preserve fine print — both for the on-device OCR address read below
  // and for an admin to actually read the card during review — so these use
  // much lighter compression than the default. A technician's gallery photo
  // is very often itself a recompressed WhatsApp forward (small print
  // already softened once); compressing it again at the default quality
  // only makes a marginal read worse.
  static const _documentImageQuality = 95;

  Future<void> _pickAadharDocument() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: _documentImageQuality);
    if (picked != null) setState(() => _aadharDocument = File(picked.path));
  }

  /// The address (and the QR code) is printed on the Aadhaar card's *back*,
  /// not the front — so this is also the photo the OCR autofill in
  /// [_tryAutofillAddress] reads from.
  Future<void> _pickAadharDocumentBack() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: _documentImageQuality);
    if (picked == null) return;
    final file = File(picked.path);
    setState(() => _aadharDocumentBack = file);
    setState(() => _autofillingAddress = true);
    final found = await _tryAutofillAddress(file);
    if (!mounted) return;
    setState(() => _autofillingAddress = false);
    if (!found) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.applyAddressAutofillFailed)));
    }
  }

  /// Re-runs OCR against the already-picked back photo — lets a technician
  /// retry a failed read without leaving the screen to re-pick the same
  /// image from their gallery.
  Future<void> _retryAutofillAddress() async {
    final file = _aadharDocumentBack;
    if (file == null) return;
    setState(() => _autofillingAddress = true);
    final found = await _tryAutofillAddress(file);
    if (!mounted) return;
    setState(() => _autofillingAddress = false);
    if (!found) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.applyAddressAutofillFailed)));
    }
  }

  /// Runs on-device OCR against the just-picked Aadhaar back photo and, if
  /// it can find an address-shaped block of text, prefills the address
  /// field with it — always still editable, never silently trusted (see
  /// aadhaar_ocr.dart for why).
  /// Returns whether an address was actually found and filled in, so the
  /// caller can tell the technician plainly when it wasn't (rather than the
  /// picker just silently doing nothing, which is indistinguishable from a
  /// broken feature).
  Future<bool> _tryAutofillAddress(File file) async {
    final address = await extractAddressFromImage(file);
    if (!mounted || address == null || address.isEmpty) return false;
    setState(() {
      _addressCtrl.text = address;
      _addressAutofilled = true;
    });
    return true;
  }

  Future<void> _pickPanDocument() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: _documentImageQuality);
    if (picked != null) setState(() => _panDocument = File(picked.path));
  }

  Future<void> _pickPassbookDocument() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: _documentImageQuality);
    if (picked != null) setState(() => _passbookDocument = File(picked.path));
  }

  /// _submit()'s own `finally` resets [_submitting] regardless of how the
  /// try block exits, so this only needs to surface the error.
  void _failUpload(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Staging-only: the backend says document/photo uploads are deferred (no
  /// Storage). Comes from the server's technician record, never from local
  /// config, and defaults to false (production behaviour) when unknown.
  bool get _docsDeferred => ref.read(technicianMeProvider)?['documentsDeferred'] == true;

  Future<void> _submit() async {
    if (_submitting || _uploader.running) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final t = context.l10n;
    if (_categories.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.applyPickCategory)));
      return;
    }
    if (_city == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.applyPickCity)));
      return;
    }
    if (!_employmentTypeLocked && _employmentType == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.applyEmploymentRequired)));
      return;
    }
    // The date picker itself only lets you pick a date 18+ years ago (see
    // _pickDob's `lastDate`), so a non-empty value here is already an
    // enforced adult date of birth — this just makes sure one was actually
    // picked, since nothing else on the form requires it.
    if (_dobCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.applyPickDob)));
      return;
    }
    if (!_isEditing && !_agreedToTerms) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.applyAcceptTerms)));
      return;
    }
    if (!_docsDeferred && _aadharDocument == null && _existingAadharDocumentUrl == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.applyUploadAadhaar)));
      return;
    }
    if (!_docsDeferred &&
        _aadharDocumentBack == null &&
        _existingAadharDocumentBackUrl == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.applyUploadAadhaarBack)));
      return;
    }
    if (!_docsDeferred && _panDocument == null && _existingPanDocumentUrl == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.applyUploadPan)));
      return;
    }
    if (_addressCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.applyEnterAddress)));
      return;
    }
    setState(() => _submitting = true);
    try {
      // Only re-upload what was actually re-picked — omitting a key from the
      // PATCH body leaves that field (and whatever's already on file)
      // untouched, see app.py's update_technician_me. Identity documents are
      // required (a failure stops here and names the failing document); the
      // profile photo is optional (a failure only warns).
      // When uploads are deferred (staging) nothing is sent to Storage and no
      // URLs are invented.
      final uploads = await _uploader.run(_docsDeferred
          ? const PickedApplicationFiles()
          : PickedApplicationFiles(
              photo: _photo,
              aadharFront: _aadharDocument,
              aadharBack: _aadharDocumentBack,
              pan: _panDocument,
              passbook: _passbookDocument,
            ));
      if (uploads == null) return; // already uploading — ignore repeat taps
      if (!uploads.canSubmit) {
        return _failUpload(uploads.blocking!.userMessage);
      }
      if (uploads.photoWarning != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                "Your profile photo wasn't uploaded, so it's skipped for now — "
                'you can add it later. ${uploads.photoWarning!.userMessage}')));
      }
      final photoUrl = uploads.photoUrl;
      final aadharDocumentUrl = uploads.aadharFrontUrl;
      final aadharDocumentBackUrl = uploads.aadharBackUrl;
      final panDocumentUrl = uploads.panUrl;
      final passbookUrl = uploads.passbookUrl;
      final fields = {
        'name': _nameCtrl.text.trim(),
        'categories': _categories.toList(),
        'area': _city,
        // Only sent while still settable — after submission the backend
        // ignores this field anyway, but omitting it here avoids implying
        // a change that never actually happens.
        if (!_employmentTypeLocked && _employmentType != null)
          'employmentType': _employmentType,
        'address': _addressCtrl.text.trim(),
        'experienceYears': int.tryParse(_experienceCtrl.text.trim()),
        if (photoUrl != null) 'photoUrl': photoUrl,
        if (aadharDocumentUrl != null) 'aadharDocumentUrl': aadharDocumentUrl,
        if (aadharDocumentBackUrl != null) 'aadharDocumentBackUrl': aadharDocumentBackUrl,
        if (panDocumentUrl != null) 'panDocumentUrl': panDocumentUrl,
        if (passbookUrl != null) 'bankPassbookUrl': passbookUrl,
        'bankAccountName': _bankNameCtrl.text.trim(),
        // Strip stray internal whitespace too — a bank passbook or a
        // pasted Aadhaar number often has it formatted in groups (e.g.
        // "1234 5678 9012"), which .trim() alone leaves in place and the
        // backend's plain-digits pattern then rejects outright.
        'bankAccountNumber': _bankAccountCtrl.text.replaceAll(RegExp(r'\s'), ''),
        // IFSC codes are always uppercase (HDFC0001234) — the bank/branch
        // lookup above already uppercases before checking, so someone who
        // typed it lowercase sees a normal-looking preview and has no
        // reason to think anything's wrong, but this was still sending
        // their literal lowercase input, which the backend's case-
        // sensitive pattern then rejected with a bare "error 400".
        'bankIfsc': _bankIfscCtrl.text.trim().toUpperCase(),
        'upiId': _upiCtrl.text.trim(),
        'panNumber': _panCtrl.text.trim().toUpperCase(),
        'gstNumber': _gstCtrl.text.trim().toUpperCase(),
        'aadharNumber': _aadharCtrl.text.replaceAll(RegExp(r'\s'), ''),
        'dateOfBirth': _dobCtrl.text.trim(),
        'emergencyContactName': _emergencyNameCtrl.text.trim(),
        'emergencyContactPhone': _emergencyPhoneCtrl.text.trim(),
        'submit': true,
      };
      final result = await _submitApplication(fields);
      if (!mounted) return;
      ref.read(technicianMeProvider.notifier).state = result;
      if (_isEditing) {
        Navigator.of(context).pop();
      } else {
        routeToStage(context, ref, stageFromTechnicianJson(result));
      }
    } on AuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// A 401 here almost always means [bootstrapTechnicianBackend] never
  /// actually created this technician's row — most likely it silently
  /// timed out against a cold-starting backend right after sign-in (Render
  /// free tier can take well past the original 8-second bootstrap timeout
  /// to wake up). Rather than stranding someone who just filled out the
  /// whole KYC form behind a generic error, retry the bootstrap once and
  /// resubmit before giving up for real.
  Future<Map<String, dynamic>> _submitApplication(Map<String, dynamic> fields) async {
    try {
      return await submitTechnicianApplication(fields);
    } on TechnicianProfileMissingException {
      final bootstrapped = await bootstrapTechnicianBackend();
      if (bootstrapped == null) {
        throw const AuthException(
            "Couldn't verify your sign-in — please sign out and sign in again.");
      }
      return submitTechnicianApplication(fields);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The upload/no-upload mode is decided by the SERVER, so never draw the
    // form from cached or stale state: wait for a fresh technician record.
    if (_mode == _Mode.loading) {
      return Scaffold(
        appBar: AppBar(title: Text(_isEditing ? context.l10n.applyEditTitle : context.l10n.applyTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final serverDeferred = ref.watch(technicianMeProvider)?['documentsDeferred'] == true;
    if (_mode == _Mode.failed) {
      return _ModeProblem(
        key: const Key('mode-load-failed'),
        title: "Couldn't load your application settings",
        body: 'Check your connection and try again. The form is not shown until '
            'the server confirms how documents are handled.',
        onRetry: _loadMode,
      );
    }
    if (!serverDeferred && !ref.watch(isProductionApiProvider)) {
      // A staging/test server that still wants production documents is a
      // misconfiguration — say so instead of showing the production form.
      return _ModeProblem(
        key: const Key('staging-misconfigured'),
        title: 'Staging configuration error',
        body: 'This test server is not set up to defer document uploads '
            '(TECHNICIAN_DOCUMENTS_DEFERRED is not enabled, or the server has not '
            'been updated). Ask the administrator to enable it on the staging '
            'service and try again. No upload form is shown.',
        onRetry: _loadMode,
      );
    }
    return _buildForm(context);
  }

  Widget _buildForm(BuildContext context) {
    final t = context.l10n;
    final deferred = ref.watch(technicianMeProvider)?['documentsDeferred'] == true;
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? t.applyEditTitle : t.applyTitle)),
      body: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              if (deferred)
                Container(
                  key: const Key('docs-deferred-note'),
                  width: double.infinity,
                  color: context.scheme.surfaceContainerHigh,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: const Text(
                      'Staging test: photo and document uploads are turned off for now, '
                      'so you can submit without them. Your application still needs owner '
                      'approval before you can receive jobs.',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
              if (!_isEditing)
                Container(
                  width: double.infinity,
                  color: CareColors.brass.withValues(alpha: 0.16),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Text(t.applyStepsBanner,
                      style: context.type.bodySmall!.copyWith(fontWeight: FontWeight.w700)),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  children: [
                    if (!_isEditing) ...[
                      Text(t.applyIntro, style: context.type.headlineLarge),
                      const SizedBox(height: 20),
                    ],
                    Center(
                      child: GestureDetector(
                        onTap: deferred ? null : _pickPhoto,
                        child: CircleAvatar(
                          radius: 44,
                          backgroundColor: context.scheme.surfaceContainerHigh,
                          backgroundImage: _photo != null
                              ? FileImage(_photo!)
                              : (_existingPhotoUrl != null
                                  ? NetworkImage(_existingPhotoUrl)
                                  : null) as ImageProvider?,
                          child: _photo == null && _existingPhotoUrl == null
                              ? Icon(Icons.add_a_photo_outlined,
                                  color: context.care.inkFaint, size: 28)
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Center(
                        child: Text(
                            deferred ? 'Profile photo — skipped for the staging test' : t.applyPhotoHint,
                            style: context.type.bodySmall)),
                    const SizedBox(height: 22),
                    Eyebrow(t.applyNameQuestion),
                    const SizedBox(height: 8),
                    CareField(t.applyFullName,
                        controller: _nameCtrl,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return t.applyNameRequired;
                          if (!_nameCharsRe.hasMatch(v)) {
                            return t.applyNameInvalid;
                          }
                          return null;
                        }),
                    const SizedBox(height: 18),
                    Eyebrow(t.applyWorkQuestion),
                    const SizedBox(height: 4),
                    Text(t.applySelectTrade, style: context.type.bodySmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final c in _categoryOptions)
                          FilterChip(
                            label: Text(c.$2),
                            selected: _categories.contains(c.$1),
                            onSelected: (selected) => setState(() {
                              if (selected) {
                                _categories.add(c.$1);
                              } else {
                                _categories.remove(c.$1);
                              }
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Eyebrow(t.applyEmploymentQuestion),
                    const SizedBox(height: 4),
                    Text(t.applyEmploymentHint, style: context.type.bodySmall),
                    const SizedBox(height: 8),
                    if (_employmentTypeLocked)
                      CareCard(
                        child: Row(
                          children: [
                            Icon(Icons.lock_outline, size: 16, color: context.care.inkFaint),
                            const SizedBox(width: 10),
                            Text(
                              _employmentType == 'payroll'
                                  ? t.applyEmploymentPayroll
                                  : t.applyEmploymentOutsourced,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      _EmploymentOption(
                        title: t.applyEmploymentPayroll,
                        subtitle: t.applyEmploymentPayrollDetail,
                        selected: _employmentType == 'payroll',
                        onTap: () => setState(() => _employmentType = 'payroll'),
                      ),
                      const SizedBox(height: 8),
                      _EmploymentOption(
                        title: t.applyEmploymentOutsourced,
                        subtitle: t.applyEmploymentOutsourcedDetail,
                        selected: _employmentType == 'outsourced',
                        onTap: () => setState(() => _employmentType = 'outsourced'),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Eyebrow(t.applyLiveQuestion),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _city,
                      isExpanded: true,
                      decoration: const InputDecoration(border: OutlineInputBorder()),
                      hint: Text(t.applySelectCity),
                      items: [
                        for (final c in _cities) DropdownMenuItem(value: c, child: Text(c)),
                      ],
                      onChanged: (v) => setState(() => _city = v),
                    ),
                    const SizedBox(height: 13),
                    CareField(t.applyExperience,
                        controller: _experienceCtrl,
                        keyboardType: TextInputType.number,
                        validator: (v) => (v == null || int.tryParse(v.trim()) == null)
                            ? t.applyExperienceError
                            : null),
                    const SizedBox(height: 24),
                    _SectionCard(
                      icon: Icons.badge_outlined,
                      title: t.applyAadhaarCard,
                      child: Column(
                        children: [
                          CareField(t.applyAadhaarNumber,
                              controller: _aadharCtrl, keyboardType: TextInputType.number),
                          if (!deferred) ...[
                          const SizedBox(height: 13),
                          _DocPickerRow(
                            label: _aadharDocument != null
                                ? _aadharDocument!.path.split('/').last
                                : (_existingAadharDocumentUrl != null
                                    ? t.applyAadhaarFrontUploaded
                                    : t.applyAadhaarFrontUpload),
                            onTap: _pickAadharDocument,
                          ),
                          const SizedBox(height: 10),
                          _DocPickerRow(
                            label: _aadharDocumentBack != null
                                ? _aadharDocumentBack!.path.split('/').last
                                : (_existingAadharDocumentBackUrl != null
                                    ? t.applyAadhaarBackUploaded
                                    : t.applyAadhaarBackUpload),
                            onTap: _pickAadharDocumentBack,
                          ),
                          ],
                          if (_autofillingAddress) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const SizedBox(
                                    width: 13,
                                    height: 13,
                                    child: CircularProgressIndicator(strokeWidth: 2)),
                                const SizedBox(width: 8),
                                Text(t.applyReadingAddress, style: context.type.bodySmall),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      icon: Icons.credit_card_outlined,
                      title: t.applyPanCard,
                      child: Column(
                        children: [
                          CareField(t.applyPanNumber, controller: _panCtrl),
                          if (!deferred) ...[
                          const SizedBox(height: 13),
                          _DocPickerRow(
                            label: _panDocument != null
                                ? _panDocument!.path.split('/').last
                                : (_existingPanDocumentUrl != null
                                    ? t.applyPanUploaded
                                    : t.applyPanUpload),
                            onTap: _pickPanDocument,
                          ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      icon: Icons.home_outlined,
                      title: t.applyAddress,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CareField(t.applyFullAddress,
                              controller: _addressCtrl, maxLines: 3),
                          if (_addressAutofilled) ...[
                            const SizedBox(height: 8),
                            Text(t.applyAddressAutofilled,
                                style: context.type.bodySmall!
                                    .copyWith(color: context.care.success)),
                          ] else if (_aadharDocumentBack != null && !_autofillingAddress) ...[
                            const SizedBox(height: 8),
                            InkWell(
                              onTap: _retryAutofillAddress,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.refresh, size: 15, color: context.scheme.primary),
                                  const SizedBox(width: 4),
                                  Text(t.applyRetryAddressAutofill,
                                      style: context.type.bodySmall!
                                          .copyWith(color: context.scheme.primary)),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      icon: Icons.account_balance_outlined,
                      title: t.applyBankDetails,
                      child: Column(
                        children: [
                          CareField(t.applyAccountHolder, controller: _bankNameCtrl),
                          const SizedBox(height: 13),
                          CareField(t.applyAccountNumber,
                              controller: _bankAccountCtrl, keyboardType: TextInputType.number),
                          const SizedBox(height: 13),
                          CareField(t.applyIfsc, controller: _bankIfscCtrl),
                          if (_ifscBankBranch != null) ...[
                            const SizedBox(height: 6),
                            Text(_ifscBankBranch!,
                                style: context.type.bodySmall!
                                    .copyWith(color: context.care.success)),
                          ] else if (_ifscLookupFailed) ...[
                            const SizedBox(height: 6),
                            Text(t.applyIfscNotFound,
                                style: context.type.bodySmall!
                                    .copyWith(color: context.scheme.error)),
                          ],
                          const SizedBox(height: 13),
                          CareField(t.applyUpi,
                              controller: _upiCtrl,
                              keyboardType: TextInputType.emailAddress,
                              prefix: const Icon(Icons.alternate_email, size: 18)),
                          const SizedBox(height: 13),
                          CareField(t.applyGst, controller: _gstCtrl),
                          if (!deferred) ...[
                          const SizedBox(height: 13),
                          _DocPickerRow(
                            label: _passbookDocument != null
                                ? _passbookDocument!.path.split('/').last
                                : (_existingPassbookUrl != null
                                    ? t.applyPassbookUploaded
                                    : t.applyPassbookUpload),
                            onTap: _pickPassbookDocument,
                          ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    Eyebrow(t.applyPersonalDetails),
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: _pickDob,
                      child: AbsorbPointer(
                        child: CareField(t.applyDob, controller: _dobCtrl),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Eyebrow(t.applyEmergencyContact),
                    const SizedBox(height: 10),
                    CareField(t.applyContactName, controller: _emergencyNameCtrl),
                    const SizedBox(height: 13),
                    CareField(t.applyContactPhone,
                        controller: _emergencyPhoneCtrl, keyboardType: TextInputType.phone),
                    if (!_isEditing) ...[
                      const SizedBox(height: 22),
                      CareCard(
                        color: context.scheme.surfaceContainerHigh,
                        borderColor: Colors.transparent,
                        onTap: () => setState(() => _agreedToTerms = !_agreedToTerms),
                        child: Row(children: [
                          Checkbox(
                            value: _agreedToTerms,
                            onChanged: (v) => setState(() => _agreedToTerms = v ?? false),
                          ),
                          Expanded(
                            child: Text(t.applyTermsText, style: context.type.bodySmall),
                          ),
                        ]),
                      ),
                    ],
                  ],
                ),
              ),
              Dock(
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_isEditing ? t.applySaveChanges : t.applyContinue),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled card wrapping a related group of fields — used to give the KYC
/// document sections (Aadhaar/PAN/Address/Bank) clearer visual separation
/// than a flat scroll of labels, without the risk of a full multi-step
/// wizard rewrite.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.icon, required this.title, required this.child});
  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => CareCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: context.scheme.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      );
}

/// One tappable employment-type choice on the apply form — plain
/// Container/InkWell, not a dropdown or radio group, matching the rest of
/// this screen's card-based pattern.
class _EmploymentOption extends StatelessWidget {
  const _EmploymentOption({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => CareCard(
        onTap: onTap,
        borderColor: selected ? context.scheme.primary : null,
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? context.scheme.primary : context.care.inkFaint,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: context.type.bodySmall),
                ],
              ),
            ),
          ],
        ),
      );
}

class _DocPickerRow extends StatelessWidget {
  const _DocPickerRow({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: Radii.rMd,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: Radii.rMd,
            border: Border.all(color: context.care.hairline),
          ),
          child: Row(children: [
            Icon(Icons.add_a_photo_outlined, size: 18, color: context.scheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: context.type.bodySmall)),
            Icon(Icons.chevron_right, size: 18, color: context.care.inkMuted),
          ]),
        ),
      );
}


enum _Mode { loading, ready, failed }

class _ModeProblem extends StatelessWidget {
  const _ModeProblem({super.key, required this.title, required this.body, required this.onRetry});
  final String title;
  final String body;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.l10n.applyTitle)),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.settings_suggest_outlined, size: 44, color: context.scheme.error),
              const SizedBox(height: 16),
              Text(title, style: context.type.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(body, style: context.type.bodyMedium, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}
