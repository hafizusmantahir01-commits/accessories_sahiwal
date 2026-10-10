import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/correction_dialogs.dart';
import '../../products/data/products_repository.dart';
import '../../products/domain/product.dart';
import '../../products/presentation/widgets/product_picker.dart';
import '../../settings/data/settings_repository.dart';
import '../../stock/data/stock_repository.dart';
import '../../valuation/data/valuation_repository.dart';
import '../data/opening_stock_repository.dart';

class OpeningStockScreen extends ConsumerStatefulWidget {
  const OpeningStockScreen({super.key});

  @override
  ConsumerState<OpeningStockScreen> createState() => _OpeningStockScreenState();
}

class _OpeningStockScreenState extends ConsumerState<OpeningStockScreen> {
  final _form = GlobalKey<FormState>();
  final _qty = TextEditingController();
  final _cost = TextEditingController();
  final _note = TextEditingController();
  Product? _product;
  // One key per entry attempt; a retry after a timeout reuses it (no double stock).
  String _key = const Uuid().v4();

  @override
  void dispose() {
    _qty.dispose();
    _cost.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final p = await pickProduct(context, allowCreate: true);
    if (p != null && mounted) setState(() => _product = p);
  }

  Future<void> _post() async {
    if (_product == null) {
      context.showError('Select a product.');
      return;
    }
    if (!_form.currentState!.validate()) return;
    final qty = int.parse(_qty.text.trim());
    final cost = Money.tryParseInput(_cost.text)!;
    final ok = await confirmDialog(
      context,
      title: 'Post opening stock?',
      message: 'Add $qty × ${_product!.name} at ${Money.format(cost)} each '
          '(${Money.format(cost * Decimal.fromInt(qty))} total).\n\n'
          'A mistake can be corrected later from the ⋮ menu in the list below.',
      confirmLabel: 'Post',
    );
    if (!ok) return;
    try {
      await ref.read(openingStockRepositoryProvider).post(
            productId: _product!.id,
            quantity: qty,
            unitCost: cost,
            idempotencyKey: _key,
            note: _note.text,
          );
      ref
        ..invalidate(openingEntriesProvider)
        ..invalidate(stockListProvider)
        ..invalidate(productListProvider)
        ..invalidate(productProvider)
        ..invalidate(valuationProvider);
      if (!mounted) return;
      context.showSuccess('Opening stock posted for ${_product!.name}.');
      setState(() {
        _product = null;
        _qty.clear();
        _cost.clear();
        _note.clear();
        _key = const Uuid().v4();
      });
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  void _refreshAll() {
    ref
      ..invalidate(openingEntriesProvider)
      ..invalidate(stockListProvider)
      ..invalidate(productListProvider)
      ..invalidate(productProvider)
      ..invalidate(valuationProvider);
  }

  Future<void> _editEntry(OpeningEntry e) async {
    final r = await editQtyPriceDialog(
      context,
      title: 'Correct ${e.productLabel}',
      quantity: e.quantity,
      price: e.unitCost,
      priceLabel: 'Actual unit cost',
    );
    if (r == null) return;
    try {
      await ref
          .read(openingStockRepositoryProvider)
          .edit(id: e.id, quantity: r.quantity, unitCost: r.price, reason: r.reason);
      _refreshAll();
      if (mounted) context.showSuccess('Corrected. Stock updated.');
    } catch (err) {
      if (mounted) context.showError(err);
    }
  }

  Future<void> _deleteEntry(OpeningEntry e) async {
    final reason = await confirmDeleteWithReason(
      context,
      title: 'Delete opening entry?',
      message: 'Only this entry is removed. Not possible for units that are already sold.',
      willRemove: ['${e.quantity} × ${e.productLabel} (${Money.format(e.totalValue)})'],
    );
    if (reason == null) return;
    try {
      await ref.read(openingStockRepositoryProvider).delete(e.id, reason);
      _refreshAll();
      if (mounted) context.showSuccess('Entry deleted. Saved in History.');
    } catch (err) {
      if (mounted) context.showError(err);
    }
  }

  Future<void> _startTrading() async {
    final ok = await confirmDialog(
      context,
      title: 'Close opening stock?',
      message: 'After this, opening stock can no longer be entered. Use purchases and stock adjustments instead. '
          'This also happens automatically with the first sale.',
      confirmLabel: 'Close opening stock',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(settingsRepositoryProvider).startTrading();
      ref.invalidate(businessSettingsProvider);
      if (mounted) context.showSuccess('Opening stock is now closed.');
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(businessSettingsProvider);
    final entries = ref.watch(openingEntriesProvider);
    final closed = settings.hasValue && settings.requireValue.tradingStartedAt != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Opening stock')),
      body: ListView(
        children: [
          PageBody(
            maxWidth: 760,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (closed)
                  Card(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: ListTile(
                      leading: const Icon(Icons.lock_clock),
                      title: const Text('Opening stock is closed'),
                      subtitle: Text('Trading started ${BizTime.dateTime(settings.requireValue.tradingStartedAt)}. '
                          'Use purchases or stock adjustments.'),
                    ),
                  )
                else
                  SectionCard(
                    title: 'Add existing stock',
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _pick,
                            icon: const Icon(Icons.search),
                            label: Text(_product == null ? 'Select product' : '${_product!.name} · ${_product!.code}'),
                          ),
                          if (_product != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text('Current stock: ${_product!.saleableQty}',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ),
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: _qty,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                  decoration: const InputDecoration(labelText: 'Quantity'),
                                  validator: Validators.quantity,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  controller: _cost,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: const InputDecoration(labelText: 'Actual unit cost *', prefixText: 'Rs. '),
                                  validator: (v) => Validators.price(v, 'Unit cost'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextFormField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)')),
                          const SizedBox(height: 16),
                          BusyButton(label: 'Post opening stock', icon: Icons.check, onPressed: _post),
                          const SizedBox(height: 8),
                          Text(
                            'Opening stock records what you already own. It does not create a payment or expense.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Opening entries',
                  child: AsyncView<List<OpeningEntry>>(
                    value: entries,
                    onRetry: () => ref.invalidate(openingEntriesProvider),
                    data: (list) {
                      if (list.isEmpty) return const Text('No opening stock entered yet.');
                      final total = list.fold(Money.zero, (a, e) => a + e.totalValue);
                      return Column(
                        children: [
                          for (final e in list)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(e.productLabel),
                              subtitle: Text('${e.quantity} × ${Money.format(e.unitCost)} · ${BizTime.dateTime(e.createdAt)}'
                                  '${e.note.isNotEmpty ? '\n${e.note}' : ''}'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(Money.format(e.totalValue)),
                                  PopupMenuButton<String>(
                                    tooltip: 'Correct',
                                    onSelected: (v) => v == 'edit' ? _editEntry(e) : _deleteEntry(e),
                                    itemBuilder: (_) => [
                                      const PopupMenuItem(value: 'edit', child: Text('Edit quantity / cost')),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Delete entry',
                                            style: TextStyle(color: Theme.of(context).colorScheme.error)),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          const Divider(),
                          InfoRow('Total opening value', Money.format(total), bold: true),
                        ],
                      );
                    },
                  ),
                ),
                if (!closed) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _startTrading,
                    icon: const Icon(Icons.flag_outlined),
                    label: const Text('Finished — close opening stock'),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
