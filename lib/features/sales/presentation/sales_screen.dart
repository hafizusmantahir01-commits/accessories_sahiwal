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

/// Sales history for any period: today, 7/30 days, this month/year, any past
/// year, all time (since the app started) or custom dates.
/// Profit only for the unlocked owner.
class SalesScreen extends ConsumerStatefulWidget {
  const SalesScreen({super.key});

  @override
  ConsumerState<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends ConsumerState<SalesScreen> {
  SalesPeriod? _period = SalesPeriod.today; // null = a picked year or custom dates
  SalesWindow _window = SalesPeriod.today.window;
  SaleType? _type; // null = both

  void _refresh() {
    ref.invalidate(salesListProvider(_window));
    ref.invalidate(salesSummaryProvider(_window));
    ref.invalidate(ownerProfitProvider(_window));
    ref.invalidate(profitByMonthProvider(_window));
    ref.invalidate(profitByProductProvider(_window));
    ref.invalidate(firstSaleDateProvider);
  }

  void _setPeriod(SalesPeriod p) => setState(() {
        _period = p;
        _window = p.window;
      });

  Future<void> _pickYear() async {
    final firstAsync = ref.read(firstSaleDateProvider);
    final first = firstAsync.hasValue ? firstAsync.requireValue : null;
    final now = BizTime.today().year;
    final firstYear = first?.year ?? now;
    final years = [for (var y = now; y >= firstYear; y--) y];
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Choose a year', style: TextStyle(fontWeight: FontWeight.w700))),
            for (final y in years)
              ListTile(
                leading: const Icon(Icons.calendar_month_outlined),
                title: Text('$y'),
                trailing: _period == null && _window == yearWindow(y) ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, y),
              ),
            if (first == null)
              const ListTile(subtitle: Text('Years appear here once sales are recorded.')),
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _period = null;
        _window = yearWindow(picked);
      });
    }
  }

  Future<void> _pickDates() async {
    final today = BizTime.today();
    final firstAsync = ref.read(firstSaleDateProvider);
    final first = firstAsync.hasValue ? firstAsync.requireValue : null;
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: today,
      initialDateRange: DateTimeRange(
        start: _window.from.isBefore(DateTime(2001)) ? (first ?? today) : _window.from,
        end: _window.to,
      ),
      helpText: 'Choose dates',
    );
    if (r != null && mounted) {
      setState(() {
        _period = null;
        _window = SalesWindow(r.start, r.end, '${BizTime.date(r.start)} – ${BizTime.date(r.end)}');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileOrNullProvider);
    final isOwner = profile?.isOwner ?? false;
    final canSell = isOwner || (profile?.canCreateSale ?? false);
    final unlocked = ref.watch(privateAreaProvider.select((s) => s.unlocked));
    final list = ref.watch(salesListProvider(_window));
    final summary = ref.watch(salesSummaryProvider(_window));
    ref.watch(firstSaleDateProvider); // keeps the year list ready
    final theme = Theme.of(context);
    final w = _window;
    final pickedYear = _period == null && w.from.month == 1 && w.from.day == 1 && w.label.startsWith('Year ');
    final custom = _period == null && !pickedYear;

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
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in SalesPeriod.values)
                        ChoiceChip(label: Text(p.label), selected: _period == p, onSelected: (_) => _setPeriod(p)),
                      ChoiceChip(
                        avatar: const Icon(Icons.calendar_month_outlined, size: 18),
                        label: Text(pickedYear ? w.label.replaceFirst('Year ', '') : 'Year…'),
                        selected: pickedYear,
                        onSelected: (_) => _pickYear(),
                      ),
                      ChoiceChip(
                        avatar: const Icon(Icons.date_range_outlined, size: 18),
                        label: const Text('Dates…'),
                        selected: custom,
                        onSelected: (_) => _pickDates(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  summary.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => ErrorView(error: e, onRetry: _refresh),
                    data: (s) => Card3D(
                      maxAngle: 0.05,
                      padding: const EdgeInsets.all(18),
                      colors: AppTheme.heroColors,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Net sales · ${w.label}', style: const TextStyle(color: Colors.white70)),
                          if (_period != SalesPeriod.today)
                            Text(
                              _period == SalesPeriod.all
                                  ? 'Up to ${BizTime.date(w.to)}'
                                  : '${BizTime.date(w.from)} – ${BizTime.date(w.to)}',
                              style: const TextStyle(color: Colors.white60, fontSize: 12),
                            ),
                          const SizedBox(height: 4),
                          Text(Money.format(s.netSales),
                              style: theme.textTheme.headlineMedium
                                  ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 10),
                          Wrap(spacing: 18, runSpacing: 6, children: [
                            _WhiteStat('Bills', '${s.count}'),
                            _WhiteStat('Pieces sold', '${s.pieces}'),
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
                    if (unlocked) ...[
                      _ProfitCard(window: w),
                      if (w.days > 31) ...[
                        const SizedBox(height: 12),
                        _MonthsCard(window: w),
                      ],
                      const SizedBox(height: 12),
                      _ProductsCard(window: w),
                    ] else
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
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (all.length >= 500)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text('Showing the latest 500 bills. Totals above include every bill.',
                                  style: theme.textTheme.bodySmall),
                            ),
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
  const _ProfitCard({required this.window});
  final SalesWindow window;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profit = ref.watch(ownerProfitProvider(window));
    return SectionCard(
      title: 'Profit · ${window.label}',
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

/// Month by month (shown for periods longer than a month).
class _MonthsCard extends ConsumerWidget {
  const _MonthsCard({required this.window});
  final SalesWindow window;

  static const _names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final months = ref.watch(profitByMonthProvider(window));
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Month by month',
      child: months.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorView(error: e),
        data: (list) {
          if (list.isEmpty) return const Text('No sales in this period.');
          return Column(
            children: [
              for (final m in list)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('${_names[m.month.month - 1]} ${m.month.year}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${m.bills} bills · ${m.pieces} pcs · sales ${Money.format(m.netSales)}'),
                  trailing: Text(
                    Money.format(m.profit),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: m.profit.signum < 0 ? AppTheme.danger : Colors.green.shade700,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Which products sold and how much profit each made.
class _ProductsCard extends ConsumerStatefulWidget {
  const _ProductsCard({required this.window});
  final SalesWindow window;

  @override
  ConsumerState<_ProductsCard> createState() => _ProductsCardState();
}

class _ProductsCardState extends ConsumerState<_ProductsCard> {
  bool _all = false;
  bool _byPieces = false;

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(profitByProductProvider(widget.window));
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Products sold',
      trailing: products.hasValue && products.requireValue.length > 1
          ? TextButton(
              onPressed: () => setState(() => _byPieces = !_byPieces),
              child: Text(_byPieces ? 'Sort: pieces' : 'Sort: profit'),
            )
          : null,
      child: products.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorView(error: e),
        data: (raw) {
          if (raw.isEmpty) return const Text('No products sold in this period.');
          final list = [...raw];
          if (_byPieces) list.sort((a, b) => b.pieces.compareTo(a.pieces));
          final shown = _all ? list : list.take(10).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final p in shown)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('${p.name} · ${p.code}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${p.pieces} pcs · sales ${Money.format(p.netSales)} · cost ${Money.format(p.cogs)}'),
                  trailing: Text(
                    Money.format(p.profit),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: p.profit.signum < 0 ? AppTheme.danger : Colors.green.shade700,
                    ),
                  ),
                  onTap: () => context.push('/products/${p.productId}'),
                ),
              if (list.length > 10)
                TextButton(
                  onPressed: () => setState(() => _all = !_all),
                  child: Text(_all ? 'Show top 10' : 'Show all ${list.length} products'),
                ),
            ],
          );
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
