import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../../auth/data/auth_repository.dart';
import '../../products/data/products_repository.dart';
import '../../products/presentation/widgets/product_picker.dart';
import '../../stock/data/stock_repository.dart';
import '../data/sales_repository.dart';
import '../domain/sale.dart';

class _Prices {
  const _Prices(this.wholesale, this.retail);
  final Decimal wholesale;
  final Decimal retail;
  Decimal of(SaleType t) => t == SaleType.wholesale ? wholesale : retail;
}

/// Wholesale / retail sale. Must be fully paid. A negotiated final amount
/// (e.g. bill 10,050 → paid 10,000) is saved as a visible discount with a reason.
class NewSaleScreen extends ConsumerStatefulWidget {
  const NewSaleScreen({super.key, this.initialType = SaleType.retail});
  final SaleType initialType;

  @override
  ConsumerState<NewSaleScreen> createState() => _NewSaleScreenState();
}

class _NewSaleScreenState extends ConsumerState<NewSaleScreen> {
  late SaleType _type = widget.initialType;
  final _lines = <CartLine>[];
  final _prices = <String, _Prices>{};
  final _qtyCtl = <String, TextEditingController>{};
  final _priceCtl = <String, TextEditingController>{};

  final _code = TextEditingController();
  final _codeFocus = FocusNode();
  final _customerName = TextEditingController();
  final _customerPhone = TextEditingController();
  String? _customerId;
  final _finalAmount = TextEditingController();
  final _reason = TextEditingController();
  final _tendered = TextEditingController();
  final _reference = TextEditingController();
  PaymentMethod _method = PaymentMethod.cash;
  String _key = const Uuid().v4();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_code, _customerName, _customerPhone, _finalAmount, _reason, _tendered, _reference]) {
      c.dispose();
    }
    for (final c in [..._qtyCtl.values, ..._priceCtl.values]) {
      c.dispose();
    }
    _codeFocus.dispose();
    super.dispose();
  }

  bool get _dirty => _lines.isNotEmpty;

  // ---------------- totals ----------------
  Decimal get _subtotal => _lines.fold(Decimal.zero, (a, l) => a + l.total);

  Decimal? get _final {
    final t = _finalAmount.text.trim();
    if (t.isEmpty) return null;
    return Money.tryParseInput(t);
  }

  Decimal get _discount {
    final f = _final;
    if (f == null || f >= _subtotal) return Decimal.zero;
    return _subtotal - f;
  }

  Decimal get _total => _subtotal - _discount;

  Decimal? get _tenderedValue {
    final t = _tendered.text.trim();
    if (t.isEmpty) return null;
    return Money.tryParseInput(t);
  }

  // ---------------- products ----------------
  void _addProduct({
    required String id,
    required String code,
    required String name,
    required int available,
    required Decimal wholesale,
    required Decimal retail,
  }) {
    if (available <= 0) {
      context.showError('$name is out of stock.');
      return;
    }
    _prices[id] = _Prices(wholesale, retail);
    final existing = _lines.where((l) => l.productId == id).toList();
    setState(() {
      if (existing.isNotEmpty) {
        existing.first.quantity++;
        _qtyCtl[id]!.text = '${existing.first.quantity}';
      } else {
        final price = _type == SaleType.wholesale ? wholesale : retail;
        _lines.add(CartLine(productId: id, code: code, name: name, available: available, defaultPrice: price, quantity: 1));
        _qtyCtl[id] = TextEditingController(text: '1');
        _priceCtl[id] = TextEditingController(text: Money.toInput(price));
      }
    });
  }

  Future<void> _addByCode(String code) async {
    final c = code.trim();
    if (c.isEmpty) {
      await _pick();
      return;
    }
    try {
      final hit = await ref.read(productsRepositoryProvider).lookup(c);
      if (!mounted) return;
      if (hit == null || hit['is_active'] != true) {
        // Not a code — treat it as a name and open search with it.
        await _pick(query: c);
        if (mounted) _code.clear();
      } else {
        _addProduct(
          id: hit['id'] as String,
          code: hit['code'] as String,
          name: hit['name'] as String,
          available: (hit['saleable_qty'] as num).toInt(),
          wholesale: Money.parse(hit['wholesale_price']),
          retail: Money.parse(hit['retail_price']),
        );
        _code.clear();
      }
    } catch (e) {
      if (mounted) context.showError(e);
    }
    _codeFocus.requestFocus();
  }

  Future<void> _pick({String query = ''}) async {
    final p = await pickProduct(context, initialQuery: query);
    if (p == null || !mounted) return;
    _addProduct(
      id: p.id,
      code: p.code,
      name: p.name,
      available: p.saleableQty,
      wholesale: p.wholesalePrice,
      retail: p.retailPrice,
    );
  }

  void _removeLine(CartLine l) {
    final q = _qtyCtl.remove(l.productId);
    final p = _priceCtl.remove(l.productId);
    setState(() => _lines.remove(l));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      q?.dispose();
      p?.dispose();
    });
  }

  void _switchType(SaleType t) {
    if (t == _type) return;
    setState(() {
      _type = t;
      for (var i = 0; i < _lines.length; i++) {
        final old = _lines[i];
        final price = _prices[old.productId]?.of(t) ?? old.defaultPrice;
        _lines[i] = CartLine(
          productId: old.productId,
          code: old.code,
          name: old.name,
          available: old.available,
          defaultPrice: price,
          quantity: old.quantity,
        );
        _priceCtl[old.productId]?.text = Money.toInput(price);
      }
    });
  }

  // ---------------- complete ----------------
  String? _problem(bool canDiscount) {
    if (_lines.isEmpty) return 'Add at least one product.';
    if (_type == SaleType.wholesale && _customerName.text.trim().isEmpty) return 'Enter the shopkeeper.';
    for (final l in _lines) {
      if (l.quantity <= 0) return '${l.name}: quantity must be at least 1.';
      if (l.unitPrice <= Decimal.zero) return '${l.name}: unit price must be greater than 0.';
      if (l.overStock) return '${l.name}: only ${l.available} in stock.';
    }
    if (_finalAmount.text.trim().isNotEmpty) {
      final f = _final;
      if (f == null) return 'Final amount is not valid.';
      if (f > _subtotal) return 'Final amount cannot be more than the bill.';
      if (_discount > Decimal.zero && _reason.text.trim().isEmpty) return 'Write the reason for the less amount.';
    }
    if (_tendered.text.trim().isNotEmpty && _tenderedValue == null) return 'Amount received is not valid.';
    final t = _tenderedValue;
    if (t != null && t < _total) return 'Short by ${Money.format(_total - t)} — sale must be fully paid.';
    if (t != null && t > _total && _method != PaymentMethod.cash) {
      return 'For ${_method.label} enter the exact amount (${Money.format(_total)}).';
    }
    return null;
  }

  Future<void> _complete({bool allowBelowCost = false, String belowCostReason = ''}) async {
    if (_saving) return;
    final me = ref.read(profileOrNullProvider);
    final canDiscount = (me?.isOwner ?? false) || (me?.canOverridePrice ?? false);
    final problem = _problem(canDiscount);
    if (problem != null) {
      context.showError(problem);
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await ref.read(salesRepositoryProvider).completeSale(
            type: _type,
            lines: _lines,
            customerId: _customerId,
            customerName: _customerName.text,
            customerPhone: _customerPhone.text,
            finalAmount: _discount > Decimal.zero ? _final : null,
            discountReason: _reason.text,
            method: _method,
            amountTendered: _tenderedValue,
            reference: _reference.text,
            idempotencyKey: _key,
            allowBelowCost: allowBelowCost,
            belowCostReason: belowCostReason,
          );
      if (!mounted) return;
      ref
        ..invalidate(salesListProvider)
        ..invalidate(salesSummaryProvider)
        ..invalidate(stockListProvider)
        ..invalidate(productListProvider)
        ..invalidate(customersProvider);
      _key = const Uuid().v4();
      context.showSuccess(result.change > Decimal.zero
          ? '${result.invoiceNo} saved. Give change: ${Money.format(result.change)}'
          : '${result.invoiceNo} saved.');
      setState(() => _lines.clear());
      context.pushReplacement('/sales/${result.id}');
    } catch (e) {
      final ex = AppException.from(e);
      if (ex.kind == AppErrorKind.belowCost && mounted) {
        setState(() => _saving = false);
        final reason = await _askBelowCost(ex.message);
        if (reason != null) await _complete(allowBelowCost: true, belowCostReason: reason);
        return;
      }
      if (mounted) context.showError(ex);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String?> _askBelowCost(String message) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sell below cost?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message),
            const SizedBox(height: 12),
            TextField(controller: c, decoration: const InputDecoration(labelText: 'Reason *')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (c.text.trim().isNotEmpty) Navigator.pop(ctx, c.text.trim());
            },
            child: const Text('Sell anyway'),
          ),
        ],
      ),
    );
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileOrNullProvider);
    final isOwner = profile?.isOwner ?? false;
    final canSell = isOwner || (profile?.canCreateSale ?? false);
    final canPrice = isOwner || (profile?.canOverridePrice ?? false);
    final wide = MediaQuery.sizeOf(context).width >= 980;

    if (!canSell) {
      return Scaffold(
        appBar: AppBar(title: const Text('New sale')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'You cannot create sales',
          message: 'Ask the owner to turn on "Can create sales" for your account.',
        ),
      );
    }

    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _customerCard(),
        const SizedBox(height: 12),
        _productsCard(canPrice),
      ],
    );
    final right = _billCard(canPrice);

    return UnsavedChangesGuard(
      isDirty: _dirty,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('New sale'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: SegmentedButton<SaleType>(
                segments: const [
                  ButtonSegment(value: SaleType.retail, label: Text('Retail'), icon: Icon(Icons.person_outline)),
                  ButtonSegment(value: SaleType.wholesale, label: Text('Wholesale'), icon: Icon(Icons.storefront_outlined)),
                ],
                selected: {_type},
                onSelectionChanged: (s) => _switchType(s.first),
              ),
            ),
          ],
        ),
        bottomNavigationBar: wide ? null : _stickyBar(),
        body: ListView(
          children: [
            PageBody(
              maxWidth: 1200,
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: left),
                        const SizedBox(width: 16),
                        Expanded(flex: 2, child: right),
                      ],
                    )
                  : Column(children: [left, const SizedBox(height: 12), right, const SizedBox(height: 24)]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _customerCard() {
    final customers = ref.watch(customersProvider);
    final wholesale = _type == SaleType.wholesale;
    return SectionCard(
      title: wholesale ? 'Shopkeeper *' : 'Customer (optional)',
      child: Column(
        children: [
          if (wholesale)
            Autocomplete<Customer>(
              initialValue: TextEditingValue(text: _customerName.text),
              displayStringForOption: (c) => c.name,
              optionsBuilder: (v) {
                final all = customers.hasValue ? customers.requireValue : const <Customer>[];
                final q = v.text.trim().toLowerCase();
                if (q.isEmpty) return all.where((c) => c.isShopkeeper).take(20);
                return all.where((c) => c.name.toLowerCase().contains(q) || c.phone.contains(q)).take(20);
              },
              onSelected: (c) => setState(() {
                _customerId = c.id;
                _customerName.text = c.name;
                _customerPhone.text = c.phone;
              }),
              fieldViewBuilder: (context, controller, focus, onSubmit) {
                return TextField(
                  controller: controller,
                  focusNode: focus,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: 'Shop name',
                    hintText: 'Type to search or add new',
                    prefixIcon: const Icon(Icons.storefront_outlined),
                    suffixIcon: _customerId != null ? const Icon(Icons.verified, color: AppTheme.success) : null,
                  ),
                  onChanged: (v) => setState(() {
                    _customerName.text = v;
                    _customerId = null; // typed a new / different name
                  }),
                );
              },
            )
          else
            TextField(
              controller: _customerName,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'Walk-in customer', prefixIcon: Icon(Icons.person_outline)),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _customerPhone,
            keyboardType: TextInputType.phone,
            enabled: _customerId == null,
            decoration: const InputDecoration(labelText: 'Phone (optional)', prefixIcon: Icon(Icons.phone_outlined)),
          ),
          if (wholesale && _customerId == null && _customerName.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('New shopkeeper — will be saved with this sale.', style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Widget _productsCard(bool canPrice) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Products (${_lines.length})',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  focusNode: _codeFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: _addByCode,
                  decoration: const InputDecoration(
                    labelText: 'Product code or name (press Enter)',
                    hintText: 'Type / scan code and press Enter',
                    prefixIcon: Icon(Icons.qr_code_scanner),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(tooltip: 'Search by name', onPressed: _pick, icon: const Icon(Icons.search)),
            ],
          ),
          const SizedBox(height: 12),
          if (_lines.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('No products yet.', textAlign: TextAlign.center),
            ),
          for (final l in _lines)
            Padding(
              key: ObjectKey(l.productId),
              padding: const EdgeInsets.only(bottom: 10),
              child: Card3D(
                tilt: false,
                radius: 12,
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.name, style: theme.textTheme.titleSmall),
                              Text('${l.code} · ${l.available} in stock',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: l.overStock ? AppTheme.danger : theme.colorScheme.outline,
                                  )),
                            ],
                          ),
                        ),
                        IconButton(tooltip: 'Remove', icon: const Icon(Icons.close), onPressed: () => _removeLine(l)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        IconButton.outlined(
                          icon: const Icon(Icons.remove),
                          onPressed: l.quantity <= 1
                              ? null
                              : () => setState(() {
                                    l.quantity--;
                                    _qtyCtl[l.productId]!.text = '${l.quantity}';
                                  }),
                        ),
                        SizedBox(
                          width: 64,
                          child: TextField(
                            controller: _qtyCtl[l.productId],
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            decoration: const InputDecoration(isDense: true),
                            onChanged: (v) => setState(() => l.quantity = int.tryParse(v) ?? 0),
                          ),
                        ),
                        IconButton.outlined(
                          icon: const Icon(Icons.add),
                          onPressed: () => setState(() {
                            l.quantity++;
                            _qtyCtl[l.productId]!.text = '${l.quantity}';
                          }),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: canPrice
                              ? TextField(
                                  controller: _priceCtl[l.productId],
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    labelText: 'Price',
                                    prefixText: 'Rs. ',
                                    helperText: l.priceChanged ? 'List ${Money.format(l.defaultPrice)}' : null,
                                  ),
                                  onChanged: (v) => setState(() => l.unitPrice = Money.tryParseInput(v) ?? l.defaultPrice),
                                )
                              : Text('@ ${Money.format(l.unitPrice)}', textAlign: TextAlign.end),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(Money.format(l.total), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _billCard(bool canPrice) {
    final theme = Theme.of(context);
    final t = _tenderedValue;
    final shortfall = t != null && t < _total ? _total - t : null;
    final change = t != null && t > _total ? t - _total : null;

    return SectionCard(
      title: 'Bill',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoRow('Bill total', Money.format(_subtotal), bold: true),
          if (canPrice) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _finalAmount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Final amount (if less)',
                hintText: 'e.g. 10000',
                prefixText: 'Rs. ',
                helperText: 'Agreed amount the customer will pay',
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (_discount > Decimal.zero) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _reason,
                decoration: const InputDecoration(labelText: 'Reason for less amount *', hintText: 'e.g. Round off'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              InfoRow('Less / discount', '− ${Money.format(_discount)}'),
            ],
          ],
          const Divider(height: 24),
          Row(
            children: [
              Text('To receive', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text(Money.format(_total),
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: theme.colorScheme.primary)),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in PaymentMethod.values)
                ChoiceChip(label: Text(m.label), selected: _method == m, onSelected: (_) => setState(() => _method = m)),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tendered,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: _method == PaymentMethod.cash ? 'Cash received' : 'Amount received',
              hintText: 'Leave empty if exact',
              prefixText: 'Rs. ',
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_method != PaymentMethod.cash) ...[
            const SizedBox(height: 10),
            TextField(controller: _reference, decoration: const InputDecoration(labelText: 'Transaction ID (optional)')),
          ],
          if (shortfall != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Short by ${Money.format(shortfall)} — sale must be fully paid.',
                  style: const TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w600)),
            ),
          if (change != null && _method == PaymentMethod.cash)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Give change: ${Money.format(change)}',
                  style: const TextStyle(color: AppTheme.success, fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          if (MediaQuery.sizeOf(context).width >= 980) ...[
            const SizedBox(height: 16),
            _completeButton(),
          ],
        ],
      ),
    );
  }

  Widget _completeButton() => SizedBox(
        height: 52,
        child: FilledButton.icon(
          onPressed: _saving || _lines.isEmpty ? null : () => _complete(),
          icon: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.check_circle_outline),
          label: Text('Complete sale · ${Money.format(_total)}'),
        ),
      );

  Widget _stickyBar() => SafeArea(
        child: Material(
          elevation: 10,
          child: Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 10), child: _completeButton()),
        ),
      );
}
