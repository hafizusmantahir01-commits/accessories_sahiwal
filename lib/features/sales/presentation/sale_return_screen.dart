import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../../products/data/products_repository.dart';
import '../../stock/data/stock_repository.dart';
import '../data/sales_repository.dart';
import '../domain/sale.dart';

/// Customer brings back some items of a bill. Good pieces go back into
/// stock; damaged pieces go to "Damaged". Money back = what was really paid.
class SaleReturnScreen extends ConsumerStatefulWidget {
  const SaleReturnScreen({super.key, required this.saleId});
  final String saleId;

  @override
  ConsumerState<SaleReturnScreen> createState() => _SaleReturnScreenState();
}

class _SaleReturnScreenState extends ConsumerState<SaleReturnScreen> {
  final _qty = <String, int>{}; // sale_item_id → pieces to return
  final _damaged = <String, bool>{};
  final _reason = TextEditingController();
  PaymentMethod _method = PaymentMethod.cash;
  bool _saving = false;
  // One key per attempt: a retry after a network error never refunds twice.
  String _key = const Uuid().v4();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  /// Approximate refund (the server calculates the exact paisa).
  Decimal _refundFor(SaleLine l, int qty) {
    if (qty <= 0 || l.quantity == 0) return Decimal.zero;
    final v = (l.netTotal * Decimal.fromInt(qty) / Decimal.fromInt(l.quantity)).toDecimal(scaleOnInfinitePrecision: 2);
    return Money.parse(v.toStringAsFixed(2));
  }

  Map<String, int> _alreadyReturned(List<SaleReturn> returns) {
    final m = <String, int>{};
    for (final r in returns) {
      for (final i in r.items) {
        m[i.saleItemId] = (m[i.saleItemId] ?? 0) + i.quantity;
      }
    }
    return m;
  }

  Future<void> _save(Sale sale) async {
    final chosen = {for (final e in _qty.entries) if (e.value > 0) e.key: e.value};
    if (chosen.isEmpty) {
      context.showError('Choose at least one item to return.');
      return;
    }
    if (_reason.text.trim().isEmpty) {
      context.showError('Write the reason for the return.');
      return;
    }
    var refund = Decimal.zero;
    final lines = <String>[];
    for (final l in sale.lines) {
      final q = chosen[l.id] ?? 0;
      if (q == 0) continue;
      refund += _refundFor(l, q);
      lines.add('$q × ${l.productName}${(_damaged[l.id] ?? false) ? ' (damaged)' : ''}');
    }
    final ok = await confirmDialog(
      context,
      title: 'Confirm return?',
      message: '${lines.join('\n')}\n\nGive back about ${Money.format(refund)} (${_method.label}).\n'
          'Good pieces go back into stock. This is saved in History.',
      confirmLabel: 'Yes, return',
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      final res = await ref.read(salesRepositoryProvider).createReturn(
            saleId: sale.id,
            items: {for (final e in chosen.entries) e.key: (e.value, _damaged[e.key] ?? false)},
            reason: _reason.text,
            method: _method,
            idempotencyKey: _key,
          );
      ref
        ..invalidate(saleReturnsProvider(sale.id))
        ..invalidate(saleProvider(sale.id))
        ..invalidate(salesListProvider)
        ..invalidate(salesSummaryProvider)
        ..invalidate(ownerProfitProvider)
        ..invalidate(profitByMonthProvider)
        ..invalidate(profitByProductProvider)
        ..invalidate(stockListProvider)
        ..invalidate(productListProvider)
        ..invalidate(productProvider);
      if (!mounted) return;
      context.showSuccess('${res['return_no']}: give back ${Money.format(res['refund'])}. Saved in History.');
      context.pop();
    } catch (e) {
      if (mounted) {
        context.showError(e);
        setState(() => _key = const Uuid().v4());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sale = ref.watch(saleProvider(widget.saleId));
    final returns = ref.watch(saleReturnsProvider(widget.saleId));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Return items')),
      body: AsyncView<Sale>(
        value: sale,
        onRetry: () => ref.invalidate(saleProvider(widget.saleId)),
        data: (s) {
          if (s.isVoided) {
            return const EmptyState(icon: Icons.cancel_outlined, title: 'This sale is voided');
          }
          if (!returns.hasValue) {
            return returns.hasError
                ? ErrorView(error: returns.error!, onRetry: () => ref.invalidate(saleReturnsProvider(widget.saleId)))
                : const Center(child: CircularProgressIndicator());
          }
          final done = _alreadyReturned(returns.requireValue);
          var refund = Decimal.zero;
          for (final l in s.lines) {
            refund += _refundFor(l, _qty[l.id] ?? 0);
          }
          return ListView(
            children: [
              PageBody(
                maxWidth: 680,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('${s.invoiceNo}${s.customerName.isNotEmpty ? ' · ${s.customerName}' : ''}',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('Choose how many pieces came back. Money back is what the customer really paid '
                        '(after any discount on the bill).',
                        style: theme.textTheme.bodySmall),
                    const SizedBox(height: 12),
                    for (final l in s.lines) ...[
                      _ReturnLineCard(
                        line: l,
                        left: l.quantity - (done[l.id] ?? 0),
                        qty: _qty[l.id] ?? 0,
                        damaged: _damaged[l.id] ?? false,
                        refund: _refundFor(l, _qty[l.id] ?? 0),
                        onQty: (v) => setState(() => _qty[l.id] = v),
                        onDamaged: (v) => setState(() => _damaged[l.id] = v),
                      ),
                      const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 8),
                    TextField(
                      controller: _reason,
                      decoration: const InputDecoration(
                          labelText: 'Reason *', hintText: 'e.g. not working / customer changed mind'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<PaymentMethod>(
                      initialValue: _method,
                      decoration: const InputDecoration(labelText: 'Money given back by'),
                      items: [
                        for (final m in PaymentMethod.values) DropdownMenuItem(value: m, child: Text(m.label)),
                      ],
                      onChanged: (v) => setState(() => _method = v ?? PaymentMethod.cash),
                    ),
                    const SizedBox(height: 16),
                    Card3D(
                      tilt: false,
                      padding: const EdgeInsets.all(16),
                      colors: AppTheme.heroColors,
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text('Give back to customer', style: TextStyle(color: Colors.white70)),
                          ),
                          Text(Money.format(refund),
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _saving ? null : () => _save(s),
                      icon: _saving
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.assignment_return_outlined),
                      label: const Text('Save return'),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ReturnLineCard extends StatelessWidget {
  const _ReturnLineCard({
    required this.line,
    required this.left,
    required this.qty,
    required this.damaged,
    required this.refund,
    required this.onQty,
    required this.onDamaged,
  });

  final SaleLine line;
  final int left;
  final int qty;
  final bool damaged;
  final Decimal refund;
  final ValueChanged<int> onQty;
  final ValueChanged<bool> onDamaged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card3D(
      tilt: false,
      radius: 14,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(line.productName, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text('${line.productCode} · sold ${line.quantity} × ${Money.format(line.unitPrice)}'
              '${left < line.quantity ? ' · ${line.quantity - left} already returned' : ''}',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          if (left <= 0)
            Text('All pieces already returned', style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.danger))
          else
            Row(
              children: [
                IconButton.filledTonal(
                  icon: const Icon(Icons.remove),
                  onPressed: qty > 0 ? () => onQty(qty - 1) : null,
                ),
                SizedBox(
                  width: 56,
                  child: Text('$qty', textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
                ),
                IconButton.filledTonal(
                  icon: const Icon(Icons.add),
                  onPressed: qty < left ? () => onQty(qty + 1) : null,
                ),
                const SizedBox(width: 8),
                Text('of $left', style: theme.textTheme.bodySmall),
                const Spacer(),
                Text(Money.format(refund), style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
          if (qty > 0) ...[
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.check_circle_outline), label: Text('Good · back to stock')),
                ButtonSegment(value: true, icon: Icon(Icons.broken_image_outlined), label: Text('Damaged')),
              ],
              selected: {damaged},
              onSelectionChanged: (v) => onDamaged(v.first),
            ),
          ],
        ],
      ),
    );
  }
}

/// Plain-text return slip for WhatsApp.
String returnReceiptText(Sale s, SaleReturn r, String businessName) {
  final buf = StringBuffer()
    ..writeln(businessName)
    ..writeln('RETURN ${r.returnNo} (bill ${s.invoiceNo})');
  if (s.customerName.isNotEmpty) buf.writeln('Customer: ${s.customerName}');
  buf.writeln('------------------------');
  for (final i in r.items) {
    buf.writeln('${i.quantity} × ${i.productName} = ${Money.format(i.refund)}${i.damaged ? ' (damaged)' : ''}');
  }
  buf
    ..writeln('------------------------')
    ..writeln('MONEY BACK: ${Money.format(r.refund)} (${r.method.label})')
    ..writeln('Reason: ${r.reason}');
  return buf.toString().trim();
}

/// Copies a return slip to the clipboard.
Future<void> copyReturnReceipt(BuildContext context, Sale s, SaleReturn r, String businessName) async {
  await Clipboard.setData(ClipboardData(text: returnReceiptText(s, r, businessName)));
  if (context.mounted) context.showSuccess('Return slip copied — paste it in WhatsApp.');
}
