import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../private_area/data/private_guard.dart';

class Supplier {
  const Supplier({
    required this.id,
    required this.name,
    required this.phone,
    required this.address,
    required this.notes,
    required this.isActive,
  });

  final String id;
  final String name;
  final String phone;
  final String address;
  final String notes;
  final bool isActive;

  factory Supplier.fromJson(Map<String, dynamic> j) => Supplier(
        id: j['id'] as String,
        name: j['name'] as String,
        phone: (j['phone'] as String?) ?? '',
        address: (j['address'] as String?) ?? '',
        notes: (j['notes'] as String?) ?? '',
        isActive: j['is_active'] != false,
      );
}

/// Suppliers live in the owner-only "private" schema.
class SuppliersRepository {
  SuppliersRepository(this._ref, this._db);
  final Ref _ref;
  final SupabaseClient _db;

  Future<List<Supplier>> list({bool includeInactive = false}) => guardedPrivate(_ref, () async {
        var q = _db.privateFrom('suppliers').select();
        if (!includeInactive) q = q.eq('is_active', true);
        final rows = await q.order('name', ascending: true);
        return rows.map(Supplier.fromJson).toList();
      });

  Future<Supplier> save({String? id, required String name, String phone = '', String address = '', String notes = '', bool isActive = true}) =>
      guardedPrivate(_ref, () async {
        final data = {
          'name': name.trim(),
          'phone': phone.trim(),
          'address': address.trim(),
          'notes': notes.trim(),
          'is_active': isActive,
        };
        final row = id == null
            ? await _db.privateFrom('suppliers').insert(data).select().single()
            : await _db.privateFrom('suppliers').update(data).eq('id', id).select().single();
        return Supplier.fromJson(row);
      });
}

final suppliersRepositoryProvider = Provider<SuppliersRepository>(
  (ref) => SuppliersRepository(ref, ref.watch(supabaseProvider)),
);

final suppliersProvider = FutureProvider.autoDispose.family<List<Supplier>, bool>(
  (ref, includeInactive) => ref.watch(suppliersRepositoryProvider).list(includeInactive: includeInactive),
);
