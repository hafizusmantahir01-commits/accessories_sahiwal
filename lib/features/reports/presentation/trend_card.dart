import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../sales/data/sales_repository.dart';
import '../../sales/domain/sale.dart';
import '../data/reports_repository.dart';

/// Owner dashboard: last 30 days of sales as bars (+ profit), best day and
/// the 5 best-selling products. Only shown while the private area is open.
class TrendCard extends ConsumerStatefulWidget {
  const TrendCard({super.key});

  @override
  ConsumerState<TrendCard> createState() => _TrendCardState();
}

class _TrendCardState extends ConsumerState<TrendCard> {
  bool _profit = false;
  int? _touched;

  @override
  Widget build(BuildContext context) {
    final days = ref.watch(last30DaysProvider);
    final top = ref.watch(profitByProductProvider(SalesPeriod.month.window));
    final theme = Theme.of(context);
    final barColor = _profit ? Colors.green.shade600 : theme.colorScheme.primary;

    return SectionCard(
      title: 'Last 30 days',
      trailing: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: false, label: Text('Sales')),
          ButtonSegment(value: true, label: Text('Profit')),
        ],
        selected: {_profit},
        onSelectionChanged: (v) => setState(() => _profit = v.first),
      ),
      child: days.when(
        loading: () => const SizedBox(height: 160, child: Center(child: CircularProgressIndicator())),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(last30DaysProvider)),
        data: (points) {
          if (points.isEmpty) return const Text('No data yet.');
          Decimal valueOf(DayPoint p) => _profit ? p.profit : p.sales;
          final maxV = points.map(valueOf).fold<Decimal>(Decimal.zero, (a, b) => b > a ? b : a);
          final total = points.fold<Decimal>(Decimal.zero, (a, p) => a + valueOf(p));
          final best = points.reduce((a, b) => valueOf(b) > valueOf(a) ? b : a);
          final shown = _touched != null && _touched! < points.length ? points[_touched!] : null;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                shown == null
                    ? '${_profit ? 'Profit' : 'Sales'} in 30 days: ${Money.format(total)}'
                    : '${BizTime.date(shown.day)}: ${Money.format(valueOf(shown))} · ${shown.bills} bills',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 140,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < points.length; i++)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (_) => setState(() => _touched = _touched == i ? null : i),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 1),
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor: maxV <= Decimal.zero || valueOf(points[i]) <= Decimal.zero
                                    ? 0.02
                                    : (valueOf(points[i]).toDouble() / maxV.toDouble()).clamp(0.02, 1.0),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        (_touched == i ? Colors.amber.shade700 : barColor),
                                        (_touched == i ? Colors.amber.shade700 : barColor).withValues(alpha: 0.55),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(children: [
                Text(BizTime.date(points.first.day), style: theme.textTheme.bodySmall),
                const Spacer(),
                Text('Today', style: theme.textTheme.bodySmall),
              ]),
              if (valueOf(best) > Decimal.zero) ...[
                const SizedBox(height: 8),
                Text('Best day: ${BizTime.date(best.day)} · ${Money.format(valueOf(best))}',
                    style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
              ],
              const Divider(height: 24),
              Text('Top 5 selling products', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              top.when(
                loading: () => const LinearProgressIndicator(),
                error: (e, _) => ErrorView(error: e),
                data: (rows) {
                  final list = [...rows]..sort((a, b) => b.pieces.compareTo(a.pieces));
                  final five = list.take(5).toList();
                  if (five.isEmpty) return const Text('No sales in the last 30 days.');
                  final maxPcs = five.first.pieces <= 0 ? 1 : five.first.pieces;
                  return Column(
                    children: [
                      for (final ProductProfit p in five)
                        InkWell(
                          onTap: () => context.push('/products/${p.productId}'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 4,
                                  child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: (p.pieces / maxPcs).clamp(0.0, 1.0),
                                      minHeight: 8,
                                    ),
                                  ),
                                ),
                                SizedBox(width: 56, child: Text('${p.pieces} pcs', textAlign: TextAlign.end)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
