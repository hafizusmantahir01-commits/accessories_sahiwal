import 'package:decimal/decimal.dart';

import '../../../core/utils/money.dart';

class Category {
  const Category({required this.id, required this.name, required this.isActive});
  final String id;
  final String name;
  final bool isActive;

  factory Category.fromJson(Map<String, dynamic> j) =>
      Category(id: j['id'] as String, name: j['name'] as String, isActive: j['is_active'] != false);
}

class ProductImage {
  const ProductImage({required this.id, required this.path, required this.isPrimary, required this.sortOrder});
  final String id;
  final String path;
  final bool isPrimary;
  final int sortOrder;

  factory ProductImage.fromJson(Map<String, dynamic> j) => ProductImage(
        id: j['id'] as String,
        path: j['storage_path'] as String,
        isPrimary: j['is_primary'] == true,
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
      );
}

/// Product master data. Contains SELLING prices only — never cost.
class Product {
  const Product({
    required this.id,
    required this.code,
    required this.name,
    required this.categoryId,
    required this.categoryName,
    required this.brand,
    required this.model,
    required this.variant,
    required this.description,
    required this.wholesalePrice,
    required this.retailPrice,
    required this.warrantyNote,
    required this.warrantyDays,
    required this.reorderThreshold,
    required this.barcode,
    required this.isActive,
    required this.saleableQty,
    required this.nonSaleableQty,
    required this.images,
  });

  final String id;
  final String code;
  final String name;
  final String? categoryId;
  final String? categoryName;
  final String brand;
  final String model;
  final String variant;
  final String description;
  final Decimal wholesalePrice;
  final Decimal retailPrice;
  final String warrantyNote;
  final int warrantyDays;
  final int reorderThreshold;
  final String? barcode;
  final bool isActive;
  final int saleableQty;
  final int nonSaleableQty;
  final List<ProductImage> images;

  bool get isLowStock => saleableQty <= reorderThreshold;
  bool get inStock => saleableQty > 0;

  ProductImage? get primaryImage {
    if (images.isEmpty) return null;
    return images.firstWhere((i) => i.isPrimary, orElse: () => images.first);
  }

  String get subtitle => [brand, model, variant].where((s) => s.trim().isNotEmpty).join(' · ');

  /// PostgREST returns one-to-one embeds as an object, older versions as a list.
  static Map<String, dynamic>? _one(Object? v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    if (v is List && v.isNotEmpty) return Map<String, dynamic>.from(v.first as Map);
    return null;
  }

  factory Product.fromJson(Map<String, dynamic> j) {
    final stock = _one(j['stock']);
    final category = _one(j['category']);
    final images = (j['images'] as List? ?? const [])
        .map((e) => ProductImage.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return Product(
      id: j['id'] as String,
      code: j['code'] as String,
      name: j['name'] as String,
      categoryId: j['category_id'] as String?,
      categoryName: category?['name'] as String?,
      brand: (j['brand'] as String?) ?? '',
      model: (j['model'] as String?) ?? '',
      variant: (j['variant'] as String?) ?? '',
      description: (j['description'] as String?) ?? '',
      wholesalePrice: Money.parse(j['wholesale_price']),
      retailPrice: Money.parse(j['retail_price']),
      warrantyNote: (j['warranty_note'] as String?) ?? '',
      warrantyDays: (j['warranty_days'] as num?)?.toInt() ?? 0,
      reorderThreshold: (j['reorder_threshold'] as num?)?.toInt() ?? 0,
      barcode: j['barcode'] as String?,
      isActive: j['is_active'] != false,
      saleableQty: (stock?['saleable_qty'] as num?)?.toInt() ?? 0,
      nonSaleableQty: (stock?['non_saleable_qty'] as num?)?.toInt() ?? 0,
      images: images,
    );
  }
}

/// Input for create/update. Stock is never set here (opening stock/purchases do that).
class ProductInput {
  const ProductInput({
    required this.code,
    required this.name,
    required this.categoryId,
    required this.brand,
    required this.model,
    required this.variant,
    required this.description,
    required this.wholesalePrice,
    required this.retailPrice,
    required this.warrantyNote,
    required this.warrantyDays,
    required this.reorderThreshold,
    required this.barcode,
    required this.isActive,
  });

  final String code;
  final String name;
  final String? categoryId;
  final String brand;
  final String model;
  final String variant;
  final String description;
  final Decimal wholesalePrice;
  final Decimal retailPrice;
  final String warrantyNote;
  final int warrantyDays;
  final int reorderThreshold;
  final String barcode;
  final bool isActive;

  Map<String, dynamic> toJson() => {
        'code': code.trim().toUpperCase(),
        'name': name.trim(),
        'category_id': categoryId,
        'brand': brand.trim(),
        'model': model.trim(),
        'variant': variant.trim(),
        'description': description.trim(),
        'wholesale_price': wholesalePrice.toString(),
        'retail_price': retailPrice.toString(),
        'warranty_note': warrantyNote.trim(),
        'warranty_days': warrantyDays,
        'reorder_threshold': reorderThreshold,
        'barcode': barcode.trim().isEmpty ? null : barcode.trim(),
        'is_active': isActive,
      };
}
