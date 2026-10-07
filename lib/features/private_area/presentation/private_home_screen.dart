import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../../auth/data/auth_repository.dart';
import '../data/private_area_controller.dart';

class PrivateHomeScreen extends ConsumerWidget {
  const PrivateHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final realOwner = ref.watch(profileOrNullProvider)?.isRealOwner ?? false;
    final items = <(IconData, String, String, String)>[
      (Icons.shopping_cart_outlined, 'Purchases', 'Record fully-paid supplier purchases', '/private/purchases'),
      (Icons.local_shipping_outlined, 'Suppliers', 'Names and contact details', '/private/suppliers'),
      (Icons.inventory_outlined, 'Opening stock', 'Existing inventory with actual unit cost', '/private/opening-stock'),
      (Icons.account_balance_wallet_outlined, 'Stock valuation', 'Average cost and stock value', '/private/valuation'),
      (Icons.history, 'Activity history', 'Who added, edited, sold or deleted what', '/private/history'),
      if (realOwner) ...[
        (Icons.group_outlined, 'Users & permissions', 'Partner accounts and access', '/private/users'),
        (Icons.key_outlined, 'Private password', 'Change the locked-area password', '/private/security'),
      ],
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Owner Private Area'),
        actions: [
          if (realOwner) TextButton.icon(
            onPressed: () async {
              await ref.read(privateAreaProvider.notifier).lock();
              if (context.mounted) context.go('/');
            },
            icon: const Icon(Icons.lock),
            label: const Text('Lock now'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        child: PageBody(
          child: LayoutBuilder(
            builder: (context, c) {
              final columns = c.maxWidth >= 900 ? 3 : (c.maxWidth >= 560 ? 2 : 1);
              return GridView.count(
                crossAxisCount: columns,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: columns == 1 ? 4.2 : 2.6,
                children: [
                  for (final (icon, title, subtitle, path) in items)
                    Card3D(
                      onTap: () => context.go(path),
                      child: Row(
                        children: [
                          IconBadge3D(icon: icon, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: Theme.of(context).textTheme.titleMedium),
                                const SizedBox(height: 2),
                                Text(subtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
