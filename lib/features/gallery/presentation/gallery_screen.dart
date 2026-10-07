import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../../products/data/products_repository.dart';
import '../../products/domain/product.dart';
import '../../products/presentation/widgets/product_thumb.dart';

/// Product photo gallery with filters. Contains selling prices only.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String? _categoryId;
  String? _brand;
  bool _inStockOnly = true;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = ProductQuery(search: _query, categoryId: _categoryId, inStockOnly: _inStockOnly);
    final products = ref.watch(productListProvider(q));
    final categories = ref.watch(categoriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Product gallery'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.slideshow_outlined),
            label: const Text('Customer view'),
            onPressed: () => context.push(Uri(path: '/display', queryParameters: {
              if (_categoryId != null) 'category': _categoryId!,
            }).toString()),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _search,
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () => setState(() => _query = v.trim()));
              },
              decoration: const InputDecoration(hintText: 'Search name or code', prefixIcon: Icon(Icons.search)),
            ),
          ),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                FilterChip(
                  label: const Text('In stock'),
                  selected: _inStockOnly,
                  onSelected: (v) => setState(() => _inStockOnly = v),
                ),
                const SizedBox(width: 8),
                if (categories.hasValue)
                  for (final c in categories.requireValue.where((c) => c.isActive)) ...[
                    ChoiceChip(
                      label: Text(c.name),
                      selected: _categoryId == c.id,
                      onSelected: (_) => setState(() => _categoryId = _categoryId == c.id ? null : c.id),
                    ),
                    const SizedBox(width: 8),
                  ],
                if (products.hasValue)
                  ..._brandChips(products.requireValue),
              ],
            ),
          ),
          Expanded(
            child: AsyncView<List<Product>>(
              value: products,
              onRetry: () => ref.invalidate(productListProvider(q)),
              data: (all) {
                final list = _brand == null ? all : all.where((p) => p.brand == _brand).toList();
                if (list.isEmpty) {
                  return const EmptyState(icon: Icons.photo_library_outlined, title: 'No products to show');
                }
                unawaited(ref.read(signedUrlCacheProvider).prefetch(
                      [for (final p in list) if (p.primaryImage != null) p.primaryImage!.path],
                    ));
                return ProductGrid(products: list, showPrices: true, onTap: (p) => context.push('/products/${p.id}'));
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _brandChips(List<Product> products) {
    final brands = {for (final p in products) if (p.brand.isNotEmpty) p.brand}.toList()..sort();
    if (brands.length < 2) return const [];
    return [
      const VerticalDivider(),
      for (final b in brands) ...[
        ChoiceChip(
          label: Text(b),
          selected: _brand == b,
          onSelected: (_) => setState(() => _brand = _brand == b ? null : b),
        ),
        const SizedBox(width: 8),
      ],
    ];
  }
}

class ProductGrid extends StatelessWidget {
  const ProductGrid({super.key, required this.products, required this.showPrices, this.onTap, this.large = false});
  final List<Product> products;
  final bool showPrices;
  final bool large;
  final void Function(Product)? onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final target = large ? 280.0 : 200.0;
      final columns = (c.maxWidth / target).floor().clamp(2, 6);
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: showPrices ? 0.72 : 0.82,
        ),
        itemCount: products.length,
        itemBuilder: (context, i) => _GalleryCard(
          product: products[i],
          showPrices: showPrices,
          large: large,
          onTap: onTap == null ? null : () => onTap!(products[i]),
        ),
      );
    });
  }
}

class _GalleryCard extends StatelessWidget {
  const _GalleryCard({required this.product, required this.showPrices, required this.large, this.onTap});
  final Product product;
  final bool showPrices;
  final bool large;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = product;
    return Tilt3D(
      maxAngle: 0.14,
      child: Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: p.primaryImage == null
                  ? Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(Icons.image_outlined, size: 40, color: theme.colorScheme.outline),
                    )
                  : LayoutBuilder(
                      builder: (_, c) => ProductThumb(
                        path: p.primaryImage!.path,
                        size: c.maxWidth,
                        radius: 0,
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: (large ? theme.textTheme.titleMedium : theme.textTheme.titleSmall)
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  if (p.subtitle.isNotEmpty)
                    Text(p.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                  if (showPrices) ...[
                    const SizedBox(height: 4),
                    Text(Money.format(p.retailPrice),
                        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
                  ],
                  if (!p.inStock)
                    Text('Out of stock', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
