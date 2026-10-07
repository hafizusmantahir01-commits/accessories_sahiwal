import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../private_area/data/private_guard.dart';

class ManagedUser {
  const ManagedUser({
    required this.id,
    required this.email,
    required this.fullName,
    required this.isOwner,
    required this.isActive,
    required this.canCreateSale,
    required this.canOverridePrice,
    required this.fullAccess,
    required this.lastSignInAt,
  });

  final String id;
  final String email;
  final String fullName;
  final bool isOwner;
  final bool isActive;
  final bool canCreateSale;
  final bool canOverridePrice;
  final bool fullAccess;
  final DateTime? lastSignInAt;

  factory ManagedUser.fromJson(Map<String, dynamic> j) => ManagedUser(
        id: j['id'] as String,
        email: (j['email'] as String?) ?? '',
        fullName: (j['full_name'] as String?) ?? '',
        isOwner: j['role'] == 'owner',
        isActive: j['is_active'] == true,
        canCreateSale: j['can_create_sale'] == true,
        canOverridePrice: j['can_override_price'] == true,
        fullAccess: j['full_access'] == true,
        lastSignInAt: j['last_sign_in_at'] == null ? null : DateTime.parse(j['last_sign_in_at'] as String),
      );
}

/// Owner-only account administration. Creating accounts and resetting
/// passwords run in the "admin-users" Edge Function (service role stays on the server).
class UsersRepository {
  UsersRepository(this._ref, this._db);
  final Ref _ref;
  final SupabaseClient _db;

  Future<List<ManagedUser>> list() => guardedPrivate(_ref, () async {
        final rows = await _db.rpc('owner_list_users');
        return (rows as List).map((e) => ManagedUser.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      });

  Future<void> setAccess(ManagedUser u, {bool? active, bool? canCreateSale, bool? canOverridePrice, String? fullName}) =>
      guardedPrivate(_ref, () async {
        await _db.rpc('owner_set_user_access', params: {
          'p_user_id': u.id,
          'p_is_active': active ?? u.isActive,
          'p_can_create_sale': canCreateSale ?? u.canCreateSale,
          'p_can_override_price': canOverridePrice ?? u.canOverridePrice,
          'p_full_name': fullName,
        });
      });

  Future<void> setFullAccess(String userId, bool enabled) => guardedPrivate(
        _ref,
        () async => _db.rpc('owner_set_full_access', params: {'p_user_id': userId, 'p_enabled': enabled}),
      );

  Future<void> revokeSessions(String userId) => guardedPrivate(
        _ref,
        () async => _db.rpc('owner_revoke_sessions', params: {'p_user_id': userId}),
      );

  Future<void> createPartner({required String email, required String password, required String fullName}) =>
      _admin({'action': 'create_partner', 'email': email.trim(), 'password': password, 'full_name': fullName.trim()});

  Future<void> resetPassword(String userId, String password) =>
      _admin({'action': 'reset_password', 'user_id': userId, 'password': password});

  Future<void> setLoginEnabled(String userId, bool enabled) =>
      _admin({'action': 'set_login_enabled', 'user_id': userId, 'enabled': enabled});

  Future<void> _admin(Map<String, dynamic> body) => guardedPrivate(_ref, () async {
        try {
          final res = await _db.functions.invoke('admin-users', body: body);
          final data = res.data;
          if (data is Map && data['error'] != null) {
            throw _functionError(data['error'].toString());
          }
        } on FunctionException catch (e) {
          final details = e.details;
          final msg = details is Map && details['error'] != null ? details['error'].toString() : 'Request failed';
          throw _functionError(msg);
        }
      });

  AppException _functionError(String msg) => msg.startsWith('PRIVATE_LOCKED')
      ? const AppException('The Owner Private Area is locked. Unlock it to continue.', kind: AppErrorKind.privateLocked)
      : AppException(msg, kind: AppErrorKind.validation);
}

final usersRepositoryProvider = Provider<UsersRepository>(
  (ref) => UsersRepository(ref, ref.watch(supabaseProvider)),
);

final usersProvider = FutureProvider.autoDispose<List<ManagedUser>>((ref) => ref.watch(usersRepositoryProvider).list());
