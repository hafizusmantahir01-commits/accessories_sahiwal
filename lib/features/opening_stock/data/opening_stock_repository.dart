import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/money.dart';
import '../../private_area/data/private_guard.dart';

class OpeningEntry {
  const OpeningEntry({
    required this.id,
    required this.productId,
    required this.productLabel,
    required this.quantity,
    required this.unitCost,
    required this.totalValue,
    required this.note,
    required this.createdAt,
  });

  final String id;
  final String productId;
  final String productLabel;
  final int quantity;
  final Decimal unitCost;
  final Decimal totalValue;
  final String note;
  final DateTime createdAt;
}

class OpeningStockRepository {
  OpeningStockRepository(this._ref, this._db);
  final Ref _ref;
  final SupabaseClient _db;

  /// Posts existing inventory with its actual unit cost. Creates an auditable
  /// opening movement — NOT a payment or expense.
  Future<String> post({
    required String productId,
    required int quantity,
    required Decimal unitCost,
    required String idempotencyKey,
    String note = '',
  }) =>
      guardedPrivate(_ref, () async {
        final res = await _db.rpc('owner_post_opening_stock', params: {
          'p_product_id': productId,
          'p_quantity': quantity,
          'p_unit_cost': unitCost.toString(),
          'p_idempotency_key': idempotencyKey,
          'p_note': note.trim(),
        });
        return res as String;
      });

  Future<List<OpeningEntry>> list() => guardedPrivate(_ref, () async {
        final rows = await _db.privateFrom('opening_stock_entries').select().order('created_at', ascending: false).limit(200);
        final ids = {for (final r in rows) r['product_id'] as String}.toList();
        final names = <String, String>{};
        if (ids.isNotEmpty) {
          final products = await _db.from('products').select('id, code, name').inFilter('id', ids);
          for (final p in products) {
            names[p['id'] as String] = '${p['name']} · ${p['code']}';
          }
        }
        return [
          for (final r in rows)
            OpeningEntry(
              id: r['id'] as String,
              productId: r['product_id'] as String,
              productLabel: names[r['product_id']] ?? 'Product',
              quantity: (r['quantity'] as num).toInt(),
              unitCost: Money.parse(r['unit_cost']),
              totalValue: Money.parse(r['total_value']),
              note: (r['note'] as String?) ?? '',
              createdAt: DateTime.parse(r['created_at'] as String),
            ),
        ];
      });
}

final openingStockRepositoryProvider = Provider<OpeningStockRepository>(
  (ref) => OpeningStockRepository(ref, ref.watch(supabaseProvider)),
);

final openingEntriesProvider = FutureProvider.autoDispose<List<OpeningEntry>>(
  (ref) => ref.watch(openingStockRepositoryProvider).list(),
);
