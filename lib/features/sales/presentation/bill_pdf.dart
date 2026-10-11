import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../settings/data/settings_repository.dart';
import '../domain/sale.dart';

const _navy = PdfColor.fromInt(0xFF0B1F3F);
const _gold = PdfColor.fromInt(0xFFB08D3C);

/// A clean A5 PDF bill with the shop logo (for WhatsApp or printing).
Future<Uint8List> buildBillPdf(Sale s, BusinessSettings b, {List<SaleReturn> returns = const []}) async {
  pw.MemoryImage? logo;
  try {
    final data = await rootBundle.load('assets/logo.png');
    logo = pw.MemoryImage(data.buffer.asUint8List());
  } catch (_) {/* no logo: text header only */}

  final logoImg = logo;
  final doc = pw.Document(title: '${s.invoiceNo} - ${b.businessName}', author: b.businessName);
  final small = const pw.TextStyle(fontSize: 8, color: PdfColors.grey700);
  final bold = pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold);
  final refunded = returns.fold(Money.zero, (a, r) => a + r.refund);

  pw.Widget row(String label, String value, {bool strong = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(children: [
          pw.Expanded(child: pw.Text(label, style: strong ? bold : const pw.TextStyle(fontSize: 9))),
          pw.Text(value, style: strong ? bold : const pw.TextStyle(fontSize: 9)),
        ]),
      );

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a5,
      margin: const pw.EdgeInsets.all(24),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(children: [
            if (logoImg != null) pw.Container(width: 44, height: 44, child: pw.Image(logoImg)),
            if (logoImg != null) pw.SizedBox(width: 10),
            pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text(b.businessName, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _navy)),
                if (b.address.isNotEmpty || b.phone.isNotEmpty)
                  pw.Text([b.address, b.phone].where((e) => e.isNotEmpty).join('  ·  '), style: small),
              ]),
            ),
          ]),
          pw.SizedBox(height: 8),
          pw.Container(height: 2, color: _gold),
          pw.SizedBox(height: 8),
          pw.Row(children: [
            pw.Expanded(child: pw.Text('${s.type.label} bill ${s.invoiceNo}', style: bold)),
            pw.Text(BizTime.dateTime(s.completedAt), style: small),
          ]),
          if (s.customerName.isNotEmpty)
            pw.Text('Customer: ${s.customerName}${s.customerPhone.isNotEmpty ? '  ·  ${s.customerPhone}' : ''}',
                style: const pw.TextStyle(fontSize: 9)),
          if (s.isVoided) pw.Text('VOIDED', style: pw.TextStyle(color: PdfColors.red, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: ['Item', 'Qty', 'Rate', 'Amount'],
            data: [
              for (final l in s.lines)
                [
                  '${l.productName}\n${l.productCode}${l.warrantyText.isNotEmpty ? ' · Warranty ${l.warrantyText}' : ''}',
                  '${l.quantity}',
                  Money.format(l.unitPrice, withSymbol: false),
                  Money.format(l.lineTotal, withSymbol: false),
                ],
            ],
            headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: _navy),
            cellStyle: const pw.TextStyle(fontSize: 8.5),
            cellAlignments: {
              0: pw.Alignment.centerLeft,
              1: pw.Alignment.center,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
            },
            columnWidths: {
              0: const pw.FlexColumnWidth(5),
              1: const pw.FlexColumnWidth(1),
              2: const pw.FlexColumnWidth(2),
              3: const pw.FlexColumnWidth(2.2),
            },
            oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
          ),
          pw.SizedBox(height: 10),
          row('Bill total', Money.format(s.subtotal)),
          if (s.discount.signum > 0)
            row('Less${s.discountReason.isNotEmpty ? ' (${s.discountReason})' : ''}', '- ${Money.format(s.discount)}'),
          row('Amount received', Money.format(s.total), strong: true),
          row('Payment', s.method.label),
          if (s.change.signum > 0) row('Change given', Money.format(s.change)),
          if (returns.isNotEmpty) ...[
            pw.SizedBox(height: 6),
            for (final r in returns)
              row('Return ${r.returnNo} (${r.items.fold(0, (a, i) => a + i.quantity)} pcs)', '- ${Money.format(r.refund)}'),
            row('Net after returns', Money.format(s.total - refunded), strong: true),
          ],
          pw.Spacer(),
          if (b.receiptFooter.isNotEmpty)
            pw.Text(b.receiptFooter, textAlign: pw.TextAlign.center, style: small),
          pw.SizedBox(height: 4),
          pw.Text('Thank you!', textAlign: pw.TextAlign.center,
              style: pw.TextStyle(fontSize: 10, color: _navy, fontWeight: pw.FontWeight.bold)),
        ],
      ),
    ),
  );
  return doc.save();
}

/// Share the PDF (WhatsApp, Files …) or download it in the browser.
Future<void> shareBillPdf(Sale s, BusinessSettings b, {List<SaleReturn> returns = const []}) async {
  final bytes = await buildBillPdf(s, b, returns: returns);
  await Printing.sharePdf(bytes: bytes, filename: '${s.invoiceNo}.pdf');
}

/// Open the print dialog.
Future<void> printBillPdf(Sale s, BusinessSettings b, {List<SaleReturn> returns = const []}) async {
  await Printing.layoutPdf(
    name: s.invoiceNo,
    format: PdfPageFormat.a5,
    onLayout: (_) => buildBillPdf(s, b, returns: returns),
  );
}
