import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/brand_logo.dart';
import '../../features/auth/data/auth_repository.dart';
import '../../features/private_area/data/private_area_controller.dart';
import '../../features/security/data/security_repository.dart';

class _Dest {
  const _Dest(this.path, this.label, this.icon, this.selectedIcon, {this.ownerOnly = false});
  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool ownerOnly;
}

const _destinations = [
  _Dest('/', 'Dashboard', Icons.space_dashboard_outlined, Icons.space_dashboard),
  _Dest('/sales', 'Sales', Icons.point_of_sale_outlined, Icons.point_of_sale),
  _Dest('/products', 'Products', Icons.inventory_2_outlined, Icons.inventory_2),
  _Dest('/stock', 'Stock', Icons.warehouse_outlined, Icons.warehouse),
  _Dest('/gallery', 'Gallery', Icons.photo_library_outlined, Icons.photo_library),
  _Dest('/private', 'Private Area', Icons.lock_outline, Icons.lock, ownerOnly: true),
  _Dest('/settings', 'Settings', Icons.settings_outlined, Icons.settings, ownerOnly: true),
];

/// Responsive navigation: bottom bar on phones, side rail on laptops.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  static const wideBreakpoint = 840.0;

  int _indexFor(List<_Dest> dests) {
    for (var i = dests.length - 1; i >= 0; i--) {
      final p = dests[i].path;
      if (p == '/' ? location == '/' : location.startsWith(p)) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOwner = ref.watch(isOwnerProvider);
    final dests = _destinations.where((d) => !d.ownerOnly || isOwner).toList();
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;

    // Owner security alerts: pop-up when something new happens + red bar.
    final alerts = ref.watch(securitySummaryProvider);
    ref.listen(securitySummaryProvider, (prev, next) {
      final before = prev != null && prev.hasValue ? prev.requireValue.unseen : 0;
      final now = next.hasValue ? next.requireValue : SecuritySummary.empty;
      if (now.unseen > before && now.unseen > 0) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 40),
            title: const Text('Security alert'),
            content: Text('${now.latestText ?? 'Something needs your attention.'}\n\n'
                '${now.pendingDevices > 0 ? '${now.pendingDevices} device(s) waiting for your approval.' : ''}'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  context.go('/private/devices');
                },
                child: const Text('View'),
              ),
            ],
          ),
        );
      }
    });

    // Any tap inside the private area counts as owner activity (sliding 10-min lock).
    Widget body = child;
    if (location.startsWith('/private')) {
      body = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => ref.read(privateAreaProvider.notifier).registerActivity(),
        child: child,
      );
    }

    final summary = alerts.hasValue ? alerts.requireValue : SecuritySummary.empty;
    if (summary.hasAlert && !location.startsWith('/private/devices')) {
      body = Column(
        children: [
          Material(
            color: Colors.red.shade700,
            child: InkWell(
              onTap: () => context.go('/private/devices'),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.shield, color: Colors.white),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          [
                            if (summary.unseen > 0) '${summary.unseen} new security alert(s)',
                            if (summary.pendingDevices > 0) '${summary.pendingDevices} device(s) waiting for approval',
                          ].join(' · '),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const Text('View', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                      const Icon(Icons.chevron_right, color: Colors.white),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: body),
        ],
      );
    }

    if (wide) {
      final index = _indexFor(dests);
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              extended: MediaQuery.sizeOf(context).width >= 1100,
              minExtendedWidth: 220,
              selectedIndex: index < 0 ? null : index,
              onDestinationSelected: (i) => context.go(dests[i].path),
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: MediaQuery.sizeOf(context).width >= 1100
                    ? const SizedBox(width: 196, child: BrandHeader(logoSize: 36))
                    : const BrandLogo(size: 36),
              ),
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: IconButton(
                      tooltip: 'Account',
                      icon: const Icon(Icons.account_circle_outlined),
                      onPressed: () => context.go('/account'),
                    ),
                  ),
                ),
              ),
              destinations: [
                for (final d in dests)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    // Phone: first four destinations + "More".
    final primary = dests.take(4).toList();
    var index = _indexFor(primary);
    if (index < 0) index = primary.length; // More
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) => context.go(i < primary.length ? primary[i].path : '/more'),
        destinations: [
          for (final d in primary)
            NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selectedIcon), label: d.label),
          const NavigationDestination(icon: Icon(Icons.menu), selectedIcon: Icon(Icons.menu_open), label: 'More'),
        ],
      ),
    );
  }
}
