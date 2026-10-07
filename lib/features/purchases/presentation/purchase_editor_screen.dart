import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/common.dart';
import '../../products/presentation/widgets/product_picker.dart';
import '../../suppliers/data/suppliers_repository.dart';
import '../../suppliers/presentation/suppliers_screen.dart';
import '../data/purchases_repository.dart';
import '../domain/purchase.dart';
import 'post_purchase_dialog.dart';

class _LineEditor {
  _LineEditor(this.line)
      : qty = TextEditingController(text: '${line.quantity}'),
        price = TextEditingController(text: Money.toInput(line.unitPrice)),
        discount = TextEditingController(
          text: line.lineDiscount == Decimal.zero ? '' : Money.toInput(line.lineDiscount),
        );

  final DraftLine line;
  final TextEditingController qty;
  final TextEditingController price;
  final TextEditingController discount;

  void sync() {
    line.quantity = int.tryParse(qty.text.trim()) ?? 0;
    line.unitPrice = Money.tryParseInput(price.text) ?? Decimal.zero;
    line.lineDiscount = discount.text.trim().isEmpty ? Decimal.zero : (Money.tryParseInput(discount.text) ?? Decimal.zero);
  }

  void dispose() {
    qty.dispose();
    price.dispose();
    discount.dispose();
  }
}

/// Draft → review → fully-paid posting. Saving a draft never changes stock.
class PurchaseEditorScreen extends ConsumerStatefulWidget {
  const PurchaseEditorScreen({super.key, this.purchaseId});
  final String? purchaseId;

  @override
  ConsumerState<PurchaseEditorScreen> createState() => _PurchaseEditorScreenState();
}

class _PurchaseEditorScreenState extends ConsumerState<PurchaseEditorScreen> {
  final _form = GlobalKey<FormState>();
  final _supplierRef = TextEditingController();
  final _extra = TextEditingController();
  final _extraNote = TextEditingController();
  final _notes = TextEditingController();
  final _lines = <_LineEditor>[];
  String? _draftId;
  String? _supplierId;
  DateTime _date = BizTime.today();
  PaymentMethod _method = PaymentMethod.cash;
  bool _loading = false;
  bool _dirty = false;
  bool _saving = false;
  List<String> _duplicates = const [];

  @override
  void initState() {
    super.initState();
    _draftId = widget.purchaseId;
    if (_draftId != null) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await ref.read(purchasesRepositoryProvider).get(_draftId!);
      if (!p.isDraft) {
        if (mounted) {
          context.showError('Posted purchases cannot be edited.');
          context.pop();
        }
        return;
      }
      _supplierId = p.supplierId;
      _date = DateTime.tryParse(p.documentDate) ?? BizTime.today();
      _supplierRef.text = p.supplierRef;
      _extra.text = p.extraCosts == Decimal.zero ? '' : Money.toInput(p.extraCosts);
      _extraNote.text = p.extraCostsNote;
      _notes.text = p.notes;
      _method = p.paymentMethod;
      for (final l in p.lines) {
        _lines.add(_LineEditor(DraftLine(
          productId: l.productId,
          productCode: l.productCode,
          productName: l.productName,
          quantity: l.quantity,
          unitPrice: l.unitPrice,
          lineDiscount: l.lineDiscount,
        )));
      }
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _supplierRef.dispose();
    _extra.dispose();
    _extraNote.dispose();
    _notes.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _changed() => setState(() => _dirty = true);

  Decimal get _extraCosts => _extra.text.trim().isEmpty ? Decimal.zero : (Money.tryParseInput(_extra.text) ?? Decimal.zero);

  PurchasePreview get _preview {
    for (final l in _lines) {
      l.sync();
    }
    return PurchasePreview([for (final l in _lines) l.line], _extraCosts);
  }

  Future<void> _addLine() async {
    final p = await pickProduct(context);
    if (p == null || !mounted) return;
    final existing = _lines.where((l) => l.line.productId == p.id).toList();
    if (existing.isNotEmpty) {
      final e = existing.first;
      e.qty.text = '${(int.tryParse(e.qty.text) ?? 0) + 1}';
      context.showSuccess('${p.name}: quantity increased.');
    } else {
      _lines.add(_LineEditor(DraftLine(productId: p.id, productCode: p.code, productName: p.name)));
    }
    _changed();
  }

  Future<void> _checkDuplicate() async {
    if (_supplierId == null || _supplierRef.text.trim().isEmpty) {
      setState(() => _duplicates = const []);
      return;
    }
    try {
      final d = await ref.read(purchasesRepositoryProvider)
          .duplicateRefs(supplierId: _supplierId!, ref: _supplierRef.text, excludeId: _draftId);
      if (mounted) setState(() => _duplicates = d);
    } catch (_) {/* warning only */}
  }

  bool _validate() {
    if (!_form.currentState!.validate()) return false;
    if (_supplierId == null) {
      context.showError('Select a supplier.');
      return false;
    }
    if (_lines.isEmpty) {
      context.showError('Add at least one product.');
      return false;
    }
    for (final l in _lines) {
      l.sync();
      if (!l.line.discountValid) {
        context.showError('${l.line.productName}: discount cannot exceed the line value.');
        return false;
      }
    }
    return true;
  }

  Future<String?> _saveDraft({bool quiet = false}) async {
    if (_saving || !_validate()) return null;
    setState(() => _saving = true);
    try {
      final id = await ref.read(purchasesRepositoryProvider).saveDraft(
            id: _draftId,
            supplierId: _supplierId!,
            documentDate: BizTime.isoDate(_date),
            supplierRef: _supplierRef.text,
            extraCosts: _extraCosts,
            extraCostsNote: _extraNote.text,
            paymentMethod: _method,
            notes: _notes.text,
            lines: [for (final l in _lines) l.line],
          );
      _draftId = id;
      ref.invalidate(purchaseListProvider);
      ref.invalidate(purchaseProvider(id));
      if (mounted) {
        setState(() => _dirty = false);
        if (!quiet) context.showSuccess('Draft saved. Stock is not changed until you post.');
      }
      return id;
    } catch (e) {
      if (mounted) context.showError(e);
      return null;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reviewAndPost() async {
    final id = await _saveDraft(quiet: true);
    if (id == null || !mounted) return;
    final Purchase purchase;
    try {
      purchase = await ref.read(purchasesRepositoryProvider).get(id);
    } catch (e) {
      if (mounted) context.showError(e);
      return;
    }
    if (!mounted) return;
    final result = await showPostPurchaseDialog(context, purchase);
    if (result != null && mounted) {
      context.pushReplacement('/private/purchases/${result.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = ref.watch(suppliersProvider(false));
    final preview = _preview;
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final summary = _Summary(preview: preview);
    final actions = Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _saving ? null : () => _saveDraft(),
            child: const Text('Save draft'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: _saving ? null : _reviewAndPost,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Review & post'),
          ),
        ),
      ],
    );

    return UnsavedChangesGuard(
      isDirty: _dirty,
      child: Scaffold(
        appBar: AppBar(title: Text(_draftId == null ? 'New purchase' : 'Edit draft purchase')),
        bottomNavigationBar: wide
            ? null
            : SafeArea(
                child: Material(
                  elevation: 8,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [summary, const SizedBox(height: 8), actions]),
                  ),
                ),
              ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Form(
                key: _form,
                child: ListView(
                  children: [
                    PageBody(
                      maxWidth: 1100,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _supplierCard(suppliers),
                                const SizedBox(height: 16),
                                _linesCard(),
                                const SizedBox(height: 16),
                                _costsCard(),
                                const SizedBox(height: 24),
                              ],
                            ),
                          ),
                          if (wide) ...[
                            const SizedBox(width: 16),
                            SizedBox(
                              width: 320,
                              child: SectionCard(
                                title: 'Summary',
                                child: Column(children: [summary, const SizedBox(height: 16), actions]),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _supplierCard(AsyncValue<List<Supplier>> suppliers) {
    return SectionCard(
      title: 'Supplier bill',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: suppliers.when(
                  data: (list) => DropdownButtonFormField<String>(
                    initialValue: list.any((s) => s.id == _supplierId) ? _supplierId : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Supplier *'),
                    items: [for (final s in list) DropdownMenuItem(value: s.id, child: Text(s.name))],
                    validator: (v) => v == null ? 'Supplier is required' : null,
                    onChanged: (v) {
                      _supplierId = v;
                      _changed();
                      _checkDuplicate();
                    },
                  ),
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => ErrorView(error: e),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'New supplier',
                icon: const Icon(Icons.add),
                onPressed: () async {
                  final s = await showSupplierEditor(context, ref);
                  if (s != null) {
                    _supplierId = s.id;
                    _changed();
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _date.isAfter(BizTime.today()) ? BizTime.today() : _date,
                      firstDate: DateTime(2020),
                      lastDate: BizTime.today(),
                      helpText: 'Supplier bill date',
                    );
                    if (d != null) {
                      _date = d;
                      _changed();
                    }
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Bill date', suffixIcon: Icon(Icons.event)),
                    child: Text(BizTime.date(BizTime.isoDate(_date))),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Focus(
                  onFocusChange: (has) {
                    if (!has) _checkDuplicate();
                  },
                  child: TextFormField(
                    controller: _supplierRef,
                    decoration: const InputDecoration(labelText: 'Supplier bill no.'),
                    onChanged: (_) {
                    if (!_dirty) _changed();
                  },
                  ),
                ),
              ),
            ],
          ),
          if (_duplicates.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This bill number is already used in ${_duplicates.join(', ')}. Check it is not a duplicate.',
                      style: TextStyle(color: Colors.orange.shade900),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Stock is posted at the time you post, even if the bill date is earlier.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _linesCard() {
    const money = TextInputType.numberWithOptions(decimal: true);
    return SectionCard(
      title: 'Products (${_lines.length})',
      trailing: FilledButton.tonalIcon(onPressed: _addLine, icon: const Icon(Icons.add), label: const Text('Add')),
      child: _lines.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('No products yet. Tap "Add" and enter a product code.', textAlign: TextAlign.center),
            )
          : Column(
              children: [
                for (var i = 0; i < _lines.length; i++) ...[
                  if (i > 0) const Divider(height: 24),
                  Builder(key: ObjectKey(_lines[i]), builder: (context) {
                    final e = _lines[i];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text('${e.line.productName}  ·  ${e.line.productCode}',
                                  style: Theme.of(context).textTheme.titleSmall),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                final removed = _lines.removeAt(i);
                                _changed();
                                // Dispose after the fields using these controllers are gone.
                                WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 80,
                              child: TextFormField(
                                controller: e.qty,
                                keyboardType: TextInputType.number,
                                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                decoration: const InputDecoration(labelText: 'Qty'),
                                validator: Validators.quantity,
                                onChanged: (_) => _changed(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextFormField(
                                controller: e.price,
                                keyboardType: money,
                                decoration: const InputDecoration(labelText: 'Unit price'),
                                validator: (v) => Validators.money(v),
                                onChanged: (_) => _changed(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextFormField(
                                controller: e.discount,
                                keyboardType: money,
                                decoration: const InputDecoration(labelText: 'Discount'),
                                validator: (v) => Validators.money(v, required: false),
                                onChanged: (_) => _changed(),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text('Line total ${Money.format(e.line.net)}',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ],
                    );
                  }),
                ],
              ],
            ),
    );
  }

  Widget _costsCard() {
    return SectionCard(
      title: 'Transport / other costs & payment',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  controller: _extra,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Extra costs', prefixText: 'Rs. '),
                  validator: (v) => Validators.money(v, required: false),
                  onChanged: (_) => _changed(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _extraNote,
                  decoration: const InputDecoration(labelText: 'Extra cost note', hintText: 'e.g. transport'),
                  onChanged: (_) {
                    if (!_dirty) _changed();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Extra costs are added to product cost (split by line value), not counted as an expense.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<PaymentMethod>(
            initialValue: _method,
            decoration: const InputDecoration(labelText: 'Payment method'),
            items: [for (final m in PaymentMethod.values) DropdownMenuItem(value: m, child: Text(m.label))],
            onChanged: (v) {
              if (v != null) {
                _method = v;
                _changed();
              }
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _notes,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Notes'),
            onChanged: (_) {
                    if (!_dirty) _changed();
                  },
          ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.preview});
  final PurchasePreview preview;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InfoRow('Products', Money.format(preview.merchandise)),
        InfoRow('Extra costs', Money.format(preview.extraCosts)),
        const Divider(height: 12),
        InfoRow('Total to pay', Money.format(preview.total), bold: true),
      ],
    );
  }
}
