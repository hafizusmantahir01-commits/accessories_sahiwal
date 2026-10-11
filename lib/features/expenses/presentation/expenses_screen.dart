import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/correction_dialogs.dart';
import '../../../core/widgets/three_d.dart';
import '../../sales/data/sales_repository.dart';
import '../data/expenses_repository.dart';

enum _Range { thisMonth, lastMonth, thisYear, all }

/// Shop expenses (rent, bills, salary …). They are taken out of profit to show
/// the real net profit on the Sales screen.
class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  _Range _range = _Range.thisMonth;

  (DateTime, DateTime) get _dates {
    final t = BizTime.today();
    return switch (_range) {
      _Range.thisMonth => (DateTime(t.year, t.month, 1), t),
      _Range.lastMonth => (DateTime(t.year, t.month - 1, 1), DateTime(t.year, t.month, 0)),
      _Range.thisYear => (DateTime(t.year, 1, 1), t),
      _Range.all => (DateTime(2000, 1, 1), t),
    };
  }

  String _label(_Range r) => switch (r) {
        _Range.thisMonth => 'This month',
        _Range.lastMonth => 'Last month',
        _Range.thisYear => 'This year',
        _Range.all => 'All',
      };

  void _refreshAll() {
    ref
      ..invalidate(expensesProvider)
      ..invalidate(ownerProfitProvider)
      ..invalidate(profitByMonthProvider);
  }

  Future<void> _edit([Expense? e]) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _ExpenseDialog(expense: e));
    if (saved == true) _refreshAll();
  }

  Future<void> _delete(Expense e) async {
    final reason = await confirmDeleteWithReason(
      context,
      title: 'Delete expense?',
      message: 'Only this expense is removed.',
      willRemove: ['${e.category.label} · ${Money.format(e.amount)} · ${BizTime.date(e.date)}'],
    );
    if (reason == null) return;
    try {
      await ref.read(expensesRepositoryProvider).delete(e.id, reason);
      _refreshAll();
      if (mounted) context.showSuccess('Expense deleted. Saved in History.');
    } catch (err) {
      if (mounted) context.showError(err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(expensesProvider(_dates));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Expenses')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add expense'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(expensesProvider),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            PageBody(
              maxWidth: 760,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final r in _Range.values)
                      ChoiceChip(label: Text(_label(r)), selected: _range == r, onSelected: (_) => setState(() => _range = r)),
                  ]),
                  const SizedBox(height: 12),
                  AsyncView<List<Expense>>(
                    value: list,
                    onRetry: () => ref.invalidate(expensesProvider),
                    data: (items) {
                      final total = items.fold(Money.zero, (a, e) => a + e.amount);
                      final byCat = <ExpenseCategory, Decimal>{};
                      for (final e in items) {
                        byCat[e.category] = (byCat[e.category] ?? Decimal.zero) + e.amount;
                      }
                      final cats = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Card3D(
                            maxAngle: 0.05,
                            padding: const EdgeInsets.all(18),
                            colors: AppTheme.heroColors,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Expenses · ${_label(_range)}', style: const TextStyle(color: Colors.white70)),
                                const SizedBox(height: 4),
                                Text(Money.format(total),
                                    style: theme.textTheme.headlineMedium
                                        ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                                Text('${items.length} entries', style: const TextStyle(color: Colors.white70)),
                              ],
                            ),
                          ),
                          if (cats.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            SectionCard(
                              title: 'By category',
                              child: Column(children: [
                                for (final c in cats) InfoRow(c.key.label, Money.format(c.value)),
                              ]),
                            ),
                          ],
                          const SizedBox(height: 12),
                          if (items.isEmpty)
                            const EmptyState(icon: Icons.receipt_long_outlined, title: 'No expenses in this period')
                          else
                            for (final e in items) ...[
                              Card3D(
                                tilt: false,
                                radius: 14,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Row(
                                  children: [
                                    IconBadge3D(icon: e.category.icon, color: theme.colorScheme.primary, size: 38),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(e.category.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                                          Text(
                                            '${BizTime.date(e.date)}${e.note.isNotEmpty ? ' · ${e.note}' : ''}'
                                            '${e.fromCash ? '' : ' · not from galla'} · ${e.createdBy}',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                    Text(Money.format(e.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
                                    PopupMenuButton<String>(
                                      onSelected: (v) => v == 'edit' ? _edit(e) : _delete(e),
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Delete', style: TextStyle(color: theme.colorScheme.error)),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpenseDialog extends ConsumerStatefulWidget {
  const _ExpenseDialog({this.expense});
  final Expense? expense;

  @override
  ConsumerState<_ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends ConsumerState<_ExpenseDialog> {
  final _form = GlobalKey<FormState>();
  late final _amount =
      TextEditingController(text: widget.expense == null ? '' : Money.toInput(widget.expense!.amount));
  late final _note = TextEditingController(text: widget.expense?.note ?? '');
  final _reason = TextEditingController();
  late ExpenseCategory _category = widget.expense?.category ?? ExpenseCategory.rent;
  late DateTime _date = widget.expense?.date ?? BizTime.today();
  late bool _fromCash = widget.expense?.fromCash ?? true;
  bool _saving = false;

  bool get _editing => widget.expense != null;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: BizTime.today(),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref.read(expensesRepositoryProvider).save(
            id: widget.expense?.id,
            date: _date,
            category: _category,
            amount: Money.tryParseInput(_amount.text)!,
            note: _note.text,
            reason: _editing ? _reason.text : null,
            fromCash: _fromCash,
          );
      if (!mounted) return;
      context.showSuccess(_editing ? 'Expense updated. Saved in History.' : 'Expense added.');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_editing ? 'Edit expense' : 'Add expense'),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<ExpenseCategory>(
                initialValue: _category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final c in ExpenseCategory.values)
                    DropdownMenuItem(value: c, child: Row(children: [Icon(c.icon, size: 18), const SizedBox(width: 8), Text(c.label)])),
                ],
                onChanged: (v) => setState(() => _category = v ?? ExpenseCategory.other),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amount,
                autofocus: !_editing,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount *', prefixText: 'Rs. '),
                validator: (v) => Validators.price(v, 'Amount'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _fromCash,
                onChanged: (v) => setState(() => _fromCash = v),
                title: const Text('Paid from galla (shop cash)'),
                subtitle: Text(_fromCash ? 'Counts in day closing' : 'Paid from bank / home'),
              ),
              OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.event),
                label: Text('Date: ${BizTime.date(_date)}'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _note,
                decoration: InputDecoration(
                  labelText: _category == ExpenseCategory.other ? 'What for? *' : 'Note (optional)',
                ),
                validator: (v) =>
                    _category == ExpenseCategory.other && (v ?? '').trim().isEmpty ? 'Write what it was for' : null,
              ),
              if (_editing) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _reason,
                  decoration: const InputDecoration(labelText: 'Reason for change *', hintText: 'e.g. wrong amount'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Write a short reason' : null,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_editing ? 'Save changes' : 'Add')),
      ],
    );
  }
}
