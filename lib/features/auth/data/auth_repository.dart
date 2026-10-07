import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../domain/profile.dart';

class AuthRepository {
  AuthRepository(this._db);
  final SupabaseClient _db;

  Future<void> signIn({required String email, required String password}) async {
    try {
      await _db.auth.signInWithPassword(email: email.trim(), password: password);
    } catch (e) {
      throw AppException.from(e);
    }
  }

  /// Locks the private area on the server before ending the session.
  Future<void> signOut() async {
    try {
      await _db.rpc('lock_private');
    } catch (_) {
      // Session may already be invalid; signing out still proceeds.
    }
    await _db.auth.signOut();
  }

  /// Sends a password-reset email (Supabase Auth). The link opens the app's
  /// configured redirect URL where a new password can be set.
  Future<void> sendPasswordReset(String email) async {
    try {
      await _db.auth.resetPasswordForEmail(email.trim());
    } catch (e) {
      throw AppException.from(e);
    }
  }

  Future<void> updatePassword(String newPassword) async {
    try {
      await _db.auth.updateUser(UserAttributes(password: newPassword));
    } catch (e) {
      throw AppException.from(e);
    }
  }

  Future<Profile?> fetchProfile(String userId) async {
    try {
      final row = await _db.from('profiles').select().eq('id', userId).maybeSingle();
      return row == null ? null : Profile.fromJson(row);
    } catch (e) {
      throw AppException.from(e);
    }
  }
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(supabaseProvider)),
);

/// The current user's profile, or null when signed out.
final currentProfileProvider = FutureProvider<Profile?>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  return ref.watch(authRepositoryProvider).fetchProfile(userId);
});

/// Synchronous access for widgets that are only shown after login.
final profileOrNullProvider = Provider<Profile?>((ref) {
  final p = ref.watch(currentProfileProvider);
  return p.hasValue ? p.requireValue : null;
});

final isOwnerProvider = Provider<bool>((ref) => ref.watch(profileOrNullProvider)?.isOwner ?? false);
