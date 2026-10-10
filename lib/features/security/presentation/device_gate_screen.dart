import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/device/device_identity.dart';
import '../../../core/widgets/brand_logo.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../../auth/data/auth_repository.dart';
import '../data/security_repository.dart';

/// Shown when this phone/computer is new (waiting for approval) or blocked.
class DeviceGateScreen extends ConsumerStatefulWidget {
  const DeviceGateScreen({super.key});

  @override
  ConsumerState<DeviceGateScreen> createState() => _DeviceGateScreenState();
}

class _DeviceGateScreenState extends ConsumerState<DeviceGateScreen> {
  final _secret = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    if (_secret.text.isEmpty) {
      context.showError('Enter your private password.');
      return;
    }
    try {
      final ok = await ref.read(securityRepositoryProvider).approveOwnDevice(_secret.text);
      if (!mounted) return;
      if (!ok) {
        context.showError('Wrong private password.');
        return;
      }
      _secret.clear();
      context.showSuccess('This device is approved.');
      ref.invalidate(deviceStatusProvider);
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(deviceStatusProvider);
    final profile = ref.watch(profileOrNullProvider);
    final blocked = status.hasValue && status.requireValue == 'blocked';
    final theme = Theme.of(context);

    return Scaffold(
      body: Background3D(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: Spin3D(angle: 0.3, child: Monogram(text: 'AS', size: 110))),
                    const SizedBox(height: 24),
                    Card3D(
                      tilt: false,
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Icon(blocked ? Icons.block : Icons.phonelink_lock,
                              size: 48, color: blocked ? theme.colorScheme.error : theme.colorScheme.primary),
                          const SizedBox(height: 12),
                          Text(
                            blocked ? 'This device is blocked' : 'New device — approval needed',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            blocked
                                ? 'The owner has blocked this phone/computer. Contact the owner.'
                                : 'For safety, every new phone or computer must be approved by the owner '
                                    '(Private Area → Devices & security). The owner has been alerted.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text('${profile?.fullName ?? ''} · ${DeviceIdentity.label}',
                              textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                          if (!blocked && (profile?.isRealOwner ?? false)) ...[
                            const Divider(height: 32),
                            Text('Owner? Approve this device with your private password:',
                                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _secret,
                              obscureText: _obscure,
                              onSubmitted: (_) => _approve(),
                              decoration: InputDecoration(
                                labelText: 'Private password',
                                prefixIcon: const Icon(Icons.key_outlined),
                                suffixIcon: IconButton(
                                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                                  onPressed: () => setState(() => _obscure = !_obscure),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            BusyButton(label: 'Approve this device', icon: Icons.verified_user, expand: true, onPressed: _approve),
                          ],
                          const SizedBox(height: 16),
                          if (!blocked)
                            OutlinedButton.icon(
                              icon: const Icon(Icons.refresh),
                              label: const Text('Check again'),
                              onPressed: () => ref.invalidate(deviceStatusProvider),
                            ),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            icon: const Icon(Icons.logout),
                            label: const Text('Sign out'),
                            onPressed: () => ref.read(authRepositoryProvider).signOut(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
