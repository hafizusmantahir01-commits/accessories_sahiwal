import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:decimal/decimal.dart';

import '../../../../core/utils/money.dart';
import '../../../../core/widgets/common.dart';
import '../../data/products_repository.dart';
import '../../../settings/data/settings_repository.dart';
import '../../domain/product.dart';
import 'product_thumb.dart';

/// Keyboard-friendly product selection: type/scan a code and press Enter for
/// an exact match, or search by name and tap a result.
/// [allowCreate] adds a "New product" button (purchases / opening stock), so a
/// new item can be created right there; photos can be added later.
Future<Product?> pickProduct(BuildContext context, {String initialQuery = '', bool allowCreate = false}) {
  return showDialog<Product>(
    context: context,
    builder: (_) => _ProductPickerDialog(initialQuery: initialQuery, allowCreate: allowCreate),
  );
}

class _ProductPickerDialog extends ConsumerStatefulWidget {
  const _ProductPickerDialog({this.initialQuery = '', this.allowCreate = false});
  final String initialQuery;
  final bool allowCreate;

  @override
  ConsumerState<_ProductPickerDialog> createState() => _ProductPickerDialogState();
}

class _ProductPickerDialogState extends ConsumerState<_ProductPickerDialog> {
  late final _search = TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  late String _query = widget.initialQuery.trim();
  String? _message;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _exact(String code) async {
    if (code.trim().isEmpty) return;
    try {
      final repo = ref.read(productsRepositoryProvider);
      final hit = await repo.lookup(code);
      if (!mounted) return;
      if (hit == null) {
        setState(() {
          _query = code.trim();
          _message = 'No exact code match — showing search results.';
        });
        return;
      }
      final product = await repo.get(hit['id'] as String);
      if (mounted) Navigator.pop(context, product);
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  Future<void> _createNew() async {
    final created = await showDialog<Product>(
      context: context,
      builder: (_) => _QuickProductDialog(initialName: _search.text.trim()),
    );
    if (created != null && mounted) Navigator.pop(context, created);
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(productListProvider(ProductQuery(search: _query)));
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: size.height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  labelText: 'Product code or name',
                  hintText: 'Scan / type code and press Enter',
                  prefixIcon: Icon(Icons.qr_code_scanner),
                ),
                onSubmitted: _exact,
                onChanged: (v) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 300), () {
                    if (!mounted) return;
                    setState(() {
                      _query = v.trim();
                      _message = null;
                    });
                  });
                },
              ),
            ),
            if (widget.allowCreate)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.add_box_outlined),
                  label: const Text('New product (not in the list)'),
                  onPressed: _createNew,
                ),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_message!, style: Theme.of(context).textTheme.bodySmall),
              ),
            Flexible(
              child: AsyncView<List<Product>>(
                value: results,
                data: (list) => list.isEmpty
                    ? const EmptyState(icon: Icons.search_off, title: 'No products found')
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final p = list[i];
                          return ListTile(
                            leading: ProductThumb(path: p.primaryImage?.path, size: 40, radius: 6),
                            title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${p.code} · stock ${p.saleableQty} · retail ${Money.format(p.retailPrice)}'),
                            onTap: () => Navigator.pop(context, p),
                          );
                        },
                      ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small form: create a product while entering a purchase / opening stock.
class _QuickProductDialog extends ConsumerStatefulWidget {
  const _QuickProductDialog({required this.initialName});
  final String initialName;

  @override
  ConsumerState<_QuickProductDialog> createState() => _QuickProductDialogState();
}

class _QuickProductDialogState extends ConsumerState<_QuickProductDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initialName);
  final _variant = TextEditingController();
  final _retail = TextEditingController();
  final _wholesale = TextEditingController();
  String? _categoryId;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _variant.dispose();
    _retail.dispose();
    _wholesale.dispose();
    super.dispose();
  }

  String? _price(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    return Money.tryParseInput(v) == null ? 'Enter a valid amount' : null;
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final settings = ref.read(businessSettingsProvider);
      final repo = ref.read(productsRepositoryProvider);
      final id = await repo.create(ProductInput(
        code: '', // blank = automatic code (AS-0001 …)
        name: _name.text,
        categoryId: _categoryId,
        brand: '',
        model: '',
        variant: _variant.text,
        description: '',
        wholesalePrice: Money.tryParseInput(_wholesale.text) ?? Decimal.zero,
        retailPrice: Money.tryParseInput(_retail.text) ?? Decimal.zero,
        warrantyNote: '',
        warrantyDays: 0,
        reorderThreshold: settings.hasValue ? settings.requireValue.lowStockDefault : 5,
        barcode: '',
        isActive: true,
      ));
      final product = await repo.get(id);
      ref.invalidate(productListProvider);
      if (mounted) Navigator.pop(context, product);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        context.showError(e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider);
    return AlertDialog(
      title: const Text('New product'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Product name *'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _variant,
                  decoration: const InputDecoration(labelText: 'Colour / variant (optional)'),
                ),
                const SizedBox(height: 10),
                if (categories.hasValue && categories.requireValue.isNotEmpty) ...[
                  DropdownButtonFormField<String?>(
                    initialValue: _categoryId,
                    decoration: const InputDecoration(labelText: 'Category (optional)'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('No category')),
                      for (final c in categories.requireValue)
                        DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _retail,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Retail price *', prefixText: 'Rs. '),
                        validator: _price,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _wholesale,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Wholesale price *', prefixText: 'Rs. '),
                        validator: _price,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Code is made automatically. Add photos later from Products.',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create & add'),
        ),
      ],
    );
  }
}
