import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../data/purchases_repository.dart';
import '../domain/purchase.dart';
import 'post_purchase_dialog.dart';

class PurchaseDetailScreen extends ConsumerWidget {
  const PurchaseDetailScreen({super.key, required this.purchaseId});
  final String purchaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final purchase = ref.watch(purchaseProvider(purchaseId));
    return Scaffold(
      appBar: AppBar(
        title: Text(purchase.hasValue
            ? (purchase.requireValue.isDraft ? 'Draft purchase' : purchase.requireValue.purchaseNo ?? 'Purchase')
            : 'Purchase'),
      ),
      body: AsyncView<Purchase>(
        value: purchase,
        onRetry: () => ref.invalidate(purchaseProvider(purchaseId)),
        data: (p) => ListView(
          children: [
            PageBody(
              maxWidth: 900,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionCard(
                    title: 'Bill',
                    trailing: StatusChip(p.isDraft ? 'Draft' : 'Posted · Paid',
                        color: p.isDraft ? Colors.orange.shade800 : Colors.green.shade700),
                    child: Column(
                      children: [
                        InfoRow('Supplier', p.supplierName),
                        InfoRow('Bill date', BizTime.date(p.documentDate)),
                        if (p.supplierRef.isNotEmpty) InfoRow('Supplier bill no.', p.supplierRef),
                        if (p.postedAt != null) InfoRow('Posted', BizTime.dateTime(p.postedAt)),
                        InfoRow('Payment', p.paymentMethod.label),
                        if ((p.paymentReference ?? '').isNotEmpty) InfoRow('Reference', p.paymentReference!),
                        if (p.notes.isNotEmpty) InfoRow('Notes', p.notes),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'Products',
                    child: Column(
                      children: [
                        for (final l in p.lines) ...[
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('${l.productName} · ${l.productCode}'),
                            subtitle: Text(
                              '${l.quantity} × ${Money.format(l.unitPrice)}'
                              '${l.lineDiscount.signum > 0 ? ' − ${Money.format(l.lineDiscount)} discount' : ''}'
                              '${l.allocatedExtra.signum > 0 ? ' + ${Money.format(l.allocatedExtra)} extra cost' : ''}\n'
                              'Landed unit cost ${Money.format(l.landedUnitCost)}',
                            ),
                            isThreeLine: true,
                            trailing: Text(Money.format(l.landedValue),
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                          ),
                          const Divider(height: 1),
                        ],
                        const SizedBox(height: 8),
                        InfoRow('Products', Money.format(p.merchandiseTotal)),
                        InfoRow('Extra costs${p.extraCostsNote.isNotEmpty ? ' (${p.extraCostsNote})' : ''}',
                            Money.format(p.extraCosts)),
                        InfoRow('Total paid', Money.format(p.total), bold: true),
                      ],
                    ),
                  ),
                  if (!p.isDraft) ...[
                    const SizedBox(height: 12),
                    _PurchaseStockCard(purchaseId: p.id),
                  ],
                  if (p.isDraft) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.icon(
                          onPressed: () async {
                            final r = await showPostPurchaseDialog(context, p);
                            if (r != null) ref.invalidate(purchaseProvider(purchaseId));
                          },
                          icon: const Icon(Icons.check),
                          label: const Text('Review & post'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => context.push('/private/purchases/${p.id}/edit'),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit draft'),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                          onPressed: () async {
                            final ok = await confirmDialog(context,
                                title: 'Delete draft?',
                                message: 'This draft will be removed. Stock is not affected.',
                                confirmLabel: 'Delete',
                                destructive: true);
                            if (!ok) return;
                            try {
                              await ref.read(purchasesRepositoryProvider).deleteDraft(p.id);
                              ref.invalidate(purchaseListProvider);
                              if (context.mounted) {
                                context.showSuccess('Draft deleted.');
                                context.pop();
                              }
                            } catch (e) {
                              if (context.mounted) context.showError(e);
                            }
                          },
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete draft'),
                        ),
                      ],
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    Text(
                      'Posted purchases are permanent records. Supplier returns are handled under Returns & Adjustments (Stage 4).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
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

/// How much of this purchase is sold and how much is still in stock.
/// Sales always use the oldest purchase first.
class _PurchaseStockCard extends ConsumerWidget {
  const _PurchaseStockCard({required this.purchaseId});
  final String purchaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stock = ref.watch(purchaseStockProvider(purchaseId));
    return SectionCard(
      title: 'Stock from this purchase',
      child: stock.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(purchaseStockProvider(purchaseId))),
        data: (lines) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final l in lines)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${l.name} · ${l.code}'),
                subtitle: LinearProgressIndicator(
                  value: l.qtyIn == 0 ? 0 : l.qtySold / l.qtyIn,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
                trailing: Text('${l.qtyLeft} left / ${l.qtyIn}\n${l.qtySold} sold',
                    textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            const SizedBox(height: 6),
            Text('Sales always take from the oldest purchase first.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
