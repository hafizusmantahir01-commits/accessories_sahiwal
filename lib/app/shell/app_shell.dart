import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/brand_logo.dart';
import '../../features/auth/data/auth_repository.dart';
import '../../features/private_area/data/private_area_controller.dart';

class _Dest {
  const _Dest(
    this.path,
    this.label,
    this.icon,
    this.selectedIcon, {
    this.ownerOnly = false,
  });
  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool ownerOnly;
}

const _destinations = [
  _Dest(
    '/',
    'Dashboard',
    Icons.space_dashboard_outlined,
    Icons.space_dashboard,
  ),
  _Dest('/sales', 'Sales', Icons.point_of_sale_outlined, Icons.point_of_sale),
  _Dest('/products', 'Products', Icons.inventory_2_outlined, Icons.inventory_2),
  _Dest('/stock', 'Stock', Icons.warehouse_outlined, Icons.warehouse),
  _Dest(
    '/gallery',
    'Gallery',
    Icons.photo_library_outlined,
    Icons.photo_library,
  ),
  _Dest(
    '/private',
    'Private Area',
    Icons.lock_outline,
    Icons.lock,
    ownerOnly: true,
  ),
  _Dest(
    '/settings',
    'Settings',
    Icons.settings_outlined,
    Icons.settings,
    ownerOnly: true,
  ),
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

    // Any tap inside the private area counts as owner activity (sliding 10-min lock).
    Widget body = child;
    if (location.startsWith('/private')) {
      body = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) =>
            ref.read(privateAreaProvider.notifier).registerActivity(),
        child: child,
      );
    }

    if (wide) {
      final index = _indexFor(dests);
      final scaffold = Scaffold(
        body: Row(
          children: [
            NavigationRail(
              extended: MediaQuery.sizeOf(context).width >= 1100,
              minExtendedWidth: 220,
              selectedIndex: index < 0 ? null : index,
              onDestinationSelected: (i) {
                if (dests[i].path == '/settings') {
                  context.push(dests[i].path);
                } else {
                  context.go(dests[i].path);
                }
              },
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: MediaQuery.sizeOf(context).width >= 1100
                    ? const SizedBox(
                        width: 196,
                        child: BrandHeader(logoSize: 36),
                      )
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
      return _withRootBackHandling(scaffold, location);
    }

    // Phone: first four destinations + "More".
    final primary = dests.take(4).toList();
    var index = _indexFor(primary);
    if (index < 0) index = primary.length; // More
    final scaffold = Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) =>
            context.go(i < primary.length ? primary[i].path : '/more'),
        destinations: [
          for (final d in primary)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
          const NavigationDestination(
            icon: Icon(Icons.menu),
            selectedIcon: Icon(Icons.menu_open),
            label: 'More',
          ),
        ],
      ),
    );
    return _withRootBackHandling(scaffold, location);
  }

  Widget _withRootBackHandling(Widget child, String location) {
    if (!const {'/', '/sales', '/products', '/stock'}.contains(location)) {
      return child;
    }
    return _RootBackGuard(location: location, child: child);
  }
}

class _RootBackGuard extends StatefulWidget {
  const _RootBackGuard({required this.location, required this.child});
  final String location;
  final Widget child;

  @override
  State<_RootBackGuard> createState() => _RootBackGuardState();
}

class _RootBackGuardState extends State<_RootBackGuard> {
  DateTime? _lastBackPressed;

  @override
  void didUpdateWidget(covariant _RootBackGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) {
      _lastBackPressed = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final now = DateTime.now();
        final lastPressed = _lastBackPressed;
        if (lastPressed != null &&
            now.difference(lastPressed) <= const Duration(seconds: 2)) {
          SystemNavigator.pop();
          return;
        }
        _lastBackPressed = now;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Press back again to exit the app.'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
      },
      child: widget.child,
    );
  }
}
