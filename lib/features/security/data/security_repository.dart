import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/device/device_identity.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../auth/data/auth_repository.dart';
import '../../private_area/data/private_guard.dart';

class SecuritySummary {
  const SecuritySummary({this.unseen = 0, this.pendingDevices = 0, this.approvalRequired = true, this.latestText});
  final int unseen;
  final int pendingDevices;
  final bool approvalRequired;
  final String? latestText;

  bool get hasAlert => unseen > 0 || pendingDevices > 0;
  static const empty = SecuritySummary();

  factory SecuritySummary.fromJson(Map<String, dynamic> j) {
    final latest = j['latest'] is Map ? Map<String, dynamic>.from(j['latest'] as Map) : null;
    return SecuritySummary(
      unseen: (j['unseen'] as num?)?.toInt() ?? 0,
      pendingDevices: (j['pending_devices'] as num?)?.toInt() ?? 0,
      approvalRequired: j['approval_required'] != false,
      latestText: latest == null
          ? null
          : '${SecurityEvent.describe(latest['kind'] as String? ?? '')}'
              '${(latest['email'] as String?)?.isNotEmpty == true ? ' · ${latest['email']}' : ''}',
    );
  }
}

class SecurityEvent {
  const SecurityEvent({required this.at, required this.kind, required this.who, required this.device, required this.ip, required this.seen});
  final DateTime at;
  final String kind;
  final String who;
  final String device;
  final String ip;
  final bool seen;

  factory SecurityEvent.fromJson(Map<String, dynamic> j) => SecurityEvent(
        at: DateTime.parse(j['created_at'] as String),
        kind: j['kind'] as String,
        who: (j['user_name'] as String?) ?? '',
        device: (j['device_label'] as String?) ?? '',
        ip: (j['ip'] as String?) ?? '',
        seen: j['seen'] == true,
      );

  static String describe(String kind) => switch (kind) {
        'failed_login' => 'Wrong password attempt',
        'new_device' => 'New device signed in',
        'blocked_device_attempt' => 'Blocked device tried to open the app',
        'failed_device_approval' => 'Wrong private password on a new device',
        'device_approved' => 'Device approved',
        'device_blocked' => 'Device blocked',
        _ => kind.replaceAll('_', ' '),
      };

  String get title => describe(kind);
  bool get isDanger => kind == 'failed_login' || kind == 'blocked_device_attempt' || kind == 'failed_device_approval';
  IconData get icon => switch (kind) {
        'failed_login' || 'failed_device_approval' => Icons.password,
        'new_device' => Icons.devices_other,
        'blocked_device_attempt' || 'device_blocked' => Icons.block,
        'device_approved' => Icons.verified_user_outlined,
        _ => Icons.shield_outlined,
      };
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.userName,
    required this.userRole,
    required this.label,
    required this.status,
    required this.firstSeen,
    required this.lastSeen,
    required this.ip,
    required this.isCurrent,
  });
  final String id;
  final String userName;
  final String userRole;
  final String label;
  final String status;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final String ip;
  final bool isCurrent;

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: j['id'] as String,
        userName: (j['user_name'] as String?) ?? '',
        userRole: (j['user_role'] as String?) ?? '',
        label: (j['label'] as String?) ?? '',
        status: j['status'] as String,
        firstSeen: DateTime.parse(j['first_seen'] as String),
        lastSeen: DateTime.parse(j['last_seen'] as String),
        ip: (j['last_ip'] as String?) ?? '',
        isCurrent: j['is_current'] == true,
      );
}

class SecurityRepository {
  SecurityRepository(this._ref, this._db);
  final Ref _ref;
  final SupabaseClient _db;

  Future<T> _wrap<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      throw AppException.from(e);
    }
  }

  /// Registers this install for the signed-in user; returns approved / pending / blocked / inactive.
  Future<String> registerDevice() => _wrap(() async {
        final res = await _db.rpc('register_device', params: {'p_label': DeviceIdentity.label});
        return (Map<String, dynamic>.from(res as Map)['status'] as String?) ?? 'approved';
      });

  /// Owner approves this new device with the private password.
  Future<bool> approveOwnDevice(String secret) => _wrap(() async {
        final res = await _db.rpc('approve_own_device', params: {'p_secret': secret});
        return Map<String, dynamic>.from(res as Map)['approved'] == true;
      });

  /// Records a failed sign-in for the owner's alerts. Never throws.
  Future<void> reportLoginFailure(String email) async {
    try {
      await _db.rpc('report_login_failure', params: {'p_email': email.trim(), 'p_label': DeviceIdentity.label});
    } catch (_) {}
  }

  Future<SecuritySummary> summary() => _wrap(() async {
        final res = await _db.rpc('owner_security_summary');
        return SecuritySummary.fromJson(Map<String, dynamic>.from(res as Map));
      });

  Future<List<SecurityEvent>> events() => guardedPrivate(_ref, () async {
        final rows = await _db.rpc('owner_security_events', params: {'p_limit': 200});
        return (rows as List).map((e) => SecurityEvent.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      });

  Future<void> markSeen() => guardedPrivate(_ref, () async => _db.rpc('owner_mark_security_seen'));

  Future<List<DeviceInfo>> devices() => guardedPrivate(_ref, () async {
        final rows = await _db.rpc('owner_list_devices');
        return (rows as List).map((e) => DeviceInfo.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      });

  Future<void> setDeviceStatus(String id, String status) => guardedPrivate(
        _ref,
        () async => _db.rpc('owner_set_device_status', params: {'p_device': id, 'p_status': status}),
      );

  Future<void> deleteDevice(String id) =>
      guardedPrivate(_ref, () async => _db.rpc('owner_delete_device', params: {'p_device': id}));

  Future<void> setApprovalRequired(bool enabled) =>
      guardedPrivate(_ref, () async => _db.rpc('owner_set_device_approval', params: {'p_enabled': enabled}));
}

final securityRepositoryProvider = Provider<SecurityRepository>(
  (ref) => SecurityRepository(ref, ref.watch(supabaseProvider)),
);

/// This device's status for the signed-in user (null when signed out).
/// If the check itself fails (e.g. offline) the app continues; the server
/// still refuses data to unapproved devices.
final deviceStatusProvider = FutureProvider<String?>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  try {
    return await ref.watch(securityRepositoryProvider).registerDevice();
  } catch (_) {
    return 'approved';
  }
});

/// Owner's security alerts, refreshed every 20 seconds while the app is open.
final securitySummaryProvider = StreamProvider<SecuritySummary>((ref) async* {
  final realOwner = ref.watch(profileOrNullProvider.select((p) => p?.isRealOwner ?? false));
  final device = ref.watch(deviceStatusProvider.select((v) => v.hasValue ? v.requireValue : null));
  if (!realOwner || device != 'approved') {
    yield SecuritySummary.empty;
    return;
  }
  final repo = ref.watch(securityRepositoryProvider);
  while (true) {
    try {
      yield await repo.summary();
    } catch (_) {/* offline: try again next round */}
    await Future<void>.delayed(const Duration(seconds: 20));
  }
});

final securityEventsProvider = FutureProvider.autoDispose<List<SecurityEvent>>(
  (ref) => ref.watch(securityRepositoryProvider).events(),
);

final devicesProvider = FutureProvider.autoDispose<List<DeviceInfo>>(
  (ref) => ref.watch(securityRepositoryProvider).devices(),
);
