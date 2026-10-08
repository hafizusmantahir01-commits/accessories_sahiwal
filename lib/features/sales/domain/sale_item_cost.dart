import 'package:decimal/decimal.dart';

import '../../../core/utils/money.dart';

class SaleItemCost {
  const SaleItemCost({
    required this.id,
    required this.saleItemId,
    required this.batchId,
    required this.quantity,
    required this.costPrice,
  });

  final String id;
  final String saleItemId;
  final String batchId;
  final int quantity;
  final Decimal costPrice;

  factory SaleItemCost.fromJson(Map<String, dynamic> j) => SaleItemCost(
    id: j['id'] as String,
    saleItemId: j['sale_item_id'] as String,
    batchId: j['batch_id'] as String,
    quantity: (j['quantity'] as num).toInt(),
    costPrice: Money.parse(j['cost_price']),
  );
}
