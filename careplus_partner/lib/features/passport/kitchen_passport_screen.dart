import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/care_widgets.dart';
import '../../data/api/passport_api.dart';
import '../../state/providers.dart';
import 'passport_catalog.dart';

/// Kitchen Passport for the customer of one job: what's already registered,
/// plus the entry to register another appliance.
class KitchenPassportScreen extends ConsumerWidget {
  const KitchenPassportScreen({super.key, required this.jobId});
  final String jobId;

  Future<void> _register(BuildContext context, WidgetRef ref) async {
    final added = await context.push<bool>('/tech/job/$jobId/kitchen/register');
    if (added == true) ref.invalidate(kitchenAppliancesProvider(jobId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appliances = ref.watch(kitchenAppliancesProvider(jobId));
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: context.pop),
        title: const Text('Kitchen Passport'),
      ),
      body: SafeArea(
        top: false,
        child: appliances.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              EmptyState(
                glyph: '⚠',
                title: 'Could not load the passport',
                body: e is PassportException ? e.message : 'Something went wrong.',
                action: FilledButton(
                  onPressed: () => ref.invalidate(kitchenAppliancesProvider(jobId)),
                  child: const Text('Retry'),
                ),
              ),
            ],
          ),
          data: (list) => Column(
            children: [
              Expanded(
                child: list.isEmpty
                    ? ListView(
                        padding: const EdgeInsets.all(20),
                        children: const [
                          EmptyState(
                            glyph: '▤',
                            title: 'No appliances registered yet',
                            body: 'Register the customer\'s kitchen appliances to start '
                                'their Kitchen Passport.',
                          ),
                        ],
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _ApplianceCard(jobId: jobId, a: list[i]),
                      ),
              ),
              Dock(
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => _register(context, ref),
                    child: const Text('Register appliance'),
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

/// "Gas · 4 burners" style summary of the appliance-specific fields.
List<String> specSummary(ApplianceCategory category, Map<String, dynamic> specs) {
  final out = <String>[];
  for (final f in category.fields) {
    final v = specs[f.key];
    if (v == null) continue;
    out.add(f.kind == SpecKind.choice
        ? (f.choices[v] ?? '$v')
        : '${f.label} $v${f.unit == null ? '' : ' ${f.unit}'}');
  }
  return out;
}

class _ApplianceCard extends StatelessWidget {
  const _ApplianceCard({required this.jobId, required this.a});
  final String jobId;
  final KitchenAppliance a;

  @override
  Widget build(BuildContext context) {
    final category = categoryById(a.category);
    final chips = category == null ? const <String>[] : specSummary(category, a.specs);
    final detail = [
      a.brand,
      if (a.model.isNotEmpty) a.model,
      if (a.installYear != null) '${a.installYear}',
    ].join(' · ');
    return CareCard(
      onTap: category == null
          ? null
          : () => context.push('/tech/job/$jobId/kitchen/appliance/${a.id}/inspection', extra: a),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(category?.glyph ?? '▪',
              style: TextStyle(fontSize: 26, color: context.scheme.primary)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(category?.label ?? a.category, style: context.type.titleSmall),
                const SizedBox(height: 3),
                Text(detail, style: context.type.bodySmall),
                if (chips.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [for (final c in chips) StatusChip(c, height: 26)],
                  ),
                ],
                if (category != null) ...[
                  const SizedBox(height: 10),
                  Text('Open checklist ›',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: context.scheme.primary)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
