import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/data/settings_repository.dart';

/// Business logo from settings: uploaded image if set, otherwise the
/// temporary "AS" monogram. Replaceable in Settings without code changes.
class BrandLogo extends ConsumerWidget {
  const BrandLogo({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(businessSettingsProvider);
    final url = ref.watch(logoUrlProvider);
    final text = settings.hasValue ? settings.requireValue.logoText : 'AS';
    final imageUrl = url.hasValue ? url.requireValue : null;

    if (imageUrl != null) {
      return ClipOval(
        child: Image.network(
          imageUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Monogram(text: text, size: size),
        ),
      );
    }
    return Monogram(text: text, size: size);
  }
}

/// Shop logo (assets/logo.png). The image already has its own gold ring,
/// so only a soft shadow is added underneath for the 3D lift.
class Monogram extends StatelessWidget {
  const Monogram({super.key, required this.text, this.size = 40});
  final String text;
  final double size;

  static const assetPath = 'assets/logo.png';

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.30), blurRadius: size * 0.18, offset: Offset(0, size * 0.06)),
        ],
      ),
      child: Image.asset(
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, _, _) => CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: Text(text, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * 0.35)),
        ),
      ),
    );
  }
}

/// Logo + business name, used in navigation and login.
class BrandHeader extends ConsumerWidget {
  const BrandHeader({super.key, this.logoSize = 40, this.showName = true});
  final double logoSize;
  final bool showName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(businessSettingsProvider);
    final name = settings.hasValue ? settings.requireValue.businessName : 'Accessories Sahiwal';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandLogo(size: logoSize),
        if (showName) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ],
    );
  }
}
