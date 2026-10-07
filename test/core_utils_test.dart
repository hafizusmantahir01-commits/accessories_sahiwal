import 'dart:typed_data';

import 'package:accessories_sahiwal/core/utils/image_type.dart';
import 'package:accessories_sahiwal/core/utils/money.dart';
import 'package:accessories_sahiwal/core/utils/validators.dart';
import 'package:accessories_sahiwal/features/purchases/domain/purchase.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

Decimal d(String s) => Decimal.parse(s);

void main() {
  group('Money', () {
    test('formats PKR with grouping and 2 decimals', () {
      expect(Money.format(d('0')), 'Rs. 0.00');
      expect(Money.format(d('950')), 'Rs. 950.00');
      expect(Money.format(d('1234567.5')), 'Rs. 1,234,567.50');
      expect(Money.format(d('-1400')), 'Rs. -1,400.00');
      expect(Money.format(3500.0), 'Rs. 3,500.00');
      expect(Money.format('20000.00', withSymbol: false), '20,000.00');
    });

    test('parses user input safely', () {
      expect(Money.tryParseInput('1,250.50'), d('1250.5'));
      expect(Money.tryParseInput(' 300 '), d('300'));
      expect(Money.tryParseInput('10.555'), isNull, reason: 'more than 2 decimals');
      expect(Money.tryParseInput('-5'), isNull);
      expect(Money.tryParseInput('abc'), isNull);
      expect(Money.tryParseInput(''), isNull);
    });

    test('decimal arithmetic has no floating point drift', () {
      expect(d('0.1') + d('0.2'), d('0.3'));
      expect(Decimal.fromInt(3) * d('33.33'), d('99.99'));
    });
  });

  group('Validators', () {
    test('quantity is a positive whole number', () {
      expect(Validators.quantity('5'), isNull);
      expect(Validators.quantity('0'), isNotNull);
      expect(Validators.quantity('0', allowZero: true), isNull);
      expect(Validators.quantity('1.5'), isNotNull);
      expect(Validators.quantity('-2'), isNotNull);
      expect(Validators.quantity(''), isNotNull);
    });

    test('product code allows blank (auto) and safe characters', () {
      expect(Validators.productCode(''), isNull);
      expect(Validators.productCode('as-0001'), isNull);
      expect(Validators.productCode('CHG/20W.1'), isNull);
      expect(Validators.productCode('bad code'), isNotNull);
      expect(Validators.productCode('-start'), isNotNull);
    });

    test('email and password', () {
      expect(Validators.email('owner@shop.pk'), isNull);
      expect(Validators.email('owner'), isNotNull);
      expect(Validators.password('short'), isNotNull);
      expect(Validators.password('long-enough'), isNull);
    });
  });

  group('ImageKind', () {
    test('detects by magic bytes, not file name', () {
      expect(ImageKind.detect(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), ImageKind.jpeg);
      expect(ImageKind.detect(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), ImageKind.png);
      expect(
        ImageKind.detect(Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])),
        ImageKind.webp,
      );
      expect(ImageKind.detect(Uint8List.fromList('%PDF-1.7'.codeUnits)), isNull);
    });
  });

  group('Purchase preview', () {
    test('totals lines, discounts and extra costs', () {
      final lines = [
        DraftLine(productId: 'a', productCode: 'A', productName: 'A', quantity: 10, unitPrice: d('300')),
        DraftLine(productId: 'b', productCode: 'B', productName: 'B', quantity: 3, unitPrice: d('100'), lineDiscount: d('25.50')),
      ];
      final preview = PurchasePreview(lines, d('100'));
      expect(preview.merchandise, d('3274.50'));
      expect(preview.total, d('3374.50'));
    });

    test('discount larger than line value is invalid', () {
      final l = DraftLine(productId: 'a', productCode: 'A', productName: 'A', quantity: 2, unitPrice: d('10'), lineDiscount: d('25'));
      expect(l.discountValid, isFalse);
    });
  });
}
