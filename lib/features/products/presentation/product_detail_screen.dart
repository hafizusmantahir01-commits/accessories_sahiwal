import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/common.dart';
import '../../auth/data/auth_repository.dart';
import '../../private_area/data/private_area_controller.dart';
import '../../stock/presentation/stock_history_sheet.dart';
import '../data/products_repository.dart';
import '../domain/product.dart';
import 'widgets/product_thumb.dart';

class ProductDetailScreen extends ConsumerWidget {
  const ProductDetailScreen({super.key, required this.productId});
  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final product = ref.watch(productProvider(productId));
    final isOwner = ref.watch(isOwnerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Product'),
        actions: [
          if (isOwner && product.hasValue)
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/products/$productId/edit'),
            ),
          if (isOwner && product.hasValue) _ArchiveMenu(product: product.requireValue),
        ],
      ),
      body: AsyncView<Product>(
        value: product,
        onRetry: () => ref.invalidate(productProvider(productId)),
        data: (p) => RefreshIndicator(
          onRefresh: () => ref.refresh(productProvider(productId).future),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: PageBody(
              maxWidth: 1000,
              child: LayoutBuilder(builder: (context, c) {
                final wide = c.maxWidth >= 760;
                final photos = _PhotosSection(product: p, canEdit: isOwner);
                final info = _InfoSection(product: p, isOwner: isOwner);
                if (wide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: photos),
                      const SizedBox(width: 16),
                      Expanded(flex: 6, child: info),
                    ],
                  );
                }
                return Column(children: [photos, const SizedBox(height: 16), info]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArchiveMenu extends ConsumerWidget {
  const _ArchiveMenu({required this.product});
  final Product product;

  Future<void> _toggleArchive(BuildContext context, WidgetRef ref) async {
    final archive = product.isActive;
    final ok = await confirmDialog(
      context,
      title: archive ? 'Archive product?' : 'Restore product?',
      message: archive
          ? 'Archived products are hidden from lists and new sales. History and old bills are kept.'
          : 'The product will appear in lists again.',
      confirmLabel: archive ? 'Archive' : 'Restore',
    );
    if (!ok) return;
    try {
      await ref.read(productsRepositoryProvider).setActive(product.id, !archive);
      ref.invalidate(productProvider(product.id));
      ref.invalidate(productListProvider);
      if (context.mounted) context.showSuccess(archive ? 'Product archived.' : 'Product restored.');
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final reason = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete product?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('"${product.name}" (${product.code}) and its photos will be deleted permanently. '
                'This is saved in the activity history.'),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Reason *', hintText: 'e.g. added by mistake'),
            ),
            const SizedBox(height: 8),
            Text(
              'Products that already have stock, purchases or sales cannot be deleted — archive them instead.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () {
              if (reason.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(productsRepositoryProvider).deleteProduct(product.id, reason.text);
      ref.invalidate(productListProvider);
      if (!context.mounted) return;
      context.showSuccess('Product deleted.');
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/products');
      }
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      onSelected: (v) => v == 'delete' ? _delete(context, ref) : _toggleArchive(context, ref),
      itemBuilder: (_) => [
        PopupMenuItem(value: 'toggle', child: Text(product.isActive ? 'Archive product' : 'Restore product')),
        PopupMenuItem(
          value: 'delete',
          child: Text('Delete product', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      ],
    );
  }
}

class _InfoSection extends ConsumerWidget {
  const _InfoSection({required this.product, required this.isOwner});
  final Product product;
  final bool isOwner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = product;
    final theme = Theme.of(context);
    final stockColor = p.saleableQty == 0 ? AppTheme.danger : (p.isLowStock ? AppTheme.warning : AppTheme.success);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(p.name, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SelectableText(p.code, style: theme.textTheme.titleSmall),
            if (p.categoryName != null) StatusChip(p.categoryName!),
            if (!p.isActive) const StatusChip('Archived', color: Colors.grey),
          ],
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Stock',
          trailing: TextButton.icon(
            icon: const Icon(Icons.history, size: 18),
            label: const Text('History'),
            onPressed: () => showStockHistory(context, productId: p.id, title: p.name),
          ),
          child: Row(
            children: [
              Text('${p.saleableQty}',
                  style: theme.textTheme.displaySmall?.copyWith(color: stockColor, fontWeight: FontWeight.w700)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.saleableQty == 0 ? 'Out of stock' : (p.isLowStock ? 'Low stock' : 'Available')),
                    Text('Reorder at ${p.reorderThreshold}', style: theme.textTheme.bodySmall),
                    if (p.nonSaleableQty > 0)
                      Text('${p.nonSaleableQty} non-saleable (damaged)', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Selling prices',
          child: Column(
            children: [
              InfoRow('Retail', Money.format(p.retailPrice), bold: true),
              InfoRow('Wholesale', Money.format(p.wholesalePrice), bold: true),
            ],
          ),
        ),
        if (isOwner) ...[const SizedBox(height: 12), _OwnerCostCard(productId: p.id)],
        const SizedBox(height: 12),
        SectionCard(
          title: 'Details',
          child: Column(
            children: [
              if (p.brand.isNotEmpty) InfoRow('Brand', p.brand),
              if (p.model.isNotEmpty) InfoRow('Model', p.model),
              if (p.variant.isNotEmpty) InfoRow('Variant', p.variant),
              if (p.barcode != null) InfoRow('Barcode', p.barcode!),
              InfoRow(
                'Warranty',
                p.warrantyDays == 0 && p.warrantyNote.isEmpty
                    ? 'No warranty'
                    : [if (p.warrantyDays > 0) '${p.warrantyDays} days', if (p.warrantyNote.isNotEmpty) p.warrantyNote]
                        .join(' · '),
              ),
              if (p.description.isNotEmpty) ...[
                const Divider(height: 24),
                Align(alignment: Alignment.centerLeft, child: Text(p.description)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Owner-only: shown with figures only when the private area is unlocked.
class _OwnerCostCard extends ConsumerWidget {
  const _OwnerCostCard({required this.productId});
  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked = ref.watch(privateAreaProvider.select((s) => s.unlocked));
    if (!unlocked) {
      return SectionCard(
        title: 'Cost (owner only)',
        child: Row(
          children: [
            const Icon(Icons.lock_outline),
            const SizedBox(width: 12),
            const Expanded(child: Text('Unlock the private area to see average cost and stock value.')),
            TextButton(
              onPressed: () => context.go(
                Uri(path: '/private/unlock', queryParameters: {'from': '/private/valuation'}).toString(),
              ),
              child: const Text('Unlock'),
            ),
          ],
        ),
      );
    }
    final cost = ref.watch(ownerProductCostProvider(productId));
    return SectionCard(
      title: 'Cost (owner only)',
      child: cost.when(
        data: (c) => Column(
          children: [
            InfoRow('Average cost', Money.format(c['average_cost'])),
            InfoRow('Stock value', Money.format(c['carrying_value']), bold: true),
          ],
        ),
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(AppException.from(e).message),
      ),
    );
  }
}

class _PhotosSection extends ConsumerStatefulWidget {
  const _PhotosSection({required this.product, required this.canEdit});
  final Product product;
  final bool canEdit;

  @override
  ConsumerState<_PhotosSection> createState() => _PhotosSectionState();
}

class _PhotosSectionState extends ConsumerState<_PhotosSection> {
  final _page = PageController();
  int _index = 0;
  bool _uploading = false;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _addPhotos() async {
    final p = widget.product;
    final remaining = maxPhotosPerProduct - p.images.length;
    if (remaining <= 0) {
      context.showError(const AppException('A product can have at most $maxPhotosPerProduct photos.'));
      return;
    }
    // Ask: take a new picture with the camera, or choose from the gallery.
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo with camera'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text('Choose from gallery (up to $remaining)'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    // Resize/compress on the device so photos load quickly on phones.
    final picker = ImagePicker();
    final List<XFile> files;
    if (source == ImageSource.camera) {
      final shot = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 82,
      );
      files = shot == null ? const [] : [shot];
    } else if (remaining == 1) {
      // pickMultiImage requires limit >= 2.
      final one = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, maxHeight: 1600, imageQuality: 82);
      files = one == null ? const [] : [one];
    } else {
      files = await picker.pickMultiImage(maxWidth: 1600, maxHeight: 1600, imageQuality: 82, limit: remaining);
    }
    if (files.isEmpty || !mounted) return;
    setState(() => _uploading = true);
    final repo = ref.read(productsRepositoryProvider);
    var current = p;
    var added = 0;
    try {
      for (final f in files.take(remaining)) {
        await repo.addPhoto(current, await f.readAsBytes());
        added++;
        current = await repo.get(p.id);
      }
      if (mounted) context.showSuccess('$added photo${added == 1 ? '' : 's'} added.');
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      // Riverpod 3 throws if a WidgetRef is used after the widget unmounted.
      if (mounted) {
        ref.invalidate(productProvider(p.id));
        setState(() => _uploading = false);
      }
    }
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      if (!mounted) return;
      ref.invalidate(productProvider(widget.product.id));
      context.showSuccess(done);
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final images = p.images;
    final repo = ref.read(productsRepositoryProvider);
    final safeIndex = images.isEmpty ? 0 : _index.clamp(0, images.length - 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: images.isEmpty
                ? Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Icon(Icons.image_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
                  )
                : PageView.builder(
                    controller: _page,
                    itemCount: images.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (_, i) => ProductPhoto(path: images[i].path),
                  ),
          ),
        ),
        if (images.length > 1) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: images.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => _page.animateToPage(i, duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: i == safeIndex ? Theme.of(context).colorScheme.primary : Colors.transparent,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ProductThumb(path: images[i].path, size: 60, radius: 8),
                ),
              ),
            ),
          ),
        ],
        if (widget.canEdit) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _uploading || images.length >= maxPhotosPerProduct ? null : _addPhotos,
                icon: _uploading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_a_photo_outlined),
                label: Text('Add photos (${images.length}/$maxPhotosPerProduct)'),
              ),
              if (images.isNotEmpty) ...[
                if (!images[safeIndex].isPrimary)
                  OutlinedButton.icon(
                    onPressed: () => _run(() => repo.setPrimaryPhoto(p, images[safeIndex]), 'Main photo set.'),
                    icon: const Icon(Icons.star_outline),
                    label: const Text('Make main'),
                  ),
                IconButton.outlined(
                  tooltip: 'Move left',
                  onPressed: safeIndex == 0 ? null : () => _run(() => repo.movePhoto(p, images[safeIndex], -1), 'Photo moved.'),
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton.outlined(
                  tooltip: 'Move right',
                  onPressed: safeIndex >= images.length - 1
                      ? null
                      : () => _run(() => repo.movePhoto(p, images[safeIndex], 1), 'Photo moved.'),
                  icon: const Icon(Icons.chevron_right),
                ),
                IconButton.outlined(
                  tooltip: 'Delete photo',
                  onPressed: () async {
                    final ok = await confirmDialog(context,
                        title: 'Delete photo?', message: 'This photo will be removed.', confirmLabel: 'Delete', destructive: true);
                    if (ok) await _run(() => repo.deletePhoto(p, images[safeIndex]), 'Photo deleted.');
                  },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text('JPEG, PNG or WebP · up to 5 MB each', style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}
