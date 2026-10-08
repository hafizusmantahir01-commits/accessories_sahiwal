import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final appPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw StateError('App preferences must be initialized before the app starts.');
});
