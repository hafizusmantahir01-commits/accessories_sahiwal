import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/money.dart';

/// One shop / customer in the ledger (khata).
class LedgerRow {
  const LedgerRow({
    required this.id,
    required this.name,
    required this.phone,
    required this.address,
    required this.isShopkeeper,
    required this.bills,
    required this.amount,
    required this.returns,
    required this.lastSaleAt,
    required this.profit,
  });

  final String id;
  final String name;
  final String phone;
  final String address;
  final bool isShopkeeper;
  final int bills;

  /// Money received from this customer (after returns).
  final Decimal amount;
  final Decimal returns;
  final DateTime? lastSaleAt;

  /// Only for the owner with the private area open; otherwise null.
  final Decimal? profit;

  factory LedgerRow.fromJson(Map<String, dynamic> j) => LedgerRow(
        id: j['customer_id'] as String,
        name: (j['name'] as String?) ?? '',
        phone: (j['phone'] as String?) ?? '',
        address: (j['address'] as String?) ?? '',
        isShopkeeper: j['customer_type'] == 'shopkeeper',
        bills: (j['bills'] as num?)?.toInt() ?? 0,
        amount: Money.parse(j['total_amount']),
        returns: Money.parse(j['returns_amount']),
        lastSaleAt: j['last_sale_at'] == null ? null : DateTime.parse(j['last_sale_at'] as String),
        profit: j['profit'] == null ? null : Money.parse(j['profit']),
      );
}

/// A product one shop buys: pieces, amount, last rate.
class CustomerProduct {
  const CustomerProduct({
    required this.productId,
    required this.code,
    required this.name,
    required this.pieces,
    required this.amount,
    required this.lastPrice,
    required this.lastSoldAt,
  });

  final String productId;
  final String code;
  final String name;
  final int pieces;
  final Decimal amount;
  final Decimal lastPrice;
  final DateTime? lastSoldAt;

  factory CustomerProduct.fromJson(Map<String, dynamic> j) => CustomerProduct(
        productId: j['product_id'] as String,
        code: (j['code'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        pieces: (j['pieces'] as num?)?.toInt() ?? 0,
        amount: Money.parse(j['amount']),
        lastPrice: Money.parse(j['last_price']),
        lastSoldAt: j['last_sold_at'] == null ? null : DateTime.parse(j['last_sold_at'] as String),
      );
}

class CustomersRepository {
  CustomersRepository(this._db);
  final SupabaseClient _db;

  Future<T> _wrap<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      throw AppException.from(e);
    }
  }

  Future<List<LedgerRow>> ledger({String search = '', bool shopkeepersOnly = true}) => _wrap(() async {
        final rows = await _db.rpc('customer_ledger', params: {
          'p_search': search.trim().isEmpty ? null : search.trim(),
          'p_type': shopkeepersOnly ? 'shopkeeper' : null,
        });
        return (rows as List).map((e) => LedgerRow.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      });

  Future<List<CustomerProduct>> products(String customerId) => _wrap(() async {
        final rows = await _db.rpc('customer_products', params: {'p_customer_id': customerId});
        return (rows as List).map((e) => CustomerProduct.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      });

  Future<void> update(String id, {required String name, String phone = '', String address = ''}) => _wrap(() async {
        await _db.rpc('owner_update_customer', params: {
          'p_customer_id': id,
          'p_name': name.trim(),
          'p_phone': phone.trim(),
          'p_address': address.trim(),
        });
      });
}

final customersRepositoryProvider = Provider<CustomersRepository>(
  (ref) => CustomersRepository(ref.watch(supabaseProvider)),
);

/// (search, shopkeepersOnly)
final ledgerProvider = FutureProvider.autoDispose.family<List<LedgerRow>, (String, bool)>(
  (ref, q) => ref.watch(customersRepositoryProvider).ledger(search: q.$1, shopkeepersOnly: q.$2),
);

final customerProductsProvider = FutureProvider.autoDispose.family<List<CustomerProduct>, String>(
  (ref, id) => ref.watch(customersRepositoryProvider).products(id),
);
