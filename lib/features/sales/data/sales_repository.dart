import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../../private_area/data/private_guard.dart';
import '../domain/sale.dart';

class SaleResult {
  const SaleResult({required this.id, required this.invoiceNo, required this.total, required this.change, required this.alreadyPosted});
  final String id;
  final String invoiceNo;
  final Decimal total;
  final Decimal change;
  final bool alreadyPosted;
}

class SalesRepository {
  SalesRepository(this._ref, this._db);
  final Ref _ref;
  final SupabaseClient _db;

  Future<T> _wrap<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      throw AppException.from(e);
    }
  }

  /// Posts a fully-paid sale atomically. Reuse [idempotencyKey] when retrying
  /// the same sale so it can never be saved twice.
  Future<SaleResult> completeSale({
    required SaleType type,
    required List<CartLine> lines,
    String? customerId,
    String customerName = '',
    String customerPhone = '',
    Decimal? finalAmount,
    String discountReason = '',
    required PaymentMethod method,
    Decimal? amountTendered,
    String reference = '',
    String notes = '',
    bool allowBelowCost = false,
    String belowCostReason = '',
    required String idempotencyKey,
  }) =>
      _wrap(() async {
        final res = await _db.rpc('complete_sale', params: {
          'p_data': {
            'sale_type': type.value,
            if (customerId != null) 'customer_id': customerId,
            'customer_name': customerName.trim(),
            'customer_phone': customerPhone.trim(),
            'items': [
              for (final l in lines)
                {
                  'product_id': l.productId,
                  'quantity': l.quantity,
                  'unit_price': l.unitPrice.toString(),
                },
            ],
            if (finalAmount != null) 'final_amount': finalAmount.toString(),
            'discount_reason': discountReason.trim(),
            'payment_method': method.value,
            if (amountTendered != null) 'amount_tendered': amountTendered.toString(),
            'payment_reference': reference.trim(),
            'notes': notes.trim(),
            'allow_below_cost': allowBelowCost,
            'below_cost_reason': belowCostReason.trim(),
          },
          'p_idempotency_key': idempotencyKey,
        });
        final m = Map<String, dynamic>.from(res as Map);
        return SaleResult(
          id: m['id'] as String,
          invoiceNo: m['invoice_no'] as String,
          total: Decimal.parse(m['total'].toString()),
          change: Decimal.parse(m['change'].toString()),
          alreadyPosted: m['already_posted'] == true,
        );
      });

  Future<List<Sale>> list({required DateTime from, required DateTime to, SaleType? type}) => _wrap(() async {
        // Karachi day boundaries (UTC+5) converted to UTC timestamps.
        final start = DateTime.utc(from.year, from.month, from.day).subtract(BizTime.offset);
        final end = DateTime.utc(to.year, to.month, to.day).add(const Duration(days: 1)).subtract(BizTime.offset);
        var q = _db
            .from('sales')
            .select('*, items:sale_items(*)')
            .gte('completed_at', start.toIso8601String())
            .lt('completed_at', end.toIso8601String());
        if (type != null) q = q.eq('sale_type', type.value);
        final rows = await q.order('completed_at', ascending: false).limit(500);
        return rows.map(Sale.fromJson).toList();
      });

  Future<Sale> get(String id) => _wrap(() async {
        final row = await _db.from('sales').select('*, items:sale_items(*)').eq('id', id).maybeSingle();
        if (row == null) throw const AppException('Sale not found.');
        return Sale.fromJson(row);
      });

  Future<List<Customer>> customers() => _wrap(() async {
        final rows = await _db.from('customers').select().eq('is_active', true).order('name', ascending: true).limit(1000);
        return rows.map(Customer.fromJson).toList();
      });

  Future<SalesSummary> summary(DateTime from, DateTime to) => _wrap(() async {
        final res = await _db.rpc('sales_summary', params: {
          'p_from': BizTime.isoDate(from),
          'p_to': BizTime.isoDate(to),
        });
        return SalesSummary.fromJson(Map<String, dynamic>.from(res as Map));
      });

  // ---------- Owner only (private area unlocked) ----------
  Future<Map<String, dynamic>> saleProfit(String saleId) => guardedPrivate(_ref, () async {
        final res = await _db.rpc('owner_sale_profit', params: {'p_sale_id': saleId});
        return Map<String, dynamic>.from(res as Map);
      });

  Future<Map<String, dynamic>> profitSummary(DateTime from, DateTime to) => guardedPrivate(_ref, () async {
        final res = await _db.rpc('owner_profit_summary', params: {
          'p_from': BizTime.isoDate(from),
          'p_to': BizTime.isoDate(to),
        });
        return Map<String, dynamic>.from(res as Map);
      });

  Future<void> voidSale(String saleId, String reason) => guardedPrivate(
        _ref,
        () async => _db.rpc('owner_void_sale', params: {'p_sale_id': saleId, 'p_reason': reason.trim()}),
      );
}

final salesRepositoryProvider = Provider<SalesRepository>(
  (ref) => SalesRepository(ref, ref.watch(supabaseProvider)),
);

/// Period presets for the sales screen.
enum SalesPeriod {
  today('Today', 0),
  week('7 days', 6),
  month('30 days', 29);

  const SalesPeriod(this.label, this.daysBack);
  final String label;
  final int daysBack;

  (DateTime, DateTime) get range {
    final to = BizTime.today();
    return (to.subtract(Duration(days: daysBack)), to);
  }
}

final salesListProvider = FutureProvider.autoDispose.family<List<Sale>, SalesPeriod>((ref, p) {
  final (from, to) = p.range;
  return ref.watch(salesRepositoryProvider).list(from: from, to: to);
});

final salesSummaryProvider = FutureProvider.autoDispose.family<SalesSummary, SalesPeriod>((ref, p) {
  final (from, to) = p.range;
  return ref.watch(salesRepositoryProvider).summary(from, to);
});

final ownerProfitProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, SalesPeriod>((ref, p) {
  final (from, to) = p.range;
  return ref.watch(salesRepositoryProvider).profitSummary(from, to);
});

final saleProvider = FutureProvider.autoDispose.family<Sale, String>(
  (ref, id) => ref.watch(salesRepositoryProvider).get(id),
);

final saleProfitProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, id) => ref.watch(salesRepositoryProvider).saleProfit(id),
);

final customersProvider = FutureProvider.autoDispose<List<Customer>>(
  (ref) => ref.watch(salesRepositoryProvider).customers(),
);
