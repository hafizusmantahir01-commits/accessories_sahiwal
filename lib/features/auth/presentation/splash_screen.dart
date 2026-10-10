import 'package:flutter/material.dart';

import '../../../core/widgets/brand_logo.dart';
import '../../../core/widgets/three_d.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Background3D(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Spin3D(angle: 0.3, child: Monogram(text: 'AS', size: 130)),
              SizedBox(height: 28),
              SizedBox(width: 28, height: 28, child: CircularProgressIndicator(color: Color(0xFFE2C77E), strokeWidth: 3)),
            ],
          ),
        ),
      ),
    );
  }
}
