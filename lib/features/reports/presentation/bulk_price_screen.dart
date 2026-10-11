import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../products/data/products_repository.dart';
import '../../products/domain/product.dart';
import '../data/reports_repository.dart';

/// Change the selling price of many products at once (e.g. all chargers +5%).
/// Always shows a preview first; the change is saved in History.
class BulkPriceScreen extends ConsumerStatefulWidget {
  const BulkPriceScreen({super.key});

  @override
  ConsumerState<BulkPriceScreen> createState() => _BulkPriceScreenState();
}

class _BulkPriceScreenState extends ConsumerState<BulkPriceScreen> {
  final _search = TextEditingController();
  final _value = TextEditingController();
  String _query = '';
  String? _categoryId;
  final Set<String> _selected = {};
  String _field = 'both'; // retail | wholesale | both
  String _mode = 'percent'; // percent | amount
  bool _increase = true;
  int _round = 0;
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    final v = Money.tryParseInput(_value.text);
    if (_selected.isEmpty) {
      context.showError('Tick the products to change.');
      return;
    }
    if (v == null || v.signum <= 0) {
      context.showError('Enter how much to change (more than 0).');
      return;
    }
    final value = _increase ? v : -v;
    setState(() => _busy = true);
    try {
      final repo = ref.read(reportsRepositoryProvider);
      final rows = await repo.pricePreview(
          productIds: _selected.toList(), field: _field, mode: _mode, value: value, round: _round);
      if (!mounted) return;
      final reason = TextEditingController();
      final bad = rows.where((r) => r.invalid).toList();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('New prices (${rows.length})'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (bad.isNotEmpty)
                  Text('${bad.length} prices would become 0 or less. Change the amount.',
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error, fontWeight: FontWeight.w700)),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final r in rows)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('${r.name} · ${r.code}', maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            [
                              if (r.oldRetail != r.newRetail)
                                'Retail ${Money.format(r.oldRetail)} → ${Money.format(r.newRetail)}',
                              if (r.oldWholesale != r.newWholesale)
                                'Wholesale ${Money.format(r.oldWholesale)} → ${Money.format(r.newWholesale)}',
                            ].join('\n').ifEmpty('No change'),
                            style: TextStyle(color: r.invalid ? Theme.of(ctx).colorScheme.error : null),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: reason,
                  decoration: const InputDecoration(labelText: 'Reason *', hintText: 'e.g. new rates from market'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: bad.isNotEmpty
                  ? null
                  : () {
                      if (reason.text.trim().isNotEmpty) Navigator.pop(ctx, true);
                    },
              child: const Text('Apply new prices'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final n = await repo.priceApply(
          productIds: _selected.toList(),
          field: _field,
          mode: _mode,
          value: value,
          round: _round,
          reason: reason.text);
      ref
        ..invalidate(productListProvider)
        ..invalidate(productProvider);
      if (!mounted) return;
      context.showSuccess('$n products updated. Saved in History.');
      setState(_selected.clear);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productListProvider(ProductQuery(search: _query, categoryId: _categoryId)));
    final categories = ref.watch(categoriesProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Change prices together')),
      body: ListView(
        children: [
          PageBody(
            maxWidth: 820,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionCard(
                  title: '1. How to change',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'retail', label: Text('Retail')),
                          ButtonSegment(value: 'wholesale', label: Text('Wholesale')),
                          ButtonSegment(value: 'both', label: Text('Both')),
                        ],
                        selected: {_field},
                        onSelectionChanged: (v) => setState(() => _field = v.first),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: true, icon: Icon(Icons.arrow_upward), label: Text('Increase')),
                              ButtonSegment(value: false, icon: Icon(Icons.arrow_downward), label: Text('Decrease')),
                            ],
                            selected: {_increase},
                            onSelectionChanged: (v) => setState(() => _increase = v.first),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _value,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: InputDecoration(
                                labelText: _mode == 'percent' ? 'By how many %' : 'By how many rupees',
                                suffixText: _mode == 'percent' ? '%' : 'Rs',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(value: 'percent', label: Text('%')),
                              ButtonSegment(value: 'amount', label: Text('Rs')),
                            ],
                            selected: {_mode},
                            onSelectionChanged: (v) => setState(() => _mode = v.first),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<int>(
                        initialValue: _round,
                        decoration: const InputDecoration(labelText: 'Round new price to'),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('No rounding')),
                          DropdownMenuItem(value: 1, child: Text('Nearest 1 rupee')),
                          DropdownMenuItem(value: 5, child: Text('Nearest 5 rupees')),
                          DropdownMenuItem(value: 10, child: Text('Nearest 10 rupees')),
                          DropdownMenuItem(value: 50, child: Text('Nearest 50 rupees')),
                        ],
                        onChanged: (v) => setState(() => _round = v ?? 0),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: '2. Choose products (${_selected.length} ticked)',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _search,
                        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name / code, press Enter'),
                        onSubmitted: (v) => setState(() => _query = v.trim()),
                      ),
                      const SizedBox(height: 8),
                      if (categories.hasValue)
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            ChoiceChip(
                                label: const Text('All'),
                                selected: _categoryId == null,
                                onSelected: (_) => setState(() => _categoryId = null)),
                            for (final c in categories.requireValue.where((c) => c.isActive))
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: ChoiceChip(
                                  label: Text(c.name),
                                  selected: _categoryId == c.id,
                                  onSelected: (_) => setState(() => _categoryId = c.id),
                                ),
                              ),
                          ]),
                        ),
                      const SizedBox(height: 8),
                      AsyncView<List<Product>>(
                        value: products,
                        onRetry: () => ref.invalidate(productListProvider),
                        data: (list) {
                          final active = list.where((p) => p.isActive).toList();
                          if (active.isEmpty) return const Text('No products found.');
                          final allTicked = active.every((p) => _selected.contains(p.id));
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  onPressed: () => setState(() {
                                    if (allTicked) {
                                      _selected.removeAll(active.map((p) => p.id));
                                    } else {
                                      _selected.addAll(active.map((p) => p.id));
                                    }
                                  }),
                                  child: Text(allTicked ? 'Untick these ${active.length}' : 'Tick all ${active.length} shown'),
                                ),
                              ),
                              for (final p in active)
                                CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  value: _selected.contains(p.id),
                                  onChanged: (v) => setState(() {
                                    if (v == true) {
                                      _selected.add(p.id);
                                    } else {
                                      _selected.remove(p.id);
                                    }
                                  }),
                                  title: Text('${p.name} · ${p.code}', maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text('Retail ${Money.format(p.retailPrice)} · Wholesale ${Money.format(p.wholesalePrice)}',
                                      style: theme.textTheme.bodySmall),
                                ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _preview,
                  icon: const Icon(Icons.preview_outlined),
                  label: Text('See new prices (${_selected.length})'),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
