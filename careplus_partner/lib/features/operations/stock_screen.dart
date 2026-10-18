import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/care_widgets.dart';
import '../../core/theme/care_plus_theme.dart';
import '../../data/operations/models.dart';
import '../../state/operations_providers.dart';
import 'dashboard_header.dart';

class StockScreen extends ConsumerWidget {
  const StockScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(operationsRepositoryProvider);
    final stock = repo.stock();
    final failed = repo.fetchFailed('inventory');

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const DashboardHeader(eyebrow: 'Rasoi Care operations', title: 'Stock & inventory'),
            Expanded(
              child: stock != null
                  ? _StockBody(stock: stock)
                  : failed
                      ? EmptyState(
                          glyph: '⚠',
                          title: "Couldn't load stock",
                          body: 'Check your connection and try again.',
                          action: FilledButton(
                            onPressed: () => repo.retryFetch('inventory'),
                            child: const Text('Retry'),
                          ),
                        )
                      : const Center(child: CircularProgressIndicator()),
            ),
          ],
        ),
      ),
    );
  }
}

class _StockBody extends ConsumerWidget {
  const _StockBody({required this.stock});
  final List<AdminStockItem> stock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lowCount = stock.where((s) => s.low).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
      children: [
        if (stock.isEmpty)
          const EmptyState(
              glyph: '◌', title: 'No stock items yet', body: 'Inventory items will appear here.')
        else ...[
          if (lowCount > 0)
            CareCard(
              color: context.scheme.errorContainer,
              borderColor: Colors.transparent,
              child: Text('$lowCount SKUs below reorder level',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: context.scheme.error)),
            ),
          if (lowCount > 0) const SizedBox(height: 12),
          Stagger(children: [
            for (final s in stock)
              CareCard(
                onTap: () => _openAdjust(context, ref, s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(s.name,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                        Mono(s.sku, color: context.care.inkMuted),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${s.inStock} in stock · reorder at ${s.reorderAt}',
                            style: context.type.bodySmall),
                        StatusChip(s.low ? 'Low' : 'Healthy',
                            tone: s.low ? ChipTone.danger : ChipTone.success, height: 24),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: Radii.pill,
                      child: LinearProgressIndicator(
                        value: s.fillFraction,
                        minHeight: 6,
                        backgroundColor: context.care.hairline,
                        valueColor: AlwaysStoppedAnimation(
                            s.low ? context.scheme.error : context.care.success),
                      ),
                    ),
                  ],
                ),
              ),
          ]),
        ],
      ],
    );
  }

  void _openAdjust(BuildContext context, WidgetRef ref, AdminStockItem s) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AdjustStockSheet(item: s),
    );
  }
}

class _AdjustStockSheet extends ConsumerStatefulWidget {
  const _AdjustStockSheet({required this.item});
  final AdminStockItem item;
  @override
  ConsumerState<_AdjustStockSheet> createState() => _AdjustStockSheetState();
}

class _AdjustStockSheetState extends ConsumerState<_AdjustStockSheet> {
  late int _quantity = widget.item.inStock;
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await ref
        .read(operationsRepositoryProvider)
        .adjustStock(widget.item.id, quantity: _quantity);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not update stock — check connection.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.item.name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Mono(widget.item.sku, color: context.care.inkMuted),
          const SizedBox(height: 20),
          Eyebrow('On-hand quantity'),
          const SizedBox(height: 10),
          Row(
            children: [
              IconButton(
                onPressed: _quantity <= 0 ? null : () => setState(() => _quantity--),
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Expanded(
                child: Text('$_quantity',
                    textAlign: TextAlign.center,
                    style: CareType.mono(context.scheme.onSurface, size: 24, w: FontWeight.w600)),
              ),
              IconButton(
                onPressed: () => setState(() => _quantity++),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Reorder level: ${widget.item.reorderAt}', style: context.type.bodySmall),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving || _quantity == widget.item.inStock ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save quantity'),
            ),
          ),
        ],
      ),
    );
  }
}
