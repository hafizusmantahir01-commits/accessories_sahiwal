import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_exception.dart';
import 'private_area_controller.dart';

/// Runs an owner-private server call. If the server says the private area
/// is locked (expired/other session), the app locks itself and the router
/// sends the owner to the unlock screen.
Future<T> guardedPrivate<T>(Ref ref, Future<T> Function() body) async {
  try {
    return await body();
  } catch (e) {
    final ex = AppException.from(e);
    if (ex.isPrivateLocked) {
      ref.read(privateAreaProvider.notifier).markLocked();
    }
    throw ex;
  }
}
