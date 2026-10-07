import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/supabase/supabase_providers.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/account_screen.dart';
import '../features/auth/presentation/blocked_screen.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/gallery/presentation/customer_display_screen.dart';
import '../features/history/presentation/activity_history_screen.dart';
import '../features/gallery/presentation/gallery_screen.dart';
import '../features/opening_stock/presentation/opening_stock_screen.dart';
import '../features/private_area/data/private_area_controller.dart';
import '../features/private_area/presentation/private_home_screen.dart';
import '../features/private_area/presentation/private_security_screen.dart';
import '../features/private_area/presentation/private_unlock_screen.dart';
import '../features/products/presentation/product_detail_screen.dart';
import '../features/products/presentation/product_form_screen.dart';
import '../features/products/presentation/products_screen.dart';
import '../features/purchases/presentation/purchase_detail_screen.dart';
import '../features/purchases/presentation/purchase_editor_screen.dart';
import '../features/purchases/presentation/purchases_screen.dart';
import '../features/sales/domain/sale.dart';
import '../features/sales/presentation/new_sale_screen.dart';
import '../features/sales/presentation/sale_detail_screen.dart';
import '../features/sales/presentation/sales_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/stock/presentation/stock_screen.dart';
import '../features/suppliers/presentation/suppliers_screen.dart';
import '../features/users/presentation/users_screen.dart';
import '../features/valuation/presentation/stock_valuation_screen.dart';
import 'shell/app_shell.dart';
import 'shell/more_screen.dart';

class _RouterRefresh extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// Routes visible only to the owner (UI guard; the database enforces it too).
bool _ownerOnly(String loc) =>
    loc.startsWith('/private') ||
    loc.startsWith('/settings') ||
    loc == '/products/new' ||
    loc.endsWith('/edit');

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh();
  ref.listen(currentProfileProvider, (_, _) => refresh.ping());
  ref.listen(currentUserIdProvider, (_, _) => refresh.ping());
  ref.listen(privateAreaProvider.select((s) => s.unlocked), (_, _) => refresh.ping());
  ref.onDispose(refresh.dispose);

  String? redirect(BuildContext context, GoRouterState state) {
    final loc = state.matchedLocation;
    final signedIn = ref.read(currentUserIdProvider) != null;
    const publicRoutes = {'/login'};

    if (!signedIn) return publicRoutes.contains(loc) ? null : '/login';

    final profileAsync = ref.read(currentProfileProvider);
    if (profileAsync.isLoading && !profileAsync.hasValue) {
      return loc == '/splash' ? null : '/splash';
    }
    final profile = profileAsync.hasValue ? profileAsync.requireValue : null;
    if (profileAsync.hasError || profile == null || !profile.isActive) {
      return loc == '/blocked' ? null : '/blocked';
    }
    if (loc == '/login' || loc == '/splash' || loc == '/blocked') return '/';
    if (_ownerOnly(loc) && !profile.isOwner) return '/';
    if ((loc.startsWith('/private/users') || loc.startsWith('/private/security')) && !profile.isRealOwner) return '/private';

    final unlocked = ref.read(privateAreaProvider).unlocked;
    if (loc.startsWith('/private') && loc != '/private/unlock' && !unlocked) {
      return Uri(path: '/private/unlock', queryParameters: {'from': state.uri.toString()}).toString();
    }
    return null;
  }

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: redirect,
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/blocked', builder: (_, _) => const BlockedScreen()),
      // Customer display mode: no navigation, no private data.
      GoRoute(path: '/display', builder: (_, s) => CustomerDisplayScreen(
            showPrices: s.uri.queryParameters['prices'] != '0',
            categoryId: s.uri.queryParameters['category'],
          )),
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/', builder: (_, _) => const DashboardScreen()),
          GoRoute(
            path: '/products',
            builder: (_, s) => ProductsScreen(initialQuery: s.uri.queryParameters['q']),
            routes: [
              GoRoute(path: 'new', builder: (_, _) => const ProductFormScreen()),
              GoRoute(
                path: ':id',
                builder: (_, s) => ProductDetailScreen(productId: s.pathParameters['id']!),
                routes: [
                  GoRoute(path: 'edit', builder: (_, s) => ProductFormScreen(productId: s.pathParameters['id'])),
                ],
              ),
            ],
          ),
          GoRoute(
            path: '/sales',
            builder: (_, _) => const SalesScreen(),
            routes: [
              GoRoute(
                path: 'new',
                builder: (_, s) => NewSaleScreen(initialType: SaleType.parse(s.uri.queryParameters['type'])),
              ),
              GoRoute(path: ':id', builder: (_, s) => SaleDetailScreen(saleId: s.pathParameters['id']!)),
            ],
          ),
          GoRoute(path: '/stock', builder: (_, s) => StockScreen(lowOnly: s.uri.queryParameters['low'] == '1')),
          GoRoute(path: '/gallery', builder: (_, _) => const GalleryScreen()),
          GoRoute(path: '/more', builder: (_, _) => const MoreScreen()),
          GoRoute(path: '/account', builder: (_, _) => const AccountScreen()),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
          GoRoute(
            path: '/private/unlock',
            builder: (_, s) => PrivateUnlockScreen(from: s.uri.queryParameters['from']),
          ),
          GoRoute(
            path: '/private',
            builder: (_, _) => const PrivateHomeScreen(),
            routes: [
              GoRoute(
                path: 'purchases',
                builder: (_, _) => const PurchasesScreen(),
                routes: [
                  GoRoute(path: 'new', builder: (_, _) => const PurchaseEditorScreen()),
                  GoRoute(
                    path: ':id',
                    builder: (_, s) => PurchaseDetailScreen(purchaseId: s.pathParameters['id']!),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        builder: (_, s) => PurchaseEditorScreen(purchaseId: s.pathParameters['id']),
                      ),
                    ],
                  ),
                ],
              ),
              GoRoute(path: 'suppliers', builder: (_, _) => const SuppliersScreen()),
              GoRoute(path: 'opening-stock', builder: (_, _) => const OpeningStockScreen()),
              GoRoute(path: 'valuation', builder: (_, _) => const StockValuationScreen()),
              GoRoute(path: 'users', builder: (_, _) => const UsersScreen()),
              GoRoute(path: 'history', builder: (_, _) => const ActivityHistoryScreen()),
              GoRoute(path: 'security', builder: (_, _) => const PrivateSecurityScreen()),
            ],
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Not found')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('This page does not exist.'),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => context.go('/'), child: const Text('Go to dashboard')),
          ],
        ),
      ),
    ),
  );
});
