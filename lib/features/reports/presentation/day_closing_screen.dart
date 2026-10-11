import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../../auth/data/auth_repository.dart';
import '../../purchases/domain/purchase.dart' show PaymentMethod;
import '../data/reports_repository.dart';

/// End of day: what should be in the galla vs what is really there.
class DayClosingScreen extends ConsumerStatefulWidget {
  const DayClosingScreen({super.key});

  @override
  ConsumerState<DayClosingScreen> createState() => _DayClosingScreenState();
}

class _DayClosingScreenState extends ConsumerState<DayClosingScreen> {
  DateTime _date = BizTime.today();
  final _opening = TextEditingController();
  final _cashOut = TextEditingController();
  final _counted = TextEditingController();
  final _note = TextEditingController();
  DateTime? _filledFor;
  bool _saving = false;

  @override
  void dispose() {
    _opening.dispose();
    _cashOut.dispose();
    _counted.dispose();
    _note.dispose();
    super.dispose();
  }

  Decimal _v(TextEditingController c) => Money.tryParseInput(c.text.trim().isEmpty ? '0' : c.text) ?? Decimal.zero;

  void _fill(DayCash d) {
    if (_filledFor == d.date) return;
    _filledFor = d.date;
    final c = d.closing;
    _opening.text = Money.toInput(c?.opening ?? d.openingDefault);
    _cashOut.text = c == null || c.cashOut == Decimal.zero ? '' : Money.toInput(c.cashOut);
    _counted.text = c == null ? '' : Money.toInput(c.counted);
    _note.text = c?.note ?? '';
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2024),
      lastDate: BizTime.today(),
    );
    if (d != null) setState(() => _date = DateTime(d.year, d.month, d.day));
  }

  Future<void> _save(DayCash d, Decimal expected) async {
    if (_counted.text.trim().isEmpty || Money.tryParseInput(_counted.text) == null) {
      context.showError('Count the cash in the galla and enter the amount.');
      return;
    }
    for (final c in [_opening, _cashOut]) {
      if (c.text.trim().isNotEmpty && Money.tryParseInput(c.text) == null) {
        context.showError('Enter valid amounts.');
        return;
      }
    }
    String? reason;
    if (d.closing != null) {
      final r = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Change this closing?'),
          content: TextField(
            controller: r,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Reason *', hintText: 'e.g. counted again'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (r.text.trim().isNotEmpty) Navigator.pop(ctx, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      reason = r.text;
    }
    final diff = _v(_counted) - expected;
    if (d.closing == null && mounted) {
      final ok = await confirmDialog(
        context,
        title: 'Close ${BizTime.date(_date)}?',
        message: 'Should be ${Money.format(expected)}, counted ${Money.format(_v(_counted))}.\n'
            '${diff.signum == 0 ? 'Cash is exactly right.' : (diff.signum < 0 ? 'SHORT by ${Money.format(-diff)}.' : 'EXTRA ${Money.format(diff)}.')}',
        confirmLabel: 'Close day',
      );
      if (!ok) return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(reportsRepositoryProvider).closeDay(
            date: _date,
            opening: _v(_opening),
            cashOut: _v(_cashOut),
            counted: _v(_counted),
            note: _note.text,
            reason: reason,
          );
      ref
        ..invalidate(dayCashProvider)
        ..invalidate(closingsProvider);
      _filledFor = null;
      if (mounted) context.showSuccess('Day closed. Saved in History.');
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final day = ref.watch(dayCashProvider(_date));
    final isOwner = ref.watch(isOwnerProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Day closing (galla)'),
        actions: [
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(dayCashProvider)),
        ],
      ),
      body: ListView(
        children: [
          PageBody(
            maxWidth: 680,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event),
                  label: Text(BizTime.date(_date)),
                ),
                const SizedBox(height: 12),
                AsyncView<DayCash>(
                  value: day,
                  onRetry: () => ref.invalidate(dayCashProvider(_date)),
                  data: (d) {
                    _fill(d);
                    final expected = _v(_opening) + d.cashSales - d.cashRefunds - d.cashExpenses - _v(_cashOut);
                    final counted = _counted.text.trim().isEmpty ? null : _v(_counted);
                    final diff = counted == null ? null : counted - expected;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (d.closing != null)
                          Card(
                            color: Colors.green.withValues(alpha: 0.08),
                            child: ListTile(
                              leading: const Icon(Icons.verified_outlined, color: Colors.green),
                              title: const Text('This day is closed'),
                              subtitle: Text('Counted ${Money.format(d.closing!.counted)} · '
                                  '${d.closing!.difference.signum == 0 ? 'exact' : (d.closing!.difference.signum < 0 ? 'short ${Money.format(-d.closing!.difference)}' : 'extra ${Money.format(d.closing!.difference)}')}'),
                            ),
                          ),
                        SectionCard(
                          title: 'Cash in the galla',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                controller: _opening,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: const InputDecoration(
                                  labelText: 'Cash at start of day',
                                  prefixText: 'Rs. ',
                                  helperText: 'Filled from the last closing',
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                              const SizedBox(height: 8),
                              InfoRow('+ Cash sales (${d.bills} bills)', Money.format(d.cashSales)),
                              InfoRow('− Cash given back (returns)', Money.format(d.cashRefunds)),
                              InfoRow('− Expenses paid from galla', Money.format(d.cashExpenses)),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _cashOut,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: const InputDecoration(
                                  labelText: '− Cash taken out (home / bank / supplier)',
                                  prefixText: 'Rs. ',
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                              const Divider(height: 24),
                              InfoRow('Should be in galla', Money.format(expected), bold: true),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _counted,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: theme.textTheme.titleLarge,
                          decoration: const InputDecoration(
                            labelText: 'Cash counted now *',
                            prefixText: 'Rs. ',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        if (diff != null) ...[
                          const SizedBox(height: 12),
                          Card3D(
                            tilt: false,
                            padding: const EdgeInsets.all(16),
                            colors: diff.signum == 0 ? AppTheme.heroColors : null,
                            child: Row(
                              children: [
                                Icon(
                                  diff.signum == 0 ? Icons.check_circle : Icons.warning_amber_rounded,
                                  color: diff.signum == 0 ? Colors.white : (diff.signum < 0 ? AppTheme.danger : AppTheme.warning),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    diff.signum == 0
                                        ? 'Cash is exactly right'
                                        : (diff.signum < 0 ? 'SHORT (kam) ${Money.format(-diff)}' : 'EXTRA (zyada) ${Money.format(diff)}'),
                                    style: theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: diff.signum == 0 ? Colors.white : null,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (d.otherMethods.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          SectionCard(
                            title: 'Not in galla (online payments)',
                            child: Column(children: [
                              for (final e in d.otherMethods.entries)
                                InfoRow(PaymentMethod.parse(e.key).label, Money.format(e.value)),
                            ]),
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)')),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _saving ? null : () => _save(d, expected),
                          icon: const Icon(Icons.lock_clock),
                          label: Text(d.closing == null ? 'Close the day' : 'Change closing'),
                        ),
                      ],
                    );
                  },
                ),
                if (isOwner) ...[
                  const SizedBox(height: 24),
                  const _ClosingHistory(),
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

class _ClosingHistory extends ConsumerWidget {
  const _ClosingHistory();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(closingsProvider);
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Past closings',
      child: list.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorView(error: e),
        data: (rows) {
          if (rows.isEmpty) return const Text('No days closed yet.');
          final shortTotal = rows.fold(Money.zero, (a, r) => r.difference.signum < 0 ? a + r.difference : a);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (shortTotal.signum < 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('Total short in these days: ${Money.format(-shortTotal)}',
                      style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.danger, fontWeight: FontWeight.w700)),
                ),
              for (final r in rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(BizTime.date(r.date), style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('Should ${Money.format(r.expected)} · counted ${Money.format(r.counted)}'
                      '${r.closedBy.isNotEmpty ? ' · ${r.closedBy}' : ''}${r.note.isNotEmpty ? '\n${r.note}' : ''}'),
                  trailing: Text(
                    r.difference.signum == 0
                        ? 'OK'
                        : (r.difference.signum < 0 ? '− ${Money.format(-r.difference)}' : '+ ${Money.format(r.difference)}'),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: r.difference.signum == 0
                          ? Colors.green.shade700
                          : (r.difference.signum < 0 ? AppTheme.danger : AppTheme.warning),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
