import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../data/reports_repository.dart';

/// Stock that has not sold for a long time — money stuck on the shelf.
class DeadStockScreen extends ConsumerStatefulWidget {
  const DeadStockScreen({super.key});

  @override
  ConsumerState<DeadStockScreen> createState() => _DeadStockScreenState();
}

class _DeadStockScreenState extends ConsumerState<DeadStockScreen> {
  int _days = 60;

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(deadStockProvider(_days));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Not selling (dead stock)')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(deadStockProvider),
        child: ListView(
          children: [
            PageBody(
              maxWidth: 760,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(spacing: 8, children: [
                    for (final d in const [30, 60, 90, 180])
                      ChoiceChip(
                        label: Text('$d+ days'),
                        selected: _days == d,
                        onSelected: (_) => setState(() => _days = d),
                      ),
                  ]),
                  const SizedBox(height: 12),
                  AsyncView<List<DeadStockRow>>(
                    value: list,
                    onRetry: () => ref.invalidate(deadStockProvider(_days)),
                    data: (rows) {
                      final value = rows.fold(Money.zero, (a, r) => a + r.value);
                      final pcs = rows.fold(0, (a, r) => a + r.qty);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Card3D(
                            maxAngle: 0.05,
                            padding: const EdgeInsets.all(18),
                            colors: AppTheme.heroColors,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Money stuck in items not sold for $_days+ days',
                                    style: const TextStyle(color: Colors.white70)),
                                const SizedBox(height: 4),
                                Text(Money.format(value),
                                    style: theme.textTheme.headlineMedium
                                        ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                                Text('${rows.length} products · $pcs pieces', style: const TextStyle(color: Colors.white70)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text('Tip: give these a discount, show them to shopkeepers, or stop ordering them.',
                              style: theme.textTheme.bodySmall),
                          const SizedBox(height: 12),
                          if (rows.isEmpty)
                            const EmptyState(icon: Icons.thumb_up_alt_outlined, title: 'Everything is selling')
                          else
                            for (final r in rows)
                              Card(
                                child: ListTile(
                                  onTap: () => context.push('/products/${r.productId}'),
                                  title: Text('${r.name} · ${r.code}', maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text('${r.qty} pcs · '
                                      '${r.lastSoldAt == null ? 'never sold' : 'last sold ${BizTime.date(r.lastSoldAt)}'}'
                                      ' · ${r.daysIdle} days'),
                                  trailing: Text(Money.format(r.value), style: const TextStyle(fontWeight: FontWeight.w700)),
                                ),
                              ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
