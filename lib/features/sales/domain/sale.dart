import 'package:decimal/decimal.dart';

import '../../../core/utils/money.dart';
import '../../purchases/domain/purchase.dart' show PaymentMethod;

export '../../purchases/domain/purchase.dart' show PaymentMethod;

enum SaleType {
  wholesale('wholesale', 'Wholesale'),
  retail('retail', 'Retail');

  const SaleType(this.value, this.label);
  final String value;
  final String label;

  static SaleType parse(Object? v) => v == 'wholesale' ? SaleType.wholesale : SaleType.retail;
}

class Customer {
  const Customer({required this.id, required this.name, required this.phone, required this.isShopkeeper});
  final String id;
  final String name;
  final String phone;
  final bool isShopkeeper;

  factory Customer.fromJson(Map<String, dynamic> j) => Customer(
        id: j['id'] as String,
        name: j['name'] as String,
        phone: (j['phone'] as String?) ?? '',
        isShopkeeper: j['customer_type'] == 'shopkeeper',
      );

  @override
  String toString() => phone.isEmpty ? name : '$name · $phone';
}

class SaleLine {
  const SaleLine({
    this.id = '',
    this.productId = '',
    required this.lineNo,
    required this.productCode,
    required this.productName,
    required this.quantity,
    required this.listPrice,
    required this.unitPrice,
    required this.lineTotal,
    required this.discountShare,
    required this.netTotal,
    required this.warrantyNote,
    required this.warrantyDays,
  });

  /// sale_items.id (used for returns).
  final String id;
  final String productId;
  final int lineNo;
  final String productCode;
  final String productName;
  final int quantity;
  final Decimal listPrice;
  final Decimal unitPrice;
  final Decimal lineTotal;
  final Decimal discountShare;
  final Decimal netTotal;
  final String warrantyNote;
  final int warrantyDays;

  String get warrantyText =>
      [if (warrantyDays > 0) '$warrantyDays days', if (warrantyNote.isNotEmpty) warrantyNote].join(' · ');

  factory SaleLine.fromJson(Map<String, dynamic> j) => SaleLine(
        id: (j['id'] as String?) ?? '',
        productId: (j['product_id'] as String?) ?? '',
        lineNo: (j['line_no'] as num).toInt(),
        productCode: j['product_code'] as String,
        productName: j['product_name'] as String,
        quantity: (j['quantity'] as num).toInt(),
        listPrice: Money.parse(j['list_price']),
        unitPrice: Money.parse(j['unit_price']),
        lineTotal: Money.parse(j['line_total']),
        discountShare: Money.parse(j['discount_share']),
        netTotal: Money.parse(j['net_total']),
        warrantyNote: (j['warranty_note'] as String?) ?? '',
        warrantyDays: (j['warranty_days'] as num?)?.toInt() ?? 0,
      );
}

/// A completed (or voided) sale. Contains selling data only — never cost.
class Sale {
  const Sale({
    required this.id,
    this.customerId,
    required this.invoiceNo,
    required this.type,
    required this.isVoided,
    required this.customerName,
    required this.customerPhone,
    required this.subtotal,
    required this.discount,
    required this.discountReason,
    required this.total,
    required this.method,
    required this.tendered,
    required this.change,
    required this.reference,
    required this.notes,
    required this.completedAt,
    required this.voidReason,
    required this.lines,
  });

  final String id;
  final String? customerId;
  final String invoiceNo;
  final SaleType type;
  final bool isVoided;
  final String customerName;
  final String customerPhone;
  final Decimal subtotal;
  final Decimal discount;
  final String discountReason;
  final Decimal total;
  final PaymentMethod method;
  final Decimal tendered;
  final Decimal change;
  final String reference;
  final String notes;
  final DateTime completedAt;
  final String? voidReason;
  final List<SaleLine> lines;

  int get itemCount => lines.fold(0, (a, l) => a + l.quantity);

  factory Sale.fromJson(Map<String, dynamic> j) {
    final lines = (j['items'] as List? ?? const [])
        .map((e) => SaleLine.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList()
      ..sort((a, b) => a.lineNo.compareTo(b.lineNo));
    return Sale(
      id: j['id'] as String,
      customerId: j['customer_id'] as String?,
      invoiceNo: j['invoice_no'] as String,
      type: SaleType.parse(j['sale_type']),
      isVoided: j['status'] == 'voided',
      customerName: (j['customer_name'] as String?) ?? '',
      customerPhone: (j['customer_phone'] as String?) ?? '',
      subtotal: Money.parse(j['subtotal']),
      discount: Money.parse(j['discount_amount']),
      discountReason: (j['discount_reason'] as String?) ?? '',
      total: Money.parse(j['total']),
      method: PaymentMethod.parse(j['payment_method']),
      tendered: Money.parse(j['amount_tendered']),
      change: Money.parse(j['change_given']),
      reference: (j['payment_reference'] as String?) ?? '',
      notes: (j['notes'] as String?) ?? '',
      completedAt: DateTime.parse(j['completed_at'] as String),
      voidReason: j['void_reason'] as String?,
      lines: lines,
    );
  }
}

/// A line in the sale being prepared (client-side; server re-checks everything).
class CartLine {
  CartLine({
    required this.productId,
    required this.code,
    required this.name,
    required this.available,
    required this.defaultPrice,
    required this.quantity,
    Decimal? unitPrice,
  }) : unitPrice = unitPrice ?? defaultPrice;

  final String productId;
  final String code;
  final String name;
  final int available;
  final Decimal defaultPrice;
  int quantity;
  Decimal unitPrice;

  Decimal get total => Decimal.fromInt(quantity) * unitPrice;
  bool get overStock => quantity > available;
  bool get priceChanged => unitPrice != defaultPrice;
}

class SalesSummary {
  SalesSummary({required this.count, this.pieces = 0, required this.netSales, required this.discounts, required this.wholesale, required this.retail, Decimal? returns, this.returnsCount = 0})
      : returns = returns ?? Decimal.zero;
  final int count;
  final int pieces;

  /// Money refunded for returned items in this period.
  final Decimal returns;
  final int returnsCount;
  final Decimal netSales;
  final Decimal discounts;
  final Decimal wholesale;
  final Decimal retail;

  factory SalesSummary.fromJson(Map<String, dynamic> j) => SalesSummary(
        count: (j['count'] as num?)?.toInt() ?? 0,
        pieces: (j['pieces'] as num?)?.toInt() ?? 0,
        returns: Money.parse(j['returns']),
        returnsCount: (j['returns_count'] as num?)?.toInt() ?? 0,
        netSales: Money.parse(j['net_sales']),
        discounts: Money.parse(j['discounts']),
        wholesale: Money.parse(j['wholesale']),
        retail: Money.parse(j['retail']),
      );
}

/// Owner report: one month of sales and profit.
class MonthProfit {
  const MonthProfit({required this.month, required this.bills, required this.pieces, required this.netSales, required this.cogs, required this.profit, required this.returns, required this.stockLoss, required this.expenses, required this.netProfit});
  final DateTime month;
  final int bills;
  final int pieces;
  final Decimal netSales;
  final Decimal cogs;

  /// Profit on goods (sales − returns − cost).
  final Decimal profit;
  final Decimal returns;
  final Decimal stockLoss;
  final Decimal expenses;

  /// Profit after stock loss and expenses.
  final Decimal netProfit;

  factory MonthProfit.fromJson(Map<String, dynamic> j) => MonthProfit(
        month: DateTime.parse(j['month'] as String),
        bills: (j['bills'] as num?)?.toInt() ?? 0,
        pieces: (j['pieces'] as num?)?.toInt() ?? 0,
        netSales: Money.parse(j['net_sales']),
        cogs: Money.parse(j['cogs']),
        profit: Money.parse(j['profit']),
        returns: Money.parse(j['returns']),
        stockLoss: Money.parse(j['stock_loss']),
        expenses: Money.parse(j['expenses']),
        netProfit: Money.parse(j['net_profit']),
      );
}

/// Owner report: how much of one product was sold and the profit on it.
class ProductProfit {
  const ProductProfit({required this.productId, required this.code, required this.name, required this.pieces, required this.netSales, required this.cogs, required this.profit});
  final String productId;
  final String code;
  final String name;
  final int pieces;
  final Decimal netSales;
  final Decimal cogs;
  final Decimal profit;

  factory ProductProfit.fromJson(Map<String, dynamic> j) => ProductProfit(
        productId: j['product_id'] as String,
        code: (j['code'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        pieces: (j['pieces'] as num?)?.toInt() ?? 0,
        netSales: Money.parse(j['net_sales']),
        cogs: Money.parse(j['cogs']),
        profit: Money.parse(j['profit']),
      );
}

/// Items a customer brought back (part of a bill).
class SaleReturn {
  const SaleReturn({
    required this.id,
    required this.returnNo,
    required this.refund,
    required this.method,
    required this.reason,
    required this.createdAt,
    required this.items,
  });

  final String id;
  final String returnNo;
  final Decimal refund;
  final PaymentMethod method;
  final String reason;
  final DateTime createdAt;
  final List<SaleReturnLine> items;

  factory SaleReturn.fromJson(Map<String, dynamic> j) => SaleReturn(
        id: j['id'] as String,
        returnNo: j['return_no'] as String,
        refund: Money.parse(j['refund_amount']),
        method: PaymentMethod.parse(j['refund_method']),
        reason: (j['reason'] as String?) ?? '',
        createdAt: DateTime.parse(j['created_at'] as String),
        items: (j['items'] as List? ?? const [])
            .map((e) => SaleReturnLine.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

class SaleReturnLine {
  const SaleReturnLine({
    required this.saleItemId,
    required this.productCode,
    required this.productName,
    required this.quantity,
    required this.refund,
    required this.damaged,
  });

  final String saleItemId;
  final String productCode;
  final String productName;
  final int quantity;
  final Decimal refund;
  final bool damaged;

  factory SaleReturnLine.fromJson(Map<String, dynamic> j) => SaleReturnLine(
        saleItemId: j['sale_item_id'] as String,
        productCode: (j['product_code'] as String?) ?? '',
        productName: (j['product_name'] as String?) ?? '',
        quantity: (j['quantity'] as num).toInt(),
        refund: Money.parse(j['refund_amount']),
        damaged: j['condition'] == 'damaged',
      );
}
