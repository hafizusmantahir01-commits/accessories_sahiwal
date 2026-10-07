import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/image_type.dart';

class BusinessSettings {
  const BusinessSettings({
    required this.businessName,
    required this.logoText,
    required this.logoPath,
    required this.address,
    required this.phone,
    required this.receiptFooter,
    required this.lowStockDefault,
    required this.tradingStartedAt,
  });

  final String businessName;
  final String logoText;
  final String? logoPath;
  final String address;
  final String phone;
  final String receiptFooter;
  final int lowStockDefault;
  final DateTime? tradingStartedAt;

  static const fallback = BusinessSettings(
    businessName: 'Accessories Sahiwal',
    logoText: 'AS',
    logoPath: null,
    address: '',
    phone: '',
    receiptFooter: '',
    lowStockDefault: 5,
    tradingStartedAt: null,
  );

  factory BusinessSettings.fromJson(Map<String, dynamic> j) => BusinessSettings(
        businessName: (j['business_name'] as String?) ?? 'Accessories Sahiwal',
        logoText: (j['logo_text'] as String?) ?? 'AS',
        logoPath: j['logo_path'] as String?,
        address: (j['address'] as String?) ?? '',
        phone: (j['phone'] as String?) ?? '',
        receiptFooter: (j['receipt_footer'] as String?) ?? '',
        lowStockDefault: (j['low_stock_default'] as num?)?.toInt() ?? 5,
        tradingStartedAt: j['trading_started_at'] == null ? null : DateTime.parse(j['trading_started_at'] as String),
      );
}

class SettingsRepository {
  SettingsRepository(this._db);
  final SupabaseClient _db;

  Future<BusinessSettings> fetch() async {
    try {
      final row = await _db.from('business_settings').select().eq('id', 1).maybeSingle();
      return row == null ? BusinessSettings.fallback : BusinessSettings.fromJson(row);
    } catch (e) {
      throw AppException.from(e);
    }
  }

  Future<void> update({
    required String businessName,
    required String logoText,
    required String address,
    required String phone,
    required String receiptFooter,
    required int lowStockDefault,
  }) async {
    try {
      await _db.from('business_settings').update({
        'business_name': businessName.trim(),
        'logo_text': logoText.trim().toUpperCase(),
        'address': address.trim(),
        'phone': phone.trim(),
        'receipt_footer': receiptFooter.trim(),
        'low_stock_default': lowStockDefault,
      }).eq('id', 1);
    } catch (e) {
      throw AppException.from(e);
    }
  }

  /// Uploads a new logo to the private "branding" bucket and points settings at it.
  Future<void> uploadLogo(Uint8List bytes) async {
    final kind = ImageKind.detect(bytes);
    if (kind == null) throw const AppException('Logo must be a JPEG, PNG or WebP image.');
    if (bytes.length > 2 * 1024 * 1024) throw const AppException('Logo must be 2 MB or smaller.');
    final path = 'logo/${const Uuid().v4()}.${kind.extension}';
    try {
      final old = (await fetch()).logoPath;
      await _db.storage.from('branding').uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: kind.mimeType, upsert: false),
          );
      await _db.from('business_settings').update({'logo_path': path}).eq('id', 1);
      if (old != null) {
        await _db.storage.from('branding').remove([old]);
      }
    } catch (e) {
      throw AppException.from(e);
    }
  }

  Future<void> removeLogo() async {
    try {
      final old = (await fetch()).logoPath;
      await _db.from('business_settings').update({'logo_path': null}).eq('id', 1);
      if (old != null) await _db.storage.from('branding').remove([old]);
    } catch (e) {
      throw AppException.from(e);
    }
  }

  Future<String?> logoUrl(String? path) async {
    if (path == null) return null;
    try {
      return await _db.storage.from('branding').createSignedUrl(path, 60 * 60);
    } catch (_) {
      return null; // fall back to the monogram
    }
  }

  Future<DateTime?> startTrading() async {
    try {
      final res = await _db.rpc('owner_start_trading');
      return res == null ? null : DateTime.parse(res as String);
    } catch (e) {
      throw AppException.from(e);
    }
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(supabaseProvider)),
);

final businessSettingsProvider = FutureProvider<BusinessSettings>((ref) async {
  ref.watch(currentUserIdProvider);
  if (ref.watch(currentUserIdProvider) == null) return BusinessSettings.fallback;
  return ref.watch(settingsRepositoryProvider).fetch();
});

final logoUrlProvider = FutureProvider<String?>((ref) async {
  final settings = await ref.watch(businessSettingsProvider.future);
  return ref.watch(settingsRepositoryProvider).logoUrl(settings.logoPath);
});
