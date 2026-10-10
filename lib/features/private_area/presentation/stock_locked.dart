import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';

/// Shown instead of stock numbers while the private area is locked.
class StockLockedCard extends StatelessWidget {
  const StockLockedCard({super.key, required this.returnTo});
  final String returnTo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card3D(
      tilt: false,
      padding: const EdgeInsets.all(20),
      onTap: () => context.go(Uri(path: '/private/unlock', queryParameters: {'from': returnTo}).toString()),
      child: Row(
        children: [
          IconBadge3D(icon: Icons.lock_outline, color: theme.colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Stock is hidden', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                const Text('Unlock the private area to see quantities.'),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

/// Full-screen version for the Stock tab.
class StockLockedScreen extends StatelessWidget {
  const StockLockedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stock')),
      body: ListView(children: const [PageBody(maxWidth: 600, child: StockLockedCard(returnTo: '/stock'))]),
    );
  }
}
