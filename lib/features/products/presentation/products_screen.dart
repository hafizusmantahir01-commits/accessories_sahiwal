import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../../auth/data/auth_repository.dart';
import '../data/products_repository.dart';
import '../domain/product.dart';
import 'widgets/product_thumb.dart';

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key, this.initialQuery});
  final String? initialQuery;

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  late final TextEditingController _search = TextEditingController(text: widget.initialQuery ?? '');
  Timer? _debounce;
  String _query = '';
  String? _categoryId;
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery ?? '';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => setState(() => _query = v.trim()));
  }

  /// Enter on the search box: exact code/barcode match opens the product.
  Future<void> _exactLookup(String code) async {
    if (code.trim().isEmpty) return;
    try {
      final hit = await ref.read(productsRepositoryProvider).lookup(code);
      if (!mounted) return;
      if (hit != null) {
        unawaited(context.push('/products/${hit['id']}'));
      } else {
        setState(() => _query = code.trim());
      }
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOwner = ref.watch(isOwnerProvider);
    final query = ProductQuery(search: _query, categoryId: _categoryId, includeInactive: _showArchived);
    final products = ref.watch(productListProvider(query));
    final categories = ref.watch(categoriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Products'),
        actions: [
          if (isOwner)
            IconButton(
              tooltip: _showArchived ? 'Hide archived' : 'Show archived',
              icon: Icon(_showArchived ? Icons.archive : Icons.archive_outlined),
              onPressed: () => setState(() => _showArchived = !_showArchived),
            ),
        ],
      ),
      floatingActionButton: isOwner
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/products/new'),
              icon: const Icon(Icons.add),
              label: const Text('Add product'),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: _onSearch,
              onSubmitted: _exactLookup,
              decoration: InputDecoration(
                hintText: 'Search name or enter product code',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: categories.when(
              data: (cats) => ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: const Text('All'),
                      selected: _categoryId == null,
                      onSelected: (_) => setState(() => _categoryId = null),
                    ),
                  ),
                  for (final c in cats.where((c) => c.isActive))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(c.name),
                        selected: _categoryId == c.id,
                        onSelected: (_) => setState(() => _categoryId = _categoryId == c.id ? null : c.id),
                      ),
                    ),
                ],
              ),
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(productListProvider(query).future),
              child: AsyncView<List<Product>>(
                value: products,
                onRetry: () => ref.invalidate(productListProvider(query)),
                data: (list) {
                  if (list.isEmpty) {
                    return ListView(children: [
                      EmptyState(
                        icon: Icons.inventory_2_outlined,
                        title: _query.isEmpty ? 'No products yet' : 'No products match "$_query"',
                        message: isOwner && _query.isEmpty ? 'Add your first product to get started.' : null,
                      ),
                    ]);
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => ProductTile(product: list[i]),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ProductTile extends StatelessWidget {
  const ProductTile({super.key, required this.product});
  final Product product;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = product;
    final stockColor = p.saleableQty == 0
        ? AppTheme.danger
        : (p.isLowStock ? AppTheme.warning : AppTheme.success);
    return Card3D(
      tilt: false,
      radius: 14,
      padding: const EdgeInsets.all(12),
      onTap: () => context.push('/products/${p.id}'),
      child: Row(
            children: [
              ProductThumb(path: p.primaryImage?.path),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(p.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                        ),
                        if (!p.isActive) ...[const SizedBox(width: 6), const StatusChip('Archived', color: Colors.grey)],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [p.code, if (p.subtitle.isNotEmpty) p.subtitle].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        Text('Retail ${Money.format(p.retailPrice)}', style: theme.textTheme.bodySmall),
                        Text('Wholesale ${Money.format(p.wholesalePrice)}', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${p.saleableQty}',
                      style: theme.textTheme.titleLarge?.copyWith(color: stockColor, fontWeight: FontWeight.w700)),
                  Text('in stock', style: theme.textTheme.bodySmall),
                ],
              ),
        ],
      ),
    );
  }
}
