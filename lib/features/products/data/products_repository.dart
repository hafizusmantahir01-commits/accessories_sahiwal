import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/image_type.dart';
import '../../private_area/data/private_guard.dart';
import '../domain/product.dart';

const _productSelect =
    '*, category:categories(name), stock:inventory_balances(saleable_qty, non_saleable_qty), '
    'images:product_images(id, storage_path, is_primary, sort_order)';

const productImagesBucket = 'product-images';
const maxPhotosPerProduct = 5;

class ProductsRepository {
  ProductsRepository(this._ref, this._db);
  final Ref _ref;
  final SupabaseClient _db;

  Future<T> _wrap<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      throw AppException.from(e);
    }
  }

  // ---------------- Categories ----------------
  Future<List<Category>> categories() => _wrap(() async {
        final rows = await _db.from('categories').select().order('sort_order', ascending: true).order('name', ascending: true);
        return rows.map(Category.fromJson).toList();
      });

  Future<Category> addCategory(String name) => _wrap(() async {
        final row = await _db.from('categories').insert({'name': name.trim()}).select().single();
        return Category.fromJson(row);
      });

  // ---------------- Products ----------------
  Future<List<Product>> list({
    String? search,
    String? categoryId,
    bool includeInactive = false,
    bool inStockOnly = false,
  }) =>
      _wrap(() async {
        var q = _db.from('products').select(_productSelect);
        if (!includeInactive) q = q.eq('is_active', true);
        if (categoryId != null) q = q.eq('category_id', categoryId);
        final s = search?.trim() ?? '';
        if (s.isNotEmpty) {
          // Escape PostgREST "or" syntax characters in the user's text.
          // Spaces become wildcards so "c type cable" matches "C Type Cable"
          // (PostgREST "or" values must not contain raw spaces).
          final t = s.replaceAll(RegExp(r'[,()*%\\."]'), ' ').trim().split(RegExp(r'\s+')).join('*');
          q = q.or('code.ilike.*$t*,name.ilike.*$t*,brand.ilike.*$t*,model.ilike.*$t*');
        }
        final rows = await q.order('name', ascending: true).limit(500);
        final products = rows.map(Product.fromJson).toList();
        return inStockOnly ? products.where((p) => p.inStock).toList() : products;
      });

  Future<Product> get(String id) => _wrap(() async {
        final row = await _db.from('products').select(_productSelect).eq('id', id).maybeSingle();
        if (row == null) throw const AppException('Product not found.');
        return Product.fromJson(row);
      });

  /// Exact code / barcode lookup (server RPC; returns stock and selling prices).
  Future<Map<String, dynamic>?> lookup(String code) => _wrap(() async {
        final rows = await _db.rpc('lookup_product', params: {'p_code': code.trim()});
        final list = rows as List;
        return list.isEmpty ? null : Map<String, dynamic>.from(list.first as Map);
      });

  Future<String> create(ProductInput input) => _wrap(() async {
        final row = await _db.from('products').insert(input.toJson()).select('id').single();
        return row['id'] as String;
      });

  Future<void> update(String id, ProductInput input) => _wrap(() async {
        await _db.from('products').update(input.toJson()).eq('id', id);
      });

  Future<void> setActive(String id, bool active) => _wrap(() async {
        await _db.from('products').update({'is_active': active}).eq('id', id);
      });

  // ---------------- Photos ----------------
  Future<void> addPhoto(Product product, Uint8List bytes) async {
    if (product.images.length >= maxPhotosPerProduct) {
      throw const AppException('A product can have at most $maxPhotosPerProduct photos.');
    }
    if (bytes.length > ImageKind.maxBytes) {
      throw const AppException('Photo is too large (maximum 5 MB).');
    }
    final kind = ImageKind.detect(bytes);
    if (kind == null) throw const AppException('Only JPEG, PNG or WebP photos are allowed.');

    final path = 'products/${product.id}/${const Uuid().v4()}.${kind.extension}';
    await _wrap(() async {
      await _db.storage.from(productImagesBucket).uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: kind.mimeType, upsert: false, cacheControl: '31536000'),
          );
      try {
        final nextOrder = product.images.isEmpty
            ? 0
            : product.images.map((i) => i.sortOrder).reduce((a, b) => a > b ? a : b) + 1;
        await _db.from('product_images').insert({
          'product_id': product.id,
          'storage_path': path,
          'is_primary': product.images.isEmpty,
          'sort_order': nextOrder,
        });
      } catch (e) {
        // Do not leave an orphaned file if the database row failed.
        await _db.storage.from(productImagesBucket).remove([path]);
        rethrow;
      }
    });
  }

  Future<void> setPrimaryPhoto(Product product, ProductImage image) => _wrap(() async {
        await _db.from('product_images').update({'is_primary': false}).eq('product_id', product.id);
        await _db.from('product_images').update({'is_primary': true}).eq('id', image.id);
      });

  Future<void> movePhoto(Product product, ProductImage image, int delta) => _wrap(() async {
        final list = [...product.images];
        final i = list.indexWhere((x) => x.id == image.id);
        final j = i + delta;
        if (i < 0 || j < 0 || j >= list.length) return;
        final other = list[j];
        await _db.from('product_images').update({'sort_order': other.sortOrder}).eq('id', image.id);
        await _db.from('product_images').update({'sort_order': image.sortOrder}).eq('id', other.id);
      });

  /// Owner only. Works only for products never used in stock, purchases or
  /// sales (the server refuses otherwise — archive those instead).
  /// Recorded in the activity history with the reason.
  /// What deleting this product would remove (for the confirm box).
  Future<Map<String, dynamic>> deletePreview(String productId) => _wrap(() async {
        final res = await _db.rpc('owner_product_delete_preview', params: {'p_product_id': productId});
        return Map<String, dynamic>.from(res as Map);
      });

  Future<void> deleteProduct(String productId, String reason) => _wrap(() async {
        final res = await _db.rpc('owner_delete_product', params: {
          'p_product_id': productId,
          'p_reason': reason.trim(),
        });
        final paths = (res as List? ?? const []).map((e) => e.toString()).toList();
        if (paths.isNotEmpty) {
          try {
            await _db.storage.from(productImagesBucket).remove(paths);
          } catch (_) {/* product is gone; leftover files are harmless */}
        }
      });

  Future<void> deletePhoto(Product product, ProductImage image) => _wrap(() async {
        await _db.from('product_images').delete().eq('id', image.id);
        await _db.storage.from(productImagesBucket).remove([image.path]);
        if (image.isPrimary) {
          final remaining = product.images.where((x) => x.id != image.id).toList();
          if (remaining.isNotEmpty) {
            await _db.from('product_images').update({'is_primary': true}).eq('id', remaining.first.id);
          }
        }
      });

  // ---------------- Owner-only cost (requires unlocked private area) ----------------
  Future<Map<String, dynamic>> ownerCost(String productId) => guardedPrivate(_ref, () async {
        final res = await _db.rpc('owner_product_cost', params: {'p_product_id': productId});
        return Map<String, dynamic>.from(res as Map);
      });
}

final productsRepositoryProvider = Provider<ProductsRepository>(
  (ref) => ProductsRepository(ref, ref.watch(supabaseProvider)),
);

/// Short-lived signed URLs for private product photos, cached for ~50 minutes.
class SignedUrlCache {
  SignedUrlCache(this._db);
  final SupabaseClient _db;
  final _cache = <String, (String, DateTime)>{};
  static const _ttl = Duration(hours: 1);

  String? cached(String path) {
    final hit = _cache[path];
    if (hit != null && hit.$2.isAfter(DateTime.now())) return hit.$1;
    return null;
  }

  Future<String?> urlFor(String path) async {
    final hit = cached(path);
    if (hit != null) return hit;
    await prefetch([path]);
    return cached(path);
  }

  /// Fetches many URLs in one request (used by grids).
  Future<void> prefetch(List<String> paths) async {
    final missing = paths.where((p) => cached(p) == null).toSet().toList();
    if (missing.isEmpty) return;
    try {
      final urls = await _db.storage.from(productImagesBucket).createSignedUrls(missing, _ttl.inSeconds);
      final expiry = DateTime.now().add(_ttl - const Duration(minutes: 10));
      for (final u in urls) {
        _cache[u.path] = (u.signedUrl, expiry);
      }
    } catch (_) {
      // Images are optional; widgets show a placeholder.
    }
  }

  void clear() => _cache.clear();
}

final signedUrlCacheProvider = Provider<SignedUrlCache>((ref) {
  ref.watch(currentUserIdProvider); // new cache per signed-in user
  return SignedUrlCache(ref.watch(supabaseProvider));
});

final imageUrlProvider = FutureProvider.autoDispose.family<String?, String>(
  (ref, path) => ref.watch(signedUrlCacheProvider).urlFor(path),
);

// ---------------- Query providers ----------------
class ProductQuery {
  const ProductQuery({this.search = '', this.categoryId, this.includeInactive = false, this.inStockOnly = false});
  final String search;
  final String? categoryId;
  final bool includeInactive;
  final bool inStockOnly;

  @override
  bool operator ==(Object other) =>
      other is ProductQuery &&
      other.search == search &&
      other.categoryId == categoryId &&
      other.includeInactive == includeInactive &&
      other.inStockOnly == inStockOnly;

  @override
  int get hashCode => Object.hash(search, categoryId, includeInactive, inStockOnly);
}

final categoriesProvider = FutureProvider.autoDispose<List<Category>>(
  (ref) => ref.watch(productsRepositoryProvider).categories(),
);

final productListProvider = FutureProvider.autoDispose.family<List<Product>, ProductQuery>(
  (ref, q) => ref.watch(productsRepositoryProvider).list(
        search: q.search,
        categoryId: q.categoryId,
        includeInactive: q.includeInactive,
        inStockOnly: q.inStockOnly,
      ),
);

final productProvider = FutureProvider.autoDispose.family<Product, String>(
  (ref, id) => ref.watch(productsRepositoryProvider).get(id),
);

final ownerProductCostProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, id) => ref.watch(productsRepositoryProvider).ownerCost(id),
);

/// Owner: stock of one product split by purchase (oldest first = sold first).
class StockLot {
  const StockLot({required this.source, required this.receivedAt, required this.qtyIn, required this.qtyLeft, required this.unitCost});
  final String source;
  final DateTime receivedAt;
  final int qtyIn;
  final int qtyLeft;
  final Object? unitCost;

  factory StockLot.fromJson(Map<String, dynamic> j) => StockLot(
        source: (j['source_label'] as String?) ?? '',
        receivedAt: DateTime.parse(j['received_at'] as String),
        qtyIn: (j['qty_in'] as num).toInt(),
        qtyLeft: (j['qty_left'] as num).toInt(),
        unitCost: j['unit_cost'],
      );
}

final productLotsProvider = FutureProvider.autoDispose.family<List<StockLot>, String>((ref, id) {
  final db = ref.watch(supabaseProvider);
  return guardedPrivate(ref, () async {
    final rows = await db.rpc('owner_product_lots', params: {'p_product_id': id});
    return (rows as List).map((e) => StockLot.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  });
});
