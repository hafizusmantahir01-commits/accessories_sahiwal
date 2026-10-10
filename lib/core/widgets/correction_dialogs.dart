import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/money.dart';

/// Red "delete for good" confirmation with a required reason.
/// Returns the reason, or null if cancelled. The reason is saved in History.
Future<String?> confirmDeleteWithReason(
  BuildContext context, {
  required String title,
  required String message,
  List<String> willRemove = const [],
  String confirmLabel = 'Yes, delete',
  String hint = 'e.g. entered by mistake / duplicate',
}) {
  final reason = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      String? error;
      return StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          icon: Icon(Icons.delete_forever_outlined, color: Theme.of(ctx).colorScheme.error, size: 32),
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(message),
                if (willRemove.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('This will be removed:', style: Theme.of(ctx).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  for (final w in willRemove)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text('•  $w'),
                    ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: reason,
                  autofocus: true,
                  decoration: InputDecoration(labelText: 'Reason *', hintText: hint, errorText: error),
                ),
                const SizedBox(height: 8),
                Text('This cannot be undone. It will be saved in History (who, when and why).',
                    style: Theme.of(ctx).textTheme.bodySmall),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () {
                final r = reason.text.trim();
                if (r.isEmpty) {
                  setState(() => error = 'Write a short reason');
                  return;
                }
                Navigator.pop(ctx, r);
              },
              child: Text(confirmLabel),
            ),
          ],
        ),
      );
    },
  );
}

/// Result of [editQtyPriceDialog].
class QtyPriceEdit {
  const QtyPriceEdit(this.quantity, this.price, this.reason);
  final int quantity;
  final Decimal price;
  final String reason;
}

/// Correct the quantity and/or unit price of an entry, with a reason.
Future<QtyPriceEdit?> editQtyPriceDialog(
  BuildContext context, {
  required String title,
  required int quantity,
  required Decimal price,
  String priceLabel = 'Unit price',
  int minQuantity = 1,
  String? note,
}) {
  final qty = TextEditingController(text: '$quantity');
  final cost = TextEditingController(text: Money.toInput(price));
  final reason = TextEditingController();
  final form = GlobalKey<FormState>();
  return showDialog<QtyPriceEdit>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.edit_note, size: 32),
      title: Text(title),
      content: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Now: $quantity × ${Money.format(price)}'),
              const SizedBox(height: 12),
              TextFormField(
                controller: qty,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Correct quantity',
                  helperText: minQuantity > 1 ? '$minQuantity already sold, so at least $minQuantity' : null,
                ),
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  if (n == null || n <= 0) return 'Enter a whole number above 0';
                  if (n < minQuantity) return 'At least $minQuantity (already sold)';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: cost,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: priceLabel, prefixText: 'Rs. '),
                validator: (v) => Money.tryParseInput(v ?? '') == null ? 'Enter a valid amount' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: reason,
                decoration: const InputDecoration(labelText: 'Reason *', hintText: 'e.g. typed 50 instead of 30'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Write a short reason' : null,
              ),
              if (note != null) ...[
                const SizedBox(height: 8),
                Text(note, style: Theme.of(ctx).textTheme.bodySmall),
              ],
              const SizedBox(height: 8),
              Text('Stock and totals are corrected automatically. Saved in History.',
                  style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!form.currentState!.validate()) return;
            Navigator.pop(
              ctx,
              QtyPriceEdit(int.parse(qty.text.trim()), Money.tryParseInput(cost.text)!, reason.text.trim()),
            );
          },
          child: const Text('Save correction'),
        ),
      ],
    ),
  );
}
