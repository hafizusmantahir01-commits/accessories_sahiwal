import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../auth/data/auth_repository.dart';
import '../../private_area/data/private_area_controller.dart';
import '../../purchases/domain/batch.dart';
import '../data/stock_repository.dart';
import 'stock_history_sheet.dart';

/// Available quantities, owner-only FIFO values, and low-stock alerts.
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
    final isOwner = ref.watch(isOwnerProvider);
    final privateUnlocked = ref.watch(
      privateAreaProvider.select((s) => s.unlocked),
    );
    final fifoValues = isOwner && privateUnlocked
        ? ref.watch(fifoStockValuesProvider(_query))
        : null;
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
                _debounce = Timer(
                  const Duration(milliseconds: 300),
                  () => setState(() => _query = v.trim()),
                );
              },
              decoration: const InputDecoration(
                hintText: 'Search code, name, brand',
                prefixIcon: Icon(Icons.search),
              ),
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
                  Text(
                    '${stock.requireValue.length} items',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(stockListProvider(q));
                await ref.read(stockListProvider(q).future);
                if (fifoValues != null) {
                  ref.invalidate(fifoStockValuesProvider(_query));
                  await ref.read(fifoStockValuesProvider(_query).future);
                }
              },
              child: AsyncView<List<StockItem>>(
                value: stock,
                onRetry: () => ref.invalidate(stockListProvider(q)),
                data: (items) {
                  if (items.isEmpty) {
                    return ListView(
                      children: [
                        EmptyState(
                          icon: Icons.warehouse_outlined,
                          title: _lowOnly
                              ? 'No low-stock items'
                              : 'No stock items',
                        ),
                      ],
                    );
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
                      final fifoValue = fifoValues == null
                          ? null
                          : _valueFor(fifoValues, s.productId);
                      final remainingQuantity =
                          fifoValue?.remainingQuantity ?? s.saleableQty;
                      return Card(
                        child: ListTile(
                          onTap: () {
                            if (isOwner && !privateUnlocked) {
                              context.showError(
                                'Unlock the Owner Private Area to view batch costs.',
                              );
                            } else if (isOwner) {
                              _showBatches(s.productId, s.name);
                            } else {
                              context.push('/products/${s.productId}');
                            }
                          },
                          title: Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              s.code,
                              if (s.categoryName != null) s.categoryName!,
                              if (s.brand.isNotEmpty) s.brand,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          leading: CircleAvatar(
                            backgroundColor: color.withValues(alpha: 0.12),
                            child: Icon(
                              s.saleableQty == 0
                                  ? Icons.remove_shopping_cart_outlined
                                  : (s.isLow
                                        ? Icons.warning_amber_rounded
                                        : Icons.check_circle_outline),
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
                                  Text(
                                    '$remainingQuantity',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          color: color,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                  Text(
                                    s.nonSaleableQty > 0
                                        ? '+${s.nonSaleableQty} damaged'
                                        : 'min ${s.reorderThreshold}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  if (fifoValues != null)
                                    if (fifoValues.hasError)
                                      Tooltip(
                                        message:
                                            'Could not load stock value: ${fifoValues.error}',
                                        child: Icon(
                                          Icons.error_outline,
                                          size: 16,
                                          color: theme.colorScheme.error,
                                        ),
                                      )
                                    else if (fifoValues.isLoading)
                                      const SizedBox(
                                        width: 52,
                                        height: 2,
                                        child: LinearProgressIndicator(),
                                      )
                                    else if (fifoValue != null)
                                      Text(
                                        'Value ${Money.format(fifoValue.stockValue)}',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                ],
                              ),
                              IconButton(
                                tooltip: 'Stock history',
                                icon: const Icon(Icons.history),
                                onPressed: () => showStockHistory(
                                  context,
                                  productId: s.productId,
                                  title: s.name,
                                ),
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

  FifoStockValue? _valueFor(
    AsyncValue<List<FifoStockValue>>? values,
    String productId,
  ) {
    if (values == null || !values.hasValue) return null;
    for (final value in values.requireValue) {
      if (value.productId == productId) return value;
    }
    return null;
  }

  Future<void> _showBatches(String productId, String productName) =>
      showDialog<void>(
        context: context,
        builder: (_) => _ProductBatchesDialog(
          productId: productId,
          productName: productName,
        ),
      );
}

class _ProductBatchesDialog extends ConsumerWidget {
  const _ProductBatchesDialog({
    required this.productId,
    required this.productName,
  });

  final String productId;
  final String productName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batches = ref.watch(productBatchesProvider(productId));
    return AlertDialog(
      title: Text('$productName batches'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.55,
        ),
        child: SizedBox(
          width: 480,
          child: AsyncView<List<Batch>>(
            value: batches,
            onRetry: () => ref.invalidate(productBatchesProvider(productId)),
            data: (items) => items.isEmpty
                ? const EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: 'No remaining batches',
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final batch = items[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(BizTime.dateTime(batch.postedAt)),
                        subtitle: Text('${batch.remainingQuantity} remaining'),
                        trailing: Text(
                          '${Money.format(batch.unitCost)} / unit',
                        ),
                      );
                    },
                  ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
