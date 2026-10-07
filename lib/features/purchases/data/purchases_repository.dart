import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../private_area/data/private_guard.dart';
import '../domain/purchase.dart';

class PostResult {
  const PostResult({required this.id, required this.purchaseNo, required this.alreadyPosted});
  final String id;
  final String purchaseNo;
  final bool alreadyPosted;
}

/// All purchase operations are owner-only and run through server functions
/// that post stock, landed costs and the payment atomically.
class PurchasesRepository {
  PurchasesRepository(this._ref, this._db);
  final Ref _ref;
  final SupabaseClient _db;

  Future<List<PurchaseSummary>> list({bool? drafts, String? search}) => guardedPrivate(_ref, () async {
        final rows = await _db.rpc('owner_list_purchases', params: {
          'p_status': drafts == null ? null : (drafts ? 'draft' : 'posted'),
          'p_search': (search ?? '').trim().isEmpty ? null : search!.trim(),
        });
        return (rows as List).map((e) => PurchaseSummary.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      });

  Future<Purchase> get(String id) => guardedPrivate(_ref, () async {
        final res = await _db.rpc('owner_get_purchase', params: {'p_purchase_id': id});
        return Purchase.fromJson(Map<String, dynamic>.from(res as Map));
      });

  /// Creates or replaces a DRAFT. Drafts never change stock or money.
  Future<String> saveDraft({
    String? id,
    required String supplierId,
    required String documentDate,
    required String supplierRef,
    required Decimal extraCosts,
    required String extraCostsNote,
    required PaymentMethod paymentMethod,
    required String notes,
    required List<DraftLine> lines,
  }) =>
      guardedPrivate(_ref, () async {
        final res = await _db.rpc('owner_save_purchase_draft', params: {
          'p_data': {
            if (id != null) 'id': id,
            'supplier_id': supplierId,
            'document_date': documentDate,
            'supplier_ref': supplierRef,
            'extra_costs': extraCosts.toString(),
            'extra_costs_note': extraCostsNote,
            'payment_method': paymentMethod.value,
            'notes': notes,
            'items': [for (final l in lines) l.toJson()],
          },
        });
        return res as String;
      });

  /// Posts a draft as fully paid. [idempotencyKey] must be reused for retries
  /// of the same attempt so a network retry can never post twice.
  Future<PostResult> post({
    required String id,
    required PaymentMethod method,
    required Decimal amountPaid,
    required String idempotencyKey,
    String reference = '',
  }) =>
      guardedPrivate(_ref, () async {
        final res = await _db.rpc('owner_post_purchase', params: {
          'p_purchase_id': id,
          'p_payment_method': method.value,
          'p_amount_paid': amountPaid.toString(),
          'p_idempotency_key': idempotencyKey,
          'p_reference': reference.trim(),
        });
        final m = Map<String, dynamic>.from(res as Map);
        return PostResult(
          id: m['id'] as String,
          purchaseNo: m['purchase_no'] as String,
          alreadyPosted: m['already_posted'] == true,
        );
      });

  Future<void> deleteDraft(String id) => guardedPrivate(
        _ref,
        () async => _db.rpc('owner_delete_purchase_draft', params: {'p_purchase_id': id}),
      );

  /// Purchases already using this supplier bill number (warning only).
  Future<List<String>> duplicateRefs({required String supplierId, required String ref, String? excludeId}) =>
      guardedPrivate(_ref, () async {
        if (ref.trim().isEmpty) return const <String>[];
        final rows = await _db.rpc('owner_find_duplicate_supplier_ref', params: {
          'p_supplier_id': supplierId,
          'p_supplier_ref': ref.trim(),
          'p_exclude_id': excludeId,
        });
        return (rows as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .map((m) => (m['purchase_no'] as String?) ?? 'a draft')
            .toList();
      });
}

final purchasesRepositoryProvider = Provider<PurchasesRepository>(
  (ref) => PurchasesRepository(ref, ref.watch(supabaseProvider)),
);

final purchaseListProvider = FutureProvider.autoDispose.family<List<PurchaseSummary>, bool>(
  (ref, drafts) => ref.watch(purchasesRepositoryProvider).list(drafts: drafts),
);

final purchaseProvider = FutureProvider.autoDispose.family<Purchase, String>(
  (ref, id) => ref.watch(purchasesRepositoryProvider).get(id),
);
