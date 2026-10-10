import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/money.dart';
import '../../private_area/data/private_guard.dart';

/// One line of the owner's activity history (who did what, when).
class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.at,
    required this.actorName,
    required this.actorRole,
    required this.action,
    required this.entity,
    required this.reason,
    required this.before,
    required this.after,
  });

  final int id;
  final DateTime at;
  final String actorName;
  final String actorRole;
  final String action;
  final String entity;
  final String? reason;
  final Map<String, dynamic> before;
  final Map<String, dynamic> after;

  bool get byPartner => actorRole == 'partner';

  factory ActivityEntry.fromJson(Map<String, dynamic> j) => ActivityEntry(
        id: (j['id'] as num).toInt(),
        at: DateTime.parse(j['created_at'] as String),
        actorName: (j['actor_name'] as String?) ?? 'System',
        actorRole: (j['actor_role'] as String?) ?? 'system',
        action: j['action'] as String,
        entity: j['entity'] as String,
        reason: j['reason'] as String?,
        before: j['before_data'] is Map ? Map<String, dynamic>.from(j['before_data'] as Map) : const {},
        after: j['after_data'] is Map ? Map<String, dynamic>.from(j['after_data'] as Map) : const {},
      );

  String _v(String key) => (after[key] ?? before[key] ?? '').toString();

  IconData get icon => switch (action) {
        'product_created' => Icons.add_box_outlined,
        'product_updated' => Icons.edit_outlined,
        'product_deleted' => Icons.delete_outline,
        'photo_added' => Icons.add_a_photo_outlined,
        'photo_removed' => Icons.hide_image_outlined,
        'sale_completed' => Icons.point_of_sale,
        'sale_voided' => Icons.cancel_outlined,
        'purchase_posted' => Icons.shopping_cart_outlined,
        'opening_stock_posted' => Icons.inventory_outlined,
        'purchase_line_edited' || 'opening_stock_edited' => Icons.edit_note,
        'purchase_line_deleted' || 'purchase_deleted' || 'opening_stock_deleted' => Icons.delete_forever_outlined,
        'category_created' || 'category_updated' || 'category_deleted' => Icons.category_outlined,
        'user_access_changed' || 'partner_created' || 'sessions_revoked' ||
        'partner_password_reset' || 'partner_login_enabled' || 'partner_login_disabled' ||
        'partner_full_access_on' || 'partner_full_access_off' => Icons.manage_accounts_outlined,
        'private_secret_changed' || 'private_unlock_failed' => Icons.key_outlined,
        'device_approved' || 'device_blocked' || 'device_removed' || 'device_approval_on' || 'device_approval_off' =>
          Icons.phonelink_lock,
        _ => Icons.history,
      };

  /// Danger-coloured actions (deletes, voids, failed password attempts).
  bool get isWarning => action.contains('deleted') || action == 'sale_voided' || action == 'private_unlock_failed' ||
      action == 'photo_removed';

  String get title => switch (action) {
        'product_created' => 'Added product ${_v('code')} · ${_v('name')}',
        'product_updated' => 'Edited product ${_v('code')} · ${_v('name')}',
        'product_deleted' => 'Deleted product ${_v('code')} · ${_v('name')}',
        'photo_added' => 'Added a photo to ${_v('code')}',
        'photo_removed' => 'Removed a photo from ${_v('code')}',
        'sale_completed' =>
          '${_v('type') == 'wholesale' ? 'Wholesale' : 'Retail'} sale ${_v('invoice_no')} · ${Money.format(after['total'])}',
        'sale_voided' => 'Voided sale ${_v('invoice_no')} · ${Money.format(before['total'])}',
        'purchase_posted' => 'Purchase ${_v('purchase_no')} · ${Money.format(after['total'])}',
        'opening_stock_posted' => 'Opening stock: ${_v('quantity')} pcs @ ${Money.format(after['unit_cost'])}',
        'purchase_line_edited' => 'Corrected ${_v('purchase_no')}: ${_v('name')} (${_v('code')})',
        'purchase_line_deleted' => 'Removed ${_v('name')} (${_v('code')}) from ${_v('purchase_no')}',
        'purchase_deleted' => 'Deleted purchase ${_v('purchase_no')} · ${Money.format(before['total'])}',
        'opening_stock_edited' => 'Corrected opening stock: ${_v('name')} (${_v('code')})',
        'opening_stock_deleted' =>
          'Deleted opening stock: ${before['quantity']} × ${_v('name')} (${_v('code')})',
        'category_created' => 'Created category ${_v('name')}',
        'category_updated' => 'Renamed category ${before['name']} → ${after['name']}',
        'category_deleted' => 'Deleted category ${_v('name')}',
        'user_access_changed' => 'Changed partner access',
        'partner_created' => 'Created a partner account',
        'partner_password_reset' => 'Reset a partner password',
        'partner_login_enabled' => 'Enabled partner login',
        'partner_login_disabled' => 'Disabled partner login',
        'partner_full_access_on' => 'Gave partner full access',
        'partner_full_access_off' => 'Removed partner full access',
        'sessions_revoked' => 'Signed a user out everywhere',
        'private_secret_changed' => 'Changed the private password',
        'private_unlock_failed' => 'Wrong private password attempt',
        'trading_started' => 'Closed opening stock',
        'device_approved' => 'Approved a device ${reason ?? ''}',
        'device_blocked' => 'Blocked a device ${reason ?? ''}',
        'device_removed' => 'Removed a device ${reason ?? ''}',
        'device_approval_on' => 'Turned on device approval',
        'device_approval_off' => 'Turned off device approval',
        _ => action.replaceAll('_', ' '),
      };

  /// Extra detail lines (price changes, discounts…).
  List<String> get details {
    final lines = <String>[];
    if (action == 'product_updated') {
      for (final (key, label) in const [
        ('retail_price', 'Retail price'),
        ('wholesale_price', 'Wholesale price'),
        ('name', 'Name'),
        ('code', 'Code'),
        ('is_active', 'Active'),
      ]) {
        final a = before[key]?.toString();
        final b = after[key]?.toString();
        if (a != b) {
          final money = key.endsWith('price');
          lines.add('$label: ${money ? Money.format(a) : a} → ${money ? Money.format(b) : b}');
        }
      }
    }
    if (action == 'purchase_line_edited' || action == 'opening_stock_edited') {
      final priceKey = action == 'purchase_line_edited' ? 'unit_price' : 'unit_cost';
      lines.add('${before['quantity']} × ${Money.format(before[priceKey])} → '
          '${after['quantity']} × ${Money.format(after[priceKey])}');
      if (before['total'] != null && after['total'] != null) {
        lines.add('Purchase total ${Money.format(before['total'])} → ${Money.format(after['total'])}');
      }
    }
    if (action == 'purchase_line_deleted') {
      lines.add('${before['quantity']} × ${Money.format(before['unit_price'])} removed');
      lines.add('Purchase total ${Money.format(before['total'])} → ${Money.format(after['total'])}');
    }
    if (action == 'purchase_deleted') {
      if (before['supplier'] != null) lines.add('Supplier: ${before['supplier']}');
      for (final i in (before['items'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(i as Map);
        lines.add('${m['quantity']} × ${m['name']} (${m['code']}) @ ${Money.format(m['unit_price'])}');
      }
    }
    if (action == 'product_deleted') {
      final stock = before['stock'];
      if (stock is num && stock > 0) lines.add('Stock removed: $stock pcs');
      for (final i in (before['purchase_lines'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(i as Map);
        lines.add('${m['purchase_no']}: ${m['quantity']} × ${Money.format(m['unit_price'])} removed');
      }
      final opening = before['opening_qty'];
      if (opening is num && opening > 0) lines.add('Opening stock removed: $opening pcs');
    }
    if (action == 'sale_completed') {
      if (_v('customer').isNotEmpty) lines.add('Customer: ${_v('customer')}');
      final discount = Money.parse(after['discount']);
      if (discount.signum > 0) {
        lines.add('Bill ${Money.format(after['subtotal'])} → received ${Money.format(after['total'])} '
            '(less ${Money.format(discount)}${_v('discount_reason').isNotEmpty ? ': ${_v('discount_reason')}' : ''})');
      }
    }
    return lines;
  }
}

class HistoryFilter {
  const HistoryFilter({this.entity});
  final String? entity;

  @override
  bool operator ==(Object other) => other is HistoryFilter && other.entity == entity;

  @override
  int get hashCode => entity.hashCode;
}

final activityLogProvider = FutureProvider.autoDispose.family<List<ActivityEntry>, HistoryFilter>((ref, f) {
  final db = ref.watch(supabaseProvider);
  return guardedPrivate(ref, () async {
    final rows = await db.rpc('owner_activity_log', params: {'p_limit': 500, 'p_entity': f.entity});
    return (rows as List).map((e) => ActivityEntry.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  });
});
