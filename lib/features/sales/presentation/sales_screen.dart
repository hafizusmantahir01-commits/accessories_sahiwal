import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../../auth/data/auth_repository.dart';
import '../../private_area/data/private_area_controller.dart';
import '../data/sales_repository.dart';
import '../domain/sale.dart';

/// Sales history: period tabs, totals, list. Profit only for the unlocked owner.
class SalesScreen extends ConsumerStatefulWidget {
  const SalesScreen({super.key});

  @override
  ConsumerState<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends ConsumerState<SalesScreen> {
  SalesPeriod _period = SalesPeriod.today;
  SaleType? _type; // null = both

  void _refresh() {
    ref.invalidate(salesListProvider(_period));
    ref.invalidate(salesSummaryProvider(_period));
    ref.invalidate(ownerProfitProvider(_period));
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileOrNullProvider);
    final isOwner = profile?.isOwner ?? false;
    final canSell = isOwner || (profile?.canCreateSale ?? false);
    final unlocked = ref.watch(privateAreaProvider.select((s) => s.unlocked));
    final list = ref.watch(salesListProvider(_period));
    final summary = ref.watch(salesSummaryProvider(_period));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales'),
        actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh)],
      ),
      floatingActionButton: canSell
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/sales/new?type=${_type?.value ?? 'retail'}'),
              icon: const Icon(Icons.add_shopping_cart),
              label: const Text('New sale'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<SalesPeriod>(
                    segments: [for (final p in SalesPeriod.values) ButtonSegment(value: p, label: Text(p.label))],
                    selected: {_period},
                    onSelectionChanged: (s) => setState(() => _period = s.first),
                  ),
                  const SizedBox(height: 12),
                  summary.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => ErrorView(error: e, onRetry: _refresh),
                    data: (s) => Card3D(
                      maxAngle: 0.05,
                      padding: const EdgeInsets.all(18),
                      colors: const [Color(0xFF0B1A4A), Color(0xFF14286B), Color(0xFF2563EB)],
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Net sales · ${_period.label}', style: const TextStyle(color: Colors.white70)),
                          const SizedBox(height: 4),
                          Text(Money.format(s.netSales),
                              style: theme.textTheme.headlineMedium
                                  ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 10),
                          Wrap(spacing: 18, runSpacing: 6, children: [
                            _WhiteStat('Bills', '${s.count}'),
                            _WhiteStat('Wholesale', Money.format(s.wholesale)),
                            _WhiteStat('Retail', Money.format(s.retail)),
                            if (s.discounts.signum > 0) _WhiteStat('Discounts given', Money.format(s.discounts)),
                          ]),
                        ],
                      ),
                    ),
                  ),
                  if (isOwner) ...[
                    const SizedBox(height: 12),
                    if (unlocked)
                      _ProfitCard(period: _period)
                    else
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.lock_outline),
                          title: const Text('Profit is locked'),
                          subtitle: const Text('Unlock the Private Area to see cost and profit.'),
                          onTap: () => context.go('/private/unlock?from=/sales'),
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, children: [
                    ChoiceChip(label: const Text('All'), selected: _type == null, onSelected: (_) => setState(() => _type = null)),
                    for (final t in SaleType.values)
                      ChoiceChip(label: Text(t.label), selected: _type == t, onSelected: (_) => setState(() => _type = t)),
                  ]),
                  const SizedBox(height: 8),
                  AsyncView<List<Sale>>(
                    value: list,
                    onRetry: _refresh,
                    data: (all) {
                      final sales = all.where((s) => _type == null || s.type == _type).toList();
                      if (sales.isEmpty) {
                        return const EmptyState(icon: Icons.receipt_long_outlined, title: 'No sales in this period');
                      }
                      return Column(
                        children: [
                          for (final s in sales) ...[
                            _SaleTile(sale: s),
                            const SizedBox(height: 8),
                          ],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WhiteStat extends StatelessWidget {
  const _WhiteStat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ],
      );
}

class _ProfitCard extends ConsumerWidget {
  const _ProfitCard({required this.period});
  final SalesPeriod period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profit = ref.watch(ownerProfitProvider(period));
    return SectionCard(
      title: 'Profit (owner only)',
      child: profit.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorView(error: e),
        data: (m) {
          final net = Money.parse(m['net_sales']);
          final cogs = Money.parse(m['cogs']);
          final gp = Money.parse(m['gross_profit']);
          final margin = net.signum > 0 ? (gp.toDouble() / net.toDouble() * 100) : 0.0;
          return Column(children: [
            InfoRow('Net sales (money received)', Money.format(net)),
            InfoRow('Cost of goods sold', Money.format(cogs)),
            InfoRow('Gross profit', Money.format(gp), bold: true),
            InfoRow('Margin', '${margin.toStringAsFixed(1)}%'),
          ]);
        },
      ),
    );
  }
}

class _SaleTile extends StatelessWidget {
  const _SaleTile({required this.sale});
  final Sale sale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = sale;
    final color = s.type == SaleType.wholesale ? AppTheme.warning : theme.colorScheme.primary;
    return Card3D(
      tilt: false,
      radius: 14,
      padding: const EdgeInsets.all(14),
      onTap: () => context.push('/sales/${s.id}'),
      child: Row(
        children: [
          IconBadge3D(
            icon: s.type == SaleType.wholesale ? Icons.storefront_outlined : Icons.person_outline,
            color: s.isVoided ? AppTheme.danger : color,
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${s.invoiceNo} · ${s.customerName.isNotEmpty ? s.customerName : s.type.label}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    decoration: s.isVoided ? TextDecoration.lineThrough : null,
                  ),
                ),
                Text('${BizTime.dateTime(s.completedAt)} · ${s.itemCount} pcs · ${s.method.label}',
                    style: theme.textTheme.bodySmall),
                if (s.discount.signum > 0)
                  Text('Bill ${Money.format(s.subtotal)} → received ${Money.format(s.total)}',
                      style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warning)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(Money.format(s.total), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              if (s.isVoided) const StatusChip('Voided', color: AppTheme.danger),
            ],
          ),
        ],
      ),
    );
  }
}
