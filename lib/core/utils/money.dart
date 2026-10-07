import 'package:decimal/decimal.dart';

/// Money helpers. All amounts use [Decimal] — never binary floating point.
/// The server is the source of truth for totals; client math is preview only.
abstract final class Money {
  static final Decimal zero = Decimal.zero;

  /// Parses a value from the API (num or String) into a Decimal.
  static Decimal parse(Object? value) {
    if (value == null) return Decimal.zero;
    if (value is Decimal) return value;
    return Decimal.tryParse(value.toString()) ?? Decimal.zero;
  }

  /// Parses user input like "1,250.50". Returns null when invalid,
  /// negative, or with more than [maxDecimals] decimals.
  static Decimal? tryParseInput(String input, {int maxDecimals = 2}) {
    final cleaned = input.replaceAll(',', '').replaceAll(' ', '').trim();
    if (cleaned.isEmpty) return null;
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(cleaned)) return null;
    final d = Decimal.tryParse(cleaned);
    if (d == null) return null;
    if (d.scale > maxDecimals) return null;
    return d;
  }

  /// "Rs. 1,234.50"
  static String format(Object? value, {bool withSymbol = true}) {
    final d = parse(value);
    final negative = d < Decimal.zero;
    final fixed = (negative ? -d : d).toStringAsFixed(2);
    final parts = fixed.split('.');
    final grouped = _group(parts[0]);
    final text = '$grouped.${parts[1]}';
    final signed = negative ? '-$text' : text;
    return withSymbol ? 'Rs. $signed' : signed;
  }

  /// Plain editable text for a form field ("1250.5" → "1250.50").
  static String toInput(Object? value) => parse(value).toStringAsFixed(2);

  static String _group(String digits) {
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return buf.toString();
  }
}
