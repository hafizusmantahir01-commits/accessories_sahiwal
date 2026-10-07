import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/money.dart';
import '../../private_area/data/private_guard.dart';

class ValuationRow {
  const ValuationRow({
    required this.productId,
    required this.code,
    required this.name,
    required this.qty,
    required this.averageCost,
    required this.carryingValue,
    required this.retailPrice,
  });

  final String productId;
  final String code;
  final String name;
  final int qty;
  final Decimal averageCost;
  final Decimal carryingValue;
  final Decimal retailPrice;

  factory ValuationRow.fromJson(Map<String, dynamic> j) => ValuationRow(
        productId: j['product_id'] as String,
        code: j['code'] as String,
        name: j['name'] as String,
        qty: (j['saleable_qty'] as num).toInt(),
        averageCost: Money.parse(j['average_cost']),
        carryingValue: Money.parse(j['carrying_value']),
        retailPrice: Money.parse(j['retail_price']),
      );
}

class ReconcileRow {
  const ReconcileRow({required this.code, required this.ok});
  final String code;
  final bool ok;
}

/// Owner-only (server requires owner + unlocked private area).
final valuationProvider = FutureProvider.autoDispose<List<ValuationRow>>((ref) {
  final db = ref.watch(supabaseProvider);
  return guardedPrivate(ref, () async {
    final rows = await db.rpc('owner_stock_valuation');
    return (rows as List).map((e) => ValuationRow.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  });
});

final reconcileProvider = FutureProvider.autoDispose<List<ReconcileRow>>((ref) {
  final db = ref.watch(supabaseProvider);
  return guardedPrivate(ref, () async {
    final rows = await db.rpc('owner_reconcile_inventory');
    return (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map((m) => ReconcileRow(code: m['code'] as String, ok: m['ok'] == true))
        .toList();
  });
});
