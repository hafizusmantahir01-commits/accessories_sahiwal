import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/theme.dart';
import 'core/config/env.dart';
import 'core/widgets/brand_logo.dart';
import 'core/widgets/three_d.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!Env.isConfigured) {
    runApp(const _MissingConfigApp());
    return;
  }

  await Supabase.initialize(url: Env.supabaseUrl, anonKey: Env.supabaseAnonKey);
  runApp(const ProviderScope(child: AccessoriesSahiwalApp()));
}

/// Shown when the app was started without valid Supabase settings.
class _MissingConfigApp extends StatelessWidget {
  const _MissingConfigApp();

  @override
  Widget build(BuildContext context) {
    final message = Env.hasPlaceholders
        ? 'Open env/dev.json and replace the YOUR-… values with your Supabase '
            'Project URL and anon (publishable) key, then restart the app.'
        : 'Start the app with your settings file:\n\n'
            'flutter run -d chrome --dart-define-from-file=env/dev.json\n\n'
            'or press F5 in VS Code (launch configuration included).';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        body: Background3D(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Spin3D(child: Monogram(text: 'AS', size: 84)),
                    const SizedBox(height: 24),
                    Card3D(
                      maxAngle: 0.05,
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          const Text('Setup needed', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 12),
                          SelectableText(message, textAlign: TextAlign.center),
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
