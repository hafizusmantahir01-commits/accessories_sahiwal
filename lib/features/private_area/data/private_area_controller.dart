import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../auth/data/auth_repository.dart';
import 'private_area_repository.dart';

class PrivateAreaState {
  const PrivateAreaState({
    this.unlocked = false,
    this.hasSecret = true,
    this.checked = false,
    this.localDeadline,
  });

  final bool unlocked;
  final bool hasSecret;

  /// True once the server status has been fetched at least once.
  final bool checked;

  /// Client-side estimate of the server's 10-minute inactivity expiry.
  final DateTime? localDeadline;

  PrivateAreaState copyWith({bool? unlocked, bool? hasSecret, bool? checked, DateTime? localDeadline}) =>
      PrivateAreaState(
        unlocked: unlocked ?? this.unlocked,
        hasSecret: hasSecret ?? this.hasSecret,
        checked: checked ?? this.checked,
        localDeadline: localDeadline ?? this.localDeadline,
      );
}

/// Tracks whether the Owner Private Area is unlocked for THIS session.
/// The database is the authority (10-minute sliding expiry); this controller
/// mirrors it so the UI can lock itself and redirect promptly.
class PrivateAreaController extends Notifier<PrivateAreaState> {
  static const _window = Duration(minutes: 10);
  static const _touchEvery = Duration(seconds: 60);

  Timer? _ticker;
  DateTime _lastTouch = DateTime.fromMillisecondsSinceEpoch(0);
  bool _touching = false;
  bool _fullPartner = false;
  static final Set<String> _lockedAtStart = <String>{};
  Future<void>? _startupLock;

  PrivateAreaRepository get _repo => ref.read(privateAreaRepositoryProvider);

  @override
  PrivateAreaState build() {
    // Reset whenever a different user signs in or out.
    final userId = ref.watch(currentUserIdProvider);
    ref.onDispose(() => _ticker?.cancel());
    _ticker?.cancel();
    // A full-access partner unlocks with their own login password.
    _fullPartner = ref.watch(profileOrNullProvider.select((p) => p?.isFullPartner ?? false));
    // Every fresh start of the app begins LOCKED (also on the server), so a
    // closed and reopened app never shows the private area or stock.
    if (userId != null && _lockedAtStart.add(userId)) {
      _startupLock = Future.microtask(() async {
        try {
          await _repo.lock();
        } catch (_) {}
      });
    }
    return const PrivateAreaState(checked: true);
  }

  Future<void> refresh() async {
    await _startupLock;
    final s = await _repo.status();
    if (s.unlocked) {
      _startTicker();
      state = PrivateAreaState(
        unlocked: true,
        hasSecret: s.hasSecret,
        checked: true,
        localDeadline: DateTime.now().add(_window - const Duration(seconds: 5)),
      );
    } else {
      _ticker?.cancel();
      state = PrivateAreaState(unlocked: false, hasSecret: s.hasSecret, checked: true);
    }
  }

  /// Returns false when the password is wrong.
  Future<bool> unlock(String secret) async {
    await _startupLock;
    final ok = _fullPartner ? await _repo.unlockWithLogin(secret) : await _repo.unlock(secret);
    if (ok) {
      _lastTouch = DateTime.now();
      _startTicker();
      state = state.copyWith(
        unlocked: true,
        checked: true,
        hasSecret: true,
        localDeadline: DateTime.now().add(_window - const Duration(seconds: 5)),
      );
    }
    return ok;
  }

  Future<void> setSecret({String? current, required String next}) async {
    await _repo.setSecret(current: current, next: next);
    // Changing the secret revokes every unlock, including this one.
    _ticker?.cancel();
    state = const PrivateAreaState(unlocked: false, hasSecret: true, checked: true);
  }

  Future<void> lock() async {
    _ticker?.cancel();
    state = PrivateAreaState(unlocked: false, hasSecret: state.hasSecret, checked: true);
    try {
      await _repo.lock();
    } catch (_) {/* already locked or offline: local state is locked anyway */}
  }

  /// Called when the server reports PRIVATE_LOCKED.
  void markLocked() {
    if (!state.unlocked) return;
    _ticker?.cancel();
    state = PrivateAreaState(unlocked: false, hasSecret: state.hasSecret, checked: true);
  }

  /// Owner interacted with a private screen: extend the server window (throttled).
  Future<void> registerActivity() async {
    if (!state.unlocked || _touching) return;
    final now = DateTime.now();
    if (now.difference(_lastTouch) < _touchEvery) return;
    _touching = true;
    try {
      final still = await _repo.touch();
      _lastTouch = DateTime.now();
      if (still) {
        state = state.copyWith(localDeadline: _lastTouch.add(_window - const Duration(seconds: 5)));
      } else {
        markLocked();
      }
    } catch (_) {
      // Network blip: keep the current deadline; the ticker will lock on expiry.
    } finally {
      _touching = false;
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 15), (_) {
      final deadline = state.localDeadline;
      if (state.unlocked && deadline != null && DateTime.now().isAfter(deadline)) {
        markLocked();
      }
    });
  }
}

final privateAreaProvider =
    NotifierProvider<PrivateAreaController, PrivateAreaState>(PrivateAreaController.new);

/// Stock quantities are shown only while the private area is unlocked,
/// so the app can be shown to a shopkeeper without revealing stock.
final stockVisibleProvider = Provider<bool>((ref) => ref.watch(privateAreaProvider.select((s) => s.unlocked)));
