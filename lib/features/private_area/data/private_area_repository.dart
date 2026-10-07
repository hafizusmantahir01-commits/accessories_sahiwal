import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';

class PrivateStatus {
  const PrivateStatus({required this.isOwner, required this.unlocked, required this.hasSecret});
  final bool isOwner;
  final bool unlocked;
  final bool hasSecret;

  factory PrivateStatus.fromJson(Map<String, dynamic> j) => PrivateStatus(
        isOwner: j['is_owner'] == true,
        unlocked: j['unlocked'] == true,
        hasSecret: j['has_secret'] == true,
      );
}

/// Server calls for the Owner Private Area ("locked folder").
/// The server decides — the app never stores the private password.
class PrivateAreaRepository {
  PrivateAreaRepository(this._db);
  final SupabaseClient _db;

  Future<PrivateStatus> status() => _call(() async {
        final res = await _db.rpc('private_status');
        return PrivateStatus.fromJson(Map<String, dynamic>.from(res as Map));
      });

  Future<bool> unlock(String secret) => _call(() async {
        final res = await _db.rpc('unlock_private', params: {'p_secret': secret});
        return (res as Map)['unlocked'] == true;
      });

  Future<bool> touch() => _call(() async {
        final res = await _db.rpc('touch_private');
        return (res as Map)['unlocked'] == true;
      });

  Future<void> lock() => _call(() => _db.rpc('lock_private'));

  Future<void> setSecret({String? current, required String next}) => _call(
        () => _db.rpc('set_private_secret', params: {'p_current': current, 'p_new': next}),
      );

  Future<T> _call<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      throw AppException.from(e);
    }
  }
}

final privateAreaRepositoryProvider = Provider<PrivateAreaRepository>(
  (ref) => PrivateAreaRepository(ref.watch(supabaseProvider)),
);
