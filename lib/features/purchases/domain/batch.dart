import 'package:decimal/decimal.dart';

import '../../../core/utils/money.dart';

class Batch {
  const Batch({
    required this.id,
    required this.productId,
    required this.purchaseId,
    required this.quantity,
    required this.remainingQuantity,
    required this.unitCost,
    required this.postedAt,
  });

  final String id;
  final String productId;
  final String? purchaseId;
  final int quantity;
  final int remainingQuantity;
  final Decimal unitCost;
  final DateTime postedAt;

  factory Batch.fromJson(Map<String, dynamic> j) => Batch(
    id: j['id'] as String,
    productId: j['product_id'] as String,
    purchaseId: j['purchase_id'] as String?,
    quantity: (j['quantity'] as num).toInt(),
    remainingQuantity: (j['remaining_quantity'] as num).toInt(),
    unitCost: Money.parse(j['unit_cost']),
    postedAt: DateTime.parse(j['posted_at'] as String),
  );
}
