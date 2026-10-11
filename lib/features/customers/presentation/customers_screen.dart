import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../../auth/data/auth_repository.dart';
import '../../sales/data/sales_repository.dart';
import '../../sales/domain/sale.dart';
import '../data/customers_repository.dart';

/// Shopkeeper ledger (khata): every shop with its bills and amount.
class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  final _search = TextEditingController();
  String _query = '';
  bool _shopsOnly = true;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(ledgerProvider((_query, _shopsOnly)));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shopkeepers'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(ledgerProvider),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(ledgerProvider),
        child: ListView(
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search shop name or phone',
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () => setState(() {
                                _search.clear();
                                _query = '';
                              }),
                            ),
                    ),
                    onSubmitted: (v) => setState(() => _query = v.trim()),
                    onChanged: (v) {
                      if (v.isEmpty && _query.isNotEmpty) setState(() => _query = '');
                    },
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, children: [
                    ChoiceChip(label: const Text('Shopkeepers'), selected: _shopsOnly, onSelected: (_) => setState(() => _shopsOnly = true)),
                    ChoiceChip(label: const Text('All customers'), selected: !_shopsOnly, onSelected: (_) => setState(() => _shopsOnly = false)),
                  ]),
                  const SizedBox(height: 12),
                  AsyncView<List<LedgerRow>>(
                    value: list,
                    onRetry: () => ref.invalidate(ledgerProvider),
                    data: (rows) {
                      if (rows.isEmpty) {
                        return const EmptyState(icon: Icons.storefront_outlined, title: 'No shopkeepers yet',
                            message: 'A shop is saved automatically with its first wholesale sale.');
                      }
                      return Column(
                        children: [
                          for (final r in rows) ...[
                            Card3D(
                              tilt: false,
                              radius: 14,
                              padding: const EdgeInsets.all(14),
                              onTap: () => context.push('/customers/${r.id}'),
                              child: Row(
                                children: [
                                  IconBadge3D(
                                    icon: r.isShopkeeper ? Icons.storefront_outlined : Icons.person_outline,
                                    color: r.isShopkeeper ? AppTheme.warning : theme.colorScheme.primary,
                                    size: 40,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(r.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                                        Text(
                                          [
                                            '${r.bills} bills',
                                            if (r.lastSaleAt != null) 'last ${BizTime.date(r.lastSaleAt)}',
                                            if (r.phone.isNotEmpty) r.phone,
                                          ].join(' · '),
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(Money.format(r.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
                                      if (r.profit != null)
                                        Text('profit ${Money.format(r.profit)}',
                                            style: theme.textTheme.bodySmall?.copyWith(color: Colors.green.shade700)),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
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

/// One shop: totals, what it buys (with last rate) and all its bills.
class CustomerDetailScreen extends ConsumerWidget {
  const CustomerDetailScreen({super.key, required this.customerId});
  final String customerId;

  Future<void> _edit(BuildContext context, WidgetRef ref, LedgerRow r) async {
    final name = TextEditingController(text: r.name);
    final phone = TextEditingController(text: r.phone);
    final address = TextEditingController(text: r.address);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit shop'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name *')),
            const SizedBox(height: 8),
            TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
            const SizedBox(height: 8),
            TextField(controller: address, decoration: const InputDecoration(labelText: 'Address')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty) Navigator.pop(ctx, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(customersRepositoryProvider).update(r.id, name: name.text, phone: phone.text, address: address.text);
      ref
        ..invalidate(ledgerProvider)
        ..invalidate(customersProvider);
      if (context.mounted) context.showSuccess('Saved.');
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(ledgerProvider(('', false)));
    final products = ref.watch(customerProductsProvider(customerId));
    final bills = ref.watch(customerSalesProvider(customerId));
    final isOwner = ref.watch(isOwnerProvider);
    final theme = Theme.of(context);
    LedgerRow? row;
    if (all.hasValue) {
      for (final r in all.requireValue) {
        if (r.id == customerId) row = r;
      }
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(row?.name ?? 'Shop'),
          actions: [
            if (isOwner && row != null)
              IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(context, ref, row!)),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Products'), Tab(text: 'Bills')]),
        ),
        body: Column(
          children: [
            if (row != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Card3D(
                  maxAngle: 0.04,
                  padding: const EdgeInsets.all(16),
                  colors: AppTheme.heroColors,
                  child: Wrap(
                    spacing: 20,
                    runSpacing: 8,
                    children: [
                      _Stat('Total bought', Money.format(row.amount)),
                      _Stat('Bills', '${row.bills}'),
                      if (row.returns.signum > 0) _Stat('Returns', Money.format(row.returns)),
                      if (row.lastSaleAt != null) _Stat('Last bill', BizTime.date(row.lastSaleAt)),
                      if (row.profit != null) _Stat('Your profit', Money.format(row.profit)),
                      if (row.phone.isNotEmpty) _Stat('Phone', row.phone),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  AsyncView<List<CustomerProduct>>(
                    value: products,
                    onRetry: () => ref.invalidate(customerProductsProvider(customerId)),
                    data: (list) => list.isEmpty
                        ? const EmptyState(icon: Icons.inventory_2_outlined, title: 'No products bought yet')
                        : ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              for (final p in list)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text('${p.name} · ${p.code}', maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text('${p.pieces} pcs · ${Money.format(p.amount)}'
                                      '${p.lastSoldAt != null ? ' · last ${BizTime.date(p.lastSoldAt)}' : ''}'),
                                  trailing: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text('Last rate', style: theme.textTheme.bodySmall),
                                      Text(Money.format(p.lastPrice), style: const TextStyle(fontWeight: FontWeight.w700)),
                                    ],
                                  ),
                                  onTap: () => context.push('/products/${p.productId}'),
                                ),
                            ],
                          ),
                  ),
                  AsyncView<List<Sale>>(
                    value: bills,
                    onRetry: () => ref.invalidate(customerSalesProvider(customerId)),
                    data: (list) => list.isEmpty
                        ? const EmptyState(icon: Icons.receipt_long_outlined, title: 'No bills yet')
                        : ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              for (final s in list)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(s.isVoided ? Icons.cancel_outlined : Icons.receipt_long_outlined,
                                      color: s.isVoided ? AppTheme.danger : null),
                                  title: Text(s.invoiceNo,
                                      style: TextStyle(decoration: s.isVoided ? TextDecoration.lineThrough : null)),
                                  subtitle: Text('${BizTime.dateTime(s.completedAt)} · ${s.itemCount} pcs'),
                                  trailing: Text(Money.format(s.total), style: const TextStyle(fontWeight: FontWeight.w700)),
                                  onTap: () => context.push('/sales/${s.id}'),
                                ),
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

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
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
