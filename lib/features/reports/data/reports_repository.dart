import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../private_area/data/private_guard.dart';

List<Map<String, dynamic>> _rows(Object? res) =>
    (res as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

// ---------------------------------------------------------------- models

class DayCash {
  const DayCash({
    required this.date,
    required this.openingDefault,
    required this.cashSales,
    required this.cashRefunds,
    required this.cashExpenses,
    required this.bills,
    required this.otherMethods,
    required this.closing,
  });

  final DateTime date;
  final Decimal openingDefault;
  final Decimal cashSales;
  final Decimal cashRefunds;
  final Decimal cashExpenses;
  final int bills;
  final Map<String, Decimal> otherMethods;

  /// Saved closing of this day (null = not closed yet).
  final DayClosing? closing;

  factory DayCash.fromJson(Map<String, dynamic> j) => DayCash(
        date: DateTime.parse(j['date'] as String),
        openingDefault: Money.parse(j['opening_default']),
        cashSales: Money.parse(j['cash_sales']),
        cashRefunds: Money.parse(j['cash_refunds']),
        cashExpenses: Money.parse(j['cash_expenses']),
        bills: (j['bills'] as num?)?.toInt() ?? 0,
        otherMethods: {
          for (final e in Map<String, dynamic>.from((j['other_methods'] as Map?) ?? const {}).entries)
            e.key: Money.parse(e.value),
        },
        closing: j['closing'] == null ? null : DayClosing.fromJson(Map<String, dynamic>.from(j['closing'] as Map)),
      );
}

class DayClosing {
  const DayClosing({
    required this.date,
    required this.opening,
    required this.cashSales,
    required this.cashRefunds,
    required this.cashExpenses,
    required this.cashOut,
    required this.expected,
    required this.counted,
    required this.difference,
    required this.note,
    required this.closedBy,
    required this.closedAt,
  });

  final DateTime date;
  final Decimal opening;
  final Decimal cashSales;
  final Decimal cashRefunds;
  final Decimal cashExpenses;
  final Decimal cashOut;
  final Decimal expected;
  final Decimal counted;
  final Decimal difference;
  final String note;
  final String closedBy;
  final DateTime? closedAt;

  factory DayClosing.fromJson(Map<String, dynamic> j) => DayClosing(
        date: DateTime.parse(j['closing_date'] as String),
        opening: Money.parse(j['opening_cash']),
        cashSales: Money.parse(j['cash_sales']),
        cashRefunds: Money.parse(j['cash_refunds']),
        cashExpenses: Money.parse(j['cash_expenses']),
        cashOut: Money.parse(j['cash_out']),
        expected: Money.parse(j['expected_cash']),
        counted: Money.parse(j['counted_cash']),
        difference: Money.parse(j['difference']),
        note: (j['note'] as String?) ?? '',
        closedBy: (j['closed_by_name'] as String?) ?? '',
        closedAt: j['closed_at'] == null ? null : DateTime.parse(j['closed_at'] as String),
      );
}

class DeadStockRow {
  const DeadStockRow(this.productId, this.code, this.name, this.qty, this.value, this.lastSoldAt, this.daysIdle);
  final String productId;
  final String code;
  final String name;
  final int qty;
  final Decimal value;
  final DateTime? lastSoldAt;
  final int daysIdle;

  factory DeadStockRow.fromJson(Map<String, dynamic> j) => DeadStockRow(
        j['product_id'] as String,
        (j['code'] as String?) ?? '',
        (j['name'] as String?) ?? '',
        (j['qty'] as num?)?.toInt() ?? 0,
        Money.parse(j['stock_value']),
        j['last_sold_at'] == null ? null : DateTime.parse(j['last_sold_at'] as String),
        (j['days_idle'] as num?)?.toInt() ?? 0,
      );
}

class DayPoint {
  const DayPoint(this.day, this.bills, this.sales, this.profit);
  final DateTime day;
  final int bills;
  final Decimal sales;
  final Decimal profit;

  factory DayPoint.fromJson(Map<String, dynamic> j) => DayPoint(
        DateTime.parse(j['day'] as String),
        (j['bills'] as num?)?.toInt() ?? 0,
        Money.parse(j['net_sales']),
        Money.parse(j['profit']),
      );
}

class PricePreview {
  const PricePreview(this.productId, this.code, this.name, this.oldRetail, this.newRetail, this.oldWholesale, this.newWholesale);
  final String productId;
  final String code;
  final String name;
  final Decimal oldRetail;
  final Decimal newRetail;
  final Decimal oldWholesale;
  final Decimal newWholesale;

  bool get invalid => newRetail <= Decimal.zero || newWholesale <= Decimal.zero;

  factory PricePreview.fromJson(Map<String, dynamic> j) => PricePreview(
        j['product_id'] as String,
        (j['code'] as String?) ?? '',
        (j['name'] as String?) ?? '',
        Money.parse(j['old_retail']),
        Money.parse(j['new_retail']),
        Money.parse(j['old_wholesale']),
        Money.parse(j['new_wholesale']),
      );
}

class ReorderRow {
  const ReorderRow({
    required this.productId,
    required this.code,
    required this.name,
    required this.stock,
    required this.sold,
    required this.perDay,
    required this.daysLeft,
    required this.suggested,
    required this.lastRate,
  });

  final String productId;
  final String code;
  final String name;
  final int stock;
  final int sold;
  final Decimal perDay;
  final Decimal? daysLeft;
  final int suggested;
  final Decimal? lastRate;

  factory ReorderRow.fromJson(Map<String, dynamic> j) => ReorderRow(
        productId: j['product_id'] as String,
        code: (j['code'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        stock: (j['stock'] as num?)?.toInt() ?? 0,
        sold: (j['sold'] as num?)?.toInt() ?? 0,
        perDay: Money.parse(j['per_day']),
        daysLeft: j['days_left'] == null ? null : Money.parse(j['days_left']),
        suggested: (j['suggested'] as num?)?.toInt() ?? 0,
        lastRate: j['last_rate'] == null ? null : Money.parse(j['last_rate']),
      );
}

// ---------------------------------------------------------------- repository

class ReportsRepository {
  ReportsRepository(this._ref, this._db);
  final Ref _ref;
  final SupabaseClient _db;

  Future<T> _wrap<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      throw AppException.from(e);
    }
  }

  // Day closing (anyone who can sell)
  Future<DayCash> dayCash(DateTime date) => _wrap(() async {
        final res = await _db.rpc('day_cash_summary', params: {'p_date': BizTime.isoDate(date)});
        return DayCash.fromJson(Map<String, dynamic>.from(res as Map));
      });

  Future<DayClosing> closeDay({
    required DateTime date,
    required Decimal opening,
    required Decimal cashOut,
    required Decimal counted,
    String note = '',
    String? reason,
  }) =>
      _wrap(() async {
        final res = await _db.rpc('close_day', params: {
          'p_date': BizTime.isoDate(date),
          'p_opening': opening.toString(),
          'p_cash_out': cashOut.toString(),
          'p_counted': counted.toString(),
          'p_note': note.trim(),
          'p_reason': reason?.trim(),
        });
        return DayClosing.fromJson(Map<String, dynamic>.from(res as Map));
      });

  Future<List<DayClosing>> closings() => _wrap(() async {
        final res = await _db.rpc('owner_list_day_closings', params: {'p_limit': 120});
        return _rows(res).map(DayClosing.fromJson).toList();
      });

  // Owner reports (private area)
  Future<List<DeadStockRow>> deadStock(int days) => guardedPrivate(_ref, () async {
        final res = await _db.rpc('owner_dead_stock', params: {'p_days': days});
        return _rows(res).map(DeadStockRow.fromJson).toList();
      });

  Future<List<DayPoint>> daily(DateTime from, DateTime to) => guardedPrivate(_ref, () async {
        final res = await _db.rpc('owner_daily_report', params: {
          'p_from': BizTime.isoDate(from),
          'p_to': BizTime.isoDate(to),
        });
        return _rows(res).map(DayPoint.fromJson).toList();
      });

  Future<List<ReorderRow>> reorder({int days = 30, int cover = 15}) => guardedPrivate(_ref, () async {
        final res = await _db.rpc('owner_reorder_suggestions', params: {'p_days': days, 'p_cover': cover});
        return _rows(res).map(ReorderRow.fromJson).toList();
      });

  Future<Map<String, dynamic>> export(DateTime from, DateTime to) => guardedPrivate(_ref, () async {
        final res = await _db.rpc('owner_export', params: {
          'p_from': BizTime.isoDate(from),
          'p_to': BizTime.isoDate(to),
        });
        return Map<String, dynamic>.from(res as Map);
      });

  // Bulk prices (owner)
  Future<List<PricePreview>> pricePreview({
    required List<String> productIds,
    required String field,
    required String mode,
    required Decimal value,
    required int round,
  }) =>
      _wrap(() async {
        final res = await _db.rpc('owner_bulk_price_preview', params: {
          'p_product_ids': productIds,
          'p_field': field,
          'p_mode': mode,
          'p_value': value.toString(),
          'p_round': round,
        });
        return _rows(res).map(PricePreview.fromJson).toList();
      });

  Future<int> priceApply({
    required List<String> productIds,
    required String field,
    required String mode,
    required Decimal value,
    required int round,
    required String reason,
  }) =>
      _wrap(() async {
        final res = await _db.rpc('owner_bulk_price_apply', params: {
          'p_product_ids': productIds,
          'p_field': field,
          'p_mode': mode,
          'p_value': value.toString(),
          'p_round': round,
          'p_reason': reason.trim(),
        });
        return (res as num).toInt();
      });
}

final reportsRepositoryProvider = Provider<ReportsRepository>(
  (ref) => ReportsRepository(ref, ref.watch(supabaseProvider)),
);

final dayCashProvider = FutureProvider.autoDispose.family<DayCash, DateTime>(
  (ref, d) => ref.watch(reportsRepositoryProvider).dayCash(d),
);

final closingsProvider = FutureProvider.autoDispose<List<DayClosing>>(
  (ref) => ref.watch(reportsRepositoryProvider).closings(),
);

final deadStockProvider = FutureProvider.autoDispose.family<List<DeadStockRow>, int>(
  (ref, days) => ref.watch(reportsRepositoryProvider).deadStock(days),
);

/// Last 30 days (Karachi) for the dashboard graph.
final last30DaysProvider = FutureProvider.autoDispose<List<DayPoint>>((ref) {
  final to = BizTime.today();
  return ref.watch(reportsRepositoryProvider).daily(to.subtract(const Duration(days: 29)), to);
});

final reorderProvider = FutureProvider.autoDispose.family<List<ReorderRow>, (int, int)>(
  (ref, q) => ref.watch(reportsRepositoryProvider).reorder(days: q.$1, cover: q.$2),
);
