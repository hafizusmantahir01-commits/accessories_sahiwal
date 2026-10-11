import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../data/reports_repository.dart';

/// "What to order": from how fast each product sells, how many to buy so the
/// stock lasts the chosen number of days.
class ReorderScreen extends ConsumerStatefulWidget {
  const ReorderScreen({super.key});

  @override
  ConsumerState<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends ConsumerState<ReorderScreen> {
  int _days = 30;
  int _cover = 15;
  final Map<String, int> _qty = {}; // selected product → quantity to order

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(reorderProvider((_days, _cover)));
    final theme = Theme.of(context);
    final rows = list.hasValue ? list.requireValue : const <ReorderRow>[];
    var cost = Decimal.zero;
    for (final r in rows) {
      final q = _qty[r.productId];
      if (q != null && r.lastRate != null) cost += r.lastRate! * Decimal.fromInt(q);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('What to order')),
      floatingActionButton: _qty.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => context.push(
                  '/private/purchases/new?products=${_qty.entries.map((e) => '${e.key}:${e.value}').join(',')}'),
              icon: const Icon(Icons.add_shopping_cart),
              label: Text('Make purchase (${_qty.length})'),
            ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          PageBody(
            maxWidth: 820,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Based on sales of the last', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                Wrap(spacing: 8, children: [
                  for (final d in const [30, 60, 90])
                    ChoiceChip(label: Text('$d days'), selected: _days == d, onSelected: (_) => setState(() {
                          _days = d;
                          _qty.clear();
                        })),
                ]),
                const SizedBox(height: 8),
                Text('Stock should last', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                Wrap(spacing: 8, children: [
                  for (final c in const [7, 15, 30, 60])
                    ChoiceChip(label: Text('$c days'), selected: _cover == c, onSelected: (_) => setState(() {
                          _cover = c;
                          _qty.clear();
                        })),
                ]),
                const SizedBox(height: 12),
                if (rows.isNotEmpty)
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => setState(() {
                          if (_qty.length == rows.where((r) => r.suggested > 0).length) {
                            _qty.clear();
                          } else {
                            _qty
                              ..clear()
                              ..addAll({for (final r in rows) if (r.suggested > 0) r.productId: r.suggested});
                          }
                        }),
                        child: const Text('Select all suggested'),
                      ),
                      const Spacer(),
                      if (_qty.isNotEmpty) Text('Approx. cost ${Money.format(cost)}', style: theme.textTheme.titleSmall),
                    ],
                  ),
                AsyncView<List<ReorderRow>>(
                  value: list,
                  onRetry: () => ref.invalidate(reorderProvider((_days, _cover))),
                  data: (rows) {
                    if (rows.isEmpty) {
                      return const EmptyState(icon: Icons.check_circle_outline, title: 'Nothing needs ordering right now');
                    }
                    return Column(
                      children: [
                        for (final r in rows)
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              child: Row(
                                children: [
                                  Checkbox(
                                    value: _qty.containsKey(r.productId),
                                    onChanged: (v) => setState(() {
                                      if (v == true) {
                                        _qty[r.productId] = r.suggested > 0 ? r.suggested : 1;
                                      } else {
                                        _qty.remove(r.productId);
                                      }
                                    }),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('${r.name} · ${r.code}',
                                            maxLines: 1, overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontWeight: FontWeight.w600)),
                                        Text(
                                          'Stock ${r.stock} · sold ${r.sold} in $_days days'
                                          '${r.daysLeft != null ? ' · lasts ~${r.daysLeft!.toStringAsFixed(0)} days' : ''}'
                                          '${r.lastRate != null ? ' · last rate ${Money.format(r.lastRate)}' : ''}',
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 72,
                                    child: TextFormField(
                                      key: ValueKey('${r.productId}-$_days-$_cover-${_qty.containsKey(r.productId)}'),
                                      initialValue: '${_qty[r.productId] ?? r.suggested}',
                                      keyboardType: TextInputType.number,
                                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                      textAlign: TextAlign.center,
                                      decoration: const InputDecoration(isDense: true, labelText: 'Order'),
                                      onChanged: (v) => setState(() {
                                        final n = int.tryParse(v) ?? 0;
                                        if (n > 0) {
                                          _qty[r.productId] = n;
                                        } else {
                                          _qty.remove(r.productId);
                                        }
                                      }),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
