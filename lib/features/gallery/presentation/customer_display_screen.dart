import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/money.dart';
import '../../../core/widgets/brand_logo.dart';
import '../../../core/widgets/common.dart';
import '../../products/data/products_repository.dart';
import '../../products/domain/product.dart';
import '../../products/presentation/widgets/product_thumb.dart';
import 'gallery_screen.dart';

/// Customer display mode: shows only available products, photos, specs and
/// (optionally) selling prices. No navigation, stock counts, costs, suppliers
/// or internal notes. Still requires a signed-in session — not a public link.
class CustomerDisplayScreen extends ConsumerStatefulWidget {
  const CustomerDisplayScreen({super.key, this.showPrices = true, this.categoryId});
  final bool showPrices;
  final String? categoryId;

  @override
  ConsumerState<CustomerDisplayScreen> createState() => _CustomerDisplayScreenState();
}

class _CustomerDisplayScreenState extends ConsumerState<CustomerDisplayScreen> {
  late bool _showPrices = widget.showPrices;
  late String? _categoryId = widget.categoryId;

  @override
  Widget build(BuildContext context) {
    final q = ProductQuery(categoryId: _categoryId, inStockOnly: true);
    final products = ref.watch(productListProvider(q));
    final categories = ref.watch(categoriesProvider);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const BrandHeader(logoSize: 36),
        actions: [
          IconButton(
            tooltip: _showPrices ? 'Hide prices' : 'Show prices',
            icon: Icon(_showPrices ? Icons.price_check : Icons.money_off),
            onPressed: () => setState(() => _showPrices = !_showPrices),
          ),
          IconButton(
            tooltip: 'Exit customer view',
            icon: const Icon(Icons.close),
            onPressed: () => context.canPop() ? context.pop() : context.go('/gallery'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (categories.hasValue && categories.requireValue.isNotEmpty)
            SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: _categoryId == null,
                    onSelected: (_) => setState(() => _categoryId = null),
                  ),
                  for (final c in categories.requireValue.where((c) => c.isActive)) ...[
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(c.name),
                      selected: _categoryId == c.id,
                      onSelected: (_) => setState(() => _categoryId = c.id),
                    ),
                  ],
                ],
              ),
            ),
          Expanded(
            child: AsyncView<List<Product>>(
              value: products,
              onRetry: () => ref.invalidate(productListProvider(q)),
              data: (list) => list.isEmpty
                  ? const EmptyState(icon: Icons.photo_library_outlined, title: 'No products available')
                  : ProductGrid(
                      products: list,
                      showPrices: _showPrices,
                      large: true,
                      onTap: (p) => _openProduct(context, p),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _openProduct(BuildContext context, Product p) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(p.name),
            leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
          ),
          body: LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > 760;
            final photos = p.images.isEmpty
                ? Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Center(child: Icon(Icons.image_outlined, size: 64)),
                  )
                : PageView(children: [for (final i in p.images) ProductPhoto(path: i.path)]);
            final details = Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name, style: Theme.of(context).textTheme.headlineSmall),
                  if (p.subtitle.isNotEmpty) Text(p.subtitle, style: Theme.of(context).textTheme.titleMedium),
                  if (_showPrices) ...[
                    const SizedBox(height: 12),
                    Text(Money.format(p.retailPrice),
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            )),
                  ],
                  if (p.warrantyDays > 0 || p.warrantyNote.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text('Warranty: ${[if (p.warrantyDays > 0) '${p.warrantyDays} days', if (p.warrantyNote.isNotEmpty) p.warrantyNote].join(' · ')}'),
                  ],
                  if (p.description.isNotEmpty) ...[const SizedBox(height: 16), Text(p.description)],
                ],
              ),
            );
            if (wide) {
              return Row(children: [Expanded(child: photos), Expanded(child: SingleChildScrollView(child: details))]);
            }
            return ListView(children: [AspectRatio(aspectRatio: 1, child: photos), details]);
          }),
        ),
      ),
    );
  }
}
