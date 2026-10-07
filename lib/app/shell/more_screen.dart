import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/common.dart';
import '../../features/auth/data/auth_repository.dart';
import '../../features/private_area/data/private_area_controller.dart';

/// Phone-only menu for destinations that do not fit in the bottom bar.
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileOrNullProvider);
    final unlocked = ref.watch(privateAreaProvider.select((s) => s.unlocked));
    final isOwner = profile?.isOwner ?? false;

    return Scaffold(
      appBar: AppBar(title: const BrandHeader(logoSize: 32)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(profile?.fullName.isNotEmpty == true ? profile!.fullName : 'Signed in'),
            subtitle: Text(profile?.roleLabel ?? ''),
            onTap: () => context.go('/account'),
          ),
          const Divider(),
          if (isOwner) ...[
            ListTile(
              leading: Icon(unlocked ? Icons.lock_open : Icons.lock_outline),
              title: const Text('Owner Private Area'),
              subtitle: Text(unlocked ? 'Unlocked' : 'Purchases, suppliers, costs'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/private'),
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              subtitle: const Text('Branding, receipt details'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/settings'),
            ),
          ],
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Gallery'),
            subtitle: const Text('Product photos'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/gallery'),
          ),
          if (isOwner)
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Activity history'),
              subtitle: const Text('Who added, edited, sold or deleted what'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/private/history'),
            ),
          ListTile(
            leading: const Icon(Icons.slideshow_outlined),
            title: const Text('Customer display mode'),
            subtitle: const Text('Show products to a customer'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/display'),
          ),
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: const Text('My account'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/account'),
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
            title: Text('Sign out', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              final ok = await confirmDialog(context, title: 'Sign out?', message: 'You will need to sign in again.');
              if (ok) await ref.read(authRepositoryProvider).signOut();
            },
          ),
        ],
      ),
    );
  }
}
