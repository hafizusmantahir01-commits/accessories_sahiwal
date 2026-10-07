import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_repository.dart';

/// Shown when the account is inactive, revoked, or the profile cannot load.
class BlockedScreen extends ConsumerWidget {
  const BlockedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider);
    final failedToLoad = profile.hasError;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(failedToLoad ? Icons.wifi_off : Icons.block, size: 56, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text(
                  failedToLoad ? 'Could not load your account' : 'Access not available',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  failedToLoad
                      ? 'Check your internet connection and try again.'
                      : 'This account is inactive or its access was revoked. Please contact the owner.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (failedToLoad)
                  FilledButton(
                    onPressed: () => ref.invalidate(currentProfileProvider),
                    child: const Text('Try again'),
                  ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => ref.read(authRepositoryProvider).signOut(),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
