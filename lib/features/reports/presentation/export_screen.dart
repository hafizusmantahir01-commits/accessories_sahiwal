import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/files/share_file.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../data/reports_repository.dart';

enum _Kind { text, money, count, date, dateTime, yesNo }

typedef _Col = (String header, String key, _Kind kind);

/// Builds a real .xlsx workbook (one sheet per topic) from the export data.
Uint8List buildExportWorkbook(Map<String, dynamic> data) {
  final book = xl.Excel.createExcel();
  final defaultSheet = book.getDefaultSheet() ?? 'Sheet1';
  final header = xl.CellStyle(bold: true);

  void sheet(String name, List<_Col> cols, List rows) {
    final s = book[name];
    for (var i = 0; i < cols.length; i++) {
      s.updateCell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0), xl.TextCellValue(cols[i].$1),
          cellStyle: header);
    }
    var r = 1;
    for (final raw in rows) {
      final m = Map<String, dynamic>.from(raw as Map);
      for (var i = 0; i < cols.length; i++) {
        final (_, key, kind) = cols[i];
        final v = m[key];
        xl.CellValue? cell;
        if (v == null) {
          cell = null;
        } else {
          switch (kind) {
            case _Kind.money:
              final d = v is num ? v.toDouble() : double.tryParse(v.toString());
              cell = d == null ? xl.TextCellValue(v.toString()) : xl.DoubleCellValue(d);
            case _Kind.count:
              final n = v is num ? v.toInt() : int.tryParse(v.toString());
              cell = n == null ? xl.TextCellValue(v.toString()) : xl.IntCellValue(n);
            case _Kind.date:
              cell = xl.TextCellValue(BizTime.date(v));
            case _Kind.dateTime:
              cell = xl.TextCellValue(BizTime.dateTime(v));
            case _Kind.yesNo:
              cell = xl.TextCellValue(v == true ? 'Yes' : 'No');
            case _Kind.text:
              cell = xl.TextCellValue(v.toString());
          }
        }
        if (cell != null) s.updateCell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: r), cell);
      }
      r++;
    }
  }

  final summary = Map<String, dynamic>.from((data['summary'] as Map?) ?? const {});
  sheet('Summary', const [
    ('Item', 'k', _Kind.text),
    ('Amount (Rs)', 'v', _Kind.money),
  ], [
    {'k': 'From', 'v': null},
    {'k': 'Sales', 'v': summary['sales']},
    {'k': 'Returns (money given back)', 'v': summary['returns']},
    {'k': 'Net sales', 'v': summary['net_sales']},
    {'k': 'Cost of goods sold', 'v': summary['cogs']},
    {'k': 'Profit on goods', 'v': summary['gross_profit']},
    {'k': 'Stock loss', 'v': summary['stock_loss']},
    {'k': 'Expenses', 'v': summary['expenses']},
    {'k': 'NET PROFIT', 'v': summary['net_profit']},
  ]);
  // Period text in the first row of the summary
  book['Summary'].updateCell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1),
      xl.TextCellValue('Period: ${BizTime.date(data['from'])} to ${BizTime.date(data['to'])}'));

  sheet('Sales', const [
    ('Bill', 'invoice_no', _Kind.text),
    ('Date', 'date', _Kind.dateTime),
    ('Type', 'type', _Kind.text),
    ('Status', 'status', _Kind.text),
    ('Customer', 'customer', _Kind.text),
    ('Phone', 'phone', _Kind.text),
    ('Bill total', 'bill', _Kind.money),
    ('Less', 'discount', _Kind.money),
    ('Reason for less', 'discount_reason', _Kind.text),
    ('Received', 'received', _Kind.money),
    ('Payment', 'method', _Kind.text),
    ('Cost', 'cost', _Kind.money),
    ('Void reason', 'void_reason', _Kind.text),
  ], (data['sales'] as List?) ?? const []);

  sheet('Sale items', const [
    ('Bill', 'invoice_no', _Kind.text),
    ('Date', 'date', _Kind.dateTime),
    ('Status', 'status', _Kind.text),
    ('Code', 'code', _Kind.text),
    ('Product', 'name', _Kind.text),
    ('Qty', 'qty', _Kind.count),
    ('List price', 'list_price', _Kind.money),
    ('Price', 'price', _Kind.money),
    ('Line total', 'line_total', _Kind.money),
    ('Discount share', 'discount_share', _Kind.money),
    ('Net', 'net', _Kind.money),
    ('Cost', 'cost', _Kind.money),
  ], (data['sale_items'] as List?) ?? const []);

  sheet('Returns', const [
    ('Return', 'return_no', _Kind.text),
    ('Date', 'date', _Kind.dateTime),
    ('Bill', 'invoice_no', _Kind.text),
    ('Customer', 'customer', _Kind.text),
    ('Code', 'code', _Kind.text),
    ('Product', 'name', _Kind.text),
    ('Qty', 'qty', _Kind.count),
    ('Money back', 'refund', _Kind.money),
    ('Condition', 'condition', _Kind.text),
    ('Paid by', 'method', _Kind.text),
    ('Reason', 'reason', _Kind.text),
  ], (data['returns'] as List?) ?? const []);

  sheet('Purchases', const [
    ('Purchase', 'purchase_no', _Kind.text),
    ('Date', 'date', _Kind.dateTime),
    ('Supplier', 'supplier', _Kind.text),
    ('Supplier bill', 'supplier_ref', _Kind.text),
    ('Code', 'code', _Kind.text),
    ('Product', 'name', _Kind.text),
    ('Qty', 'qty', _Kind.count),
    ('Rate', 'rate', _Kind.money),
    ('Discount', 'discount', _Kind.money),
    ('Extra cost', 'extra', _Kind.money),
    ('Total', 'total', _Kind.money),
    ('Cost per piece', 'unit_cost', _Kind.money),
  ], (data['purchases'] as List?) ?? const []);

  sheet('Expenses', const [
    ('Date', 'date', _Kind.date),
    ('Category', 'category', _Kind.text),
    ('Amount', 'amount', _Kind.money),
    ('Note', 'note', _Kind.text),
    ('From galla', 'from_cash', _Kind.yesNo),
  ], (data['expenses'] as List?) ?? const []);

  sheet('Stock fixes', const [
    ('Date', 'date', _Kind.dateTime),
    ('Code', 'code', _Kind.text),
    ('Product', 'name', _Kind.text),
    ('Pieces +/-', 'qty_change', _Kind.count),
    ('What happened', 'kind', _Kind.text),
    ('Note', 'note', _Kind.text),
    ('Value change', 'value_change', _Kind.money),
  ], (data['adjustments'] as List?) ?? const []);

  sheet('Day closings', const [
    ('Date', 'closing_date', _Kind.date),
    ('Start cash', 'opening_cash', _Kind.money),
    ('Cash sales', 'cash_sales', _Kind.money),
    ('Cash returns', 'cash_refunds', _Kind.money),
    ('Cash expenses', 'cash_expenses', _Kind.money),
    ('Taken out', 'cash_out', _Kind.money),
    ('Should be', 'expected_cash', _Kind.money),
    ('Counted', 'counted_cash', _Kind.money),
    ('Difference', 'difference', _Kind.money),
    ('Note', 'note', _Kind.text),
  ], (data['closings'] as List?) ?? const []);

  sheet('Stock now', const [
    ('Code', 'code', _Kind.text),
    ('Product', 'name', _Kind.text),
    ('Brand', 'brand', _Kind.text),
    ('Active', 'active', _Kind.yesNo),
    ('Qty', 'qty', _Kind.count),
    ('Damaged', 'damaged', _Kind.count),
    ('Average cost', 'avg_cost', _Kind.money),
    ('Stock value', 'stock_value', _Kind.money),
    ('Wholesale', 'wholesale', _Kind.money),
    ('Retail', 'retail', _Kind.money),
  ], (data['stock'] as List?) ?? const []);

  sheet('Shopkeepers', const [
    ('Name', 'name', _Kind.text),
    ('Phone', 'phone', _Kind.text),
    ('Address', 'address', _Kind.text),
    ('Type', 'customer_type', _Kind.text),
    ('Bills', 'bills', _Kind.count),
    ('Total bought', 'total_amount', _Kind.money),
    ('Returns', 'returns_amount', _Kind.money),
    ('Last bill', 'last_sale_at', _Kind.date),
    ('Profit', 'profit', _Kind.money),
  ], (data['customers'] as List?) ?? const []);

  book.setDefaultSheet('Summary');
  if (defaultSheet != 'Summary') book.delete(defaultSheet);
  final bytes = book.encode();
  if (bytes == null) throw StateError('Could not create the Excel file');
  return Uint8List.fromList(bytes);
}

enum _Range { thisMonth, lastMonth, thisYear, all }

/// Owner: download everything for a period as one Excel file (backup).
class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  _Range _range = _Range.thisMonth;
  bool _busy = false;

  (DateTime, DateTime, String) get _period {
    final t = BizTime.today();
    return switch (_range) {
      _Range.thisMonth => (DateTime(t.year, t.month, 1), t, 'This month'),
      _Range.lastMonth => (DateTime(t.year, t.month - 1, 1), DateTime(t.year, t.month, 0), 'Last month'),
      _Range.thisYear => (DateTime(t.year, 1, 1), t, 'This year'),
      _Range.all => (DateTime(2000, 1, 1), t, 'Everything'),
    };
  }

  Future<void> _export() async {
    final (from, to, _) = _period;
    setState(() => _busy = true);
    try {
      final data = await ref.read(reportsRepositoryProvider).export(from, to);
      final bytes = buildExportWorkbook(data);
      final name = 'Accessories-Sahiwal_${BizTime.isoDate(from)}_to_${BizTime.isoDate(to)}.xlsx';
      await shareFile(bytes,
          fileName: name, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      if (mounted) context.showSuccess('Excel file ready: $name');
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (from, to, label) = _period;
    return Scaffold(
      appBar: AppBar(title: const Text('Excel backup')),
      body: ListView(
        children: [
          PageBody(
            maxWidth: 640,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card3D(
                  maxAngle: 0.05,
                  padding: const EdgeInsets.all(18),
                  colors: AppTheme.heroColors,
                  child: const Row(
                    children: [
                      Icon(Icons.table_view_outlined, color: Colors.white, size: 40),
                      SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          'Download your sales, stock, purchases, returns, expenses and day closings as one Excel file. '
                          'Keep a copy every week (Google Drive / email).',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (r, t) in const [
                    (_Range.thisMonth, 'This month'),
                    (_Range.lastMonth, 'Last month'),
                    (_Range.thisYear, 'This year'),
                    (_Range.all, 'Everything'),
                  ])
                    ChoiceChip(label: Text(t), selected: _range == r, onSelected: (_) => setState(() => _range = r)),
                ]),
                const SizedBox(height: 8),
                Text(_range == _Range.all ? 'All data up to ${BizTime.date(to)}' : '$label: ${BizTime.date(from)} – ${BizTime.date(to)}',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _export,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download_outlined),
                  label: const Text('Download Excel file'),
                ),
                const SizedBox(height: 12),
                Text(
                  'On the phone a menu opens: choose "Save to Files", Google Drive or WhatsApp. '
                  'In the browser the file goes to Downloads. The file has cost and profit, so keep it private.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
