 import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/money.dart';
import '../../private_area/data/private_guard.dart';
import '../../purchases/domain/batch.dart';

/// Quantities only — safe for partners. No cost fields exist in these results.
class StockItem {
  const StockItem({
    required this.productId,
    required this.code,
    required this.name,
    required this.categoryName,
    required this.brand,
    required this.saleableQty,
    required this.nonSaleableQty,
    required this.reorderThreshold,
    required this.isLow,
    required this.isActive,
  });

  final String productId;
  final String code;
  final String name;
  final String? categoryName;
  final String brand;
  final int saleableQty;
  final int nonSaleableQty;
  final int reorderThreshold;
  final bool isLow;
  final bool isActive;

  factory StockItem.fromJson(Map<String, dynamic> j) => StockItem(
        productId: j['product_id'] as String,
        code: j['code'] as String,
        name: j['name'] as String,
        categoryName: j['category_name'] as String?,
        brand: (j['brand'] as String?) ?? '',
        saleableQty: (j['saleable_qty'] as num).toInt(),
        nonSaleableQty: (j['non_saleable_qty'] as num).toInt(),
        reorderThreshold: (j['reorder_threshold'] as num).toInt(),
        isLow: j['is_low'] == true,
        isActive: j['is_active'] != false,
      );
}

class StockMovement {
  const StockMovement({required this.postedAt, required this.type, required this.bucket, required this.quantity, required this.qtyAfter});
  final DateTime postedAt;
  final String type;
  final String bucket;
  final int quantity;
  final int qtyAfter;

  String get typeLabel => switch (type) {
        'opening' => 'Opening stock',
        'purchase' => 'Purchase',
        'sale' => 'Sale',
        'sale_return' => 'Customer return',
        'sale_void' => 'Sale voided',
        'purchase_return' => 'Returned to supplier',
        'adjustment_in' => 'Adjustment (+)',
        'adjustment_out' => 'Adjustment (−)',
        'damage' => 'Damaged / lost',
        _ => type,
      };

  factory StockMovement.fromJson(Map<String, dynamic> j) => StockMovement(
        postedAt: DateTime.parse(j['posted_at'] as String),
        type: j['movement_type'] as String,
        bucket: j['bucket'] as String,
        quantity: (j['quantity'] as num).toInt(),
        qtyAfter: (j['qty_after'] as num).toInt(),
      );
}

class StockRepository {
  StockRepository(this._ref, this._db);
  final Ref _ref;
  final SupabaseClient _db;

  Future<List<StockItem>> list({String? search, String? categoryId, bool lowOnly = false}) async {
    try {
      final rows = await _db.rpc('stock_list', params: {
        'p_search': (search ?? '').trim().isEmpty ? null : search!.trim(),
        'p_category_id': categoryId,
        'p_low_only': lowOnly,
        'p_include_inactive': false,
      });
      return (rows as List).map((e) => StockItem.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (e) {
      throw AppException.from(e);
    }
  }

  Future<List<StockMovement>> history(String productId) async {
    try {
      final rows = await _db.rpc('stock_movement_history', params: {'p_product_id': productId, 'p_limit': 100});
      return (rows as List).map((e) => StockMovement.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (e) {
      throw AppException.from(e);
    }
  }

  Future<List<FifoStockValue>> fifoValues(String search) => guardedPrivate(_ref, () async {
        final rows = await _db.rpc('owner_fifo_stock_values', params: {
          'p_search': search.trim().isEmpty ? null : search.trim(),
        });
        return (rows as List)
            .map((e) => FifoStockValue.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      });

  Future<List<Batch>> batches(String productId) => guardedPrivate(_ref, () async {
        final rows = await _db.rpc('owner_product_batches', params: {'p_product_id': productId});
        return (rows as List).map((e) => Batch.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      });
}

class FifoStockValue {
  const FifoStockValue({required this.productId, required this.remainingQuantity, required this.stockValue});

  final String productId;
  final int remainingQuantity;
  final Decimal stockValue;

  factory FifoStockValue.fromJson(Map<String, dynamic> json) => FifoStockValue(
        productId: json['product_id'] as String,
        remainingQuantity: (json['remaining_quantity'] as num).toInt(),
        stockValue: Money.parse(json['stock_value']),
      );
}

final stockRepositoryProvider = Provider<StockRepository>(
  (ref) => StockRepository(ref, ref.watch(supabaseProvider)),
);

class StockQuery {
  const StockQuery({this.search = '', this.categoryId, this.lowOnly = false});
  final String search;
  final String? categoryId;
  final bool lowOnly;

  @override
  bool operator ==(Object other) =>
      other is StockQuery && other.search == search && other.categoryId == categoryId && other.lowOnly == lowOnly;

  @override
  int get hashCode => Object.hash(search, categoryId, lowOnly);
}

final stockListProvider = FutureProvider.autoDispose.family<List<StockItem>, StockQuery>(
  (ref, q) => ref.watch(stockRepositoryProvider).list(search: q.search, categoryId: q.categoryId, lowOnly: q.lowOnly),
);

final stockHistoryProvider = FutureProvider.autoDispose.family<List<StockMovement>, String>(
  (ref, productId) => ref.watch(stockRepositoryProvider).history(productId),
);

final fifoStockValuesProvider = FutureProvider.autoDispose.family<List<FifoStockValue>, String>(
  (ref, search) => ref.watch(stockRepositoryProvider).fifoValues(search),
);

final productBatchesProvider = FutureProvider.autoDispose.family<List<Batch>, String>(
  (ref, productId) => ref.watch(stockRepositoryProvider).batches(productId),
);
