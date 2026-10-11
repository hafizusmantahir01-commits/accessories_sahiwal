import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../products/data/products_repository.dart';
import '../../products/domain/product.dart';
import '../../valuation/data/valuation_repository.dart';
import '../data/stock_repository.dart';

/// "Fix stock": remove broken / lost pieces, or add pieces found on counting.
/// Removed pieces leave at their real cost (shown as stock loss in profit).
Future<void> showAdjustStockDialog(BuildContext context, WidgetRef ref, Product product) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => _AdjustStockDialog(product: product),
  );
  if (done == true) {
    ref
      ..invalidate(productProvider(product.id))
      ..invalidate(productListProvider)
      ..invalidate(stockListProvider)
      ..invalidate(ownerProductCostProvider(product.id))
      ..invalidate(productLotsProvider(product.id))
      ..invalidate(valuationProvider);
  }
}

class _AdjustStockDialog extends ConsumerStatefulWidget {
  const _AdjustStockDialog({required this.product});
  final Product product;

  @override
  ConsumerState<_AdjustStockDialog> createState() => _AdjustStockDialogState();
}

class _AdjustStockDialogState extends ConsumerState<_AdjustStockDialog> {
  final _form = GlobalKey<FormState>();
  final _qty = TextEditingController();
  final _note = TextEditingController();
  final _cost = TextEditingController();
  bool _remove = true;
  String _kind = 'damaged';
  bool _saving = false;

  static const _kinds = [
    ('damaged', 'Broken / damaged', Icons.broken_image_outlined),
    ('lost', 'Lost / missing', Icons.search_off),
    ('count', 'Count difference', Icons.fact_check_outlined),
    ('other', 'Other', Icons.more_horiz),
  ];

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    _cost.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final n = int.parse(_qty.text.trim());
    final change = _remove ? -n : n;
    final after = widget.product.saleableQty + change;
    final ok = await confirmDialog(
      context,
      title: 'Fix stock?',
      message: '${widget.product.name}: ${widget.product.saleableQty} → $after pieces '
          '(${_remove ? 'remove' : 'add'} $n).\n\nThis is saved in History.',
      confirmLabel: 'Yes, save',
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      final res = await ref.read(stockRepositoryProvider).adjust(
            productId: widget.product.id,
            qtyChange: change,
            kind: _remove ? _kind : (_kind == 'damaged' || _kind == 'lost' ? 'count' : _kind),
            note: _note.text,
            unitCost: !_remove && _cost.text.trim().isNotEmpty ? Money.tryParseInput(_cost.text)?.toString() : null,
          );
      if (!mounted) return;
      context.showSuccess('Stock is now ${res['qty_after']}. Saved in History.');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kinds = _remove ? _kinds : _kinds.where((k) => k.$1 == 'count' || k.$1 == 'other').toList();
    if (!kinds.any((k) => k.$1 == _kind)) _kind = kinds.first.$1;
    return AlertDialog(
      icon: const Icon(Icons.tune, size: 32),
      title: const Text('Fix stock'),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${widget.product.name} · now ${widget.product.saleableQty} in stock'),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, icon: Icon(Icons.remove_circle_outline), label: Text('Remove')),
                  ButtonSegment(value: false, icon: Icon(Icons.add_circle_outline), label: Text('Add (found)')),
                ],
                selected: {_remove},
                onSelectionChanged: (v) => setState(() => _remove = v.first),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _qty,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: _remove ? 'How many pieces to remove *' : 'How many pieces to add *'),
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  if (n == null || n <= 0) return 'Enter a number above 0';
                  if (_remove && n > widget.product.saleableQty) return 'Only ${widget.product.saleableQty} in stock';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Text('What happened?', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final k in kinds)
                    ChoiceChip(
                      avatar: Icon(k.$3, size: 18),
                      label: Text(k.$2),
                      selected: _kind == k.$1,
                      onSelected: (_) => setState(() => _kind = k.$1),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _note,
                decoration: InputDecoration(labelText: _kind == 'other' ? 'Note *' : 'Note (optional)'),
                validator: (v) => _kind == 'other' && (v ?? '').trim().isEmpty ? 'Write what happened' : null,
              ),
              if (!_remove) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _cost,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Cost per piece (optional)',
                    prefixText: 'Rs. ',
                    helperText: 'Blank = current average cost',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty || Money.tryParseInput(v!) != null ? null : 'Enter a valid amount',
                ),
              ],
              const SizedBox(height: 8),
              Text(
                _remove
                    ? 'Removed pieces are counted as stock loss in your profit report.'
                    : 'Use "Purchase" for new stock from a supplier. This is only for pieces found while counting.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
