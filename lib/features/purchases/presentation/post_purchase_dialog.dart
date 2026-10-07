import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../products/data/products_repository.dart';
import '../../stock/data/stock_repository.dart';
import '../../valuation/data/valuation_repository.dart';
import '../data/purchases_repository.dart';
import '../domain/purchase.dart';

/// Review + fully-paid posting. One idempotency key per dialog: pressing Post
/// again after a timeout re-sends the SAME key, so the server posts only once.
Future<PostResult?> showPostPurchaseDialog(BuildContext context, Purchase purchase) {
  return showDialog<PostResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PostPurchaseDialog(purchase: purchase),
  );
}

class _PostPurchaseDialog extends ConsumerStatefulWidget {
  const _PostPurchaseDialog({required this.purchase});
  final Purchase purchase;

  @override
  ConsumerState<_PostPurchaseDialog> createState() => _PostPurchaseDialogState();
}

class _PostPurchaseDialogState extends ConsumerState<_PostPurchaseDialog> {
  final _idempotencyKey = const Uuid().v4();
  late final _amount = TextEditingController(text: Money.toInput(widget.purchase.total));
  final _reference = TextEditingController();
  late PaymentMethod _method = widget.purchase.paymentMethod;
  bool _posting = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  Decimal? get _paid => Money.tryParseInput(_amount.text);

  Future<void> _post() async {
    final paid = _paid;
    if (paid == null) {
      setState(() => _error = 'Enter the amount paid.');
      return;
    }
    setState(() {
      _posting = true;
      _error = null;
    });
    try {
      final result = await ref.read(purchasesRepositoryProvider).post(
            id: widget.purchase.id,
            method: _method,
            amountPaid: paid,
            idempotencyKey: _idempotencyKey,
            reference: _reference.text,
          );
      ref
        ..invalidate(purchaseListProvider)
        ..invalidate(purchaseProvider(widget.purchase.id))
        ..invalidate(stockListProvider)
        ..invalidate(productListProvider)
        ..invalidate(productProvider)
        ..invalidate(valuationProvider);
      if (!mounted) return;
      context.showSuccess(result.alreadyPosted
          ? '${result.purchaseNo} was already posted.'
          : '${result.purchaseNo} posted. Stock and costs updated.');
      Navigator.pop(context, result);
    } catch (e) {
      if (mounted) setState(() => _error = AppException.from(e).message);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.purchase;
    final paid = _paid;
    final shortfall = paid == null ? null : p.total - paid;
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Review & post purchase'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InfoRow('Supplier', p.supplierName),
              if (p.supplierRef.isNotEmpty) InfoRow('Bill no.', p.supplierRef),
              const Divider(),
              for (final l in p.lines)
                InfoRow('${l.quantity} × ${l.productName}', Money.format(l.landedValue)),
              const Divider(),
              InfoRow('Products', Money.format(p.merchandiseTotal)),
              InfoRow('Extra costs', Money.format(p.extraCosts)),
              InfoRow('Total', Money.format(p.total), bold: true),
              const SizedBox(height: 16),
              DropdownButtonFormField<PaymentMethod>(
                initialValue: _method,
                decoration: const InputDecoration(labelText: 'Payment method'),
                items: [for (final m in PaymentMethod.values) DropdownMenuItem(value: m, child: Text(m.label))],
                onChanged: _posting ? null : (v) => setState(() => _method = v ?? _method),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amount,
                enabled: !_posting,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount paid', prefixText: 'Rs. '),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reference,
                enabled: !_posting,
                decoration: const InputDecoration(labelText: 'Payment reference (optional)', hintText: 'Transaction ID'),
              ),
              if (shortfall != null && shortfall > Decimal.zero) ...[
                const SizedBox(height: 12),
                Text('Shortfall ${Money.format(shortfall)} — only fully-paid purchases can be posted.',
                    style: TextStyle(color: theme.colorScheme.error)),
              ],
              if (shortfall != null && shortfall < Decimal.zero) ...[
                const SizedBox(height: 12),
                Text('Amount is more than the total. Enter the exact amount paid.',
                    style: TextStyle(color: theme.colorScheme.error)),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 12),
              Text(
                'Posting adds the stock, updates average costs and records the payment. '
                'A posted purchase cannot be edited.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _posting ? null : () => Navigator.pop(context), child: const Text('Back')),
        FilledButton.icon(
          onPressed: _posting || shortfall == null || shortfall != Decimal.zero ? null : _post,
          icon: _posting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check),
          label: const Text('Post as paid'),
        ),
      ],
    );
  }
}
