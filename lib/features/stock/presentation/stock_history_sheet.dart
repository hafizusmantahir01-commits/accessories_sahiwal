import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/common.dart';
import '../data/stock_repository.dart';

/// Partner-safe movement history: dates, types and quantities only.
Future<void> showStockHistory(BuildContext context, {required String productId, required String title}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => _HistoryBody(productId: productId, title: title, controller: controller),
    ),
  );
}

class _HistoryBody extends ConsumerWidget {
  const _HistoryBody({required this.productId, required this.title, required this.controller});
  final String productId;
  final String title;
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(stockHistoryProvider(productId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Stock history — $title', style: Theme.of(context).textTheme.titleMedium),
        ),
        Expanded(
          child: AsyncView<List<StockMovement>>(
            value: history,
            onRetry: () => ref.invalidate(stockHistoryProvider(productId)),
            data: (items) => items.isEmpty
                ? const EmptyState(icon: Icons.history, title: 'No stock movements yet')
                : ListView.separated(
                    controller: controller,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final m = items[i];
                      final positive = m.quantity > 0;
                      return ListTile(
                        title: Text(m.typeLabel),
                        subtitle: Text(
                          '${BizTime.dateTime(m.postedAt)}${m.bucket == 'non_saleable' ? ' · non-saleable' : ''}',
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${positive ? '+' : ''}${m.quantity}',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: positive ? AppTheme.success : AppTheme.danger,
                              ),
                            ),
                            Text('Balance ${m.qtyAfter}', style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
