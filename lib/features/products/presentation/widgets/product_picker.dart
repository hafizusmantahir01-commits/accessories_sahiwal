import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/money.dart';
import '../../../../core/widgets/common.dart';
import '../../data/products_repository.dart';
import '../../domain/product.dart';
import 'product_thumb.dart';

/// Keyboard-friendly product selection: type/scan a code and press Enter for
/// an exact match, or search by name and tap a result.
Future<Product?> pickProduct(BuildContext context, {String initialQuery = ''}) {
  return showDialog<Product>(context: context, builder: (_) => _ProductPickerDialog(initialQuery: initialQuery));
}

class _ProductPickerDialog extends ConsumerStatefulWidget {
  const _ProductPickerDialog({this.initialQuery = ''});
  final String initialQuery;

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
