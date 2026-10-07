import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../data/valuation_repository.dart';

/// Owner-only stock valuation at moving weighted-average cost.
class StockValuationScreen extends ConsumerStatefulWidget {
  const StockValuationScreen({super.key});

  @override
  ConsumerState<StockValuationScreen> createState() => _StockValuationScreenState();
}

class _StockValuationScreenState extends ConsumerState<StockValuationScreen> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final valuation = ref.watch(valuationProvider);
    final reconcile = ref.watch(reconcileProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Stock valuation')),
      body: AsyncView<List<ValuationRow>>(
        value: valuation,
        onRetry: () => ref.invalidate(valuationProvider),
        data: (all) {
          final rows = _filter.isEmpty
              ? all
              : all.where((r) =>
                  r.name.toLowerCase().contains(_filter.toLowerCase()) ||
                  r.code.toLowerCase().contains(_filter.toLowerCase())).toList();
          final totalValue = all.fold(Money.zero, (a, r) => a + r.carryingValue);
          final totalUnits = all.fold<int>(0, (a, r) => a + r.qty);
          final mismatches = reconcile.hasValue ? reconcile.requireValue.where((r) => !r.ok).toList() : const <ReconcileRow>[];

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(reconcileProvider);
              await ref.refresh(valuationProvider.future);
            },
            child: ListView(
              children: [
                PageBody(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionCard(
                        child: Wrap(
                          spacing: 32,
                          runSpacing: 12,
                          children: [
                            _Figure('Total stock value', Money.format(totalValue)),
                            _Figure('Units on hand', '$totalUnits'),
                            _Figure('Products', '${all.length}'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (reconcile.hasValue)
                        Card(
                          color: mismatches.isEmpty ? Colors.green.shade50 : theme.colorScheme.errorContainer,
                          child: ListTile(
                            leading: Icon(mismatches.isEmpty ? Icons.verified_outlined : Icons.error_outline),
                            title: Text(mismatches.isEmpty
                                ? 'Stock balances reconcile with the movement ledger'
                                : '${mismatches.length} product(s) do not reconcile: ${mismatches.map((m) => m.code).join(', ')}'),
                          ),
                        ),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: const InputDecoration(hintText: 'Filter by name or code', prefixIcon: Icon(Icons.search)),
                        onChanged: (v) => setState(() => _filter = v.trim()),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Value = remaining units × moving weighted-average landed cost. '
                        'Unsold stock is an asset, not an expense.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      for (final r in rows)
                        Card(
                          margin: const EdgeInsets.only(bottom: 6),
                          child: ListTile(
                            onTap: () => context.push('/products/${r.productId}'),
                            title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${r.code} · ${r.qty} × ${Money.format(r.averageCost)} avg'),
                            trailing: Text(Money.format(r.carryingValue),
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ),
                      if (rows.isEmpty) const EmptyState(icon: Icons.inventory_outlined, title: 'No products'),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      ],
    );
  }
}
