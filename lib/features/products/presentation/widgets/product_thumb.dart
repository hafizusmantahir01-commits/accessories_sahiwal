import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/products_repository.dart';

/// Displays a private product photo through a short-lived signed URL.
class ProductThumb extends ConsumerWidget {
  const ProductThumb({super.key, required this.path, this.size = 56, this.radius = 10, this.fit = BoxFit.cover});

  final String? path;
  final double size;
  final double radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(radius)),
      child: Icon(Icons.image_outlined, color: scheme.outline, size: size * 0.45),
    );
    if (path == null) return placeholder;

    final url = ref.watch(imageUrlProvider(path!));
    final value = url.hasValue ? url.requireValue : null;
    if (value == null) return placeholder;

    // cacheWidth keeps phone memory/decoding light for thumbnails.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        value,
        width: size,
        height: size,
        fit: fit,
        cacheWidth: (size * dpr).round(),
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (context, child, progress) => progress == null ? child : placeholder,
      ),
    );
  }
}

/// Full-width photo (detail/gallery), height-constrained by its parent.
class ProductPhoto extends ConsumerWidget {
  const ProductPhoto({super.key, required this.path, this.fit = BoxFit.contain});
  final String path;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(imageUrlProvider(path));
    final value = url.hasValue ? url.requireValue : null;
    final scheme = Theme.of(context).colorScheme;
    if (value == null) {
      return Container(
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: url.isLoading ? const CircularProgressIndicator() : Icon(Icons.broken_image_outlined, color: scheme.outline),
      );
    }
    return Image.network(
      value,
      fit: fit,
      errorBuilder: (_, _, _) => Container(
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.broken_image_outlined, color: scheme.outline),
      ),
    );
  }
}
