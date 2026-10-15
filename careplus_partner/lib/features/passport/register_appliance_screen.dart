import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/care_widgets.dart';
import '../../state/providers.dart';
import 'passport_catalog.dart';

/// Register one appliance in the customer's Kitchen Passport. The category
/// selector is the appliance itself (no separate "Type" field); everything
/// below it is specific to that category.
class RegisterApplianceScreen extends ConsumerStatefulWidget {
  const RegisterApplianceScreen({super.key, required this.jobId});
  final String jobId;

  @override
  ConsumerState<RegisterApplianceScreen> createState() => _RegisterApplianceScreenState();
}

class _RegisterApplianceScreenState extends ConsumerState<RegisterApplianceScreen> {
  final _formKey = GlobalKey<FormState>();
  final _model = TextEditingController();
  final _serial = TextEditingController();
  final _year = TextEditingController();
  final _notes = TextEditingController();
  final _newBrand = TextEditingController();
  final _specNumbers = <String, TextEditingController>{};
  final _specChoices = <String, String>{};
  // One id per form: if a submit's response is lost and the technician taps
  // Save again, the server returns the first record rather than a duplicate.
  final _requestId = newClientRequestId();

  ApplianceCategory? _category;
  List<String> _customBrands = const [];
  String? _brand; // a real brand name, or kBrandOther while adding one
  String? _brandError;
  bool _addingBrand = false;
  bool _savingBrand = false;
  bool _submitting = false;
  String? _submitError;

  @override
  void dispose() {
    for (final c in [_model, _serial, _year, _notes, _newBrand, ..._specNumbers.values]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _brandOptions {
    final all = <String>[..._category!.brands];
    for (final b in _customBrands) {
      if (matchBrand(b, all) == null) all.add(b);
    }
    return all;
  }

  Future<void> _selectCategory(ApplianceCategory c) async {
    if (_category?.id == c.id) return;
    setState(() {
      _category = c;
      _brand = null;
      _brandError = null;
      _addingBrand = false;
      _newBrand.clear();
      _customBrands = const [];
      _specChoices.clear();
      for (final ctl in _specNumbers.values) {
        ctl.clear();
      }
      _submitError = null;
    });
    final r = await ref.read(passportApiProvider).customBrands(c.id);
    if (!mounted || _category?.id != c.id) return;
    // A failed fetch just means no saved brands are offered; the predefined
    // list and Add Brand still work.
    if (r.ok) setState(() => _customBrands = r.value!);
  }

  Future<void> _addBrand() async {
    final c = _category!;
    final problem = validateBrandName(_newBrand.text);
    if (problem != null) {
      setState(() => _brandError = problem);
      return;
    }
    final typed = normaliseBrand(_newBrand.text);
    final existing = matchBrand(typed, _brandOptions);
    if (existing != null) {
      setState(() {
        _brand = existing;
        _addingBrand = false;
        _brandError = null;
        _newBrand.clear();
      });
      return;
    }
    setState(() {
      _savingBrand = true;
      _brandError = null;
    });
    final r = await ref.read(passportApiProvider).addCustomBrand(c.id, typed);
    if (!mounted || _category?.id != c.id) return;
    setState(() {
      _savingBrand = false;
      if (r.ok) {
        final saved = r.value!;
        if (matchBrand(saved, _customBrands) == null) {
          _customBrands = [..._customBrands, saved];
        }
        _brand = saved;
        _addingBrand = false;
        _newBrand.clear();
      } else {
        _brandError = r.error;
      }
    });
  }

  Future<void> _submit() async {
    final c = _category;
    final brandOk = _brand != null && _brand != kBrandOther;
    if (!brandOk) {
      setState(() => _brandError = _addingBrand
          ? 'Tap Add Brand to save the new brand'
          : 'Choose a brand');
    }
    final formOk = _formKey.currentState?.validate() ?? false;
    if (c == null || !brandOk || !formOk) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    final specValues = {
      for (final f in c.fields)
        f.key: f.kind == SpecKind.choice
            ? (_specChoices[f.key] ?? '')
            : (_specNumbers['${c.id}.${f.key}']?.text ?? ''),
    };
    final payload = buildRegistrationPayload(
      category: c,
      brand: _brand!,
      specValues: specValues,
      model: _model.text,
      serialNumber: _serial.text,
      installYear: _year.text,
      notes: _notes.text,
      clientRequestId: _requestId,
    );
    final r = await ref.read(passportApiProvider).register(widget.jobId, payload);
    if (!mounted) return;
    if (r.ok) {
      context.pop(true);
    } else {
      setState(() {
        _submitting = false;
        _submitError = r.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _category;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: context.pop),
        title: const Text('Register appliance'),
      ),
      body: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  children: [
                    const Eyebrow('Appliance'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final cat in kApplianceCategories)
                          ChoiceTag('${cat.glyph} ${cat.label}',
                              selected: c?.id == cat.id, onTap: () => _selectCategory(cat)),
                      ],
                    ),
                    if (c != null) ...[
                      const SizedBox(height: 22),
                      _brandSection(c),
                      const SizedBox(height: 22),
                      const Eyebrow('Specifications'),
                      const SizedBox(height: 10),
                      for (final f in c.fields) ...[_specField(f), const SizedBox(height: 14)],
                      const SizedBox(height: 8),
                      const Eyebrow('Details (optional)'),
                      const SizedBox(height: 10),
                      CareField('Model', controller: _model),
                      const SizedBox(height: 14),
                      CareField('Serial number', controller: _serial),
                      const SizedBox(height: 14),
                      CareField('Year installed',
                          controller: _year,
                          keyboardType: TextInputType.number,
                          validator: (v) => validateInstallYear(v,
                              currentYear: DateTime.now().year)),
                      const SizedBox(height: 14),
                      CareField('Notes', controller: _notes, maxLines: 3),
                    ],
                    if (_submitError != null) ...[
                      const SizedBox(height: 16),
                      Text(_submitError!,
                          style: TextStyle(color: context.scheme.error, fontSize: 13)),
                    ],
                  ],
                ),
              ),
              Dock(
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: c == null || _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Save to Kitchen Passport'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _brandSection(ApplianceCategory c) {
    final options = _brandOptions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Eyebrow('Brand'),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          key: ValueKey('brand-${c.id}-${_brand ?? ''}-${options.length}'),
          initialValue: _addingBrand ? kBrandOther : _brand,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Brand name',
            errorText: _addingBrand ? null : _brandError,
          ),
          items: [
            for (final b in options) DropdownMenuItem(value: b, child: Text(b)),
            const DropdownMenuItem(value: kBrandOther, child: Text(kBrandOther)),
          ],
          onChanged: (v) => setState(() {
            _brandError = null;
            if (v == kBrandOther) {
              _addingBrand = true;
              _brand = kBrandOther;
            } else {
              _addingBrand = false;
              _brand = v;
            }
          }),
        ),
        if (_addingBrand) ...[
          const SizedBox(height: 12),
          CareField('New brand name', controller: _newBrand),
          if (_brandError != null) ...[
            const SizedBox(height: 6),
            Text(_brandError!, style: TextStyle(color: context.scheme.error, fontSize: 12.5)),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _savingBrand ? null : _addBrand,
              icon: _savingBrand
                  ? const SizedBox(
                      height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.add, size: 18),
              label: const Text('Add Brand'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _specField(SpecField f) {
    final label = f.unit == null ? f.label : '${f.label} (${f.unit})';
    if (f.kind == SpecKind.choice) {
      return DropdownButtonFormField<String>(
        key: ValueKey('spec-${_category!.id}-${f.key}'),
        initialValue: _specChoices[f.key],
        isExpanded: true,
        decoration: InputDecoration(labelText: f.required ? label : '$label (optional)'),
        items: [
          for (final e in f.choices.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        validator: f.validate,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        onChanged: (v) => setState(() {
          if (v == null) {
            _specChoices.remove(f.key);
          } else {
            _specChoices[f.key] = v;
          }
        }),
      );
    }
    final ctl = _specNumbers.putIfAbsent('${_category!.id}.${f.key}', TextEditingController.new);
    return CareField(f.required ? label : '$label (optional)',
        controller: ctl, keyboardType: TextInputType.number, validator: f.validate);
  }
}
