import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/widgets/appliance_illustration.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/models.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/providers.dart';

// ============================================================ ALL SERVICES
class CatalogScreen extends ConsumerWidget {
  const CatalogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.catalogAllServicesTitle),
        actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.tune))],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
          children: [
            CareCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  hintText: t.catalogSearchHint,
                  hintStyle: context.type.bodyMedium,
                  prefixIcon: Icon(Icons.search, color: context.care.inkFaint, size: 20),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Eyebrow(t.catalogCategoriesCount(Appliance.values.length)),
            const SizedBox(height: 12),
            Stagger(
              children: [
                for (final a in Appliance.values)
                  CareCard(
                    onTap: () => context.push('/services/${a.name}'),
                    child: Row(children: [
                      Blob(a.glyph, glyph: true),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(a.label,
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 3),
                            Text(_blurb(a, t), style: context.type.bodySmall),
                          ],
                        ),
                      ),
                      _fromPrice(context, ref, a, t),
                    ]),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _fromPrice(BuildContext context, WidgetRef ref, Appliance a, AppLocalizations t) {
    final services = ref.read(repositoryProvider).servicesFor(a);
    if (services.isEmpty) {
      return StatusChip(t.catalogComingSoon, height: 26);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Eyebrow(t.catalogFromPriceEyebrow),
        const SizedBox(height: 2),
        Text(Money.rupees(services.map((s) => s.pricePaise).reduce((a, b) => a < b ? a : b)),
            style: CareType.mono(context.scheme.onSurface, size: 14, w: FontWeight.w600)),
      ],
    );
  }

  String _blurb(Appliance a, AppLocalizations t) => switch (a) {
        Appliance.chimney => t.catalogBlurbChimney,
        Appliance.hob => t.catalogBlurbHob,
        Appliance.cooktop => t.catalogBlurbCooktop,
        Appliance.dishwasher => t.catalogBlurbDishwasher,
        Appliance.microwave => t.catalogBlurbMicrowave,
        Appliance.refrigerator => t.catalogBlurbRefrigerator,
        Appliance.otg => t.catalogBlurbOtg,
        Appliance.purifier => t.catalogBlurbPurifier,
      };
}

// ============================================================ SERVICE DETAIL
class ServiceDetailScreen extends ConsumerStatefulWidget {
  const ServiceDetailScreen({super.key, required this.appliance});
  final Appliance appliance;
  @override
  ConsumerState<ServiceDetailScreen> createState() => _ServiceDetailState();
}

class _ServiceDetailState extends ConsumerState<ServiceDetailScreen> {
  final Set<String> _selectedIds = {};
  final Set<String> _expandedIncluded = {};
  Appliance? _seededAppliance;

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final detail = repo.applianceDetail(widget.appliance);

    if (detail.comingSoon) {
      return _ComingSoonScreen(appliance: widget.appliance, detail: detail);
    }

    final services = repo.servicesFor(widget.appliance);
    // Pre-select the first service once per appliance — not
    // "whenever nothing's selected", or removing the last pick (allowed
    // below) would just get silently re-added on the next rebuild.
    if (_seededAppliance != widget.appliance) {
      _selectedIds
        ..clear()
        ..add(services.first.id);
      _seededAppliance = widget.appliance;
    }
    final selected = [for (final s in services) if (_selectedIds.contains(s.id)) s];
    final selectedTotalPaise = selected.fold<int>(0, (sum, s) => sum + s.pricePaise);
    final avgDurationMin =
        services.firstWhere((s) => s.mostBooked, orElse: () => services.first).durationMin;
    final t = context.l10n;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: context.pop),
        title: Text(widget.appliance.label),
        actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.favorite_border))],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                children: [
                  _ApplianceHero(appliance: widget.appliance),
                  const SizedBox(height: 16),
                  Wrap(spacing: 8, children: [
                    StatusChip(t.serviceDetailAvgDuration(avgDurationMin), height: 28),
                    StatusChip(t.serviceDetailAllBrands, height: 28),
                  ]),
                  const SizedBox(height: 16),
                  Text(detail.heading, style: context.type.headlineMedium),
                  const SizedBox(height: 8),
                  Text(detail.blurb, style: context.type.bodyMedium),
                  const SizedBox(height: 22),
                  const SizedBox(height: 16),
                  ..._servicesTab(services, t),
                ],
              ),
            ),
            Dock(
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Eyebrow(t.serviceDetailSelectedCount(selected.length)),
                      Text(Money.rupees(selectedTotalPaise),
                          style: CareType.mono(context.scheme.onSurface,
                              size: 16, w: FontWeight.w600)),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () {
                          ref.read(bookingDraftProvider.notifier).start(selected);
                          context.push('/book/issue');
                        },
                  child: Text(t.serviceDetailContinue),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _servicesTab(List<ServiceItem> services, AppLocalizations t) => [
        for (final s in services) ...[
          CareCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (s.mostBooked) ...[
                            StatusChip(t.serviceDetailMostBooked,
                                tone: ChipTone.warning, height: 22),
                            const SizedBox(height: 8),
                          ],
                          Text(s.title,
                              style: const TextStyle(
                                  fontSize: 14.5, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 5),
                          Text(s.blurb, style: context.type.bodySmall),
                          const SizedBox(height: 9),
                          Row(children: [
                            Text(Money.rupees(s.pricePaise),
                                style: CareType.mono(context.scheme.onSurface,
                                    size: 15, w: FontWeight.w600)),
                            if (s.strikePaise != null) ...[
                              const SizedBox(width: 8),
                              Text(Money.rupees(s.strikePaise!),
                                  style: CareType.mono(context.care.inkFaint, size: 12)
                                      .copyWith(decoration: TextDecoration.lineThrough)),
                            ],
                          ]),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    ChoiceTag(
                        _selectedIds.contains(s.id)
                            ? t.serviceDetailAdded
                            : t.serviceDetailAdd,
                        selected: _selectedIds.contains(s.id),
                        onTap: () => setState(() {
                              // A real multi-add, not a single radio pick —
                              // the "Add"/"Added" wording always implied you
                              // could pick more than one service in a visit.
                              // Deselecting the last one is allowed too —
                              // Continue just disables until something's
                              // picked again (see the FilledButton below).
                              if (_selectedIds.contains(s.id)) {
                                _selectedIds.remove(s.id);
                              } else {
                                _selectedIds.add(s.id);
                              }
                            })),
                  ],
                ),
                if (s.included.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _IncludedDropdown(
                    service: s,
                    expanded: _expandedIncluded.contains(s.id),
                    onToggle: () => setState(() => _expandedIncluded.contains(s.id)
                        ? _expandedIncluded.remove(s.id)
                        : _expandedIncluded.add(s.id)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ];
}

/// A collapsible "What's included" card shown above the services list,
/// instead of its own tab — tap the header to expand/collapse.
class _IncludedDropdown extends StatelessWidget {
  const _IncludedDropdown({
    required this.service,
    required this.expanded,
    required this.onToggle,
  });
  final ServiceItem service;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: context.scheme.surfaceContainerHigh,
          borderRadius: Radii.rMd,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Pressable(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(context.l10n.serviceDetailWhatsIncluded,
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w700)),
                    ),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: Motion.press,
                      child: Icon(Icons.expand_more, size: 20, color: context.care.inkMuted),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    for (final t in service.included)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          Icon(Icons.check, size: 15, color: context.care.success),
                          const SizedBox(width: 8),
                          Expanded(child: Text(t, style: context.type.bodySmall)),
                        ]),
                      ),
                    if (service.notIncluded.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(context.l10n.serviceDetailNotIncluded,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: context.scheme.error)),
                      const SizedBox(height: 5),
                      Text(service.notIncluded, style: context.type.bodySmall),
                    ],
                    if (service.requirements.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      Text(context.l10n.serviceDetailWhatWeNeed,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 16,
                        runSpacing: 10,
                        children: [
                          for (final r in service.requirements) _RequirementTile(r),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              crossFadeState:
                  expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: Motion.screen,
              sizeCurve: Motion.ease,
            ),
          ],
        ),
      );
}

/// One "what we'll need from you" item — an icon over a short label, in a
/// row with the others. The icon is guessed from the label's own wording
/// (no separate icon field on [ServiceItem] — every requirement so far is
/// short enough that a few keyword checks cover it, and a service with
/// nothing unusual to ask for just doesn't set any).
IconData _requirementIcon(String label) {
  final l = label.toLowerCase();
  if (l.contains('water') || l.contains('bucket')) return Icons.water_drop_outlined;
  if (l.contains('power') || l.contains('socket') || l.contains('point')) {
    return Icons.electrical_services_outlined;
  }
  if (l.contains('ladder') || l.contains('stool')) return Icons.stairs_outlined;
  return Icons.info_outline;
}

class _RequirementTile extends StatelessWidget {
  const _RequirementTile(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 74,
        child: Column(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.scheme.surfaceContainerHigh,
              ),
              child: Icon(_requirementIcon(label), size: 19, color: context.scheme.primary),
            ),
            const SizedBox(height: 6),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.type.bodySmall),
          ],
        ),
      );
}

/// The appliance illustration shown at the top of its service-detail
/// screen — a soft gradient card with the pictogram centered on a glossy
/// badge. Deliberately simple/static (no floating overlays that could
/// clip or overflow at odd screen sizes): a fixed-size illustration
/// centered in a fixed-height card, nothing positioned outside its bounds.
class _ApplianceHero extends StatelessWidget {
  const _ApplianceHero({required this.appliance});
  final Appliance appliance;

  @override
  Widget build(BuildContext context) {
    final primary = context.scheme.primary;
    return Container(
      height: 150,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: Radii.rLg,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [context.scheme.primaryContainer, context.scheme.surfaceContainerHigh],
        ),
      ),
      child: Container(
        width: 108,
        height: 108,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: const Alignment(-0.3, -0.35),
            radius: 0.95,
            colors: [Color.lerp(primary, Colors.white, 0.45)!, primary],
          ),
          boxShadow: [
            BoxShadow(
                color: primary.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 8)),
          ],
        ),
        child: ApplianceIllustration(appliance: appliance, size: 62, color: Colors.white),
      ),
    );
  }
}

// ============================================================ COMING SOON
class _ComingSoonScreen extends StatelessWidget {
  const _ComingSoonScreen({required this.appliance, required this.detail});
  final Appliance appliance;
  final ApplianceDetail detail;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(leading: BackButton(onPressed: context.pop), title: Text(appliance.label)),
        body: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              children: [
                _ApplianceHero(appliance: appliance),
                const SizedBox(height: 16),
                StatusChip(context.l10n.catalogComingSoon, height: 28),
                const SizedBox(height: 16),
                Text(detail.heading, style: context.type.headlineMedium),
                const SizedBox(height: 8),
                Text(detail.blurb, textAlign: TextAlign.center, style: context.type.bodyMedium),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(context.l10n.catalogNotifySnackbar))),
                    child: Text(context.l10n.catalogNotifyMe),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      );
}

class _Segmented extends StatelessWidget {
  const _Segmented({required this.tabs, required this.index, required this.onChanged});
  final List<String> tabs;
  final int index;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: context.scheme.surfaceContainerHigh, borderRadius: Radii.rSm),
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(i),
                  child: AnimatedContainer(
                    duration: Motion.press,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == index ? context.scheme.surface : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: i == index
                          ? Shadows.card(Theme.of(context).brightness == Brightness.dark)
                          : null,
                    ),
                    child: Text(tabs[i],
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: i == index
                                ? context.scheme.onSurface
                                : context.care.inkMuted)),
                  ),
                ),
              ),
          ],
        ),
      );
}
