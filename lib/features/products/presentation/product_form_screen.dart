import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/money.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/common.dart';
import '../../settings/data/settings_repository.dart';
import '../data/products_repository.dart';
import '../domain/product.dart';

/// Owner-only create/edit. Stock is NOT entered here — use opening stock or purchases.
class ProductFormScreen extends ConsumerStatefulWidget {
  const ProductFormScreen({super.key, this.productId});
  final String? productId;

  @override
  ConsumerState<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends ConsumerState<ProductFormScreen> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _brand = TextEditingController();
  final _model = TextEditingController();
  final _variant = TextEditingController();
  final _description = TextEditingController();
  final _wholesale = TextEditingController();
  final _retail = TextEditingController();
  final _warrantyNote = TextEditingController();
  final _warrantyDays = TextEditingController(text: '0');
  final _reorder = TextEditingController(text: '5');
  final _barcode = TextEditingController();
  String? _categoryId;
  bool _active = true;
  bool _loaded = false;
  bool _dirty = false;
  bool _saving = false;

  bool get _editing => widget.productId != null;

  List<TextEditingController> get _controllers => [
        _code, _name, _brand, _model, _variant, _description, _wholesale, _retail,
        _warrantyNote, _warrantyDays, _reorder, _barcode,
      ];

  @override
  void initState() {
    super.initState();
    if (_editing) {
      _load();
    } else {
      _loaded = true;
      // New products start with the owner's default low-stock level.
      ref.read(businessSettingsProvider.future).then((s) {
        if (mounted && !_dirty) _reorder.text = '${s.lowStockDefault}';
      }).catchError((Object _) {});
    }
  }

  Future<void> _load() async {
    try {
      final p = await ref.read(productsRepositoryProvider).get(widget.productId!);
      _code.text = p.code;
      _name.text = p.name;
      _brand.text = p.brand;
      _model.text = p.model;
      _variant.text = p.variant;
      _description.text = p.description;
      _wholesale.text = Money.toInput(p.wholesalePrice);
      _retail.text = Money.toInput(p.retailPrice);
      _warrantyNote.text = p.warrantyNote;
      _warrantyDays.text = '${p.warrantyDays}';
      _reorder.text = '${p.reorderThreshold}';
      _barcode.text = p.barcode ?? '';
      _categoryId = p.categoryId;
      _active = p.isActive;
      if (mounted) setState(() => _loaded = true);
    } catch (e) {
      if (mounted) {
        context.showError(e);
        context.pop();
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _addCategory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Category name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      final c = await ref.read(productsRepositoryProvider).addCategory(name);
      ref.invalidate(categoriesProvider);
      if (!mounted) return;
      setState(() {
        _categoryId = c.id;
        _dirty = true;
      });
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final input = ProductInput(
      code: _code.text,
      name: _name.text,
      categoryId: _categoryId,
      brand: _brand.text,
      model: _model.text,
      variant: _variant.text,
      description: _description.text,
      wholesalePrice: Money.tryParseInput(_wholesale.text)!,
      retailPrice: Money.tryParseInput(_retail.text)!,
      warrantyNote: _warrantyNote.text,
      warrantyDays: int.parse(_warrantyDays.text.trim()),
      reorderThreshold: int.parse(_reorder.text.trim()),
      barcode: _barcode.text,
      isActive: _active,
    );
    setState(() => _saving = true);
    try {
      final repo = ref.read(productsRepositoryProvider);
      String id;
      if (_editing) {
        id = widget.productId!;
        await repo.update(id, input);
      } else {
        id = await repo.create(input);
      }
      ref.invalidate(productProvider(id));
      ref.invalidate(productListProvider);
      if (!mounted) return;
      setState(() => _dirty = false);
      context.showSuccess(_editing ? 'Product updated.' : 'Product created. Add photos and stock next.');
      if (_editing) {
        context.pop();
      } else {
        context.pushReplacement('/products/$id');
      }
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? Function(String?)? validator,
    TextInputType? keyboard,
    int maxLines = 1,
    String? helper,
    String? prefix,
    List<TextInputFormatter>? formatters,
    TextCapitalization caps = TextCapitalization.none,
  }) {
    return TextFormField(
      controller: c,
      keyboardType: keyboard,
      maxLines: maxLines,
      inputFormatters: formatters,
      textCapitalization: caps,
      decoration: InputDecoration(labelText: label, helperText: helper, prefixText: prefix),
      validator: validator,
      onChanged: (_) => _markDirty(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider);
    const money = TextInputType.numberWithOptions(decimal: true);
    final digits = [FilteringTextInputFormatter.digitsOnly];

    return UnsavedChangesGuard(
      isDirty: _dirty,
      child: Scaffold(
        appBar: AppBar(title: Text(_editing ? 'Edit product' : 'New product')),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : Form(
                key: _form,
                child: ListView(
                  children: [
                    PageBody(
                      maxWidth: 760,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SectionCard(
                            title: 'Identification',
                            child: Column(
                              children: [
                                _field(_code, 'Product code',
                                    helper: _editing ? 'Unique code' : 'Leave blank to auto-generate (e.g. AS-0001)',
                                    validator: Validators.productCode,
                                    caps: TextCapitalization.characters),
                                const SizedBox(height: 12),
                                _field(_name, 'Product name *',
                                    validator: (v) => Validators.required(v, 'Name'), caps: TextCapitalization.words),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: categories.when(
                                        data: (cats) => DropdownButtonFormField<String?>(
                                          initialValue: cats.any((c) => c.id == _categoryId) ? _categoryId : null,
                                          isExpanded: true,
                                          decoration: const InputDecoration(labelText: 'Category'),
                                          items: [
                                            const DropdownMenuItem<String?>(value: null, child: Text('No category')),
                                            for (final c in cats)
                                              DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
                                          ],
                                          onChanged: (v) => setState(() {
                                            _categoryId = v;
                                            _dirty = true;
                                          }),
                                        ),
                                        loading: () => const LinearProgressIndicator(),
                                        error: (_, _) => const Text('Could not load categories'),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton.filledTonal(
                                      tooltip: 'New category',
                                      onPressed: _addCategory,
                                      icon: const Icon(Icons.add),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                _ResponsiveRow(children: [
                                  _field(_brand, 'Brand', caps: TextCapitalization.words),
                                  _field(_model, 'Model'),
                                  _field(_variant, 'Variant (colour / capacity)'),
                                ]),
                                const SizedBox(height: 12),
                                _field(_barcode, 'Barcode (optional)'),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          SectionCard(
                            title: 'Selling prices',
                            child: _ResponsiveRow(children: [
                              _field(_retail, 'Retail price *',
                                  prefix: 'Rs. ', keyboard: money, validator: (v) => Validators.price(v, 'Retail price')),
                              _field(_wholesale, 'Wholesale price *',
                                  prefix: 'Rs. ', keyboard: money, validator: (v) => Validators.price(v, 'Wholesale price')),
                            ]),
                          ),
                          const SizedBox(height: 16),
                          SectionCard(
                            title: 'Warranty & stock alerts',
                            child: Column(
                              children: [
                                _ResponsiveRow(children: [
                                  _field(_warrantyDays, 'Warranty (days)',
                                      keyboard: TextInputType.number,
                                      formatters: digits,
                                      validator: (v) {
                                        final n = int.tryParse(v?.trim() ?? '');
                                        return (n == null || n < 0 || n > 3650) ? '0 – 3650' : null;
                                      }),
                                  _field(_reorder, 'Low-stock alert at',
                                      keyboard: TextInputType.number,
                                      formatters: digits,
                                      validator: (v) => Validators.quantity(v, allowZero: true)),
                                ]),
                                const SizedBox(height: 12),
                                _field(_warrantyNote, 'Warranty note (printed on receipt)'),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          SectionCard(
                            title: 'Description / specifications',
                            child: _field(_description, 'Description', maxLines: 5, keyboard: TextInputType.multiline),
                          ),
                          if (_editing) ...[
                            const SizedBox(height: 8),
                            SwitchListTile(
                              title: const Text('Active'),
                              subtitle: const Text('Archived products are hidden but their history is kept.'),
                              value: _active,
                              onChanged: (v) => setState(() {
                                _active = v;
                                _dirty = true;
                              }),
                            ),
                          ],
                          const SizedBox(height: 16),
                          SizedBox(
                            height: 50,
                            child: FilledButton.icon(
                              onPressed: _saving ? null : _save,
                              icon: _saving
                                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.save_outlined),
                              label: Text(_editing ? 'Save changes' : 'Create product'),
                            ),
                          ),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Fields side by side on wide screens, stacked on phones.
class _ResponsiveRow extends StatelessWidget {
  const _ResponsiveRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 520) {
        return Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              children[i],
            ],
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: children[i]),
          ],
        ],
      );
    });
  }
}
