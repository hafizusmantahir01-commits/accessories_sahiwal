import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../data/purchases_repository.dart';
import '../domain/purchase.dart';

class PurchasesScreen extends ConsumerWidget {
  const PurchasesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Purchases'),
          bottom: const TabBar(tabs: [Tab(text: 'Posted'), Tab(text: 'Drafts')]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => context.push('/private/purchases/new'),
          icon: const Icon(Icons.add),
          label: const Text('New purchase'),
        ),
        body: const TabBarView(children: [_PurchaseList(drafts: false), _PurchaseList(drafts: true)]),
      ),
    );
  }
}

class _PurchaseList extends ConsumerWidget {
  const _PurchaseList({required this.drafts});
  final bool drafts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final purchases = ref.watch(purchaseListProvider(drafts));
    return RefreshIndicator(
      onRefresh: () => ref.refresh(purchaseListProvider(drafts).future),
      child: AsyncView<List<PurchaseSummary>>(
        value: purchases,
        onRetry: () => ref.invalidate(purchaseListProvider(drafts)),
        data: (list) {
          if (list.isEmpty) {
            return ListView(children: [
              EmptyState(
                icon: drafts ? Icons.edit_note : Icons.receipt_long_outlined,
                title: drafts ? 'No draft purchases' : 'No posted purchases yet',
              ),
            ]);
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (_, i) {
              final p = list[i];
              return Card(
                child: ListTile(
                  onTap: () => context.push('/private/purchases/${p.id}'),
                  title: Text(p.isDraft ? 'Draft · ${p.supplierName}' : '${p.purchaseNo} · ${p.supplierName}'),
                  subtitle: Text([
                    p.isDraft ? 'Created ${BizTime.dateTime(p.createdAt)}' : 'Posted ${BizTime.dateTime(p.postedAt)}',
                    '${p.itemCount} item${p.itemCount == 1 ? '' : 's'}',
                    if (p.supplierRef.isNotEmpty) 'Bill ${p.supplierRef}',
                    if (!p.isDraft) p.paymentMethod.label,
                  ].join(' · ')),
                  trailing: Text(Money.format(p.total), style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
