import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/brand_logo.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../../auth/data/auth_repository.dart';
import '../../private_area/data/private_area_controller.dart';
import '../../sales/data/sales_repository.dart';
import '../../stock/data/stock_repository.dart';
import '../../valuation/data/valuation_repository.dart';
import '../../private_area/presentation/stock_locked.dart';

/// Role-specific summary. Partners see quantities only; the owner sees stock
/// value only while the private area is unlocked (fetched from the server then).
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileOrNullProvider);
    final isOwner = profile?.isOwner ?? false;
    final unlocked = ref.watch(privateAreaProvider.select((s) => s.unlocked));
    final stock = ref.watch(stockListProvider(const StockQuery()));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const BrandHeader(logoSize: 32),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(stockListProvider);
              ref.invalidate(salesSummaryProvider(SalesPeriod.today.window));
              if (unlocked) {
                ref.invalidate(valuationProvider);
                ref.invalidate(ownerProfitProvider(SalesPeriod.today.window));
              }
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(stockListProvider(const StockQuery()).future),
        child: ListView(
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card3D(
                    maxAngle: 0.05,
                    padding: const EdgeInsets.all(20),
                    colors: AppTheme.heroColors,
                    child: Row(
                      children: [
                        const Spin3D(angle: 0.35, child: Monogram(text: 'AS', size: 64)),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            'Assalam-o-Alaikum',
                            style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _TodaySalesCard(showProfit: isOwner && unlocked),
                  const SizedBox(height: 16),
                  stock.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(stockListProvider)),
                    data: (items) {
                      if (!ref.watch(stockVisibleProvider)) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _StatGrid(children: [
                              _Stat(label: 'Active products', value: '${items.length}', icon: Icons.inventory_2_outlined,
                                  onTap: () => context.go('/products')),
                            ]),
                            const SizedBox(height: 12),
                            const StockLockedCard(returnTo: '/'),
                          ],
                        );
                      }
                      final totalUnits = items.fold<int>(0, (a, s) => a + s.saleableQty);
                      final low = items.where((s) => s.isLow && s.saleableQty > 0).length;
                      final out = items.where((s) => s.saleableQty == 0).length;
                      return _StatGrid(children: [
                        _Stat(label: 'Active products', value: '${items.length}', icon: Icons.inventory_2_outlined,
                            onTap: () => context.go('/products')),
                        _Stat(label: 'Units in stock', value: '$totalUnits', icon: Icons.warehouse_outlined,
                            onTap: () => context.go('/stock')),
                        _Stat(label: 'Low stock', value: '$low', icon: Icons.warning_amber_rounded,
                            color: low > 0 ? AppTheme.warning : null, onTap: () => context.go('/stock?low=1')),
                        _Stat(label: 'Out of stock', value: '$out', icon: Icons.remove_shopping_cart_outlined,
                            color: out > 0 ? AppTheme.danger : null, onTap: () => context.go('/stock?low=1')),
                      ]);
                    },
                  ),
                  if (isOwner) ...[
                    const SizedBox(height: 16),
                    if (unlocked) const _OwnerValueCard() else const _LockedOwnerCard(),
                  ],
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Shortcuts',
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (isOwner || (profile?.canCreateSale ?? false)) ...[
                          ActionChip(avatar: const Icon(Icons.storefront_outlined), label: const Text('Wholesale sale'),
                              onPressed: () => context.push('/sales/new?type=wholesale')),
                          ActionChip(avatar: const Icon(Icons.point_of_sale), label: const Text('Retail sale'),
                              onPressed: () => context.push('/sales/new?type=retail')),
                        ],
                        ActionChip(avatar: const Icon(Icons.search), label: const Text('Find product'),
                            onPressed: () => context.go('/products')),
                        ActionChip(avatar: const Icon(Icons.photo_library_outlined), label: const Text('Gallery'),
                            onPressed: () => context.go('/gallery')),
                        ActionChip(avatar: const Icon(Icons.slideshow_outlined), label: const Text('Customer view'),
                            onPressed: () => context.go('/display')),
                        if (isOwner) ...[
                          ActionChip(avatar: const Icon(Icons.add_box_outlined), label: const Text('New product'),
                              onPressed: () => context.push('/products/new')),
                          ActionChip(avatar: const Icon(Icons.shopping_cart_outlined), label: const Text('New purchase'),
                              onPressed: () => context.go('/private/purchases/new')),
                        ],
                      ],
                    ),
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

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final columns = c.maxWidth >= 800 ? 4 : 2;
      final width = (c.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [for (final w in children) SizedBox(width: width, child: w)],
      );
    });
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.icon, this.color, this.onTap});
  final String label;
  final String value;
  final IconData icon;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.primary;
    return Card3D(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconBadge3D(icon: icon, color: c),
          const SizedBox(height: 12),
          Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: c)),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _LockedOwnerCard extends StatelessWidget {
  const _LockedOwnerCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.lock_outline),
        title: const Text('Stock value and costs are locked'),
        subtitle: const Text('Unlock the Owner Private Area to view financial figures.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.go('/private'),
      ),
    );
  }
}

class _OwnerValueCard extends ConsumerWidget {
  const _OwnerValueCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuation = ref.watch(valuationProvider);
    return SectionCard(
      title: 'Stock value (owner only)',
      trailing: TextButton(onPressed: () => context.go('/private/valuation'), child: const Text('Details')),
      child: valuation.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorView(error: e),
        data: (rows) {
          final total = rows.fold(Money.zero, (a, r) => a + r.carryingValue);
          return Text(Money.format(total),
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700));
        },
      ),
    );
  }
}

class _TodaySalesCard extends ConsumerWidget {
  const _TodaySalesCard({required this.showProfit});
  final bool showProfit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(salesSummaryProvider(SalesPeriod.today.window));
    final theme = Theme.of(context);
    return Card3D(
      onTap: () => context.go('/sales'),
      child: summary.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorView(error: e),
        data: (s) => Row(
          children: [
            IconBadge3D(icon: Icons.point_of_sale, color: theme.colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Today's sales", style: theme.textTheme.bodySmall),
                  Text(Money.format(s.netSales),
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                  Text('${s.count} bills · Wholesale ${Money.format(s.wholesale)} · Retail ${Money.format(s.retail)}',
                      style: theme.textTheme.bodySmall),
                  if (showProfit)
                    ref.watch(ownerProfitProvider(SalesPeriod.today.window)).when(
                          loading: () => const SizedBox.shrink(),
                          error: (_, _) => const SizedBox.shrink(),
                          data: (m) => Text('Profit today: ${Money.format(m['gross_profit'])}',
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: AppTheme.success, fontWeight: FontWeight.w700)),
                        ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
