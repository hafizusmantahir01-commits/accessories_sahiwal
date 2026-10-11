import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/money.dart';
import '../../private_area/data/private_guard.dart';

/// Expense categories (value stored in the database → label + icon).
enum ExpenseCategory {
  rent('rent', 'Rent (kiraya)', Icons.home_work_outlined),
  electricity('electricity', 'Electricity / bills', Icons.bolt_outlined),
  salary('salary', 'Salary', Icons.badge_outlined),
  transport('transport', 'Transport', Icons.local_shipping_outlined),
  food('food', 'Tea / food', Icons.coffee_outlined),
  repair('repair', 'Repair / maintenance', Icons.build_outlined),
  other('other', 'Other', Icons.more_horiz);

  const ExpenseCategory(this.value, this.label, this.icon);
  final String value;
  final String label;
  final IconData icon;

  static ExpenseCategory parse(Object? v) =>
      ExpenseCategory.values.firstWhere((c) => c.value == v, orElse: () => ExpenseCategory.other);
}

class Expense {
  const Expense({
    required this.id,
    required this.date,
    required this.category,
    required this.amount,
    required this.note,
    required this.createdBy,
    this.fromCash = true,
  });

  final String id;
  final DateTime date;
  final ExpenseCategory category;
  final Decimal amount;
  final String note;
  final String createdBy;

  /// Paid from the shop's cash drawer (galla) - counts in day closing.
  final bool fromCash;

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        id: j['id'] as String,
        date: DateTime.parse(j['expense_date'] as String),
        category: ExpenseCategory.parse(j['category']),
        amount: Money.parse(j['amount']),
        note: (j['note'] as String?) ?? '',
        createdBy: (j['created_by_name'] as String?) ?? '',
        fromCash: j['paid_from_cash'] != false,
      );
}

class ExpensesRepository {
  ExpensesRepository(this._ref, this._db);
  final Ref _ref;
  final SupabaseClient _db;

  Future<List<Expense>> list(DateTime from, DateTime to) => guardedPrivate(_ref, () async {
        final rows = await _db.rpc('owner_list_expenses', params: {
          'p_from': BizTime.isoDate(from),
          'p_to': BizTime.isoDate(to),
        });
        return (rows as List).map((e) => Expense.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      });

  /// Add (id null) or edit (id + reason).
  Future<void> save({
    String? id,
    required DateTime date,
    required ExpenseCategory category,
    required Decimal amount,
    String note = '',
    String? reason,
    bool fromCash = true,
  }) =>
      guardedPrivate(_ref, () async {
        await _db.rpc('owner_save_expense', params: {
          'p_id': id,
          'p_date': BizTime.isoDate(date),
          'p_category': category.value,
          'p_amount': amount.toString(),
          'p_note': note.trim(),
          'p_reason': reason?.trim(),
          'p_from_cash': fromCash,
        });
      });

  Future<void> delete(String id, String reason) => guardedPrivate(_ref, () async {
        await _db.rpc('owner_delete_expense', params: {'p_id': id, 'p_reason': reason.trim()});
      });
}

final expensesRepositoryProvider = Provider<ExpensesRepository>(
  (ref) => ExpensesRepository(ref, ref.watch(supabaseProvider)),
);

/// Expenses between two dates (both included).
final expensesProvider = FutureProvider.autoDispose.family<List<Expense>, (DateTime, DateTime)>(
  (ref, r) => ref.watch(expensesRepositoryProvider).list(r.$1, r.$2),
);
