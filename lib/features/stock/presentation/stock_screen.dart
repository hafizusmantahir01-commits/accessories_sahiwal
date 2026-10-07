import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/widgets/common.dart';
import '../data/stock_repository.dart';
import 'stock_history_sheet.dart';

/// Available quantities and low-stock alerts (no cost data).
class StockScreen extends ConsumerStatefulWidget {
  const StockScreen({super.key, this.lowOnly = false});
  final bool lowOnly;

  @override
  ConsumerState<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends ConsumerState<StockScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  late bool _lowOnly = widget.lowOnly;

  @override
  void didUpdateWidget(StockScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lowOnly != widget.lowOnly) _lowOnly = widget.lowOnly;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = StockQuery(search: _query, lowOnly: _lowOnly);
    final stock = ref.watch(stockListProvider(q));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Stock')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _search,
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () => setState(() => _query = v.trim()));
              },
              decoration: const InputDecoration(hintText: 'Search code, name, brand', prefixIcon: Icon(Icons.search)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('Low stock only'),
                  selected: _lowOnly,
                  onSelected: (v) => setState(() => _lowOnly = v),
                ),
                const Spacer(),
                if (stock.hasValue)
                  Text('${stock.requireValue.length} items', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(stockListProvider(q).future),
              child: AsyncView<List<StockItem>>(
                value: stock,
                onRetry: () => ref.invalidate(stockListProvider(q)),
                data: (items) {
                  if (items.isEmpty) {
                    return ListView(children: [
                      EmptyState(
                        icon: Icons.warehouse_outlined,
                        title: _lowOnly ? 'No low-stock items' : 'No stock items',
                      ),
                    ]);
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, i) {
                      final s = items[i];
                      final color = s.saleableQty == 0
                          ? AppTheme.danger
                          : (s.isLow ? AppTheme.warning : AppTheme.success);
                      return Card(
                        child: ListTile(
                          onTap: () => context.push('/products/${s.productId}'),
                          title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            [s.code, if (s.categoryName != null) s.categoryName!, if (s.brand.isNotEmpty) s.brand].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          leading: CircleAvatar(
                            backgroundColor: color.withValues(alpha: 0.12),
                            child: Icon(
                              s.saleableQty == 0
                                  ? Icons.remove_shopping_cart_outlined
                                  : (s.isLow ? Icons.warning_amber_rounded : Icons.check_circle_outline),
                              color: color,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('${s.saleableQty}',
                                      style: theme.textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w700)),
                                  Text(
                                    s.nonSaleableQty > 0 ? '+${s.nonSaleableQty} damaged' : 'min ${s.reorderThreshold}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                              IconButton(
                                tooltip: 'Stock history',
                                icon: const Icon(Icons.history),
                                onPressed: () => showStockHistory(context, productId: s.productId, title: s.name),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
