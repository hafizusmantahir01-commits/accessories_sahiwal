import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/private_area/data/private_area_controller.dart';
import 'router.dart';
import 'theme.dart';

class AccessoriesSahiwalApp extends ConsumerStatefulWidget {
  const AccessoriesSahiwalApp({super.key});

  @override
  ConsumerState<AccessoriesSahiwalApp> createState() => _AccessoriesSahiwalAppState();
}

class _AccessoriesSahiwalAppState extends ConsumerState<AccessoriesSahiwalApp> {
  late final AppLifecycleListener _lifecycle;
  DateTime? _hiddenAt;

  @override
  void initState() {
    super.initState();
    // Leaving the app (home button, switching apps/tabs) for more than 15
    // seconds locks the private area and hides stock again.
    _lifecycle = AppLifecycleListener(
      onHide: () => _hiddenAt = DateTime.now(),
      onShow: () {
        final at = _hiddenAt;
        _hiddenAt = null;
        if (at != null && DateTime.now().difference(at) > const Duration(seconds: 15)) {
          ref.read(privateAreaProvider.notifier).lock();
        }
      },
      onDetach: () => ref.read(privateAreaProvider.notifier).lock(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Accessories Sahiwal',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.light,
      routerConfig: router,
      // English now; Urdu can be added later without changing screens.
      supportedLocales: const [Locale('en'), Locale('ur')],
      locale: const Locale('en'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
