import 'package:decimal/decimal.dart';

import '../../../core/utils/money.dart';

enum PaymentMethod {
  cash('cash', 'Cash'),
  bankTransfer('bank_transfer', 'Bank transfer'),
  jazzcash('jazzcash', 'JazzCash'),
  easypaisa('easypaisa', 'Easypaisa');

  const PaymentMethod(this.value, this.label);
  final String value;
  final String label;

  static PaymentMethod parse(Object? v) =>
      PaymentMethod.values.firstWhere((m) => m.value == v, orElse: () => PaymentMethod.cash);
}

class PurchaseSummary {
  const PurchaseSummary({
    required this.id,
    required this.purchaseNo,
    required this.isDraft,
    required this.supplierName,
    required this.supplierRef,
    required this.documentDate,
    required this.total,
    required this.paymentMethod,
    required this.itemCount,
    required this.postedAt,
    required this.createdAt,
  });

  final String id;
  final String? purchaseNo;
  final bool isDraft;
  final String supplierName;
  final String supplierRef;
  final String documentDate;
  final Decimal total;
  final PaymentMethod paymentMethod;
  final int itemCount;
  final DateTime? postedAt;
  final DateTime createdAt;

  factory PurchaseSummary.fromJson(Map<String, dynamic> j) => PurchaseSummary(
        id: j['id'] as String,
        purchaseNo: j['purchase_no'] as String?,
        isDraft: j['status'] == 'draft',
        supplierName: j['supplier_name'] as String,
        supplierRef: (j['supplier_ref'] as String?) ?? '',
        documentDate: j['document_date'] as String,
        total: Money.parse(j['total']),
        paymentMethod: PaymentMethod.parse(j['payment_method']),
        itemCount: (j['item_count'] as num).toInt(),
        postedAt: j['posted_at'] == null ? null : DateTime.parse(j['posted_at'] as String),
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}

class PurchaseLine {
  const PurchaseLine({
    required this.lineNo,
    required this.productId,
    required this.productCode,
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    required this.lineDiscount,
    required this.merchandiseValue,
    required this.allocatedExtra,
    required this.landedValue,
    required this.landedUnitCost,
  });

  final int lineNo;
  final String productId;
  final String productCode;
  final String productName;
  final int quantity;
  final Decimal unitPrice;
  final Decimal lineDiscount;
  final Decimal merchandiseValue;
  final Decimal allocatedExtra;
  final Decimal landedValue;
  final Decimal landedUnitCost;

  factory PurchaseLine.fromJson(Map<String, dynamic> j) => PurchaseLine(
        lineNo: (j['line_no'] as num).toInt(),
        productId: j['product_id'] as String,
        productCode: j['product_code'] as String,
        productName: j['product_name'] as String,
        quantity: (j['quantity'] as num).toInt(),
        unitPrice: Money.parse(j['unit_price']),
        lineDiscount: Money.parse(j['line_discount']),
        merchandiseValue: Money.parse(j['merchandise_value']),
        allocatedExtra: Money.parse(j['allocated_extra']),
        landedValue: Money.parse(j['landed_value']),
        landedUnitCost: Money.parse(j['landed_unit_cost']),
      );
}

class Purchase {
  const Purchase({
    required this.id,
    required this.purchaseNo,
    required this.isDraft,
    required this.supplierId,
    required this.supplierName,
    required this.documentDate,
    required this.supplierRef,
    required this.merchandiseTotal,
    required this.extraCosts,
    required this.extraCostsNote,
    required this.total,
    required this.paymentMethod,
    required this.notes,
    required this.postedAt,
    required this.paymentReference,
    required this.lines,
  });

  final String id;
  final String? purchaseNo;
  final bool isDraft;
  final String supplierId;
  final String supplierName;
  final String documentDate;
  final String supplierRef;
  final Decimal merchandiseTotal;
  final Decimal extraCosts;
  final String extraCostsNote;
  final Decimal total;
  final PaymentMethod paymentMethod;
  final String notes;
  final DateTime? postedAt;
  final String? paymentReference;
  final List<PurchaseLine> lines;

  factory Purchase.fromJson(Map<String, dynamic> j) {
    final supplier = Map<String, dynamic>.from(j['supplier'] as Map);
    final payment = j['payment'] == null ? null : Map<String, dynamic>.from(j['payment'] as Map);
    return Purchase(
      id: j['id'] as String,
      purchaseNo: j['purchase_no'] as String?,
      isDraft: j['status'] == 'draft',
      supplierId: supplier['id'] as String,
      supplierName: supplier['name'] as String,
      documentDate: j['document_date'] as String,
      supplierRef: (j['supplier_ref'] as String?) ?? '',
      merchandiseTotal: Money.parse(j['merchandise_total']),
      extraCosts: Money.parse(j['extra_costs']),
      extraCostsNote: (j['extra_costs_note'] as String?) ?? '',
      total: Money.parse(j['total']),
      paymentMethod: PaymentMethod.parse(j['payment_method']),
      notes: (j['notes'] as String?) ?? '',
      postedAt: j['posted_at'] == null ? null : DateTime.parse(j['posted_at'] as String),
      paymentReference: payment?['reference'] as String?,
      lines: (j['items'] as List).map((e) => PurchaseLine.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
    );
  }
}

/// Editable line in the purchase editor (client-side preview only).
class DraftLine {
  DraftLine({
    required this.productId,
    required this.productCode,
    required this.productName,
    this.quantity = 1,
    Decimal? unitPrice,
    Decimal? lineDiscount,
  })  : unitPrice = unitPrice ?? Decimal.zero,
        lineDiscount = lineDiscount ?? Decimal.zero;

  final String productId;
  final String productCode;
  final String productName;
  int quantity;
  Decimal unitPrice;
  Decimal lineDiscount;

  Decimal get gross => Decimal.fromInt(quantity) * unitPrice;
  Decimal get net => gross - lineDiscount;
  bool get discountValid => lineDiscount >= Decimal.zero && lineDiscount <= gross;

  Map<String, dynamic> toJson() => {
        'product_id': productId,
        'quantity': quantity,
        'unit_price': unitPrice.toString(),
        'line_discount': lineDiscount.toString(),
      };
}

/// Client preview of purchase totals (the server recalculates authoritatively).
class PurchasePreview {
  PurchasePreview(this.lines, this.extraCosts);
  final List<DraftLine> lines;
  final Decimal extraCosts;

  Decimal get merchandise => lines.fold(Decimal.zero, (a, l) => a + l.net);
  Decimal get total => merchandise + extraCosts;
}
