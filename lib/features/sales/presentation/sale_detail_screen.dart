import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/brand_logo.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../../auth/data/auth_repository.dart';
import '../../private_area/data/private_area_controller.dart';
import '../../settings/data/settings_repository.dart';
import '../data/sales_repository.dart';
import '../domain/sale.dart';

/// Receipt view of one sale. Owner (unlocked) also sees cost/profit and can void.
class SaleDetailScreen extends ConsumerWidget {
  const SaleDetailScreen({super.key, required this.saleId});
  final String saleId;

  String _receiptText(Sale s, BusinessSettings b) {
    final buf = StringBuffer()
      ..writeln(b.businessName)
      ..writeln([b.address, b.phone].where((e) => e.isNotEmpty).join(' · '))
      ..writeln('${s.type.label} bill ${s.invoiceNo}')
      ..writeln(BizTime.dateTime(s.completedAt));
    if (s.customerName.isNotEmpty) buf.writeln('Customer: ${s.customerName}');
    buf.writeln('------------------------');
    for (final l in s.lines) {
      buf.writeln('${l.productName} (${l.productCode})');
      buf.writeln('  ${l.quantity} x ${Money.format(l.unitPrice)} = ${Money.format(l.lineTotal)}');
      if (l.warrantyText.isNotEmpty) buf.writeln('  Warranty: ${l.warrantyText}');
    }
    buf.writeln('------------------------');
    buf.writeln('Bill: ${Money.format(s.subtotal)}');
    if (s.discount.signum > 0) buf.writeln('Less: ${Money.format(s.discount)}');
    buf.writeln('TOTAL PAID: ${Money.format(s.total)} (${s.method.label})');
    if (s.change.signum > 0) buf.writeln('Change: ${Money.format(s.change)}');
    if (b.receiptFooter.isNotEmpty) buf.writeln(b.receiptFooter);
    return buf.toString().trim();
  }

  Future<void> _void(BuildContext context, WidgetRef ref, Sale s) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Void ${s.invoiceNo}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Items go back into stock and the sale is removed from totals. This is recorded in history.'),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Reason (required)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () {
              if (reason.text.trim().length >= 3) Navigator.pop(ctx, true);
            },
            child: const Text('Void sale'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(salesRepositoryProvider).voidSale(s.id, reason.text);
      ref.invalidate(saleProvider(s.id));
      ref.invalidate(salesListProvider);
      ref.invalidate(salesSummaryProvider);
      ref.invalidate(ownerProfitProvider);
      if (context.mounted) context.showSuccess('${s.invoiceNo} voided — stock returned.');
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sale = ref.watch(saleProvider(saleId));
    final settings = ref.watch(businessSettingsProvider);
    final isOwner = ref.watch(isOwnerProvider);
    final unlocked = ref.watch(privateAreaProvider.select((s) => s.unlocked));
    final b = settings.hasValue ? settings.requireValue : BusinessSettings.fallback;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sale receipt'),
        actions: [
          if (sale.hasValue) ...[
            IconButton(
              tooltip: 'Copy receipt (WhatsApp)',
              icon: const Icon(Icons.copy_all_outlined),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _receiptText(sale.requireValue, b)));
                if (context.mounted) context.showSuccess('Receipt copied — paste it in WhatsApp.');
              },
            ),
            if (isOwner && unlocked && !sale.requireValue.isVoided)
              IconButton(
                tooltip: 'Void sale',
                icon: const Icon(Icons.cancel_outlined),
                onPressed: () => _void(context, ref, sale.requireValue),
              ),
          ],
        ],
      ),
      body: AsyncView<Sale>(
        value: sale,
        onRetry: () => ref.invalidate(saleProvider(saleId)),
        data: (s) => ListView(
          children: [
            PageBody(
              maxWidth: 640,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (s.isVoided)
                    Card(
                      color: AppTheme.danger.withValues(alpha: 0.08),
                      child: ListTile(
                        leading: const Icon(Icons.cancel, color: AppTheme.danger),
                        title: const Text('This sale was voided'),
                        subtitle: Text(s.voidReason ?? ''),
                      ),
                    ),
                  Card3D(
                    tilt: false,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [
                          Monogram(text: b.logoText, size: 44),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(b.businessName, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                              if (b.address.isNotEmpty || b.phone.isNotEmpty)
                                Text([b.address, b.phone].where((e) => e.isNotEmpty).join(' · '),
                                    style: theme.textTheme.bodySmall),
                            ]),
                          ),
                        ]),
                        const Divider(height: 28),
                        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          Text(s.invoiceNo, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                          StatusChip(s.type.label, color: s.type == SaleType.wholesale ? AppTheme.warning : null),
                          Text(BizTime.dateTime(s.completedAt), style: theme.textTheme.bodySmall),
                        ]),
                        if (s.customerName.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text('Customer: ${s.customerName}${s.customerPhone.isNotEmpty ? ' · ${s.customerPhone}' : ''}'),
                        ],
                        const Divider(height: 28),
                        for (final l in s.lines)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(l.productName, style: const TextStyle(fontWeight: FontWeight.w600)),
                                    Text('${l.productCode} · ${l.quantity} × ${Money.format(l.unitPrice)}',
                                        style: theme.textTheme.bodySmall),
                                    if (l.warrantyText.isNotEmpty)
                                      Text('Warranty: ${l.warrantyText}', style: theme.textTheme.bodySmall),
                                  ]),
                                ),
                                Text(Money.format(l.lineTotal)),
                              ],
                            ),
                          ),
                        const Divider(height: 20),
                        InfoRow('Bill total', Money.format(s.subtotal)),
                        if (s.discount.signum > 0) ...[
                          InfoRow('Less (agreed)', '− ${Money.format(s.discount)}'),
                          if (s.discountReason.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text('Reason: ${s.discountReason}',
                                  style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                            ),
                        ],
                        InfoRow('Amount received', Money.format(s.total), bold: true),
                        InfoRow('Payment', s.method.label + (s.reference.isNotEmpty ? ' · ${s.reference}' : '')),
                        if (s.change.signum > 0) InfoRow('Change given', Money.format(s.change)),
                        if (s.notes.isNotEmpty) InfoRow('Notes', s.notes),
                        if (b.receiptFooter.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(b.receiptFooter, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                        ],
                      ],
                    ),
                  ),
                  if (isOwner) ...[
                    const SizedBox(height: 16),
                    if (unlocked)
                      _SaleProfitCard(saleId: s.id)
                    else
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.lock_outline),
                          title: const Text('Cost & profit locked'),
                          subtitle: const Text('Unlock the Private Area to see this sale\'s profit or void it.'),
                          onTap: () => context.go('/private/unlock?from=/sales/${s.id}'),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SaleProfitCard extends ConsumerWidget {
  const _SaleProfitCard({required this.saleId});
  final String saleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(saleProfitProvider(saleId));
    return SectionCard(
      title: 'Profit on this sale (owner only)',
      child: p.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorView(error: e),
        data: (m) {
          final net = Money.parse(m['net_sales']);
          final profit = Money.parse(m['profit']);
          final margin = net.signum > 0 ? profit.toDouble() / net.toDouble() * 100 : 0.0;
          return Column(children: [
            InfoRow('Money received', Money.format(net)),
            InfoRow('Cost (average)', Money.format(m['cost'])),
            if (Money.parse(m['discount']).signum > 0) InfoRow('Discount given', Money.format(m['discount'])),
            InfoRow('Profit', Money.format(profit), bold: true),
            InfoRow('Margin', '${margin.toStringAsFixed(1)}%'),
          ]);
        },
      ),
    );
  }
}
