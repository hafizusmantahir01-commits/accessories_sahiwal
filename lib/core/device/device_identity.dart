import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// A random id saved once per install (browser or phone). The owner sees it
/// as "this device" and can approve or block it.
abstract final class DeviceIdentity {
  static const _key = 'accessories_sahiwal_device_id';
  static String id = '';
  static String label = '';

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var value = prefs.getString(_key);
      if (value == null || value.length < 8) {
        value = const Uuid().v4();
        await prefs.setString(_key, value);
      }
      id = value;
    } catch (_) {
      // Storage blocked (private window): use a temporary id for this run.
      id = const Uuid().v4();
    }
    label = _describe();
  }

  static String _describe() {
    final os = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iPhone/iPad',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.macOS => 'Mac',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.fuchsia => 'Device',
    };
    return kIsWeb ? 'Browser on $os' : '$os app';
  }
}
